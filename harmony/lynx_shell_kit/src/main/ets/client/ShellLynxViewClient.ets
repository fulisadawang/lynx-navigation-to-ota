import {
  LLog,
  LynxContext,
  LynxError,
  LynxPipelineInfo,
  LynxViewClient,
  LynxResourceLoadInfo,
  PerformanceEntry,
  TemplateBundle
} from '@lynx/lynx';
import ShellConstants from '../common/ShellConstants';
import LynxMonitor, { ViewMonitorBinding } from '../monitoring/LynxMonitor';
import {
  BundleIdentity,
  BundleIdentityValue,
  ErrorFrame,
  ErrorFrameValue,
  JsErrorPayload,
  JsErrorPayloadValue,
  MonitorMetric,
  MonitorMetricValue,
  PerformancePayload,
  PerformancePayloadValue,
  ResourcePayload,
  ResourcePayloadValue
} from '../monitoring/MonitorTypes';
import {
  finiteNumber,
  monitorBundleIdentity,
  monitorDebugKey,
  monitorSanitize,
  monitorTruncate
} from '../monitoring/MonitorUtils';

/**
 * LynxView 生命周期回调适配器。
 * 页面只关心 loading/error/success，日志和性能事件在这里集中处理。
 */
export default class ShellLynxViewClient extends LynxViewClient {
  private readonly onSuccessCallback: (url: string) => void;
  private readonly onErrorCallback: (message: string) => void;
  private readonly onFirstScreenCallback: () => void;
  private readonly monitor: ViewMonitorBinding;
  private hasFirstContent: boolean = false;

  constructor(
    onSuccess: (url: string) => void,
    onError: (message: string) => void,
    onFirstScreen: () => void,
    containerKind: 'page' | 'tab'
  ) {
    super();
    this.onSuccessCallback = onSuccess;
    this.onErrorCallback = onError;
    this.onFirstScreenCallback = onFirstScreen;
    this.monitor = LynxMonitor.shared().bindView(containerKind);
  }

  setBundleIdentity(bundle: BundleIdentity): void {
    this.monitor.setBundle(bundle);
  }

  setPreparedBundle(source: string, lynxAppId: string, bundleName: string,
    releaseId: string, releaseSequence: string | null, sha256: string): void {
    this.setBundleIdentity(monitorBundleIdentity(source, lynxAppId, bundleName, releaseId, releaseSequence, sha256));
  }

  markBundleUnavailable(reason: string, bundleUrl: string = ''): void {
    const bundleName = bundleUrl.trim().split('?')[0].split('#')[0].split('/').pop() ?? '';
    this.setBundleIdentity(new BundleIdentityValue(
      bundleUrl.trim().toLowerCase().startsWith('https://') ? 'direct_https' : 'direct_asset',
      null, bundleName.length === 0 ? null : monitorTruncate(bundleName, 256), null, null, null,
      'unavailable', reason, null));
  }

  setLoadKind(kind: 'initial' | 'retry' | 'reload'): void {
    this.monitor.setLoadKind(kind);
  }

  markLoadStarted(): void {
    this.monitor.startLoad();
  }

  markCreated(): void {
    this.monitor.created(null, null);
  }

  markVisible(): void {
    this.monitor.visible();
  }

  markHidden(): void {
    this.monitor.hidden();
  }

  markBackground(): void {
    this.monitor.background();
  }

  markDestroyed(reasonCode: string): void {
    this.monitor.destroyed(reasonCode);
  }

  markLoadResolved(durationMs: number | null): void {
    this.monitor.loadResolved(durationMs);
  }

  markLoadFailed(reasonCode: string): void {
    this.monitor.loadFailed(reasonCode);
  }

  override onPageStarted(lynxContext: LynxContext, pipelineInfo: LynxPipelineInfo): void {
    LLog.d(ShellConstants.TAG, `onPageStarted: ${pipelineInfo}`);
  }

  override onLoadSuccess(url: string): void {
    LLog.d(ShellConstants.TAG, `onLoadSuccess: ${url}`);
    this.monitor.loadSuccess();
    this.onSuccessCallback(url);
  }

  override onFirstScreen(): void {
    LLog.d(ShellConstants.TAG, 'onFirstScreen');
    if (!this.hasFirstContent) {
      this.hasFirstContent = true;
      this.monitor.firstContent();
    }
    this.onFirstScreenCallback();
  }

  override onReceivedError(error: LynxError): void {
    const message = error.getMsg();
    LLog.e(ShellConstants.TAG, `onReceivedError: ${message}`);
    if (!LynxMonitor.shared().enabled) {
      this.onErrorCallback(message ?? '');
      return;
    }
    const jsPayload = this.toJsErrorPayload(error);
    if (jsPayload === null) {
      this.monitor.diagnostic('unclassified_lynx_error', monitorTruncate(message ?? '', 4096));
    } else {
      this.monitor.jsError(jsPayload);
    }
    this.onErrorCallback(message ?? '');
  }

  override onTemplateBundleReady(bundle: TemplateBundle): void {
    LLog.d(ShellConstants.TAG, 'onTemplateBundleReady');
  }

  override onPerformanceEvent(entry: PerformanceEntry): void {
    if (!LynxMonitor.shared().enabled) return;
    const payload = this.toPerformancePayload(entry);
    LLog.d(ShellConstants.TAG, `onPerformanceEvent: ${JSON.stringify(payload)}`);
    this.monitor.performance(payload);
  }

  override onResourceLoaded(info: LynxResourceLoadInfo): void {
    if (!LynxMonitor.shared().enabled) return;
    const errorCode = Number(info.errCode);
    const payload: ResourcePayload = new ResourcePayloadValue(
      String(info.type),
      errorCode === 0 ? 'success' : 'failed',
      null,
      errorCode === 0 ? null : String(errorCode),
      null
    );
    this.monitor.resource(payload);
  }

  private toPerformancePayload(entry: PerformanceEntry): PerformancePayload {
    const raw = entry.toRecord() as Record<string, Object>;
    const metrics: MonitorMetric[] = [];
    this.appendMetric(raw, 'lynxFcp', 'lynx_fcp_ms', metrics);
    this.appendMetric(raw, 'fcp', 'prepare_to_fcp_ms', metrics);
    this.appendMetric(raw, 'totalFcp', 'open_to_fcp_ms', metrics);
    this.appendMetric(raw, 'pipeline', 'pipeline_ms', metrics);
    const timing: Record<string, number> = {};
    [
      'loadBundleStart', 'loadBundleEnd', 'parseStart', 'parseEnd', 'loadBackgroundStart', 'loadBackgroundEnd',
      'pipelineStart', 'pipelineEnd', 'mtsRenderStart', 'mtsRenderEnd', 'resolveStart', 'resolveEnd',
      'layoutStart', 'layoutEnd', 'paintingUiOperationExecuteStart', 'paintingUiOperationExecuteEnd',
      'layoutUiOperationExecuteStart', 'layoutUiOperationExecuteEnd', 'paintEnd', 'loadCoreStart', 'loadCoreEnd',
      'openTime', 'containerInitStart', 'containerInitEnd', 'prepareTemplateStart', 'prepareTemplateEnd',
      'createLynxStart', 'createLynxEnd'
    ].forEach((name: string) => {
      const value = finiteNumber(raw[name]);
      if (value !== null) timing[name] = value;
    });
    const differences: Array<[string, string, string]> = [
      ['parse_ms', 'parseStart', 'parseEnd'],
      ['bts_load_ms', 'loadBackgroundStart', 'loadBackgroundEnd'],
      ['mts_render_ms', 'mtsRenderStart', 'mtsRenderEnd'],
      ['style_resolve_ms', 'resolveStart', 'resolveEnd'],
      ['layout_ms', 'layoutStart', 'layoutEnd'],
      ['paint_ui_ops_ms', 'paintingUiOperationExecuteStart', 'paintingUiOperationExecuteEnd'],
      ['pipeline_ms', 'pipelineStart', 'pipelineEnd']
    ];
    differences.forEach((item: [string, string, string]) => {
      const start = finiteNumber(raw[item[1]]);
      const end = finiteNumber(raw[item[2]]);
      if (start !== null && end !== null && end >= start) {
        metrics.push(new MonitorMetricValue(
          item[0] as 'parse_ms' | 'bts_load_ms' | 'mts_render_ms' | 'style_resolve_ms' |
            'layout_ms' | 'paint_ui_ops_ms' | 'pipeline_ms',
          end - start, 'ms', 'sdk_timestamp_difference', [item[1], item[2]]));
      }
    });
    const identifier = typeof raw['identifier'] === 'string' ? String(raw['identifier']) : null;
    return new PerformancePayloadValue(entry.entryType, entry.name, identifier, metrics, timing);
  }

  private appendMetric(
    raw: Record<string, Object>, sourceName: string,
    metricName: 'lynx_fcp_ms' | 'prepare_to_fcp_ms' | 'open_to_fcp_ms' | 'pipeline_ms',
    metrics: MonitorMetric[]
  ): void {
    const metric = this.metric(raw, sourceName, metricName);
    if (metric !== null) metrics.push(metric);
  }

  private metric(
    raw: Record<string, Object>,
    sourceName: string,
    metricName: 'lynx_fcp_ms' | 'prepare_to_fcp_ms' | 'open_to_fcp_ms' | 'pipeline_ms'
  ): MonitorMetric | null {
    const value = raw[sourceName];
    if (value === undefined) return null;
    const duration = typeof value === 'number' ? finiteNumber(value) : finiteNumber((value as Record<string, Object>)['duration']);
    if (duration === null) return null;
    return new MonitorMetricValue(metricName, duration, 'ms', 'sdk_duration', [sourceName]);
  }

  private toJsErrorPayload(error: LynxError): JsErrorPayload | null {
    const raw = error.getMsg() ?? '';
    let message = monitorTruncate(raw, 4096);
    let parsedError: Record<string, Object> | null = null;
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      parsedError = parsed;
      if (typeof parsed['error'] === 'string') message = monitorTruncate(String(parsed['error']), 4096);
      else if (typeof parsed['message'] === 'string') message = monitorTruncate(String(parsed['message']), 4096);
    } catch (_error) {
      // LynxError 的消息不是 JSON 时保留原始字符串，不能凭空制造堆栈。
    }
    const classification = parsedError === null ? '' :
      `${String(parsedError['type'] ?? '')} ${String(parsedError['errorType'] ?? '')} ` +
      `${String(parsedError['source'] ?? '')} ${String(parsedError['realm'] ?? '')}`.toLowerCase();
    const sdkType = error.getType();
    const isJavaScriptError = sdkType === LynxError.JS_ERROR ||
      classification.indexOf('js') >= 0 || classification.indexOf('javascript') >= 0 ||
      classification.indexOf('background') >= 0 || classification.indexOf('main_thread') >= 0;
    if (!isJavaScriptError) {
      return null;
    }
    const errorCodeValue = error.getErrorCode();
    const subCodeValue = error.getSubCode();
    const levelText = String(error.getLevel()).toLowerCase();
    const level: 'fatal' | 'error' | 'warning' | 'unknown' = levelText.indexOf('fatal') >= 0 ? 'fatal' :
      levelText.indexOf('warn') >= 0 ? 'warning' :
      levelText.indexOf('error') >= 0 ? 'error' : 'unknown';
    const rawStack = parsedError !== null && typeof parsedError['error_stack'] === 'string'
      ? monitorTruncate(String(parsedError['error_stack']), 16 * 1024) :
      parsedError !== null && typeof parsedError['stack'] === 'string'
        ? monitorTruncate(String(parsedError['stack']), 16 * 1024) : null;
    message = monitorSanitize(message);
    const sanitizedStack = rawStack === null ? null : monitorSanitize(rawStack);
    const runtimeRelease = parsedError !== null && typeof parsedError['release'] === 'string'
      ? monitorDebugKey(String(parsedError['release'])) : null;
    const realm: 'background' | 'main_thread' | 'unknown' = classification.indexOf('background') >= 0 ? 'background' :
      classification.indexOf('main_thread') >= 0 || (sanitizedStack !== null && sanitizedStack.indexOf('main-thread.js') >= 0)
        ? 'main_thread' : sdkType === LynxError.JS_ERROR ? 'background' : 'unknown';
    const frame: ErrorFrame[] = this.framesFromError(parsedError, sanitizedStack, runtimeRelease, realm);
    return new JsErrorPayloadValue(
      errorCodeValue === undefined || errorCodeValue === null ? null : String(errorCodeValue),
      subCodeValue === undefined || subCodeValue === null ? null : String(subCodeValue),
      level, realm, message, sanitizedStack, frame, 'reported', this.hasFirstContent ? 'running' : 'loading');
  }

  private framesFromError(
    parsedError: Record<string, Object> | null,
    rawStack: string | null,
    runtimeRelease: string | null,
    realm: 'background' | 'main_thread' | 'unknown'
  ): ErrorFrame[] {
    const frames: ErrorFrame[] = [];
    const rawFrames = parsedError?.['frames'];
    if (Array.isArray(rawFrames)) {
      rawFrames.forEach((value: Object) => {
        const item = value as Record<string, Object>;
        const functionId = finiteNumber(item['functionId']);
        const pc = finiteNumber(item['pc']);
        const line = finiteNumber(item['line']);
        const column = finiteNumber(item['column']);
        const positionKind: 'line_column' | 'function_pc' | 'unknown' =
          functionId !== null && pc !== null ? 'function_pc' :
          line !== null && column !== null ? 'line_column' : 'unknown';
        const itemRelease = typeof item['runtimeRelease'] === 'string'
          ? monitorDebugKey(String(item['runtimeRelease'])) : null;
        const itemDebugKey = typeof item['debugKey'] === 'string'
          ? monitorDebugKey(String(item['debugKey'])) : null;
        const debugKey = itemDebugKey ?? itemRelease ?? runtimeRelease;
        frames.push(new ErrorFrameValue(
          typeof item['file'] === 'string' ? monitorTruncate(monitorSanitize(String(item['file'])), 2048) : null,
          typeof item['functionName'] === 'string' ? monitorTruncate(monitorSanitize(String(item['functionName'])), 2048) : null,
          debugKey === null ? null : monitorTruncate(`debugmetadata:${debugKey}`, 2048),
          debugKey === null ? null : monitorTruncate(debugKey, 2048),
          realm === 'main_thread' && positionKind === 'line_column' ? 'unknown' : positionKind,
          realm === 'main_thread' || positionKind !== 'line_column' ? null : line,
          realm === 'main_thread' || positionKind !== 'line_column' ? null : column,
          positionKind === 'function_pc' ? functionId : null,
          positionKind === 'function_pc' ? pc : null));
      });
      return frames;
    }
    if (rawStack !== null) {
      rawStack.split('\n').forEach((stackLine: string) => {
        if (frames.length >= 64) return;
        const atIndex = stackLine.indexOf('at ');
        if (atIndex < 0) return;
        const location = stackLine.substring(atIndex + 3).replace('(', '').replace(')', '').trim();
        const lastColon = location.lastIndexOf(':');
        const secondLastColon = lastColon < 0 ? -1 : location.lastIndexOf(':', lastColon - 1);
        if (secondLastColon < 0) return;
        const line = Number(location.substring(secondLastColon + 1, lastColon));
        const column = Number(location.substring(lastColon + 1));
        if (!Number.isInteger(line) || !Number.isInteger(column) || line < 1 || column < 0) return;
        const file = location.substring(0, secondLastColon).trim();
        const functionName = stackLine.substring(atIndex + 3, stackLine.indexOf('(') < 0 ? stackLine.length : stackLine.indexOf('(')).trim();
        const positionKind: 'line_column' | 'unknown' = file.indexOf('main-thread.js') >= 0 ? 'unknown' : 'line_column';
        const debugKey = monitorDebugKey(stackLine) ?? runtimeRelease;
        frames.push(new ErrorFrameValue(
          monitorTruncate(monitorSanitize(file), 2048), functionName.length > 0 ? monitorTruncate(monitorSanitize(functionName), 2048) : null,
          debugKey === null ? null : `debugmetadata:${monitorTruncate(debugKey, 2048)}`,
          debugKey === null ? null : monitorTruncate(debugKey, 2048), positionKind,
          positionKind === 'line_column' ? line : null,
          positionKind === 'line_column' ? column : null, null, null));
      });
    }
    return frames;
  }
}
