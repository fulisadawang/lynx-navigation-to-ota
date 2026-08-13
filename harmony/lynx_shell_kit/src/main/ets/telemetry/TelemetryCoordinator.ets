import {
  AttemptedBundleSnapshot,
  ResolvedBundleSnapshot,
  TelemetryAppState,
  TelemetryAttributes,
  TelemetryBundleSource,
  TelemetryEvent,
  TelemetryIdentity,
  TelemetryPageHandle,
  TelemetryPageState,
  TelemetryTransitionTerminal,
  TelemetryLifecycleSnapshot,
  TelemetryNavigationSnapshot,
  TelemetryTransitionSnapshot,
  TelemetryPrivacySnapshot
} from './TelemetryModels';

/** Noop/Debug Sink 均为本地同步旁路；Sink 错误不得反向影响页面。 */
export interface TelemetrySink {
  record(event: TelemetryEvent): void;
}

export class NoopTelemetrySink implements TelemetrySink {
  record(_event: TelemetryEvent): void {
  }
}

/** 仅用于开发与 fixture，使用有界数组避免长期占用内存。 */
export class DebugTelemetrySink implements TelemetrySink {
  private events: TelemetryEvent[] = [];
  private readonly maxEvents: number;

  constructor(maxEvents: number = 500) {
    this.maxEvents = Math.max(1, maxEvents);
  }

  record(event: TelemetryEvent): void {
    this.events.push(event);
    while (this.events.length > this.maxEvents) {
      this.events.shift();
    }
  }

  snapshot(): TelemetryEvent[] {
    return this.events.slice();
  }
}

export interface TelemetryConfig {
  platform?: string;
  hostMode?: string;
  hostApp?: string;
  appVersion?: string;
  buildNumber?: string;
  lynxSdkVersion?: string;
  engineVersion?: string;
  runtimeKind?: string;
  sampleRate?: number;
  samplingGroup?: string;
  samplingRuleVersion?: string;
  sink?: TelemetrySink;
}

/**
 * HarmonyOS Phase 1 Alpha 协调器。
 * ArkUI Page、LynxViewClient 和 Router 只提交事实；这里统一生成 Wire 事件。
 * 不接 Lynx Performance 未确认 ABI，不联网、不落盘，所有路径均 fail-open。
 */
export default class TelemetryCoordinator {
  private readonly platform: string;
  private readonly hostMode: string;
  private readonly hostApp: string;
  private readonly appVersion: string;
  private readonly buildNumber: string;
  private readonly lynxSdkVersion: string;
  private readonly engineVersion: string;
  private readonly runtimeKind: string;
  private readonly sampleRate: number;
  private readonly samplingGroup: string;
  private readonly samplingRuleVersion: string;
  private readonly sink: TelemetrySink;
  private readonly processStartMillis: number = Date.now();
  private appState: TelemetryAppState = TelemetryAppState.FOREGROUND;
  private readonly pagesById: Map<string, TelemetryPageHandle> = new Map();

  constructor(config: TelemetryConfig = {}) {
    this.platform = config.platform ?? 'harmony';
    this.hostMode = config.hostMode ?? 'arkui_page';
    this.hostApp = config.hostApp ?? 'unknown';
    this.appVersion = config.appVersion ?? 'unknown';
    this.buildNumber = config.buildNumber ?? 'unknown';
    this.lynxSdkVersion = config.lynxSdkVersion ?? 'unknown';
    this.engineVersion = config.engineVersion ?? 'unknown';
    this.runtimeKind = config.runtimeKind ?? 'lynx_view';
    this.sampleRate = Math.min(1, Math.max(0, config.sampleRate ?? 1));
    this.samplingGroup = config.samplingGroup ?? 'page_quality';
    this.samplingRuleVersion = config.samplingRuleVersion ?? 'v1';
    this.sink = config.sink ?? new NoopTelemetrySink();
  }

  /** Router 已受理与页面身份创建分离；rejected 不构造 pageView。 */
  recordNavigationAdmission(
    navigationId: string,
    accepted: boolean,
    identity?: TelemetryIdentity,
    reason?: string
  ): void {
    const handle = identity === undefined ? undefined : this.pagesById.get(identity.pageViewId);
    const attributes: TelemetryAttributes = {};
    if (reason !== undefined) {
      attributes.reason = this.safeString(reason) as Object;
    }
    this.emit(
      accepted ? 'lynx.navigation.accepted' : 'lynx.navigation.rejected',
      'router',
      'native',
      handle,
      identity,
      attributes
    );
  }

  startPage(identity: TelemetryIdentity, attemptedBundle: AttemptedBundleSnapshot): TelemetryPageHandle {
    const handle = new TelemetryPageHandle(identity, attemptedBundle);
    handle.pageState = TelemetryPageState.REGISTERED;
    this.pagesById.set(handle.pageViewId, handle);
    this.emit('lynx.page.identity_created', 'page', 'native', handle);
    return handle;
  }

  /** prepare 完成后冻结 Resolved Snapshot；current 的绝对路径不进入事件队列。 */
  resolve(pageViewId: string, snapshot: ResolvedBundleSnapshot, renderAttemptId?: string, generation?: number): boolean {
    const handle = this.pagesById.get(pageViewId);
    if (handle === undefined || !this.isCurrent(handle, renderAttemptId, generation)) {
      return this.dropStaleCallback(pageViewId, renderAttemptId, generation);
    }
    handle.resolvedBundle = snapshot;
    this.emit('ota.verify', 'ota', 'native', handle);
    return true;
  }

  markTransitionTerminal(pageViewId: string, status: TelemetryTransitionTerminal, durationMs?: number, reason?: string): void {
    const handle = this.pagesById.get(pageViewId);
    if (handle === undefined) {
      return;
    }
    const attributes: TelemetryAttributes = { status: status as Object };
    if (durationMs !== undefined) {
      attributes.durationMs = Math.max(0, durationMs) as Object;
    }
    if (reason !== undefined) {
      attributes.reason = this.safeString(reason) as Object;
    }
    this.emit('lynx.transition.terminal', 'router', 'native', handle, undefined, attributes);
  }

  markPageVisible(pageViewId: string, reason: string = 'arkui_page_appear'): void {
    const handle = this.pagesById.get(pageViewId);
    if (handle === undefined || handle.pageState === TelemetryPageState.DESTROYED) {
      return;
    }
    handle.pageState = TelemetryPageState.VISIBLE;
    handle.appState = this.appState;
    this.emit('lynx.page.visibility_changed', 'page', 'native', handle, undefined, {
      state: 'visible' as Object,
      reason: this.safeString(reason) as Object
    });
    this.beginActivationIfEligible(handle, reason);
  }

  markPageHidden(pageViewId: string, reason: string = 'arkui_page_disappear'): void {
    const handle = this.pagesById.get(pageViewId);
    if (handle === undefined || handle.pageState === TelemetryPageState.DESTROYED) {
      return;
    }
    this.endActivationIfNeeded(handle, reason);
    handle.pageState = TelemetryPageState.HIDDEN;
    this.emit('lynx.page.visibility_changed', 'page', 'native', handle, undefined, {
      state: 'hidden' as Object,
      reason: this.safeString(reason) as Object
    });
  }

  markPageDestroyed(pageViewId: string, reason: string = 'arkui_page_removed'): void {
    const handle = this.pagesById.get(pageViewId);
    if (handle === undefined || handle.pageState === TelemetryPageState.DESTROYED) {
      return;
    }
    this.endActivationIfNeeded(handle, reason);
    handle.pageState = TelemetryPageState.DESTROYED;
    this.emit('lynx.page.destroyed', 'page', 'native', handle, undefined, {
      state: 'destroyed' as Object,
      reason: this.safeString(reason) as Object
    });
    this.pagesById.delete(pageViewId);
  }

  markFirstScreen(pageViewId: string, renderAttemptId: string, generation?: number, durationMs?: number): void {
    const handle = this.pagesById.get(pageViewId);
    if (handle === undefined || !this.isCurrent(handle, renderAttemptId, generation)) {
      this.dropStaleCallback(pageViewId, renderAttemptId, generation);
      return;
    }
    const attributes: TelemetryAttributes = {};
    if (durationMs !== undefined) {
      attributes.durationMs = Math.max(0, durationMs) as Object;
    }
    this.emit('lynx.page.first_screen', 'page', 'lynx_runtime', handle, undefined, attributes);
    if (handle.resolvedBundle !== undefined && !handle.pageOpenReported) {
      handle.pageOpenReported = true;
      this.emit('lynx.ota.page_open', 'ota', 'lynx_runtime', handle);
    }
  }

  markRuntimeReady(pageViewId: string, renderAttemptId?: string, generation?: number): void {
    const handle = this.pagesById.get(pageViewId);
    if (handle === undefined || !this.isCurrent(handle, renderAttemptId, generation)) {
      this.dropStaleCallback(pageViewId, renderAttemptId, generation);
      return;
    }
    this.emit('lynx.page.runtime_ready', 'page', 'lynx_runtime', handle);
  }

  /** UIAbility 的 App 前后台事实与 ArkUI Page 可见状态正交。 */
  onApplicationBackground(): void {
    if (this.appState === TelemetryAppState.BACKGROUND) {
      return;
    }
    this.appState = TelemetryAppState.BACKGROUND;
    this.pagesById.forEach((handle: TelemetryPageHandle) => {
      handle.appState = TelemetryAppState.BACKGROUND;
      this.endActivationIfNeeded(handle, 'app_background');
      this.emit('app.lifecycle.changed', 'app', 'system', handle, undefined, { state: 'background' as Object });
    });
  }

  onApplicationForeground(): void {
    if (this.appState === TelemetryAppState.FOREGROUND) {
      return;
    }
    this.appState = TelemetryAppState.FOREGROUND;
    this.pagesById.forEach((handle: TelemetryPageHandle) => {
      handle.appState = TelemetryAppState.FOREGROUND;
      this.emit('app.lifecycle.changed', 'app', 'system', handle, undefined, { state: 'foreground' as Object });
      this.beginActivationIfEligible(handle, 'app_foreground');
    });
  }

  dropStaleCallback(pageViewId: string, renderAttemptId?: string, generation?: number): boolean {
    const handle = this.pagesById.get(pageViewId);
    if (handle === undefined || this.isCurrent(handle, renderAttemptId, generation)) {
      return false;
    }
    const callbackAttempt = renderAttemptId ?? 'unknown';
    this.emit('telemetry.stale_callback_dropped', 'telemetry', 'system', handle, undefined, {
      callbackRenderAttemptId: this.safeString(callbackAttempt) as Object
    });
    return true;
  }

  pages(): TelemetryPageHandle[] {
    const result: TelemetryPageHandle[] = [];
    this.pagesById.forEach((handle: TelemetryPageHandle) => result.push(handle));
    return result;
  }

  private isCurrent(handle: TelemetryPageHandle, renderAttemptId?: string, generation?: number): boolean {
    return (renderAttemptId === undefined || renderAttemptId === handle.identity.renderAttemptId) &&
      (generation === undefined || generation === handle.attemptGeneration);
  }

  private beginActivationIfEligible(handle: TelemetryPageHandle, reason: string): void {
    if (handle.pageState !== TelemetryPageState.VISIBLE ||
      handle.appState !== TelemetryAppState.FOREGROUND ||
      handle.resolvedBundle === undefined || handle.activeStartedAtMonotonic !== undefined) {
      return;
    }
    handle.identity.activationId = `activation_${Date.now()}_${handle.sequenceNo}`;
    handle.activeStartedAtMonotonic = this.monotonicMillis();
    this.emit('lynx.page.visibility_changed', 'page', 'native', handle, undefined, {
      activation: 'started' as Object,
      reason: this.safeString(reason) as Object
    });
  }

  private endActivationIfNeeded(handle: TelemetryPageHandle, reason: string): void {
    if (handle.activeStartedAtMonotonic === undefined) {
      return;
    }
    const durationMs = Math.max(0, this.monotonicMillis() - handle.activeStartedAtMonotonic);
    this.emit('lynx.page.visibility_changed', 'page', 'native', handle, undefined, {
      activation: 'ended' as Object,
      reason: this.safeString(reason) as Object,
      durationMs: durationMs as Object
    });
    handle.activeStartedAtMonotonic = undefined;
    handle.identity.activationId = undefined;
  }

  private emit(
    eventName: string,
    category: string,
    source: string,
    handle?: TelemetryPageHandle,
    identityOverride?: TelemetryIdentity,
    attributes: TelemetryAttributes = {}
  ): void {
    if (!this.isSafeEventName(eventName)) {
      return;
    }
    const identity = identityOverride ?? handle?.identity;
    let sequenceNo = 0;
    if (handle !== undefined) {
      handle.sequenceNo += 1;
      sequenceNo = handle.sequenceNo;
    }
    const pageState = handle?.pageState;
    const appState = handle?.appState ?? this.appState;
    const activeEligible = pageState === TelemetryPageState.VISIBLE &&
      appState === TelemetryAppState.FOREGROUND && handle?.resolvedBundle !== undefined;
    const lifecycle: TelemetryLifecycleSnapshot | undefined = pageState === undefined ? undefined : {
      pageState: pageState,
      appState: appState,
      attemptState: handle?.resolvedBundle === undefined ? 'unusable' : 'usable',
      activeEligible: activeEligible
    };
    const navigationAdmission: TelemetryNavigationSnapshot = {
      state: eventName === 'lynx.navigation.rejected' ? 'rejected' :
        eventName === 'lynx.navigation.accepted' ? 'accepted' : 'requested'
    };
    const transition: TelemetryTransitionSnapshot = {
      state: eventName === 'lynx.transition.terminal' ? 'terminal' : 'waitingTarget'
    };
    const privacy: TelemetryPrivacySnapshot = {
      consentState: 'unknown',
      subjectRefPresent: false,
      optOut: false
    };
    const event: TelemetryEvent = {
      schemaVersion: '3.0.0',
      eventId: `evt_${Date.now()}_${sequenceNo}`,
      eventName: eventName,
      category: category,
      source: source,
      occurredAtUnixMs: Date.now(),
      monotonicOffsetMs: Math.max(0, this.monotonicMillis() - this.processStartMillis),
      sequenceNo: sequenceNo,
      navigationId: identity?.navigationId,
      navigationSessionId: identity?.navigationSessionId,
      pageViewId: identity?.pageViewId,
      entryId: identity?.entryId,
      renderAttemptId: identity?.renderAttemptId,
      activationId: identity?.activationId,
      transactionId: identity?.transactionId,
      runtimeKind: this.runtimeKind,
      runtimeInstanceId: handle?.pageViewId ?? 'process',
      telemetryRouteKey: handle?.resolvedBundle?.telemetryRouteKey ?? handle?.attemptedBundle.telemetryRouteKey ?? 'unknown',
      hostMode: this.hostMode,
      platform: this.platform,
      hostApp: this.hostApp,
      appVersion: this.appVersion,
      buildNumber: this.buildNumber,
      lynxSdkVersion: this.lynxSdkVersion,
      engineVersion: handle?.resolvedBundle?.engineVersion ?? this.engineVersion,
      lifecycle: lifecycle,
      navigationAdmission: navigationAdmission,
      transition: transition,
      privacy: privacy,
      attemptedBundleSnapshot: handle?.attemptedBundle,
      resolvedBundleSnapshot: handle?.resolvedBundle,
      sampleRate: this.sampleRate,
      samplingGroup: this.samplingGroup,
      samplingRuleVersion: this.samplingRuleVersion,
      analysisEligible: true,
      deliveryOwner: 'internal',
      attributes: attributes
    };
    try {
      this.sink.record(event);
    } catch (_error) {
      // 采集器故障必须 fail-open，不能让异常回到 Router/Lynx 页面。
    }
  }

  private monotonicMillis(): number {
    // ArkTS 当前只需要进程内单调近似值；正式接入可替换为平台 monotonic clock。
    return Date.now();
  }

  private safeString(value: string): string {
    return value.replace(/\n/g, ' ').replace(/\r/g, ' ').substring(0, 256);
  }

  private isSafeEventName(value: string): boolean {
    return /^[a-z][a-z0-9_.-]{0,63}$/.test(value);
  }
}
