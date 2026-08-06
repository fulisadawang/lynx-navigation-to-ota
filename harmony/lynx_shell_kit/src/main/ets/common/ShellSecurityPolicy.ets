import url from '@ohos.url';
import ShellConstants from './ShellConstants';

/** URL 校验结果。 */
export class ShellUrlValidationResult {
  readonly valid: boolean;
  readonly message: string;

  constructor(valid: boolean, message: string = '') {
    this.valid = valid;
    this.message = message;
  }
}

/** 远程资源安全策略：不限制 Host，保留协议、模板后缀与本地路径校验。 */
export default class ShellSecurityPolicy {
  /** 默认彻底关闭 HTTP；调试时需要同时改为 true 且路由携带 allowHttpInDebug=true。 */
  static readonly ALLOW_DEBUG_HTTP: boolean = false;

  static validateTemplateUrl(rawUrl: string, pageAllowsHttp: boolean): ShellUrlValidationResult {
    return ShellSecurityPolicy.validateRemoteUrl(
      rawUrl,
      pageAllowsHttp,
      true
    );
  }

  static validateResourceUrl(rawUrl: string): ShellUrlValidationResult {
    return ShellSecurityPolicy.validateRemoteUrl(
      rawUrl,
      false,
      false
    );
  }

  static validateLocalRawFilePath(path: string): ShellUrlValidationResult {
    const normalized = path.trim();
    if (normalized.length === 0) {
      return new ShellUrlValidationResult(false, '本地 Bundle 路径不能为空');
    }
    if (normalized.startsWith('/') || normalized.includes('\\') || normalized.includes('\0')) {
      return new ShellUrlValidationResult(false, '本地 Bundle 路径包含非法片段');
    }

    // rawfile 只接受相对路径。出现 :// 说明调用方传入了未支持的 Scheme。
    if (normalized.includes('://')) {
      return new ShellUrlValidationResult(false, '本地 Bundle 不支持该 URL Scheme');
    }

    const segments = normalized.split('/');
    if (segments.some((segment: string) => segment === '..' || segment.length === 0)) {
      return new ShellUrlValidationResult(false, '本地 Bundle 路径包含非法目录片段');
    }
    return new ShellUrlValidationResult(true);
  }

  static isRemoteUrl(rawUrl: string): boolean {
    const lower = rawUrl.toLowerCase();
    return lower.startsWith('https://') || lower.startsWith('http://');
  }

  private static validateRemoteUrl(
    rawUrl: string,
    pageAllowsHttp: boolean,
    requireBundleSuffix: boolean
  ): ShellUrlValidationResult {
    try {
      const parsed = url.URL.parseURL(rawUrl);
      const protocol = parsed.protocol.toLowerCase();
      const isHttps = protocol === 'https:';
      const isAllowedDebugHttp = protocol === 'http:' && ShellSecurityPolicy.ALLOW_DEBUG_HTTP && pageAllowsHttp;
      if (!isHttps && !isAllowedDebugHttp) {
        return new ShellUrlValidationResult(false, '远程资源仅允许 HTTPS');
      }

      if (requireBundleSuffix && !parsed.pathname.toLowerCase().endsWith('.lynx.bundle')) {
        return new ShellUrlValidationResult(false, '远程模板必须以 .lynx.bundle 结尾');
      }
      return new ShellUrlValidationResult(true);
    } catch (error) {
      return new ShellUrlValidationResult(false, `远程 URL 无法解析: ${error}`);
    }
  }

  private constructor() {
  }
}
