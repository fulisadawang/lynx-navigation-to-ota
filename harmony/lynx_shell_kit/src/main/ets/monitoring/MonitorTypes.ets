/** HarmonyOS 监控事件的只读契约；字段缺失必须保留为 null 或质量状态。 */
export type MonitorPlatform = 'harmony';
export type BundleSource = 'ota' | 'embedded' | 'direct_https' | 'direct_asset';
export type ContainerKind = 'page' | 'tab' | 'embedded' | 'unknown';
export type LoadKind = 'initial' | 'retry' | 'reload' | null;
export type MonitorEventType =
  | 'view.lifecycle'
  | 'view.load'
  | 'lynx.performance'
  | 'lynx.js_error'
  | 'lynx.resource'
  | 'monitor.diagnostic';

export interface BundleIdentity {
  readonly source: BundleSource;
  readonly lynxAppId: string | null;
  readonly bundleName: string | null;
  readonly releaseId: string | null;
  readonly releaseSequence: string | null;
  readonly sha256: string | null;
  readonly identityStatus: 'verified' | 'computed' | 'unavailable';
  readonly missingReason: string | null;
  readonly buildId: string | null;
}

export interface MonitorMetric {
  readonly name: 'lynx_fcp_ms' | 'prepare_to_fcp_ms' | 'open_to_fcp_ms' | 'parse_ms' |
    'bts_load_ms' | 'mts_render_ms' | 'style_resolve_ms' | 'layout_ms' | 'paint_ui_ops_ms' | 'pipeline_ms';
  readonly value: number;
  readonly unit: 'ms';
  readonly origin: 'sdk_duration' | 'sdk_timestamp_difference';
  readonly sourceFields: string[];
}

export interface ErrorFrame {
  readonly file: string | null;
  readonly functionName: string | null;
  readonly runtimeRelease: string | null;
  readonly debugKey: string | null;
  readonly positionKind: 'line_column' | 'function_pc' | 'unknown';
  readonly line: number | null;
  readonly column: number | null;
  readonly functionId: number | null;
  readonly pc: number | null;
}

export interface EventQuality {
  readonly association: 'exact_load' | 'exact_view' | 'unassigned';
  readonly late: boolean;
  readonly missingFields: string[];
  readonly invalidFields: string[];
  readonly truncatedFields: string[];
}

export interface EventSampling {
  readonly owner: 'core' | 'provider' | 'none';
  readonly rate: number | null;
}

export interface EventEnvelope {
  readonly schemaVersion: '1.0';
  readonly eventId: string;
  readonly processSessionId: string;
  readonly observedAtMs: number;
  readonly platform: MonitorPlatform;
  readonly runtimeVersion: string;
  readonly hostBuild: string;
  readonly viewId: string | null;
  readonly nativeInstanceId: string | null;
  readonly containerKind: ContainerKind;
  readonly loadId: string | null;
  readonly loadKind: LoadKind;
  readonly bundle: BundleIdentity | null;
  readonly visibility: 'visible' | 'hidden' | 'background' | 'unknown';
  readonly quality: EventQuality;
  readonly sampling: EventSampling;
}

export interface LifecyclePayload {
  readonly state: 'created' | 'visible' | 'hidden' | 'background' | 'destroyed' | 'create_failed';
  readonly durationMs: number | null;
}

export interface LoadPayload {
  readonly phase: 'started' | 'resolved' | 'loaded_unconfirmed' | 'first_content' | 'failed' | 'cancelled' | 'incomplete';
  readonly reasonCode: string | null;
  readonly durationMs: number | null;
}

export interface PerformancePayload {
  readonly entryType: string;
  readonly entryName: string;
  readonly identifier: string | null;
  readonly metrics: MonitorMetric[];
  readonly timing: Record<string, number>;
}

export interface JsErrorPayload {
  readonly errorCode: string | null;
  readonly subCode: string | null;
  readonly level: 'fatal' | 'error' | 'warning' | 'unknown';
  readonly realm: 'background' | 'main_thread' | 'unknown';
  readonly message: string;
  readonly rawStack: string | null;
  readonly frames: ErrorFrame[];
  readonly handled: 'unhandled' | 'reported' | 'unknown';
  readonly phase: 'loading' | 'running' | 'unknown';
}

export interface ResourcePayload {
  readonly resourceType: string;
  readonly outcome: 'success' | 'failed';
  readonly durationMs: number | null;
  readonly errorCode: string | null;
  readonly resourceKey: string | null;
}

export interface DiagnosticPayload {
  readonly code: string;
  readonly count: number;
  readonly detail: string | null;
}

export interface MonitorEvent extends EventEnvelope {
  readonly eventType: MonitorEventType;
  readonly payload: LifecyclePayload | LoadPayload | PerformancePayload | JsErrorPayload | ResourcePayload | DiagnosticPayload;
}

export interface HostContext {
  readonly platform: MonitorPlatform;
  readonly hostAppId: string;
  readonly hostBuild: string;
  readonly runtimeVersion: string;
  readonly processSessionId: string;
}

export interface ProviderCapabilities {
  readonly platform: MonitorPlatform;
  readonly supportedEvents: MonitorEventType[];
  readonly perEventBundleContext: boolean;
  readonly rawJsFrames: boolean;
  readonly sdkOwnsRetry: boolean;
  readonly flushSupported: boolean;
  readonly samplingOwner: 'core' | 'provider';
  readonly diagnostics: DiagnosticCapabilities;
}

export interface DiagnosticCapabilities {
  readonly instanceMemory: 'supported' | 'probe_required' | 'unsupported';
  readonly cpuUsage: 'supported' | 'probe_required' | 'unsupported';
  readonly longTask: 'supported' | 'probe_required' | 'unsupported';
  readonly fluency: 'supported' | 'probe_required' | 'unsupported';
}

export interface ReadyInitResult { readonly state: 'ready'; }
export interface FailedInitResult { readonly state: 'failed'; readonly reason: string; }
export type InitResult = ReadyInitResult | FailedInitResult;
export interface AcceptedHandoffResult { readonly state: 'accepted_by_sdk' | 'recorded_locally'; }
export interface RejectedHandoffResult {
  readonly state: 'rejected';
  readonly reason: 'unsupported' | 'not_ready' | 'invalid_event' | 'provider_error';
}
export type HandoffResult =
  | AcceptedHandoffResult | RejectedHandoffResult;
export interface FlushResultValue {
  readonly state: 'completed_sdk_flush' | 'unsupported' | 'timed_out' | 'failed';
}
export type FlushResult = FlushResultValue;

export interface RuntimeProvider {
  readonly id: string;
  readonly capabilities: ProviderCapabilities;
  initialize(context: HostContext): Promise<InitResult>;
  record(event: Readonly<MonitorEvent>): HandoffResult;
  flush?(timeoutMs: number): Promise<FlushResult>;
  /** G1 本地验收 Provider 可选导出快照；生产厂商 Provider 不要求暴露原始事件。 */
  snapshot?(): MonitorEvent[];
  dispose(): void;
}

export interface MonitorConfig {
  readonly enabled: boolean;
  readonly provider: RuntimeProvider | null;
  readonly performanceSampleRate: number;
}

export class BundleIdentityValue implements BundleIdentity {
  readonly source: BundleSource;
  readonly lynxAppId: string | null;
  readonly bundleName: string | null;
  readonly releaseId: string | null;
  readonly releaseSequence: string | null;
  readonly sha256: string | null;
  readonly identityStatus: 'verified' | 'computed' | 'unavailable';
  readonly missingReason: string | null;
  readonly buildId: string | null;
  constructor(source: BundleSource, lynxAppId: string | null, bundleName: string | null,
    releaseId: string | null, releaseSequence: string | null, sha256: string | null,
    identityStatus: 'verified' | 'computed' | 'unavailable', missingReason: string | null,
    buildId: string | null) {
    this.source = source;
    this.lynxAppId = lynxAppId;
    this.bundleName = bundleName;
    this.releaseId = releaseId;
    this.releaseSequence = releaseSequence;
    this.sha256 = sha256;
    this.identityStatus = identityStatus;
    this.missingReason = missingReason;
    this.buildId = buildId;
  }
}

export class EventQualityValue implements EventQuality {
  readonly association: 'exact_load' | 'exact_view' | 'unassigned';
  readonly late: boolean;
  readonly missingFields: string[];
  readonly invalidFields: string[];
  readonly truncatedFields: string[];
  constructor(association: 'exact_load' | 'exact_view' | 'unassigned', late: boolean,
    missingFields: string[], invalidFields: string[], truncatedFields: string[]) {
    this.association = association;
    this.late = late;
    this.missingFields = missingFields;
    this.invalidFields = invalidFields;
    this.truncatedFields = truncatedFields;
  }
}

export class EventSamplingValue implements EventSampling {
  readonly owner: 'core' | 'provider' | 'none';
  readonly rate: number | null;
  constructor(owner: 'core' | 'provider' | 'none', rate: number | null) {
    this.owner = owner;
    this.rate = rate;
  }
}

export class EventEnvelopeValue implements EventEnvelope {
  readonly schemaVersion: '1.0';
  readonly eventId: string;
  readonly processSessionId: string;
  readonly observedAtMs: number;
  readonly platform: MonitorPlatform;
  readonly runtimeVersion: string;
  readonly hostBuild: string;
  readonly viewId: string | null;
  readonly nativeInstanceId: string | null;
  readonly containerKind: ContainerKind;
  readonly loadId: string | null;
  readonly loadKind: LoadKind;
  readonly bundle: BundleIdentity | null;
  readonly visibility: 'visible' | 'hidden' | 'background' | 'unknown';
  readonly quality: EventQuality;
  readonly sampling: EventSampling;
  constructor(schemaVersion: '1.0', eventId: string, processSessionId: string, observedAtMs: number,
    platform: MonitorPlatform, runtimeVersion: string, hostBuild: string, viewId: string | null,
    nativeInstanceId: string | null, containerKind: ContainerKind, loadId: string | null,
    loadKind: LoadKind, bundle: BundleIdentity | null,
    visibility: 'visible' | 'hidden' | 'background' | 'unknown',
    quality: EventQuality, sampling: EventSampling) {
    this.schemaVersion = schemaVersion;
    this.eventId = eventId;
    this.processSessionId = processSessionId;
    this.observedAtMs = observedAtMs;
    this.platform = platform;
    this.runtimeVersion = runtimeVersion;
    this.hostBuild = hostBuild;
    this.viewId = viewId;
    this.nativeInstanceId = nativeInstanceId;
    this.containerKind = containerKind;
    this.loadId = loadId;
    this.loadKind = loadKind;
    this.bundle = bundle;
    this.visibility = visibility;
    this.quality = quality;
    this.sampling = sampling;
  }
}

export class LifecyclePayloadValue implements LifecyclePayload {
  readonly state: 'created' | 'visible' | 'hidden' | 'background' | 'destroyed' | 'create_failed';
  readonly durationMs: number | null;
  constructor(state: 'created' | 'visible' | 'hidden' | 'background' | 'destroyed' | 'create_failed',
    durationMs: number | null) {
    this.state = state;
    this.durationMs = durationMs;
  }
}

export class LoadPayloadValue implements LoadPayload {
  readonly phase: 'started' | 'resolved' | 'loaded_unconfirmed' | 'first_content' | 'failed' | 'cancelled' | 'incomplete';
  readonly reasonCode: string | null;
  readonly durationMs: number | null;
  constructor(phase: 'started' | 'resolved' | 'loaded_unconfirmed' | 'first_content' | 'failed' | 'cancelled' | 'incomplete',
    reasonCode: string | null, durationMs: number | null) {
    this.phase = phase;
    this.reasonCode = reasonCode;
    this.durationMs = durationMs;
  }
}

export class DiagnosticPayloadValue implements DiagnosticPayload {
  readonly code: string;
  readonly count: number;
  readonly detail: string | null;
  constructor(code: string, count: number, detail: string | null) {
    this.code = code;
    this.count = count;
    this.detail = detail;
  }
}

export class DiagnosticCapabilitiesValue implements DiagnosticCapabilities {
  readonly instanceMemory: 'supported' | 'probe_required' | 'unsupported';
  readonly cpuUsage: 'supported' | 'probe_required' | 'unsupported';
  readonly longTask: 'supported' | 'probe_required' | 'unsupported';
  readonly fluency: 'supported' | 'probe_required' | 'unsupported';
  constructor(instanceMemory: 'supported' | 'probe_required' | 'unsupported',
    cpuUsage: 'supported' | 'probe_required' | 'unsupported',
    longTask: 'supported' | 'probe_required' | 'unsupported',
    fluency: 'supported' | 'probe_required' | 'unsupported') {
    this.instanceMemory = instanceMemory;
    this.cpuUsage = cpuUsage;
    this.longTask = longTask;
    this.fluency = fluency;
  }
}

export class ProviderCapabilitiesValue implements ProviderCapabilities {
  readonly platform: MonitorPlatform;
  readonly supportedEvents: MonitorEventType[];
  readonly perEventBundleContext: boolean;
  readonly rawJsFrames: boolean;
  readonly sdkOwnsRetry: boolean;
  readonly flushSupported: boolean;
  readonly samplingOwner: 'core' | 'provider';
  readonly diagnostics: DiagnosticCapabilities;
  constructor(platform: MonitorPlatform, supportedEvents: MonitorEventType[],
    perEventBundleContext: boolean, rawJsFrames: boolean, sdkOwnsRetry: boolean,
    flushSupported: boolean, samplingOwner: 'core' | 'provider',
    diagnostics: DiagnosticCapabilities) {
    this.platform = platform;
    this.supportedEvents = supportedEvents;
    this.perEventBundleContext = perEventBundleContext;
    this.rawJsFrames = rawJsFrames;
    this.sdkOwnsRetry = sdkOwnsRetry;
    this.flushSupported = flushSupported;
    this.samplingOwner = samplingOwner;
    this.diagnostics = diagnostics;
  }
}

export class ReadyInitResultValue implements ReadyInitResult {
  readonly state: 'ready' = 'ready';
}

export class FailedInitResultValue implements FailedInitResult {
  readonly state: 'failed' = 'failed';
  readonly reason: string;
  constructor(reason: string) {
    this.reason = reason;
  }
}

export class AcceptedHandoffResultValue implements AcceptedHandoffResult {
  readonly state: 'accepted_by_sdk' | 'recorded_locally';
  constructor(state: 'accepted_by_sdk' | 'recorded_locally') {
    this.state = state;
  }
}

export class RejectedHandoffResultValue implements RejectedHandoffResult {
  readonly state: 'rejected' = 'rejected';
  readonly reason: 'unsupported' | 'not_ready' | 'invalid_event' | 'provider_error';
  constructor(reason: 'unsupported' | 'not_ready' | 'invalid_event' | 'provider_error') {
    this.reason = reason;
  }
}

export class FlushResultValueImpl implements FlushResultValue {
  readonly state: 'completed_sdk_flush' | 'unsupported' | 'timed_out' | 'failed';
  constructor(state: 'completed_sdk_flush' | 'unsupported' | 'timed_out' | 'failed') {
    this.state = state;
  }
}

export class MonitorMetricValue implements MonitorMetric {
  readonly name: 'lynx_fcp_ms' | 'prepare_to_fcp_ms' | 'open_to_fcp_ms' | 'parse_ms' |
    'bts_load_ms' | 'mts_render_ms' | 'style_resolve_ms' | 'layout_ms' | 'paint_ui_ops_ms' | 'pipeline_ms';
  readonly value: number;
  readonly unit: 'ms';
  readonly origin: 'sdk_duration' | 'sdk_timestamp_difference';
  readonly sourceFields: string[];
  constructor(name: 'lynx_fcp_ms' | 'prepare_to_fcp_ms' | 'open_to_fcp_ms' | 'parse_ms' |
    'bts_load_ms' | 'mts_render_ms' | 'style_resolve_ms' | 'layout_ms' | 'paint_ui_ops_ms' | 'pipeline_ms',
    value: number, unit: 'ms', origin: 'sdk_duration' | 'sdk_timestamp_difference', sourceFields: string[]) {
    this.name = name;
    this.value = value;
    this.unit = unit;
    this.origin = origin;
    this.sourceFields = sourceFields;
  }
}

export class ErrorFrameValue implements ErrorFrame {
  readonly file: string | null;
  readonly functionName: string | null;
  readonly runtimeRelease: string | null;
  readonly debugKey: string | null;
  readonly positionKind: 'line_column' | 'function_pc' | 'unknown';
  readonly line: number | null;
  readonly column: number | null;
  readonly functionId: number | null;
  readonly pc: number | null;
  constructor(file: string | null, functionName: string | null, runtimeRelease: string | null,
    debugKey: string | null, positionKind: 'line_column' | 'function_pc' | 'unknown',
    line: number | null, column: number | null, functionId: number | null, pc: number | null) {
    this.file = file;
    this.functionName = functionName;
    this.runtimeRelease = runtimeRelease;
    this.debugKey = debugKey;
    this.positionKind = positionKind;
    this.line = line;
    this.column = column;
    this.functionId = functionId;
    this.pc = pc;
  }
}

export class PerformancePayloadValue implements PerformancePayload {
  readonly entryType: string;
  readonly entryName: string;
  readonly identifier: string | null;
  readonly metrics: MonitorMetric[];
  readonly timing: Record<string, number>;
  constructor(entryType: string, entryName: string, identifier: string | null,
    metrics: MonitorMetric[], timing: Record<string, number>) {
    this.entryType = entryType;
    this.entryName = entryName;
    this.identifier = identifier;
    this.metrics = metrics;
    this.timing = timing;
  }
}

export class ResourcePayloadValue implements ResourcePayload {
  readonly resourceType: string;
  readonly outcome: 'success' | 'failed';
  readonly durationMs: number | null;
  readonly errorCode: string | null;
  readonly resourceKey: string | null;
  constructor(resourceType: string, outcome: 'success' | 'failed', durationMs: number | null,
    errorCode: string | null, resourceKey: string | null) {
    this.resourceType = resourceType;
    this.outcome = outcome;
    this.durationMs = durationMs;
    this.errorCode = errorCode;
    this.resourceKey = resourceKey;
  }
}

export class JsErrorPayloadValue implements JsErrorPayload {
  readonly errorCode: string | null;
  readonly subCode: string | null;
  readonly level: 'fatal' | 'error' | 'warning' | 'unknown';
  readonly realm: 'background' | 'main_thread' | 'unknown';
  readonly message: string;
  readonly rawStack: string | null;
  readonly frames: ErrorFrame[];
  readonly handled: 'unhandled' | 'reported' | 'unknown';
  readonly phase: 'loading' | 'running' | 'unknown';
  constructor(errorCode: string | null, subCode: string | null,
    level: 'fatal' | 'error' | 'warning' | 'unknown', realm: 'background' | 'main_thread' | 'unknown',
    message: string, rawStack: string | null, frames: ErrorFrame[],
    handled: 'unhandled' | 'reported' | 'unknown', phase: 'loading' | 'running' | 'unknown') {
    this.errorCode = errorCode;
    this.subCode = subCode;
    this.level = level;
    this.realm = realm;
    this.message = message;
    this.rawStack = rawStack;
    this.frames = frames;
    this.handled = handled;
    this.phase = phase;
  }
}

export class MonitorEventValue implements MonitorEvent {
  readonly schemaVersion: '1.0';
  readonly eventId: string;
  readonly processSessionId: string;
  readonly observedAtMs: number;
  readonly platform: MonitorPlatform;
  readonly runtimeVersion: string;
  readonly hostBuild: string;
  readonly viewId: string | null;
  readonly nativeInstanceId: string | null;
  readonly containerKind: ContainerKind;
  readonly loadId: string | null;
  readonly loadKind: LoadKind;
  readonly bundle: BundleIdentity | null;
  readonly visibility: 'visible' | 'hidden' | 'background' | 'unknown';
  readonly quality: EventQuality;
  readonly sampling: EventSampling;
  readonly eventType: MonitorEventType;
  readonly payload: LifecyclePayload | LoadPayload | PerformancePayload | JsErrorPayload | ResourcePayload | DiagnosticPayload;

  constructor(envelope: EventEnvelope, eventType: MonitorEventType,
    payload: LifecyclePayload | LoadPayload | PerformancePayload | JsErrorPayload | ResourcePayload | DiagnosticPayload) {
    this.schemaVersion = envelope.schemaVersion;
    this.eventId = envelope.eventId;
    this.processSessionId = envelope.processSessionId;
    this.observedAtMs = envelope.observedAtMs;
    this.platform = envelope.platform;
    this.runtimeVersion = envelope.runtimeVersion;
    this.hostBuild = envelope.hostBuild;
    this.viewId = envelope.viewId;
    this.nativeInstanceId = envelope.nativeInstanceId;
    this.containerKind = envelope.containerKind;
    this.loadId = envelope.loadId;
    this.loadKind = envelope.loadKind;
    this.bundle = envelope.bundle;
    this.visibility = envelope.visibility;
    this.quality = envelope.quality;
    this.sampling = envelope.sampling;
    this.eventType = eventType;
    this.payload = payload;
  }
}
