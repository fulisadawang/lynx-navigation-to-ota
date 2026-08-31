import { statfs } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import cryptoFramework from '@ohos.security.cryptoFramework';
import OtaApiClient from './OtaApiClient';
import OtaJson from './OtaJson';
import {
  LynxOtaConfig,
  OtaBundleArtifact,
  OtaBundleLease,
  OtaLocalManifest,
  OtaPrepareSignal,
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
  private readonly activeLeases: Map<string, number> = new Map();
  private leaseReleaseScheduler: (() => void) | null = null;
  private lastOperation: string = 'none';

  constructor(config: LynxOtaConfig, api: OtaApiClient) {
    this.config = config;
    this.api = api;
    this.root = config.storageDirectory;
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

  /** 只读取 current；embedded current 返回 null，由 Registry 直接读取 rawfile。 */
  acquireCurrentBundleLease(lynxAppId: string, bundleName: string): PreparedPageBundle | null {
    const state = this.readState(lynxAppId);
    if (state === null || state.current.kind !== 'downloaded') return null;
    this.ensureScope(state, lynxAppId);
    return this.acquireBundleLease(state.current, lynxAppId, bundleName);
  }

  /** 按固定 Release 读取 Bundle；用于同一导航 session 继承旧 Manifest。 */
  acquireBundleLeaseForRelease(lynxAppId: string, releaseId: string, bundleName: string, manifestId: string = ''): PreparedPageBundle | null {
    if (manifestId.trim().length > 0) {
      const pinnedRef: OtaReleaseRef = { kind: 'downloaded', releaseId: releaseId, manifestId: manifestId };
      return this.acquireBundleLease(pinnedRef, lynxAppId, bundleName);
    }
    const state = this.readState(lynxAppId);
    if (state === null) return null;
    this.ensureScope(state, lynxAppId);
    const ref = [state.current, state.previous]
      .find((item: OtaReleaseRef | undefined) => item !== undefined && item.releaseId === releaseId);
    if (ref === undefined) return null;
    return this.acquireBundleLease(ref, lynxAppId, bundleName);
  }

  /** 为 NavigationSnapshot 建立独立 Manifest lease，不依赖某一个页面 Bundle。 */
  acquireReleaseLease(lynxAppId: string, releaseId: string, manifestId: string = ''): OtaBundleLease | null {
    const state = this.readState(lynxAppId);
    if (state === null) return null;
    this.ensureScope(state, lynxAppId);
    const ref = [state.current, state.previous]
      .find((item: OtaReleaseRef | undefined) => item !== undefined && item.releaseId === releaseId);
    if (ref === undefined || ref.kind !== 'downloaded' || ref.manifestId === undefined) return null;
    if (manifestId.trim().length > 0 && ref.manifestId !== manifestId) return null;
    const manifest = this.readManifest(lynxAppId, ref.manifestId);
    if (manifest === null || !this.manifestObjectsUsable(lynxAppId, manifest.bundles)) return null;
    return this.createManifestLease(lynxAppId, ref.manifestId);
  }

  /** 缺包/校验失败时只修复指定 App ID。 */
  async ensureBundleReady(
    lynxAppId: string,
    bundleName: string,
    signal: OtaPrepareSignal
  ): Promise<PreparedPageBundle> {
    signal.throwIfCancelled();
    const current = this.acquireCurrentBundleLease(lynxAppId, bundleName);
    if (current !== null) return current;
    const latest = await this.api.fetchLatestBundleList(lynxAppId, signal);
    signal.throwIfCancelled();
    await this.install(latest, signal);
    signal.throwIfCancelled();
    const repaired = this.acquireCurrentBundleLease(lynxAppId, bundleName);
    if (repaired === null) {
      throw new Error(`Release 已激活但 Bundle 无法建立 lease：${lynxAppId}/${bundleName}`);
    }
    return repaired;
  }

  /**
   * 安装完整 Release Snapshot。
   *
   * 服务端 changedBundles 是完整快照。每个 artifact 先按 SHA 查 CAS；命中就直接复用，
   * 未命中才下载到 transactions/<tx>/.part，校验后原子发布对象，最后写 Manifest 与 State。
   */
  async install(snapshot: OtaReleaseSnapshot, signal: OtaPrepareSignal): Promise<void> {
    this.validateSnapshot(snapshot);
    signal.throwIfCancelled();
    this.ensureAppDirectories(snapshot.lynxAppId);
    this.recoverTransactions(snapshot.lynxAppId);

    const targetManifestId = this.manifestId(snapshot);
    const oldState = this.readState(snapshot.lynxAppId);
    if (oldState !== null) {
      this.ensureScope(oldState, snapshot.lynxAppId);
      if (oldState.current.kind === 'downloaded' &&
        oldState.current.releaseId === snapshot.releaseId &&
        oldState.current.manifestId === targetManifestId &&
        this.manifestObjectsUsable(snapshot.lynxAppId, snapshot.changedBundles)) {
        this.lastOperation = 'already_active';
        return;
      }
    }

    const reusableTargetObjects = snapshot.changedBundles
      .filter((artifact: OtaBundleArtifact) => this.hasUsableObject(snapshot.lynxAppId, artifact.bundleSha256, artifact.size))
      .map((artifact: OtaBundleArtifact) => artifact.bundleSha256);
    // 进程可能在 State 提交前被终止；保留事务索引声明的已发布对象，避免预检前 GC
    // 把仍可复用的 CAS Object 当作 orphan 删除。
    const recoveredObjectIds = this.transactionObjectIds(snapshot.lynxAppId);
    this.pruneApp(snapshot.lynxAppId, reusableTargetObjects.concat(recoveredObjectIds));
    const missingBytes = snapshot.changedBundles
      .filter((artifact: OtaBundleArtifact) => !this.hasUsableObject(snapshot.lynxAppId, artifact.bundleSha256, artifact.size))
      .reduce((total: number, artifact: OtaBundleArtifact) => total + (artifact.size ?? 0), 0);
    const requiredBytes = missingBytes + ContentAddressedOtaStore.METADATA_ALLOWANCE_BYTES +
      Math.max(ContentAddressedOtaStore.SAFETY_RESERVE_BYTES, Math.ceil(missingBytes * 0.1));
    const availableBytes = this.availableCapacity();
    if (availableBytes >= 0 && availableBytes < requiredBytes) {
      throw new Error(`OTA v3 预检空间不足：需要 ${requiredBytes} bytes，可用 ${availableBytes} bytes`);
    }

    const transactionId = `${new Date().getTime()}-${Math.floor(Math.random() * 1000000)}`;
    const transaction = this.transactionDirectory(snapshot.lynxAppId, transactionId);
    this.ensureDirectory(transaction);
    this.writeTextAtomic(`${transaction}/transaction.json`, JSON.stringify({
      schemaVersion: ContentAddressedOtaStore.STORE_SCHEMA_VERSION,
      lynxAppId: snapshot.lynxAppId,
      releaseId: snapshot.releaseId,
      objectIds: snapshot.changedBundles.map((item: OtaBundleArtifact) => item.bundleSha256)
    }));

    let downloadedCount = 0;
    let reusedCount = 0;
    try {
      for (let index = 0; index < snapshot.changedBundles.length; index += 1) {
        signal.throwIfCancelled();
        const artifact = snapshot.changedBundles[index];
        if (this.hasUsableObject(snapshot.lynxAppId, artifact.bundleSha256, artifact.size)) {
          reusedCount += 1;
          continue;
        }
        const part = `${transaction}/object-${index}.part`;
        const binary = await this.api.downloadBundle(artifact.bundleUrl, signal);
        signal.throwIfCancelled();
        this.ensureDeclaredSize(binary.byteLength, artifact);
        this.ensureExpectedSha(this.sha256(binary), artifact.bundleSha256, artifact.bundlePath);
        this.writeBinaryAtomic(part, binary);
        const objectPath = this.objectPath(snapshot.lynxAppId, artifact.bundleSha256);
        this.ensureParent(objectPath);
        if (this.hasUsableObject(snapshot.lynxAppId, artifact.bundleSha256, artifact.size)) {
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
          downloadedCount += 1;
        }
      }

      await this.pauseAtTestPoint('after_objects_ready');
      this.checkTestFault('after_objects_ready');
      signal.throwIfCancelled();
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
        installedAt: new Date().getTime()
      };
      this.checkTestFault('before_manifest_commit');
      this.checkTestFault('enospc_manifest_commit');
      this.writeTextAtomic(this.manifestPath(snapshot.lynxAppId, targetManifestId), JSON.stringify(manifest));
      this.verifyManifestObjects(snapshot.lynxAppId, manifest);
      await this.pauseAtTestPoint('after_manifest_commit');
      this.checkTestFault('after_manifest_commit');

      const previous: OtaReleaseRef | undefined = oldState !== null &&
        oldState.current.releaseId !== snapshot.releaseId ? oldState.current : oldState?.previous;
      const state: OtaReleaseState = {
        schemaVersion: ContentAddressedOtaStore.STORE_SCHEMA_VERSION,
        env: snapshot.env,
        hostApp: snapshot.hostApp,
        lynxAppId: snapshot.lynxAppId,
        platform: snapshot.platform,
        generation: (oldState?.generation ?? 0) + 1,
        current: { kind: 'downloaded', releaseId: snapshot.releaseId, manifestId: targetManifestId },
        previous: previous
      };
      // State 是唯一激活点，必须最后原子写入。
      await this.pauseAtTestPoint('before_state_commit');
      this.checkTestFault('before_state_commit');
      this.checkTestFault('enospc_state_commit');
      this.writeState(state);
      await this.pauseAtTestPoint('after_state_commit');
      this.checkTestFault('after_state_commit_report_failure');
      this.pruneApp(snapshot.lynxAppId);
      this.lastOperation = `install:${snapshot.releaseId}:downloaded=${downloadedCount}:reused=${reusedCount}`;
      this.removeIfPresent(this.transactionRoot(snapshot.lynxAppId));
      this.ensureDirectory(this.transactionRoot(snapshot.lynxAppId));
    } catch (error) {
      // 保留 transaction.json 作为下一次进程启动的恢复索引；下次启动会先读取其中的
      // 已验证 Object ID，再清理 transaction，避免 force-stop 后丢掉可复用的 orphan。
      throw new Error(`OTA v3 Release 事务失败：${error}`);
    }
  }

  rollback(lynxAppId: string): boolean {
    const state = this.readState(lynxAppId);
    if (state === null || state.previous === undefined || state.previous.kind !== 'downloaded') return false;
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
      previous: undefined
    };
    this.writeState(next);
    this.validatedObjects.clear();
    this.pruneApp(lynxAppId);
    this.lastOperation = `rollback:${restored.releaseId}`;
    return true;
  }

  deleteBundles(lynxAppId: string): void {
    this.ensureSafeAppId(lynxAppId);
    this.removeIfPresent(this.statePath(lynxAppId));
    this.removeIfPresent(this.transactionRoot(lynxAppId));
    this.writeTextAtomic(this.purgeMarkerPath(lynxAppId), 'delete');
    this.pruneApp(lynxAppId);
    this.validatedObjects.clear();
    this.lastOperation = `delete:${lynxAppId}`;
  }

  deleteAllBundles(): void {
    if (!this.exists(this.appsRoot())) return;
    fs.listFileSync(this.appsRoot()).forEach((name: string) => {
      if (!this.isValidAppId(name)) return;
      this.removeIfPresent(this.statePath(name));
      this.removeIfPresent(this.transactionRoot(name));
      this.writeTextAtomic(this.purgeMarkerPath(name), 'delete');
      this.pruneApp(name);
    });
    this.validatedObjects.clear();
    this.lastOperation = 'delete_all';
  }

  pruneAllUnreferencedReleases(): void {
    if (!this.exists(this.appsRoot())) return;
    fs.listFileSync(this.appsRoot()).forEach((name: string) => {
      if (this.isValidAppId(name)) this.pruneApp(name, this.transactionObjectIds(name));
    });
  }

  storageRoot(): string {
    return this.root;
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
            objectIds: manifest.bundles.map((item: OtaBundleArtifact) => item.objectId ?? item.bundleSha256)
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
      currentReleaseId: state.current.releaseId,
      currentKind: state.current.kind,
      previousReleaseId: state.previous?.releaseId,
      previousKind: state.previous?.kind,
      currentManifestId: state.current.manifestId,
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

  private acquireBundleLease(ref: OtaReleaseRef, appId: string, bundleName: string): PreparedPageBundle | null {
    const prepared = this.resolveBundle(ref, appId, bundleName, true);
    if (prepared === null || ref.kind !== 'downloaded') return prepared;
    const manifestId = ref.manifestId ?? ref.releaseId;
    prepared.lease = this.createManifestLease(appId, manifestId);
    return prepared;
  }

  private createManifestLease(appId: string, manifestId: string): OtaBundleLease {
    const key = this.leaseKey(appId, manifestId);
    this.activeLeases.set(key, (this.activeLeases.get(key) ?? 0) + 1);
    return new OtaBundleLease(() => {
      const remaining = (this.activeLeases.get(key) ?? 0) - 1;
      if (remaining > 0) this.activeLeases.set(key, remaining);
      else this.activeLeases.delete(key);
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
      source: 'ota_current'
    };
  }

  private resolveRef(ref: OtaReleaseRef, appId: string): PreparedPageBundle | null {
    if (ref.kind !== 'downloaded' || ref.manifestId === undefined) return null;
    const manifest = this.readManifest(appId, ref.manifestId);
    if (manifest === null || !this.manifestObjectsUsable(appId, manifest.bundles)) return null;
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

  private manifestObjectsUsable(appId: string, bundles: OtaBundleArtifact[]): boolean {
    return bundles.every((item: OtaBundleArtifact) => this.hasUsableObject(appId, item.objectId ?? item.bundleSha256, item.size));
  }

  private verifyManifestObjects(appId: string, manifest: OtaLocalManifest): void {
    if (!this.manifestObjectsUsable(appId, manifest.bundles)) throw new Error('Manifest 对象校验失败');
  }

  private hasUsableObject(appId: string, objectId: string, expectedSize: number | undefined): boolean {
    if (!/^sha256:[0-9a-fA-F]{64}$/.test(objectId) || expectedSize === undefined) return false;
    const path = this.objectPath(appId, objectId);
    if (!this.isRegularFile(path)) return false;
    const stat = fs.statSync(path);
    if (stat.size !== expectedSize) return false;
    const key = `${appId}|${objectId.toLowerCase()}|${stat.size}|${stat.mtime}|${stat.ctime}|${stat.ino}`;
    if (this.validatedObjects.has(key)) return true;
    try {
      const matches = this.sha256File(path).toLowerCase() === objectId.toLowerCase();
      if (matches) this.validatedObjects.set(key, new Date().getTime());
      return matches;
    } catch (error) {
      return false;
    }
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
      return manifest;
    } catch (error) {
      return null;
    }
  }

  private writeState(state: OtaReleaseState): void {
    this.writeTextAtomic(this.statePath(state.lynxAppId), JSON.stringify({
      schemaVersion: ContentAddressedOtaStore.STORE_SCHEMA_VERSION,
      env: state.env,
      hostApp: state.hostApp,
      lynxAppId: state.lynxAppId,
      platform: state.platform,
      generation: state.generation,
      current: state.current,
      previous: state.previous
    }));
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
    const retainedObjects = new Set<string>();
    preservedObjectIds.forEach((objectId: string) => retainedObjects.add(objectId));
    const retain = (ref: OtaReleaseRef | undefined): boolean => {
      if (ref === undefined || ref.kind !== 'downloaded' || ref.manifestId === undefined) return true;
      retainedManifests.add(ref.manifestId);
      const manifest = this.readManifest(appId, ref.manifestId);
      if (manifest === null) return false;
      manifest.bundles.forEach((item: OtaBundleArtifact) => retainedObjects.add(item.objectId ?? item.bundleSha256));
      return true;
    };
    if (!retain(state?.current) || !retain(state?.previous)) return;
    const activeLeaseManifestIds = this.activeLeasedManifestIds(appId);
    activeLeaseManifestIds.forEach((manifestId: string) => {
      retainedManifests.add(manifestId);
      const manifest = this.readManifest(appId, manifestId);
      if (manifest !== null) manifest.bundles.forEach((item: OtaBundleArtifact) => retainedObjects.add(item.objectId ?? item.bundleSha256));
    });
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
  }

  private validateLogicalObjectId(value: string): void {
    if (!/^sha256:[0-9a-fA-F]{64}$/.test(value)) throw new Error('对象 SHA-256 不合法');
  }

  private manifestId(snapshot: OtaReleaseSnapshot): string {
    const canonical = [
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
    return this.sha256(this.stringBytes(canonical));
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

  private sha256File(path: string): string {
    const stat = fs.statSync(path);
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try {
      const buffer = new ArrayBuffer(stat.size);
      const count = fs.readSync(file.fd, buffer);
      if (count !== stat.size) throw new Error(`读取对象不完整：${path}`);
      return this.sha256(buffer);
    } finally {
      fs.closeSync(file);
    }
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

  private writeBinaryAtomic(path: string, binary: ArrayBuffer): void {
    this.ensureParent(path);
    // 调用方已经把 path 放在 transaction 目录并命名为 .part；这里直接 fsync 写入，
    // 随后由事务线程把这个 part 原子 rename 到 CAS 对象路径，避免生成 .part.part。
    const temporary = path;
    const file = fs.openSync(temporary, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, binary); fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
  }

  private writeTextAtomic(path: string, raw: string): void {
    this.ensureParent(path);
    const temporary = `${path}.tmp-${new Date().getTime()}-${Math.floor(Math.random() * 1000000)}`;
    const file = fs.openSync(temporary, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, raw); fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
    fs.moveFileSync(temporary, path, 0);
    this.syncDirectory(path.substring(0, path.lastIndexOf('/')));
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
    const prefix = `${appId}|`;
    this.activeLeases.forEach((count: number, key: string) => { if (count > 0 && key.startsWith(prefix)) result.add(key.substring(prefix.length)); });
    return result;
  }

  private leaseKey(appId: string, manifestId: string): string { return `${appId}|${manifestId}`; }

  private static readonly STORE_SCHEMA_VERSION: number = 3;
  private static readonly MAX_BUNDLE_BYTES: number = 20 * 1024 * 1024;
  private static readonly MAX_SCAN_DEPTH: number = 32;
  private static readonly METADATA_ALLOWANCE_BYTES: number = 1024 * 1024;
  private static readonly SAFETY_RESERVE_BYTES: number = 32 * 1024 * 1024;
}
