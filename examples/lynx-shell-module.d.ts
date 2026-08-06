/** Android/iOS 页面侧完整 NativeModules 类型声明。 */
export interface NativeResult<T = unknown> {
  code: number;
  message?: string;
  msg?: string;
  /** 经过 Playground wrapper 归一化后保留的宿主原始 code。 */
  nativeCode?: number;
  data?: T;
}

export interface AppInfo {
  platform: 'android' | 'ios';
  appVersion: string;
  buildNumber: string;
  systemVersion: string;
}

export type TransitionStyle =
  | 'default'
  | 'fade'
  | 'slide'
  | 'slideUp'
  | 'zoom'
  | 'sharedElement'
  | 'openContainer'
  | 'none';

export type SharedElementRectTween =
  | 'materialRectArc'
  | 'materialRectCenterArc'
  | 'linear'
  | 'elasticIn'
  | 'elasticOut'
  | 'elasticInOut'
  | 'bounceIn'
  | 'bounceOut'
  | 'bounceInOut'
  | `cubic-bezier(${string})`;

export interface SharedElementSpec {
  key: string;
  sourceSelector: string;
  targetSelector: string;
  transitionOnGesture?: boolean;
  shuttleOnPush?: 'from' | 'to';
  shuttleOnPop?: 'from' | 'to';
  rectTweenType?: SharedElementRectTween;
  sourceStyle?: {
    backgroundColor?: string;
    cornerRadius?: number;
    elevation?: number;
  };
  targetStyle?: {
    backgroundColor?: string;
    cornerRadius?: number;
    elevation?: number;
  };
}

export interface NativeTransitionSpec {
  style?: TransitionStyle;
  fallbackStyle?: 'fade' | 'slide' | 'none';
  durationMs?: number;
  readyTimeoutMs?: number;
  /** 旧单元素字段，继续兼容。 */
  sharedElement?: SharedElementSpec;
  /** Skyline 多共享元素字段；最多 8 个，后声明的元素 overlay 层级更高。 */
  sharedElements?: SharedElementSpec[];
  openContainer?: {
    sourceSelector: string;
    closedColor?: string;
    middleColor?: string;
    openColor?: string;
    closedCornerRadius?: number;
    openCornerRadius?: number;
    closedElevation?: number;
    openElevation?: number;
    /** Skyline 正式字段，默认 fade。 */
    transitionType?: 'fade' | 'fadeThrough';
    /** 默认 300ms。 */
    transitionDuration?: number;
    /** 旧字段，继续兼容。 */
    contentTransition?: 'fade' | 'fadeThrough';
  };
  popGesture?: {
    enabled?: boolean;
    direction?: 'horizontal' | 'vertical' | 'multi';
    fullScreen?: boolean;
    edgeWidth?: number;
  };
}

export type SkylineRouteType =
  | 'wx://bottom-sheet'
  | 'wx://upwards'
  | 'wx://zoom'
  | 'wx://cupertino-modal'
  | 'wx://cupertino-modal-inside'
  | 'wx://modal-navigation'
  | 'wx://modal';

export interface SkylineRouteConfig {
  opaque?: boolean;
  maintainState?: boolean;
  transitionDuration?: number;
  reverseTransitionDuration?: number;
  barrierColor?: string;
  barrierDismissible?: boolean;
  barrierLabel?: string;
  canTransitionTo?: boolean;
  canTransitionFrom?: boolean;
  allowEnterRouteSnapshotting?: boolean;
  allowExitRouteSnapshotting?: boolean;
  fullscreenDrag?: boolean;
  popGestureDirection?: 'horizontal' | 'vertical' | 'multi';
}

export interface SkylineRouteOptions {
  round?: boolean;
  /** 单位 vh；bottom-sheet 默认 60。 */
  height?: number;
}

export interface TransitionState {
  transactionID: string;
  status:
    | 'idle'
    | 'accepted'
    | 'waitingTarget'
    | 'running'
    | 'settling'
    | 'completed'
    | 'cancelled'
    | 'degraded'
    | 'failed';
  requestedTransition: TransitionStyle;
  effectiveTransition: TransitionStyle;
  direction: 'push' | 'pop';
  progress: number;
  reason?: string;
  routeKey?: string;
  updatedAt: number;
}

export interface LynxShellModule {
  open(url: string, optionsJSON: string, callback: (result: NativeResult) => void): void;
  close(callback: (result: NativeResult) => void): void;
  back(
    delta: number,
    optionsJSON: string,
    callback: (result: NativeResult) => void
  ): void;
  popTo(routeKey: string, callback: (result: NativeResult) => void): void;
  popToWithOptions(
    routeKey: string,
    optionsJSON: string,
    callback: (result: NativeResult) => void
  ): void;
  closeAll(callback: (result: NativeResult) => void): void;
  closeAllWithOptions(
    optionsJSON: string,
    callback: (result: NativeResult) => void
  ): void;
  reLaunch(optionsJSON: string, callback: (result: NativeResult) => void): void;
  redirect(
    url: string,
    optionsJSON: string,
    callback: (result: NativeResult) => void
  ): void;
  getNavigationState(callback: (result: NativeResult) => void): void;
  closeWithResult(
    resultJSON: string,
    callback: (result: NativeResult) => void
  ): void;
  consumeNavigationResult(callback: (result: NativeResult) => void): void;
  emitToNative(
    eventName: string,
    payload: Record<string, unknown>,
    callback: (result: NativeResult) => void
  ): void;
  broadcast(
    eventName: string,
    payload: Record<string, unknown>,
    callback: (result: NativeResult) => void
  ): void;
  sendToPage(
    targetPageId: string,
    eventName: string,
    payload: Record<string, unknown>,
    callback: (result: NativeResult) => void
  ): void;
  /**
   * 壳级 Bundle 预取。它不会预先创建 LynxView、Activity 或 UIViewController。
   */
  prepareRoute(
    url: string,
    optionsJSON: string,
    callback: (result: NativeResult<{
      token: string;
      expiresAt?: number;
      sizeBytes?: number;
      routeKey?: string;
    }>) => void
  ): void;
  cancelPreparedRoute(
    token: string,
    callback: (result: NativeResult) => void
  ): void;
  /**
   * 页面只发送内容 ready；原生会自行测量 idSelector 并驱动转场进度。
   */
  markTransitionReady(
    transactionID: string,
    callback: (result: NativeResult) => void
  ): void;
  getTransitionState(
    callback: (result: NativeResult<TransitionState>) => void
  ): void;
  setStorageItem(key: string, value: string): void;
  getStorageItem(key: string, callback: (value: string) => void): void;
  removeStorageItem(key: string): void;
  clearStorage(): void;
  getAppInfo(callback: (info: AppInfo) => void): void;
  /** Android Router OTA 扩展：按 appId 直接删除磁盘中的下载 Bundle。 */
  deleteOtaBundles?: (
    lynxAppId: string,
    callback: (result: NativeResult<{
      lynxAppId: string;
      deleted: boolean;
    }>) => void
  ) => void;
  /** Android Router OTA 扩展：直接删除所有 appId 的下载 Bundle。 */
  deleteAllOtaBundles?: (
    callback: (result: NativeResult<{
      scope: 'all';
      deleted: boolean;
    }>) => void
  ) => void;
}

declare global {
  const NativeModules: {
    LynxShellModule: LynxShellModule;
  };
}

export {};
