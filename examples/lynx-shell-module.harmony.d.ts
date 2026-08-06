/** HarmonyOS NativeModules 类型；导航、生命周期和消息协议与 Android/iOS 对齐。 */
export interface HarmonyNativeResult<T = unknown> {
  code: number;
  message: string;
  data?: T;
}

export interface HarmonyAppInfo {
  platform: 'harmony';
  appVersion: string;
  buildNumber: string;
  systemVersion: string;
}

export interface HarmonyLynxShellModule {
  open(
    url: string,
    optionsJSON: string,
    callback: (result: HarmonyNativeResult) => void
  ): void;
  close(callback: (result: HarmonyNativeResult) => void): void;
  back(delta: number, optionsJSON: string, callback: (result: HarmonyNativeResult) => void): void;
  popTo(routeKey: string, callback: (result: HarmonyNativeResult) => void): void;
  popToWithOptions(routeKey: string, optionsJSON: string, callback: (result: HarmonyNativeResult) => void): void;
  closeAll(callback: (result: HarmonyNativeResult) => void): void;
  closeAllWithOptions(optionsJSON: string, callback: (result: HarmonyNativeResult) => void): void;
  reLaunch(optionsJSON: string, callback: (result: HarmonyNativeResult) => void): void;
  redirect(url: string, optionsJSON: string, callback: (result: HarmonyNativeResult) => void): void;
  getNavigationState(callback: (result: HarmonyNativeResult) => void): void;
  closeWithResult(resultJSON: string, callback: (result: HarmonyNativeResult) => void): void;
  consumeNavigationResult(callback: (result: HarmonyNativeResult) => void): void;
  emitToNative(eventName: string, payload: Record<string, unknown>, callback: (result: HarmonyNativeResult) => void): void;
  broadcast(eventName: string, payload: Record<string, unknown>, callback: (result: HarmonyNativeResult) => void): void;
  sendToPage(targetPageId: string, eventName: string, payload: Record<string, unknown>, callback: (result: HarmonyNativeResult) => void): void;
  setStorageItem(key: string, value: string): void;
  getStorageItem(key: string, callback: (value: string) => void): void;
  removeStorageItem(key: string): void;
  clearStorage(): void;
  getAppInfo(callback: (info: HarmonyAppInfo) => void): void;
}

declare global {
  const NativeModules: {
    LynxShellModule: HarmonyLynxShellModule;
  };
}

export {};
