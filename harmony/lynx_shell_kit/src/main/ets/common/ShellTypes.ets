/** 原生 Bridge 的统一结果对象。 */
export interface ShellBridgeResult {
  code: number;
  message: string;
  data?: Object;
}

/** ArkTS 的动态消息对象统一使用显式 Record，避免 untyped object literal 编译错误。 */
export type ShellRouterPayload = Record<string, Object>;

/** 消息发送类 Bridge 的受影响页面数量。 */
export interface ShellMessageCount {
  affectedCount: number;
}

/** 三端 Native Page Stack 共用的页面实例身份。 */
export interface ShellRouterPageInfo {
  pageId: string;
  containerId: string;
  pageKey: string;
  hostMode: string;
}

/** 页面发给 HarmonyOS 宿主的消息。 */
export interface ShellRouterMessage {
  source: ShellRouterPageInfo;
  eventName: string;
  payload: Object;
}

/** 宿主处理 JS -> Native 消息后的统一回复。 */
export interface ShellRouterMessageReply {
  accepted: boolean;
  message: string;
  data?: Object;
}

/** HarmonyOS 宿主可选安装的双向消息处理器。 */
export type ShellRouterMessageHandler = (message: ShellRouterMessage) => ShellRouterMessageReply;

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
  /** OTA 逻辑地址；绝对文件路径禁止进入 Router params。 */
  lynxAppId?: string;
  bundleName?: string;
  routeKey?: string;
  sessionID?: string;
  entryID?: string;
  routerIndex?: number;
  hasHostAnchor?: boolean;
  title?: string;
  initDataJson?: string;
  globalPropsJson?: string;
  hideNavigationBar?: boolean;
  hideStatusBar?: boolean;
  fullscreen?: boolean;
  orientation?: string;
  /** 是否使用系统页面转场；默认开启。 */
  animated?: boolean;
  /** 页面获得输入焦点后，ArkUI 如何处理软键盘遮挡。 */
  keyboardBehavior?: string;
  backgroundColor?: string;
  widthPx?: number;
  heightPx?: number;
  allowHttpInDebug?: boolean;
  __lynxRouterContainerId?: string;
  __lynxRouterPageId?: string;
  __lynxRouterPageKey?: string;
  __lynxRouterSessionId?: string;
}

/** Native Module open 的 JSON Options。 */
export interface ShellOpenOptions {
  launchMode?: string;
  /** 是否使用系统页面转场；未传时默认 true。 */
  animated?: boolean;
  title?: string;
  initData?: Object;
  globalProps?: Object;
  hideNavigationBar?: boolean;
  hideNavBar?: boolean;
  hideStatusBar?: boolean;
  fullscreen?: boolean;
  orientation?: string;
  screenOrientation?: string;
  /** `system` / `resize` / `pan` / `nothing`。 */
  keyboardBehavior?: string;
  backgroundColor?: string;
  width?: number;
  widthPx?: number;
  height?: number;
  heightPx?: number;
  allowHttpInDebug?: boolean;
  allowHttp?: boolean;
  /** JS Bridge 可通过 options 传入 OTA 逻辑地址。 */
  lynxAppId?: string;
  bundleName?: string;
}

/** Lynx 页面创建后发送的宿主事件参数。 */
export class ShellViewAppearPayload {
  url: string;
  platform: string = 'harmony';

  constructor(url: string) {
    this.url = url;
  }
}
