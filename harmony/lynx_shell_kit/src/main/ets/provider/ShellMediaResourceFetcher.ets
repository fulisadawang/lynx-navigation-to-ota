import { LynxMediaResourceFetcher, LynxOptionalBool, LynxResourceRequest } from '@lynx/lynx';
import { OtaAsyncResourceResolver } from '../ota/OtaModels';

/** 将 Lynx 的 local/assets 逻辑地址转换为 HarmonyOS rawfile 地址。 */
export default class ShellMediaResourceFetcher extends LynxMediaResourceFetcher {
  private static readonly MEDIA_EXTENSIONS: Set<string> = new Set(['png', 'jpg', 'jpeg', 'webp', 'gif', 'svg', 'avif', 'mp4', 'webm']);
  private readonly asyncResolver?: OtaAsyncResourceResolver;
  constructor(asyncResolver?: OtaAsyncResourceResolver) { super(); this.asyncResolver = asyncResolver; }

  shouldRedirectUrl(request: LynxResourceRequest): string {
    const kind = this.asyncResolver?.kind(request.url);
    if (kind !== null && kind !== undefined) {
      if (kind !== 'asset' || !ShellMediaResourceFetcher.isMedia(request.url)) return '';
      return `file://${this.asyncResolver!.resolvePath(request.url)}`;
    }
    if (this.asyncResolver !== undefined && request.url.startsWith('webpack:///')) return '';
    if (request.url.startsWith('local://')) {
      return `resource://rawfile/${request.url.substring('local://'.length)}`;
    }
    if (request.url.startsWith('assets://')) {
      return `resource://rawfile/${request.url.substring('assets://'.length)}`;
    }
    return request.url;
  }

  isLocalResource(resourceUrl: string): LynxOptionalBool {
    if (this.asyncResolver?.kind(resourceUrl) === 'asset' && ShellMediaResourceFetcher.isMedia(resourceUrl)) {
      return LynxOptionalBool.TRUE;
    }
    // 交由 Lynx/Image Service 根据重定向后的 resource:// 协议判断，避免重复维护规则。
    return LynxOptionalBool.UNDEFINED;
  }

  private static isMedia(url: string): boolean {
    const path = url.split('?')[0].split('#')[0];
    return ShellMediaResourceFetcher.MEDIA_EXTENSIONS.has(path.substring(path.lastIndexOf('.') + 1).toLowerCase());
  }
}
