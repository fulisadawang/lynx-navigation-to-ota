/** 原生 Bridge 的统一结果对象。 */
export interface ShellBridgeResult {
  code: number;
  message: string;
}

/** 返回给 Lynx 页面的宿主信息。 */
export interface ShellAppInfo {
  platform: string;
  appVersion: string;
  buildNumber: string;
  systemVersion: string;
}

/** Router 参数使用显式字段，避免在业务代码中到处访问无类型 Object。 */
export interface ShellPageParams {
  bundleUrl?: string;
  title?: string;
  initDataJson?: string;
  globalPropsJson?: string;
  hideNavigationBar?: boolean;
  hideStatusBar?: boolean;
  fullscreen?: boolean;
  orientation?: string;
  backgroundColor?: string;
  widthPx?: number;
  heightPx?: number;
  allowHttpInDebug?: boolean;
}

/** Native Module open 的 JSON Options。 */
export interface ShellOpenOptions {
  title?: string;
  initData?: Object;
  globalProps?: Object;
  hideNavigationBar?: boolean;
  hideNavBar?: boolean;
  hideStatusBar?: boolean;
  fullscreen?: boolean;
  orientation?: string;
  screenOrientation?: string;
  backgroundColor?: string;
  width?: number;
  widthPx?: number;
  height?: number;
  heightPx?: number;
  allowHttpInDebug?: boolean;
  allowHttp?: boolean;
}

/** Lynx 页面创建后发送的宿主事件参数。 */
export class ShellViewAppearPayload {
  url: string;
  platform: string = 'harmony';

  constructor(url: string) {
    this.url = url;
  }
}
