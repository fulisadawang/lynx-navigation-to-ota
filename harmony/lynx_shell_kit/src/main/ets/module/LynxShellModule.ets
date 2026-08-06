import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { LLog, LynxContext, LynxModule } from '@lynx/lynx';
import ShellConstants from '../common/ShellConstants';
import { ShellAppInfo, ShellBridgeResult, ShellMessageCount, ShellRouterPayload } from '../common/ShellTypes';
import LynxRouteParser from '../routing/LynxRouteParser';
import LynxNavigator from '../routing/LynxNavigator';
import ShellMessageHub from '../common/ShellMessageHub';

/**
 * Lynx 页面统一原生能力入口。
 *
 * 该类保持普通 Module（不加 @Sendable）：导航和 callback 按 Lynx Harmony 的异步 Module
 * 语义执行；持久化使用 HarmonyOS Preferences 同步 API，避免回调前数据尚未落盘。
 */
export class LynxShellModule extends LynxModule {
  private dataPreferences: preferences.Preferences | null = null;

  constructor(context: LynxContext, param?: Object) {
    super(context, param);
    this.initializePreferences();
    LLog.d(ShellConstants.TAG, 'LynxShellModule instance created');
  }

  public open(url: string, optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    const parsed = LynxRouteParser.parseWithOptions(url, optionsJSON);
    if (!parsed.isSuccess || parsed.request === null) {
      callback({ code: 1001, message: parsed.errorMessage });
      return;
    }

    LynxNavigator.openResult(parsed.request, false, optionsJSON).then((result: ShellBridgeResult) => {
      callback(result);
    });
  }

  public close(callback: (result: ShellBridgeResult) => void): void {
    try {
      callback(LynxNavigator.closeResult());
    } catch (error) {
      callback({ code: 1500, message: `关闭页面失败: ${error}` });
    }
  }

  public back(delta: number, optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    callback(LynxNavigator.back(delta, optionsJSON));
  }

  public popTo(routeKey: string, callback: (result: ShellBridgeResult) => void): void {
    callback(LynxNavigator.popTo(routeKey));
  }

  public popToWithOptions(
    routeKey: string,
    optionsJSON: string,
    callback: (result: ShellBridgeResult) => void
  ): void {
    callback(LynxNavigator.popTo(routeKey, optionsJSON));
  }

  public closeAll(callback: (result: ShellBridgeResult) => void): void {
    callback(LynxNavigator.closeAll());
  }

  public closeAllWithOptions(optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    callback(LynxNavigator.closeAll());
  }

  public reLaunch(optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    callback(LynxNavigator.reLaunch());
  }

  public redirect(url: string, optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    const parsed = LynxRouteParser.parseWithOptions(url, optionsJSON);
    if (!parsed.isSuccess || parsed.request === null) {
      callback({ code: 1001, message: parsed.errorMessage });
      return;
    }
    LynxNavigator.redirectResult(parsed.request).then((result: ShellBridgeResult) => callback(result));
  }

  public getNavigationState(callback: (result: ShellBridgeResult) => void): void {
    const result = LynxNavigator.getNavigationState();
    LLog.d(ShellConstants.TAG, `bridge getNavigationState invoked: code=${result.code}`);
    callback(result);
  }

  public closeWithResult(resultJSON: string, callback: (result: ShellBridgeResult) => void): void {
    callback(LynxNavigator.closeWithResult(resultJSON));
  }

  public consumeNavigationResult(callback: (result: ShellBridgeResult) => void): void {
    const result = LynxNavigator.consumeNavigationResult();
    LLog.d(ShellConstants.TAG, `bridge consumeNavigationResult invoked: code=${result.code}`);
    callback(result);
  }

  /** 页面向宿主发送消息；回包结构与 Android/iOS 的 emitToNative 对齐。 */
  public emitToNative(
    eventName: string,
    payload: ShellRouterPayload,
    callback: (result: ShellBridgeResult) => void
  ): void {
    const reply = ShellMessageHub.dispatchFromPage(this.context, eventName, payload);
    callback({
      code: reply.accepted ? 0 : 1,
      message: reply.message,
      data: reply.data
    });
  }

  /** 页面向当前进程内全部活体 Lynx 页面广播事件。 */
  public broadcast(
    eventName: string,
    payload: ShellRouterPayload,
    callback: (result: ShellBridgeResult) => void
  ): void {
    try {
      const affectedCount = ShellMessageHub.broadcast(eventName, payload);
      const data: ShellMessageCount = { affectedCount: affectedCount };
      callback({ code: 0, message: '广播已发送', data: data });
    } catch (error) {
      callback({ code: 1001, message: `广播发送失败: ${error}` });
    }
  }

  /** 页面按 pageId 向另一个 Lynx 页面发送事件。 */
  public sendToPage(
    targetPageId: string,
    eventName: string,
    payload: ShellRouterPayload,
    callback: (result: ShellBridgeResult) => void
  ): void {
    try {
      const sent = ShellMessageHub.sendToPage(targetPageId, eventName, payload);
      const data: ShellMessageCount = { affectedCount: sent ? 1 : 0 };
      callback({
        code: sent ? 0 : 1,
        message: sent ? '定向消息已发送' : '目标页面不存在或已经销毁',
        data: data
      });
    } catch (error) {
      callback({ code: 1001, message: `定向消息发送失败: ${error}` });
    }
  }

  public prepareRoute(url: string, optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    const parsed = LynxRouteParser.parseWithOptions(url, optionsJSON);
    if (!parsed.isSuccess || parsed.request === null) {
      callback({ code: 1001, message: parsed.errorMessage });
      return;
    }
    callback(LynxNavigator.prepareRoute(url, optionsJSON));
  }

  public cancelPreparedRoute(token: string, callback: (result: ShellBridgeResult) => void): void {
    callback(LynxNavigator.cancelPreparedRoute(token));
  }

  public markTransitionReady(transactionID: string, callback: (result: ShellBridgeResult) => void): void {
    callback(LynxNavigator.markTransitionReady(transactionID));
  }

  public getTransitionState(callback: (result: ShellBridgeResult) => void): void {
    callback(LynxNavigator.getTransitionState());
  }

  /** Harmony 首版只保证导航/存储桥；媒体方法保留稳定错误码，避免 JS 侧再遇到“方法不存在”。 */
  public chooseMedia(optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    callback({ code: 1004, message: 'HarmonyOS 媒体选择桥尚未接入' });
  }

  public uploadFile(optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    callback({ code: 1004, message: 'HarmonyOS 文件上传桥尚未接入' });
  }

  public uploadImage(optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    callback({ code: 1004, message: 'HarmonyOS 图片上传桥尚未接入' });
  }

  public downloadFile(optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    callback({ code: 1004, message: 'HarmonyOS 文件下载桥尚未接入' });
  }

  public saveDataURL(optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    callback({ code: 1004, message: 'HarmonyOS DataURL 保存桥尚未接入' });
  }

  public setStorageItem(key: string, value: string): void {
    if (!this.isValidStorageKey(key) || this.dataPreferences === null) {
      return;
    }
    try {
      this.dataPreferences.putSync(key, value);
      this.dataPreferences.flushSync();
    } catch (error) {
      console.error(ShellConstants.TAG, `setStorageItem failed: ${error}`);
    }
  }

  public getStorageItem(key: string, callback: (value: string) => void): void {
    if (!this.isValidStorageKey(key) || this.dataPreferences === null) {
      callback('');
      return;
    }
    try {
      callback(this.dataPreferences.getSync(key, '') as string);
    } catch (error) {
      console.error(ShellConstants.TAG, `getStorageItem failed: ${error}`);
      callback('');
    }
  }

  public removeStorageItem(key: string): void {
    if (!this.isValidStorageKey(key) || this.dataPreferences === null) {
      return;
    }
    try {
      this.dataPreferences.deleteSync(key);
      this.dataPreferences.flushSync();
    } catch (error) {
      console.error(ShellConstants.TAG, `removeStorageItem failed: ${error}`);
    }
  }

  public clearStorage(): void {
    if (this.dataPreferences === null) {
      return;
    }
    try {
      this.dataPreferences.clearSync();
      this.dataPreferences.flushSync();
    } catch (error) {
      console.error(ShellConstants.TAG, `clearStorage failed: ${error}`);
    }
  }

  public getAppInfo(callback: (info: ShellAppInfo) => void): void {
    callback({
      platform: 'harmony',
      appVersion: ShellConstants.APP_VERSION,
      buildNumber: ShellConstants.BUILD_NUMBER,
      systemVersion: deviceInfo.osFullName
    });
  }

  private initializePreferences(): void {
    try {
      this.dataPreferences = preferences.getPreferencesSync(
        getContext(),
        { name: ShellConstants.STORAGE_NAME }
      );
    } catch (error) {
      this.dataPreferences = null;
      console.error(ShellConstants.TAG, `Preferences initialization failed: ${error}`);
    }
  }

  private isValidStorageKey(key: string): boolean {
    return key.trim().length > 0 && key.length <= 128;
  }
}
