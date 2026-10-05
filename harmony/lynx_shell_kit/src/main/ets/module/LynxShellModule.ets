import PageBundleRuntimeRegistry from '../ota/OtaModels';
import HostNativeModules from '../common/HostNativeModules';
import { ShellMediaResult } from '../common/ShellTypes';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { LLog, LynxContext, LynxModule } from '@lynx/lynx';
import ShellConstants from '../common/ShellConstants';
import { ShellAppInfo, ShellBridgeResult, ShellMessageCount, ShellRouterPayload } from '../common/ShellTypes';
import { ShellLocaleStateValue } from '../common/ShellLocale';
import LynxRouteParser from '../routing/LynxRouteParser';
import LynxNavigator from '../routing/LynxNavigator';
import LynxRouter from '../routing/LynxRouter';
import ShellMessageHub from '../common/ShellMessageHub';
import BusinessEventReporter, { NativeBusinessEventResult } from '../monitoring/BusinessEventReporter';
import ShellTransitionRuntime from '../transition/ShellTransitionRuntime';
import ShellPreparedRouteStore from '../transition/ShellPreparedRouteStore';

interface ShellLocaleReadData {
  state: ShellLocaleStateValue;
}

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

    if (this.rejectNavigationSource(callback)) return;
    parsed.request.sourceSnapshotID = ShellMessageHub.sourceSnapshotID(this.context);
    parsed.request.sourceEntryID = ShellMessageHub.pageId(this.context) ?? '';
    parsed.request.sourceNativeViewID = ShellTransitionRuntime.shared.viewIDForContext(this.context);
    parsed.request.sessionID = ShellMessageHub.sourceSessionID(this.context);
    parsed.request.hasHostAnchor = ShellMessageHub.sourceHasHostAnchor(this.context);
    try { PageBundleRuntimeRegistry.current()?.validateNavigationSource(parsed.request.sourceSnapshotID); }
    catch (error) { callback({ code: 1002, message: '来源导航版本已退休或正在恢复' }); return; }
    LynxNavigator.openResult(parsed.request, false, optionsJSON).then((result: ShellBridgeResult) => {
      callback(result);
    });
  }

  public close(callback: (result: ShellBridgeResult) => void): void {
    if (this.rejectNavigationSource(callback)) return;
    let result: ShellBridgeResult;
    try {
      result = LynxNavigator.closeResult();
    } catch (error) {
      result = { code: 1500, message: `关闭页面失败: ${error}` };
    }
    callback(result);
  }

  public back(delta: number, optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    if (this.rejectNavigationSource(callback)) return;
    callback(LynxNavigator.back(delta, optionsJSON));
  }

  public popTo(routeKey: string, callback: (result: ShellBridgeResult) => void): void {
    if (this.rejectNavigationSource(callback)) return;
    callback(LynxNavigator.popTo(routeKey));
  }

  public popToWithOptions(
    routeKey: string,
    optionsJSON: string,
    callback: (result: ShellBridgeResult) => void
  ): void {
    if (this.rejectNavigationSource(callback)) return;
    callback(LynxNavigator.popTo(routeKey, optionsJSON));
  }

  public closeAll(callback: (result: ShellBridgeResult) => void): void {
    if (this.rejectNavigationSource(callback)) return;
    callback(LynxNavigator.closeAll());
  }

  public closeAllWithOptions(optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    if (this.rejectNavigationSource(callback)) return;
    callback(LynxNavigator.closeAll(optionsJSON));
  }

  public reLaunch(optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    if (this.rejectNavigationSource(callback)) return;
    callback(LynxNavigator.reLaunch(optionsJSON));
  }

  public redirect(url: string, optionsJSON: string, callback: (result: ShellBridgeResult) => void): void {
    const parsed = LynxRouteParser.parseWithOptions(url, optionsJSON);
    if (!parsed.isSuccess || parsed.request === null) {
      callback({ code: 1001, message: parsed.errorMessage });
      return;
    }
    if (this.rejectNavigationSource(callback)) return;
    parsed.request.sourceSnapshotID = ShellMessageHub.sourceSnapshotID(this.context);
    parsed.request.sourceEntryID = ShellMessageHub.pageId(this.context) ?? '';
    parsed.request.sourceNativeViewID = ShellTransitionRuntime.shared.viewIDForContext(this.context);
    parsed.request.sessionID = ShellMessageHub.sourceSessionID(this.context);
    parsed.request.hasHostAnchor = ShellMessageHub.sourceHasHostAnchor(this.context);
    try { PageBundleRuntimeRegistry.current()?.validateNavigationSource(parsed.request.sourceSnapshotID); }
    catch (error) { callback({ code: 1002, message: '来源导航版本已退休或正在恢复' }); return; }
    LynxNavigator.redirectResult(parsed.request, optionsJSON).then((result: ShellBridgeResult) => callback(result));
  }

  public getNavigationState(callback: (result: ShellBridgeResult) => void): void {
    const result = LynxNavigator.getNavigationState();
    LLog.d(ShellConstants.TAG, `bridge getNavigationState invoked: code=${result.code}`);
    callback(result);
  }

  public closeWithResult(resultJSON: string, callback: (result: ShellBridgeResult) => void): void {
    if (this.rejectNavigationSource(callback)) return;
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

  public reportBusinessEvent(
    group: string,
    name: string,
    attributesJSON: string,
    callback: (result: NativeBusinessEventResult) => void
  ): void {
    const result = BusinessEventReporter.report(this.context, group, name, attributesJSON);
    callback(result);
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

  /** 页面设置 App 语言；资源加载状态由页面自己的 i18next 实例独立维护。 */
  public setLocale(locale: string, callback: (result: ShellBridgeResult) => void): void {
    callback(LynxRouter.setLocale(locale));
  }

  /** 页面读取当前宿主 LocaleState；新页面也会在初始 GlobalProps 中得到同一状态。 */
  public getLocale(callback: (result: ShellBridgeResult) => void): void {
    const data: ShellLocaleReadData = { state: LynxRouter.currentLocaleState() };
    callback({
      code: 0,
      message: '当前语言读取成功',
      data: data
    });
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
    if (this.rejectNavigationSource(callback)) return;
    parsed.request.sourceSnapshotID = ShellMessageHub.sourceSnapshotID(this.context);
    parsed.request.sourceEntryID = ShellMessageHub.pageId(this.context) ?? '';
    parsed.request.sourceNativeViewID = ShellTransitionRuntime.shared.viewIDForContext(this.context);
    parsed.request.sessionID = ShellMessageHub.sourceSessionID(this.context);
    parsed.request.hasHostAnchor = ShellMessageHub.sourceHasHostAnchor(this.context);
    const request = parsed.request;
    ShellPreparedRouteStore.shared.prepare(request, (): boolean =>
      ShellTransitionRuntime.shared.viewIDForContext(this.context).length > 0).then(
        (result: ShellBridgeResult): void => callback(result),
        (error: Object): void => callback({ code: 1003, message: 'Bundle预加载失败: ' + String(error) }));
  }

  public cancelPreparedRoute(token: string, callback: (result: ShellBridgeResult) => void): void {
    callback(ShellPreparedRouteStore.shared.cancel(token));
  }

  // 保活页面的旧定时器不能关闭另一个前台页面；已退休版本的活体页面仍允许退出。
  private rejectNavigationSource(callback: (result: ShellBridgeResult) => void): boolean {
    if (ShellMessageHub.isNavigationBusy()) {
      callback({ code: 1006, message: '原生转场正在进行' });
      return true;
    }
    if (!ShellMessageHub.isContextVisible(this.context) || !HostNativeModules.isContextVisible(this.context)) {
      callback({ code: 1002, message: '来源Context已销毁或不在前台' });
      return true;
    }
    return false;
  }

  public markTransitionReady(transactionID: string, callback: (result: ShellBridgeResult) => void): void {
    callback(LynxNavigator.markTransitionReady(transactionID));
  }

  public getTransitionState(callback: (result: ShellBridgeResult) => void): void {
    callback(LynxNavigator.getTransitionState());
  }

  public markOtaHealthy(callback: (result: ShellBridgeResult) => void): void { ShellMessageHub.markOtaHealthy(this.context, callback); }

  public setBackGestureEnabled(enabled: boolean, callback: (result: ShellBridgeResult) => void): void {
    callback(ShellMessageHub.setBackGestureEnabled(this.context, enabled));
  }

  public chooseMedia(optionsJSON: string, callback: (result: ShellMediaResult) => void): void { this.callMedia('chooseMedia', optionsJSON, callback); }
  public uploadFile(optionsJSON: string, callback: (result: ShellMediaResult) => void): void { this.callMedia('uploadFile', optionsJSON, callback); }
  public uploadImage(optionsJSON: string, callback: (result: ShellMediaResult) => void): void { this.callMedia('uploadImage', optionsJSON, callback); }
  public downloadFile(optionsJSON: string, callback: (result: ShellMediaResult) => void): void { this.callMedia('downloadFile', optionsJSON, callback); }
  public saveDataURL(optionsJSON: string, callback: (result: ShellMediaResult) => void): void { this.callMedia('saveDataURL', optionsJSON, callback); }

  private callMedia(method: string, optionsJSON: string, callback: (result: ShellMediaResult) => void): void {
    HostNativeModules.callMedia(this.context, method, optionsJSON, (raw: string) => {
      let result: ShellMediaResult;
      try {
        result = JSON.parse(raw) as ShellMediaResult;
        if (typeof result.code !== 'number' || typeof result.msg !== 'string') throw new Error('invalid_media_receipt');
      } catch (error) { result = { code: -1, msg: '原生媒体返回协议无效' }; }
      callback(result);
    });
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
