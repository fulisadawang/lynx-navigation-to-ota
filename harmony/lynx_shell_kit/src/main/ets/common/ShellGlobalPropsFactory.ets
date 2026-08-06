import { display } from '@kit.ArkUI';
import ShellJson from './ShellJson';
import ShellConstants from './ShellConstants';
import LynxPageRequest from '../model/LynxPageRequest';

/** 构建传给 Lynx 的 globalProps，保留业务字段并补充稳定宿主信息。 */
export default class ShellGlobalPropsFactory {
  static build(businessJson: string, request?: LynxPageRequest): Object {
    const business = ShellJson.parseObject(businessJson) as Record<string, Object>;
    const currentDisplay = display.getDefaultDisplaySync();
    business['platform'] = 'harmony';
    business['os'] = 'harmony';
    business['lynxVersion'] = '4.0';
    business['hostAppVersion'] = ShellConstants.APP_VERSION;
    business['density'] = currentDisplay.densityPixels;
    business['screenWidthPx'] = currentDisplay.width;
    business['screenHeightPx'] = currentDisplay.height;
    business['screenWidth'] = currentDisplay.width / currentDisplay.densityPixels;
    business['screenHeight'] = currentDisplay.height / currentDisplay.densityPixels;
    const queryItems = (business['queryItems'] as Record<string, Object>) ?? {};
    if (request !== undefined) {
      queryItems['fullscreen'] = request.fullscreen ? '1' : '0';
      queryItems['hide_nav_bar'] = request.hideNavigationBar ? '1' : '0';
      queryItems['hide_status_bar'] = request.hideStatusBar ? '1' : '0';
    }
    business['queryItems'] = queryItems;
    // v1 跨端契约：每次打开同一个 Bundle 都必须拥有独立 pageId，不能使用 Bundle 名称或
    // hash 作为消息目标。containerID 继续保留为旧 Shell 字段，但值改为当前 entry 身份。
    const pageId = request?.entryID ?? `lynx-shell-${request?.bundleUrl ?? 'container'}`;
    const pageKey = request?.routeKey ?? request?.bundleUrl ?? 'lynx';
    business['containerID'] = pageId;
    business['__lynxRouterContainerId'] = pageId;
    business['__lynxRouterPageId'] = pageId;
    business['__lynxRouterPageKey'] = pageKey;
    business['__lynxRouterSessionId'] = request?.sessionID ?? '';
    business['__lynxRouterNavigationModel'] = 'native_page_stack';
    business['__lynxRouterPlatformContainer'] = 'arkui_page';
    business['__lynxRouterParams'] = queryItems;
    return business;
  }

  private constructor() {
  }
}
