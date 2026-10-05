import { http } from '@kit.NetworkKit';
import util from '@ohos.util';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';
import { LynxHarmonyNativeIO, LYNX_INLINE_BYTES, lynxUTF8Bytes } from './LynxHarmonyNativeIO';

interface LynxCapacitorHttpMultipartBody { body: ArrayBuffer; contentType: string; }

export class LynxHarmonyHttp {
  private readonly owner: LynxHarmonyNativeOwner;
  constructor(owner: LynxHarmonyNativeOwner) { this.owner = owner; }
  public request(method: string, options: Record<string, Object>): Promise<Object> {
    return LynxHarmonyNativeIO.run(this.owner, async (): Promise<Object> => {
      this.owner.checkActive();
      const rawUrl = String(options['url'] ?? '');
      if (!/^https?:\/\//.test(rawUrl)) throw new Error('INVALID_ARGUMENT: url 必须为 HTTP(S)');
      const url = this.appendHttpParams(rawUrl, options);
      const requested = method === 'request' ? String(options['method'] ?? 'GET').toUpperCase() : method.toUpperCase();
      if (!['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'].includes(requested)) throw new Error('INVALID_ARGUMENT: 不支持的 HTTP method');
      if (options['disableRedirects'] === true) throw new Error('UNSUPPORTED: NetworkKit 不提供本适配器可用的禁止跳转能力');
      if (options['disableRedirects'] !== undefined && typeof options['disableRedirects'] !== 'boolean') throw new Error('INVALID_ARGUMENT: disableRedirects 必须为 boolean');
      const config: http.HttpRequestOptions = { method: this.httpMethod(requested), expectDataType: http.HttpDataType.ARRAY_BUFFER, maxLimit: LYNX_INLINE_BYTES };
      if (requested === 'PATCH') config.customMethod = 'PATCH';
      const read = this.httpTimeout(options, 'readTimeout');
      const connect = this.httpTimeout(options, 'connectTimeout');
      if (read !== null) config.readTimeout = read;
      if (connect !== null) config.connectTimeout = connect;
      if (options['headers'] !== undefined) config.header = options['headers'];
      const data = options['data'];
      if (data !== undefined && data !== null) {
        const kind = String(options['dataType'] ?? '').toLowerCase();
        if (kind === 'file') config.extraData = await LynxHarmonyNativeIO.directTask('decodeBody', [data]);
        else if (kind === 'formdata') {
          const multipart = await LynxHarmonyNativeIO.directTask('multipartBody', [data, this.httpHeaderValue(options['headers'] ?? {}, 'content-type')]) as LynxCapacitorHttpMultipartBody;
          config.extraData = multipart.body;
          const headers = this.httpHeaders(options['headers']);
          headers['Content-Type'] = multipart.contentType;
          config.header = headers;
        } else {
          const encoded = typeof data === 'string' ? data : String(await LynxHarmonyNativeIO.directTask('stringify', [data]));
          if (lynxUTF8Bytes(encoded) > LYNX_INLINE_BYTES) throw new Error('PAYLOAD_TOO_LARGE: HTTP 内联请求体超过 512 KiB');
          config.extraData = encoded;
        }
      }
      this.owner.checkActive();
      const request = http.createHttp();
      const key = 'http:' + util.generateRandomUUID(false);
      this.owner.own(key, (): void => request.destroy());
      try {
        const response = await request.request(url, config);
        this.owner.checkActive();
        const type = String(options['responseType'] ?? 'text').toLowerCase();
        const isJSON = this.httpHeaderValue(response.header, 'content-type').toLowerCase().includes('application/json') || type === 'json';
        const value = await LynxHarmonyNativeIO.directTask('httpResponse', [response.result, isJSON, type === 'arraybuffer' || type === 'blob']);
        this.owner.checkActive();
        return { status: response.responseCode, headers: response.header, url: url, data: value };
      } finally { this.owner.disown(key); request.destroy(); }
    });
  }
  private appendHttpParams(url: string, options: Record<string, Object>): string {
    const rawParams = options['params'];
    if (rawParams === null || rawParams === undefined || typeof rawParams !== 'object' || Array.isArray(rawParams)) return url;
    const params = rawParams as Record<string, Object>;
    const shouldEncode = options['shouldEncodeUrlParams'] === undefined || options['shouldEncodeUrlParams'] === null
      ? true
      : Boolean(options['shouldEncodeUrlParams']);
    const pairs: string[] = [];
    Object.keys(params).forEach((key: string): void => {
      const rawKey = shouldEncode ? encodeURIComponent(key) : key;
      const rawValue = params[key];
      const values: Array<Object> = Array.isArray(rawValue) ? rawValue as Array<Object> : [rawValue];
      values.forEach((value: Object): void => {
        const text = String(value);
        pairs.push(rawKey + '=' + (shouldEncode ? encodeURIComponent(text) : text));
      });
    });
    if (pairs.length === 0) return url;
    const hashIndex = url.indexOf('#');
    const beforeFragment = hashIndex >= 0 ? url.substring(0, hashIndex) : url;
    const fragment = hashIndex >= 0 ? url.substring(hashIndex) : '';
    const separator = beforeFragment.indexOf('?') < 0
      ? '?'
      : beforeFragment.endsWith('?') || beforeFragment.endsWith('&') ? '' : '&';
    return beforeFragment + separator + pairs.join('&') + fragment;
  }

  private httpMethod(raw: string): http.RequestMethod {
    switch (raw) {
      case 'POST': return http.RequestMethod.POST;
      case 'PUT': return http.RequestMethod.PUT;
      case 'PATCH': return http.RequestMethod.POST;
      case 'DELETE': return http.RequestMethod.DELETE;
      case 'HEAD': return http.RequestMethod.HEAD;
      case 'OPTIONS': return http.RequestMethod.OPTIONS;
      default: return http.RequestMethod.GET;
    }
  }

  /** NetworkKit 的 timeout 单位也是毫秒；非法值不能静默退回 SDK 默认值。 */
  private httpTimeout(options: Record<string, Object>, key: string): number | null {
    const raw = options[key];
    if (raw === undefined || raw === null || (typeof raw === 'string' && raw.trim().length === 0)) return null;
    const value = Number(raw);
    if (!Number.isFinite(value) || value < 0) throw new Error(`${key} must be a finite non-negative number`);
    return Math.floor(value);
  }

  /** NetworkKit header key 的大小写不固定，按 HTTP 的不区分大小写语义读取。 */
  private httpHeaderValue(headers: Object, key: string): string {
    const values = headers as Record<string, Object>;
    const actualKey = Object.keys(values).find((name: string): boolean => name.toLowerCase() === key.toLowerCase());
    return actualKey === undefined ? '' : String(values[actualKey]);
  }

  /** 复制 HTTP header，供 multipart 自动补齐 boundary。 */
  private httpHeaders(value: Object | undefined): Record<string, Object> {
    const output: Record<string, Object> = {};
    if (value !== undefined && value !== null && typeof value === 'object') {
      const source = value as Record<string, Object>;
      Object.keys(source).forEach((key: string): void => { output[key] = source[key]; });
    }
    return output;
  }

}
