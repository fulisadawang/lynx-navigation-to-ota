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
  monitorTruncate,
  monitorTruncateUtf8,
  monitorUtf8Bytes,
  monitorJsonBytes
} from '../monitoring/MonitorUtils';

export class ShellLynxLoadFailure {
  code: number; subCode: number; fatal: boolean; level: string; message: string;
  constructor(error: LynxError) {
    this.code = Number(error.getErrorCode()); this.subCode = Number(error.getSubCode());
    this.fatal = error.isFatal(); this.level = String(error.getLevel()).toLowerCase(); this.message = error.getSummaryMessage();
  }
  requiresErrorState(): boolean {
    if (this.level === 'warn' || this.level === 'warning') return false;
    if (this.code === 301 || (this.code >= 30000 && this.code <= 39999) || (this.subCode >= 30000 && this.subCode <= 39999)) return false;
    return this.fatal || this.code === 102 || (this.code >= 10201 && this.code <= 10299) || (this.subCode >= 10201 && this.subCode <= 10299);
  }
}

/**
 * LynxView 生命周期回调适配器。
 * 页面只关心 loading/error/success，日志和性能事件在这里集中处理。
 */
export default class ShellLynxViewClient extends LynxViewClient {
  private readonly onSuccessCallback: (url: string) => void;
  private readonly onErrorCallback: (failure: ShellLynxLoadFailure) => void;
  private readonly onFirstScreenCallback: () => void;
  private readonly monitor: ViewMonitorBinding;
  private readonly onContextCallback: ((context: LynxContext) => void) | null;
  private monitorContext: LynxContext | null = null;
  private hasFirstContent: boolean = false;
  private errorMissingFields: string[] = [];
  private errorTruncatedFields: string[] = [];

  constructor(
    onSuccess: (url: string) => void,
    onError: (failure: ShellLynxLoadFailure) => void,
    onFirstScreen: () => void,
    containerKind: 'page' | 'tab',
    onContext: ((context: LynxContext) => void) | null = null
  ) {
    super();
    this.onContextCallback = onContext;
    this.onSuccessCallback = onSuccess;
    this.onErrorCallback = onError;
    this.onFirstScreenCallback = onFirstScreen;
    this.monitor = LynxMonitor.shared().bindView(containerKind);
  }

  bindContext(context: LynxContext, entryID: string): void {
    if (this.monitorContext !== null && this.monitorContext !== context) {
      LynxMonitor.shared().unbindContext(this.monitorContext);
      this.monitor.contextReplaced();
    }
    this.monitorContext = context;
    LynxMonitor.shared().bindContext(context, entryID, this.monitor);
  }

  setBundleIdentity(bundle: BundleIdentity): void {
    this.monitor.setBundle(bundle);
  }

  get monitoringEnabled(): boolean {
    return LynxMonitor.shared().enabled;
  }

  setPreparedBundle(source: string, lynxAppId: string, bundleName: string,
    releaseId: string, releaseSequence: string | null, sha256: string,
    env: string | null = null, hostApp: string | null = null, bundlePath: string | null = null): void {
    this.setBundleIdentity(monitorBundleIdentity(source, lynxAppId, bundleName, releaseId, releaseSequence, sha256, env, hostApp, bundlePath));
  }

  setDirectBundle(bundleUrl: string, sha256: string | null): void {
    if (sha256 === null) { this.markBundleUnavailable('direct_bundle_hash_failed', bundleUrl); return; }
    const bundleName = bundleUrl.trim().split('?')[0].split('#')[0].split('/').pop() ?? '';
    this.setBundleIdentity(new BundleIdentityValue(
      bundleUrl.trim().toLowerCase().startsWith('https://') ? 'direct_https' : 'direct_asset',
      null, bundleName.length === 0 ? null : monitorTruncate(bundleName, 256), null, null, sha256,
      'computed', null, null));
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
    if (this.monitorContext !== null) {
      LynxMonitor.shared().unbindContext(this.monitorContext);
      this.monitorContext = null;
    }
    this.monitor.destroyed(reasonCode);
  }

  markLoadResolved(durationMs: number | null): void {
    this.monitor.loadResolved(durationMs);
  }

  markLoadFailed(reasonCode: string): void {
    this.monitor.loadFailed(reasonCode);
  }

  override onPageStarted(lynxContext: LynxContext, pipelineInfo: LynxPipelineInfo): void {
    this.onContextCallback?.(lynxContext);
    this.monitor.pageStarted();
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
    const failure = new ShellLynxLoadFailure(error);
    const message = failure.message;
    LLog.e(ShellConstants.TAG, `onReceivedError: ${message}`);
    if (!LynxMonitor.shared().enabled) {
      this.onErrorCallback(failure);
      return;
    }
    const jsPayload = this.toJsErrorPayload(error);
    if (jsPayload === null) {
      this.monitor.diagnostic('unclassified_lynx_error', monitorTruncate(this.plainErrorMessage(message) ?? '', 4096));
    } else {
      this.monitor.jsError(jsPayload, this.errorMissingFields, this.errorTruncatedFields);
    }
    this.onErrorCallback(failure);
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
    this.errorMissingFields = [];
    this.errorTruncatedFields = [];
    // 4.1 getMsg() 的顶层含 customInfo，原始脚本错误可能在 rawError/error 的 JSON 字符串里。
    const sdkMessage = error.getMsg() ?? '';
    const parsedError = this.errorObject(sdkMessage, 'sdkError');
    const rawError = this.errorObject(parsedError?.['rawError'], 'sdkError.rawError');
    const summary = this.errorObject(parsedError?.['error'], 'sdkError.error');
    const details = rawError ?? summary ?? parsedError;
    const sentry = this.errorObject(details?.['sentry'] ?? parsedError?.['sentry'], 'sdkError.sentry');
    const classification = details === null ? '' :
      `${String(details['type'] ?? '')} ${String(details['errorType'] ?? '')} ` +
      `${String(details['source'] ?? '')} ${String(details['realm'] ?? '')}`.toLowerCase().trim();
    const code = Number(error.getErrorCode());
    const subCode = Number(error.getSubCode());
    const backgroundCode = code === 201 || code === 203 ||
      (subCode >= 20100 && subCode <= 20199) || subCode === 20301;
    const mainThreadCode = code === 1101 || code === 1111 || code === 1901 ||
      subCode === 110100 || subCode === 111101 || subCode === 111102 || subCode === 190100;
    const sdkType = error.getType();
    const isJavaScriptError = sdkType === LynxError.JS_ERROR || backgroundCode || mainThreadCode ||
      classification.indexOf('javascript') >= 0 || classification.indexOf('background') >= 0 ||
      classification.indexOf('main_thread') >= 0 || classification === 'js';
    if (!isJavaScriptError) return null;

    const messageValue = this.errorString(details?.['message']) ?? this.plainErrorMessage(details?.['error']) ??
      this.plainErrorMessage(error.getSummaryMessage());
    if (messageValue === null || messageValue.length === 0) this.errorMissingFields.push('payload.message');
    const message = messageValue === null ? '' : this.errorText(messageValue, 4096, 'payload.message');
    const stackValue = this.errorString(details?.['error_stack']) ?? this.errorString(details?.['stack']) ??
      this.errorString(parsedError?.['error_stack']) ?? this.errorString(parsedError?.['stack']);
    const rawStack = stackValue === null ? null : this.errorText(stackValue, 16 * 1024, 'payload.rawStack');
    const release = this.errorString(sentry?.['release']) ?? this.errorString(details?.['release']) ??
      this.errorString(parsedError?.['release']);
    const debugKey = release === null ? null : monitorDebugKey(release, true);
    const frames = this.framesFromError(details, sentry, rawStack, debugKey);
    if (frames.length === 0) this.errorMissingFields.push('payload.frames');
    if (rawStack === null) this.errorMissingFields.push('payload.rawStack');
    if (frames.some((frame: ErrorFrame) => frame.debugKey === null)) this.errorMissingFields.push('payload.frames.debugKey');
    if (frames.some((frame: ErrorFrame) => frame.positionKind === 'unknown')) this.errorMissingFields.push('payload.frames.position');
    const levelText = String(error.getLevel()).toLowerCase();
    const level: 'fatal' | 'error' | 'warning' | 'unknown' = error.isFatal() ? 'fatal' :
      levelText.indexOf('warn') >= 0 ? 'warning' : levelText.indexOf('error') >= 0 ? 'error' : 'unknown';
    const realm: 'background' | 'main_thread' | 'unknown' = mainThreadCode || classification.indexOf('main_thread') >= 0
      ? 'main_thread' : backgroundCode || classification.indexOf('background') >= 0 || sdkType === LynxError.JS_ERROR
        ? 'background' : 'unknown';
    return new JsErrorPayloadValue(String(code), String(subCode), level, realm, message, rawStack,
      frames, 'reported', this.hasFirstContent ? 'running' : 'loading');
  }

  private errorObject(value: Object | undefined, field: string): Record<string, Object> | null {
    if (typeof value === 'string') {
      if (monitorUtf8Bytes(value) > 64 * 1024) { this.errorTruncated(field); return null; }
      try {
        const parsed = JSON.parse(value) as Object;
        return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)
          ? parsed as Record<string, Object> : null;
      } catch (_error) {
        // SDK 同一字段可以是普通字符串；未解析的内容只作为文本，不制造结构化字段。
        return null;
      }
    }
    return typeof value === 'object' && value !== null && !Array.isArray(value)
      ? value as Record<string, Object> : null;
  }

  private errorString(value: Object | undefined): string | null {
    return typeof value === 'string' ? value : null;
  }

  private plainErrorMessage(value: Object | undefined): string | null {
    if (typeof value !== 'string') return null;
    const text = value.trim();
    // 结构化摘要解析失败或超预算时，不把 JSON 片段（可能包含凭据/源码）当消息交给 Provider。
    return text.startsWith('{') || text.startsWith('[') ? null : value;
  }

  private errorText(value: string, maximumBytes: number, field: string): string {
    const sanitized = monitorSanitize(value);
    const bounded = monitorTruncateUtf8(sanitized, maximumBytes);
    if (bounded.length !== sanitized.length) this.errorTruncated(field);
    return bounded;
  }

  private errorTruncated(field: string): void {
    if (!this.errorTruncatedFields.includes(field)) this.errorTruncatedFields.push(field);
  }

  private errorPosition(value: Object | undefined): number | null {
    if (typeof value !== 'number' && !(typeof value === 'string' && /^[0-9]+$/.test(value))) return null;
    const numberValue = Number(value);
    return Number.isSafeInteger(numberValue) && numberValue >= 0 ? numberValue : null;
  }

  private framesFromError(details: Record<string, Object> | null, sentry: Record<string, Object> | null,
    rawStack: string | null, fallbackKey: string | null): ErrorFrame[] {
    const frames: ErrorFrame[] = [];
    const exception = this.errorObject(sentry?.['exception'], 'sdkError.sentry.exception');
    const values = exception?.['values'];
    if (Array.isArray(values)) {
      // Sentry 的每个 exception 有独立帧；按 SDK 原顺序保留，统一限制到 64 帧。
      for (let index = 0; index < values.length && index < 64; index += 1) {
        const value = this.errorObject(values[index] as Object, 'sdkError.sentry.exception.values');
        const stack = this.errorObject(value?.['stacktrace'], 'sdkError.sentry.stacktrace');
        this.appendStructuredFrames(stack?.['frames'], frames, fallbackKey);
      }
      if (values.length > 64) this.errorTruncated('payload.frames');
    }
    if (frames.length === 0) this.appendStructuredFrames(details?.['frames'], frames, fallbackKey);
    if (frames.length === 0 && rawStack !== null) {
      const lines = rawStack.split('\n');
      for (const stackLine of lines) {
        const match = /(?:at\s+)?(?:(.*?)\s+\()?([^()\s]+):(\d+):(\d+)\)?/.exec(stackLine);
        if (match === null) continue;
        const first = this.errorPosition(match[3]);
        const second = this.errorPosition(match[4]);
        if (first === null || second === null) continue;
        const reportedKey = monitorDebugKey(stackLine);
        const key = stackLine.toLowerCase().indexOf('debugmetadata:') >= 0 ? reportedKey : fallbackKey;
        const frame = new ErrorFrameValue(this.errorText(match[2], 2048, 'payload.frames.file'),
          match[1]?.length > 0 ? this.errorText(match[1], 2048, 'payload.frames.functionName') : null,
          key === null ? null : `debugmetadata:${key}`, key, 'reported', null, null, null, null, first, second);
        if (!this.appendErrorFrame(frame, frames)) break;
      }
    }
    return frames;
  }

  private appendStructuredFrames(value: Object | undefined, frames: ErrorFrame[], fallbackKey: string | null): void {
    if (!Array.isArray(value)) return;
    for (let index = 0; index < value.length; index += 1) {
      if (frames.length >= 64) { this.errorTruncated('payload.frames'); return; }
      const item = this.errorObject(value[index] as Object, 'sdkError.frames');
      if (item === null) continue;
      const functionId = this.errorPosition(item['functionId']);
      const pc = this.errorPosition(item['pc']);
      const first = this.errorPosition(item['lineno'] ?? item['line']);
      const second = this.errorPosition(item['colno'] ?? item['column']);
      const explicitBytecode = functionId !== null && pc !== null;
      const hasRelease = item['release'] !== undefined || item['runtimeRelease'] !== undefined;
      const releaseValue = item['release'] !== undefined ? item['release'] : item['runtimeRelease'];
      const release = this.errorString(releaseValue);
      const encodedKey = release === null ? null : monitorDebugKey(release, true);
      const hasDebugKey = item['debugKey'] !== undefined;
      const itemKey = this.errorString(item['debugKey']);
      const rawKeyMatch = itemKey === null ? null : new RegExp('^[A-Za-z0-9._/-]+$').exec(itemKey);
      const explicitKey = itemKey === null ? null : monitorDebugKey(itemKey, true) ??
        (rawKeyMatch !== null && rawKeyMatch[0].length === itemKey.length && monitorUtf8Bytes(itemKey) <= 2048 ? itemKey : null);
      // 帧明确给出但不合法的 key 不能被顶层 release 掩盖，否则可能反解到另一个脚本。
      const invalidKey = (hasRelease && encodedKey === null) || (hasDebugKey && explicitKey === null);
      const debugKey = invalidKey ? null : hasRelease || hasDebugKey ? encodedKey ?? explicitKey : fallbackKey;
      const file = this.errorString(item['filename']) ?? this.errorString(item['file']);
      const functionName = this.errorString(item['function']) ?? this.errorString(item['functionName']);
      const frame = new ErrorFrameValue(file === null ? null : this.errorText(file, 2048, 'payload.frames.file'),
        functionName === null ? null : this.errorText(functionName, 2048, 'payload.frames.functionName'),
        debugKey === null ? null : `debugmetadata:${debugKey}`, debugKey,
        explicitBytecode ? 'function_pc' : first !== null && second !== null ? 'reported' : 'unknown',
        null, null, explicitBytecode ? functionId : null, explicitBytecode ? pc : null,
        explicitBytecode ? null : first, explicitBytecode ? null : second);
      if (!this.appendErrorFrame(frame, frames)) return;
    }
  }

  private appendErrorFrame(frame: ErrorFrame, frames: ErrorFrame[]): boolean {
    // 原始堆栈另有 16 KiB；帧摘要只占 8 KiB，给身份和事件封套保留总预算空间。
    if (frames.length >= 64 || monitorJsonBytes(frames) + monitorJsonBytes(frame) > 8 * 1024) {
      this.errorTruncated('payload.frames');
      return false;
    }
    frames.push(frame);
    return true;
  }
}
