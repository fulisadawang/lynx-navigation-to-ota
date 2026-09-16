import {
  BundleIdentity,
  ContainerKind,
  EventEnvelope,
  EventEnvelopeValue,
  EventQuality,
  EventQualityValue,
  EventSampling,
  EventSamplingValue,
  HostContext,
  InitResult,
  JsErrorPayload,
  LifecyclePayload,
  LoadKind,
  LoadPayload,
  MonitorConfig,
  MonitorEvent,
  PerformancePayload,
  ResourcePayload,
  DiagnosticPayload,
  DiagnosticPayloadValue,
  FailedInitResultValue,
  ReadyInitResultValue,
  LifecyclePayloadValue,
  LoadPayloadValue,
  MonitorEventValue,
  RuntimeProvider
} from './MonitorTypes';
import { monitorId, monitorJsonBytes } from './MonitorUtils';
import { LynxEnv } from '@lynx/lynx';

const MAX_QUEUE_EVENTS: number = 128;
const MAX_QUEUE_BYTES: number = 512 * 1024;
const MAX_EVENT_BYTES: number = 32 * 1024;
const INITIALIZATION_TIMEOUT_MS: number = 10 * 1000;

/** 进程级监控核心；不持有 ArkUI Page，Provider 调用不会进入 Lynx 回调同步链路。 */
export default class LynxMonitor {
  private static singleton: LynxMonitor | null = null;
  private readonly processSessionId: string = monitorId('process');
  private provider: RuntimeProvider | null = null;
  private config: MonitorConfig | null = null;
  private hostContext: HostContext | null = null;
  private state: 'idle' | 'initializing' | 'ready' | 'failed' | 'closed' = 'idle';
  private ready: boolean = false;
  private closed: boolean = false;
  private readonly pending: MonitorEvent[] = [];
  private pendingBytes: number = 0;
  private drainScheduled: boolean = false;
  private providerDisposed: boolean = false;
  private readonly diagnostics: Map<string, number> = new Map<string, number>();

  static shared(): LynxMonitor {
    if (LynxMonitor.singleton === null) LynxMonitor.singleton = new LynxMonitor();
    return LynxMonitor.singleton;
  }

  static install(config: MonitorConfig, context: HostContext): Promise<InitResult> {
    return LynxMonitor.shared().install(config, context);
  }

  private constructor() {
  }

  get sessionId(): string {
    return this.processSessionId;
  }

  get runtimeVersion(): string {
    return LynxEnv.getLynxVersion();
  }

  get performanceSampleRate(): number {
    return this.config?.performanceSampleRate ?? 1;
  }

  get enabled(): boolean {
    return !this.closed && (this.state === 'initializing' || this.state === 'ready') &&
      this.config?.enabled === true && this.provider !== null;
  }

  async install(config: MonitorConfig, context: HostContext): Promise<InitResult> {
    if (this.config !== null) {
      if (this.config.enabled === config.enabled &&
        this.config.performanceSampleRate === config.performanceSampleRate && this.provider === config.provider) {
        return this.state === 'ready' ? new ReadyInitResultValue() :
          new FailedInitResultValue(this.state === 'initializing' ? 'already_initializing' : 'already_initialized');
      }
      return new FailedInitResultValue('already_initialized');
    }
    if (!config.enabled) return new FailedInitResultValue('disabled');
    if (!Number.isFinite(config.performanceSampleRate) || config.performanceSampleRate < 0 || config.performanceSampleRate > 1) {
      return new FailedInitResultValue('invalid_sample_rate');
    }
    if (config.provider === null) return new FailedInitResultValue('not_configured');
    if (config.provider.capabilities.platform !== 'harmony') {
      return new FailedInitResultValue('provider_platform_mismatch');
    }
    const capabilities = config.provider.capabilities;
    if (!capabilities.perEventBundleContext || !capabilities.rawJsFrames ||
      !capabilities.supportedEvents.includes('lynx.performance') ||
      !capabilities.supportedEvents.includes('lynx.js_error')) {
      return new FailedInitResultValue('incompatible_provider');
    }
    if (config.provider.capabilities.samplingOwner === 'provider' && config.performanceSampleRate !== 1) {
      return new FailedInitResultValue('sampling_conflict');
    }
    this.config = config;
    this.provider = config.provider;
    this.hostContext = context;
    this.state = 'initializing';
    this.providerDisposed = false;
    try {
      // 初始化结果必须有界；迟到的 Provider 不得在超时后复活监控实例。
      const initialization = config.provider.initialize(context).catch((_error: Error): InitResult =>
        new FailedInitResultValue('provider_initialize_threw'));
      const timeout = new Promise<InitResult>((resolve: (result: InitResult) => void) => {
        setTimeout(() => resolve(new FailedInitResultValue('initialization_timeout')), INITIALIZATION_TIMEOUT_MS);
      });
      const result = await Promise.race([initialization, timeout]);
      if (result.state !== 'ready') {
        this.recordDiagnostic('provider_initialization_failed', result.reason);
        this.pending.length = 0;
        this.pendingBytes = 0;
        this.ready = false;
        this.state = 'failed';
        this.disposeProviderOnce();
        return result;
      }
      if (this.closed) {
        this.disposeProviderOnce();
        return new FailedInitResultValue('closed_during_initialization');
      }
      this.ready = true;
      this.state = 'ready';
      this.scheduleDrain();
      return result;
    } catch (_error) {
      this.recordDiagnostic('provider_initialization_failed', 'provider_initialize_threw');
      this.pending.length = 0;
      this.pendingBytes = 0;
      this.ready = false;
      this.state = 'failed';
      this.disposeProviderOnce();
      return new FailedInitResultValue('provider_initialize_threw');
    }
  }

  bindView(containerKind: ContainerKind): ViewMonitorBinding {
    const context = this.hostContext ?? {
      platform: 'harmony',
      hostAppId: 'unknown',
      hostBuild: 'unknown',
      runtimeVersion: 'unknown',
      processSessionId: this.processSessionId
    } as HostContext;
    return new ViewMonitorBinding(
      this,
      monitorId('view'),
      containerKind,
      context.hostBuild,
      context.runtimeVersion,
      context.processSessionId
    );
  }

  record(event: MonitorEvent): void {
    if (!this.enabled) {
      this.incrementDiagnostic(this.state === 'failed' ? 'discarded_initialization' : 'not_configured');
      return;
    }
    this.enqueue(event);
    this.scheduleDrain();
  }

  private deliver(event: MonitorEvent): void {
    if (this.provider === null) return;
    if (!this.provider.capabilities.supportedEvents.includes(event.eventType)) {
      this.incrementDiagnostic('provider_unsupported');
      return;
    }
    try {
      const result = this.provider.record(event);
      if (result.state === 'rejected') this.incrementDiagnostic(`provider_${result.reason}`);
    } catch (_error) {
      this.incrementDiagnostic('provider_error');
    }
  }

  private enqueue(event: MonitorEvent): void {
    const bytes = this.eventBytes(event);
    if (bytes > MAX_EVENT_BYTES) {
      this.incrementDiagnostic('event_too_large');
      return;
    }
    while (this.pending.length >= MAX_QUEUE_EVENTS || this.pendingBytes + bytes > MAX_QUEUE_BYTES) {
      const performanceIndex = this.pending.findIndex((item: MonitorEvent) =>
        item.eventType === 'lynx.performance' || item.eventType === 'lynx.resource');
      const dropped = performanceIndex >= 0
        ? this.pending.splice(performanceIndex, 1)[0]
        : this.pending.shift();
      if (dropped === undefined) break;
      this.pendingBytes -= this.eventBytes(dropped);
      this.incrementDiagnostic(`dropped_${dropped.eventType}`);
    }
    this.pending.push(event);
    this.pendingBytes += bytes;
  }

  /** Lynx 回调只入队；Provider 交付在下一轮事件循环串行执行。 */
  private scheduleDrain(): void {
    if (this.drainScheduled || this.closed || !this.ready || this.pending.length === 0) return;
    this.drainScheduled = true;
    setTimeout(() => {
      this.drainScheduled = false;
      this.drainOne();
    }, 0);
  }

  private drainOne(): void {
    if (this.closed || !this.ready) return;
    const event = this.pending.shift();
    if (event === undefined) return;
    this.pendingBytes -= this.eventBytes(event);
    this.deliver(event);
    this.scheduleDrain();
  }

  private eventBytes(event: MonitorEvent): number {
    return monitorJsonBytes(event);
  }

  private incrementDiagnostic(code: string): void {
    this.diagnostics.set(code, (this.diagnostics.get(code) ?? 0) + 1);
  }

  private recordDiagnostic(code: string, detail: string): void {
    this.incrementDiagnostic(code);
    const payload = new DiagnosticPayloadValue(code, 1, detail);
    const envelope = this.envelope(null, null, 'unknown', null, null, null, 'unknown',
      this.quality('unassigned'), new EventSamplingValue('none', null));
    if (this.provider !== null && this.ready) {
      this.record(new MonitorEventValue(envelope, 'monitor.diagnostic', payload));
    }
  }

  private quality(association: 'exact_load' | 'exact_view' | 'unassigned'): EventQuality {
    return new EventQualityValue(association, false, [], [], []);
  }

  private envelope(viewId: string | null, nativeInstanceId: string | null, containerKind: ContainerKind,
    loadId: string | null, loadKind: LoadKind, bundle: BundleIdentity | null,
    visibility: 'visible' | 'hidden' | 'background' | 'unknown', quality: EventQuality,
    sampling: EventSampling): EventEnvelope {
    return new EventEnvelopeValue('1.0', monitorId('event'), this.processSessionId,
      new Date().getTime(), 'harmony', this.hostContext?.runtimeVersion ?? 'unknown',
      this.hostContext?.hostBuild ?? 'unknown', viewId, nativeInstanceId,
      containerKind, loadId, loadKind, bundle, visibility, quality, sampling);
  }

  snapshot(): MonitorEvent[] {
    return this.provider?.snapshot?.() ?? [];
  }

  snapshotSummary(): string {
    const events = this.snapshot();
    const counts: Map<string, number> = new Map<string, number>();
    events.forEach((event: MonitorEvent) => {
      counts.set(event.eventType, (counts.get(event.eventType) ?? 0) + 1);
    });
    const typeParts: string[] = [];
    counts.forEach((count: number, type: string) => typeParts.push(`${type}=${count}`));
    const types = typeParts.join(',');
    const latestEvent: MonitorEvent | null = events.length === 0 ? null : events[events.length - 1];
    const latest = latestEvent?.eventType ?? 'none';
    const viewId = latestEvent?.viewId?.substring(0, 8) ?? 'none';
    const loadId = latestEvent?.loadId?.substring(0, 8) ?? 'none';
    const bundleName = latestEvent?.bundle?.bundleName ?? 'none';
    const releaseId = latestEvent?.bundle?.releaseId ?? 'none';
    const releaseSequence = latestEvent?.bundle?.releaseSequence ?? 'none';
    const sha = latestEvent?.bundle?.sha256?.substring(0, 12) ?? 'none';
    return `provider=${this.provider?.id ?? 'none'};ready=${this.ready};events=${events.length};` +
      `types=${types || 'none'};latest=${latest};view=${viewId};load=${loadId};` +
      `container=${latestEvent?.containerKind ?? 'none'};bundle=${bundleName};release=${releaseId};` +
      `sequence=${releaseSequence};sha=${sha}`;
  }

  private disposeProviderOnce(): void {
    if (this.provider === null || this.providerDisposed) return;
    this.providerDisposed = true;
    this.provider.dispose();
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.ready = false;
    this.state = 'closed';
    this.drainScheduled = false;
    this.pending.length = 0;
    this.pendingBytes = 0;
    this.disposeProviderOnce();
    this.provider = null;
  }
}

export class ViewMonitorBinding {
  private readonly monitor: LynxMonitor;
  readonly viewId: string;
  readonly containerKind: ContainerKind;
  private readonly hostBuild: string;
  private readonly runtimeVersion: string;
  private readonly processSessionId: string;
  private loadId: string = monitorId('load');
  private loadKind: LoadKind = 'initial';
  private startedLoad: boolean = false;
  private bundle: BundleIdentity | null = null;
  private nativeInstanceId: string | null = null;
  private visibility: 'visible' | 'hidden' | 'background' | 'unknown' = 'unknown';
  private closed: boolean = false;
  private firstContentReached: boolean = false;
  private loadTerminal: boolean = false;
  private ambiguous: boolean = false;

  constructor(monitor: LynxMonitor, viewId: string, containerKind: ContainerKind,
    hostBuild: string, runtimeVersion: string, processSessionId: string) {
    this.monitor = monitor;
    this.viewId = viewId;
    this.containerKind = containerKind;
    this.hostBuild = hostBuild;
    this.runtimeVersion = runtimeVersion;
    this.processSessionId = processSessionId;
  }

  setBundle(bundle: BundleIdentity): void {
    if (!this.closed) this.bundle = bundle;
  }

  setLoadKind(kind: LoadKind): void {
    if (kind !== null) this.loadKind = kind;
  }

  startLoad(): void {
    if (this.startedLoad) this.loadId = monitorId('load');
    this.startedLoad = true;
    this.record('view.load', new LoadPayloadValue('started', null, null), 'none');
  }

  created(nativeInstanceId: string | null, durationMs: number | null): void {
    this.nativeInstanceId = nativeInstanceId;
    this.record('view.lifecycle', new LifecyclePayloadValue('created', durationMs), 'none');
  }

  visible(): void {
    this.visibility = 'visible';
    this.record('view.lifecycle', new LifecyclePayloadValue('visible', null), 'none');
  }

  hidden(): void {
    this.visibility = 'hidden';
    this.record('view.lifecycle', new LifecyclePayloadValue('hidden', null), 'none');
  }

  background(): void {
    this.visibility = 'background';
    this.record('view.lifecycle', new LifecyclePayloadValue('background', null), 'none');
  }

  loadResolved(durationMs: number | null): void {
    this.record('view.load', new LoadPayloadValue('resolved', null, durationMs), 'none');
  }

  loadSuccess(): void {
    this.record('view.load', new LoadPayloadValue('loaded_unconfirmed', null, null), 'none');
  }

  firstContent(): void {
    if (this.closed || this.firstContentReached || this.loadTerminal) return;
    this.firstContentReached = true;
    this.loadTerminal = true;
    this.record('view.load', new LoadPayloadValue('first_content', null, null), 'none');
  }

  loadFailed(reasonCode: string): void {
    if (this.closed || this.loadTerminal) return;
    this.loadTerminal = true;
    this.record('view.load', new LoadPayloadValue('failed', reasonCode, null), 'none');
  }

  cancelled(reasonCode: string): void {
    if (this.closed || this.loadTerminal) return;
    this.loadTerminal = true;
    this.record('view.load', new LoadPayloadValue('cancelled', reasonCode, null), 'none');
  }

  destroyed(reasonCode: string): void {
    if (this.closed) return;
    this.record('view.lifecycle', new LifecyclePayloadValue('destroyed', null), 'none');
    if (!this.loadTerminal) {
      this.cancelled(reasonCode);
    }
    this.closed = true;
  }

  performance(payload: PerformancePayload): void {
    if (this.monitor.performanceSampleRate <= 0) return;
    this.record('lynx.performance', payload, 'performance');
  }

  jsError(payload: JsErrorPayload): void {
    this.record('lynx.js_error', payload, 'error');
  }

  resource(payload: ResourcePayload): void {
    this.record('lynx.resource', payload, 'none');
  }

  diagnostic(code: string, detail: string | null): void {
    this.record('monitor.diagnostic', new DiagnosticPayloadValue(code, 1, detail), 'none');
  }

  private record(eventType: 'view.lifecycle' | 'view.load' | 'lynx.performance' | 'lynx.js_error' |
    'lynx.resource' | 'monitor.diagnostic',
    payload: LifecyclePayload | LoadPayload | PerformancePayload | JsErrorPayload | ResourcePayload | DiagnosticPayload,
    sampleType: 'none' | 'performance' | 'error'): void {
    if (this.closed && eventType !== 'view.lifecycle') return;
    const sampling: EventSampling = sampleType === 'performance'
      ? new EventSamplingValue('core', this.monitor.performanceSampleRate)
      : new EventSamplingValue('none', null);
    const exactLoad = !this.ambiguous && this.bundle !== null;
    const quality = new EventQualityValue(exactLoad ? 'exact_load' : 'exact_view', false,
      this.bundle === null ? ['bundle'] : [], [], []);
    const envelope: EventEnvelope = new EventEnvelopeValue(
      '1.0', monitorId('event'), this.processSessionId, new Date().getTime(), 'harmony',
      this.runtimeVersion, this.hostBuild, this.viewId, this.nativeInstanceId, this.containerKind,
      exactLoad ? this.loadId : null, exactLoad ? this.loadKind : null,
      this.ambiguous ? null : this.bundle, this.visibility, quality, sampling);
    this.monitor.record(new MonitorEventValue(envelope, eventType, payload));
  }
}
