import fs from '@ohos.file.fs';
import cryptoFramework from '@ohos.security.cryptoFramework';
import OtaApiClient from './OtaApiClient';
import OtaJson from './OtaJson';
import {
  LynxOtaConfig,
  OtaBundleArtifact,
  OtaLocalManifest,
  OtaPrepareSignal,
  OtaReleaseSnapshot,
  OtaReleaseState,
  PreparedPageBundle
} from './OtaModels';

/**
 * HarmonyOS 最小 ReleaseTransaction。
 *
 * Bundle 先写 `.staging`，逐个校验 size/SHA，完整 Snapshot 发布后最后提交 state；任一阶段
 * 失败都不会让 current 指向半成品。所有公开操作由 Runtime 串行调用。
 */
export default class ReleaseTransaction {
  private readonly config: LynxOtaConfig;
  private readonly api: OtaApiClient;
  private readonly root: string;

  constructor(config: LynxOtaConfig, api: OtaApiClient) {
    this.config = config;
    this.api = api;
    this.root = config.storageDirectory;
    this.ensureDirectory(this.root);
    this.ensureDirectory(this.releasesRoot());
    this.ensureDirectory(this.statesRoot());
    this.ensureDirectory(this.stagingRoot());
  }

  /** 只读取并校验已提交 current；不访问网络。 */
  currentBundle(lynxAppId: string, bundleName: string): PreparedPageBundle | null {
    const state = this.readState(lynxAppId);
    if (state === null) {
      return null;
    }
    this.ensureScope(state, lynxAppId);
    return this.resolveBundle(state.currentReleaseId, lynxAppId, bundleName, true);
  }

  /** 缺包或损坏时由当前 appId 的最新快照修复，然后再次读取 current。 */
  async ensureBundleReady(
    lynxAppId: string,
    bundleName: string,
    signal: OtaPrepareSignal
  ): Promise<PreparedPageBundle> {
    signal.throwIfCancelled();
    const current = this.currentBundle(lynxAppId, bundleName);
    if (current !== null) {
      return current;
    }
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

  /** 安装完整 Snapshot；已激活且所有 Bundle 完整时直接返回。 */
  async install(snapshot: OtaReleaseSnapshot, signal: OtaPrepareSignal): Promise<void> {
    this.validateSnapshot(snapshot);
    signal.throwIfCancelled();
    const oldState = this.readState(snapshot.lynxAppId);
    if (oldState !== null) {
      this.ensureScope(oldState, snapshot.lynxAppId);
      if (oldState.currentReleaseId === snapshot.releaseId && this.verifyRelease(snapshot.releaseId, snapshot.lynxAppId)) {
        return;
      }
    }

    this.recoverStaging();
    const transactionId = `${new Date().getTime()}-${Math.floor(Math.random() * 1000000)}`;
    const staging = `${this.stagingRoot()}/${snapshot.releaseId}.${transactionId}`;
    this.ensureDirectory(staging);
    try {
      for (const artifact of snapshot.changedBundles) {
        signal.throwIfCancelled();
        const normalized = this.normalizeBundlePath(artifact.bundlePath);
        const target = `${staging}/${normalized}`;
        this.ensureParent(target);
        let reused = false;
        if (oldState !== null) {
          const previous = this.resolveBundle(oldState.currentReleaseId, snapshot.lynxAppId, normalized, true);
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

      const published = this.releaseDirectory(snapshot.releaseId);
      if (this.exists(published)) {
        this.deleteRecursively(published);
      }
      fs.renameSync(staging, published);
      if (!this.verifyRelease(snapshot.releaseId, snapshot.lynxAppId)) {
        throw new Error('发布后的 Release 校验失败');
      }

      const previous = oldState !== null && oldState.currentReleaseId !== snapshot.releaseId ?
        oldState.currentReleaseId : oldState?.previousReleaseId;
      const state: OtaReleaseState = {
        env: this.config.environment,
        hostApp: this.config.hostApp,
        lynxAppId: snapshot.lynxAppId,
        // 本地 Manifest 记录服务端快照的平台；宿主平台仍由 config.platform 表示。
        platform: this.config.requestPlatform(),
        generation: (oldState?.generation ?? 0) + 1,
        currentReleaseId: snapshot.releaseId,
        previousReleaseId: previous
      };
      // state 是唯一激活点，必须最后写入。
      this.writeTextAtomic(this.statePath(snapshot.lynxAppId), JSON.stringify(state));
    } catch (error) {
      if (this.exists(staging)) {
        this.deleteRecursively(staging);
      }
      throw new Error(`OTA Release 事务失败：${error}`);
    }
  }

  /** 首屏失败只切换 state；不把坏 current 再保存成 previous。 */
  rollback(lynxAppId: string): boolean {
    const state = this.readState(lynxAppId);
    if (state === null || state.previousReleaseId === undefined) {
      return false;
    }
    const previousId = state.previousReleaseId;
    if (!this.verifyRelease(previousId, lynxAppId)) {
      return false;
    }
    const restored: OtaReleaseState = {
      env: state.env,
      hostApp: state.hostApp,
      lynxAppId: state.lynxAppId,
      platform: state.platform,
      generation: state.generation + 1,
      currentReleaseId: previousId
    };
    this.writeTextAtomic(this.statePath(lynxAppId), JSON.stringify(restored));
    return true;
  }

  /** 永久删除指定 appId 的下载内容，不生成 .delete-* 或备份目录。 */
  deleteBundles(lynxAppId: string): void {
    let state: OtaReleaseState | null = null;
    try {
      state = this.readState(lynxAppId);
    } catch (error) {
      // 损坏 state 也不能阻塞用户显式删除；下面继续按 Manifest 扫描归属。
    }
    const releaseIds: string[] = [];
    if (state !== null) {
      releaseIds.push(state.currentReleaseId);
      if (state.previousReleaseId !== undefined) {
        releaseIds.push(state.previousReleaseId);
      }
    }
    const statePath = this.statePath(lynxAppId);
    if (this.exists(statePath)) {
      fs.unlinkSync(statePath);
    }
    // state 丢失/损坏时仍按已发布 Manifest 精确查找 appId，保证真正删除磁盘全部 Bundle。
    if (this.exists(this.releasesRoot())) {
      fs.listFileSync(this.releasesRoot()).forEach((directoryName: string) => {
        const manifestPath = `${this.releasesRoot()}/${directoryName}/release-manifest.json`;
        if (!this.isRegularFile(manifestPath)) {
          return;
        }
        try {
          const manifest = OtaJson.parseLocalManifest(fs.readTextSync(manifestPath));
          if (manifest.lynxAppId === lynxAppId && !releaseIds.includes(manifest.releaseId)) {
            releaseIds.push(manifest.releaseId);
          }
        } catch (error) {
          // 无法确认归属的损坏目录不按 appId 猜删；deleteAll 仍能彻底清理。
        }
      });
    }
    releaseIds.forEach((releaseId: string) => {
      if (!this.isReleaseReferenced(releaseId)) {
        const directory = this.releaseDirectory(releaseId);
        if (this.exists(directory)) {
          this.deleteRecursively(directory);
        }
      }
    });
    this.recoverStaging();
  }

  /** 永久删除所有 appId 的 OTA 下载目录，再重建空 Store。 */
  deleteAllBundles(): void {
    if (this.exists(this.root)) {
      this.deleteRecursively(this.root);
    }
    this.ensureDirectory(this.root);
    this.ensureDirectory(this.releasesRoot());
    this.ensureDirectory(this.statesRoot());
    this.ensureDirectory(this.stagingRoot());
  }

  storageRoot(): string {
    return this.root;
  }

  private validateSnapshot(snapshot: OtaReleaseSnapshot): void {
    if (snapshot.lynxAppId.trim().length === 0 || snapshot.releaseId.trim().length === 0) {
      throw new Error('Release 的 lynxAppId/releaseId 不能为空');
    }
    this.ensureSafeReleaseId(snapshot.releaseId);
    if (snapshot.env !== this.config.environment || snapshot.hostApp !== this.config.hostApp ||
      snapshot.platform !== this.config.requestPlatform()) {
      throw new Error('Release Snapshot 与当前 env/hostApp/platform 不一致');
    }
    if (snapshot.status !== 'ACTIVE') {
      throw new Error(`Release 状态不可激活：${snapshot.status}`);
    }
    if (snapshot.changedBundles.length === 0) {
      throw new Error('Release Snapshot 不包含 Bundle');
    }
    const paths: Set<string> = new Set();
    snapshot.changedBundles.forEach((artifact: OtaBundleArtifact) => {
      const normalized = this.normalizeBundlePath(artifact.bundlePath);
      if (!normalized.endsWith('.lynx.bundle')) {
        throw new Error(`Bundle 后缀不合法：${artifact.bundlePath}`);
      }
      if (paths.has(normalized)) {
        throw new Error(`Release 中存在重复 Bundle：${normalized}`);
      }
      paths.add(normalized);
      if (!/^sha256:[0-9a-fA-F]{64}$/.test(artifact.bundleSha256)) {
        throw new Error(`Bundle SHA-256 不合法：${normalized}`);
      }
      if (artifact.size !== undefined && (artifact.size <= 0 || artifact.size > ReleaseTransaction.MAX_BUNDLE_BYTES)) {
        throw new Error(`Bundle size 不合法：${normalized}`);
      }
      if (!artifact.bundleUrl.toLowerCase().startsWith('https://')) {
        throw new Error(`OTA Bundle 必须使用 HTTPS：${normalized}`);
      }
    });
  }

  private resolveBundle(
    releaseId: string,
    lynxAppId: string,
    bundleName: string,
    verify: boolean
  ): PreparedPageBundle | null {
    const manifest = this.readManifest(releaseId);
    if (manifest === null || manifest.lynxAppId !== lynxAppId ||
      manifest.env !== this.config.environment || manifest.hostApp !== this.config.hostApp ||
      manifest.platform !== this.config.requestPlatform()) {
      return null;
    }
    const normalized = this.normalizeBundlePath(bundleName);
    let artifact = manifest.bundles.find((item: OtaBundleArtifact) => item.bundlePath === normalized);
    if (artifact === undefined && !normalized.includes('/')) {
      const matches = manifest.bundles.filter((item: OtaBundleArtifact) =>
        item.bundlePath.substring(item.bundlePath.lastIndexOf('/') + 1) === normalized);
      if (matches.length === 1) {
        artifact = matches[0];
      }
    }
    if (artifact === undefined) {
      return null;
    }
    const filePath = `${this.releaseDirectory(releaseId)}/${this.normalizeBundlePath(artifact.bundlePath)}`;
    if (!this.isRegularFile(filePath)) {
      return null;
    }
    if (verify) {
      try {
        this.verifyFileAgainstArtifact(filePath, artifact);
      } catch (error) {
        return null;
      }
    }
    return {
      lynxAppId: lynxAppId,
      bundleName: artifact.bundlePath,
      filePath: filePath,
      releaseId: releaseId,
      sha256: artifact.bundleSha256
    };
  }

  private verifyRelease(releaseId: string, lynxAppId: string): boolean {
    const manifest = this.readManifest(releaseId);
    if (manifest === null || manifest.lynxAppId !== lynxAppId) {
      return false;
    }
    try {
      this.verifyDirectory(this.releaseDirectory(releaseId), manifest);
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
    if (!this.isRegularFile(filePath)) {
      throw new Error(`Bundle 文件不存在：${artifact.bundlePath}`);
    }
    const stat = fs.statSync(filePath);
    this.ensureDeclaredSize(stat.size, artifact);
    if (stat.size <= 0 || stat.size > ReleaseTransaction.MAX_BUNDLE_BYTES) {
      throw new Error(`Bundle 文件大小越界：${artifact.bundlePath}`);
    }
    this.ensureExpectedSha(this.sha256File(filePath), artifact.bundleSha256, artifact.bundlePath);
  }

  private ensureDeclaredSize(actual: number, artifact: OtaBundleArtifact): void {
    if (artifact.size !== undefined && actual !== artifact.size) {
      throw new Error(`Bundle 大小校验失败：${artifact.bundlePath}，expected=${artifact.size}, actual=${actual}`);
    }
    if (actual > ReleaseTransaction.MAX_BUNDLE_BYTES) {
      throw new Error(`Bundle 超过 ${ReleaseTransaction.MAX_BUNDLE_BYTES} 字节`);
    }
  }

  private ensureExpectedSha(actual: string, expected: string, bundlePath: string): void {
    if (actual.toLowerCase() !== expected.toLowerCase()) {
      throw new Error(`Bundle SHA-256 校验失败：${bundlePath}`);
    }
  }

  private sha256File(filePath: string): string {
    const stat = fs.statSync(filePath);
    const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(stat.size);
      const count = fs.readSync(file.fd, buffer);
      if (count !== stat.size) {
        throw new Error(`读取 Bundle 不完整：${filePath}`);
      }
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
    bytes.forEach((value: number) => {
      hex += value.toString(16).padStart(2, '0');
    });
    return `sha256:${hex}`;
  }

  private readState(lynxAppId: string): OtaReleaseState | null {
    const path = this.statePath(lynxAppId);
    if (!this.isRegularFile(path)) {
      return null;
    }
    return OtaJson.parseState(fs.readTextSync(path));
  }

  private readManifest(releaseId: string): OtaLocalManifest | null {
    const path = `${this.releaseDirectory(releaseId)}/release-manifest.json`;
    if (!this.isRegularFile(path)) {
      return null;
    }
    try {
      return OtaJson.parseLocalManifest(fs.readTextSync(path));
    } catch (error) {
      return null;
    }
  }

  private ensureScope(state: OtaReleaseState, lynxAppId: string): void {
    if (state.lynxAppId !== lynxAppId || state.env !== this.config.environment ||
      state.hostApp !== this.config.hostApp || state.platform !== this.config.requestPlatform()) {
      throw new Error(`OTA state scope 不匹配：${lynxAppId}`);
    }
  }

  private writeBinaryAtomic(path: string, binary: ArrayBuffer): void {
    const temporary = `${path}.part`;
    const file = fs.openSync(temporary, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      const count = fs.writeSync(file.fd, binary);
      if (count !== binary.byteLength) {
        throw new Error(`Bundle 写入不完整：${path}`);
      }
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
    // 同一目录 move mode=0 会覆盖旧文件，保持 state/manifest 的单一可见性切换点。
    fs.moveFileSync(temporary, path, 0);
  }

  private recoverStaging(): void {
    if (!this.exists(this.stagingRoot())) {
      this.ensureDirectory(this.stagingRoot());
      return;
    }
    fs.listFileSync(this.stagingRoot()).forEach((name: string) => {
      this.deleteRecursively(`${this.stagingRoot()}/${name}`);
    });
  }

  private isReleaseReferenced(releaseId: string): boolean {
    if (!this.exists(this.statesRoot())) {
      return false;
    }
    for (const name of fs.listFileSync(this.statesRoot())) {
      const path = `${this.statesRoot()}/${name}`;
      if (!this.isRegularFile(path)) {
        continue;
      }
      try {
        const state = OtaJson.parseState(fs.readTextSync(path));
        if (state.currentReleaseId === releaseId || state.previousReleaseId === releaseId) {
          return true;
        }
      } catch (error) {
        // 损坏 state 不应阻止用户显式删除目标 appId 的 Bundle。
      }
    }
    return false;
  }

  private normalizeBundlePath(raw: string): string {
    let normalized = raw.trim();
    while (normalized.startsWith('./')) {
      normalized = normalized.substring(2);
    }
    if (normalized.startsWith('/') || normalized.includes('\\')) {
      throw new Error(`Bundle 路径不安全：${raw}`);
    }
    const segments = normalized.split('/');
    if (segments.length === 0 || segments.some((item: string) => item.length === 0 || item === '.' || item === '..')) {
      throw new Error(`Bundle 路径不安全：${raw}`);
    }
    return segments.join('/');
  }

  private statePath(lynxAppId: string): string {
    return `${this.statesRoot()}/${this.safeFileName(lynxAppId)}.json`;
  }

  private releaseDirectory(releaseId: string): string {
    this.ensureSafeReleaseId(releaseId);
    return `${this.releasesRoot()}/${releaseId}`;
  }

  private releasesRoot(): string {
    return `${this.root}/releases`;
  }

  private statesRoot(): string {
    return `${this.root}/states`;
  }

  private stagingRoot(): string {
    return `${this.root}/.staging`;
  }

  private safeFileName(raw: string): string {
    const safe = raw.toLowerCase().replace(/[^a-z0-9_-]/g, '_');
    if (safe.length === 0) {
      throw new Error('OTA 文件标识不能为空');
    }
    return safe;
  }

  /** Release 目录使用原始 ID；先严格拒绝路径字符，避免 safe-name 折叠造成 ID 碰撞。 */
  private ensureSafeReleaseId(releaseId: string): void {
    if (releaseId.trim().length === 0 || releaseId !== releaseId.trim() || releaseId === '.' || releaseId === '..' ||
      releaseId.includes('/') || releaseId.includes('\\') || releaseId.includes('\u0000')) {
      throw new Error(`releaseId 不安全：${releaseId}`);
    }
  }

  private ensureParent(path: string): void {
    const index = path.lastIndexOf('/');
    if (index > 0) {
      this.ensureDirectory(path.substring(0, index));
    }
  }

  private ensureDirectory(path: string): void {
    if (this.exists(path)) {
      const stat = fs.lstatSync(path);
      if (!stat.isDirectory() || stat.isSymbolicLink()) {
        throw new Error(`OTA 路径不是目录：${path}`);
      }
      return;
    }
    fs.mkdirSync(path, true);
    const created = fs.lstatSync(path);
    if (!created.isDirectory() || created.isSymbolicLink()) {
      throw new Error(`OTA 目录创建后校验失败：${path}`);
    }
  }

  private exists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  private isRegularFile(path: string): boolean {
    try {
      return fs.accessSync(path) && fs.statSync(path).isFile();
    } catch (error) {
      return false;
    }
  }

  private deleteRecursively(path: string): void {
    if (!this.exists(path)) {
      return;
    }
    const stat = fs.statSync(path);
    if (stat.isDirectory()) {
      fs.listFileSync(path).forEach((name: string) => this.deleteRecursively(`${path}/${name}`));
      fs.rmdirSync(path);
      return;
    }
    fs.unlinkSync(path);
  }

  private static readonly MAX_BUNDLE_BYTES: number = 20 * 1024 * 1024;
}
