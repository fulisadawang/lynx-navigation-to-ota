/** Lynx 页面侧 NativeModules 类型声明。 */
export interface NativeResult {
  code: number;
  message: string;
}

export interface AppInfo {
  platform: 'android' | 'ios' | 'harmony';
  appVersion: string;
  buildNumber: string;
  systemVersion: string;
}

export interface LynxShellModule {
  /**
   * 普通页面传完整 bundle URL；OTA 页面在 optionsJSON 同时传 lynxAppId + bundleName。
   */
  open(url: string, optionsJSON: string, callback: (result: NativeResult) => void): void;
  close(callback: (result: NativeResult) => void): void;
  setStorageItem(key: string, value: string): void;
  getStorageItem(key: string, callback: (value: string) => void): void;
  removeStorageItem(key: string): void;
  clearStorage(): void;
  getAppInfo(callback: (info: AppInfo) => void): void;
}

declare global {
  const NativeModules: {
    LynxShellModule: LynxShellModule;
  };
}

export {};
