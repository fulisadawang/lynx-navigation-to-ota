import { hashOtaFile } from './OtaFileIO';
import { statfs } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import cryptoFramework from '@ohos.security.cryptoFramework';
import OtaApiClient from './OtaApiClient';
import OtaJson from './OtaJson';
import { OtaUserContext, OtaUserContextBox } from './OtaUserContext';
import {
  LynxOtaConfig, OtaAsyncBundleManifest, OtaAsyncBundleManifestRef, OtaAsyncBundleResource, OtaAsyncResourceKind,
  OtaAsyncResourceResolver, OtaLocalManifest, OtaPrepareSignal
} from './OtaModels';

interface SidecarTransaction {
  objectIds: string[];
  manifestId: string;
}

export interface OtaPreparedSidecars {
  asyncResolver?: OtaAsyncResourceResolver;
}

class PageAsyncResolver implements OtaAsyncResourceResolver {
  private readonly store: OtaSidecarStore;
  private readonly appId: string;
  private readonly entries: Map<string, OtaAsyncBundleResource> = new Map();
  constructor(store: OtaSidecarStore, appId: string, owner: string, manifest: OtaAsyncBundleManifest) {
    this.store = store;
    this.appId = appId;
    manifest.entries.forEach((entry: OtaAsyncBundleResource) => {
      if (entry.ownerBundlePath !== owner) return;
      if (this.entries.has(entry.requestKey) || this.entries.has(entry.url)) {
        throw new Error('当前页面 Async 请求键或 URL 重复');
      }
      this.entries.set(entry.requestKey, entry);
      this.entries.set(entry.url, entry);
    });
  }

  kind(requestKey: string): OtaAsyncResourceKind | null {
    return this.entries.get(this.normalizeRequestKey(requestKey))?.kind ?? null;
  }

  resolveBytes(requestKey: string): Promise<ArrayBuffer> {
    return this.store.readAsyncBytes(this.appId, this.entry(requestKey));
  }

  resolvePath(requestKey: string): string {
    return this.store.asyncObjectPath(this.appId, this.entry(requestKey));
  }

  private entry(requestKey: string): OtaAsyncBundleResource {
    const entry = this.entries.get(this.normalizeRequestKey(requestKey));
    if (entry === undefined) throw new Error('Async 请求未在当前代码快照声明');
    return entry;
  }

  private normalizeRequestKey(raw: string): string {
    if (raw.startsWith('webpack:///')) return raw.substring('webpack:///'.length).split('?')[0].split('#')[0];
    if (raw.startsWith('/') && !raw.startsWith('//')) return raw.substring(1);
    return raw;
  }
}

/** App ID 作用域附属资源 Store；主 Store 的 State/Manifest 仍是代码版本唯一激活点。 */
export default class OtaSidecarStore {
  private readonly root: string;
  private readonly config: LynxOtaConfig;
  private readonly api: OtaApiClient;
  private readonly identity: OtaUserContextBox;
  private static readonly runningTransactions: Set<string> = new Set();
  private readonly activeTransactions: Set<string> = OtaSidecarStore.runningTransactions;
  private readonly validatedObjects: Set<string> = new Set();

  constructor(config: LynxOtaConfig, api: OtaApiClient, identity: OtaUserContextBox) {
    this.root = config.storageDirectory;
    this.config = config;
    this.api = api;
    this.identity = identity;
  }

  async prepareAsync(appId: string, ref: OtaAsyncBundleManifestRef, owners: string[], signal: OtaPrepareSignal,
    context?: OtaUserContext, mainMissingBytes: number = 0): Promise<void> {
    this.validateRef(ref);
    this.ensureAllowedUrl(ref.url);
    if (this.verifyAsync(appId, ref, owners, true)) return;
    signal.throwIfCancelled();
    const metadataRoot = this.transactionRoot(appId, 'async-bundles');
    this.ensureDirectory(metadataRoot);
    const metadataPart = `${metadataRoot}/manifest-${this.randomToken()}.part`;
    this.activeTransactions.add(metadataPart);
    let raw: string;
    try {
      const byteCount = await this.api.downloadBundleToFile(ref.url, metadataPart, signal, context, ref.size);
      if (byteCount !== ref.size || await hashOtaFile(metadataPart, ref.size) !== ref.sha256) throw new Error('附属资源清单 size/SHA 校验失败');
      raw = await fs.readText(metadataPart);
      signal.throwIfCancelled(); this.identityGuard(context);
    } finally {
      this.activeTransactions.delete(metadataPart);
      this.removeIfPresent(metadataPart);
    }
    const manifest = OtaJson.parseAsyncBundleManifest(raw);
    const ownerSet = new Set<string>(owners);
    manifest.entries.forEach((entry: OtaAsyncBundleResource) => {
      if (!ownerSet.has(entry.ownerBundlePath)) throw new Error('Async ownerBundlePath 不属于当前代码 Release');
      this.ensureAllowedUrl(entry.url);
    });
    for (const entry of manifest.entries) {
      await this.validateObjectAsync(appId, 'async-bundles', entry.sha256, entry.size, true);
      signal.throwIfCancelled(); this.identityGuard(context);
    }
    const declaredObjects = new Map<string, number>();
    const missingObjects = new Map<string, number>();
    manifest.entries.forEach((entry: OtaAsyncBundleResource) => {
      const declaredSize = declaredObjects.get(entry.sha256);
      if (declaredSize !== undefined && declaredSize !== entry.size) throw new Error('Async 对象 SHA 对应不同大小');
      declaredObjects.set(entry.sha256, entry.size);
      if (!this.objectUsable(appId, 'async-bundles', entry.sha256, entry.size, true)) {
        missingObjects.set(entry.sha256, entry.size);
      }
    });
    let missingBytes = mainMissingBytes;
    missingObjects.forEach((size: number) => { missingBytes += size; });
    const requiredBytes = missingBytes + 1024 * 1024 + Math.max(32 * 1024 * 1024, Math.ceil(missingBytes * 0.1));
    const availableBytes = this.availableCapacity();
    if (availableBytes >= 0 && availableBytes < requiredBytes) {
      throw new Error(`OTA 主包与 Async 预检空间不足：需要 ${requiredBytes} bytes，可用 ${availableBytes} bytes`);
    }
    const transaction = this.beginTransaction(appId, 'async-bundles', ref.sha256,
      manifest.entries.map((entry: OtaAsyncBundleResource) => entry.sha256));
    try {
      for (let index = 0; index < manifest.entries.length; index += 1) {
        const entry = manifest.entries[index];
        signal.throwIfCancelled();
        if (this.objectUsable(appId, 'async-bundles', entry.sha256, entry.size, true)) continue;
        await this.fetchObject(appId, 'async-bundles', entry.url, entry.sha256, entry.size, transaction, index, signal, context);
      }
      signal.throwIfCancelled();
      this.identityGuard(context);
      this.writeTextAtomic(this.manifestPath(appId, 'async-bundles', ref.sha256), raw);
      if (!this.verifyAsync(appId, ref, owners, true)) throw new Error('Async 清单本地提交不完整');
    } finally {
      this.activeTransactions.delete(transaction);
    }
  }

  async validateManifestObjects(appId: string, manifest: OtaLocalManifest, forceHash: boolean = false): Promise<void> {
    if (manifest.asyncBundleManifest === undefined) return;
    let resources: OtaAsyncBundleManifest;
    try { resources = this.readAsyncManifest(appId, manifest.asyncBundleManifest); }
    catch (error) { return; }
    for (const entry of resources.entries) await this.validateObjectAsync(appId, 'async-bundles', entry.sha256, entry.size, forceHash);
  }

  private async validateObjectAsync(appId: string, kind: string, sha: string, size: number, forceHash: boolean = false): Promise<void> {
    const path = this.objectPath(appId, kind, sha);
    if (!this.isRegularFile(path) || this.fileSize(path) !== size) return;
    const stat = fs.statSync(path);
    const key = `${path}|${size}|${stat.mtime}|${stat.ctime}|${stat.ino}`;
    if (!forceHash && this.validatedObjects.has(key)) return;
    if (forceHash) this.validatedObjects.delete(key);
    if (await hashOtaFile(path) !== sha) { this.validatedObjects.delete(key); return; }
    const after = fs.statSync(path);
    if (stat.size === after.size && stat.mtime === after.mtime && stat.ctime === after.ctime && stat.ino === after.ino) this.validatedObjects.add(key);
  }

  verifyBound(appId: string, manifest: OtaLocalManifest): boolean {
    try {
      if (manifest.asyncBundleManifest !== undefined &&
        !this.verifyAsync(appId, manifest.asyncBundleManifest, manifest.bundles.map((bundle) => bundle.bundlePath), true)) return false;
      return true;
    } catch (error) { return false; }
  }

  preparePage(appId: string, manifest: OtaLocalManifest, owner: string): OtaPreparedSidecars {
    const prepared: OtaPreparedSidecars = {};
    if (manifest.asyncBundleManifest !== undefined) {
      if (!this.verifyAsync(appId, manifest.asyncBundleManifest, manifest.bundles.map((bundle) => bundle.bundlePath))) {
        throw new Error('本地 Async 资源缺失或校验失败');
      }
      // 页面只保留已验证清单的固定索引；后续 lazy 请求不再反复同步读取清单。
      const asyncManifest = this.readAsyncManifest(appId, manifest.asyncBundleManifest);
      prepared.asyncResolver = new PageAsyncResolver(this, appId, owner, asyncManifest);
    }
    return prepared;
  }

  async readAsyncBytes(appId: string, entry: OtaAsyncBundleResource): Promise<ArrayBuffer> {
    const path = this.objectPath(appId, 'async-bundles', entry.sha256);
    const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try {
      const bytes = new ArrayBuffer(entry.size);
      const result = new Uint8Array(bytes);
      let total = 0;
      while (total < entry.size) {
        const chunk = new ArrayBuffer(Math.min(256 * 1024, entry.size - total));
        const count = await fs.read(file.fd, chunk);
        if (count <= 0) throw new Error('Async 本地对象读取不完整');
        result.set(new Uint8Array(chunk, 0, count), total);
        total += count;
      }
      if (await this.sha256Async(bytes) !== entry.sha256) throw new Error('Async 本地对象 SHA 不匹配');
      return bytes;
    } finally { await fs.close(file); }
  }

  asyncObjectPath(appId: string, entry: OtaAsyncBundleResource): string {
    const path = this.objectPath(appId, 'async-bundles', entry.sha256);
    if (!this.isRegularFile(path) || this.fileSize(path) !== entry.size) throw new Error('Async 本地对象缺失或损坏');
    return path;
  }

  /** 先完成所有 rooted manifest/object 的 mark，任一根损坏即不 sweep。 */
  prune(appId: string, mainManifests: OtaLocalManifest[]): void {
    const asyncRoots = new Map<string, OtaAsyncBundleManifestRef>();
    mainManifests.forEach((manifest) => {
      if (manifest.asyncBundleManifest !== undefined) {
        const previous = asyncRoots.get(manifest.asyncBundleManifest.sha256);
        if (previous !== undefined && previous.size !== manifest.asyncBundleManifest.size) throw new Error('Async 根引用 size 冲突');
        asyncRoots.set(manifest.asyncBundleManifest.sha256, manifest.asyncBundleManifest);
      }
    });
    const asyncObjects = new Set<string>();
    asyncRoots.forEach((ref) => {
      const manifest = this.readAsyncManifest(appId, ref);
      manifest.entries.forEach((entry) => {
        if (!this.objectUsable(appId, 'async-bundles', entry.sha256, entry.size, true)) throw new Error('rooted Async 对象损坏');
        asyncObjects.add(entry.sha256);
      });
    });
    const asyncManifestIds = new Set<string>(asyncRoots.keys());
    this.transactionRoots(appId, 'async-bundles', asyncManifestIds, asyncObjects);
    this.sweep(appId, 'async-bundles', asyncManifestIds, asyncObjects);
  }

  retireTransactions(appId: string): void {
    const root = this.transactionRoot(appId, 'async-bundles');
    if (!this.isDirectory(root)) return;
    fs.listFileSync(root).forEach((name) => {
      const path = `${root}/${name}`;
      if (!this.activeTransactions.has(path)) this.removeIfPresent(path);
    });
  }

  private verifyAsync(appId: string, ref: OtaAsyncBundleManifestRef, owners: string[], forceHash: boolean = false): boolean {
    try {
      const manifest = this.readAsyncManifest(appId, ref);
      const ownerSet = new Set<string>(owners);
      return manifest.entries.every((entry) => {
        this.ensureAllowedUrl(entry.url);
        return ownerSet.has(entry.ownerBundlePath) &&
          this.objectUsable(appId, 'async-bundles', entry.sha256, entry.size, forceHash);
      });
    } catch (error) { return false; }
  }

  private readAsyncManifest(appId: string, ref: OtaAsyncBundleManifestRef): OtaAsyncBundleManifest {
    this.validateRef(ref);
    const path = this.manifestPath(appId, 'async-bundles', ref.sha256);
    if (!this.isRegularFile(path) || this.fileSize(path) !== ref.size) throw new Error('Async 清单缺失或大小不匹配');
    const raw = fs.readTextSync(path);
    if (OtaUserContext.hash(raw) !== ref.sha256) throw new Error('Async 清单 SHA 不匹配');
    return OtaJson.parseAsyncBundleManifest(raw);
  }

  private async fetchObject(appId: string, kind: string, url: string, sha: string, size: number,
    transaction: string, index: number, signal: OtaPrepareSignal, context?: OtaUserContext): Promise<void> {
    const part = `${transaction}/object-${index}.part`;
    const byteCount = await this.api.downloadBundleToFile(url, part, signal, context);
    const digest = await hashOtaFile(part);
    signal.throwIfCancelled(); this.identityGuard(context);
    if (byteCount !== size || digest !== sha) throw new Error('附属资源 size/SHA 校验失败');
    const destination = this.objectPath(appId, kind, sha);
    this.ensureParent(destination);
    if (this.objectUsable(appId, kind, sha, size)) this.removeIfPresent(part);
    else {
      fs.renameSync(part, destination);
      this.syncDirectory(transaction);
      this.syncDirectory(destination.substring(0, destination.lastIndexOf('/')));
      await this.validateObjectAsync(appId, kind, sha, size);
      signal.throwIfCancelled(); this.identityGuard(context);
    }
  }

  private beginTransaction(appId: string, kind: string, manifestId: string, objectIds: string[]): string {
    const root = this.transactionRoot(appId, kind);
    this.ensureDirectory(root);
    let path = '';
    for (let attempt = 0; attempt < 5; attempt += 1) {
      path = `${root}/${this.randomToken()}`;
      try { fs.mkdirSync(path); break; }
      catch (error) {
        if (!this.exists(path)) throw (error as Error);
        if (attempt === 4) throw new Error('无法分配附属资源事务目录');
      }
    }
    this.writeTextAtomic(`${path}/transaction.json`, JSON.stringify({ manifestId: manifestId,
      objectIds: objectIds } as SidecarTransaction));
    this.activeTransactions.add(path);
    return path;
  }

  private transactionRoots(appId: string, kind: string, manifests: Set<string>, objects: Set<string>): void {
    const root = this.transactionRoot(appId, kind);
    if (!this.isDirectory(root)) return;
    fs.listFileSync(root).forEach((name) => {
      const marker = `${root}/${name}/transaction.json`;
      if (!this.isRegularFile(marker)) return;
      try {
        const record = JSON.parse(fs.readTextSync(marker)) as SidecarTransaction;
        this.validateSha(record.manifestId);
        manifests.add(record.manifestId);
        record.objectIds.forEach((id) => { this.validateSha(id); objects.add(id); });
      } catch (error) { throw new Error('附属资源事务索引损坏，拒绝清理'); }
    });
  }

  private sweep(appId: string, kind: string, manifests: Set<string>, objects: Set<string>): void {
    const manifestRoot = this.manifestRoot(appId, kind);
    if (this.isDirectory(manifestRoot)) fs.listFileSync(manifestRoot).forEach((name) => {
      if (name.endsWith('.json') && !manifests.has(`sha256:${name.substring(0, name.length - 5)}`)) {
        this.removeIfPresent(`${manifestRoot}/${name}`);
      }
    });
    const objectFiles: string[] = [];
    this.collectFiles(this.objectsRoot(appId, kind), objectFiles);
    objectFiles.forEach((path) => {
      const name = path.substring(path.lastIndexOf('/') + 1);
      if (name.endsWith('.bin') && !objects.has(`sha256:${name.substring(0, name.length - 4)}`)) this.removeIfPresent(path);
    });
  }

  private objectUsable(appId: string, kind: string, sha: string, size: number, forceHash: boolean = false): boolean {
    try {
      const path = this.objectPath(appId, kind, sha);
      if (!this.isRegularFile(path) || this.fileSize(path) !== size) return false;
      const stat = fs.statSync(path);
      const key = `${path}|${size}|${stat.mtime}|${stat.ctime}|${stat.ino}`;
      return this.validatedObjects.has(key);
    } catch (error) { return false; }
  }

  private async sha256Async(bytes: ArrayBuffer): Promise<string> {
    const digest = cryptoFramework.createMd('SHA256');
    await digest.update({ data: new Uint8Array(bytes) });
    let hex = '';
    (await digest.digest()).data.forEach((byte: number) => { hex += byte.toString(16).padStart(2, '0'); });
    return `sha256:${hex}`;
  }

  private validateRef(ref: OtaAsyncBundleManifestRef): void {
    if (ref.schemaVersion !== 1 || ref.size <= 0 || ref.size > 1024 * 1024 || !Number.isSafeInteger(ref.size)) {
      throw new Error('Async 清单引用不合法或超过 1 MB');
    }
    this.validateSha(ref.sha256);
  }

  private availableCapacity(): number {
    if (this.config.environment.toUpperCase() === 'TEST' && this.config.testAvailableCapacityBytes >= 0) {
      return this.config.testAvailableCapacityBytes;
    }
    try { return statfs.getFreeSizeSync(this.root); } catch (error) { return -1; }
  }

  private ensureAllowedUrl(raw: string): void {
    const url = raw.trim().toLowerCase();
    if (url.includes('?') || url.includes('#') || url.substring(url.indexOf('://') + 3).split('/')[0].includes('@')) {
      throw new Error('附属资源 URL 包含不允许的参数或凭据');
    }
    if (url.startsWith('https://')) return;
    const host = url.startsWith('http://') ? url.substring('http://'.length).split('/')[0].split(':')[0] : '';
    const local = host === '127.0.0.1' || host === 'localhost' || host === '[::1]' || host === '10.0.2.2' ||
      host.startsWith('10.') || host.startsWith('192.168.') || host.startsWith('172.16.') || host.startsWith('172.17.') ||
      host.startsWith('172.18.') || host.startsWith('172.19.') || host.startsWith('172.20.') || host.startsWith('172.21.') ||
      host.startsWith('172.22.') || host.startsWith('172.23.') || host.startsWith('172.24.') || host.startsWith('172.25.') ||
      host.startsWith('172.26.') || host.startsWith('172.27.') || host.startsWith('172.28.') || host.startsWith('172.29.') ||
      host.startsWith('172.30.') || host.startsWith('172.31.');
    if (!this.config.allowLocalHTTPForTest || this.config.environment !== 'TEST' || !local) {
      throw new Error('附属资源只允许 HTTPS；本机 HTTP 仅 TEST 显式调试');
    }
  }

  private validateSha(id: string): void {
    if (!/^sha256:[0-9a-f]{64}$/.test(id)) throw new Error('附属资源 SHA 不合法');
  }

  private identityGuard(context?: OtaUserContext): void {
    if (context !== undefined) this.identity.validate(context);
  }

  private appRoot(appId: string): string {
    if (!/^[0-9]{8}$/.test(appId)) throw new Error('附属资源 App ID 不合法');
    return `${this.root}/apps/${appId}`;
  }

  private kindRoot(appId: string, kind: string): string { return `${this.appRoot(appId)}/${kind}`; }
  private manifestRoot(appId: string, kind: string): string { return `${this.kindRoot(appId, kind)}/manifests`; }
  private objectsRoot(appId: string, kind: string): string { return `${this.kindRoot(appId, kind)}/objects`; }
  private transactionRoot(appId: string, kind: string): string { return `${this.kindRoot(appId, kind)}/transactions`; }
  private manifestPath(appId: string, kind: string, sha: string): string {
    this.validateSha(sha); return `${this.manifestRoot(appId, kind)}/${sha.substring(7)}.json`;
  }
  private objectPath(appId: string, kind: string, sha: string): string {
    this.validateSha(sha); const hex = sha.substring(7);
    return `${this.objectsRoot(appId, kind)}/${hex.substring(0, 2)}/${hex}.bin`;
  }

  private fileSize(path: string): number {
    if (!this.isRegularFile(path)) throw new Error('附属资源文件缺失');
    return fs.statSync(path).size;
  }

  private exists(path: string): boolean { try { return fs.accessSync(path); } catch (error) { return false; } }
  private isRegularFile(path: string): boolean {
    try { const value = fs.lstatSync(path); return value.isFile() && !value.isSymbolicLink(); } catch (error) { return false; }
  }
  private isDirectory(path: string): boolean {
    try { const value = fs.lstatSync(path); return value.isDirectory() && !value.isSymbolicLink(); } catch (error) { return false; }
  }
  private ensureDirectory(path: string): void {
    if (this.exists(path)) { if (!this.isDirectory(path)) throw new Error('附属资源目录不安全'); return; }
    fs.mkdirSync(path, true);
  }
  private ensureParent(path: string): void { this.ensureDirectory(path.substring(0, path.lastIndexOf('/'))); }
  private writeTextAtomic(path: string, raw: string): void {
    this.ensureParent(path);
    const temporary = `${path}.tmp-${this.randomToken()}`;
    const file = fs.openSync(temporary, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, raw); fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
    try {
      fs.renameSync(temporary, path);
      this.syncDirectory(path.substring(0, path.lastIndexOf('/')));
    } finally { this.removeIfPresent(temporary); }
  }
  private syncDirectory(path: string): void {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY | fs.OpenMode.DIR);
    try { fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
  }
  private randomToken(): string {
    let token = '';
    cryptoFramework.createRandom().generateRandomSync(16).data.forEach((byte: number) => {
      token += byte.toString(16).padStart(2, '0');
    });
    return token;
  }
  private removeIfPresent(path: string): void {
    if (!this.exists(path)) return;
    if (this.isDirectory(path)) {
      fs.listFileSync(path).forEach((name) => this.removeIfPresent(`${path}/${name}`));
      fs.rmdirSync(path);
    } else fs.unlinkSync(path);
  }
  private collectFiles(path: string, output: string[]): void {
    if (this.isRegularFile(path)) { output.push(path); return; }
    if (this.isDirectory(path)) fs.listFileSync(path).forEach((name) => this.collectFiles(`${path}/${name}`, output));
  }
}
