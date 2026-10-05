import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import OtaJson from './OtaJson';
import { LynxOtaConfig, OtaLatestBundleLists, OtaPrepareSignal, OtaReleaseSnapshot } from './OtaModels';
import { OtaUserContext, OtaUserContextBox } from './OtaUserContext';
import { OtaLatestSelection, OtaSelection, OtaSelectionDirective } from './OtaSelection';

/** 仅供 TEST 模式注入的本地快照源；不进入默认网络请求链。 */
export interface OtaMockSource {
  fetchLatestBundleLists(): Promise<OtaLatestBundleLists>;
  fetchLatestBundleList(lynxAppId: string): Promise<OtaReleaseSnapshot>;
  downloadBundle(bundleUrl: string): Promise<ArrayBuffer>;
}

interface OtaHttpCacheEntry {
  body: string;
  etag: string;
}

/** OTA 服务端客户端。只接受 2xx；不限制 Host，但生产 Bundle 必须是 HTTPS。 */
export default class OtaApiClient {
  private readonly config: LynxOtaConfig;
  private readonly mockSource: OtaMockSource | null;
  private readonly activeRequests: Set<http.HttpRequest> = new Set();
  /** 进程内 latest JSON + ETag 缓存；进程重启后仍由服务端返回完整快照。 */
  private readonly responseCache: Map<string, OtaHttpCacheEntry> = new Map();
  private identityBox?: OtaUserContextBox;

  constructor(config: LynxOtaConfig, mockSource: OtaMockSource | null = null, identityBox?: OtaUserContextBox) {
    const normalized = config.apiBaseUrl.trim().toLowerCase();
    const localHttp = this.isTestHttpUrl(normalized);
    if (!normalized.startsWith('https://') &&
      !(config.allowLocalHTTPForTest && config.environment.toUpperCase() === 'TEST' && localHttp)) {
      throw new Error('OTA API 必须使用 HTTPS；仅 TEST + loopback 调试地址允许 HTTP');
    }
    this.config = config;
    this.mockSource = mockSource;
    this.identityBox = identityBox;
  }

  bindUserContext(identityBox: OtaUserContextBox): void { this.identityBox = identityBox; }

  async fetchLatestBundleLists(signal?: OtaPrepareSignal, context?: OtaUserContext): Promise<OtaLatestBundleLists> {
    this.validateContext(context);
    if (this.config.debugMockEnabled && this.mockSource !== null) {
      signal?.throwIfCancelled();
      const mock = await this.mockSource.fetchLatestBundleLists();
      this.validateResponse(mock, context);
      return mock;
    }
    const query = `env=${encodeURIComponent(this.config.environment)}` +
      `&hostApp=${encodeURIComponent(this.config.hostApp)}` +
      `&platform=harmony${this.contextQuery(context)}`;
    const raw = await this.getText(`${this.baseUrl()}/api/ota/v1/releases/latest-bundle-list?${query}`, signal, context);
    const parsed = OtaJson.parseLatestLists(raw);
    this.validateResponse(parsed, context);
    return parsed;
  }

  async fetchLatestBundleList(lynxAppId: string, signal?: OtaPrepareSignal, context?: OtaUserContext): Promise<OtaReleaseSnapshot> {
    const selected = await this.fetchLatestSelection(lynxAppId, signal, context);
    if (selected.release === undefined) throw new Error('no_compatible_release');
    return selected.release;
  }

  async fetchLatestSelection(lynxAppId: string, signal?: OtaPrepareSignal, context?: OtaUserContext): Promise<OtaLatestSelection> {
    this.validateContext(context);
    if (this.config.debugMockEnabled && this.mockSource !== null) {
      signal?.throwIfCancelled();
      const release = await this.mockSource.fetchLatestBundleList(lynxAppId);
      this.validateContext(context);
      if (context?.selectionEnabled) OtaSelection.fromRelease(release, context);
      return { release: release };
    }
    const query = `env=${encodeURIComponent(this.config.environment)}` +
      `&hostApp=${encodeURIComponent(this.config.hostApp)}` +
      `&lynxAppId=${encodeURIComponent(lynxAppId)}` +
      `&platform=harmony${this.contextQuery(context)}`;
    const raw = await this.getText(`${this.baseUrl()}/api/ota/v1/releases/latest-bundle-list?${query}`, signal, context);
    const parsed = OtaJson.parseLatestLists(raw);
    this.validateResponse(parsed, context);
    if (context?.selectionEnabled && (parsed.bundleLists.length + (parsed.directives?.length ?? 0) !== 1)) throw new Error('invalid_single_selection');
    const directive = parsed.directives?.find((item: OtaSelectionDirective) => item.lynxAppId === lynxAppId);
    if (directive !== undefined) return { directive: directive };
    const matched = parsed.bundleLists.find((item: OtaReleaseSnapshot) => item.lynxAppId === lynxAppId);
    if (matched === undefined) {
      throw new Error(`最新 bundle-list 中不存在 lynxAppId：${lynxAppId}`);
    }
    return { release: matched };
  }

  async downloadBundle(bundleUrl: string, signal?: OtaPrepareSignal, context?: OtaUserContext): Promise<ArrayBuffer> {
    this.validateContext(context);
    const normalized = bundleUrl.trim().toLowerCase();
    const localHttp = this.isTestHttpUrl(normalized);
    if (!normalized.startsWith('https://') &&
      !(this.config.allowLocalHTTPForTest && this.config.environment.toUpperCase() === 'TEST' && localHttp)) {
      throw new Error('OTA Bundle 必须使用 HTTPS；仅 TEST + loopback 调试地址允许 HTTP');
    }
    signal?.throwIfCancelled();
    if (this.config.debugMockEnabled && this.mockSource !== null) {
      const binary = await this.mockSource.downloadBundle(bundleUrl);
      signal?.throwIfCancelled();
      this.validateContext(context);
      return binary.slice(0);
    }
    const chunks: ArrayBuffer[] = [];
    const request = http.createHttp();
    this.activeRequests.add(request);
    let bytes = 0;
    let complete: (() => void) | null = null;
    let fail: ((error: Error) => void) | null = null;
    const ended = new Promise<void>((resolve, reject) => { complete = resolve; fail = reject; });
    request.on('dataReceive', (chunk: ArrayBuffer) => {
      try {
        signal?.throwIfCancelled(); this.validateContext(context);
        bytes += chunk.byteLength;
        if (bytes > 20 * 1024 * 1024) throw new Error('OTA Bundle 超过 20 MiB');
        chunks.push(chunk);
      } catch (error) { fail?.(error as Error); request.destroy(); }
    });
    request.on('dataEnd', () => { complete?.(); });
    try {
      let status = 0;
      const response = request.requestInStream(bundleUrl, { method: http.RequestMethod.GET, usingCache: false,
        connectTimeout: 15_000, readTimeout: 30_000 }).then((code: number) => { status = code; });
      await Promise.all([response, ended]);
      this.ensureSuccess(status, '下载 Bundle 失败');
      signal?.throwIfCancelled(); this.validateContext(context);
      if (bytes === 0) throw new Error('OTA Bundle 内容为空');
      const output = new Uint8Array(bytes);
      let offset = 0;
      chunks.forEach((chunk: ArrayBuffer) => { output.set(new Uint8Array(chunk), offset); offset += chunk.byteLength; });
      return output.buffer;
    } finally { request.destroy(); this.activeRequests.delete(request); }
  }

  /** 主 Bundle/Async 对象直接接收到本次 transaction 文件；接收阶段即执行字节预算。 */
  async downloadBundleToFile(bundleUrl: string, target: string, signal?: OtaPrepareSignal, context?: OtaUserContext,
    maximumBytes: number = 20 * 1024 * 1024): Promise<number> {
    this.validateContext(context); signal?.throwIfCancelled();
    if (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0 || maximumBytes > 20 * 1024 * 1024) throw new Error('OTA 下载字节预算不合法');
    const normalized = bundleUrl.trim().toLowerCase();
    if (!normalized.startsWith('https://') && !(this.config.allowLocalHTTPForTest &&
      this.config.environment.toUpperCase() === 'TEST' && this.isTestHttpUrl(normalized))) throw new Error('OTA Bundle 必须使用 HTTPS');
    const file = await fs.open(target, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    let request: http.HttpRequest | null = null;
    let received = 0;
    let queuedBytes = 0;
    let streamFailure: Error | null = null;
    let writes: Promise<void> = Promise.resolve();
    try {
      if (this.config.debugMockEnabled && this.mockSource !== null) {
        const bytes = await this.mockSource.downloadBundle(bundleUrl);
        if (bytes.byteLength === 0 || bytes.byteLength > maximumBytes) throw new Error('OTA Bundle 大小超过声明预算');
        signal?.throwIfCancelled(); this.validateContext(context);
        let offset = 0;
        while (offset < bytes.byteLength) {
          const chunk = bytes.slice(offset, Math.min(offset + 64 * 1024, bytes.byteLength));
          let written = 0;
          while (written < chunk.byteLength) {
            const count = await fs.write(file.fd, chunk.slice(written));
            if (count <= 0) throw new Error('OTA 文件写入失败');
            written += count;
          }
          offset += chunk.byteLength;
        }
        received = bytes.byteLength;
      } else {
        const stream = http.createHttp(); request = stream; this.activeRequests.add(stream);
        let complete: (() => void) | null = null;
        let fail: ((error: Error) => void) | null = null;
        const ended = new Promise<void>((resolve, reject) => { complete = resolve; fail = reject; });
        stream.on('dataReceive', (chunk: ArrayBuffer) => {
          if (streamFailure !== null) return;
          try {
            signal?.throwIfCancelled(); this.validateContext(context);
            received += chunk.byteLength;
            if (received > maximumBytes) throw new Error('OTA Bundle 超过声明字节预算');
            if (queuedBytes + chunk.byteLength > 512 * 1024) throw new Error('OTA 文件写入等待队列超过 512 KiB');
            queuedBytes += chunk.byteLength;
            writes = writes.then(async () => {
              signal?.throwIfCancelled(); this.validateContext(context);
              let written = 0;
              while (written < chunk.byteLength) {
                if (streamFailure !== null) throw streamFailure;
                const count = await fs.write(file.fd, chunk.slice(written));
                if (count <= 0) throw new Error('OTA 文件写入失败');
                written += count;
              }
            }).finally(() => { queuedBytes -= chunk.byteLength; });
            writes.catch((error: Error) => { streamFailure = streamFailure ?? error; fail?.(error); stream.destroy(); });
          } catch (error) { streamFailure = error as Error; fail?.(streamFailure); stream.destroy(); }
        });
        stream.on('dataEnd', () => { complete?.(); });
        let status = 0;
        const response = stream.requestInStream(bundleUrl, { method: http.RequestMethod.GET, usingCache: false,
          connectTimeout: 15_000, readTimeout: 30_000 }).then((code: number) => { status = code; });
        await Promise.all([response, ended]);
        this.ensureSuccess(status, '下载 Bundle 失败');
        await writes;
      }
      signal?.throwIfCancelled(); this.validateContext(context);
      if (received === 0) throw new Error('OTA Bundle 内容为空');
      await fs.fsync(file.fd);
      return received;
    } finally {
      request?.destroy(); if (request !== null) this.activeRequests.delete(request);
      // 请求失败时先等待已经接收的有界写入结束，避免关闭 fd 后后台写错新复用的 fd。
      await writes.catch(() => undefined);
      await fs.close(file);
    }
  }

  cancelAll(): void {
    this.activeRequests.forEach((request: http.HttpRequest) => request.destroy());
    this.activeRequests.clear();
  }

  private async getText(requestUrl: string, signal?: OtaPrepareSignal, context?: OtaUserContext): Promise<string> {
    signal?.throwIfCancelled();
    this.validateContext(context);
    const cacheKey = OtaUserContext.hash(requestUrl) + `|${context?.clientContextKey ?? 'legacy'}|${context?.identityEpoch ?? 0}`;
    const request = http.createHttp();
    this.activeRequests.add(request);
    try {
      const headers: Record<string, string> = { 'Accept': 'application/json', 'x-ota-resource-schema': '1' };
      if (this.config.clientToken.trim().length > 0) {
        headers['x-ota-client-token'] = this.config.clientToken;
      }
      const cached = this.responseCache.get(cacheKey);
      if (cached !== undefined) headers['If-None-Match'] = cached.etag;
      const response = await request.request(requestUrl, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        header: headers,
        connectTimeout: 10_000,
        readTimeout: 30_000
      });
      signal?.throwIfCancelled();
      this.validateContext(context);
      if (response.responseCode === 304 && cached !== undefined) {
        return cached.body;
      }
      this.ensureSuccess(response.responseCode, 'OTA 清单请求失败');
      const raw = response.result as string;
      if (raw.trim().length === 0) {
        throw new Error('OTA 清单响应为空');
      }
      this.validateResponse(OtaJson.parseLatestLists(raw), context);
      const responseHeaders = response.header as Record<string, Object>;
      let etag: string = '';
      Object.keys(responseHeaders).forEach((key: string) => {
        if (key.toLowerCase() === 'etag') etag = String(responseHeaders[key]);
      });
      if (etag.length > 0) {
        const cacheEntry: OtaHttpCacheEntry = { body: raw, etag: etag };
        this.responseCache.set(cacheKey, cacheEntry);
      }
      return raw;
    } finally {
      request.destroy();
      this.activeRequests.delete(request);
    }
  }

  private ensureSuccess(statusCode: number, prefix: string): void {
    if (statusCode < 200 || statusCode >= 300) {
      throw new Error(`${prefix}，HTTP ${statusCode}`);
    }
  }

  private validateContext(context: OtaUserContext | undefined): void {
    if (this.config.versionCode !== undefined && context === undefined) throw new Error('missing_captured_context');
    if (context !== undefined) {
      if (this.identityBox === undefined) throw new Error('missing_identity_box');
      this.identityBox.validate(context);
    }
  }

  private contextQuery(context: OtaUserContext | undefined): string {
    if (context === undefined || !context.selectionEnabled) return '';
    return `&versioncode=${encodeURIComponent(context.versionCode!)}` +
      `&lynxSdkVersion=${encodeURIComponent(context.lynxSdkVersion!)}` +
      (context.userId === undefined ? '' : `&userId=${encodeURIComponent(context.userId)}`);
  }

  private validateResponse(response: OtaLatestBundleLists, context: OtaUserContext | undefined): void {
    this.validateContext(context);
    if (context === undefined || !context.selectionEnabled) return;
    if (response.selectionSchemaVersion !== 1 || response.env !== context.env || response.hostApp !== context.hostApp || response.platform !== 'harmony') throw new Error('invalid_selection_scope');
    const apps = new Set<string>();
    response.bundleLists.forEach((release: OtaReleaseSnapshot) => {
      OtaSelection.fromRelease(release, context);
      if (apps.has(release.lynxAppId)) throw new Error('duplicate_selection');
      apps.add(release.lynxAppId);
    });
    response.directives?.forEach((directive: OtaSelectionDirective) => {
      OtaSelection.validateDirective(directive);
      if (apps.has(directive.lynxAppId)) throw new Error('duplicate_selection');
      apps.add(directive.lynxAppId);
    });
  }

  private baseUrl(): string {
    const value = this.config.apiBaseUrl.trim();
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
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
}
