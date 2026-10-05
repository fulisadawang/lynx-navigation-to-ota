import { hashOtaFile } from './OtaFileIO';
import { statfs } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import cryptoFramework from '@ohos.security.cryptoFramework';
import OtaApiClient from './OtaApiClient';
import OtaJson from './OtaJson';
import OtaSidecarStore from './OtaSidecarStore';
import { OtaUserContext, OtaUserContextBox } from './OtaUserContext';
import { OtaLastDecision, OtaLatestSelection, OtaSelection, OtaStoredSelection } from './OtaSelection';
import {
  LynxOtaConfig,
  OtaBundleArtifact,
  OtaCandidateState,
  OtaBundleLease,
  OtaLocalManifest,
  OtaPrepareSignal,
  OtaPrewarmTicket,
  OtaReleaseRef,
  OtaReleaseSnapshot,
  OtaReleaseState,
  OtaStorageAppSnapshot,
  OtaStorageFileSnapshot,
  OtaStorageReleaseRole,
  OtaStorageReleaseSnapshot,
  OtaStorageSnapshot,
  OtaStorageStagingSnapshot,
  OtaStorageStateSnapshot,
  PreparedPageBundle
} from './OtaModels';

interface OtaTreeScan {
  totalBytes: number;
  fileCount: number;
  files: OtaStorageFileSnapshot[];
  truncated: boolean;
}

interface OtaTransactionRecord {
  objectIds?: string[];
  manifestId?: string;
}

export interface OtaFailedReleaseTicket {
  lynxAppId: string;
  releaseId: string;
  manifestId: string;
  candidate: boolean;
  identityEpoch: number;
  decision?: OtaLastDecision;
  lease: OtaBundleLease;
}

/**
 * HarmonyOS Store v3：完整 Manifest 快照 + App ID 隔离的 SHA-256 CAS 对象库。
 *
 * rawfile embedded 不复制到 filesDir；远程对象只进入：
 * apps/<appId>/objects/<sha 前两位>/<sha>.lynx.bundle。
 * state.json 只保存 current/previous 的逻辑引用，Manifest 最后提交，路由只读已提交对象。
 */
export default class ContentAddressedOtaStore {
  private readonly config: LynxOtaConfig;
  private readonly api: OtaApiClient;
  private readonly root: string;
  private readonly testFaultPoint: string;
  private readonly testAvailableCapacityBytes: number;
  private readonly testPausePoint: string;
  private readonly testPauseMillis: number;
  private readonly testPauseToken: string;
  private readonly validatedObjects: Map<string, number> = new Map();
  private readonly activeLeases: Map<string, number> = ContentAddressedOtaStore.sharedLeases;
  private leaseReleaseScheduler: (() => void) | null = null;
  private lastOperation: string = 'none';
  private readonly identityBox: OtaUserContextBox;
  private readonly sidecars: OtaSidecarStore;
  private static readonly runningTransactions: Set<string> = new Set();
  private static readonly sharedLeases: Map<string, number> = new Map();
  private static readonly leasedSelections: Map<string, OtaStoredSelection> = new Map();

  constructor(config: LynxOtaConfig, api: OtaApiClient, identityBox?: OtaUserContextBox) {
    this.config = config;
    this.api = api;
    this.root = config.storageDirectory;
    this.identityBox = identityBox ?? new OtaUserContextBox(config);
    this.api.bindUserContext(this.identityBox);
    this.sidecars = new OtaSidecarStore(config, api, this.identityBox);
    this.testFaultPoint = config.environment.toUpperCase() === 'TEST' ? config.testFaultPoint.trim().toLowerCase() : '';
    this.testAvailableCapacityBytes = config.environment.toUpperCase() === 'TEST' ? config.testAvailableCapacityBytes : -1;
    this.testPausePoint = config.environment.toUpperCase() === 'TEST' ? config.testPausePoint.trim().toLowerCase() : '';
    this.testPauseMillis = config.environment.toUpperCase() === 'TEST' ? config.testPauseMillis : 0;
    this.testPauseToken = config.environment.toUpperCase() === 'TEST' ? config.testPauseToken.trim() : '';
    this.ensureDirectory(this.root);
    this.ensureDirectory(this.appsRoot());
    this.recoverExistingStorage();
  }

  setLeaseReleaseScheduler(scheduler: (() => void) | null): void {
    this.leaseReleaseScheduler = scheduler;
  }

  /** 第一次读取冷缓存前，真实异步分块 SHA；后续同步解析只消费同 stat 身份的校验缓存。 */
  async validateCachedObjects(context?: OtaUserContext, forceHash: boolean = false): Promise<void> {
    this.validateContext(context);
    if (!this.exists(this.appsRoot())) return;
    for (const appId of fs.listFileSync(this.appsRoot())) {
      if (!this.isValidAppId(appId)) continue;
      const manifests = this.manifestsRoot(appId);
      if (!this.isDirectory(manifests)) continue;
      for (const name of fs.listFileSync(manifests)) {
        if (!name.endsWith('.json')) continue;
        const manifest = this.readManifest(appId, name.substring(0, name.length - 5));
        if (manifest === null) continue;
        for (const artifact of manifest.bundles) {
          await this.validateObjectAsync(appId, artifact, forceHash);
          this.validateContext(context);
        }
        await this.sidecars.validateManifestObjects(appId, manifest, forceHash);
        this.validateContext(context);
      }
    }
  }

  private async validateObjectAsync(appId: string, artifact: OtaBundleArtifact, forceHash: boolean = false): Promise<void> {
    const objectId = artifact.objectId ?? artifact.bundleSha256;
    if (!forceHash && this.hasUsableObject(appId, objectId, artifact.size)) return;
    const path = this.objectPath(appId, objectId);
    if (!this.isRegularFile(path)) return;
    const stat = fs.statSync(path);
    if (stat.size !== artifact.size) return;
    const key = `${appId}|${objectId.toLowerCase()}|${stat.size}|${stat.mtime}|${stat.ctime}|${stat.ino}`;
    if (forceHash) this.validatedObjects.delete(key);
    if ((await hashOtaFile(path)).toLowerCase() !== objectId.toLowerCase()) { this.validatedObjects.delete(key); return; }
    const after = fs.statSync(path);
    if (stat.size === after.size && stat.mtime === after.mtime && stat.ctime === after.ctime && stat.ino === after.ino) {
      this.validatedObjects.set(key, new Date().getTime());
    }
  }

  /** 缓存读独立于网络写队列；临时 Manifest lease 保护异步校验期间的 main/Async。 */
  async acquireCachedBundleLease(appId: string, bundleName: string, allowCandidate: boolean,
    context?: OtaUserContext, isReadActive?: () => boolean, markTrial: boolean = true): Promise<PreparedPageBundle | null> {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      this.validateContext(context);
      const captured = this.contextState(appId, context);
      if (captured === null) return null;
      const candidate = allowCandidate && this.config.candidateActivationEnabled && captured.candidate !== undefined &&
        this.eligible(captured.candidate.release, captured, context) ? captured.candidate.release : undefined;
      const ref = candidate ?? this.effectiveRef(captured, context);
      if (ref === undefined || ref.kind !== 'downloaded' || ref.manifestId === undefined) return null;
      const manifest = this.readManifest(appId, ref.manifestId);
      if (manifest === null || manifest.releaseId !== ref.releaseId) {
        return candidate === undefined ? null : this.acquireCachedBundleLease(appId, bundleName, false, context, isReadActive, markTrial);
      }
      const validationLease = this.createManifestLease(appId, ref.manifestId, ref.selection);
      try {
        await this.validateReadManifest(appId, manifest, context);
        this.validateContext(context);
        const live = this.contextState(appId, context);
        if (live === null) return null;
        const sameDecision = captured.lastDecision === undefined ? live.lastDecision === undefined :
          OtaSelection.sameDecision(live.lastDecision, captured.lastDecision);
        const liveRef = candidate === undefined ? this.effectiveRef(live, context) : live.candidate?.release;
        if (!sameDecision || liveRef?.releaseId !== ref.releaseId || liveRef.manifestId !== ref.manifestId ||
          !this.eligible(liveRef, live, context)) continue;
        if (isReadActive !== undefined && !isReadActive()) throw new Error('OTA 页面准备已取消');
        // ArkTS 同一事件线程同步提交；从末端复核到 TRIAL State rename 之间没有 await。
        const prepared = candidate === undefined ? this.acquireCurrentBundleLease(appId, bundleName, context) :
          this.acquireCandidateTrialBundleLease(appId, bundleName, context, markTrial);
        if (prepared === null && candidate !== undefined) return this.acquireCachedBundleLease(appId, bundleName, false, context, isReadActive, markTrial);
        if (prepared !== null && !markTrial && context !== undefined) {
          try { prepared.prewarm = this.capturePrewarmTicket(appId, context); }
          catch (error) { prepared.lease?.close(); throw (error as Error); }
        }
        return prepared;
      } finally { validationLease.close(); }
    }
    throw new Error('stale_cache_read');
  }

  async acquirePinnedBundleLease(appId: string, releaseId: string, bundleName: string, manifestId: string,
    context?: OtaUserContext): Promise<PreparedPageBundle | null> {
    this.validateContext(context);
    const manifest = this.readManifest(appId, manifestId);
    if (manifest === null || manifest.releaseId !== releaseId) return null;
    const state = this.contextState(appId, context);
    if (state === null) return null;
    const key = this.leaseKey(appId, manifestId);
    const ref: OtaReleaseRef = { kind: 'downloaded', releaseId: releaseId, manifestId: manifestId,
      selection: ContentAddressedOtaStore.leasedSelections.get(key) };
    if (!this.activeLeases.has(key) || !this.eligible(ref, state, context)) return null;
    const validationLease = this.createManifestLease(appId, manifestId, ref.selection);
    try {
      await this.validateReadManifest(appId, manifest, context);
      this.validateContext(context);
      const live = this.contextState(appId, context);
      if (live === null || !this.eligible(ref, live, context)) return null;
      return this.acquireBundleLeaseForRelease(appId, releaseId, bundleName, manifestId, context);
    } finally { validationLease.close(); }
  }

  /** 预热固定快照时从其受 lease 保护的完整 Manifest 修复，不查询另一个 latest Release。 */
  async prewarmPinnedBundleLease(appId: string, releaseId: string, bundleName: string, manifestId: string,
    signal: OtaPrepareSignal, context: OtaUserContext): Promise<PreparedPageBundle> {
    this.validateContext(context);
    signal.throwIfCancelled();
    const manifest = this.readManifest(appId, manifestId);
    const key = this.leaseKey(appId, manifestId);
    const selection = ContentAddressedOtaStore.leasedSelections.get(key);
    const ref: OtaReleaseRef = { kind: 'downloaded', releaseId: releaseId, manifestId: manifestId, selection: selection };
    const state = this.contextState(appId, context);
    if (manifest === null || manifest.releaseId !== releaseId || !this.activeLeases.has(key) ||
      state === null || !this.eligible(ref, state, context)) throw new Error('stale_navigation_snapshot');
    const hold = this.createManifestLease(appId, manifestId, selection);
    let prepared: PreparedPageBundle | null = null;
    try {
      const snapshot: OtaReleaseSnapshot = { env: manifest.env, hostApp: manifest.hostApp, lynxAppId: appId,
        releaseId: releaseId, platform: manifest.platform, status: manifest.status, changedBundles: manifest.bundles,
        asyncBundleManifest: manifest.asyncBundleManifest, selectionSchemaVersion: context.selectionEnabled ? 1 : undefined,
        releaseSequence: selection?.releaseSequence, selection: selection === undefined ? undefined : {
          kind: selection.kind, ruleId: selection.ruleId, policyRevision: selection.policyRevision,
          reason: selection.kind === 'gray' ? 'matched_gray' : 'latest_full' },
        versionCodeRange: selection?.versionCodeRange, lynxSdkRange: selection?.lynxSdkRange,
        minAppVersion: selection?.minAppVersion, maxAppVersion: selection?.maxAppVersion,
        nativeProtocolVersionRange: selection?.nativeProtocolVersionRange };
      if (this.manifestId(snapshot) !== manifestId) throw new Error('stale_navigation_snapshot');
      await this.install(snapshot, signal, context, true);
      signal.throwIfCancelled();
      this.validateContext(context);
      const live = this.contextState(appId, context);
      if (live === null || !this.eligible(ref, live, context)) throw new Error('stale_decision');
      prepared = this.acquireBundleLease(ref, appId, bundleName, context);
      if (prepared === null) throw new Error('pinned_bundle_unavailable');
      prepared.prewarm = this.capturePrewarmTicket(appId, context);
      this.retireRecoveredTransactions(appId);
      this.sidecars.retireTransactions(appId);
      this.pruneApp(appId);
      return prepared;
    } catch (error) { prepared?.lease?.close(); throw (error as Error); }
    finally { hold.close(); }
  }

  private async validateReadManifest(appId: string, manifest: OtaLocalManifest, context?: OtaUserContext, forceHash: boolean = false): Promise<void> {
    for (const artifact of manifest.bundles) {
      await this.validateObjectAsync(appId, artifact, forceHash);
      this.validateContext(context);
    }
    await this.sidecars.validateManifestObjects(appId, manifest, forceHash);
    this.validateContext(context);
  }

  /** 每进程只由 Runtime 启动维护调用一次；pending 是完整下载结果，不能被误清理。 */
  recoverInterruptedCandidates(context?: OtaUserContext): void {
    this.validateContext(context);
    if (!this.exists(this.appsRoot())) return;
    fs.listFileSync(this.appsRoot()).forEach((appId: string) => {
      if (!this.isValidAppId(appId)) return;
      const state = this.contextState(appId, context);
      if (state?.candidate?.status !== 'trial') return;
      state.candidate = undefined;
      state.generation += 1;
      if (state.current === undefined) this.removeIfPresent(this.statePath(appId));
      else this.writeState(state, context);
      this.pruneApp(appId);
    });
  }

  acquireCandidateTrialBundleLease(appId: string, bundleName: string, context?: OtaUserContext, markTrial: boolean = true): PreparedPageBundle | null {
    if (!this.config.candidateActivationEnabled) return null;
    this.validateContext(context);
    const state = this.contextState(appId, context);
    const candidate = state?.candidate;
    if (state === null || candidate === undefined || !this.eligible(candidate.release, state, context)) return null;
    const manifest = this.readManifest(appId, candidate.release.manifestId ?? '');
    if (manifest === null || !this.manifestObjectsUsable(appId, manifest.bundles) || !this.sidecars.verifyBound(appId, manifest)) return null;
    const prepared = this.acquireBundleLease(candidate.release, appId, bundleName, context);
    if (prepared === null) return null;
    try {
      if (markTrial && candidate.status === 'pending') {
        candidate.status = 'trial';
        candidate.trialStartedAt = new Date().getTime();
        state.generation += 1;
        this.writeState(state, context, state.lastDecision);
      }
      prepared.source = candidate.status === 'trial' ? 'candidate_trial' : 'candidate_pending';
      return prepared;
    } catch (error) { prepared.lease?.close(); throw (error as Error); }
  }

  isTrialCandidate(appId: string, releaseId: string, manifestId: string | undefined, context?: OtaUserContext): boolean {
    this.validateContext(context);
    const state = this.contextState(appId, context);
    return state !== null && state.candidate?.status === 'trial' && state.candidate.release.releaseId === releaseId &&
      state.candidate.release.manifestId === manifestId && this.eligible(state.candidate.release, state, context);
  }

  confirmCandidateHealthy(appId: string, expectedReleaseId: string, context?: OtaUserContext, expectedManifestId?: string): boolean {
    this.validateContext(context);
    const state = this.contextState(appId, context);
    if (state === null) return false;
    const candidate = state.candidate;
    if (candidate === undefined) return state.current?.releaseId === expectedReleaseId && (expectedManifestId === undefined || state.current?.manifestId === expectedManifestId);
    if (candidate.status !== 'trial' || candidate.release.releaseId !== expectedReleaseId || (expectedManifestId !== undefined && candidate.release.manifestId !== expectedManifestId) || !this.eligible(candidate.release, state, context)) return false;
    const manifest = this.readManifest(appId, candidate.release.manifestId ?? '');
    if (manifest === null || !this.manifestObjectsUsable(appId, manifest.bundles) || !this.sidecars.verifyBound(appId, manifest)) return false;
    const former = state.current;
    state.current = candidate.release;
    if (former?.releaseId !== candidate.release.releaseId) state.previous = former;
    state.candidate = undefined;
    state.generation += 1;
    this.writeState(state, context, state.lastDecision);
    this.pruneApp(appId);
    return true;
  }

  discardCandidate(appId: string, expectedReleaseId?: string, context?: OtaUserContext, expectedManifestId?: string): boolean {
    this.validateContext(context);
    const state = this.contextState(appId, context);
    if (state?.candidate === undefined || (expectedReleaseId !== undefined && state.candidate.release.releaseId !== expectedReleaseId) || (expectedManifestId !== undefined && state?.candidate?.release.manifestId !== expectedManifestId)) return false;
    state.candidate = undefined;
    state.generation += 1;
    if (state.current === undefined) this.removeIfPresent(this.statePath(appId));
    else this.writeState(state, context, state.lastDecision);
    this.pruneApp(appId);
    return true;
  }

  capturePrewarmTicket(appId: string, context: OtaUserContext): OtaPrewarmTicket {
    this.validateContext(context);
    const state = this.contextState(appId, context);
    return { navigationSessionID: '', sourceSnapshotID: '', identityEpoch: context.identityEpoch,
      decision: state?.lastDecision, currentReleaseId: state?.current?.releaseId, currentManifestId: state?.current?.manifestId,
      candidateReleaseId: state?.candidate?.release.releaseId, candidateManifestId: state?.candidate?.release.manifestId };
  }

  validatePrewarmTicket(appId: string, ticket: OtaPrewarmTicket, context: OtaUserContext): void {
    this.validateContext(context);
    if (ticket.identityEpoch !== context.identityEpoch) throw new Error('stale_identity');
    const state = this.contextState(appId, context);
    const sameDecision = ticket.decision === undefined ? state?.lastDecision === undefined : OtaSelection.sameDecision(state?.lastDecision, ticket.decision);
    if (!sameDecision) throw new Error('stale_decision');
    if (ticket.navigationSnapshotID === undefined && (state?.current?.releaseId !== ticket.currentReleaseId ||
      state?.current?.manifestId !== ticket.currentManifestId || state?.candidate?.release.releaseId !== ticket.candidateReleaseId ||
      state?.candidate?.release.manifestId !== ticket.candidateManifestId)) throw new Error('stale_prewarm_release');
  }

  /** 只为真实消费重新取得页面 lease；旧预热 lease 的所有权仍属于 Broker。 */
  async claimPrewarmedBundleLease(warm: PreparedPageBundle, context: OtaUserContext, isClaimActive: () => boolean): Promise<PreparedPageBundle> {
    const ticket = warm.prewarm;
    if (ticket === undefined || warm.manifestId === undefined) throw new Error('invalid_prewarm_ticket');
    this.validatePrewarmTicket(warm.lynxAppId, ticket, context);
    const manifest = this.readManifest(warm.lynxAppId, warm.manifestId);
    if (manifest === null || manifest.releaseId !== warm.releaseId) throw new Error('stale_prewarm_release');
    const ref: OtaReleaseRef = { kind: 'downloaded', releaseId: warm.releaseId, manifestId: warm.manifestId, selection: warm.selection };
    const validationLease = this.createManifestLease(warm.lynxAppId, warm.manifestId, ref.selection);
    let claimed: PreparedPageBundle | null = null;
    try {
      await this.validateReadManifest(warm.lynxAppId, manifest, context, true);
      await this.validatePrewarmedBytes(warm, context, isClaimActive);
      this.validatePrewarmTicket(warm.lynxAppId, ticket, context);
      if (!isClaimActive()) throw new Error('stale_prewarm_source');
      const live = this.contextState(warm.lynxAppId, context);
      const staged = warm.source === 'prewarm_staged';
      if (staged) {
        if (context.selectionEnabled && (!OtaSelection.compatible(ref.selection, context) || ticket.selectionDecision === undefined ||
          ticket.selectionDecision.action !== 'use_release' || ticket.selectionDecision.targetReleaseId !== warm.releaseId ||
          ticket.selectionDecision.clientContextKey !== context.clientContextKey || ticket.selectionDecision.audienceKey !== context.audienceKey ||
          ticket.selectionDecision.policyRevision !== ref.selection?.policyRevision)) throw new Error('stale_decision');
        if (ticket.selectionDecision !== undefined && live?.lastDecision !== undefined &&
          OtaUserContext.compareDecimal(ticket.selectionDecision.policyRevision, live.lastDecision.policyRevision) < 0) throw new Error('stale_decision');
      } else {
        if (live === null || !this.eligible(ref, live, context)) throw new Error('stale_prewarm_release');
        if (ticket.navigationSnapshotID === undefined) {
          const target = warm.source === 'candidate_pending' || warm.source === 'candidate_trial' ? live.candidate?.release : this.effectiveRef(live, context);
          if (target?.releaseId !== ref.releaseId || target.manifestId !== ref.manifestId) throw new Error('stale_prewarm_release');
        }
      }
      claimed = this.acquireBundleLease(ref, warm.lynxAppId, warm.bundleName, context);
      if (claimed === null || claimed.sha256 !== warm.sha256 || claimed.actualSizeBytes !== warm.actualSizeBytes) throw new Error('stale_prewarm_bundle');
      if (warm.bytes !== undefined) claimed.bytes = warm.bytes;
      // 页面 lease 已建立，末端来源/epoch/decision 门禁到 State rename 之间不再 await。
      this.validatePrewarmTicket(warm.lynxAppId, ticket, context);
      if (!isClaimActive()) throw new Error('stale_prewarm_source');
      if (staged) {
        const next: OtaReleaseState = { schemaVersion: ContentAddressedOtaStore.STORE_SCHEMA_VERSION,
          env: manifest.env, hostApp: manifest.hostApp, lynxAppId: warm.lynxAppId, platform: manifest.platform,
          generation: (live?.generation ?? 0) + 1, current: live?.current, previous: live?.previous,
          candidate: live?.candidate, selectionSchemaVersion: context.selectionEnabled ? 1 : live?.selectionSchemaVersion,
          lastDecision: ticket.selectionDecision ?? live?.lastDecision };
        if (this.config.candidateActivationEnabled) {
          const now = new Date().getTime();
          next.candidate = { release: ref, status: 'trial', failureCount: 0, createdAt: now, trialStartedAt: now };
          claimed.source = 'candidate_trial';
        } else {
          if (live?.current?.releaseId !== ref.releaseId || live?.current?.manifestId !== ref.manifestId) next.previous = live?.current;
          next.current = ref;
          next.candidate = undefined;
          claimed.source = 'ota_current';
        }
        // 写入新决定由本次真实 consume 授权；回调仍复核捕获的旧决定，避免覆盖并发同步。
        this.writeState(next, context, ticket.decision);
      } else if ((warm.source === 'candidate_pending' || warm.source === 'candidate_trial') &&
        live?.candidate?.release.releaseId === ref.releaseId && live.candidate.release.manifestId === ref.manifestId) {
        if (live.candidate.status === 'pending') {
          live.candidate.status = 'trial';
          live.candidate.trialStartedAt = new Date().getTime();
          live.generation += 1;
          this.writeState(live, context, live.lastDecision);
        }
        claimed.source = 'candidate_trial';
      } else {
        claimed.source = 'ota_current';
      }
      return claimed;
    } catch (error) { claimed?.lease?.close(); throw (error as Error); }
    finally { validationLease.close(); }
  }

  private async validatePrewarmedBytes(warm: PreparedPageBundle, context: OtaUserContext, isClaimActive: () => boolean): Promise<void> {
    if (warm.bytes === undefined) return;
    if (warm.bytes.byteLength !== warm.actualSizeBytes) throw new Error('stale_prewarm_bundle');
    const digest = cryptoFramework.createMd('SHA256');
    for (let offset = 0; offset < warm.bytes.byteLength; offset += 64 * 1024) {
      await digest.update({ data: new Uint8Array(warm.bytes, offset, Math.min(64 * 1024, warm.bytes.byteLength - offset)) });
      this.validateContext(context);
      if (!isClaimActive()) throw new Error('stale_prewarm_source');
    }
    const bytes = (await digest.digest()).data;
    let hex = '';
    bytes.forEach((value: number) => { hex += value.toString(16).padStart(2, '0'); });
    if (`sha256:${hex}`.toLowerCase() !== warm.sha256.toLowerCase()) throw new Error('stale_prewarm_bundle');
  }

  /** 在调用线程同步受理失败身份；队列等待期间页面 Snapshot 可以正常退休。 */
  captureFailedRelease(appId: string, releaseId: string, manifestId: string | undefined, candidate: boolean, context: OtaUserContext): OtaFailedReleaseTicket {
    this.validateContext(context);
    const state = this.contextState(appId, context);
    const ref = candidate ? state?.candidate?.release : state?.current;
    if (state === null || ref?.kind !== 'downloaded' || ref.releaseId !== releaseId || ref.manifestId === undefined ||
      (manifestId !== undefined && ref.manifestId !== manifestId) || (candidate && state.candidate?.status !== 'trial')) throw new Error('stale_decision');
    const manifest = this.readManifest(appId, ref.manifestId);
    if (manifest === null || manifest.releaseId !== releaseId) throw new Error('stale_decision');
    return { lynxAppId: appId, releaseId: releaseId, manifestId: ref.manifestId, candidate: candidate, identityEpoch: context.identityEpoch,
      decision: state.lastDecision, lease: this.createManifestLease(appId, ref.manifestId, ref.selection) };
  }

  validateFailedRelease(ticket: OtaFailedReleaseTicket, context: OtaUserContext): void {
    this.validateContext(context);
    if (ticket.identityEpoch !== context.identityEpoch) throw new Error('stale_identity');
    const state = this.contextState(ticket.lynxAppId, context);
    const ref = ticket.candidate ? state?.candidate?.release : state?.current;
    const sameDecision = ticket.decision === undefined ? state?.lastDecision === undefined : OtaSelection.sameDecision(state?.lastDecision, ticket.decision);
    if (!sameDecision || ref?.releaseId !== ticket.releaseId || ref.manifestId !== ticket.manifestId ||
      (ticket.candidate && state?.candidate?.status !== 'trial')) throw new Error('stale_decision');
    const manifest = this.readManifest(ticket.lynxAppId, ticket.manifestId);
    if (manifest === null || manifest.releaseId !== ticket.releaseId) throw new Error('stale_decision');
  }

  /** 只读取 current；embedded current 返回 null，由 Registry 直接读取 rawfile。 */
  acquireCurrentBundleLease(lynxAppId: string, bundleName: string, context?: OtaUserContext): PreparedPageBundle | null {
    this.validateContext(context);
    const state = this.contextState(lynxAppId, context);
    if (state === null) return null;
    const ref = this.effectiveRef(state, context);
    if (ref === undefined || ref.kind !== 'downloaded') return null;
    try { return this.acquireBundleLease(ref, lynxAppId, bundleName, context); }
    catch (error) { return null; }
  }

  hasDownloadedCurrent(lynxAppId: string, context?: OtaUserContext): boolean {
    const state = this.contextState(lynxAppId, context);
    if (state === null) return false;
    const ref = this.effectiveRef(state, context);
    return ref !== undefined && ref.kind === 'downloaded';
  }

  /** 按固定 Release 读取 Bundle；用于同一导航 session 继承旧 Manifest。 */
  acquireBundleLeaseForRelease(lynxAppId: string, releaseId: string, bundleName: string, manifestId: string = '',
    context?: OtaUserContext): PreparedPageBundle | null {
    this.validateContext(context);
    if (manifestId.trim().length > 0 && !context?.selectionEnabled) {
      const pinnedRef: OtaReleaseRef = { kind: 'downloaded', releaseId: releaseId, manifestId: manifestId };
      return this.acquireBundleLease(pinnedRef, lynxAppId, bundleName);
    }
    const state = this.contextState(lynxAppId, context);
    if (state === null) return null;
    this.ensureScope(state, lynxAppId);
    if (manifestId.length > 0 && this.activeLeases.has(this.leaseKey(lynxAppId, manifestId))) {
      const pinned: OtaReleaseRef = { kind: 'downloaded', releaseId: releaseId, manifestId: manifestId,
        selection: ContentAddressedOtaStore.leasedSelections.get(this.leaseKey(lynxAppId, manifestId)) };
      if (this.eligible(pinned, state, context)) return this.acquireBundleLease(pinned, lynxAppId, bundleName, context);
    }
    const ref = [state.current, state.previous, state.candidate?.release]
      .find((item: OtaReleaseRef | undefined) => item !== undefined && item.releaseId === releaseId &&
        (manifestId.length === 0 || item.manifestId === manifestId));
    if (ref === undefined) return null;
    if (manifestId.length > 0 && ref.manifestId !== manifestId) return null;
    if (!this.eligible(ref, state, context)) return null;
    return this.acquireBundleLease(ref, lynxAppId, bundleName, context);
  }

  /** 为 NavigationSnapshot 建立独立 Manifest lease，不依赖某一个页面 Bundle。 */
  acquireReleaseLease(lynxAppId: string, releaseId: string, manifestId: string = '', context?: OtaUserContext): OtaBundleLease | null {
    this.validateContext(context);
    const state = this.contextState(lynxAppId, context);
    if (state === null) return null;
    this.ensureScope(state, lynxAppId);
    const ref = [state.current, state.previous, state.candidate?.release]
      .find((item: OtaReleaseRef | undefined) => item !== undefined && item.releaseId === releaseId &&
        (manifestId.length === 0 || item.manifestId === manifestId));
    if (ref === undefined || ref.kind !== 'downloaded' || ref.manifestId === undefined) return null;
    if (!this.eligible(ref, state, context)) return null;
    if (manifestId.trim().length > 0 && ref.manifestId !== manifestId) return null;
    const manifest = this.readManifest(lynxAppId, ref.manifestId);
    if (manifest === null || !this.manifestObjectsUsable(lynxAppId, manifest.bundles) ||
      !this.sidecars.verifyBound(lynxAppId, manifest)) return null;
    return this.createManifestLease(lynxAppId, ref.manifestId, ref.selection);
  }

  /** 缺包/校验失败时只修复指定 App ID。 */
  async ensureBundleReady(
    lynxAppId: string,
    bundleName: string,
    signal: OtaPrepareSignal,
    context?: OtaUserContext,
    markTrial: boolean = true
  ): Promise<PreparedPageBundle> {
    signal.throwIfCancelled();
    this.validateContext(context);
    const current = this.acquireCurrentBundleLease(lynxAppId, bundleName, context);
    if (current !== null) {
      if (!markTrial && context !== undefined) {
        try { current.prewarm = this.capturePrewarmTicket(lynxAppId, context); }
        catch (error) { current.lease?.close(); throw (error as Error); }
      }
      return current;
    }
    const warmTicket = !markTrial && context !== undefined ? this.capturePrewarmTicket(lynxAppId, context) : undefined;
    const selected = await this.api.fetchLatestSelection(lynxAppId, signal, context);
    signal.throwIfCancelled();
    this.validateContext(context);
    if (markTrial && context?.selectionEnabled) this.recordDecision(lynxAppId, selected, context);
    if (selected.release === undefined) throw new Error('no_compatible_release');
    await this.install(selected.release, signal, context, !markTrial);
    signal.throwIfCancelled();
    let repaired: PreparedPageBundle | null;
    if (markTrial) {
      repaired = this.acquireCandidateTrialBundleLease(lynxAppId, bundleName, context) ?? this.acquireCurrentBundleLease(lynxAppId, bundleName, context);
    } else {
      if (warmTicket !== undefined && context !== undefined) this.validatePrewarmTicket(lynxAppId, warmTicket, context);
      const ref: OtaReleaseRef = { kind: 'downloaded', releaseId: selected.release.releaseId,
        manifestId: this.manifestId(selected.release), selection: context?.selectionEnabled ? OtaSelection.fromRelease(selected.release, context) : undefined };
      repaired = this.acquireBundleLease(ref, lynxAppId, bundleName, context);
      if (repaired !== null) {
        repaired.source = 'prewarm_staged';
        repaired.prewarm = warmTicket;
        if (warmTicket !== undefined && context?.selectionEnabled) warmTicket.selectionDecision = OtaSelection.decision(selected, context);
        try {
          this.retireRecoveredTransactions(lynxAppId);
          this.sidecars.retireTransactions(lynxAppId);
          this.pruneApp(lynxAppId);
        } catch (error) { repaired.lease?.close(); throw (error as Error); }
      }
    }
    if (repaired === null) {
      throw new Error(`${markTrial ? 'Release 已激活' : '预热 Release 已下载'}但 Bundle 无法建立 lease：${lynxAppId}/${bundleName}`);
    }
    return repaired;
  }

  /**
   * 安装完整 Release Snapshot。
   *
   * 服务端 changedBundles 是完整快照。每个 artifact 先按 SHA 查 CAS；命中就直接复用，
   * 未命中才下载到 transactions/<tx>/.part，校验后原子发布对象，最后写 Manifest 与 State。
   */
  async install(snapshot: OtaReleaseSnapshot, signal: OtaPrepareSignal, context?: OtaUserContext, prewarmOnly: boolean = false): Promise<void> {
    this.validateContext(context);
    let selected: OtaStoredSelection | undefined;
    let decision: OtaLastDecision | undefined;
    if (context?.selectionEnabled) {
      const value: OtaLatestSelection = { release: snapshot };
      selected = OtaSelection.fromRelease(snapshot, context);
      decision = prewarmOnly ? this.contextState(snapshot.lynxAppId, context)?.lastDecision : OtaSelection.decision(value, context);
      if (!prewarmOnly) this.recordDecision(snapshot.lynxAppId, value, context);
      if (!OtaSelection.compatible(selected, context)) throw new Error('incompatible_release');
    }
    this.validateSnapshot(snapshot);
    for (const artifact of snapshot.changedBundles) {
      await this.validateObjectAsync(snapshot.lynxAppId, artifact, true);
      signal.throwIfCancelled(); this.validateContext(context);
    }
    signal.throwIfCancelled();
    this.ensureAppDirectories(snapshot.lynxAppId);
    this.recoverTransactions(snapshot.lynxAppId);

    const oldState = this.readState(snapshot.lynxAppId);
    if (oldState !== null) {
      this.ensureScope(oldState, snapshot.lynxAppId);
      const target = this.config.candidateActivationEnabled ? (oldState.candidate?.release ?? oldState.current) : oldState.current;
      const currentManifest = target?.manifestId === undefined ? null :
        this.readManifest(snapshot.lynxAppId, target.manifestId);
      if (target?.kind === 'downloaded' && target.releaseId === snapshot.releaseId &&
        currentManifest !== null && this.sameSnapshot(currentManifest, snapshot) &&
        this.manifestObjectsUsable(snapshot.lynxAppId, snapshot.changedBundles, true) &&
        this.sidecars.verifyBound(snapshot.lynxAppId, currentManifest)) {
        this.retireRecoveredTransactions(snapshot.lynxAppId);
        this.sidecars.retireTransactions(snapshot.lynxAppId);
        this.pruneApp(snapshot.lynxAppId);
        this.lastOperation = 'already_active';
        return;
      }
    }

    if (snapshot.asyncBundleManifest !== undefined) {
      const mainMissingBytes = snapshot.changedBundles
        .filter((artifact: OtaBundleArtifact) => !this.hasUsableObject(snapshot.lynxAppId, artifact.bundleSha256, artifact.size, true))
        .reduce((total: number, artifact: OtaBundleArtifact) => total + (artifact.size ?? 0), 0);
      await this.sidecars.prepareAsync(snapshot.lynxAppId, snapshot.asyncBundleManifest,
        snapshot.changedBundles.map((bundle) => bundle.bundlePath), signal, context, mainMissingBytes);
    }
    signal.throwIfCancelled();
    this.validateContext(context);
    const targetManifestId = this.manifestId(snapshot);

    const reusableTargetObjects = snapshot.changedBundles
      .filter((artifact: OtaBundleArtifact) => this.hasUsableObject(snapshot.lynxAppId, artifact.bundleSha256, artifact.size, true))
      .map((artifact: OtaBundleArtifact) => artifact.bundleSha256);
    // 进程可能在 State 提交前被终止；保留事务索引声明的已发布对象，避免预检前 GC
    // 把仍可复用的 CAS Object 当作 orphan 删除。
    const recoveredObjectIds = this.transactionObjectIds(snapshot.lynxAppId);
    this.pruneApp(snapshot.lynxAppId, reusableTargetObjects.concat(recoveredObjectIds));
    const missingBytes = snapshot.changedBundles
      .filter((artifact: OtaBundleArtifact) => !this.hasUsableObject(snapshot.lynxAppId, artifact.bundleSha256, artifact.size, true))
      .reduce((total: number, artifact: OtaBundleArtifact) => total + (artifact.size ?? 0), 0);
    const requiredBytes = missingBytes + ContentAddressedOtaStore.METADATA_ALLOWANCE_BYTES +
      Math.max(ContentAddressedOtaStore.SAFETY_RESERVE_BYTES, Math.ceil(missingBytes * 0.1));
    const availableBytes = this.availableCapacity();
    if (availableBytes >= 0 && availableBytes < requiredBytes) {
      throw new Error(`OTA v3 预检空间不足：需要 ${requiredBytes} bytes，可用 ${availableBytes} bytes`);
    }

    const transaction = this.createTransactionDirectory(snapshot.lynxAppId);
    this.writeTextAtomic(`${transaction}/transaction.json`, JSON.stringify({
      schemaVersion: ContentAddressedOtaStore.STORE_SCHEMA_VERSION,
      lynxAppId: snapshot.lynxAppId,
      releaseId: snapshot.releaseId,
      manifestId: targetManifestId,
      objectIds: snapshot.changedBundles.map((item: OtaBundleArtifact) => item.bundleSha256)
    }));
    ContentAddressedOtaStore.runningTransactions.add(transaction);

    let downloadedCount = 0;
    let reusedCount = 0;
    try {
      for (let index = 0; index < snapshot.changedBundles.length; index += 1) {
        signal.throwIfCancelled();
        const artifact = snapshot.changedBundles[index];
        if (this.hasUsableObject(snapshot.lynxAppId, artifact.bundleSha256, artifact.size, true)) {
          reusedCount += 1;
          continue;
        }
        const part = `${transaction}/object-${index}.part`;
        const byteCount = await this.api.downloadBundleToFile(artifact.bundleUrl, part, signal, context);
        const digest = await hashOtaFile(part);
        signal.throwIfCancelled();
        this.validateCommit(snapshot.lynxAppId, context, decision);
        this.ensureDeclaredSize(byteCount, artifact);
        this.ensureExpectedSha(digest, artifact.bundleSha256, artifact.bundlePath);
        const objectPath = this.objectPath(snapshot.lynxAppId, artifact.bundleSha256);
        this.ensureParent(objectPath);
        if (this.hasUsableObject(snapshot.lynxAppId, artifact.bundleSha256, artifact.size, true)) {
          this.removeIfPresent(part);
          reusedCount += 1;
        } else {
          this.checkTestFault('before_object_publish');
          this.checkTestFault('enospc_object_publish');
          fs.renameSync(part, objectPath);
          // Bundle bytes 已经 fsync；跨目录 rename 还必须分别持久化源目录和目标目录，
          // 否则进程在这里被终止时，下一次启动可能看不到刚发布的 CAS Object。
          this.syncDirectory(transaction);
          this.syncDirectory(objectPath.substring(0, objectPath.lastIndexOf('/')));
          await this.pauseAtTestPoint('after_object_publish');
          this.checkTestFault('after_object_publish');
          await this.validateObjectAsync(snapshot.lynxAppId, artifact, true);
          signal.throwIfCancelled(); this.validateContext(context);
          downloadedCount += 1;
        }
      }

      await this.pauseAtTestPoint('after_objects_ready');
      this.checkTestFault('after_objects_ready');
      signal.throwIfCancelled();
      this.validateCommit(snapshot.lynxAppId, context, decision);
      const manifest: OtaLocalManifest = {
        schemaVersion: ContentAddressedOtaStore.STORE_SCHEMA_VERSION,
        manifestId: targetManifestId,
        env: snapshot.env,
        hostApp: snapshot.hostApp,
        lynxAppId: snapshot.lynxAppId,
        releaseId: snapshot.releaseId,
        platform: snapshot.platform,
        status: snapshot.status,
        bundles: snapshot.changedBundles.map((item: OtaBundleArtifact) => {
          return {
            pageId: item.pageId,
            bundlePath: item.bundlePath,
            bundleSha256: item.bundleSha256,
            bundleUrl: item.bundleUrl,
            size: item.size,
            objectId: item.bundleSha256
          } as OtaBundleArtifact;
        }),
        asyncBundleManifest: snapshot.asyncBundleManifest,
        installedAt: new Date().getTime()
      };
      this.checkTestFault('before_manifest_commit');
      this.checkTestFault('enospc_manifest_commit');
      this.writeTextAtomic(this.manifestPath(snapshot.lynxAppId, targetManifestId), JSON.stringify(manifest));
      for (const artifact of manifest.bundles) {
        await this.validateObjectAsync(snapshot.lynxAppId, artifact, true);
        signal.throwIfCancelled(); this.validateContext(context);
      }
      await this.sidecars.validateManifestObjects(snapshot.lynxAppId, manifest, true);
      signal.throwIfCancelled(); this.validateContext(context);
      this.verifyManifestObjects(snapshot.lynxAppId, manifest);
      await this.pauseAtTestPoint('after_manifest_commit');
      this.checkTestFault('after_manifest_commit');

      if (prewarmOnly) {
        // 事务索引持续保护 main/Async，直到 ensureBundleReady 同步取得预热页面 lease。
        this.validateCommit(snapshot.lynxAppId, context, decision);
        this.lastOperation = `prewarm:${snapshot.releaseId}:downloaded=${downloadedCount}:reused=${reusedCount}`;
        return;
      }

      // 所有 await 之后重新读 State；不能把下载前 oldState 的 previous 写回。
      await this.pauseAtTestPoint('before_state_commit');
      this.validateCommit(snapshot.lynxAppId, context, decision);
      const publishState = this.readState(snapshot.lynxAppId);
      const previous: OtaReleaseRef | undefined = publishState !== null &&
        publishState.current?.releaseId !== snapshot.releaseId ? publishState.current : publishState?.previous;
      const state: OtaReleaseState = {
        schemaVersion: ContentAddressedOtaStore.STORE_SCHEMA_VERSION,
        env: snapshot.env,
        hostApp: snapshot.hostApp,
        lynxAppId: snapshot.lynxAppId,
        platform: snapshot.platform,
        generation: (publishState?.generation ?? 0) + 1,
        current: { kind: 'downloaded', releaseId: snapshot.releaseId, manifestId: targetManifestId,
          selection: selected },
        previous: previous,
        candidate: undefined,
        selectionSchemaVersion: context?.selectionEnabled ? 1 : publishState?.selectionSchemaVersion,
        lastDecision: decision ?? publishState?.lastDecision
      };
      if (this.config.candidateActivationEnabled) {
        state.current = publishState?.current;
        state.previous = publishState?.previous;
        state.candidate = { release: { kind: 'downloaded', releaseId: snapshot.releaseId, manifestId: targetManifestId, selection: selected },
          status: 'pending', failureCount: 0, createdAt: new Date().getTime() };
      }
      // State 是唯一激活点，必须最后原子写入。
      this.checkTestFault('before_state_commit');
      this.checkTestFault('enospc_state_commit');
      this.writeState(state, context, decision);
      await this.pauseAtTestPoint('after_state_commit');
      this.validateContext(context);
      this.checkTestFault('after_state_commit_report_failure');
      this.removeIfPresent(transaction);
      this.retireRecoveredTransactions(snapshot.lynxAppId);
      this.sidecars.retireTransactions(snapshot.lynxAppId);
      this.pruneApp(snapshot.lynxAppId);
      this.lastOperation = `install:${snapshot.releaseId}:downloaded=${downloadedCount}:reused=${reusedCount}`;
    } catch (error) {
      // 保留 transaction.json 作为下一次进程启动的恢复索引；下次启动会先读取其中的
      // 已验证 Object ID，再清理 transaction，避免 force-stop 后丢掉可复用的 orphan。
      const failure = error as Error;
      if (failure.message === 'stale_identity' || failure.message === 'stale_decision') {
        this.removeIfPresent(transaction);
        this.pruneApp(snapshot.lynxAppId);
      }
      throw (error as Error);
    } finally {
      ContentAddressedOtaStore.runningTransactions.delete(transaction);
    }
  }

  rollback(lynxAppId: string, expectedReleaseId?: string, context?: OtaUserContext): boolean {
    this.validateContext(context);
    const state = this.contextState(lynxAppId, context);
    if (context?.selectionEnabled) {
      if (state === null) return false;
      const current = this.effectiveRef(state, context);
      if (expectedReleaseId !== undefined && current?.releaseId !== expectedReleaseId) throw new Error('stale_decision');
      let previous = state.previous;
      if (previous?.releaseId === current?.releaseId) previous = undefined;
      if (previous !== undefined && (!this.eligible(previous, state, context) || this.resolveRef(previous, lynxAppId) === null)) previous = undefined;
      state.current = previous ?? this.embeddedRef();
      state.previous = undefined;
      state.generation += 1;
      this.writeState(state, context);
      this.pruneApp(lynxAppId);
      // boolean 保留原接口的“恢复远程 previous”含义；false 也已原子写入 embedded。
      return previous !== undefined;
    }
    if (state === null) return false;
    if (expectedReleaseId !== undefined && state.current?.releaseId !== expectedReleaseId) throw new Error('stale_decision');
    if (state.previous === undefined || state.previous.kind !== 'downloaded') {
      state.current = this.embeddedRef(); state.generation += 1; this.writeState(state, context); return false;
    }
    this.ensureScope(state, lynxAppId);
    const restored = this.resolveRef(state.previous, lynxAppId);
    if (restored === null) return false;
    const next: OtaReleaseState = {
      schemaVersion: ContentAddressedOtaStore.STORE_SCHEMA_VERSION,
      env: state.env,
      hostApp: state.hostApp,
      lynxAppId: state.lynxAppId,
      platform: state.platform,
      generation: state.generation + 1,
      current: state.previous,
      previous: undefined,
      candidate: state.candidate
    };
    this.writeState(next);
    this.validatedObjects.clear();
    this.pruneApp(lynxAppId);
    this.lastOperation = `rollback:${restored.releaseId}`;
    return true;
  }

  deleteBundles(lynxAppId: string, context?: OtaUserContext): void {
    this.validateContext(context);
    this.ensureSafeAppId(lynxAppId);
    if (context?.selectionEnabled) {
      const state = this.contextState(lynxAppId, context) ?? this.emptyState(lynxAppId, context);
      state.current = this.embeddedRef();
      state.previous = undefined;
      state.candidate = undefined;
      state.generation += 1;
      state.lastDecision = { action: 'use_embedded', audienceKey: context.audienceKey, clientContextKey: context.clientContextKey,
        policyRevision: state.lastDecision?.policyRevision ?? '0', reason: 'local_delete' };
      this.writeState(state, context);
      this.pruneApp(lynxAppId);
      return;
    }
    this.removeIfPresent(this.statePath(lynxAppId));
    this.removeIfPresent(this.transactionRoot(lynxAppId));
    this.writeTextAtomic(this.purgeMarkerPath(lynxAppId), 'delete');
    this.pruneApp(lynxAppId);
    this.validatedObjects.clear();
    this.lastOperation = `delete:${lynxAppId}`;
  }

  deleteAllBundles(context?: OtaUserContext): void {
    this.validateContext(context);
    if (!this.exists(this.appsRoot())) return;
    fs.listFileSync(this.appsRoot()).forEach((name: string) => {
      if (!this.isValidAppId(name)) return;
      if (context?.selectionEnabled) { this.deleteBundles(name, context); return; }
      this.removeIfPresent(this.statePath(name));
      this.removeIfPresent(this.transactionRoot(name));
      this.writeTextAtomic(this.purgeMarkerPath(name), 'delete');
      this.pruneApp(name);
    });
    this.validatedObjects.clear();
    this.lastOperation = 'delete_all';
  }

  pruneAllUnreferencedReleases(context?: OtaUserContext): void {
    // 无 context 的调用仅用于 lease.close 后的维护，不包含身份敏感 State 变更。
    if (context !== undefined) this.validateContext(context);
    if (!this.exists(this.appsRoot())) return;
    fs.listFileSync(this.appsRoot()).forEach((name: string) => {
      if (this.isValidAppId(name)) this.pruneApp(name, this.transactionObjectIds(name));
    });
  }

  storageRoot(): string {
    return this.root;
  }

  /** 所有 App 在网络下载前先调用此同步提交；合法决定与引用 metadata 一次写入。 */
  recordDecision(lynxAppId: string, value: OtaLatestSelection, context: OtaUserContext): void {
    this.validateContext(context);
    if (!context.selectionEnabled) throw new Error('selection_context_required');
    this.ensureSafeAppId(lynxAppId);
    if ((value.release?.lynxAppId ?? value.directive?.lynxAppId) !== lynxAppId) throw new Error('invalid_selection_scope');
    const decision = OtaSelection.decision(value, context);
    const state = this.contextState(lynxAppId, context) ?? this.emptyState(lynxAppId, context);
    const old = state.lastDecision;
    if (old !== undefined && old.clientContextKey === context.clientContextKey &&
      OtaUserContext.compareDecimal(decision.policyRevision, old.policyRevision) < 0) throw new Error('stale_decision');
    if (value.release !== undefined) {
      const selected = OtaSelection.fromRelease(value.release, context);
      if (state.current !== undefined && state.current.releaseId === value.release.releaseId) state.current.selection = selected;
      if (state.previous?.releaseId === value.release.releaseId) state.previous.selection = selected;
    }
    state.selectionSchemaVersion = 1;
    state.lastDecision = decision;
    if (state.candidate !== undefined) {
      if (value.release?.releaseId === state.candidate.release.releaseId && value.release !== undefined) {
        state.candidate.release.selection = OtaSelection.fromRelease(value.release, context);
      }
      if (decision.action !== 'use_release' || decision.targetReleaseId !== state.candidate.release.releaseId ||
        !this.eligible(state.candidate.release, state, context)) state.candidate = undefined;
    }
    if (decision.action !== 'use_release') {
      if (state.current?.kind === 'downloaded') state.previous = state.current;
      state.current = this.embeddedRef();
    } else if (!this.eligible(state.current, state, context)) {
      const replacement = this.effectiveRef(state, context) ?? this.embeddedRef();
      const former = state.current;
      state.current = replacement;
      state.previous = former;
    }
    state.generation += 1;
    this.writeState(state, context);
  }

  /** 只整理元数据；不联网，不清理进程 SHA 缓存，不释放仍在显示的页面 lease。 */
  reconcileUserContext(context: OtaUserContext): void {
    this.validateContext(context);
    if (!context.selectionEnabled || !this.exists(this.appsRoot())) return;
    fs.listFileSync(this.appsRoot()).forEach((appId: string) => {
      if (!this.isValidAppId(appId)) return;
      const state = this.contextState(appId, context);
      if (state === null) return;
      const invalidCandidate = state.candidate !== undefined && !this.eligible(state.candidate.release, state, context);
      if (invalidCandidate) state.candidate = undefined;
      if (this.eligible(state.current, state, context)) {
        if (invalidCandidate) { state.generation += 1; this.writeState(state, context); }
        return;
      }
      const replacement = this.effectiveRef(state, context) ?? this.embeddedRef();
      state.previous = state.current;
      state.current = replacement;
      state.selectionSchemaVersion = 1;
      state.generation += 1;
      this.writeState(state, context);
    });
  }

  private validateContext(context: OtaUserContext | undefined): void {
    if (this.config.versionCode !== undefined && context === undefined) throw new Error('missing_captured_context');
    if (context !== undefined) this.identityBox.validate(context);
  }

  private validateCommit(appId: string, context: OtaUserContext | undefined, decision?: OtaLastDecision): void {
    this.validateContext(context);
    if (decision !== undefined && !OtaSelection.sameDecision(this.readState(appId)?.lastDecision, decision)) throw new Error('stale_decision');
  }

  private contextState(appId: string, context: OtaUserContext | undefined): OtaReleaseState | null {
    const state = this.readState(appId);
    if (state === null) return null;
    if (context?.selectionEnabled && (state.env !== context.env || state.hostApp !== context.hostApp || state.platform !== context.platform)) return null;
    this.ensureScope(state, appId);
    return state;
  }

  private emptyState(appId: string, context: OtaUserContext): OtaReleaseState {
    return { schemaVersion: 3, env: context.env, hostApp: context.hostApp, lynxAppId: appId, platform: context.platform,
      generation: 0, current: this.embeddedRef(), selectionSchemaVersion: 1 };
  }

  private embeddedRef(): OtaReleaseRef { return { kind: 'embedded', releaseId: '__embedded__' }; }

  private eligible(ref: OtaReleaseRef | undefined, state: OtaReleaseState, context: OtaUserContext | undefined): boolean {
    if (ref === undefined) return false;
    if (context === undefined || !context.selectionEnabled || ref.kind === 'embedded') return true;
    if (state.selectionSchemaVersion !== 1 || !OtaSelection.compatible(ref.selection, context)) return false;
    const decision = state.lastDecision;
    if (decision !== undefined && decision.audienceKey === context.audienceKey) {
      if (decision.action !== 'use_release') return false;
      if (ref.selection?.kind === 'gray' && decision.targetReleaseId !== ref.releaseId) return false;
    }
    return true;
  }

  private effectiveRef(state: OtaReleaseState, context: OtaUserContext | undefined): OtaReleaseRef | undefined {
    if (this.eligible(state.current, state, context)) return state.current;
    const previous = state.previous;
    if (previous !== undefined && previous.selection?.kind === 'full' && this.eligible(previous, state, context)) return previous;
    return undefined;
  }

  storageSnapshot(maxFilesPerTree: number = 2_000): OtaStorageSnapshot {
    if (maxFilesPerTree <= 0) throw new Error('maxFilesPerTree 必须大于 0');
    const rootScan = this.scanTree(this.root, maxFilesPerTree);
    const apps: OtaStorageAppSnapshot[] = [];
    if (this.exists(this.appsRoot())) {
      fs.listFileSync(this.appsRoot())
        .filter((name: string) => this.isValidAppId(name) && this.isDirectory(this.appDirectory(name)))
        .sort()
        .forEach((name: string) => apps.push(this.snapshotApp(name, maxFilesPerTree)));
    }
    return {
      rootPath: this.root,
      totalBytes: rootScan.totalBytes,
      fileCount: rootScan.fileCount,
      generatedAt: new Date().getTime(),
      apps: apps
    };
  }

  private snapshotApp(appId: string, maxFilesPerTree: number): OtaStorageAppSnapshot {
    const state = this.tryReadState(appId);
    const leased = this.activeLeasedManifestIds(appId);
    const releases: OtaStorageReleaseSnapshot[] = [];
    const manifestRoot = this.manifestsRoot(appId);
    if (this.exists(manifestRoot)) {
      fs.listFileSync(manifestRoot)
        .filter((name: string) => name.endsWith('.json') && this.isRegularFile(`${manifestRoot}/${name}`))
        .sort()
        .forEach((name: string) => {
          const manifestId = name.substring(0, name.length - 5);
          const manifest = this.readManifest(appId, manifestId);
          if (manifest === null) return;
          const roles: OtaStorageReleaseRole[] = [];
          if (state?.current?.manifestId === manifestId) roles.push(OtaStorageReleaseRole.CURRENT);
          if (state?.previous?.manifestId === manifestId) roles.push(OtaStorageReleaseRole.PREVIOUS);
          if (state?.candidate?.release.manifestId === manifestId) roles.push(OtaStorageReleaseRole.CANDIDATE);
          if (leased.has(manifestId)) roles.push(OtaStorageReleaseRole.LEASED);
          if (roles.length === 0) roles.push(OtaStorageReleaseRole.ORPHAN);
          const path = `${manifestRoot}/${name}`;
          const stat = fs.statSync(path);
          releases.push({
            releaseId: manifest.releaseId,
            roles: roles,
            totalBytes: stat.size,
            fileCount: 1,
            manifestValid: true,
            files: [{
              relativePath: name,
              byteCount: stat.size,
              modifiedAt: Number(stat.mtime ?? 0)
            }],
            truncated: false,
            manifestId: manifestId,
            bundleCount: manifest.bundles.length,
            objectIds: manifest.bundles.map((item: OtaBundleArtifact) => item.objectId ?? item.bundleSha256),
            asyncManifestId: manifest.asyncBundleManifest?.sha256
          });
        });
    }
    const objectFiles: string[] = [];
    const objectRoot = this.objectsRoot(appId);
    if (this.exists(objectRoot)) this.collectFiles(objectRoot, objectFiles);
    const objectBytes = objectFiles.reduce((total: number, path: string) => total + fs.statSync(path).size, 0);
    const manifestBytes = releases.reduce((total: number, item: OtaStorageReleaseSnapshot) => total + item.totalBytes, 0);
    const appScan = this.scanTree(this.appDirectory(appId), maxFilesPerTree);
    const stateSnapshot: OtaStorageStateSnapshot | undefined = state === null ? undefined : {
      generation: state.generation,
      currentReleaseId: state.current?.releaseId ?? '',
      currentKind: state.current?.kind ?? 'none',
      candidateReleaseId: state.candidate?.release.releaseId,
      candidateManifestId: state.candidate?.release.manifestId,
      candidateStatus: state.candidate?.status,
      previousReleaseId: state.previous?.releaseId,
      previousKind: state.previous?.kind,
      currentManifestId: state.current?.manifestId,
      previousManifestId: state.previous?.manifestId
    };
    return {
      appId: appId,
      state: stateSnapshot,
      releases: releases,
      staging: this.snapshotTransactions(appId, maxFilesPerTree),
      totalBytes: appScan.totalBytes,
      fileCount: appScan.fileCount,
      objectCount: objectFiles.length,
      objectBytes: objectBytes,
      manifestBytes: manifestBytes,
      lastOperation: this.lastOperation
    };
  }

  private snapshotTransactions(appId: string, maxFilesPerTree: number): OtaStorageStagingSnapshot[] {
    const result: OtaStorageStagingSnapshot[] = [];
    const root = this.transactionRoot(appId);
    if (!this.exists(root)) return result;
    fs.listFileSync(root).filter((name: string) => this.isDirectory(`${root}/${name}`)).sort().forEach((name: string) => {
      const scan = this.scanTree(`${root}/${name}`, maxFilesPerTree);
      result.push({
        transactionName: name,
        totalBytes: scan.totalBytes,
        fileCount: scan.fileCount,
        files: scan.files,
        truncated: scan.truncated
      });
    });
    return result;
  }

  private acquireBundleLease(ref: OtaReleaseRef, appId: string, bundleName: string, context?: OtaUserContext): PreparedPageBundle | null {
    const prepared = this.resolveBundle(ref, appId, bundleName, true);
    if (prepared === null || ref.kind !== 'downloaded') return prepared;
    const manifestId = ref.manifestId ?? ref.releaseId;
    prepared.lease = this.createManifestLease(appId, manifestId, ref.selection);
    try {
      const manifest = this.readManifest(appId, manifestId);
      if (manifest === null) throw new Error('页面主 Manifest 缺失');
      if (manifest.asyncBundleManifest !== undefined) {
        const resources = this.sidecars.preparePage(appId, manifest, prepared.bundleName);
        prepared.asyncResolver = resources.asyncResolver;
      }
    } catch (error) {
      prepared.lease.close();
      throw (error as Error);
    }
    prepared.selection = ref.selection;
    prepared.identityEpoch = context?.identityEpoch;
    prepared.userIdentityEpoch = context?.identityEpoch;
    prepared.selectionKind = ref.selection?.kind;
    prepared.releaseSequence = ref.selection?.releaseSequence;
    prepared.policyRevision = ref.selection?.policyRevision;
    return prepared;
  }

  private createManifestLease(appId: string, manifestId: string, selection?: OtaStoredSelection): OtaBundleLease {
    const key = this.leaseKey(appId, manifestId);
    this.activeLeases.set(key, (this.activeLeases.get(key) ?? 0) + 1);
    if (selection !== undefined) ContentAddressedOtaStore.leasedSelections.set(key, selection);
    return new OtaBundleLease(() => {
      const remaining = (this.activeLeases.get(key) ?? 0) - 1;
      if (remaining > 0) this.activeLeases.set(key, remaining);
      else { this.activeLeases.delete(key); ContentAddressedOtaStore.leasedSelections.delete(key); }
      this.leaseReleaseScheduler?.();
    });
  }

  private resolveBundle(
    ref: OtaReleaseRef,
    appId: string,
    bundleName: string,
    verify: boolean
  ): PreparedPageBundle | null {
    if (ref.kind !== 'downloaded' || ref.manifestId === undefined) return null;
    const manifest = this.readManifest(appId, ref.manifestId);
    if (manifest === null || manifest.releaseId !== ref.releaseId) return null;
    const normalized = this.normalizeBundlePath(bundleName);
    let artifact = manifest.bundles.find((item: OtaBundleArtifact) => item.bundlePath === normalized);
    if (artifact === undefined && !normalized.includes('/')) {
      const matches = manifest.bundles.filter((item: OtaBundleArtifact) => item.bundlePath.substring(item.bundlePath.lastIndexOf('/') + 1) === normalized);
      if (matches.length === 1) artifact = matches[0];
    }
    if (artifact === undefined) return null;
    const objectId = artifact.objectId ?? artifact.bundleSha256;
    const filePath = this.objectPath(appId, objectId);
    if (!this.isRegularFile(filePath)) return null;
    if (verify) {
      this.verifyCurrentObject(filePath, appId, ref.manifestId, artifact);
    }
    return {
      lynxAppId: appId,
      bundleName: artifact.bundlePath,
      filePath: filePath,
      releaseId: ref.releaseId,
      manifestId: ref.manifestId,
      sha256: artifact.bundleSha256,
      actualSizeBytes: fs.statSync(filePath).size,
      source: 'ota_current'
    };
  }

  private resolveRef(ref: OtaReleaseRef, appId: string): PreparedPageBundle | null {
    if (ref.kind !== 'downloaded' || ref.manifestId === undefined) return null;
    const manifest = this.readManifest(appId, ref.manifestId);
    if (manifest === null || !this.manifestObjectsUsable(appId, manifest.bundles) ||
      !this.sidecars.verifyBound(appId, manifest)) return null;
    return {
      lynxAppId: appId,
      bundleName: manifest.bundles[0]?.bundlePath ?? '',
      filePath: this.objectPath(appId, manifest.bundles[0]?.objectId ?? manifest.bundles[0]?.bundleSha256 ?? ''),
      releaseId: manifest.releaseId,
      manifestId: ref.manifestId,
      sha256: manifest.bundles[0]?.bundleSha256 ?? '',
      source: 'ota_current'
    };
  }

  private manifestObjectsUsable(appId: string, bundles: OtaBundleArtifact[], forceHash: boolean = false): boolean {
    return bundles.every((item: OtaBundleArtifact) => this.hasUsableObject(appId,
      item.objectId ?? item.bundleSha256, item.size, forceHash));
  }

  private verifyManifestObjects(appId: string, manifest: OtaLocalManifest): void {
    if (!manifest.bundles.every((item: OtaBundleArtifact) =>
      this.hasUsableObject(appId, item.objectId ?? item.bundleSha256, item.size, true))) {
      throw new Error('Manifest 对象校验失败');
    }
    if (!this.sidecars.verifyBound(appId, manifest)) throw new Error('Manifest 附属资源校验失败');
  }

  private hasUsableObject(appId: string, objectId: string, expectedSize: number | undefined,
    forceHash: boolean = false): boolean {
    if (!/^sha256:[0-9a-fA-F]{64}$/.test(objectId) || expectedSize === undefined) return false;
    const path = this.objectPath(appId, objectId);
    if (!this.isRegularFile(path)) return false;
    const stat = fs.statSync(path);
    if (stat.size !== expectedSize) return false;
    const key = `${appId}|${objectId.toLowerCase()}|${stat.size}|${stat.mtime}|${stat.ctime}|${stat.ino}`;
    return this.validatedObjects.has(key);
  }

  private verifyCurrentObject(filePath: string, appId: string, manifestId: string, artifact: OtaBundleArtifact): void {
    if (!this.hasUsableObject(appId, artifact.objectId ?? artifact.bundleSha256, artifact.size)) {
      throw new Error(`Bundle SHA-256 校验失败：${manifestId}/${artifact.bundlePath}`);
    }
  }

  private readManifest(appId: string, manifestId: string): OtaLocalManifest | null {
    if (!/^sha256:[0-9a-fA-F]{64}$/.test(manifestId)) return null;
    const path = this.manifestPath(appId, manifestId);
    if (!this.isRegularFile(path)) return null;
    try {
      const manifest = OtaJson.parseLocalManifest(fs.readTextSync(path));
      if (manifest.schemaVersion !== ContentAddressedOtaStore.STORE_SCHEMA_VERSION || manifest.manifestId !== manifestId) return null;
      if (manifest.lynxAppId !== appId || manifest.status !== 'ACTIVE') return null;
      if (manifest.env !== this.config.environment || manifest.hostApp !== this.config.hostApp || manifest.platform !== this.config.requestPlatform()) return null;
      return manifest;
    } catch (error) {
      return null;
    }
  }

  private writeState(state: OtaReleaseState, context?: OtaUserContext, decision?: OtaLastDecision): void {
    this.writeTextAtomic(this.statePath(state.lynxAppId), JSON.stringify({
      schemaVersion: ContentAddressedOtaStore.STORE_SCHEMA_VERSION,
      env: state.env,
      hostApp: state.hostApp,
      lynxAppId: state.lynxAppId,
      platform: state.platform,
      generation: state.generation,
      current: state.current,
      previous: state.previous,
      candidate: state.candidate,
      selectionSchemaVersion: state.selectionSchemaVersion,
      lastDecision: state.lastDecision
    }), () => this.validateCommit(state.lynxAppId, context, decision));
  }

  private readState(appId: string): OtaReleaseState | null {
    const path = this.statePath(appId);
    if (!this.isRegularFile(path)) return null;
    return OtaJson.parseState(fs.readTextSync(path));
  }

  private tryReadState(appId: string): OtaReleaseState | null {
    try { return this.readState(appId); } catch (error) { return null; }
  }

  private pruneApp(appId: string, preservedObjectIds: string[] = []): void {
    const app = this.appDirectory(appId);
    if (!this.isDirectory(app)) return;
    const purgeRequested = this.exists(this.purgeMarkerPath(appId));
    let state: OtaReleaseState | null;
    try {
      state = this.readState(appId);
    } catch (error) {
      return;
    }
    const retainedManifests = new Set<string>();
    this.transactionManifestIds(appId).forEach((manifestId: string) => retainedManifests.add(manifestId));
    const retainedObjects = new Set<string>();
    const rootedMainManifests: OtaLocalManifest[] = [];
    preservedObjectIds.forEach((objectId: string) => retainedObjects.add(objectId));
    this.transactionObjectIds(appId).forEach((objectId: string) => retainedObjects.add(objectId));
    const retain = (ref: OtaReleaseRef | undefined): boolean => {
      if (ref === undefined || ref.kind !== 'downloaded' || ref.manifestId === undefined) return true;
      retainedManifests.add(ref.manifestId);
      const manifest = this.readManifest(appId, ref.manifestId);
      if (manifest === null) return false;
      rootedMainManifests.push(manifest);
      for (const item of manifest.bundles) {
        const objectId = item.objectId ?? item.bundleSha256;
        if (!this.hasUsableObject(appId, objectId, item.size, true)) return false;
        retainedObjects.add(objectId);
      }
      return true;
    };
    if (!retain(state?.current) || !retain(state?.previous) || !retain(state?.candidate?.release)) return;
    const activeLeaseManifestIds = this.activeLeasedManifestIds(appId);
    let leaseRootsValid = true;
    activeLeaseManifestIds.forEach((manifestId: string) => {
      retainedManifests.add(manifestId);
      const manifest = this.readManifest(appId, manifestId);
      if (manifest === null) { leaseRootsValid = false; return; }
      rootedMainManifests.push(manifest);
      for (const item of manifest.bundles) {
        const objectId = item.objectId ?? item.bundleSha256;
        if (!this.hasUsableObject(appId, objectId, item.size, true)) { leaseRootsValid = false; return; }
        retainedObjects.add(objectId);
      }
    });
    if (!leaseRootsValid) return;
    try { this.sidecars.prune(appId, rootedMainManifests); }
    catch (error) { console.warn('附属资源 rooted Manifest 校验失败，本轮不清理'); return; }
    const manifestRoot = this.manifestsRoot(appId);
    if (this.exists(manifestRoot)) {
      fs.listFileSync(manifestRoot).filter((name: string) => name.endsWith('.json')).forEach((name: string) => {
        if (!retainedManifests.has(name.substring(0, name.length - 5))) this.removeIfPresent(`${manifestRoot}/${name}`);
      });
    }
    const objectFiles: string[] = [];
    this.collectFiles(this.objectsRoot(appId), objectFiles);
    objectFiles.forEach((path: string) => {
      const hex = path.substring(path.lastIndexOf('/') + 1).replace('.lynx.bundle', '');
      const objectId = `sha256:${hex}`;
      if (!retainedObjects.has(objectId)) this.removeIfPresent(path);
    });
    this.removeEmptyDirectories(this.objectsRoot(appId), this.objectsRoot(appId));
    if (purgeRequested && activeLeaseManifestIds.size === 0) this.removeIfPresent(this.purgeMarkerPath(appId));
  }

  private recoverTransactions(appId: string): void {
    const root = this.transactionRoot(appId);
    if (!this.exists(root)) {
      this.ensureDirectory(root);
      return;
    }
    fs.listFileSync(root).forEach((name: string) => {
      const transaction = `${root}/${name}`;
      if (ContentAddressedOtaStore.runningTransactions.has(transaction)) return;
      if (!this.isDirectory(transaction)) {
        this.removeIfPresent(transaction);
        return;
      }
      const marker = `${transaction}/transaction.json`;
      if (!this.isRegularFile(marker)) {
        this.removeIfPresent(transaction);
        return;
      }
      try {
        const record = JSON.parse(fs.readTextSync(marker)) as OtaTransactionRecord;
        if (!Array.isArray(record.objectIds)) {
          this.removeIfPresent(transaction);
          return;
        }
        fs.listFileSync(transaction)
          .filter((entry: string) => entry.endsWith('.part') || entry.includes('.tmp-'))
          .forEach((entry: string) => this.removeIfPresent(`${transaction}/${entry}`));
      } catch (error) {
        this.removeIfPresent(transaction);
      }
    });
  }

  /** 成功后退休已结束的恢复索引；不能清除另一个 epoch 正在 await 的事务。 */
  private retireRecoveredTransactions(appId: string): void {
    const root = this.transactionRoot(appId);
    if (!this.exists(root)) return;
    fs.listFileSync(root).forEach((name: string) => {
      const transaction = `${root}/${name}`;
      if (!ContentAddressedOtaStore.runningTransactions.has(transaction)) this.removeIfPresent(transaction);
    });
    this.syncDirectory(root);
  }

  /** 新进程先清理上次未完成的事务；只有显式 delete purge 才在启动期强制清理 orphan。 */
  private recoverExistingStorage(): void {
    if (!this.exists(this.appsRoot())) return;
    fs.listFileSync(this.appsRoot())
      .filter((name: string) => this.isValidAppId(name) && this.isDirectory(this.appDirectory(name)))
      .forEach((name: string) => {
        const purgeRequested = this.exists(this.purgeMarkerPath(name));
        this.recoverTransactions(name);
        if (purgeRequested) this.pruneApp(name);
      });
  }

  /** 进程被终止时从 transaction.json 恢复已经下载并校验过的 CAS Object 引用。 */
  private transactionObjectIds(appId: string): string[] {
    const result: string[] = [];
    const root = this.transactionRoot(appId);
    if (!this.exists(root)) return result;
    fs.listFileSync(root).forEach((name: string) => {
      const marker = `${root}/${name}/transaction.json`;
      if (!this.isRegularFile(marker)) return;
      try {
        const record = JSON.parse(fs.readTextSync(marker)) as OtaTransactionRecord;
        if (!Array.isArray(record.objectIds)) return;
        record.objectIds.forEach((objectId: string) => {
          if (/^sha256:[0-9a-fA-F]{64}$/.test(objectId)) result.push(objectId.toLowerCase());
        });
      } catch (error) {
        // 损坏的事务索引不参与 roots，后续按保守策略清理其不可验证对象。
      }
    });
    return result;
  }

  private transactionManifestIds(appId: string): string[] {
    const result: string[] = [];
    const root = this.transactionRoot(appId);
    if (!this.exists(root)) return result;
    fs.listFileSync(root).forEach((name: string) => {
      const marker = `${root}/${name}/transaction.json`;
      if (!this.isRegularFile(marker)) return;
      try {
        const record = JSON.parse(fs.readTextSync(marker)) as OtaTransactionRecord;
        if (record.manifestId !== undefined && /^sha256:[0-9a-f]{64}$/.test(record.manifestId)) result.push(record.manifestId);
      } catch (error) { }
    });
    return result;
  }


  private validateSnapshot(snapshot: OtaReleaseSnapshot): void {
    this.ensureSafeAppId(snapshot.lynxAppId);
    this.ensureSafeReleaseId(snapshot.releaseId);
    if (snapshot.env !== this.config.environment || snapshot.hostApp !== this.config.hostApp ||
      snapshot.platform !== this.config.requestPlatform()) throw new Error('Release Snapshot scope 不一致');
    if (snapshot.status !== 'ACTIVE' || snapshot.changedBundles.length === 0) throw new Error('Release Snapshot 不可激活');
    const paths = new Set<string>();
    snapshot.changedBundles.forEach((artifact: OtaBundleArtifact) => {
      const path = this.normalizeBundlePath(artifact.bundlePath);
      if (!path.endsWith('.lynx.bundle') || paths.has(path)) throw new Error(`Bundle 路径不合法或重复：${path}`);
      paths.add(path);
      if (!/^sha256:[0-9a-fA-F]{64}$/.test(artifact.bundleSha256)) throw new Error(`Bundle SHA 不合法：${path}`);
      if (artifact.size === undefined || artifact.size <= 0 || artifact.size > ContentAddressedOtaStore.MAX_BUNDLE_BYTES) throw new Error(`Bundle size 不合法：${path}`);
      const url = artifact.bundleUrl.trim().toLowerCase();
      const localHttp = this.isTestHttpUrl(url);
      if (!url.startsWith('https://') && !(this.config.allowLocalHTTPForTest && this.config.environment.toUpperCase() === 'TEST' && localHttp)) throw new Error(`OTA Bundle URL 不允许：${path}`);
    });
    if (snapshot.asyncBundleManifest !== undefined &&
      (snapshot.asyncBundleManifest.schemaVersion !== 1 || !Number.isSafeInteger(snapshot.asyncBundleManifest.size) ||
        snapshot.asyncBundleManifest.size <= 0 ||
        !/^sha256:[0-9a-f]{64}$/.test(snapshot.asyncBundleManifest.sha256))) throw new Error('Async 清单引用不合法');
  }

  private validateLogicalObjectId(value: string): void {
    if (!/^sha256:[0-9a-fA-F]{64}$/.test(value)) throw new Error('对象 SHA-256 不合法');
  }

  private manifestId(snapshot: OtaReleaseSnapshot): string {
    const base = [
      snapshot.env,
      snapshot.hostApp,
      snapshot.lynxAppId,
      snapshot.releaseId,
      snapshot.platform,
      snapshot.status,
      snapshot.changedBundles.map((item: OtaBundleArtifact) =>
        `${item.pageId}|${item.bundlePath}|${item.bundleSha256}|${item.bundleUrl}|${item.size ?? 0}`
      ).join('\n')
    ].join('\n');
    return snapshot.asyncBundleManifest === undefined ? this.sha256(this.stringBytes(base)) :
      OtaUserContext.hash(`${base}\n${JSON.stringify(snapshot.asyncBundleManifest)}`);
  }

  private sameSnapshot(manifest: OtaLocalManifest, snapshot: OtaReleaseSnapshot): boolean {
    if (manifest.releaseId !== snapshot.releaseId || manifest.bundles.length !== snapshot.changedBundles.length) return false;
    if (JSON.stringify(manifest.asyncBundleManifest) !== JSON.stringify(snapshot.asyncBundleManifest)) return false;
    return manifest.bundles.every((installed, index) => {
      const expected = snapshot.changedBundles[index];
      return installed.pageId === expected.pageId && installed.bundlePath === expected.bundlePath &&
        installed.bundleUrl === expected.bundleUrl && installed.bundleSha256 === expected.bundleSha256 &&
        installed.size === expected.size;
    });
  }

  private stringBytes(value: string): ArrayBuffer {
    const bytes = new Uint8Array(value.length);
    for (let index = 0; index < value.length; index += 1) bytes[index] = value.charCodeAt(index) & 0xff;
    return bytes.buffer;
  }

  private sha256(buffer: ArrayBuffer): string {
    const digest = cryptoFramework.createMd('SHA256');
    digest.updateSync({ data: new Uint8Array(buffer) });
    const bytes = digest.digestSync().data;
    let hex = '';
    bytes.forEach((value: number) => { hex += value.toString(16).padStart(2, '0'); });
    return `sha256:${hex}`;
  }

  private ensureDeclaredSize(actual: number, artifact: OtaBundleArtifact): void {
    if (artifact.size === undefined || actual !== artifact.size) throw new Error(`Bundle size 校验失败：${artifact.bundlePath}`);
    if (actual <= 0 || actual > ContentAddressedOtaStore.MAX_BUNDLE_BYTES) throw new Error(`Bundle 文件大小越界：${artifact.bundlePath}`);
  }

  private ensureExpectedSha(actual: string, expected: string, path: string): void {
    if (actual.toLowerCase() !== expected.toLowerCase()) throw new Error(`Bundle SHA-256 校验失败：${path}`);
  }

  private ensureScope(state: OtaReleaseState, appId: string): void {
    if (state.schemaVersion !== ContentAddressedOtaStore.STORE_SCHEMA_VERSION || state.lynxAppId !== appId ||
      state.env !== this.config.environment || state.hostApp !== this.config.hostApp || state.platform !== this.config.requestPlatform()) throw new Error(`OTA state scope 不匹配：${appId}`);
  }

  private ensureSafeAppId(appId: string): void {
    if (!this.isValidAppId(appId)) throw new Error(`lynxAppId 必须是 8 位数字：${appId}`);
  }

  private isValidAppId(appId: string): boolean { return /^[0-9]{8}$/.test(appId); }

  private ensureSafeReleaseId(releaseId: string): void {
    if (releaseId.trim().length === 0 || releaseId !== releaseId.trim() || releaseId === '.' || releaseId === '..' || releaseId.includes('/') || releaseId.includes('\\') || releaseId.includes('\u0000')) throw new Error(`releaseId 不安全：${releaseId}`);
  }

  private isTestHttpUrl(value: string): boolean {
    if (!value.startsWith('http://')) return false;
    const host = value.substring('http://'.length).split('/')[0].split(':')[0];
    return host === '127.0.0.1' || host === 'localhost' || host === '[::1]' || host === '10.0.2.2' ||
      host.startsWith('10.') || host.startsWith('192.168.') || host.startsWith('172.16.') ||
      host.startsWith('172.17.') || host.startsWith('172.18.') || host.startsWith('172.19.') ||
      host.startsWith('172.20.') || host.startsWith('172.21.') || host.startsWith('172.22.') ||
      host.startsWith('172.23.') || host.startsWith('172.24.') || host.startsWith('172.25.') ||
      host.startsWith('172.26.') || host.startsWith('172.27.') || host.startsWith('172.28.') ||
      host.startsWith('172.29.') || host.startsWith('172.30.') || host.startsWith('172.31.');
  }

  private normalizeBundlePath(raw: string): string {
    const value = raw.trim();
    const segments = value.split('/');
    if (value.length === 0 || value.startsWith('/') || value.includes('\\') || segments.some((item: string) => item.length === 0 || item === '.' || item === '..')) throw new Error(`Bundle 路径不安全：${raw}`);
    return value;
  }

  private availableCapacity(): number {
    if (this.testAvailableCapacityBytes >= 0) {
      return this.testAvailableCapacityBytes;
    }
    try { return statfs.getFreeSizeSync(this.root); } catch (error) { return -1; }
  }

  private checkTestFault(point: string): void {
    if (this.testFaultPoint === point) {
      const prefix = point.startsWith('enospc_') ? 'TEST ENOSPC' : 'TEST fault';
      throw new Error(`${prefix} injected: ${point}`);
    }
  }

  private async pauseAtTestPoint(point: string): Promise<void> {
    if (this.testPausePoint !== point || this.testPauseMillis <= 0) return;
    console.info(`[LynxShellOTA] TEST pause reached: ${point}, token=${this.testPauseToken || 'none'}, millis=${this.testPauseMillis}`);
    await new Promise<void>((resolve: () => void) => setTimeout(resolve, this.testPauseMillis));
  }

  private appDirectory(appId: string): string { this.ensureSafeAppId(appId); return `${this.appsRoot()}/${appId}`; }
  private appsRoot(): string { return `${this.root}/apps`; }
  private statePath(appId: string): string { return `${this.appDirectory(appId)}/state.json`; }
  private purgeMarkerPath(appId: string): string { return `${this.appDirectory(appId)}/.purge`; }
  private manifestsRoot(appId: string): string { return `${this.appDirectory(appId)}/manifests`; }
  private objectsRoot(appId: string): string { return `${this.appDirectory(appId)}/objects`; }
  private transactionRoot(appId: string): string { return `${this.appDirectory(appId)}/transactions`; }
  private transactionDirectory(appId: string, transactionId: string): string { return `${this.transactionRoot(appId)}/${transactionId}`; }
  private createTransactionDirectory(appId: string): string {
    const root = this.transactionRoot(appId);
    this.ensureDirectory(root);
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const path = this.transactionDirectory(appId, this.randomToken());
      try { fs.mkdirSync(path); return path; }
      catch (error) {
        if (!this.exists(path)) throw (error as Error);
      }
    }
    throw new Error('无法分配 OTA 事务目录');
  }
  private randomToken(): string {
    let token = '';
    cryptoFramework.createRandom().generateRandomSync(16).data.forEach((byte: number) => {
      token += byte.toString(16).padStart(2, '0');
    });
    return token;
  }
  private manifestPath(appId: string, manifestId: string): string { return `${this.manifestsRoot(appId)}/${manifestId}.json`; }
  private objectPath(appId: string, objectId: string): string {
    this.validateLogicalObjectId(objectId);
    const hex = objectId.substring('sha256:'.length);
    return `${this.objectsRoot(appId)}/${hex.substring(0, 2)}/${hex}.lynx.bundle`;
  }

  private ensureAppDirectories(appId: string): void {
    this.ensureSafeAppId(appId);
    this.ensureDirectory(this.appDirectory(appId));
    this.ensureDirectory(this.manifestsRoot(appId));
    this.ensureDirectory(this.objectsRoot(appId));
    this.ensureDirectory(this.transactionRoot(appId));
  }

  private ensureDirectory(path: string): void {
    if (this.exists(path)) {
      if (!this.isDirectory(path)) throw new Error(`OTA 路径不是目录：${path}`);
      return;
    }
    fs.mkdirSync(path, true);
  }

  private ensureParent(path: string): void {
    const index = path.lastIndexOf('/');
    if (index > 0) this.ensureDirectory(path.substring(0, index));
  }

  private writeTextAtomic(path: string, raw: string, finalGuard?: () => void): void {
    this.ensureParent(path);
    const temporary = `${path}.tmp-${this.randomToken()}`;
    const file = fs.openSync(temporary, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, raw); fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
    try {
      // UI-thread 同步区段：最终 epoch/revision 校验到 rename 之间没有 await。
      finalGuard?.();
      fs.moveFileSync(temporary, path, 0);
      this.syncDirectory(path.substring(0, path.lastIndexOf('/')));
    } finally { this.removeIfPresent(temporary); }
  }

  /** 持久化目录项，确保 atomic rename 在进程终止后对下一进程可见。 */
  private syncDirectory(path: string): void {
    const directory = fs.openSync(path, fs.OpenMode.READ_ONLY | fs.OpenMode.DIR);
    try {
      fs.fsyncSync(directory.fd);
    } finally {
      fs.closeSync(directory);
    }
  }

  private exists(path: string): boolean { try { return fs.accessSync(path); } catch (error) { return false; } }
  private isDirectory(path: string): boolean { try { const stat = fs.lstatSync(path); return stat.isDirectory() && !stat.isSymbolicLink(); } catch (error) { return false; } }
  private isRegularFile(path: string): boolean { try { const stat = fs.lstatSync(path); return stat.isFile() && !stat.isSymbolicLink(); } catch (error) { return false; } }

  private removeIfPresent(path: string): void {
    if (!this.exists(path)) return;
    if (this.isDirectory(path)) {
      fs.listFileSync(path).forEach((name: string) => this.removeIfPresent(`${path}/${name}`));
      fs.rmdirSync(path);
    } else {
      fs.unlinkSync(path);
    }
  }

  private collectFiles(root: string, output: string[]): void {
    if (!this.exists(root)) return;
    if (this.isRegularFile(root)) { output.push(root); return; }
    if (!this.isDirectory(root)) return;
    fs.listFileSync(root).forEach((name: string) => this.collectFiles(`${root}/${name}`, output));
  }

  private removeEmptyDirectories(root: string, preservedRoot: string): void {
    if (!this.isDirectory(root)) return;
    fs.listFileSync(root).forEach((name: string) => this.removeEmptyDirectories(`${root}/${name}`, preservedRoot));
    if (root !== preservedRoot) {
      try { if (fs.listFileSync(root).length === 0) fs.rmdirSync(root); } catch (error) { }
    }
  }

  private scanTree(root: string, maxFiles: number): OtaTreeScan {
    const result: OtaTreeScan = { totalBytes: 0, fileCount: 0, files: [], truncated: false };
    const files: string[] = [];
    this.collectFiles(root, files);
    files.forEach((path: string) => {
      try {
        const stat = fs.statSync(path);
        result.totalBytes += stat.size;
        result.fileCount += 1;
        if (result.files.length < maxFiles) result.files.push({ relativePath: path.substring(root.length + 1), byteCount: stat.size, modifiedAt: Number(stat.mtime ?? 0) });
        else result.truncated = true;
      } catch (error) { result.truncated = true; }
    });
    result.files.sort((left: OtaStorageFileSnapshot, right: OtaStorageFileSnapshot) => left.relativePath.localeCompare(right.relativePath));
    return result;
  }

  private activeLeasedManifestIds(appId: string): Set<string> {
    const result = new Set<string>();
    const prefix = `${this.root}|${appId}|`;
    this.activeLeases.forEach((count: number, key: string) => { if (count > 0 && key.startsWith(prefix)) result.add(key.substring(prefix.length)); });
    return result;
  }

  private leaseKey(appId: string, manifestId: string): string { return `${this.root}|${appId}|${manifestId}`; }

  private static readonly STORE_SCHEMA_VERSION: number = 3;
  private static readonly MAX_BUNDLE_BYTES: number = 20 * 1024 * 1024;
  private static readonly MAX_SCAN_DEPTH: number = 32;
  private static readonly METADATA_ALLOWANCE_BYTES: number = 1024 * 1024;
  private static readonly SAFETY_RESERVE_BYTES: number = 32 * 1024 * 1024;
}
