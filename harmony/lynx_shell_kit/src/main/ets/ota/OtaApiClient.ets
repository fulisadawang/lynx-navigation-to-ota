import http from '@ohos.net.http';
import OtaJson from './OtaJson';
import { LynxOtaConfig, OtaLatestBundleLists, OtaPrepareSignal, OtaReleaseSnapshot } from './OtaModels';

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

  constructor(config: LynxOtaConfig, mockSource: OtaMockSource | null = null) {
    const normalized = config.apiBaseUrl.trim().toLowerCase();
    const localHttp = this.isTestHttpUrl(normalized);
    if (!normalized.startsWith('https://') &&
      !(config.allowLocalHTTPForTest && config.environment.toUpperCase() === 'TEST' && localHttp)) {
      throw new Error('OTA API 必须使用 HTTPS；仅 TEST + loopback 调试地址允许 HTTP');
    }
    this.config = config;
    this.mockSource = mockSource;
  }

  async fetchLatestBundleLists(signal?: OtaPrepareSignal): Promise<OtaLatestBundleLists> {
    if (this.config.debugMockEnabled && this.mockSource !== null) {
      signal?.throwIfCancelled();
      return this.mockSource.fetchLatestBundleLists();
    }
    const query = `env=${encodeURIComponent(this.config.environment)}` +
      `&hostApp=${encodeURIComponent(this.config.hostApp)}` +
      `&platform=${encodeURIComponent(this.config.requestPlatform())}`;
    const raw = await this.getText(`${this.baseUrl()}/api/ota/v1/releases/latest-bundle-list?${query}`, signal);
    return OtaJson.parseLatestLists(raw);
  }

  async fetchLatestBundleList(lynxAppId: string, signal?: OtaPrepareSignal): Promise<OtaReleaseSnapshot> {
    if (this.config.debugMockEnabled && this.mockSource !== null) {
      signal?.throwIfCancelled();
      return this.mockSource.fetchLatestBundleList(lynxAppId);
    }
    const query = `env=${encodeURIComponent(this.config.environment)}` +
      `&hostApp=${encodeURIComponent(this.config.hostApp)}` +
      `&lynxAppId=${encodeURIComponent(lynxAppId)}` +
      `&platform=${encodeURIComponent(this.config.requestPlatform())}`;
    const raw = await this.getText(`${this.baseUrl()}/api/ota/v1/releases/latest-bundle-list?${query}`, signal);
    const parsed = OtaJson.parseLatestLists(raw);
    const matched = parsed.bundleLists.find((item: OtaReleaseSnapshot) => item.lynxAppId === lynxAppId);
    if (matched === undefined) {
      throw new Error(`最新 bundle-list 中不存在 lynxAppId：${lynxAppId}`);
    }
    return matched;
  }

  async downloadBundle(bundleUrl: string, signal?: OtaPrepareSignal): Promise<ArrayBuffer> {
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
      return binary.slice(0);
    }
    const request = http.createHttp();
    this.activeRequests.add(request);
    try {
      const response = await request.request(bundleUrl, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: false,
        connectTimeout: 15_000,
        readTimeout: 30_000
      });
      signal?.throwIfCancelled();
      this.ensureSuccess(response.responseCode, `下载 Bundle 失败：${bundleUrl}`);
      const binary = response.result as ArrayBuffer;
      if (binary === undefined || binary.byteLength === 0) {
        throw new Error('OTA Bundle 内容为空');
      }
      if (binary.byteLength > 20 * 1024 * 1024) {
        throw new Error('OTA Bundle 超过 20 MB');
      }
      return binary;
    } finally {
      request.destroy();
      this.activeRequests.delete(request);
    }
  }

  cancelAll(): void {
    this.activeRequests.forEach((request: http.HttpRequest) => request.destroy());
    this.activeRequests.clear();
  }

  private async getText(requestUrl: string, signal?: OtaPrepareSignal): Promise<string> {
    signal?.throwIfCancelled();
    const request = http.createHttp();
    this.activeRequests.add(request);
    try {
      const headers: Record<string, string> = { 'Accept': 'application/json' };
      if (this.config.clientToken.trim().length > 0) {
        headers['x-ota-client-token'] = this.config.clientToken;
      }
      const cached = this.responseCache.get(requestUrl);
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
      if (response.responseCode === 304 && cached !== undefined) {
        return cached.body;
      }
      this.ensureSuccess(response.responseCode, 'OTA 清单请求失败');
      const raw = response.result as string;
      if (raw.trim().length === 0) {
        throw new Error('OTA 清单响应为空');
      }
      const responseHeaders = response.header as Record<string, Object>;
      let etag: string = '';
      Object.keys(responseHeaders).forEach((key: string) => {
        if (key.toLowerCase() === 'etag') etag = String(responseHeaders[key]);
      });
      if (etag.length > 0) {
        const cacheEntry: OtaHttpCacheEntry = { body: raw, etag: etag };
        this.responseCache.set(requestUrl, cacheEntry);
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
