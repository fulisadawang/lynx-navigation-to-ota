import { common } from '@kit.AbilityKit';
import systemDateTime from '@ohos.systemDateTime';
import bundleManager from '@ohos.bundle.bundleManager';
import { LynxEnv } from '@lynx/lynx';
import OtaApiClient, { OtaMockSource } from './OtaApiClient';
import {
  OtaBundleArtifact,
  OtaBundleLease,
  LynxOtaConfig,
  OtaLatestBundleLists,
  OtaPrepareSignal,
  OtaReleaseSnapshot,
  OtaStorageSnapshot,
  PageBundleRuntime,
  PreparedPageBundle
} from './OtaModels';
import ContentAddressedOtaStore from './ContentAddressedOtaStore';
import EmbeddedBundleRegistry from './EmbeddedBundleRegistry';
import PageBundleRuntimeRegistry from './OtaModels';
import { OtaUserContext, OtaUserContextBox } from './OtaUserContext';
import { OtaSelectionSyncError, OtaSelectionSyncResult } from './OtaSelection';
import OtaSelectionSync from './OtaSelectionSync';
import OtaPageRefreshGate from './OtaPageRefreshGate';
import OtaUserContextEvents from './OtaUserContextEvents';

/** 把所有会修改 current/state 的事务串行化；网络等待期间不会阻塞 ArkUI 线程。 */
class OtaOperationQueue {
  private tail: Promise<void> = Promise.resolve();

  run<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.tail.then(operation, operation);
    this.tail = result.then(() => undefined, () => undefined);
    return result;
  }
}

/**
 * TEST 环境的确定性 OTA 源。
 *
 * 只在 Ability Want 显式开启 debugMockEnabled 时由 Runtime 注入；它复用 HAP rawfile 中已校验
 * 的 home/main 字节，模拟两次不同 Release，仍完整经过 Store 的 size/SHA/发布/current/previous。
 */
class EmbeddedMockOtaSource implements OtaMockSource {
  private readonly config: LynxOtaConfig;
  private readonly registry: EmbeddedBundleRegistry;
  private readonly bundles: Map<string, ArrayBuffer> = new Map();
  private generation: number = 0;

  constructor(config: LynxOtaConfig, registry: EmbeddedBundleRegistry) {
    this.config = config;
    this.registry = registry;
  }

  async fetchLatestBundleLists(): Promise<OtaLatestBundleLists> {
    this.generation += 1;
    return {
      env: this.config.environment,
      hostApp: this.config.hostApp,
      platform: this.config.requestPlatform(),
      selectionSchemaVersion: 1,
      directives: [],
      bundleLists: [
        await this.makeSnapshot('10000001', ['home.lynx.bundle', 'main.lynx.bundle']),
        await this.makeSnapshot('10000002', ['home.lynx.bundle'])
      ]
    };
  }

  async fetchLatestBundleList(lynxAppId: string): Promise<OtaReleaseSnapshot> {
    if (this.generation === 0) this.generation = 1;
    const snapshot = await this.makeSnapshot(
      lynxAppId,
      lynxAppId === '10000002' ? ['home.lynx.bundle'] : ['home.lynx.bundle', 'main.lynx.bundle']
    );
    if (snapshot.lynxAppId !== lynxAppId) {
      throw new Error(`Mock latest 中不存在 lynxAppId：${lynxAppId}`);
    }
    return snapshot;
  }

  async downloadBundle(bundleUrl: string): Promise<ArrayBuffer> {
    const bytes = this.bundles.get(bundleUrl);
    if (bytes === undefined) throw new Error(`Mock Bundle 不存在：${bundleUrl}`);
    return bytes.slice(0);
  }

  private async makeSnapshot(lynxAppId: string, bundleNames: string[]): Promise<OtaReleaseSnapshot> {
    const releaseId = this.generation <= 1 ? 'mock-ota-v1' : 'mock-ota-v2';
    const artifacts: OtaBundleArtifact[] = [];
    for (let index = 0; index < bundleNames.length; index += 1) {
      const bundleName = bundleNames[index];
      const embedded = await this.registry.resolve(lynxAppId, bundleName);
      if (embedded === null || embedded.bytes === undefined) continue;
      const bundleUrl = `https://mock.lynx-ota.invalid/${lynxAppId}/${releaseId}/${bundleName}`;
      this.bundles.set(bundleUrl, embedded.bytes);
      artifacts.push({
        pageId: index + 1,
        bundlePath: bundleName,
        bundleSha256: embedded.sha256,
        bundleUrl: bundleUrl,
        size: embedded.bytes.byteLength
      });
    }
    if (artifacts.length === 0) throw new Error('Mock rawfile 没有可用 Bundle');
    return {
      env: this.config.environment,
      hostApp: this.config.hostApp,
      lynxAppId: lynxAppId,
      releaseId: releaseId,
      platform: this.config.requestPlatform(),
      status: 'ACTIVE',
      selectionSchemaVersion: 1,
      releaseSequence: this.generation <= 1 ? '1' : '2',
      selection: { kind: 'full', policyRevision: Math.max(1, this.generation).toString(), reason: 'latest_full' },
      changedBundles: artifacts
    };
  }
}

interface NavigationSnapshotRecord {
  id: string;
  sessionID: string;
  lynxAppId: string;
  releaseId: string;
  manifestId?: string;
  embedded: boolean;
  lease: OtaBundleLease | null;
  identityEpoch: number;
  source: string;
  retired: boolean;
}

/** 生命周期票据使用对象身份，reset 后无需永久保存每个已结束 session 的计数墓碑。 */
class NavigationSnapshotToken { active: boolean = true; }

/**
 * HarmonyOS Router 内置 OTA Runtime。
 *
 * 启动/回前台每次全量检查；页面命中本地 current 时立即打开并按 appId 做 30 分钟后台检查；
 * 缺包或 SHA 损坏忽略时间门控，在原生 Loading 中等待 repair。
 */
export default class LynxOtaRuntime implements PageBundleRuntime {
  private readonly config: LynxOtaConfig;
  private readonly api: OtaApiClient;
  private readonly transaction: ContentAddressedOtaStore;
  private readonly embeddedBundleRegistry: EmbeddedBundleRegistry;
  private queue: OtaOperationQueue = new OtaOperationQueue();
  private readonly identity: OtaUserContextBox;
  private readonly selectionSync: OtaSelectionSync;
  private readonly refreshGate: OtaPageRefreshGate = new OtaPageRefreshGate(0);
  private readonly activeSignals: Set<OtaPrepareSignal> = new Set();
  private readonly snapshotTokens: Map<string, NavigationSnapshotToken> = new Map();
  private reconciledEpoch: number = -1;
  private startupMaintenanceCompleted: boolean = false;
  private readonly snapshotsByID: Map<string, NavigationSnapshotRecord> = new Map();
  private readonly recoverySessions: Set<string> = new Set();
  private readonly processNonce: string = `${new Date().getTime()}-${Math.random().toString(36).substring(2)}`;
  private closed: boolean = false;
  private fullSyncTaskId: number = 0;
  private readonly navigationSnapshots: Map<string, NavigationSnapshotRecord> = new Map();
  private navigationSnapshotSequence: number = 0;
  private fullSyncInFlight: boolean = false;
  private fullSyncPending: boolean = false;
  private readonly fullSyncWaiters: Array<(success: boolean) => void> = [];
  /** install 完成后 Ability 首次 onForeground 属于同一次冷启动，避免重复请求。 */
  private skipNextForegroundSync: boolean = false;

  constructor(context: common.UIAbilityContext, config: LynxOtaConfig) {
    config.environment = config.environment.trim().toUpperCase();
    config.hostApp = config.hostApp.trim().toLowerCase();
    config.platform = config.platform.trim().toLowerCase();
    config.apiBaseUrl = config.apiBaseUrl.trim();
    if (config.platform !== 'harmony' || (config.serverPlatform.trim().length > 0 && config.serverPlatform.trim().toLowerCase() !== 'harmony')) {
      throw new Error('Harmony OTA 必须使用 platform=harmony，不再支持 Android 兼容请求');
    }
    const nativeInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    config.versionCode = OtaUserContext.normalizeVersionCode(config.versionCode ?? nativeInfo.versionCode.toString());
    const actualSDK = OtaUserContext.normalizeLynxSdkVersion(LynxEnv.getLynxVersion());
    config.lynxSdkVersion = OtaUserContext.normalizeLynxSdkVersion(config.lynxSdkVersion ?? actualSDK);
    if (config.lynxSdkVersion !== actualSDK) throw new Error('lynxSdkVersion 必须等于实际 Lynx HAR 版本');
    if (config.appVersion === undefined) config.appVersion = nativeInfo.versionName;
    config.validate(context);
    this.config = config;
    this.identity = new OtaUserContextBox(config);
    this.embeddedBundleRegistry = new EmbeddedBundleRegistry(context);
    const mockSource: OtaMockSource | null = config.debugMockEnabled ?
      new EmbeddedMockOtaSource(config, this.embeddedBundleRegistry) : null;
    this.api = new OtaApiClient(config, mockSource, this.identity);
    this.transaction = new ContentAddressedOtaStore(config, this.api, this.identity);
    this.selectionSync = new OtaSelectionSync(this.api, this.transaction, this.identity);
    this.transaction.setLeaseReleaseScheduler(() => {
      if (this.closed) return;
      const context = this.identity.capture();
      this.queue.run(async () => {
        this.guard(context);
        this.transaction.pruneAllUnreferencedReleases(context);
      }).catch(() => {
        console.warn('LynxShellOTA lease 释放后清理未完成');
      });
    });
  }

  get userIdentityEpoch(): number { return this.identity.identityEpoch; }

  registerUserId(userId?: string): boolean {
    if (this.closed) throw new Error('ota_runtime_closed');
    const changed = this.identity.register(userId);
    if (!changed) return false;
    this.navigationSnapshots.forEach((snapshot) => { snapshot.retired = true; });
    this.api.cancelAll();
    this.activeSignals.forEach((signal) => signal.cancel());
    this.activeSignals.clear();
    this.queue = new OtaOperationQueue();
    this.reconciledEpoch = -1;
    this.refreshGate.reset(this.userIdentityEpoch);
    this.fullSyncTaskId += 1;
    this.fullSyncInFlight = false;
    this.fullSyncPending = false;
    this.fullSyncWaiters.splice(0).forEach((waiter) => waiter(false));
    return true;
  }

  synchronizeRegisteredUser(epoch: number): void {
    if (epoch !== this.userIdentityEpoch || this.closed) return;
    this.refreshAllBundles().then(() => {
      if (PageBundleRuntimeRegistry.current() === this && epoch === this.userIdentityEpoch && !this.closed) OtaUserContextEvents.emit(epoch);
    });
  }

  close(): void {
    this.closed = true;
    this.identity.invalidate();
    this.api.cancelAll();
    this.activeSignals.forEach((signal) => signal.cancel());
    this.activeSignals.clear();
    this.fullSyncWaiters.splice(0).forEach((waiter) => waiter(false));
    this.navigationSnapshots.forEach((snapshot) => snapshot.lease?.close());
    this.navigationSnapshots.clear();
    this.snapshotsByID.clear();
    this.recoverySessions.clear();
    this.snapshotTokens.clear();
  }

  private guard(context: OtaUserContext, signal?: OtaPrepareSignal): void {
    if (this.closed) throw new Error('ota_runtime_closed');
    this.identity.validate(context);
    signal?.throwIfCancelled();
  }

  private reconcile(context: OtaUserContext): void {
    this.guard(context);
    if (!this.startupMaintenanceCompleted) {
      this.transaction.recoverInterruptedCandidates(context);
      this.startupMaintenanceCompleted = true;
    }
    if (this.reconciledEpoch === context.identityEpoch) return;
    this.transaction.reconcileUserContext(context);
    this.guard(context);
    this.reconciledEpoch = context.identityEpoch;
  }

  onApplicationStarted(): void {
    this.skipNextForegroundSync = true;
    this.syncAllBundlesAsync();
  }

  onApplicationForeground(): void {
    if (this.skipNextForegroundSync) {
      this.skipNextForegroundSync = false;
      return;
    }
    this.syncAllBundlesAsync();
  }

  async prepare(
    lynxAppId: string,
    bundleName: string,
    signal: OtaPrepareSignal,
    navigationSessionID: string = '',
    sourceSnapshotID: string = ''
  ): Promise<PreparedPageBundle> {
    const context = this.identity.capture();
    this.validateLogicalAddress(lynxAppId, bundleName);
    this.guard(context, signal);
    this.reconcile(context);
    const sessionID = navigationSessionID.trim();
    this.validateSourceSnapshot(sessionID, lynxAppId, sourceSnapshotID, context);
    const snapshotGeneration = this.snapshotToken(sessionID, lynxAppId);
    const snapshot = this.snapshotFor(sessionID, lynxAppId, context);
    if (snapshot !== null) {
      const pinned = await this.prepareFromSnapshot(snapshot, bundleName, context);
      if (pinned === null) {
        throw new Error(`NavigationSnapshot 已失效：${snapshot.id}/${lynxAppId}/${bundleName}`);
      }
      try { this.validateSourceSnapshot(sessionID, lynxAppId, sourceSnapshotID, context); }
      catch (error) { pinned.lease?.close(); throw (error as Error); }
      return this.attachSnapshot(snapshot, this.preparedForContext(context, pinned, signal));
    }
    const local = await this.transaction.acquireCachedBundleLease(lynxAppId, bundleName, true, context,
      () => !this.closed && !signal.cancelled && context.identityEpoch === this.userIdentityEpoch);
    try {
      this.guard(context, signal);
      this.validateSourceSnapshot(sessionID, lynxAppId, sourceSnapshotID, context);
    } catch (error) { local?.lease?.close(); throw (error as Error); }
    if (local !== null) {
      this.syncAppBundleAsync(lynxAppId);
      return this.createOrAttachSnapshot(sessionID, local, context, snapshotGeneration);
    }
    const repairDownloadedCurrent = this.transaction.hasDownloadedCurrent(lynxAppId, context);
    const embedded = repairDownloadedCurrent ? null : await this.embeddedBundleRegistry.resolve(lynxAppId, bundleName);
    this.guard(context, signal);
    this.validateSourceSnapshot(sessionID, lynxAppId, sourceSnapshotID, context);
    if (embedded !== null) {
      return this.createOrAttachSnapshot(sessionID, embedded, context, snapshotGeneration);
    }
    // 缺包/损坏不走 30 分钟门控，必须在创建 LynxView 前完成定向 repair。
    this.activeSignals.add(signal);
    const repaired = await this.queue.run(() => {
      this.guard(context, signal);
      return this.transaction.ensureBundleReady(lynxAppId, bundleName, signal, context);
    }).finally(() => this.activeSignals.delete(signal));
    // ensureBundleReady 已交付带 lease 的结果，不能丢弃后再次租用造成永久额外引用。
    this.preparedForContext(context, repaired, signal);
    try { this.validateSourceSnapshot(sessionID, lynxAppId, sourceSnapshotID, context); }
    catch (error) { repaired.lease?.close(); throw (error as Error); }
    this.refreshGate.markSuccess(lynxAppId, context.identityEpoch, this.uptimeMillis());
    return this.createOrAttachSnapshot(sessionID, repaired, context, snapshotGeneration);
  }

  /** 预热不建立正式 session Snapshot、不安排后台同步，也不进入候选 TRIAL。 */
  async prewarm(lynxAppId: string, bundleName: string, signal: OtaPrepareSignal,
    navigationSessionID: string = '', sourceSnapshotID: string = ''): Promise<PreparedPageBundle> {
    const context = this.identity.capture();
    this.validateLogicalAddress(lynxAppId, bundleName);
    this.guard(context, signal);
    const sessionID = navigationSessionID.trim();
    this.validateSourceSnapshot(sessionID, lynxAppId, sourceSnapshotID, context);
    const snapshot = this.snapshotFor(sessionID, lynxAppId, context);
    this.activeSignals.add(signal);
    try {
      if (snapshot !== null) {
        const ticket = this.transaction.capturePrewarmTicket(lynxAppId, context);
        ticket.navigationSnapshotID = snapshot.id;
        const pinned = snapshot.embedded ? await this.prepareFromSnapshot(snapshot, bundleName, context) :
          await this.queue.run(() => {
            this.guard(context, signal);
            this.validateSourceSnapshot(sessionID, lynxAppId, sourceSnapshotID, context);
            return this.transaction.prewarmPinnedBundleLease(lynxAppId, snapshot.releaseId, bundleName, snapshot.manifestId ?? '', signal, context);
          });
        if (pinned === null) throw new Error('pinned_bundle_unavailable');
        pinned.prewarm = pinned.prewarm ?? ticket;
        pinned.prewarm.navigationSnapshotID = snapshot.id;
        pinned.source = snapshot.source;
        return this.completePrewarm(pinned, sessionID, sourceSnapshotID, context, signal);
      }
      const cached = await this.transaction.acquireCachedBundleLease(lynxAppId, bundleName, true, context,
        () => !this.closed && !signal.cancelled && context.identityEpoch === this.userIdentityEpoch, false);
      if (cached !== null) return this.completePrewarm(cached, sessionID, sourceSnapshotID, context, signal);
      const ticket = this.transaction.capturePrewarmTicket(lynxAppId, context);
      const embedded = this.transaction.hasDownloadedCurrent(lynxAppId, context) ? null :
        await this.embeddedBundleRegistry.resolve(lynxAppId, bundleName);
      this.guard(context, signal);
      if (embedded !== null) {
        embedded.prewarm = ticket;
        return this.completePrewarm(embedded, sessionID, sourceSnapshotID, context, signal);
      }
      const repaired = await this.queue.run(() => {
        this.guard(context, signal);
        this.validateSourceSnapshot(sessionID, lynxAppId, sourceSnapshotID, context);
        return this.transaction.ensureBundleReady(lynxAppId, bundleName, signal, context, false);
      });
      return this.completePrewarm(repaired, sessionID, sourceSnapshotID, context, signal);
    } finally { this.activeSignals.delete(signal); }
  }

  private completePrewarm(prepared: PreparedPageBundle, sessionID: string, sourceID: string,
    context: OtaUserContext, signal: OtaPrepareSignal): PreparedPageBundle {
    try {
      this.preparedForContext(context, prepared, signal);
      this.validateSourceSnapshot(sessionID, prepared.lynxAppId, sourceID, context);
      const ticket = prepared.prewarm;
      if (ticket === undefined) throw new Error('invalid_prewarm_ticket');
      const snapshot = this.snapshotFor(sessionID, prepared.lynxAppId, context);
      if ((ticket.navigationSnapshotID !== undefined && ticket.navigationSnapshotID !== snapshot?.id) ||
        (snapshot !== null && (snapshot.releaseId !== prepared.releaseId || snapshot.manifestId !== prepared.manifestId))) throw new Error('stale_navigation_snapshot');
      ticket.navigationSessionID = sessionID;
      ticket.sourceSnapshotID = sourceID;
      ticket.navigationSnapshotID = snapshot?.id;
      this.transaction.validatePrewarmTicket(prepared.lynxAppId, ticket, context);
      if (prepared.bytes !== undefined) prepared.actualSizeBytes = prepared.bytes.byteLength;
      return prepared;
    } catch (error) { this.closePrepared(prepared); throw (error as Error); }
  }

  async claimPrewarmed(warm: PreparedPageBundle, navigationSessionID: string, sourceSnapshotID: string,
    signal: OtaPrepareSignal): Promise<PreparedPageBundle> {
    const ticket = warm.prewarm;
    if (ticket === undefined) throw new Error('invalid_prewarm_ticket');
    const context = this.identity.capture(ticket.identityEpoch);
    const sessionID = navigationSessionID.trim();
    if (ticket.navigationSessionID !== sessionID || ticket.sourceSnapshotID !== sourceSnapshotID) throw new Error('stale_prewarm_source');
    this.validateLogicalAddress(warm.lynxAppId, warm.bundleName);
    const active = (): boolean => {
      this.guard(context, signal);
      this.validateSourceSnapshot(sessionID, warm.lynxAppId, sourceSnapshotID, context);
      const snapshot = this.snapshotFor(sessionID, warm.lynxAppId, context);
      if ((ticket.navigationSnapshotID !== undefined && ticket.navigationSnapshotID !== snapshot?.id) ||
        (snapshot !== null && (snapshot.releaseId !== warm.releaseId || snapshot.manifestId !== warm.manifestId))) throw new Error('stale_navigation_snapshot');
      return true;
    };
    active();
    this.transaction.validatePrewarmTicket(warm.lynxAppId, ticket, context);
    const generation = this.snapshotToken(sessionID, warm.lynxAppId);
    this.activeSignals.add(signal);
    let claimed: PreparedPageBundle | null = null;
    try {
      claimed = await this.queue.run(async () => {
        active();
        if (warm.manifestId !== undefined) {
          return this.transaction.claimPrewarmedBundleLease(warm, context, () => generation.active && active());
        }
        const embedded = await this.embeddedBundleRegistry.resolve(warm.lynxAppId, warm.bundleName);
        active();
        this.transaction.validatePrewarmTicket(warm.lynxAppId, ticket, context);
        if (embedded === null || embedded.releaseId !== warm.releaseId || embedded.sha256 !== warm.sha256 ||
          embedded.bytes?.byteLength !== warm.actualSizeBytes) throw new Error('stale_prewarm_bundle');
        embedded.actualSizeBytes = embedded.bytes?.byteLength;
        return embedded;
      });
      active();
      return this.createOrAttachSnapshot(sessionID, this.preparedForContext(context, claimed, signal), context, generation);
    } catch (error) { claimed?.lease?.close(); throw (error as Error); }
    finally { this.activeSignals.delete(signal); }
  }

  /**
   * Native Tab 专用 cache-only 入口。
   *
   * 只读取并校验已经提交的 current，不调用定向清单接口，也不进入 repair 或后台刷新。
   */
  async resolveCurrent(
    lynxAppId: string,
    bundleName: string,
    navigationSessionID: string = '',
    sourceSnapshotID: string = '',
    allowCandidate: boolean = false,
    signal?: OtaPrepareSignal
  ): Promise<PreparedPageBundle | null> {
    const context = this.identity.capture();
    this.guard(context);
    this.validateLogicalAddress(lynxAppId, bundleName);
    this.reconcile(context);
    const sessionID = navigationSessionID.trim();
    this.validateSourceSnapshot(sessionID, lynxAppId, sourceSnapshotID, context);
    const snapshotGeneration = this.snapshotToken(sessionID, lynxAppId);
    const snapshot = this.snapshotFor(sessionID, lynxAppId, context);
    if (snapshot !== null) {
      const pinned = await this.prepareFromSnapshot(snapshot, bundleName, context);
      if (pinned !== null) this.preparedForContext(context, pinned, signal); else this.guard(context, signal);
      try { this.validateSourceSnapshot(sessionID, lynxAppId, sourceSnapshotID, context); }
      catch (error) { pinned?.lease?.close(); throw (error as Error); }
      return pinned === null ? null : this.attachSnapshot(snapshot, pinned);
    }
    const current = await this.transaction.acquireCachedBundleLease(lynxAppId, bundleName, allowCandidate, context,
      () => !this.closed && signal?.cancelled !== true && context.identityEpoch === this.userIdentityEpoch);
    try {
      this.guard(context, signal);
      this.validateSourceSnapshot(sessionID, lynxAppId, sourceSnapshotID, context);
    } catch (error) { current?.lease?.close(); throw (error as Error); }
    if (current !== null) {
      return this.createOrAttachSnapshot(sessionID, current, context, snapshotGeneration);
    }
    const embedded = await this.embeddedBundleRegistry.resolve(lynxAppId, bundleName);
    this.guard(context, signal);
    this.validateSourceSnapshot(sessionID, lynxAppId, sourceSnapshotID, context);
    return embedded === null ? null : this.createOrAttachSnapshot(sessionID, embedded, context, snapshotGeneration);
  }

  resolvePage(lynxAppId: string, bundleName: string, navigationSessionID: string = '', sourceSnapshotID: string = '', signal?: OtaPrepareSignal): Promise<PreparedPageBundle | null> {
    return this.resolveCurrent(lynxAppId, bundleName, navigationSessionID, sourceSnapshotID, true, signal);
  }

  async confirmCandidateHealthy(lynxAppId: string, expectedReleaseId: string, expectedIdentityEpoch?: number, isSourceActive?: () => boolean, expectedManifestId?: string): Promise<boolean> {
    const context = this.identity.capture(expectedIdentityEpoch);
    return this.queue.run(async () => {
      this.guard(context);
      await this.transaction.validateCachedObjects(context, true);
      this.guard(context);
      if (isSourceActive !== undefined && !isSourceActive()) throw new Error('invalid_health_source');
      const confirmed = this.transaction.confirmCandidateHealthy(lynxAppId, expectedReleaseId, context, expectedManifestId);
      if (confirmed) this.navigationSnapshots.forEach((snapshot) => {
        if (snapshot.lynxAppId === lynxAppId && snapshot.releaseId === expectedReleaseId && snapshot.identityEpoch === context.identityEpoch) snapshot.source = 'ota_current';
      });
      return confirmed;
    });
  }

  async recoverFailedRelease(lynxAppId: string, reason: string, expectedReleaseId: string, expectedIdentityEpoch: number | undefined,
    navigationSessionID: string, snapshotID: string, candidate: boolean): Promise<boolean> {
    const context = this.identity.capture(expectedIdentityEpoch);
    const key = this.snapshotKey(navigationSessionID, lynxAppId);
    if (this.recoverySessions.has(key)) throw new Error('ota_recovery_in_progress');
    this.guard(context);
    const source = this.snapshotsByID.get(snapshotID);
    if (snapshotID.length > 0 && (source === undefined || source.retired || source.sessionID !== navigationSessionID ||
      source.lynxAppId !== lynxAppId || source.releaseId !== expectedReleaseId || source.identityEpoch !== context.identityEpoch)) throw new Error('stale_navigation_snapshot');
    const ticket = this.transaction.captureFailedRelease(lynxAppId, expectedReleaseId, source?.manifestId,
      candidate && source?.source !== 'ota_current', context);
    this.recoverySessions.add(key);
    try {
      return await this.queue.run(async () => {
        this.guard(context);
        await this.transaction.validateCachedObjects(context);
        this.guard(context);
        this.transaction.validateFailedRelease(ticket, context);
        if (ticket.candidate) {
          if (!this.transaction.discardCandidate(lynxAppId, expectedReleaseId, context, ticket.manifestId)) throw new Error('stale_decision');
        } else { this.transaction.rollback(lynxAppId, expectedReleaseId, context); }
        const failedSnapshots: NavigationSnapshotRecord[] = [];
        this.navigationSnapshots.forEach((record) => {
          if (record.lynxAppId === lynxAppId && record.releaseId === expectedReleaseId && record.manifestId === ticket.manifestId && record.identityEpoch === context.identityEpoch) failedSnapshots.push(record);
        });
        failedSnapshots.forEach((record) => this.retireSnapshot(record));
        this.resetNavigationSnapshot(navigationSessionID, lynxAppId);
        this.refreshGate.clearApp(lynxAppId, context.identityEpoch);
        const current = this.transaction.hasDownloadedCurrent(lynxAppId, context);
        if (current) return true;
        const embedded = await this.embeddedBundleRegistry.containsApp(lynxAppId);
        this.guard(context);
        return embedded;
      });
    } finally { ticket.lease.close(); this.recoverySessions.delete(key); }
  }

  releaseNavigationSnapshot(navigationSessionID: string, lynxAppId: string): void {
    const key = this.snapshotKey(navigationSessionID, lynxAppId);
    const token = this.snapshotTokens.get(key);
    if (token !== undefined) token.active = false;
    this.snapshotTokens.delete(key);
    const snapshot = this.navigationSnapshots.get(key);
    if (snapshot === undefined) return;
    this.navigationSnapshots.delete(key);
    snapshot.retired = true;
    snapshot.lease?.close();
    snapshot.lease = null;
    this.snapshotsByID.forEach((value, id) => {
      if (value.sessionID === navigationSessionID && value.lynxAppId === lynxAppId) this.snapshotsByID.delete(id);
    });
  }

  resetNavigationSnapshot(navigationSessionID: string, lynxAppId: string): void {
    const key = this.snapshotKey(navigationSessionID, lynxAppId);
    const token = this.snapshotTokens.get(key);
    if (token !== undefined) token.active = false;
    this.snapshotTokens.delete(key);
    const snapshot = this.navigationSnapshots.get(key);
    this.navigationSnapshots.delete(key);
    if (snapshot !== undefined) { snapshot.retired = true; snapshot.lease?.close(); snapshot.lease = null; this.snapshotsByID.delete(snapshot.id); }
  }

  /** cache-first 普通页面使用的后台刷新入口；syncAppBundleAsync 自带 AppId 门控。 */
  refreshAppBundleIfNeeded(lynxAppId: string): void {
    this.syncAppBundleAsync(lynxAppId);
  }

  /** 用户主动刷新使用；等待最后一轮合并后的全量同步完成，再由 Tab Host 重读 current。 */
  refreshAllBundles(): Promise<boolean> {
    if (this.closed) return Promise.resolve(false);
    const epoch = this.userIdentityEpoch;
    return new Promise<boolean>((resolve) => {
      this.fullSyncWaiters.push((success) => resolve(success && epoch === this.userIdentityEpoch && !this.closed));
      this.syncAllBundlesAsync(true);
    });
  }

  async rollback(lynxAppId: string, reason: string, expectedReleaseId?: string, expectedIdentityEpoch?: number): Promise<boolean> {
    const context = this.identity.capture(expectedIdentityEpoch);
    return this.queue.run(async () => {
      this.guard(context);
      const restoredRemote = this.transaction.rollback(lynxAppId, expectedReleaseId, context);
      if (restoredRemote) {
        this.refreshGate.clearApp(lynxAppId, context.identityEpoch);
        return true;
      }
      // 回滚/内置回退由 Store 一次提交，不能在探测后再删除可能新提交的 current。
      const embedded = await this.embeddedBundleRegistry.containsApp(lynxAppId);
      this.guard(context);
      this.refreshGate.clearApp(lynxAppId, context.identityEpoch);
      return embedded;
    });
  }

  async deleteBundles(lynxAppId: string): Promise<void> {
    const context = this.identity.capture();
    return this.queue.run(async () => {
      this.guard(context);
      this.transaction.deleteBundles(lynxAppId, context);
      this.refreshGate.clearApp(lynxAppId, context.identityEpoch);
    });
  }

  async deleteAllBundles(): Promise<void> {
    const context = this.identity.capture();
    return this.queue.run(async () => {
      this.guard(context);
      this.transaction.deleteAllBundles(context);
      this.refreshGate.clearAll(context.identityEpoch);
    });
  }

  storageRoot(): string {
    return this.transaction.storageRoot();
  }

  storageSnapshot(): Promise<OtaStorageSnapshot> {
    return Promise.resolve(this.transaction.storageSnapshot());
  }

  private snapshotKey(sessionID: string, lynxAppId: string): string {
    return `${sessionID}::${lynxAppId}`;
  }

  private snapshotToken(sessionID: string, lynxAppId: string): NavigationSnapshotToken {
    if (sessionID.length === 0) return new NavigationSnapshotToken();
    const key = this.snapshotKey(sessionID, lynxAppId);
    let token = this.snapshotTokens.get(key);
    if (token === undefined) { token = new NavigationSnapshotToken(); this.snapshotTokens.set(key, token); }
    return token;
  }

  validateNavigationSource(sourceSnapshotID: string): void {
    const context = this.identity.capture();
    this.guard(context);
    if (sourceSnapshotID.length === 0) return;
    const source = this.snapshotsByID.get(sourceSnapshotID);
    if (source !== undefined && source.source === 'candidate_trial' &&
      !this.transaction.isTrialCandidate(source.lynxAppId, source.releaseId, source.manifestId, context)) this.retireSnapshot(source);
    if (source === undefined || source.retired || source.identityEpoch !== context.identityEpoch ||
      this.recoverySessions.has(this.snapshotKey(source.sessionID, source.lynxAppId))) throw new Error('stale_navigation_snapshot');
  }

  private validateSourceSnapshot(sessionID: string, appId: string, sourceID: string, context: OtaUserContext): void {
    if (this.recoverySessions.has(this.snapshotKey(sessionID, appId))) throw new Error('ota_recovery_in_progress');
    if (sourceID.length === 0) return;
    const source = this.snapshotsByID.get(sourceID);
    if (source !== undefined && source.source === 'candidate_trial' &&
      !this.transaction.isTrialCandidate(source.lynxAppId, source.releaseId, source.manifestId, context)) this.retireSnapshot(source);
    if (source === undefined || source.retired || source.identityEpoch !== context.identityEpoch || source.sessionID !== sessionID) throw new Error('stale_navigation_snapshot');
  }

  private snapshotFor(sessionID: string, lynxAppId: string, context: OtaUserContext): NavigationSnapshotRecord | null {
    if (sessionID.length === 0) return null;
    const snapshot = this.navigationSnapshots.get(this.snapshotKey(sessionID, lynxAppId)) ?? null;
    if (snapshot !== null && snapshot.source === 'candidate_trial' &&
      !this.transaction.isTrialCandidate(snapshot.lynxAppId, snapshot.releaseId, snapshot.manifestId, context)) this.retireSnapshot(snapshot);
    if (snapshot !== null && (snapshot.retired || snapshot.identityEpoch !== context.identityEpoch)) throw new Error('旧用户导航会话不能打开新页面');
    return snapshot;
  }

  private preparedForContext(context: OtaUserContext, prepared: PreparedPageBundle, signal?: OtaPrepareSignal): PreparedPageBundle {
    try {
      this.guard(context, signal);
      if (prepared.userIdentityEpoch !== undefined && prepared.userIdentityEpoch !== context.identityEpoch) throw new Error('stale_identity');
      prepared.userIdentityEpoch = context.identityEpoch;
      return prepared;
    } catch (error) { this.closePrepared(prepared); throw (error as Error); }
  }

  private createOrAttachSnapshot(sessionID: string, prepared: PreparedPageBundle, context: OtaUserContext, generation: NavigationSnapshotToken): PreparedPageBundle {
    this.preparedForContext(context, prepared);
    if (sessionID.length === 0) return prepared;
    if (!generation.active || generation !== this.snapshotTokens.get(this.snapshotKey(sessionID, prepared.lynxAppId))) {
      this.closePrepared(prepared);
      throw new Error('navigation_snapshot_reset');
    }
    const key = this.snapshotKey(sessionID, prepared.lynxAppId);
    const existing = this.navigationSnapshots.get(key);
    if (existing !== undefined) return this.attachSnapshot(existing, prepared);
    const embedded = prepared.manifestId === undefined;
    const lease = embedded ? null : this.transaction.acquireReleaseLease(
      prepared.lynxAppId,
      prepared.releaseId,
      prepared.manifestId ?? '',
      context
    );
    if (!embedded && lease === null) {
      this.closePrepared(prepared);
      throw new Error(`NavigationSnapshot lease 建立失败：${prepared.lynxAppId}/${prepared.releaseId}`);
    }
    try { this.guard(context); } catch (error) { lease?.close(); this.closePrepared(prepared); throw (error as Error); }
    this.navigationSnapshotSequence += 1;
    const snapshot: NavigationSnapshotRecord = {
      id: `lynx-snapshot-${this.processNonce}-${this.navigationSnapshotSequence}`,
      sessionID: sessionID,
      lynxAppId: prepared.lynxAppId,
      releaseId: prepared.releaseId,
      manifestId: prepared.manifestId,
      embedded: embedded,
      lease: lease,
      identityEpoch: context.identityEpoch,
      source: prepared.source ?? 'ota_current',
      retired: false
    };
    this.navigationSnapshots.set(key, snapshot);
    this.snapshotsByID.set(snapshot.id, snapshot);
    return this.attachSnapshot(snapshot, prepared);
  }

  private attachSnapshot(snapshot: NavigationSnapshotRecord, prepared: PreparedPageBundle): PreparedPageBundle {
    if (this.navigationSnapshots.get(this.snapshotKey(snapshot.sessionID, snapshot.lynxAppId)) !== snapshot ||
      snapshot.retired || snapshot.identityEpoch !== this.userIdentityEpoch || snapshot.releaseId !== prepared.releaseId ||
      snapshot.manifestId !== prepared.manifestId) {
      this.closePrepared(prepared);
      throw new Error('stale_navigation_snapshot');
    }
    prepared.navigationSnapshotID = snapshot.id;
    prepared.source = snapshot.source;
    return prepared;
  }

  private closePrepared(prepared: PreparedPageBundle): void {
    prepared.lease?.close();
  }

  private async prepareFromSnapshot(
    snapshot: NavigationSnapshotRecord,
    bundleName: string,
    context: OtaUserContext
  ): Promise<PreparedPageBundle | null> {
    if (snapshot.embedded) {
      const value = await this.embeddedBundleRegistry.resolve(snapshot.lynxAppId, bundleName);
      return value === null ? null : this.preparedForContext(context, value);
    }
    return this.transaction.acquirePinnedBundleLease(
      snapshot.lynxAppId,
      snapshot.releaseId,
      bundleName,
      snapshot.manifestId ?? '',
      context
    );
  }

  /** 生命周期全量请求不限次数；重叠事件合并为当前请求结束后的补发。 */
  private syncAllBundlesAsync(coalesce: boolean = false): void {
    if (this.closed) return;
    if (this.fullSyncInFlight) {
      if (!coalesce) this.fullSyncPending = true;
      return;
    }
    const context = this.identity.capture();
    const taskId = ++this.fullSyncTaskId;
    const signal = new OtaPrepareSignal();
    this.activeSignals.add(signal);
    this.fullSyncInFlight = true;
    let succeeded = true;
    this.queue.run(async () => {
      this.reconcile(context);
      await this.transaction.validateCachedObjects(context);
      this.guard(context, signal);
      const result = await this.selectionSync.syncAll(signal, context);
      this.guard(context, signal);
      this.markChecked(result, context);
    }).catch((error: Error) => {
      // 生命周期刷新失败不能影响已提交 current，后续页面仍可定向 repair。
      succeeded = false;
      if (context.identityEpoch === this.userIdentityEpoch && !this.closed) {
        if (error instanceof OtaSelectionSyncError) this.markChecked(error.partialResult, context);
        console.warn('LynxShellOTA 全量同步未全部完成');
      }
    }).finally(() => {
      this.activeSignals.delete(signal);
      if (taskId !== this.fullSyncTaskId || context.identityEpoch !== this.userIdentityEpoch || this.closed) return;
      this.fullSyncInFlight = false;
      this.retireInvalidCandidates(context);
      if (this.fullSyncPending) {
        this.fullSyncPending = false;
        this.syncAllBundlesAsync();
        return;
      }
      const waiters = this.fullSyncWaiters.splice(0, this.fullSyncWaiters.length);
      waiters.forEach((waiter: (success: boolean) => void) => {
        try {
          waiter(succeeded);
        } catch (error) {
          console.warn('LynxShellOTA 主动刷新回调失败');
        }
      });
    });
  }

  /** 页面已有合法 current 时才进入 appId 级时间门控，后台失败不阻塞旧版本。 */
  private syncAppBundleAsync(lynxAppId: string): void {
    if (this.closed) return;
    const context = this.identity.capture();
    const now = this.uptimeMillis();
    if (this.fullSyncInFlight || !this.refreshGate.reserve(lynxAppId, context.identityEpoch, now, this.config.pageRefreshIntervalMillis)) return;
    const signal = new OtaPrepareSignal();
    this.activeSignals.add(signal);
    this.queue.run(async () => {
      this.guard(context, signal);
      this.reconcile(context);
      await this.transaction.validateCachedObjects(context);
      this.guard(context, signal);
      if (this.fullSyncInFlight) return;
      const result = await this.selectionSync.syncApp(lynxAppId, signal, context);
      this.guard(context, signal);
      // 只有清单和事务都成功后才刷新时间戳。
      this.markChecked(result, context);
    }).catch(() => {
      if (context.identityEpoch === this.userIdentityEpoch && !this.closed) console.warn(`LynxShellOTA appId 后台刷新未完成：${lynxAppId}`);
    }).finally(() => {
      this.activeSignals.delete(signal);
      this.refreshGate.complete(lynxAppId, context.identityEpoch);
      if (context.identityEpoch === this.userIdentityEpoch && !this.closed) this.retireInvalidCandidates(context);
    });
  }

  private retireSnapshot(snapshot: NavigationSnapshotRecord): void {
    snapshot.retired = true;
    const key = this.snapshotKey(snapshot.sessionID, snapshot.lynxAppId);
    if (this.navigationSnapshots.get(key) === snapshot) this.navigationSnapshots.delete(key);
    const token = this.snapshotTokens.get(key);
    if (token !== undefined) token.active = false;
    this.snapshotTokens.delete(key);
    this.snapshotsByID.delete(snapshot.id);
    snapshot.lease?.close(); snapshot.lease = null;
  }

  private retireInvalidCandidates(context: OtaUserContext): void {
    this.guard(context);
    const records: NavigationSnapshotRecord[] = [];
    this.navigationSnapshots.forEach((snapshot) => records.push(snapshot));
    records.forEach((snapshot) => {
      if (snapshot.identityEpoch === context.identityEpoch && snapshot.source === 'candidate_trial' &&
        !this.transaction.isTrialCandidate(snapshot.lynxAppId, snapshot.releaseId, snapshot.manifestId, context)) this.retireSnapshot(snapshot);
    });
  }

  private markChecked(result: OtaSelectionSyncResult, context: OtaUserContext): void {
    this.retireInvalidCandidates(context);
    result.completedAppIds.forEach((appId) => this.refreshGate.markSuccess(appId, context.identityEpoch, this.uptimeMillis()));
  }

  private validateLogicalAddress(lynxAppId: string, bundleName: string): void {
    if (lynxAppId.trim().length === 0 || bundleName.trim().length === 0) {
      throw new Error('lynxAppId/bundleName 不能为空');
    }
    if (!bundleName.trim().endsWith('.lynx.bundle')) {
      throw new Error('OTA bundleName 必须以 .lynx.bundle 结尾');
    }
  }

  /** 使用开机单调时间，避免用户修改系统时间绕过或拉长 30 分钟门控。 */
  private uptimeMillis(): number {
    return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
  }
}
