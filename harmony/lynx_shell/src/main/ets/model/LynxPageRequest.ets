import ShellConstants from '../common/ShellConstants';
import { ShellPageParams } from '../common/ShellTypes';

/**
 * Lynx 容器唯一输入模型。
 *
 * Ability、首页、深链和 Native Module 都先生成该对象，容器页面不再重复解析 URL。
 */
export default class LynxPageRequest {
  bundleUrl: string = ShellConstants.DEFAULT_LOCAL_BUNDLE;
  title: string = 'Lynx';
  initDataJson: string = '{}';
  globalPropsJson: string = '{}';
  /** Lynx 页面默认由页面自身绘制，不叠加原生标题栏。 */
  hideNavigationBar: boolean = true;
  hideStatusBar: boolean = false;
  fullscreen: boolean = false;
  orientation: string = 'auto';
  backgroundColor: string = '#FFFFFF';
  widthPx: number = 0;
  heightPx: number = 0;
  allowHttpInDebug: boolean = false;

  toRouterParams(): ShellPageParams {
    return {
      bundleUrl: this.bundleUrl,
      title: this.title,
      initDataJson: this.initDataJson,
      globalPropsJson: this.globalPropsJson,
      hideNavigationBar: this.hideNavigationBar,
      hideStatusBar: this.hideStatusBar,
      fullscreen: this.fullscreen,
      orientation: this.orientation,
      backgroundColor: this.backgroundColor,
      widthPx: this.widthPx,
      heightPx: this.heightPx,
      allowHttpInDebug: this.allowHttpInDebug
    };
  }

  static fromRouterParams(value: Object | undefined): LynxPageRequest {
    const params = (value ?? {}) as ShellPageParams;
    const request = new LynxPageRequest();
    request.bundleUrl = params.bundleUrl ?? request.bundleUrl;
    request.title = params.title ?? request.title;
    request.initDataJson = params.initDataJson ?? request.initDataJson;
    request.globalPropsJson = params.globalPropsJson ?? request.globalPropsJson;
    request.hideNavigationBar = params.hideNavigationBar ?? request.hideNavigationBar;
    request.hideStatusBar = params.hideStatusBar ?? request.hideStatusBar;
    request.fullscreen = params.fullscreen ?? request.fullscreen;
    request.orientation = params.orientation ?? request.orientation;
    request.backgroundColor = params.backgroundColor ?? request.backgroundColor;
    request.widthPx = params.widthPx ?? request.widthPx;
    request.heightPx = params.heightPx ?? request.heightPx;
    request.allowHttpInDebug = params.allowHttpInDebug ?? request.allowHttpInDebug;
    return request;
  }
}
