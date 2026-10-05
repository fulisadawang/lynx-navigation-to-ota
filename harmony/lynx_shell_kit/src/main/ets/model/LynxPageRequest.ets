import ShellRoutePresentationSpec from '../transition/ShellRoutePresentationSpec';
import ShellTransitionSpec from '../transition/ShellTransitionSpec';
import ShellConstants from '../common/ShellConstants';
import { ShellPageParams } from '../common/ShellTypes';

/**
 * Lynx 容器唯一输入模型。
 *
 * Ability、首页、深链和 Native Module 都先生成该对象，容器页面不再重复解析 URL。
 */
export default class LynxPageRequest {
  bundleUrl: string = ShellConstants.DEFAULT_LOCAL_BUNDLE;
  /** 非空时表示 OTA 页面；bundleUrl 仅作为 Lynx render key。 */
  lynxAppId: string = '';
  bundleName: string = '';
  routeKey: string = '';
  sessionID: string = '';
  sourceSnapshotID: string = '';
  sourceEntryID: string = '';
  transitionJSON: string = '';
  routeConfigJSON: string = '';
  routeType?: string;
  routeOptionsJSON: string = '';
  transparent: boolean = false;
  preparedRouteToken: string = '';
  nativeViewID: string = '';
  sourceNativeViewID: string = '';
  transitionID: string = '';
  nativeNavigationHosted: boolean = false;
  backGestureEnabled: boolean = true;
  entryID: string = '';
  routerIndex: number = 0;
  hasHostAnchor: boolean = true;
  title: string = 'Lynx';
  initDataJson: string = '{}';
  globalPropsJson: string = '{}';
  /** Lynx 页面默认由页面自身绘制，不叠加原生标题栏。 */
  hideNavigationBar: boolean = true;
  hideStatusBar: boolean = false;
  fullscreen: boolean = false;
  orientation: string = 'auto';
  /** 页面打开/替换时是否保留 ArkUI 系统转场；默认开启。 */
  animated: boolean = true;
  /** 页面级软键盘避让策略；默认采用 ArkUI 的 OFFSET 系统行为。 */
  keyboardBehavior: string = 'system';
  backgroundColor: string = '#FFFFFF';
  widthPx: number = 0;
  heightPx: number = 0;
  allowHttpInDebug: boolean = false;

  toRouterParams(): ShellPageParams {
    return {
      bundleUrl: this.bundleUrl,
      lynxAppId: this.lynxAppId,
      bundleName: this.bundleName,
      routeKey: this.routeKey,
      sessionID: this.sessionID,
      sourceSnapshotID: this.sourceSnapshotID,
      transitionJSON: this.transitionJSON,
      routeConfigJSON: this.routeConfigJSON,
      routeType: this.routeType, routeOptionsJSON: this.routeOptionsJSON, transparent: this.transparent, preparedRouteToken: this.preparedRouteToken,
      sourceNativeViewID: this.sourceNativeViewID,
      nativeViewID: this.nativeViewID,
      transitionID: this.transitionID,
      nativeNavigationHosted: this.nativeNavigationHosted,
      backGestureEnabled: this.backGestureEnabled,
      entryID: this.entryID,
      routerIndex: this.routerIndex,
      hasHostAnchor: this.hasHostAnchor,
      title: this.title,
      initDataJson: this.initDataJson,
      globalPropsJson: this.globalPropsJson,
      hideNavigationBar: this.hideNavigationBar,
      hideStatusBar: this.hideStatusBar,
      fullscreen: this.fullscreen,
      orientation: this.orientation,
      animated: this.animated,
      keyboardBehavior: this.keyboardBehavior,
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
    request.lynxAppId = params.lynxAppId ?? request.lynxAppId;
    request.bundleName = params.bundleName ?? request.bundleName;
    request.routeKey = params.routeKey ?? request.routeKey;
    request.sessionID = params.sessionID ?? request.sessionID;
    request.sourceSnapshotID = params.sourceSnapshotID ?? request.sourceSnapshotID;
    request.transitionJSON = params.transitionJSON ?? request.transitionJSON;
    request.routeConfigJSON = params.routeConfigJSON ?? request.routeConfigJSON;
    request.routeType = params.routeType; request.routeOptionsJSON = params.routeOptionsJSON ?? '';
    request.transparent = params.transparent ?? false; request.preparedRouteToken = params.preparedRouteToken ?? '';
    request.sourceNativeViewID = params.sourceNativeViewID ?? '';
    request.nativeViewID = params.nativeViewID ?? request.nativeViewID;
    request.transitionID = params.transitionID ?? request.transitionID;
    request.nativeNavigationHosted = params.nativeNavigationHosted ?? false;
    request.backGestureEnabled = params.backGestureEnabled ?? request.backGestureEnabled;
    request.entryID = params.entryID ?? request.entryID;
    request.routerIndex = params.routerIndex ?? request.routerIndex;
    request.hasHostAnchor = params.hasHostAnchor ?? request.hasHostAnchor;
    request.title = params.title ?? request.title;
    request.initDataJson = params.initDataJson ?? request.initDataJson;
    request.globalPropsJson = params.globalPropsJson ?? request.globalPropsJson;
    request.hideNavigationBar = params.hideNavigationBar ?? request.hideNavigationBar;
    request.hideStatusBar = params.hideStatusBar ?? request.hideStatusBar;
    request.fullscreen = params.fullscreen ?? request.fullscreen;
    request.orientation = params.orientation ?? request.orientation;
    request.animated = params.animated ?? request.animated;
    request.keyboardBehavior = params.keyboardBehavior ?? request.keyboardBehavior;
    request.backgroundColor = params.backgroundColor ?? request.backgroundColor;
    request.widthPx = params.widthPx ?? request.widthPx;
    request.heightPx = params.heightPx ?? request.heightPx;
    request.allowHttpInDebug = params.allowHttpInDebug ?? request.allowHttpInDebug;
    return request;
  }

  presentationSpec(): ShellRoutePresentationSpec {
    return ShellRoutePresentationSpec.parse(this.routeType, this.routeOptionsJSON.length === 0 ? undefined : JSON.parse(this.routeOptionsJSON) as Object,
      this.routeConfigJSON.length === 0 ? undefined : JSON.parse(this.routeConfigJSON) as Object, this.transparent);
  }
  transitionSpec(): ShellTransitionSpec {
    const raw = this.transitionJSON.length === 0 ? undefined : JSON.parse(this.transitionJSON) as Object;
    const config = this.routeConfigJSON.length === 0 ? undefined : JSON.parse(this.routeConfigJSON) as Object;
    const spec = ShellTransitionSpec.parse(raw, config); spec.presentation = this.presentationSpec();
    const gesture = raw === undefined ? {} : ((raw as Record<string, Object>)['popGesture'] ?? {}) as Record<string, Object>;
    const route = config === undefined ? {} : config as Record<string, Object>;
    if (route['fullscreenDrag'] !== undefined || gesture['fullScreen'] === undefined) spec.popGesture.fullScreen = spec.presentation.fullscreenDrag;
    if (route['popGestureDirection'] !== undefined || gesture['direction'] === undefined) spec.popGesture.direction = spec.presentation.popGestureDirection;
    // hero表面/滚动由Lynx持有，原生只承载透明全屏，避免双份Sheet手势。
    if (spec.presentation.mode === 'heroSheet') spec.popGesture.enabled = false;
    return spec;
  }

  isOtaRequest(): boolean {
    return this.lynxAppId.trim().length > 0 && this.bundleName.trim().length > 0;
  }
}
