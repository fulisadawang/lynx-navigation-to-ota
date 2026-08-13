/**
 * HarmonyOS Telemetry 的本地模型。
 *
 * 字段与 Wire Schema 3.0.0 对齐；本阶段只在进程内交给 Noop/Debug Sink，
 * 不实现网络上传或磁盘队列。绝对 bundlePath 只能由加载器使用，禁止进入模型。
 */
export enum TelemetryBundleSource {
  OTA = 'ota',
  DIRECT_HTTPS = 'direct_https',
  ASSETS = 'assets',
  LOCAL_FILE = 'local_file'
}

export enum TelemetryPageState {
  ALLOCATED = 'allocated',
  REGISTERED = 'registered',
  VISIBLE = 'visible',
  HIDDEN = 'hidden',
  DESTROYED = 'destroyed'
}

export enum TelemetryAppState {
  FOREGROUND = 'foreground',
  BACKGROUND = 'background'
}

export enum TelemetryTransitionTerminal {
  COMPLETED = 'completed',
  DEGRADED = 'degraded',
  CANCELLED = 'cancelled',
  FAILED = 'failed',
  NOT_APPLICABLE = 'notApplicable'
}

/** ArkTS 动态字段统一使用显式 Record；页面字段不能覆盖 Native 字段。 */
export type TelemetryAttributes = Record<string, Object>;

export interface TelemetryIdentity {
  navigationId: string;
  navigationSessionId: string;
  entryId: string;
  pageViewId: string;
  renderAttemptId: string;
  activationId?: string;
  transactionId?: string;
}

/** prepare() 前冻结的候选 Release。 */
export interface AttemptedBundleSnapshot {
  kind: string;
  bundleSource: TelemetryBundleSource;
  lynxAppId?: string;
  bundleName: string;
  telemetryRouteKey: string;
  otaOperationId?: string;
  candidateReleaseId?: string;
  expectedSha256?: string;
  prepareStartedAtUnixMs: number;
  attemptGeneration: number;
}

/** prepare 校验成功后冻结的 Release；internalLocalPath 仅在进程内存在。 */
export interface ResolvedBundleSnapshot {
  kind: string;
  bundleSource: TelemetryBundleSource;
  lynxAppId?: string;
  bundleName: string;
  telemetryRouteKey: string;
  releaseId?: string;
  bundleSha256?: string;
  engineVersion?: string;
  localGeneration?: string;
  rollbackFromReleaseId?: string;
  resolvedAtUnixMs: number;
  internalLocalPath?: string;
}

export interface TelemetryEvent {
  schemaVersion: string;
  eventId: string;
  eventName: string;
  category: string;
  source: string;
  occurredAtUnixMs: number;
  monotonicOffsetMs: number;
  sequenceNo: number;
  navigationId?: string;
  navigationSessionId?: string;
  pageViewId?: string;
  entryId?: string;
  renderAttemptId?: string;
  activationId?: string;
  transactionId?: string;
  runtimeKind: string;
  runtimeInstanceId: string;
  telemetryRouteKey: string;
  hostMode: string;
  platform: string;
  hostApp: string;
  appVersion: string;
  buildNumber: string;
  lynxSdkVersion: string;
  engineVersion: string;
  lifecycle?: TelemetryLifecycleSnapshot;
  navigationAdmission?: TelemetryNavigationSnapshot;
  transition?: TelemetryTransitionSnapshot;
  privacy: TelemetryPrivacySnapshot;
  attemptedBundleSnapshot?: AttemptedBundleSnapshot;
  resolvedBundleSnapshot?: ResolvedBundleSnapshot;
  sampleRate: number;
  samplingGroup: string;
  samplingRuleVersion: string;
  analysisEligible: boolean;
  deliveryOwner: string;
  attributes: TelemetryAttributes;
}

/** 共享 Wire Schema 的嵌套状态对象；页面状态不能代替 App 前后台状态。 */
export interface TelemetryLifecycleSnapshot {
  pageState: TelemetryPageState;
  appState: TelemetryAppState;
  attemptState: string;
  activeEligible: boolean;
  reason?: string;
}

export interface TelemetryNavigationSnapshot {
  state: string;
  rejectionCode?: string;
}

export interface TelemetryTransitionSnapshot {
  state: string;
  terminal?: TelemetryTransitionTerminal;
  durationMs?: number;
}

export interface TelemetryPrivacySnapshot {
  consentState: string;
  subjectRefPresent: boolean;
  optOut: boolean;
}

/** 一个页面的逻辑身份、两个正交状态和当前 Snapshot。 */
export class TelemetryPageHandle {
  readonly pageViewId: string;
  identity: TelemetryIdentity;
  attemptedBundle: AttemptedBundleSnapshot;
  resolvedBundle?: ResolvedBundleSnapshot;
  pageState: TelemetryPageState = TelemetryPageState.ALLOCATED;
  appState: TelemetryAppState = TelemetryAppState.FOREGROUND;
  pageOpenReported: boolean = false;
  sequenceNo: number = 0;
  attemptGeneration: number;
  activeStartedAtMonotonic?: number;

  constructor(identity: TelemetryIdentity, attemptedBundle: AttemptedBundleSnapshot) {
    this.pageViewId = identity.pageViewId;
    this.identity = identity;
    this.attemptedBundle = attemptedBundle;
    this.attemptGeneration = attemptedBundle.attemptGeneration;
  }

  /** 重试/回滚保留 pageViewId，但必须生成新的 renderAttemptId。 */
  beginRenderAttempt(attemptedBundle: AttemptedBundleSnapshot, transactionId?: string): void {
    this.attemptGeneration = Math.max(this.attemptGeneration + 1, attemptedBundle.attemptGeneration);
    this.identity = {
      navigationId: this.identity.navigationId,
      navigationSessionId: this.identity.navigationSessionId,
      entryId: this.identity.entryId,
      pageViewId: this.identity.pageViewId,
      renderAttemptId: `attempt_${Date.now()}_${this.attemptGeneration}`,
      activationId: this.identity.activationId,
      transactionId: transactionId ?? this.identity.transactionId
    };
    this.attemptedBundle = attemptedBundle;
    this.resolvedBundle = undefined;
    this.pageOpenReported = false;
  }
}
