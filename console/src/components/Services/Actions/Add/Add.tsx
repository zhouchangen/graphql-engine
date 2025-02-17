import React, { useEffect, useReducer } from 'react';
import { GraphQLError } from 'graphql';
import { connect, ConnectedProps } from 'react-redux';
import Helmet from 'react-helmet';
import { Tooltip } from 'react-bootstrap';
import requestAction from '@/utils/requestAction';
import {
  parseValidateApiData,
  getValidateTransformOptions,
} from '@/components/Common/ConfigureTransformation/utils';
import Endpoints from '@/Endpoints';
import {
  getActionRequestTransformDefaultState,
  requestTransformReducer,
  setRequestMethod,
  setRequestUrl,
  setRequestUrlError,
  setRequestUrlPreview,
  setRequestQueryParams,
  setRequestAddHeaders,
  setRequestBody,
  setRequestBodyError,
  setRequestSampleInput,
  setRequestTransformedBody,
  setRequestContentType,
  setRequestUrlTransform,
  setRequestPayloadTransform,
} from '@/components/Common/ConfigureTransformation/requestTransformState';
import {
  RequestTransformContentType,
  RequestTransformMethod,
} from '@/metadata/types';
import { KeyValuePair } from '@/components/Common/ConfigureTransformation/stateDefaults';
import ConfigureTransformation from '@/components/Common/ConfigureTransformation/ConfigureTransformation';
import ActionEditor from '../Common/components/ActionEditor';
import Button from '../../../Common/Button';
import { createAction } from '../ServerIO';
import { getActionDefinitionFromSdl } from '../../../../shared/utils/sdlUtils';
import { showWarningNotification } from '../../Common/Notification';
import {
  setActionHandler,
  setActionExecution,
  setDefaults,
  setActionDefinition,
  setTypeDefinition,
  setHeaders as dispatchNewHeaders,
  toggleForwardClientHeaders as toggleFCH,
  resetDerivedActionParentOperation,
  setActionTimeout,
  setActionComment,
} from './reducer';
import { getActionRequestSampleInput } from './utils';
import { Header, ActionExecution } from '../Common/stateDefaults';
import { Nullable } from '../../../Common/utils/tsUtils';
import { ReduxState } from '../../../../types';
import { mapDispatchToPropsEmpty } from '../../../Common/utils/reactUtils';
import styles from '../../../Common/Common.scss';

interface AddActionProps extends InjectedProps {}

const AddAction: React.FC<AddActionProps> = ({
  handler,
  dispatch,
  execution,
  actionDefinition,
  typeDefinition,
  isFetching,
  headers,
  forwardClientHeaders,
  derive,
  readOnlyMode,
  timeout,
  comment,
}) => {
  const [transformState, transformDispatch] = useReducer(
    requestTransformReducer,
    getActionRequestTransformDefaultState()
  );

  useEffect(() => {
    if (readOnlyMode)
      dispatch(
        showWarningNotification(
          'Failed to add action',
          'Adding new action is not allowed in Read only mode!'
        )
      );
  }, [dispatch, readOnlyMode]);
  useEffect(() => {
    if (!derive.operation) {
      dispatch(setDefaults());
    }
    return () => {
      dispatch(resetDerivedActionParentOperation());
    };
  }, []);

  const handlerOnChange = (val: string) => dispatch(setActionHandler(val));
  const executionOnChange = (k: ActionExecution) =>
    dispatch(setActionExecution(k));
  const timeoutOnChange = (e: React.ChangeEvent<HTMLInputElement>) =>
    dispatch(setActionTimeout(e.target.value));
  const commentOnChange = (e: React.ChangeEvent<HTMLInputElement>) =>
    dispatch(setActionComment(e.target.value));
  const {
    sdl: typeDefinitionSdl,
    error: typesDefinitionError,
    timer: typedefParseTimer,
  } = typeDefinition;

  const {
    sdl: actionDefinitionSdl,
    error: actionDefinitionError,
    timer: actionParseTimer,
  } = actionDefinition;

  const onSubmit = () => {
    dispatch(createAction(transformState));
  };

  const setHeaders = (hs: Header[]) => {
    dispatch(dispatchNewHeaders(hs));
  };

  const toggleForwardClientHeaders = () => {
    dispatch(toggleFCH());
  };

  const actionDefinitionOnChange = (
    value: Nullable<string>,
    error: Nullable<GraphQLError>,
    timer: Nullable<NodeJS.Timeout>,
    ast: Nullable<Record<string, any>>
  ) => {
    dispatch(setActionDefinition(value as string, error, timer, ast));
  };

  const typeDefinitionOnChange = (
    value: Nullable<string>,
    error: Nullable<GraphQLError>,
    timer: Nullable<NodeJS.Timeout>,
    ast: Nullable<Record<string, any>>
  ) => {
    dispatch(setTypeDefinition(value as string, error, timer, ast));
  };

  // request transform methods
  const resetSampleInput = () => {
    if (!actionDefinitionError && !typesDefinitionError) {
      const value = getActionRequestSampleInput(
        actionDefinitionSdl,
        typeDefinitionSdl
      );
      transformDispatch(setRequestSampleInput(value));
    }
  };

  const requestMethodOnChange = (requestMethod: RequestTransformMethod) => {
    transformDispatch(setRequestMethod(requestMethod));
  };

  const requestUrlOnChange = (requestUrl: string) => {
    transformDispatch(setRequestUrl(requestUrl));
  };

  const requestUrlErrorOnChange = (requestUrlError: string) => {
    transformDispatch(setRequestUrlError(requestUrlError));
  };

  const requestUrlPreviewOnChange = (requestUrlPreview: string) => {
    transformDispatch(setRequestUrlPreview(requestUrlPreview));
  };

  const requestQueryParamsOnChange = (requestQueryParams: KeyValuePair[]) => {
    transformDispatch(setRequestQueryParams(requestQueryParams));
  };

  const requestAddHeadersOnChange = (requestAddHeaders: KeyValuePair[]) => {
    transformDispatch(setRequestAddHeaders(requestAddHeaders));
  };

  const requestBodyOnChange = (requestBody: string) => {
    transformDispatch(setRequestBody(requestBody));
  };

  const requestBodyErrorOnChange = (requestBodyError: string) => {
    transformDispatch(setRequestBodyError(requestBodyError));
  };

  const requestSampleInputOnChange = (requestSampleInput: string) => {
    transformDispatch(setRequestSampleInput(requestSampleInput));
  };

  const requestTransformedBodyOnChange = (requestTransformedBody: string) => {
    transformDispatch(setRequestTransformedBody(requestTransformedBody));
  };

  const requestContentTypeOnChange = (
    requestContentType: RequestTransformContentType
  ) => {
    transformDispatch(setRequestContentType(requestContentType));
  };

  const requestUrlTransformOnChange = (data: boolean) => {
    transformDispatch(setRequestUrlTransform(data));
  };

  const requestPayloadTransformOnChange = (data: boolean) => {
    transformDispatch(setRequestPayloadTransform(data));
  };

  useEffect(() => {
    const onResponse = (data: Record<string, any>) => {
      parseValidateApiData(
        data,
        requestUrlErrorOnChange,
        requestUrlPreviewOnChange
      );
    };
    const options = getValidateTransformOptions(
      transformState.requestSampleInput,
      handler,
      undefined,
      transformState.requestUrl,
      transformState.requestQueryParams
    );
    if (!handler) {
      requestUrlErrorOnChange(
        'Please configure your webhook handler to generate request url transform'
      );
      requestUrlPreviewOnChange('');
    } else if (!transformState.requestUrl) {
      requestUrlPreviewOnChange('');
    } else {
      requestUrlErrorOnChange('');
      dispatch(
        requestAction(
          Endpoints.metadata,
          options,
          undefined,
          undefined,
          true,
          true
        )
      ).then(onResponse, onResponse); // parseValidateApiData will parse both success and error
    }
  }, [
    transformState.requestSampleInput,
    handler,
    transformState.requestUrl,
    transformState.requestQueryParams,
  ]);

  useEffect(() => {
    const onResponse = (data: Record<string, any>) => {
      parseValidateApiData(
        data,
        requestBodyErrorOnChange,
        undefined,
        requestTransformedBodyOnChange
      );
    };
    const options = getValidateTransformOptions(
      transformState.requestSampleInput,
      handler,
      transformState.requestBody
    );
    if (!transformState.requestBody) {
      requestTransformedBodyOnChange('');
    } else if (transformState.requestBody && handler) {
      requestBodyErrorOnChange('');
      dispatch(
        requestAction(
          Endpoints.metadata,
          options,
          undefined,
          undefined,
          true,
          true
        )
      ).then(onResponse, onResponse); // parseValidateApiData will parse both success and error
    }
  }, [transformState.requestSampleInput, transformState.requestBody]);

  const allowSave =
    !isFetching &&
    !typesDefinitionError &&
    !actionDefinitionError &&
    !actionParseTimer &&
    !typedefParseTimer &&
    !readOnlyMode;

  let actionType = '';
  if (!actionDefinitionError && !actionParseTimer) {
    const { type, error } = getActionDefinitionFromSdl(actionDefinitionSdl);
    if (!error) {
      actionType = type;
    }
  }

  return (
    <div className="w-full overflow-y-auto bg-gray-50">
      <div className="max-w-6xl">
        <Helmet title="Add Action - Actions | Hasura" />
        <h2
          className={`${styles.headerText} ${styles.display_inline} ${styles.add_mar_bottom}`}
        >
          Add a new action
        </h2>

        <ActionEditor
          handler={handler}
          execution={execution}
          actionDefinition={actionDefinition}
          typeDefinition={typeDefinition}
          headers={headers}
          forwardClientHeaders={forwardClientHeaders}
          readOnlyMode={readOnlyMode}
          timeout={timeout}
          comment={comment}
          actionType={actionType}
          commentOnChange={commentOnChange}
          handlerOnChange={handlerOnChange}
          executionOnChange={executionOnChange}
          timeoutOnChange={timeoutOnChange}
          setHeaders={setHeaders}
          toggleForwardClientHeaders={toggleForwardClientHeaders}
          actionDefinitionOnChange={actionDefinitionOnChange}
          typeDefinitionOnChange={typeDefinitionOnChange}
        />

        <ConfigureTransformation
          webhookUrl={handler}
          state={transformState}
          resetSampleInput={resetSampleInput}
          requestMethodOnChange={requestMethodOnChange}
          requestUrlOnChange={requestUrlOnChange}
          requestUrlErrorOnChange={requestUrlErrorOnChange}
          requestQueryParamsOnChange={requestQueryParamsOnChange}
          requestAddHeadersOnChange={requestAddHeadersOnChange}
          requestBodyOnChange={requestBodyOnChange}
          requestBodyErrorOnChange={requestBodyErrorOnChange}
          requestSampleInputOnChange={requestSampleInputOnChange}
          requestContentTypeOnChange={requestContentTypeOnChange}
          requestUrlTransformOnChange={requestUrlTransformOnChange}
          requestPayloadTransformOnChange={requestPayloadTransformOnChange}
        />

        <div>
          <Button
            color="yellow"
            size="sm"
            type="submit"
            disabled={!allowSave}
            onClick={onSubmit}
            data-test="create-action-btn"
          >
            Create Action
          </Button>
          {readOnlyMode && (
            <Tooltip id="tooltip-actions-add-readonlymode">
              Adding new action is not allowed in Read only mode!
            </Tooltip>
          )}
        </div>
      </div>
    </div>
  );
};

const mapStateToProps = (state: ReduxState) => {
  return {
    ...state.actions.add,
    readOnlyMode: state.main.readOnlyMode,
  };
};

const connector = connect(mapStateToProps, mapDispatchToPropsEmpty);

type InjectedProps = ConnectedProps<typeof connector>;

const AddActionConnector = connector(AddAction);

export default AddActionConnector;
