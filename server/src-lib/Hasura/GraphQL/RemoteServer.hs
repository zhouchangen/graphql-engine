module Hasura.GraphQL.RemoteServer
  ( fetchRemoteSchema,
    IntrospectionResult,
    execRemoteGQ,
    identityCustomizer,
    -- The following exports are needed for unit tests
    getCustomizer,
    validateSchemaCustomizationsDistinct,
  )
where

import Control.Arrow.Extended (left)
import Control.Exception (try)
import Control.Lens (set, (^.))
import Control.Monad.Unique
import Data.Aeson ((.:), (.:?))
import Data.Aeson qualified as J
import Data.Aeson.Types qualified as J
import Data.ByteString.Lazy qualified as BL
import Data.Environment qualified as Env
import Data.FileEmbed (makeRelativeToProject)
import Data.HashMap.Strict qualified as Map
import Data.HashSet qualified as Set
import Data.List.Extended (duplicates)
import Data.Text qualified as T
import Data.Text.Extended (dquoteList, (<<>))
import Data.Tuple (swap)
import Hasura.Base.Error
import Hasura.GraphQL.Parser.Collect ()
import Hasura.GraphQL.Parser.Monad qualified as P
-- Needed for GHCi and HLS due to TH in cyclically dependent modules (see https://gitlab.haskell.org/ghc/ghc/-/issues/1012)
import Hasura.GraphQL.Schema.Remote (buildRemoteParser)
import Hasura.GraphQL.Transport.HTTP.Protocol
import Hasura.HTTP
import Hasura.Prelude
import Hasura.RQL.DDL.Headers (makeHeadersFromConf)
import Hasura.RQL.Types
import Hasura.Server.Utils
import Hasura.Session
import Hasura.Tracing qualified as Tracing
import Language.GraphQL.Draft.Parser qualified as G
import Language.GraphQL.Draft.Syntax qualified as G
import Language.Haskell.TH.Syntax qualified as TH
import Network.HTTP.Client.Transformable qualified as HTTP
import Network.URI (URI)
import Network.Wreq qualified as Wreq

introspectionQuery :: GQLReqOutgoing
introspectionQuery =
  $( do
       fp <- makeRelativeToProject "src-rsr/introspection.json"
       TH.qAddDependentFile fp
       eitherResult <- TH.runIO $ J.eitherDecodeFileStrict fp
       either fail TH.lift $ do
         r@GQLReq {..} <- eitherResult
         op <- left show $ getSingleOperation r
         pure GQLReq {_grQuery = op, ..}
   )

validateSchemaCustomizations ::
  forall m.
  MonadError QErr m =>
  RemoteSchemaCustomizer ->
  RemoteSchemaIntrospection ->
  m ()
validateSchemaCustomizations remoteSchemaCustomizer remoteSchemaIntrospection = do
  validateSchemaCustomizationsConsistent remoteSchemaCustomizer remoteSchemaIntrospection
  validateSchemaCustomizationsDistinct remoteSchemaCustomizer remoteSchemaIntrospection

validateSchemaCustomizationsConsistent ::
  forall m.
  MonadError QErr m =>
  RemoteSchemaCustomizer ->
  RemoteSchemaIntrospection ->
  m ()
validateSchemaCustomizationsConsistent remoteSchemaCustomizer (RemoteSchemaIntrospection typeDefinitions) = do
  traverse_ validateInterfaceFields typeDefinitions
  where
    customizeFieldName = remoteSchemaCustomizeFieldName remoteSchemaCustomizer

    validateInterfaceFields :: G.TypeDefinition [G.Name] a -> m ()
    validateInterfaceFields = \case
      G.TypeDefinitionInterface G.InterfaceTypeDefinition {..} ->
        for_ _itdPossibleTypes $ \typeName ->
          for_ _itdFieldsDefinition $ \G.FieldDefinition {..} -> do
            let interfaceCustomizedFieldName = customizeFieldName _itdName _fldName
                typeCustomizedFieldName = customizeFieldName typeName _fldName
            when (interfaceCustomizedFieldName /= typeCustomizedFieldName) $
              throwRemoteSchema $
                "Remote schema customization inconsistency: field name mapping for field "
                  <> _fldName
                  <<> " of interface "
                  <> _itdName
                  <<> " is inconsistent with mapping for type "
                  <> typeName
                  <<> ". Interface field name maps to "
                  <> interfaceCustomizedFieldName
                  <<> ". Type field name maps to "
                  <> typeCustomizedFieldName
                  <<> "."
      _ -> pure ()

validateSchemaCustomizationsDistinct ::
  forall m.
  MonadError QErr m =>
  RemoteSchemaCustomizer ->
  RemoteSchemaIntrospection ->
  m ()
validateSchemaCustomizationsDistinct remoteSchemaCustomizer (RemoteSchemaIntrospection typeDefinitions) = do
  validateTypeMappingsAreDistinct
  traverse_ validateFieldMappingsAreDistinct typeDefinitions
  where
    customizeTypeName = remoteSchemaCustomizeTypeName remoteSchemaCustomizer
    customizeFieldName = remoteSchemaCustomizeFieldName remoteSchemaCustomizer

    validateTypeMappingsAreDistinct :: m ()
    validateTypeMappingsAreDistinct = do
      let dups = duplicates $ (customizeTypeName . typeDefinitionName) <$> typeDefinitions
      unless (Set.null dups) $
        throwRemoteSchema $
          "Type name mappings are not distinct; the following types appear more than once: "
            <> dquoteList dups

    validateFieldMappingsAreDistinct :: G.TypeDefinition a b -> m ()
    validateFieldMappingsAreDistinct = \case
      G.TypeDefinitionInterface G.InterfaceTypeDefinition {..} -> do
        let dups = duplicates $ (customizeFieldName _itdName . G._fldName) <$> _itdFieldsDefinition
        unless (Set.null dups) $
          throwRemoteSchema $
            "Field name mappings for interface type " <> _itdName
              <<> " are not distinct; the following fields appear more than once: "
              <> dquoteList dups
      G.TypeDefinitionObject G.ObjectTypeDefinition {..} -> do
        let dups = duplicates $ (customizeFieldName _otdName . G._fldName) <$> _otdFieldsDefinition
        unless (Set.null dups) $
          throwRemoteSchema $
            "Field name mappings for object type " <> _otdName
              <<> " are not distinct; the following fields appear more than once: "
              <> dquoteList dups
      _ -> pure ()

-- | Make an introspection query to the remote graphql server for the data we
-- need to present and stitch the remote schema. This powers add_remote_schema,
-- and also is called by schema cache rebuilding code in "Hasura.RQL.DDL.Schema.Cache".
fetchRemoteSchema ::
  forall m.
  (MonadIO m, MonadUnique m, MonadError QErr m, Tracing.MonadTrace m) =>
  Env.Environment ->
  HTTP.Manager ->
  RemoteSchemaName ->
  ValidatedRemoteSchemaDef ->
  m RemoteSchemaCtx
fetchRemoteSchema env manager _rscName rsDef@ValidatedRemoteSchemaDef {..} = do
  (_, _, _rscRawIntrospectionResult) <-
    execRemoteGQ env manager adminUserInfo [] rsDef introspectionQuery

  -- Parse the JSON into flat GraphQL type AST
  FromIntrospection _rscIntroOriginal <-
    J.eitherDecode _rscRawIntrospectionResult `onLeft` (throwRemoteSchema . T.pack)

  -- possibly transform type names from the remote schema, per the user's 'RemoteSchemaDef'
  let rsCustomizer = getCustomizer (addDefaultRoots _rscIntroOriginal) _vrsdCustomization

  validateSchemaCustomizations rsCustomizer (irDoc _rscIntroOriginal)

  let _rscInfo = RemoteSchemaInfo {..}
  -- Check that the parsed GraphQL type info is valid by running the schema generation
  (piQuery, piMutation, piSubscription) <-
    P.runSchemaT @m @(P.ParseT Identity) $ buildRemoteParser _rscIntroOriginal _rscInfo

  -- The 'rawIntrospectionResult' contains the 'Bytestring' response of
  -- the introspection result of the remote server. We store this in the
  -- 'RemoteSchemaCtx' because we can use this when the 'introspect_remote_schema'
  -- is called by simple encoding the result to JSON.
  return
    RemoteSchemaCtx
      { _rscPermissions = mempty,
        _rscParsed = ParsedIntrospection {..},
        ..
      }
  where
    -- If there is no explicit mutation or subscription root type we need to check for
    -- objects type definitions with the default names "Mutation" and "Subscription".
    -- If found, we add the default roots explicitly to the IntrospectionResult.
    -- This simplifies the customization code.
    addDefaultRoots :: IntrospectionResult -> IntrospectionResult
    addDefaultRoots IntrospectionResult {..} =
      IntrospectionResult
        { irMutationRoot = getRootTypeName $$(G.litName "Mutation") irMutationRoot,
          irSubscriptionRoot = getRootTypeName $$(G.litName "Subscription") irSubscriptionRoot,
          ..
        }
      where
        getRootTypeName defaultName providedName =
          providedName <|> (defaultName <$ lookupObject irDoc defaultName)

-- | Parsing the introspection query result.  We use this newtype wrapper to
-- avoid orphan instances and parse JSON in the way that we need for GraphQL
-- introspection results.
newtype FromIntrospection a = FromIntrospection {fromIntrospection :: a}
  deriving (Show, Eq, Generic, Functor)

pErr :: (MonadFail m) => Text -> m a
pErr = fail . T.unpack

kindErr :: (MonadFail m) => Text -> Text -> m a
kindErr gKind eKind = pErr $ "Invalid `kind: " <> gKind <> "` in " <> eKind

instance J.FromJSON (FromIntrospection G.Description) where
  parseJSON = fmap (FromIntrospection . G.Description) . J.parseJSON

instance J.FromJSON (FromIntrospection G.ScalarTypeDefinition) where
  parseJSON = J.withObject "ScalarTypeDefinition" $ \o -> do
    kind <- o .: "kind"
    name <- o .: "name"
    desc <- o .:? "description"
    when (kind /= "SCALAR") $ kindErr kind "scalar"
    let desc' = fmap fromIntrospection desc
        r = G.ScalarTypeDefinition desc' name []
    return $ FromIntrospection r

instance J.FromJSON (FromIntrospection (G.ObjectTypeDefinition G.InputValueDefinition)) where
  parseJSON = J.withObject "ObjectTypeDefinition" $ \o -> do
    kind <- o .: "kind"
    name <- o .: "name"
    desc <- o .:? "description"
    fields <- o .:? "fields"
    interfaces :: Maybe [FromIntrospection (G.InterfaceTypeDefinition [G.Name] G.InputValueDefinition)] <- o .:? "interfaces"
    when (kind /= "OBJECT") $ kindErr kind "object"
    let implIfaces = map G._itdName $ maybe [] (fmap fromIntrospection) interfaces
        flds = maybe [] (fmap fromIntrospection) fields
        desc' = fmap fromIntrospection desc
        r = G.ObjectTypeDefinition desc' name implIfaces [] flds
    return $ FromIntrospection r

instance (J.FromJSON (FromIntrospection a)) => J.FromJSON (FromIntrospection (G.FieldDefinition a)) where
  parseJSON = J.withObject "FieldDefinition" $ \o -> do
    name <- o .: "name"
    desc <- o .:? "description"
    args <- o .: "args"
    _type <- o .: "type"
    let desc' = fmap fromIntrospection desc
        r =
          G.FieldDefinition
            desc'
            name
            (fmap fromIntrospection args)
            (fromIntrospection _type)
            []
    return $ FromIntrospection r

instance J.FromJSON (FromIntrospection G.GType) where
  parseJSON = J.withObject "GType" $ \o -> do
    kind <- o .: "kind"
    mName <- o .:? "name"
    mType <- o .:? "ofType"
    r <- case (kind, mName, mType) of
      ("NON_NULL", _, Just typ) -> return $ mkNotNull (fromIntrospection typ)
      ("NON_NULL", _, Nothing) -> pErr "NON_NULL should have `ofType`"
      ("LIST", _, Just typ) ->
        return $ G.TypeList (G.Nullability True) (fromIntrospection typ)
      ("LIST", _, Nothing) -> pErr "LIST should have `ofType`"
      (_, Just name, _) -> return $ G.TypeNamed (G.Nullability True) name
      _ -> pErr $ "kind: " <> kind <> " should have name"
    return $ FromIntrospection r
    where
      mkNotNull typ = case typ of
        G.TypeList _ ty -> G.TypeList (G.Nullability False) ty
        G.TypeNamed _ n -> G.TypeNamed (G.Nullability False) n

instance J.FromJSON (FromIntrospection G.InputValueDefinition) where
  parseJSON = J.withObject "InputValueDefinition" $ \o -> do
    name <- o .: "name"
    desc <- o .:? "description"
    _type <- o .: "type"
    defVal <- o .:? "defaultValue"
    let desc' = fmap fromIntrospection desc
    let defVal' = fmap fromIntrospection defVal
        r = G.InputValueDefinition desc' name (fromIntrospection _type) defVal' []
    return $ FromIntrospection r

instance J.FromJSON (FromIntrospection (G.Value Void)) where
  parseJSON = J.withText "Value Void" $ \t ->
    let parseValueConst = G.runParser G.value
     in FromIntrospection <$> onLeft (parseValueConst t) (fail . T.unpack)

instance J.FromJSON (FromIntrospection (G.InterfaceTypeDefinition [G.Name] G.InputValueDefinition)) where
  parseJSON = J.withObject "InterfaceTypeDefinition" $ \o -> do
    kind <- o .: "kind"
    name <- o .: "name"
    desc <- o .:? "description"
    fields <- o .:? "fields"
    possibleTypes :: Maybe [FromIntrospection (G.ObjectTypeDefinition G.InputValueDefinition)] <- o .:? "possibleTypes"
    let flds = maybe [] (fmap fromIntrospection) fields
        desc' = fmap fromIntrospection desc
        possTps = map G._otdName $ maybe [] (fmap fromIntrospection) possibleTypes
    when (kind /= "INTERFACE") $ kindErr kind "interface"
    -- TODO (non PDV) track which interfaces implement which other interfaces, after a
    -- GraphQL spec > Jun 2018 is released.
    let r = G.InterfaceTypeDefinition desc' name [] flds possTps
    return $ FromIntrospection r

instance J.FromJSON (FromIntrospection G.UnionTypeDefinition) where
  parseJSON = J.withObject "UnionTypeDefinition" $ \o -> do
    kind <- o .: "kind"
    name <- o .: "name"
    desc <- o .:? "description"
    possibleTypes :: [FromIntrospection (G.ObjectTypeDefinition G.InputValueDefinition)] <- o .: "possibleTypes"
    let possibleTypes' = map G._otdName $ fmap fromIntrospection possibleTypes
        desc' = fmap fromIntrospection desc
    when (kind /= "UNION") $ kindErr kind "union"
    let r = G.UnionTypeDefinition desc' name [] possibleTypes'
    return $ FromIntrospection r

instance J.FromJSON (FromIntrospection G.EnumTypeDefinition) where
  parseJSON = J.withObject "EnumTypeDefinition" $ \o -> do
    kind <- o .: "kind"
    name <- o .: "name"
    desc <- o .:? "description"
    vals <- o .: "enumValues"
    when (kind /= "ENUM") $ kindErr kind "enum"
    let desc' = fmap fromIntrospection desc
    let r = G.EnumTypeDefinition desc' name [] (fmap fromIntrospection vals)
    return $ FromIntrospection r

instance J.FromJSON (FromIntrospection G.EnumValueDefinition) where
  parseJSON = J.withObject "EnumValueDefinition" $ \o -> do
    name <- o .: "name"
    desc <- o .:? "description"
    let desc' = fmap fromIntrospection desc
    let r = G.EnumValueDefinition desc' name []
    return $ FromIntrospection r

instance J.FromJSON (FromIntrospection (G.InputObjectTypeDefinition G.InputValueDefinition)) where
  parseJSON = J.withObject "InputObjectTypeDefinition" $ \o -> do
    kind <- o .: "kind"
    name <- o .: "name"
    desc <- o .:? "description"
    mInputFields <- o .:? "inputFields"
    let inputFields = maybe [] (fmap fromIntrospection) mInputFields
    let desc' = fmap fromIntrospection desc
    when (kind /= "INPUT_OBJECT") $ kindErr kind "input_object"
    let r = G.InputObjectTypeDefinition desc' name [] inputFields
    return $ FromIntrospection r

instance J.FromJSON (FromIntrospection (G.TypeDefinition [G.Name] G.InputValueDefinition)) where
  parseJSON = J.withObject "TypeDefinition" $ \o -> do
    kind :: Text <- o .: "kind"
    r <- case kind of
      "SCALAR" ->
        G.TypeDefinitionScalar . fromIntrospection <$> J.parseJSON (J.Object o)
      "OBJECT" ->
        G.TypeDefinitionObject . fromIntrospection <$> J.parseJSON (J.Object o)
      "INTERFACE" ->
        G.TypeDefinitionInterface . fromIntrospection <$> J.parseJSON (J.Object o)
      "UNION" ->
        G.TypeDefinitionUnion . fromIntrospection <$> J.parseJSON (J.Object o)
      "ENUM" ->
        G.TypeDefinitionEnum . fromIntrospection <$> J.parseJSON (J.Object o)
      "INPUT_OBJECT" ->
        G.TypeDefinitionInputObject . fromIntrospection <$> J.parseJSON (J.Object o)
      _ -> pErr $ "unknown kind: " <> kind
    return $ FromIntrospection r

instance J.FromJSON (FromIntrospection IntrospectionResult) where
  parseJSON = J.withObject "SchemaDocument" $ \o -> do
    _data <- o .: "data"
    schema <- _data .: "__schema"
    -- the list of types
    types <- schema .: "types"
    -- query root
    queryType <- schema .: "queryType"
    queryRoot <- queryType .: "name"
    -- mutation root
    mMutationType <- schema .:? "mutationType"
    mutationRoot <- case mMutationType of
      Nothing -> return Nothing
      Just mutType -> do
        mutRoot <- mutType .: "name"
        return $ Just mutRoot
    -- subscription root
    mSubsType <- schema .:? "subscriptionType"
    subsRoot <- case mSubsType of
      Nothing -> return Nothing
      Just subsType -> do
        subRoot <- subsType .: "name"
        return $ Just subRoot
    let types' =
          (fmap . fmap . fmap)
            -- presets are only defined for non-admin roles,
            -- an admin will not have any presets
            -- defined and the admin will be the one,
            -- who'll be adding the remote schema,
            -- hence presets are set to `Nothing`
            (`RemoteSchemaInputValueDefinition` Nothing)
            types
        r =
          IntrospectionResult
            (RemoteSchemaIntrospection (fmap fromIntrospection types'))
            queryRoot
            mutationRoot
            subsRoot
    return $ FromIntrospection r

objectWithoutNullValues :: [J.Pair] -> J.Value
objectWithoutNullValues = J.object . filter notNull
  where
    notNull (_, J.Null) = False
    notNull _ = True

toObjectTypeDefinition :: G.Name -> G.ObjectTypeDefinition G.InputValueDefinition
toObjectTypeDefinition name = G.ObjectTypeDefinition Nothing name [] [] []

execRemoteGQ ::
  ( MonadIO m,
    MonadError QErr m,
    Tracing.MonadTrace m
  ) =>
  Env.Environment ->
  HTTP.Manager ->
  UserInfo ->
  [HTTP.Header] ->
  ValidatedRemoteSchemaDef ->
  GQLReqOutgoing ->
  -- | Returns the response body and headers, along with the time taken for the
  -- HTTP request to complete
  m (DiffTime, [HTTP.Header], BL.ByteString)
execRemoteGQ env manager userInfo reqHdrs rsdef gqlReq@GQLReq {..} = do
  let gqlReqUnparsed = renderGQLReqOutgoing gqlReq

  when (G._todType _grQuery == G.OperationTypeSubscription) $
    throwRemoteSchema "subscription to remote server is not supported"
  confHdrs <- makeHeadersFromConf env hdrConf
  let clientHdrs = bool [] (mkClientHeadersForward reqHdrs) fwdClientHdrs
      -- filter out duplicate headers
      -- priority: conf headers > resolved userinfo vars > client headers
      hdrMaps =
        [ Map.fromList confHdrs,
          Map.fromList userInfoToHdrs,
          Map.fromList clientHdrs
        ]
      headers = Map.toList $ foldr Map.union Map.empty hdrMaps
      finalHeaders = addDefaultHeaders headers
  initReq <- onLeft (HTTP.mkRequestEither $ tshow url) (throwRemoteSchemaHttp url)
  let req =
        initReq & set HTTP.method "POST"
          & set HTTP.headers finalHeaders
          & set HTTP.body (Just $ J.encode gqlReqUnparsed)
          & set HTTP.timeout (HTTP.responseTimeoutMicro (timeout * 1000000))

  Tracing.tracedHttpRequest req \req' -> do
    (time, res) <- withElapsedTime $ liftIO $ try $ HTTP.performRequest req' manager
    resp <- onLeft res (throwRemoteSchemaHttp url)
    pure (time, mkSetCookieHeaders resp, resp ^. Wreq.responseBody)
  where
    ValidatedRemoteSchemaDef url hdrConf fwdClientHdrs timeout _mPrefix = rsdef

    userInfoToHdrs = sessionVariablesToHeaders $ _uiSession userInfo

identityCustomizer :: RemoteSchemaCustomizer
identityCustomizer = RemoteSchemaCustomizer Nothing mempty mempty mempty mempty

typeDefinitionName :: G.TypeDefinition a b -> G.Name
typeDefinitionName = \case
  G.TypeDefinitionScalar G.ScalarTypeDefinition {..} -> _stdName
  G.TypeDefinitionObject G.ObjectTypeDefinition {..} -> _otdName
  G.TypeDefinitionInterface G.InterfaceTypeDefinition {..} -> _itdName
  G.TypeDefinitionUnion G.UnionTypeDefinition {..} -> _utdName
  G.TypeDefinitionEnum G.EnumTypeDefinition {..} -> _etdName
  G.TypeDefinitionInputObject G.InputObjectTypeDefinition {..} -> _iotdName

getCustomizer :: IntrospectionResult -> Maybe RemoteSchemaCustomization -> RemoteSchemaCustomizer
getCustomizer _ Nothing = identityCustomizer
getCustomizer IntrospectionResult {..} (Just RemoteSchemaCustomization {..}) = RemoteSchemaCustomizer {..}
  where
    mapMap f = Map.fromList . map f . Map.toList
    invertMap = mapMap swap -- key collisions are checked for later in validateSchemaCustomizations
    rootTypeNames =
      if isNothing _rscRootFieldsNamespace
        then catMaybes [Just irQueryRoot, irMutationRoot, irSubscriptionRoot]
        else []
    -- root type names should not be prefixed or suffixed unless
    -- there is a custom root namespace field
    scalarTypeNames = [intScalar, floatScalar, stringScalar, boolScalar, idScalar]
    protectedTypeNames = scalarTypeNames ++ rootTypeNames
    nameFilter name = not $ "__" `T.isPrefixOf` G.unName name || name `elem` protectedTypeNames

    mkPrefixSuffixMap :: Maybe G.Name -> Maybe G.Name -> [G.Name] -> HashMap G.Name G.Name
    mkPrefixSuffixMap mPrefix mSuffix names = Map.fromList $ case (mPrefix, mSuffix) of
      (Nothing, Nothing) -> []
      (Just prefix, Nothing) -> map (\name -> (name, prefix <> name)) names
      (Nothing, Just suffix) -> map (\name -> (name, name <> suffix)) names
      (Just prefix, Just suffix) -> map (\name -> (name, prefix <> name <> suffix)) names

    RemoteSchemaIntrospection typeDefinitions = irDoc
    typesToRename = filter nameFilter $ typeDefinitionName <$> typeDefinitions
    typeRenameMap =
      case _rscTypeNames of
        Nothing -> Map.empty
        Just RemoteTypeCustomization {..} ->
          _rtcMapping <> mkPrefixSuffixMap _rtcPrefix _rtcSuffix typesToRename

    typeFieldMap :: HashMap G.Name [G.Name] -- typeName -> fieldNames
    typeFieldMap =
      Map.fromList $
        typeDefinitions >>= \case
          G.TypeDefinitionObject G.ObjectTypeDefinition {..} -> pure (_otdName, G._fldName <$> _otdFieldsDefinition)
          G.TypeDefinitionInterface G.InterfaceTypeDefinition {..} -> pure (_itdName, G._fldName <$> _itdFieldsDefinition)
          _ -> []

    mkFieldRenameMap RemoteFieldCustomization {..} fieldNames =
      _rfcMapping <> mkPrefixSuffixMap _rfcPrefix _rfcSuffix fieldNames

    fieldRenameMap =
      case _rscFieldNames of
        Nothing -> Map.empty
        Just fieldNameCustomizations ->
          let customizationMap = Map.fromList $ map (\rfc -> (_rfcParentType rfc, rfc)) fieldNameCustomizations
           in Map.intersectionWith mkFieldRenameMap customizationMap typeFieldMap

    mapLookup :: (Eq a, Hashable a) => HashMap a a -> a -> a
    mapLookup m a = fromMaybe a $ Map.lookup a m

    _rscNamespaceFieldName = _rscRootFieldsNamespace
    _rscCustomizeTypeName = typeRenameMap
    _rscCustomizeFieldName = fieldRenameMap
    _rscDecustomizeTypeName = invertMap typeRenameMap
    _rscDecustomizeFieldName = mapMap (mapLookup typeRenameMap *** invertMap) fieldRenameMap

throwRemoteSchema ::
  QErrM m =>
  Text ->
  m a
throwRemoteSchema = throw400 RemoteSchemaError

throwRemoteSchemaWithInternal ::
  (QErrM m, J.ToJSON a) =>
  Text ->
  a ->
  m b
throwRemoteSchemaWithInternal msg v =
  let err = err400 RemoteSchemaError msg
   in throwError err {qeInternal = Just $ ExtraInternal $ J.toJSON v}

throwRemoteSchemaHttp ::
  QErrM m =>
  URI ->
  HTTP.HttpException ->
  m a
throwRemoteSchemaHttp url =
  throwRemoteSchemaWithInternal (T.pack httpExceptMsg) . httpExceptToJSON
  where
    httpExceptMsg =
      "HTTP exception occurred while sending the request to " <> show url
