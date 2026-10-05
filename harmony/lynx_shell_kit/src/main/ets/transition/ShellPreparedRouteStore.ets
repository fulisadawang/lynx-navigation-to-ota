import util from '@ohos.util';
import systemDateTime from '@ohos.systemDateTime';
import cryptoFramework from '@ohos.security.cryptoFramework';
import LynxPageRequest from '../model/LynxPageRequest';
import { ShellBridgeResult } from '../common/ShellTypes';
import PageBundleRuntimeRegistry, { PageBundleRuntime, PreparedPageBundle, OtaPrepareSignal } from '../ota/OtaModels';
import ShellTemplateResourceFetcher from '../provider/ShellTemplateResourceFetcher';
import ShellConstants from '../common/ShellConstants';

interface PreparedRouteEntry {
  token: string;
  routeKey: string;
  bundleUrl: string;
  lynxAppId: string;
  bundleName: string;
  sessionID: string;
  sourceSnapshotID: string;
  runtime: PageBundleRuntime | null;
  epoch?: number;
  prepared: PreparedPageBundle;
  sizeBytes: number;
  expiresAt: number;
  expiresElapsed: number;
  isSourceActive: () => boolean;
}

/** 四条/32MiB/30秒一次性字节缓存，不保存LynxView、JS runtime、导航参数或转场快照。 */
export default class ShellPreparedRouteStore {
  static readonly shared: ShellPreparedRouteStore = new ShellPreparedRouteStore();
  private readonly entries: Map<string, PreparedRouteEntry> = new Map();
  private bytes: number = 0;
  private preparing: boolean = false;
  private generation: number = 0;
  private expiryTimer: number = -1;
  private activeSignal: OtaPrepareSignal | null = null;

  async prepare(request: LynxPageRequest, isSourceActive: () => boolean = (): boolean => true): Promise<ShellBridgeResult> {
    if (this.preparing) return { code: 1006, message: '已有Bundle预加载正在进行' };
    this.cleanupExpired();
    // 未知大小先预留一份最大Bundle，避免已缓存32MiB再并发追加多个20MiB下载。
    this.makeRoom(ShellConstants.MAX_BUNDLE_BYTES);
    this.preparing = true;
    const generation = this.generation;
    const signal = new OtaPrepareSignal(); this.activeSignal = signal;
    const runtime = PageBundleRuntimeRegistry.current();
    const epoch = runtime?.userIdentityEpoch;
    let prepared: PreparedPageBundle | null = null;
    try {
      if (!isSourceActive()) throw new Error('prepared_source_destroyed');
      runtime?.validateNavigationSource(request.sourceSnapshotID);
      if (request.isOtaRequest()) {
        if (runtime === null) throw new Error('OTA宿主未安装');
        prepared = await runtime.prewarm(request.lynxAppId, request.bundleName, signal, request.sessionID, request.sourceSnapshotID);
        const fetcher = new ShellTemplateResourceFetcher(request.allowHttpInDebug, request.bundleUrl,
          prepared.filePath, runtime.storageRoot(), prepared.bytes ?? null, prepared.asyncResolver);
        try { prepared.bytes = await fetcher.preload(request.bundleUrl); }
        finally { fetcher.cancelAll(); }
      } else {
        const fetcher = new ShellTemplateResourceFetcher(request.allowHttpInDebug);
        let data: ArrayBuffer;
        try { data = await fetcher.preload(request.bundleUrl); } finally { fetcher.cancelAll(); }
        prepared = { lynxAppId: '', bundleName: request.bundleUrl, filePath: '', bytes: data,
          releaseId: '', sha256: '', source: 'direct_prepared', userIdentityEpoch: epoch };
      }
      signal.throwIfCancelled();
      if (generation !== this.generation || !isSourceActive() || runtime !== PageBundleRuntimeRegistry.current() || epoch !== runtime?.userIdentityEpoch) throw new Error('prepared_source_destroyed');
      runtime?.validateNavigationSource(request.sourceSnapshotID);
      const data = prepared.bytes;
      if (data === undefined || data.byteLength === 0 || data.byteLength > ShellConstants.MAX_BUNDLE_BYTES) throw new Error('预置Bundle大小不合法');
      const sha = await this.hashBytes(data);
      if (request.isOtaRequest() && sha !== prepared.sha256) throw new Error('预置Bundle字节SHA不匹配');
      prepared.sha256 = sha;
      signal.throwIfCancelled();
      if (generation !== this.generation || !isSourceActive() || runtime !== PageBundleRuntimeRegistry.current() || epoch !== runtime?.userIdentityEpoch) throw new Error('prepared_source_destroyed');
      runtime?.validateNavigationSource(request.sourceSnapshotID);
      this.makeRoom(data.byteLength);
      const token = util.generateRandomUUID(false);
      const expiresAt = Date.now() + 30_000;
      const entry: PreparedRouteEntry = { token: token, routeKey: request.routeKey, bundleUrl: request.bundleUrl,
        lynxAppId: request.lynxAppId, bundleName: request.bundleName, sessionID: request.sessionID,
        sourceSnapshotID: request.sourceSnapshotID, runtime: runtime, epoch: epoch, prepared: prepared,
        sizeBytes: data.byteLength, expiresAt: expiresAt, expiresElapsed: this.now() + 30_000, isSourceActive: isSourceActive };
      this.entries.set(token, entry); this.bytes += entry.sizeBytes; prepared = null;
      this.scheduleExpiry();
      const result: Record<string, Object> = { token: token, routeKey: entry.routeKey, bundleURL: entry.bundleUrl,
        sizeBytes: entry.sizeBytes, byteCount: entry.sizeBytes, expiresAt: expiresAt, ttlMs: 30_000 };
      return { code: 0, message: 'Bundle已真实预加载', data: result };
    } catch (error) {
      prepared?.lease?.close();
      return { code: 1003, message: 'Bundle预加载失败: ' + String(error) };
    } finally { this.preparing = false; if (this.activeSignal === signal) this.activeSignal = null; }
  }

  /** 无效缓存退回正常Provider；确切路由不同不交错字节，token只消费一次。 */
  async consume(token: string, request: LynxPageRequest, signal: OtaPrepareSignal = new OtaPrepareSignal()): Promise<PreparedPageBundle | null> {
    this.cleanupExpired();
    const entry = this.entries.get(token);
    if (entry === undefined) return null;
    this.entries.delete(token); this.bytes -= entry.sizeBytes; this.scheduleExpiry();
    try {
      if (entry.bundleUrl !== request.bundleUrl || entry.routeKey !== request.routeKey ||
        entry.lynxAppId !== request.lynxAppId || entry.bundleName !== request.bundleName ||
        entry.sessionID !== request.sessionID || entry.sourceSnapshotID !== request.sourceSnapshotID) return null;
      if (!entry.isSourceActive() || entry.runtime !== PageBundleRuntimeRegistry.current() || entry.epoch !== entry.runtime?.userIdentityEpoch) return null;
      signal.throwIfCancelled();
      entry.runtime?.validateNavigationSource(request.sourceSnapshotID);
      if (request.isOtaRequest()) {
        if (entry.runtime === null) return null;
        try {
          const claimed = await entry.runtime.claimPrewarmed(entry.prepared, request.sessionID, request.sourceSnapshotID, signal);
          claimed.bytes = entry.prepared.bytes;
          return claimed;
        } catch (error) {
          // 预置仅是优化；已分类缓存失效回到真实Provider，取消/身份/来源与IO错误仍拒绝。
          const message = (error as Error).message;
          if (['stale_prewarm_release', 'stale_prewarm_bundle', 'stale_prewarm_decision',
            'stale_decision', 'invalid_prewarm_ticket', 'stale_prepared_route'].includes(message)) return null;
          throw error;
        }
      }
      return entry.prepared;
    } finally { entry.prepared.lease?.close(); }
  }

  cancel(token: string): ShellBridgeResult {
    if (token.trim().length === 0) return { code: 1001, message: 'prepared route token不能为空' };
    this.cleanupExpired();
    const entry = this.entries.get(token);
    if (entry === undefined) return { code: 1003, message: '预置路由不存在、已消费或已过期' };
    this.remove(entry); this.scheduleExpiry();
    return { code: 0, message: '预置路由已取消', data: { affectedCount: 1 } };
  }

  clear(): void {
    this.generation += 1; this.activeSignal?.cancel();
    Array.from(this.entries.values()).forEach((entry: PreparedRouteEntry): void => this.remove(entry));
    if (this.expiryTimer >= 0) clearTimeout(this.expiryTimer); this.expiryTimer = -1;
  }

  private remove(entry: PreparedRouteEntry): void {
    if (this.entries.get(entry.token) !== entry) return;
    this.entries.delete(entry.token); this.bytes -= entry.sizeBytes; entry.prepared.lease?.close();
  }
  private cleanupExpired(): void {
    const now = this.now(); const runtime = PageBundleRuntimeRegistry.current();
    Array.from(this.entries.values()).forEach((entry: PreparedRouteEntry): void => {
      if (entry.expiresElapsed <= now || entry.runtime !== runtime || entry.epoch !== runtime?.userIdentityEpoch || !entry.isSourceActive()) this.remove(entry);
    });
  }
  private makeRoom(incomingBytes: number): void {
    if (incomingBytes > 32 * 1024 * 1024) throw new Error('预置缓存超过32MiB');
    while (this.entries.size >= 4 || this.bytes + incomingBytes > 32 * 1024 * 1024) {
      const oldest = Array.from(this.entries.values())[0]; if (oldest === undefined) break; this.remove(oldest);
    }
  }
  private scheduleExpiry(): void {
    if (this.expiryTimer >= 0) clearTimeout(this.expiryTimer); this.expiryTimer = -1;
    if (this.entries.size === 0) return;
    const earliest = Math.min(...Array.from(this.entries.values()).map((entry: PreparedRouteEntry): number => entry.expiresElapsed));
    this.expiryTimer = setTimeout((): void => { this.expiryTimer = -1; this.cleanupExpired(); this.scheduleExpiry(); }, Math.max(1, earliest - this.now()));
  }
  private now(): number { return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false); }
  private async hashBytes(bytes: ArrayBuffer): Promise<string> {
    const digest = cryptoFramework.createMd('SHA256');
    for (let offset = 0; offset < bytes.byteLength; offset += 64 * 1024) {
      await digest.update({ data: new Uint8Array(bytes, offset, Math.min(64 * 1024, bytes.byteLength - offset)) });
    }
    const result = await digest.digest(); let hex = '';
    result.data.forEach((byte: number): void => { hex += byte.toString(16).padStart(2, '0'); });
    return 'sha256:' + hex;
  }
}
