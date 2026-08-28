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

interface OtaTreeNode {
  path: string;
  relative: string;
  depth: number;
}

interface OtaTreeScan {
  totalBytes: number;
  fileCount: number;
  files: OtaStorageFileSnapshot[];
  truncated: boolean;
}

/**
 * HarmonyOS Store v2 的持久化事务。
 *
 * 远程 Bundle 只允许进入 `apps/<lynxAppId>`，先写 app-scoped staging，再发布完整 Release，
 * 最后原子写入 state。HarmonyOS 的稳定回退集合就是 current + previous + 活体页面 lease。
 */
export default class ReleaseTransaction {
  private readonly config: LynxOtaConfig;
  private readonly api: OtaApiClient;
  private readonly root: string;
  private readonly validatedBundles: Map<string, number> = new Map();
  private readonly activeLeases: Map<string, number> = new Map();
  private leaseReleaseScheduler: (() => void) | null = null;
  private validationAccessCounter: number = 0;

  constructor(config: LynxOtaConfig, api: OtaApiClient) {
    this.config = config;
    this.api = api;
    this.root = config.storageDirectory;
    this.ensureDirectory(this.root);
    this.ensureDirectory(this.appsRoot());
  }

  /** 只读取并校验已经提交的 current；不会访问网络。 */
  currentBundle(lynxAppId: string, bundleName: string): PreparedPageBundle | null {
    const state = this.readState(lynxAppId);
    if (state === null) return null;
    this.ensureScope(state, lynxAppId);
    return this.resolveBundle(state.current, lynxAppId, bundleName, true);
  }

  /** Runtime 注入统一队列；lease 释放不能绕过正在进行的下载/发布事务。 */
  setLeaseReleaseScheduler(scheduler: (() => void) | null): void {
    this.leaseReleaseScheduler = scheduler;
  }

  /** 缺包或校验失败时由当前 App ID 的 latest snapshot 修复。 */
  async ensureBundleReady(
    lynxAppId: string,
    bundleName: string,
    signal: OtaPrepareSignal
  ): Promise<PreparedPageBundle> {
    signal.throwIfCancelled();
    const current = this.currentBundle(lynxAppId, bundleName);
    if (current !== null) return current;
    const latest = await this.api.fetchLatestBundleList(lynxAppId, signal);
    signal.throwIfCancelled();
    await this.install(latest, signal);
    signal.throwIfCancelled();
    const repaired = this.currentBundle(lynxAppId, bundleName);
    if (repaired === null) {
      throw new Error(`Release 已激活但 Bundle 不存在：${lynxAppId}/${bundleName}`);
    }
    return repaired;
  }

  /**
   * 原子安装完整 Release Snapshot。
   *
   * changedBundles 在当前服务端契约中是完整快照；旧 current 中 SHA 相同的文件只复制到
   * 新 App-scoped staging，再统一发布，避免把旧 Release 的绝对路径写入新状态。
   */
  async install(snapshot: OtaReleaseSnapshot, signal: OtaPrepareSignal): Promise<void> {
    this.validateSnapshot(snapshot);
    signal.throwIfCancelled();
    this.ensureAppDirectories(snapshot.lynxAppId);
    this.recoverStaging(snapshot.lynxAppId);

    const oldState = this.readState(snapshot.lynxAppId);
    if (oldState !== null) {
      this.ensureScope(oldState, snapshot.lynxAppId);
      if (oldState.current.releaseId === snapshot.releaseId &&
        oldState.current.kind === 'downloaded' &&
        this.verifyRelease(snapshot.releaseId, snapshot.lynxAppId)) {
        this.pruneUnreferencedReleases(snapshot.lynxAppId);
        return;
      }
    }

    // 先释放无引用历史版本，再做容量预检，避免旧版本把新版本空间挤掉。
    this.pruneUnreferencedReleases(snapshot.lynxAppId);
    const targetBytes = snapshot.changedBundles.reduce(
      (total: number, bundle: OtaBundleArtifact) => total + (bundle.size ?? 0),
      0
    );
    const requiredBytes = targetBytes + ReleaseTransaction.METADATA_ALLOWANCE_BYTES + Math.max(
      ReleaseTransaction.SAFETY_RESERVE_BYTES,
      Math.ceil(targetBytes * 0.1)
    );
    const availableBytes = this.availableCapacity();
    if (availableBytes >= 0 && availableBytes < requiredBytes) {
      throw new Error(`OTA 预检空间不足：需要 ${requiredBytes} bytes，可用 ${availableBytes} bytes`);
    }

    const transactionId = `${new Date().getTime()}-${Math.floor(Math.random() * 1000000)}`;
    const staging = this.stagingDirectory(
      snapshot.lynxAppId,
      snapshot.releaseId,
      transactionId
    );
    this.ensureDirectory(staging);
    try {
      for (const artifact of snapshot.changedBundles) {
        signal.throwIfCancelled();
        const normalized = this.normalizeBundlePath(artifact.bundlePath);
        const target = `${staging}/${normalized}`;
        this.ensureParent(target);
        let reused = false;
        if (oldState !== null) {
          const previous = this.resolveBundle(oldState.current, snapshot.lynxAppId, normalized, true);
          if (previous !== null && previous.sha256.toLowerCase() === artifact.bundleSha256.toLowerCase()) {
            fs.copyFileSync(previous.filePath, target);
            reused = true;
          }
        }
        if (!reused) {
          const binary = await this.api.downloadBundle(artifact.bundleUrl, signal);
          this.ensureDeclaredSize(binary.byteLength, artifact);
          this.ensureExpectedSha(this.sha256(binary), artifact.bundleSha256, artifact.bundlePath);
          this.writeBinaryAtomic(target, binary);
        }
        this.verifyFileAgainstArtifact(target, artifact);
      }

      const manifest: OtaLocalManifest = {
        schemaVersion: ReleaseTransaction.LOCAL_MANIFEST_SCHEMA_VERSION,
        env: snapshot.env,
        hostApp: snapshot.hostApp,
        lynxAppId: snapshot.lynxAppId,
        releaseId: snapshot.releaseId,
        platform: snapshot.platform,
        status: snapshot.status,
        bundles: snapshot.changedBundles,
        installedAt: new Date().getTime()
      };
      this.writeTextAtomic(`${staging}/release-manifest.json`, JSON.stringify(manifest));
      this.verifyDirectory(staging, manifest);
      signal.throwIfCancelled();

      const published = this.releaseDirectory(snapshot.lynxAppId, snapshot.releaseId);
      if (this.exists(published)) {
        fs.moveFileSync(staging, published, 0);
      } else {
        fs.renameSync(staging, published);
      }
      if (!this.verifyRelease(snapshot.releaseId, snapshot.lynxAppId)) {
        throw new Error('发布后的 Release 校验失败');
      }

      // 当前版本的直接前驱进入 previous；同一 Release 修复时不制造自引用。
      const previous: OtaReleaseRef | undefined = oldState !== null &&
        oldState.current.releaseId !== snapshot.releaseId ? oldState.current : oldState?.previous;
      const state: OtaReleaseState = {
        schemaVersion: ReleaseTransaction.STORE_SCHEMA_VERSION,
        env: this.config.environment,
        hostApp: this.config.hostApp,
        lynxAppId: snapshot.lynxAppId,
        platform: this.config.requestPlatform(),
        generation: (oldState?.generation ?? 0) + 1,
        current: { kind: 'downloaded', releaseId: snapshot.releaseId },
        previous: previous
      };
      // state 是唯一激活点，必须最后写入。
      this.writeState(state);
      this.pruneUnreferencedReleases(snapshot.lynxAppId);
    } catch (error) {
      // 如果发布已完成但 state 写入失败，目录会在下一次冷启动被识别为 orphan。
      if (this.exists(staging)) this.deleteRecursively(staging);
      throw new Error(`OTA Release 事务失败：${error}`);
    }
  }

  /** 原子解析 current 并登记 lease，避免解析与 prune 之间出现竞态。 */
  acquireCurrentBundleLease(lynxAppId: string, bundleName: string): PreparedPageBundle | null {
    const state = this.readState(lynxAppId);
    if (state === null) return null;
    this.ensureScope(state, lynxAppId);
    return this.acquireBundleLease(state.current, lynxAppId, bundleName);
  }

  /** 回滚到 previous；没有 previous 时由 Runtime 负责切回 rawfile baseline。 */
  rollback(lynxAppId: string): boolean {
    const state = this.readState(lynxAppId);
    if (state === null || state.previous === undefined || state.previous.kind !== 'downloaded') {
      return false;
    }
    if (!this.verifyRelease(state.previous.releaseId, lynxAppId)) {
      return false;
    }
    const next: OtaReleaseState = {
      schemaVersion: ReleaseTransaction.STORE_SCHEMA_VERSION,
      env: state.env,
      hostApp: state.hostApp,
      lynxAppId: state.lynxAppId,
      platform: state.platform,
      generation: state.generation + 1,
      current: state.previous,
      previous: undefined
    };
    this.writeState(next);
    this.validatedBundles.clear();
    this.pruneUnreferencedReleases(lynxAppId);
    return true;
  }

  /** 删除指定 App ID 的远程内容；活体 lease 仍然保护对应 Release。 */
  deleteBundles(lynxAppId: string): void {
    this.ensureSafeAppId(lynxAppId);
    this.removeIfPresent(this.statePath(lynxAppId));
    this.removeIfPresent(this.stagingRoot(lynxAppId));
    this.pruneDownloadedDirectories(lynxAppId, new Set<string>());
    this.validatedBundles.clear();
  }

  /** 删除所有 App ID 的远程内容，但不触碰 rawfile 内置资源。 */
  deleteAllBundles(): void {
    if (!this.exists(this.appsRoot())) return;
    for (const name of fs.listFileSync(this.appsRoot())) {
      const appDirectory = `${this.appsRoot()}/${name}`;
      if (!this.isDirectory(appDirectory) || !this.isValidAppId(name)) continue;
      this.removeIfPresent(this.statePath(name));
      this.removeIfPresent(this.stagingRoot(name));
      this.pruneDownloadedDirectories(name, new Set<string>());
    }
    this.validatedBundles.clear();
  }

  /** 冷启动维护：状态损坏的 App 保守跳过，合法状态之外的 Release 和 staging 可回收。 */
  pruneAllUnreferencedReleases(): void {
    if (!this.exists(this.appsRoot())) return;
    for (const name of fs.listFileSync(this.appsRoot())) {
      const appDirectory = `${this.appsRoot()}/${name}`;
      if (!this.isDirectory(appDirectory) || !this.isValidAppId(name)) continue;
      let state: OtaReleaseState | null;
      try {
        state = this.readState(name);
      } catch (error) {
        continue;
      }
      this.recoverStaging(name);
      const retained = new Set<string>();
      if (state?.current.kind === 'downloaded') retained.add(state.current.releaseId);
      if (state?.previous?.kind === 'downloaded') retained.add(state.previous.releaseId);
      this.pruneDownloadedDirectories(name, retained);
    }
  }

  /** 只读快照；不会创建目录、修剪文件、请求网络或重算 SHA。 */
  storageSnapshot(maxFilesPerTree: number = 2_000): OtaStorageSnapshot {
    if (maxFilesPerTree <= 0) throw new Error('maxFilesPerTree 必须大于 0');
    const rootScan = this.scanTree(this.root, maxFilesPerTree);
    const apps: OtaStorageAppSnapshot[] = [];
    if (this.exists(this.appsRoot())) {
      const appIds = fs.listFileSync(this.appsRoot())
        .filter((name: string) => this.isValidAppId(name) && this.isDirectory(`${this.appsRoot()}/${name}`))
        .sort();
      appIds.forEach((appId: string) => apps.push(this.snapshotApp(appId, maxFilesPerTree)));
    }
    return {
      rootPath: this.root,
      totalBytes: rootScan.totalBytes,
      fileCount: rootScan.fileCount,
      generatedAt: new Date().getTime(),
      apps: apps
    };
  }

  storageRoot(): string {
    return this.root;
  }

  private snapshotApp(appId: string, maxFilesPerTree: number): OtaStorageAppSnapshot {
    const state = this.tryReadState(appId);
    const leased = this.activeLeasedReleaseIds(appId);
    const releases: OtaStorageReleaseSnapshot[] = [];
    const releasesRoot = this.releasesRoot(appId);
    if (this.exists(releasesRoot)) {
      fs.listFileSync(releasesRoot)
        .filter((name: string) => this.isDirectory(`${releasesRoot}/${name}`))
        .sort()
        .forEach((releaseId: string) => {
          const roles: OtaStorageReleaseRole[] = [];
          if (state?.current.kind === 'downloaded' && state.current.releaseId === releaseId) {
            roles.push(OtaStorageReleaseRole.CURRENT);
          }
          if (state?.previous?.kind === 'downloaded' && state.previous.releaseId === releaseId) {
            roles.push(OtaStorageReleaseRole.PREVIOUS);
          }
          if (leased.has(releaseId)) roles.push(OtaStorageReleaseRole.LEASED);
          if (roles.length === 0) roles.push(OtaStorageReleaseRole.ORPHAN);
          const scan = this.scanTree(`${releasesRoot}/${releaseId}`, maxFilesPerTree);
          releases.push({
            releaseId: releaseId,
            roles: roles,
            totalBytes: scan.totalBytes,
            fileCount: scan.fileCount,
            manifestValid: this.isManifestStructurallyValid(appId, releaseId),
            files: scan.files,
            truncated: scan.truncated
          });
        });
    }

    const staging: OtaStorageStagingSnapshot[] = [];
    const stagingRoot = this.stagingRoot(appId);
    if (this.exists(stagingRoot)) {
      fs.listFileSync(stagingRoot)
        .filter((name: string) => this.isDirectory(`${stagingRoot}/${name}`))
        .sort()
        .forEach((transactionName: string) => {
          const scan = this.scanTree(`${stagingRoot}/${transactionName}`, maxFilesPerTree);
          staging.push({
            transactionName: transactionName,
            totalBytes: scan.totalBytes,
            fileCount: scan.fileCount,
            files: scan.files,
            truncated: scan.truncated
          });
        });
    }

    const appScan = this.scanTree(this.appDirectory(appId), maxFilesPerTree);
    const stateSnapshot: OtaStorageStateSnapshot | undefined = state === null ? undefined : {
      generation: state.generation,
      currentReleaseId: state.current.releaseId,
      currentKind: state.current.kind,
      previousReleaseId: state.previous?.releaseId,
      previousKind: state.previous?.kind
    };
    return {
      appId: appId,
      state: stateSnapshot,
      releases: releases,
      staging: staging,
      totalBytes: appScan.totalBytes,
      fileCount: appScan.fileCount
    };
  }

  private scanTree(root: string, maxFiles: number): OtaTreeScan {
    const result: OtaTreeScan = {
      totalBytes: 0,
      fileCount: 0,
      files: [],
      truncated: false
    };
    if (!this.exists(root)) return result;
    const pending: OtaTreeNode[] = [
      { path: root, relative: '', depth: 0 }
    ];
    while (pending.length > 0) {
      const current = pending.pop() as OtaTreeNode;
      if (current.depth > ReleaseTransaction.MAX_SCAN_DEPTH) {
        result.truncated = true;
        continue;
      }
      let children: string[] = [];
      try {
        children = fs.listFileSync(current.path).sort();
      } catch (error) {
        result.truncated = true;
        continue;
      }
      children.forEach((name: string) => {
        const path = `${current.path}/${name}`;
        const relative = current.relative.length > 0 ? `${current.relative}/${name}` : name;
        if (this.isDirectory(path)) {
          pending.push({ path: path, relative: relative, depth: current.depth + 1 });
          return;
        }
        if (!this.isRegularFile(path)) return;
        try {
          const stat = fs.statSync(path);
          const byteCount = stat.size;
          result.totalBytes += byteCount;
          result.fileCount += 1;
          if (result.files.length < maxFiles) {
            result.files.push({
              relativePath: relative,
              byteCount: byteCount,
              modifiedAt: Number(stat.mtime ?? 0)
            });
          } else {
            result.truncated = true;
          }
        } catch (error) {
          result.truncated = true;
        }
      });
    }
    result.files.sort((left: OtaStorageFileSnapshot, right: OtaStorageFileSnapshot) =>
      left.relativePath.localeCompare(right.relativePath));
    return result;
  }

  private validateSnapshot(snapshot: OtaReleaseSnapshot): void {
    this.ensureSafeAppId(snapshot.lynxAppId);
    if (snapshot.releaseId.trim().length === 0) throw new Error('Release 的 releaseId 不能为空');
    this.ensureSafeReleaseId(snapshot.releaseId);
    if (snapshot.env !== this.config.environment || snapshot.hostApp !== this.config.hostApp ||
      snapshot.platform !== this.config.requestPlatform()) {
      throw new Error('Release Snapshot 与当前 env/hostApp/platform 不一致');
    }
    if (snapshot.status !== 'ACTIVE') throw new Error(`Release 状态不可激活：${snapshot.status}`);
    if (snapshot.changedBundles.length === 0) throw new Error('Release Snapshot 不包含 Bundle');
    const paths = new Set<string>();
    snapshot.changedBundles.forEach((artifact: OtaBundleArtifact) => {
      const normalized = this.normalizeBundlePath(artifact.bundlePath);
      if (!normalized.endsWith('.lynx.bundle')) throw new Error(`Bundle 后缀不合法：${artifact.bundlePath}`);
      if (paths.has(normalized)) throw new Error(`Release 中存在重复 Bundle：${normalized}`);
      paths.add(normalized);
      if (!/^sha256:[0-9a-fA-F]{64}$/.test(artifact.bundleSha256)) {
        throw new Error(`Bundle SHA-256 不合法：${normalized}`);
      }
      if (artifact.size === undefined || artifact.size <= 0 ||
        artifact.size > ReleaseTransaction.MAX_BUNDLE_BYTES) {
        throw new Error(`Bundle size 不合法：${normalized}`);
      }
      if (!artifact.bundleUrl.toLowerCase().startsWith('https://')) {
        throw new Error(`OTA Bundle 必须使用 HTTPS：${normalized}`);
      }
    });
  }

  private resolveBundle(
    reference: OtaReleaseRef,
    lynxAppId: string,
    bundleName: string,
    verify: boolean
  ): PreparedPageBundle | null {
    if (reference.kind !== 'downloaded') return null;
    const manifest = this.readManifest(lynxAppId, reference.releaseId);
    if (manifest === null || manifest.lynxAppId !== lynxAppId ||
      manifest.env !== this.config.environment || manifest.hostApp !== this.config.hostApp ||
      manifest.platform !== this.config.requestPlatform()) {
      return null;
    }
    let artifact: OtaBundleArtifact | undefined;
    if (bundleName.length === 0) {
      artifact = manifest.bundles[0];
    } else {
      const normalized = this.normalizeBundlePath(bundleName);
      artifact = manifest.bundles.find((item: OtaBundleArtifact) => item.bundlePath === normalized);
      if (artifact === undefined && !normalized.includes('/')) {
        const matches = manifest.bundles.filter((item: OtaBundleArtifact) =>
          item.bundlePath.substring(item.bundlePath.lastIndexOf('/') + 1) === normalized);
        if (matches.length === 1) artifact = matches[0];
      }
    }
    if (artifact === undefined) return null;
    const filePath = `${this.releaseDirectory(lynxAppId, reference.releaseId)}/${this.normalizeBundlePath(artifact.bundlePath)}`;
    if (!this.isRegularFile(filePath)) return null;
    if (verify) {
      try {
        this.verifyCurrentFileAgainstArtifact(filePath, reference.releaseId, lynxAppId, artifact);
      } catch (error) {
        return null;
      }
    }
    return {
      lynxAppId: lynxAppId,
      bundleName: artifact.bundlePath,
      filePath: filePath,
      releaseId: reference.releaseId,
      sha256: artifact.bundleSha256,
      source: 'ota_current'
    };
  }

  private acquireBundleLease(
    reference: OtaReleaseRef,
    lynxAppId: string,
    bundleName: string
  ): PreparedPageBundle | null {
    const prepared = this.resolveBundle(reference, lynxAppId, bundleName, true);
    if (prepared === null || reference.kind !== 'downloaded') return prepared;
    const key = this.leaseKey(lynxAppId, reference.releaseId);
    this.activeLeases.set(key, (this.activeLeases.get(key) ?? 0) + 1);
    prepared.lease = new OtaBundleLease(() => {
      this.releaseLease(lynxAppId, reference.releaseId);
      this.leaseReleaseScheduler?.();
    });
    return prepared;
  }

  private releaseLease(lynxAppId: string, releaseId: string): void {
    const key = this.leaseKey(lynxAppId, releaseId);
    const remaining = (this.activeLeases.get(key) ?? 0) - 1;
    if (remaining > 0) {
      this.activeLeases.set(key, remaining);
    } else {
      this.activeLeases.delete(key);
    }
  }

  private activeLeasedReleaseIds(lynxAppId: string): Set<string> {
    const result = new Set<string>();
    const prefix = `${lynxAppId}|`;
    this.activeLeases.forEach((count: number, key: string) => {
      if (count > 0 && key.startsWith(prefix)) result.add(key.substring(prefix.length));
    });
    return result;
  }

  private verifyRelease(releaseId: string, lynxAppId: string): boolean {
    const manifest = this.readManifest(lynxAppId, releaseId);
    if (manifest === null || manifest.lynxAppId !== lynxAppId) return false;
    try {
      this.verifyDirectory(this.releaseDirectory(lynxAppId, releaseId), manifest);
      return true;
    } catch (error) {
      return false;
    }
  }

  private verifyDirectory(directory: string, manifest: OtaLocalManifest): void {
    manifest.bundles.forEach((artifact: OtaBundleArtifact) => {
      this.verifyFileAgainstArtifact(`${directory}/${this.normalizeBundlePath(artifact.bundlePath)}`, artifact);
    });
  }

  private verifyFileAgainstArtifact(filePath: string, artifact: OtaBundleArtifact): void {
    if (!this.isRegularFile(filePath)) throw new Error(`Bundle 文件不存在：${artifact.bundlePath}`);
    const stat = fs.statSync(filePath);
    this.ensureDeclaredSize(stat.size, artifact);
    this.ensureExpectedSha(this.sha256File(filePath), artifact.bundleSha256, artifact.bundlePath);
  }

  /** 页面热路径的 SHA 校验；命中指纹缓存时不重复读取 Bundle bytes。 */
  private verifyCurrentFileAgainstArtifact(
    filePath: string,
    releaseId: string,
    lynxAppId: string,
    artifact: OtaBundleArtifact
  ): void {
    if (!this.isRegularFile(filePath)) throw new Error(`Bundle 文件不存在：${artifact.bundlePath}`);
    const stat = fs.statSync(filePath);
    this.ensureDeclaredSize(stat.size, artifact);
    const key = [
      this.config.environment,
      this.config.hostApp,
      this.config.requestPlatform(),
      lynxAppId,
      releaseId,
      artifact.bundlePath,
      artifact.bundleSha256.toLowerCase(),
      String(stat.size),
      String(stat.mtime),
      String(stat.ctime),
      stat.ino.toString()
    ].join('|');
    if (this.validatedBundles.has(key)) {
      this.validationAccessCounter += 1;
      this.validatedBundles.set(key, this.validationAccessCounter);
      return;
    }
    this.ensureExpectedSha(this.sha256File(filePath), artifact.bundleSha256, artifact.bundlePath);
    this.validationAccessCounter += 1;
    this.validatedBundles.set(key, this.validationAccessCounter);
    while (this.validatedBundles.size > ReleaseTransaction.MAX_VALIDATED_BUNDLES) {
      let oldestKey: string | null = null;
      let oldestAccess = Number.MAX_SAFE_INTEGER;
      this.validatedBundles.forEach((access: number, entryKey: string) => {
        if (access < oldestAccess) {
          oldestAccess = access;
          oldestKey = entryKey;
        }
      });
      if (oldestKey === null) break;
      this.validatedBundles.delete(oldestKey);
    }
  }

  private ensureDeclaredSize(actual: number, artifact: OtaBundleArtifact): void {
    if (artifact.size !== undefined && actual !== artifact.size) {
      throw new Error(`Bundle 大小校验失败：${artifact.bundlePath}，expected=${artifact.size}, actual=${actual}`);
    }
    if (actual <= 0 || actual > ReleaseTransaction.MAX_BUNDLE_BYTES) {
      throw new Error(`Bundle 文件大小越界：${artifact.bundlePath}`);
    }
  }

  private ensureExpectedSha(actual: string, expected: string, bundlePath: string): void {
    if (actual.toLowerCase() !== expected.toLowerCase()) throw new Error(`Bundle SHA-256 校验失败：${bundlePath}`);
  }

  private sha256File(filePath: string): string {
    const stat = fs.statSync(filePath);
    const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try {
      const buffer = new ArrayBuffer(stat.size);
      const count = fs.readSync(file.fd, buffer);
      if (count !== stat.size) throw new Error(`读取 Bundle 不完整：${filePath}`);
      return this.sha256(buffer);
    } finally {
      fs.closeSync(file);
    }
  }

  private sha256(buffer: ArrayBuffer): string {
    const digest = cryptoFramework.createMd('SHA256');
    digest.updateSync({ data: new Uint8Array(buffer) });
    const bytes = digest.digestSync().data;
    let hex = '';
    bytes.forEach((value: number) => { hex += value.toString(16).padStart(2, '0'); });
    return `sha256:${hex}`;
  }

  private availableCapacity(): number {
    try {
      return statfs.getFreeSizeSync(this.root);
    } catch (error) {
      // 某些设备/测试容器可能不提供 statfs；不把查询失败误报成空间不足。
      console.warn(`LynxShellOTA 无法读取可用空间：${error}`);
      return -1;
    }
  }

  private readState(lynxAppId: string): OtaReleaseState | null {
    const path = this.statePath(lynxAppId);
    if (!this.isRegularFile(path)) return null;
    return OtaJson.parseState(fs.readTextSync(path));
  }

  private tryReadState(lynxAppId: string): OtaReleaseState | null {
    try { return this.readState(lynxAppId); } catch (error) { return null; }
  }

  private readManifest(lynxAppId: string, releaseId: string): OtaLocalManifest | null {
    const path = `${this.releaseDirectory(lynxAppId, releaseId)}/release-manifest.json`;
    if (!this.isRegularFile(path)) return null;
    try { return OtaJson.parseLocalManifest(fs.readTextSync(path)); } catch (error) { return null; }
  }

  private isManifestStructurallyValid(lynxAppId: string, releaseId: string): boolean {
    const manifest = this.readManifest(lynxAppId, releaseId);
    return manifest !== null && manifest.lynxAppId === lynxAppId && manifest.releaseId === releaseId;
  }

  private ensureScope(state: OtaReleaseState, lynxAppId: string): void {
    if (state.schemaVersion !== ReleaseTransaction.STORE_SCHEMA_VERSION ||
      state.lynxAppId !== lynxAppId || state.env !== this.config.environment ||
      state.hostApp !== this.config.hostApp || state.platform !== this.config.requestPlatform()) {
      throw new Error(`OTA state scope 不匹配：${lynxAppId}`);
    }
  }

  private writeBinaryAtomic(path: string, binary: ArrayBuffer): void {
    this.ensureParent(path);
    const temporary = `${path}.part`;
    const file = fs.openSync(temporary, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      const count = fs.writeSync(file.fd, binary);
      if (count !== binary.byteLength) throw new Error(`Bundle 写入不完整：${path}`);
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(temporary, path);
  }

  private writeTextAtomic(path: string, raw: string): void {
    this.ensureParent(path);
    const temporary = `${path}.tmp`;
    const file = fs.openSync(temporary, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, raw);
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
    fs.moveFileSync(temporary, path, 0);
  }

  private writeState(state: OtaReleaseState): void {
    const canonical: OtaReleaseState = {
      schemaVersion: ReleaseTransaction.STORE_SCHEMA_VERSION,
      env: state.env,
      hostApp: state.hostApp,
      lynxAppId: state.lynxAppId,
      platform: state.platform,
      generation: state.generation,
      current: state.current,
      previous: state.previous
    };
    this.writeTextAtomic(this.statePath(state.lynxAppId), JSON.stringify(canonical));
  }

  private recoverStaging(lynxAppId: string): void {
    const root = this.stagingRoot(lynxAppId);
    if (!this.exists(root)) {
      this.ensureDirectory(root);
      return;
    }
    fs.listFileSync(root).forEach((name: string) => this.deleteRecursively(`${root}/${name}`));
  }

  private pruneUnreferencedReleases(lynxAppId: string): void {
    const retained = new Set<string>();
    let state: OtaReleaseState | null;
    try {
      state = this.readState(lynxAppId);
    } catch (error) {
      // 状态损坏时不猜测删除；显式 deleteBundles 会先移除 state 后再执行清理。
      return;
    }
    if (state?.current.kind === 'downloaded') retained.add(state.current.releaseId);
    if (state?.previous?.kind === 'downloaded') retained.add(state.previous.releaseId);
    this.pruneDownloadedDirectories(lynxAppId, retained);
  }

  private pruneDownloadedDirectories(lynxAppId: string, retained: Set<string>): void {
    const keep = new Set<string>(retained);
    this.activeLeasedReleaseIds(lynxAppId).forEach((releaseId: string) => keep.add(releaseId));
    const root = this.releasesRoot(lynxAppId);
    if (!this.exists(root)) return;
    fs.listFileSync(root).forEach((name: string) => {
      const path = `${root}/${name}`;
      if (this.isDirectory(path) && !keep.has(name)) this.deleteRecursively(path);
    });
  }

  private appDirectory(lynxAppId: string): string {
    this.ensureSafeAppId(lynxAppId);
    return `${this.appsRoot()}/${lynxAppId}`;
  }

  private appsRoot(): string { return `${this.root}/apps`; }

  private releasesRoot(lynxAppId: string): string {
    return `${this.appDirectory(lynxAppId)}/releases`;
  }

  private stagingRoot(lynxAppId: string): string {
    return `${this.appDirectory(lynxAppId)}/.staging`;
  }

  private statePath(lynxAppId: string): string {
    return `${this.appDirectory(lynxAppId)}/state.json`;
  }

  private releaseDirectory(lynxAppId: string, releaseId: string): string {
    this.ensureSafeReleaseId(releaseId);
    return `${this.releasesRoot(lynxAppId)}/${releaseId}`;
  }

  private stagingDirectory(lynxAppId: string, releaseId: string, transactionId: string): string {
    this.ensureSafeReleaseId(releaseId);
    return `${this.stagingRoot(lynxAppId)}/${releaseId}.${transactionId}`;
  }

  private leaseKey(lynxAppId: string, releaseId: string): string {
    return `${lynxAppId}|${releaseId}`;
  }

  private ensureAppDirectories(lynxAppId: string): void {
    this.ensureSafeAppId(lynxAppId);
    this.ensureDirectory(this.appDirectory(lynxAppId));
    this.ensureDirectory(this.releasesRoot(lynxAppId));
    this.ensureDirectory(this.stagingRoot(lynxAppId));
  }

  private ensureDirectory(path: string): void {
    if (this.exists(path)) {
      if (!this.isDirectory(path)) throw new Error(`OTA 路径不是目录：${path}`);
      return;
    }
    fs.mkdirSync(path, true);
    if (!this.isDirectory(path)) throw new Error(`OTA 目录创建后校验失败：${path}`);
  }

  private ensureParent(path: string): void {
    const index = path.lastIndexOf('/');
    if (index > 0) this.ensureDirectory(path.substring(0, index));
  }

  private exists(path: string): boolean {
    try { return fs.accessSync(path); } catch (error) { return false; }
  }

  private isDirectory(path: string): boolean {
    try {
      const stat = fs.lstatSync(path);
      return stat.isDirectory() && !stat.isSymbolicLink();
    } catch (error) { return false; }
  }

  private isRegularFile(path: string): boolean {
    try {
      const stat = fs.lstatSync(path);
      return stat.isFile() && !stat.isSymbolicLink();
    } catch (error) { return false; }
  }

  private removeIfPresent(path: string): void {
    if (this.exists(path)) this.deleteRecursively(path);
  }

  private deleteRecursively(path: string): void {
    if (!this.exists(path)) return;
    if (this.isDirectory(path)) {
      fs.listFileSync(path).forEach((name: string) => this.deleteRecursively(`${path}/${name}`));
      fs.rmdirSync(path);
      return;
    }
    fs.unlinkSync(path);
  }

  private normalizeBundlePath(raw: string): string {
    const normalized = raw.trim();
    const segments = normalized.split('/');
    if (normalized.length === 0 || normalized.startsWith('/') || normalized.includes('\\') ||
      segments.some((item: string) => item.length === 0 || item === '.' || item === '..')) {
      throw new Error(`Bundle 路径不安全：${raw}`);
    }
    return normalized;
  }

  private ensureSafeAppId(appId: string): void {
    if (!this.isValidAppId(appId)) throw new Error(`lynxAppId 必须是 8 位数字：${appId}`);
  }

  private isValidAppId(appId: string): boolean {
    return /^[0-9]{8}$/.test(appId);
  }

  private ensureSafeReleaseId(releaseId: string): void {
    if (releaseId.trim().length === 0 || releaseId !== releaseId.trim() || releaseId === '.' ||
      releaseId === '..' || releaseId.includes('/') || releaseId.includes('\\') ||
      releaseId.includes('\u0000')) {
      throw new Error(`releaseId 不安全：${releaseId}`);
    }
  }

  private static readonly STORE_SCHEMA_VERSION: number = 2;
  private static readonly LOCAL_MANIFEST_SCHEMA_VERSION: number = 1;
  private static readonly MAX_BUNDLE_BYTES: number = 20 * 1024 * 1024;
  private static readonly MAX_VALIDATED_BUNDLES: number = 128;
  private static readonly MAX_SCAN_DEPTH: number = 32;
  private static readonly METADATA_ALLOWANCE_BYTES: number = 1024 * 1024;
  private static readonly SAFETY_RESERVE_BYTES: number = 32 * 1024 * 1024;
}
