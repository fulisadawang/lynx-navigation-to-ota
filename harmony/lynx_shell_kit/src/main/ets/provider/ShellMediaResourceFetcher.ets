import { LynxMediaResourceFetcher, LynxOptionalBool, LynxResourceRequest } from '@lynx/lynx';

/** 将 Lynx 的 local/assets 逻辑地址转换为 HarmonyOS rawfile 地址。 */
export default class ShellMediaResourceFetcher extends LynxMediaResourceFetcher {
  shouldRedirectUrl(request: LynxResourceRequest): string {
    if (request.url.startsWith('local://')) {
      return `resource://rawfile/${request.url.substring('local://'.length)}`;
    }
    if (request.url.startsWith('assets://')) {
      return `resource://rawfile/${request.url.substring('assets://'.length)}`;
    }
    return request.url;
  }

  isLocalResource(resourceUrl: string): LynxOptionalBool {
    // 交由 Lynx/Image Service 根据重定向后的 resource:// 协议判断，避免重复维护规则。
    return LynxOptionalBool.UNDEFINED;
  }
}
