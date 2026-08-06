import {
  LLog,
  LynxContext,
  LynxError,
  LynxPipelineInfo,
  LynxViewClient,
  PerformanceEntry,
  TemplateBundle
} from '@lynx/lynx';
import ShellConstants from '../common/ShellConstants';

/**
 * LynxView 生命周期回调适配器。
 * 页面只关心 loading/error/success，日志和性能事件在这里集中处理。
 */
export default class ShellLynxViewClient extends LynxViewClient {
  private readonly onSuccessCallback: (url: string) => void;
  private readonly onErrorCallback: (message: string) => void;
  private readonly onFirstScreenCallback: () => void;

  constructor(
    onSuccess: (url: string) => void,
    onError: (message: string) => void,
    onFirstScreen: () => void
  ) {
    super();
    this.onSuccessCallback = onSuccess;
    this.onErrorCallback = onError;
    this.onFirstScreenCallback = onFirstScreen;
  }

  override onPageStarted(lynxContext: LynxContext, pipelineInfo: LynxPipelineInfo): void {
    LLog.d(ShellConstants.TAG, `onPageStarted: ${pipelineInfo}`);
  }

  override onLoadSuccess(url: string): void {
    LLog.d(ShellConstants.TAG, `onLoadSuccess: ${url}`);
    this.onSuccessCallback(url);
  }

  override onFirstScreen(): void {
    LLog.d(ShellConstants.TAG, 'onFirstScreen');
    this.onFirstScreenCallback();
  }

  override onReceivedError(error: LynxError): void {
    const message = error.getMsg();
    LLog.e(ShellConstants.TAG, `onReceivedError: ${message}`);
    this.onErrorCallback(message ?? '');
  }

  override onTemplateBundleReady(bundle: TemplateBundle): void {
    LLog.d(ShellConstants.TAG, 'onTemplateBundleReady');
  }

  override onPerformanceEvent(entry: PerformanceEntry): void {
    LLog.d(ShellConstants.TAG, `onPerformanceEvent: ${entry.toRecord()}`);
  }
}
