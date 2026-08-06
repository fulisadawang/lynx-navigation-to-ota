// Copyright (c) 2025 TikTok Pte. Ltd.
// Licensed under the Apache License Version 2.0 that can be found in the
// LICENSE file in the root directory of this source tree.
import type {} from '@lynx-js/types';

declare let NativeModules: {
  LynxShellModule: {
    open(
      route: string,
      optionsJSON: string,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    close(callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void): void;
    back(
      delta: number,
      optionsJSON: string,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    popTo(
      routeKey: string,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    popToWithOptions(
      routeKey: string,
      optionsJSON: string,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    closeAll(callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void): void;
    closeAllWithOptions(
      optionsJSON: string,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    reLaunch(
      optionsJSON: string,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    redirect(
      route: string,
      optionsJSON: string,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    getNavigationState(
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    closeWithResult(
      resultJSON: string,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    consumeNavigationResult(
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    emitToNative(
      eventName: string,
      payload: Record<string, unknown>,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    broadcast(
      eventName: string,
      payload: Record<string, unknown>,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    sendToPage(
      targetPageId: string,
      eventName: string,
      payload: Record<string, unknown>,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    /**
     * 预取 Bundle 字节并返回一次性 token；不会提前创建原生页面或 LynxView。
     */
    prepareRoute(
      route: string,
      optionsJSON: string,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    cancelPreparedRoute(
      token: string,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    /**
     * 只发送业务 ready；共享元素坐标与动画 progress 均由原生宿主管理。
     */
    markTransitionReady(
      transactionID: string,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    getTransitionState(
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ): void;
    setStorageItem(key: string, value: string): void;
    getStorageItem(key: string, callback: (value: string) => void): void;
    removeStorageItem(key: string): void;
    clearStorage(): void;
    getAppInfo(callback: (value: Record<string, unknown>) => void): void;
    /** Android Router OTA 扩展：按 appId 直接删除磁盘中的下载 Bundle。 */
    deleteOtaBundles?: (
      lynxAppId: string,
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ) => void;
    /** Android Router OTA 扩展：直接删除所有 appId 的下载 Bundle。 */
    deleteAllOtaBundles?: (
      callback: (result: { code: number; message?: string; msg?: string; data?: any }) => void,
    ) => void;
    chooseMedia(optionsJSON: string, callback: (result: any) => void): void;
    uploadFile(optionsJSON: string, callback: (result: any) => void): void;
    uploadImage(optionsJSON: string, callback: (result: any) => void): void;
    downloadFile(optionsJSON: string, callback: (result: any) => void): void;
    saveDataURL(optionsJSON: string, callback: (result: any) => void): void;
  };
};

declare module '@lynx-js/types' {
  interface GlobalProps {
    preferredTheme?: string;
    theme: string;
    isNotchScreen: boolean;
  }

  interface InputProps {
    value?: string;
    defaultValue?: string;
  }
}
