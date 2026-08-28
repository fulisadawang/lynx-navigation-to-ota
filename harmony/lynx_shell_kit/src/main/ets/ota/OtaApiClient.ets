import http from '@ohos.net.http';
import OtaJson from './OtaJson';
import { LynxOtaConfig, OtaLatestBundleLists, OtaPrepareSignal, OtaReleaseSnapshot } from './OtaModels';

/** 仅供 TEST 模式注入的本地快照源；不进入默认网络请求链。 */
export interface OtaMockSource {
  fetchLatestBundleLists(): Promise<OtaLatestBundleLists>;
  fetchLatestBundleList(lynxAppId: string): Promise<OtaReleaseSnapshot>;
  downloadBundle(bundleUrl: string): Promise<ArrayBuffer>;
}

/** OTA 服务端客户端。只接受 2xx；不限制 Host，但生产 Bundle 必须是 HTTPS。 */
export default class OtaApiClient {
  private readonly config: LynxOtaConfig;
  private readonly mockSource: OtaMockSource | null;
  private readonly activeRequests: Set<http.HttpRequest> = new Set();

  constructor(config: LynxOtaConfig, mockSource: OtaMockSource | null = null) {
    if (!config.apiBaseUrl.trim().toLowerCase().startsWith('https://')) {
      throw new Error('OTA API 必须使用 HTTPS');
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
    if (!bundleUrl.toLowerCase().startsWith('https://')) {
      throw new Error('OTA Bundle 必须使用 HTTPS');
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
      const response = await request.request(requestUrl, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        header: headers,
        connectTimeout: 10_000,
        readTimeout: 30_000
      });
      signal?.throwIfCancelled();
      this.ensureSuccess(response.responseCode, 'OTA 清单请求失败');
      const raw = response.result as string;
      if (raw.trim().length === 0) {
        throw new Error('OTA 清单响应为空');
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
}
