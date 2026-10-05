import systemDateTime from '@ohos.systemDateTime';
import ShellNavigationCommandOptions from './ShellNavigationCommandOptions';
import ShellPreparedRouteStore from '../transition/ShellPreparedRouteStore';
import LynxRouteParser from './LynxRouteParser';
import { ShellNavigationDriver } from '../transition/ShellNavigationDriver';
import PageBundleRuntimeRegistry from '../ota/OtaModels';
import router from '@ohos.router';
import { LLog } from '@lynx/lynx';
import ShellConstants from '../common/ShellConstants';
import { ShellBridgeResult } from '../common/ShellTypes';
import LynxPageRequest from '../model/LynxPageRequest';

/** 对齐 Playground navigation.ts 的稳定导航条目。 */
export interface LynxNavigationEntry {
  entryID: string;
  routeKey: string;
  index: number;
}

interface InternalNavigationEntry extends LynxNavigationEntry {
  lynxAppId: string;
  sessionID: string;
  routerIndex: number;
  hasHostAnchor: boolean;
}

interface NavigationResultRecord {
  result: Object;
  sourceEntryID: string;
  sourceRouteKey: string;
  createdAt: number;
}

interface NavigationCommandData {
  requestedDelta?: number;
  actualDelta?: number;
  targetEntryID?: string;
  targetRouteKey?: string;
}

interface NavigationStateData {
  sessionID: string;
  current: LynxNavigationEntry;
  stack: Object[];
  depth: number;
  canGoBack: boolean;
  hasHostAnchor: boolean;
  affectedCount: number;
}

interface NavigationResultPayload {
  hasResult: boolean;
  result?: Object;
  sourceEntryID?: string;
  sourceRouteKey?: string;
  createdAt?: number;
  affectedCount: number;
}



/** 原生Navigation驱动负责真实栈与事务；本层保留公开逻辑地址、session及提交后的结果。 */
export default class LynxNavigator {
  private static busyUntil: number = 0; private static lastCommand: string = '';
  private static driver: ShellNavigationDriver | null = null;
  private static hostState: 'absent' | 'initializing' | 'ready' | 'closed' = 'absent';
  private static driverWaiters: Array<{ resolve: (driver: ShellNavigationDriver) => void; reject: (error: Error) => void }> = [];
  private static hostDeadline: number = -1;
  private static entries: InternalNavigationEntry[] = [];
  private static currentEntryID: string = '';
  private static sequence: number = 0;
  private static navigationResults: Map<string, NavigationResultRecord> = new Map();

  static installNavigationDriver(driver: ShellNavigationDriver | null): void {
    LynxNavigator.driver = driver;
    if (LynxNavigator.hostDeadline >= 0) clearTimeout(LynxNavigator.hostDeadline);
    if (driver !== null) { LynxNavigator.hostState = 'ready'; LynxNavigator.driverWaiters.splice(0).forEach((waiter) => waiter.resolve(driver)); }
    else {
      LynxNavigator.hostState = 'closed'; LynxNavigator.busyUntil = 0; LynxNavigator.lastCommand = '';
      LynxNavigator.driverWaiters.splice(0).forEach((waiter) => waiter.reject(new Error('navigation_host_destroyed')));
      LynxNavigator.entries = []; LynxNavigator.currentEntryID = '';
    }
  }
  static expectNavigationHost(): void {
    if (LynxNavigator.hostState === 'ready' || LynxNavigator.hostState === 'initializing') return;
    LynxNavigator.hostState = 'initializing';
    LynxNavigator.hostDeadline = setTimeout(() => {
      if (LynxNavigator.hostState !== 'initializing') return;
      LynxNavigator.hostState = 'absent';
      LynxNavigator.driverWaiters.splice(0).forEach((waiter) => waiter.reject(new Error('navigation_host_not_ready')));
    }, 3000);
  }
  private static navigationDriver(): Promise<ShellNavigationDriver> {
    if (LynxNavigator.driver !== null) return Promise.resolve(LynxNavigator.driver);
    if (LynxNavigator.hostState !== 'initializing') return Promise.reject(new Error('navigation_host_unavailable'));
    if (LynxNavigator.driverWaiters.length >= 16) return Promise.reject(new Error('navigation_host_queue_full'));
    return new Promise((resolve, reject) => { LynxNavigator.driverWaiters.push({ resolve: resolve, reject: reject }); });
  }
  static updateBackGesture(viewID: string, enabled: boolean): void { LynxNavigator.driver?.updateBackGesture(viewID, enabled); }

  static reconcileWithDriver(): void {
    const driver = LynxNavigator.driver; if (driver === null) return;
    LynxNavigator.entries = LynxNavigator.entries.filter((entry) => driver.contains(entry.entryID));
    LynxNavigator.reindex();
    const current = LynxNavigator.entries.find((entry) => driver.isCurrent(entry.entryID));
    LynxNavigator.currentEntryID = current?.entryID ?? '';
  }

  /** 供首页保持原有调用语义；失败会让首页显示错误。 */
  static open(request: LynxPageRequest, replace: boolean = false): Promise<void> {
    return LynxNavigator.openResult(request, replace, '')
      .then((result: ShellBridgeResult) => {
        if (result.code !== 0) {
          throw new Error(result.message);
        }
      });
  }

  /** Native Module 使用的带结果版本，回调 code=0 表示原生事务已提交。 */
  static async openResult(
    request: LynxPageRequest,
    replace: boolean = false,
    optionsJSON: string = '',
    admitted: boolean = false
  ): Promise<ShellBridgeResult> {
    let command: ShellNavigationCommandOptions;
    try { command = ShellNavigationCommandOptions.parse(optionsJSON, request.animated); request.animated = command.animated; }
    catch (error) { return LynxNavigator.failure(1001, (error as Error).message); }
    let driver: ShellNavigationDriver;
    try { driver = await LynxNavigator.navigationDriver(); }
    catch (error) { return LynxNavigator.failure(1004, `Native Navigation宿主不可用：${(error as Error).message}`); }
    if (driver.isBusy()) return LynxNavigator.failure(1006, '原生导航正在转场');
    try { PageBundleRuntimeRegistry.current()?.validateNavigationSource(request.sourceSnapshotID); }
    catch (error) { return LynxNavigator.failure(1002, '来源导航快照已失效'); }
    if (!admitted) { const admission = LynxNavigator.admitCommand(command, `open:${request.routeKey}:${replace}`); if (admission !== null) return admission; }
    const launchMode = command.launchMode;
    const source = request.sourceEntryID.length > 0 ?
      (LynxNavigator.entries.find((entry: InternalNavigationEntry) => entry.entryID === request.sourceEntryID) ?? null) : LynxNavigator.currentEntry();
    const routeKey = request.routeKey.trim().length > 0 ? request.routeKey : request.bundleUrl;
    request.routeKey = routeKey;

    if (source !== null && launchMode === 'singleTop' && source.routeKey === routeKey) {
      request.sessionID = source.sessionID;
      request.entryID = source.entryID;
      request.routerIndex = source.routerIndex;
      request.hasHostAnchor = source.hasHostAnchor;
      return LynxNavigator.replaceCurrent(request, source, 'singleTop 已刷新栈顶页面');
    }

    if (source !== null && (launchMode === 'clearTop' || launchMode === 'singleTask')) {
      const targetIndex = LynxNavigator.findEntryIndex(source.sessionID, routeKey, source);
      if (targetIndex >= 0) {
        const target = LynxNavigator.entries[targetIndex];
        if (target.entryID === source.entryID) {
          if (launchMode === 'clearTop') return LynxNavigator.success('当前已是目标页面', 0, LynxNavigator.entryData(target));
          request.sessionID = target.sessionID; request.entryID = target.entryID; request.routerIndex = target.routerIndex; request.hasHostAnchor = target.hasHostAnchor;
          return LynxNavigator.replaceCurrent(request, target, 'singleTask 已刷新当前目标页面');
        }
        try {
          if (LynxNavigator.driver !== null) {
            const completed = new Promise<void>((resolve, reject) => { LynxNavigator.driver!.backTo(target.entryID, () => { LynxNavigator.reconcileWithDriver(); resolve(); }, reject, command.animated); });
            await completed;
          } else { return LynxNavigator.failure(1004, 'Native Navigation宿主已销毁'); }
          if (launchMode === 'singleTask') {
            request.sessionID = target.sessionID;
            request.entryID = target.entryID;
            request.routerIndex = target.routerIndex;
            request.hasHostAnchor = target.hasHostAnchor;
            return LynxNavigator.replaceCurrent(request, target, 'singleTask 已复用并刷新目标页面');
          }
          return Promise.resolve(LynxNavigator.success(
            `clearTop 已回到 ${routeKey}`,
            targetIndex < LynxNavigator.entries.length ? 1 : 0,
            LynxNavigator.entryData(target),
          ));
        } catch (error) {
          return Promise.resolve(LynxNavigator.failure(1500, `回到目标页面失败: ${error}`));
        }
      }
    }

    const sessionID = request.sessionID.length > 0 ? request.sessionID : (source?.sessionID ?? LynxNavigator.nextID('session'));
    const entryID = LynxNavigator.nextID('entry');
    request.sessionID = sessionID;
    request.entryID = entryID;
    request.routerIndex = LynxNavigator.stackLength() + 1;
    request.hasHostAnchor = source?.hasHostAnchor ?? request.hasHostAnchor;
    try {
      const navigation = driver.push(request, replace);
      return navigation.then(() => {
        const entry: InternalNavigationEntry = {
          entryID,
          lynxAppId: request.lynxAppId,
          sessionID,
          routeKey,
          routerIndex: request.routerIndex,
          hasHostAnchor: request.hasHostAnchor,
          index: LynxNavigator.entries.length,
        };
        if (replace && source !== null) {
          const sourceIndex = LynxNavigator.entries.findIndex((item: InternalNavigationEntry) =>
            item.entryID === source.entryID);
          if (sourceIndex >= 0) {
            LynxNavigator.entries[sourceIndex] = entry;
          } else {
            LynxNavigator.entries.push(entry);
          }
        } else {
          LynxNavigator.entries.push(entry);
        }
        LynxNavigator.reindex();
        LynxNavigator.currentEntryID = entryID;
        driver.routeCommitted(request.nativeViewID);
        LLog.d(ShellConstants.TAG, `open Lynx page: ${request.bundleUrl}, routeKey=${routeKey}`);
        return LynxNavigator.success('已提交打开动作', 1, LynxNavigator.entryData(entry));
      }).catch((error: Error) => LynxNavigator.failure(1500, `打开 Lynx 页面失败: ${error.message}`));
    } catch (error) {
      return Promise.resolve(LynxNavigator.failure(1500, `打开 Lynx 页面失败: ${error}`));
    }
  }

  /** 页面进入/恢复时登记；同时清理系统返回造成的静态栈尾部残留。 */
  static register(request: LynxPageRequest): void {
    if (request.nativeNavigationHosted && LynxNavigator.driver?.isStaged(request.entryID)) return;
    const entryID = request.entryID.trim();
    if (entryID.length === 0) {
      return;
    }
    const existingIndex = LynxNavigator.entries.findIndex((item: InternalNavigationEntry) =>
      item.entryID === entryID);
    if (existingIndex >= 0) {
      const existing = LynxNavigator.entries[existingIndex];
      existing.routeKey = request.routeKey.length > 0 ? request.routeKey : existing.routeKey;
      LynxNavigator.trimAfter(existingIndex);
      LynxNavigator.currentEntryID = entryID;
      return;
    }
    const entry: InternalNavigationEntry = {
      entryID,
      lynxAppId: request.lynxAppId,
      sessionID: request.sessionID.length > 0 ? request.sessionID : LynxNavigator.nextID('session'),
      routeKey: request.routeKey.length > 0 ? request.routeKey : request.bundleUrl,
      routerIndex: request.routerIndex > 0 ? request.routerIndex : LynxNavigator.stackLength(),
      hasHostAnchor: request.hasHostAnchor,
      index: LynxNavigator.entries.length,
    };
    LynxNavigator.entries.push(entry);
    LynxNavigator.reindex();
    LynxNavigator.currentEntryID = entryID;
  }

  /** 页面容器用它区分“被覆盖”与“已经从 Native Page Stack 移除”。 */
  static isCurrentEntry(entryID: string): boolean { return LynxNavigator.driver?.isCurrent(entryID) ?? (LynxNavigator.currentEntry()?.entryID === entryID); }

  static hasEntry(entryID: string): boolean {
    return LynxNavigator.driver?.contains(entryID) ?? LynxNavigator.entries.some((entry: InternalNavigationEntry) => entry.entryID === entryID);
  }

  /** 判断一个 Lynx session 是否仍有页面；用于最后一个页面退出时释放 OTA Snapshot。 */
  static hasSession(sessionID: string, lynxAppId?: string): boolean {
    if (sessionID.trim().length === 0) return false;
    return LynxNavigator.entries.some((entry: InternalNavigationEntry) => entry.sessionID === sessionID && (lynxAppId === undefined || entry.lynxAppId === lynxAppId) &&
      (LynxNavigator.driver === null || LynxNavigator.driver.contains(entry.entryID)));
  }

  /** 同步 ArkUI Router 已经由系统返回键移除的逻辑 entry，避免 session/Snapshot 残留。 */
  static reconcileWithRouter(): void {
    if (LynxNavigator.driver !== null) { if (!LynxNavigator.driver.isBusy()) LynxNavigator.reconcileWithDriver(); return; }
    let routerLength: number;
    try {
      routerLength = Number(router.getLength());
    } catch (error) {
      return;
    }
    if (!Number.isFinite(routerLength) || routerLength < 0) return;
    const currentEntryStillPresent = LynxNavigator.entries.some((entry: InternalNavigationEntry) => {
      return entry.routerIndex <= routerLength;
    });
    if (currentEntryStillPresent && LynxNavigator.entries.every((entry: InternalNavigationEntry) => entry.routerIndex <= routerLength)) {
      return;
    }
    LynxNavigator.entries = LynxNavigator.entries.filter((entry: InternalNavigationEntry) => entry.routerIndex <= routerLength);
    LynxNavigator.reindex();
    if (!LynxNavigator.hasEntry(LynxNavigator.currentEntryID)) {
      const target = LynxNavigator.entries.length > 0 ? LynxNavigator.entries[LynxNavigator.entries.length - 1] : null;
      LynxNavigator.currentEntryID = target?.entryID ?? '';
    }
  }

  static close(): void { LynxNavigator.closeResult(); }

  static closeResult(optionsJSON: string = ''): ShellBridgeResult {
    let command: ShellNavigationCommandOptions;
    try { command = ShellNavigationCommandOptions.parse(optionsJSON); } catch (error) { return LynxNavigator.failure(1001, (error as Error).message); }
    if (LynxNavigator.driver !== null) {
      if (LynxNavigator.driver.isBusy()) return LynxNavigator.failure(1006, '原生导航正在转场');
      const index = LynxNavigator.currentIndex();
      if (index < 0) return LynxNavigator.failure(1002, '当前没有可返回的Lynx页面');
      const admission = LynxNavigator.admitCommand(command, 'close'); if (admission !== null) return admission;
      const targetID = index > 0 ? LynxNavigator.entries[index - 1].entryID : '';
      try { LynxNavigator.driver.backTo(targetID, () => LynxNavigator.reconcileWithDriver(), undefined, command.animated); return LynxNavigator.success('返回动作已提交', 1); }
      catch (error) { return LynxNavigator.failure(1500, `返回提交失败：${error}`); }
    }
    return LynxNavigator.failure(1004, '尚未安装Native Navigation宿主');
  }

  static back(delta: number, optionsJSON: string = ''): ShellBridgeResult {
    let command: ShellNavigationCommandOptions;
    try { command = ShellNavigationCommandOptions.parse(optionsJSON); } catch (error) { return LynxNavigator.failure(1001, (error as Error).message); }
    if (!Number.isInteger(delta) || delta <= 0) return LynxNavigator.failure(1001, 'delta 必须为正整数');
    if (LynxNavigator.driver?.isBusy()) return LynxNavigator.failure(1006, '原生导航正在转场');
    const currentIndex = LynxNavigator.currentIndex();
    if (currentIndex <= 0) return LynxNavigator.failure(1005, '当前已是 Lynx session 首页');
    const targetIndex = Math.max(0, currentIndex - delta);
    const current = LynxNavigator.entries[currentIndex];
    const target = LynxNavigator.entries[targetIndex];
    const result = command.result ?? null;

    try {
      if (LynxNavigator.driver !== null) {
        if (LynxNavigator.driver.isBusy()) return LynxNavigator.failure(1006, '原生导航正在转场');
        const admission = LynxNavigator.admitCommand(command, `back:${delta}`); if (admission !== null) return admission;
        LynxNavigator.driver.backTo(target.entryID, () => {
          LynxNavigator.reconcileWithDriver();
          if (result !== null) LynxNavigator.navigationResults.set(target.entryID, { result: result, sourceEntryID: current.entryID, sourceRouteKey: current.routeKey, createdAt: Date.now() } as NavigationResultRecord);
        }, undefined, command.animated);
        return LynxNavigator.success('回退动作已提交', currentIndex - targetIndex);
      }
      return LynxNavigator.failure(1004, '尚未安装Native Navigation宿主');
    } catch (error) {
      return LynxNavigator.failure(1500, `回退页面失败: ${error}`);
    }
  }

  static popTo(routeKey: string, optionsJSON: string = ''): ShellBridgeResult {
    let command: ShellNavigationCommandOptions;
    try { command = ShellNavigationCommandOptions.parse(optionsJSON); } catch (error) { return LynxNavigator.failure(1001, (error as Error).message); }
    if (LynxNavigator.driver?.isBusy()) return LynxNavigator.failure(1006, '原生导航正在转场');
    const currentIndex = LynxNavigator.currentIndex();
    if (currentIndex < 0) return LynxNavigator.failure(1002, '当前页面不在 Lynx 导航会话中');
    const normalized = routeKey.trim();
    if (normalized.length === 0) return LynxNavigator.failure(1001, 'routeKey 不能为空');
    let targetIndex = -1;
    for (let index = currentIndex; index >= 0; index--) {
      if (LynxNavigator.entries[index].routeKey === normalized) {
        targetIndex = index;
        break;
      }
    }
    if (targetIndex < 0) return LynxNavigator.failure(1003, `当前 Lynx 会话中不存在 routeKey=${normalized}`);
    const target = LynxNavigator.entries[targetIndex];
    const current = LynxNavigator.entries[currentIndex];
    if (targetIndex === currentIndex) return LynxNavigator.success('当前已是目标页面', 0, LynxNavigator.entryData(target));
    const result = command.result ?? null;

    try {
      if (LynxNavigator.driver !== null && targetIndex < currentIndex) {
        if (LynxNavigator.driver.isBusy()) return LynxNavigator.failure(1006, '原生导航正在转场');
        const admission = LynxNavigator.admitCommand(command, `popTo:${normalized}`); if (admission !== null) return admission;
        LynxNavigator.driver.backTo(target.entryID, () => {
          LynxNavigator.reconcileWithDriver();
          if (result !== null) LynxNavigator.navigationResults.set(target.entryID, { result: result, sourceEntryID: current.entryID, sourceRouteKey: current.routeKey, createdAt: Date.now() } as NavigationResultRecord);
        }, undefined, command.animated);
        return LynxNavigator.success('popTo动作已提交', currentIndex - targetIndex);
      }
      return LynxNavigator.failure(1004, '尚未安装Native Navigation宿主');
    } catch (error) {
      return LynxNavigator.failure(1500, `popTo 失败: ${error}`);
    }
  }

  static closeAll(optionsJSON: string = ''): ShellBridgeResult {
    let command: ShellNavigationCommandOptions;
    try { command = ShellNavigationCommandOptions.parse(optionsJSON); } catch (error) { return LynxNavigator.failure(1001, (error as Error).message); }
    if (LynxNavigator.driver?.isBusy()) return LynxNavigator.failure(1006, '原生导航正在转场');
    if (LynxNavigator.currentIndex() < 0) return LynxNavigator.failure(1002, '当前页面不在 Lynx 导航会话中');
    try {
      if (LynxNavigator.driver !== null) {
        if (LynxNavigator.driver.isBusy()) return LynxNavigator.failure(1006, '原生导航正在转场');
        const admission = LynxNavigator.admitCommand(command, 'closeAll'); if (admission !== null) return admission;
        const count = LynxNavigator.entries.length;
        LynxNavigator.driver.backTo('', () => LynxNavigator.reconcileWithDriver(), undefined, command.animated);
        return LynxNavigator.success('closeAll动作已提交', count);
      }
      return LynxNavigator.failure(1004, '尚未安装Native Navigation宿主');
    } catch (error) {
      return LynxNavigator.failure(1500, `关闭全部页面失败: ${error}`);
    }
  }

  static reLaunch(optionsJSON: string = ''): ShellBridgeResult {
    return LynxNavigator.closeAll(optionsJSON);
  }

  /** 原生SDK的清空后打开是同一命令，真实pop提交之后才开新session。 */
  static async reLaunchRequest(request: LynxPageRequest, optionsJSON: string = ''): Promise<ShellBridgeResult> {
    let command: ShellNavigationCommandOptions; let driver: ShellNavigationDriver;
    try { command = ShellNavigationCommandOptions.parse(optionsJSON, request.animated); request.animated = command.animated; }
    catch (error) { return LynxNavigator.failure(1001, (error as Error).message); }
    try { driver = await LynxNavigator.navigationDriver(); }
    catch (error) { return LynxNavigator.failure(1004, (error as Error).message); }
    if (driver.isBusy()) return LynxNavigator.failure(1006, '原生导航正在转场');
    try { PageBundleRuntimeRegistry.current()?.validateNavigationSource(request.sourceSnapshotID); }
    catch (error) { return LynxNavigator.failure(1002, '来源导航快照已失效'); }
    const admission = LynxNavigator.admitCommand(command, 'reLaunch'); if (admission !== null) return admission;
    try {
      if (LynxNavigator.currentIndex() >= 0) {
        await new Promise<void>((resolve, reject) => driver.backTo('', () => { LynxNavigator.reconcileWithDriver(); resolve(); }, reject, command.animated));
      }
      request.sessionID = ''; request.sourceSnapshotID = ''; request.sourceEntryID = ''; request.sourceNativeViewID = '';
      return LynxNavigator.openResult(request, false, optionsJSON, true);
    } catch (error) { return LynxNavigator.failure(1500, `重新打开页面失败：${(error as Error).message}`); }
  }

  static redirectResult(request: LynxPageRequest, optionsJSON: string = ''): Promise<ShellBridgeResult> {
    let command: ShellNavigationCommandOptions;
    try { command = ShellNavigationCommandOptions.parse(optionsJSON, request.animated); request.animated = command.animated; }
    catch (error) { return Promise.resolve(LynxNavigator.failure(1001, (error as Error).message)); }
    const current = LynxNavigator.currentEntry();
    if (current === null) return Promise.resolve(LynxNavigator.failure(1002, '当前页面不在 Lynx 导航会话中'));
    if (request.sourceEntryID.length > 0 && request.sourceEntryID !== current.entryID) {
      return Promise.resolve(LynxNavigator.failure(1002, '来源页面不能重定向另一个页面'));
    }
    const admission = LynxNavigator.admitCommand(command, 'redirect'); if (admission !== null) return Promise.resolve(admission);
    request.sessionID = current.sessionID;
    request.entryID = current.entryID;
    request.routerIndex = current.routerIndex;
    request.hasHostAnchor = current.hasHostAnchor;
    request.routeKey = request.routeKey.length > 0 ? request.routeKey : request.bundleUrl;
    return LynxNavigator.replaceCurrent(request, current, '当前页面已重定向');
  }

  static getNavigationState(): ShellBridgeResult {
    const currentIndex = LynxNavigator.currentIndex();
    if (currentIndex < 0) return LynxNavigator.failure(1002, '当前页面不在 Lynx 导航会话中');
    const current = LynxNavigator.entries[currentIndex];
    const stack: Object[] = [];
    LynxNavigator.entries.forEach((entry: InternalNavigationEntry) => {
      const stackEntry: LynxNavigationEntry = {
        entryID: entry.entryID,
        routeKey: entry.routeKey,
        index: entry.index,
      };
      stack.push(stackEntry);
    });
    const state: NavigationStateData = {
      sessionID: current.sessionID,
      current: { entryID: current.entryID, routeKey: current.routeKey, index: current.index },
      stack,
      depth: LynxNavigator.entries.length,
      canGoBack: currentIndex > 0,
      hasHostAnchor: current.hasHostAnchor,
      affectedCount: 0,
    };
    return LynxNavigator.success('导航状态读取成功', 0, state);
  }

  static closeWithResult(resultJSON: string): ShellBridgeResult {
    const currentIndex = LynxNavigator.currentIndex();
    if (currentIndex <= 0) return LynxNavigator.failure(1005, '当前页面没有可接收结果的上一个 Lynx entry');
    const result = LynxNavigator.parseObject(resultJSON);
    if (result === null) return LynxNavigator.failure(1001, 'resultJSON 必须是 JSON Object');
    const target = LynxNavigator.entries[currentIndex - 1];
    const current = LynxNavigator.entries[currentIndex];
    return LynxNavigator.back(1, JSON.stringify({ result: result }));
  }

  static consumeNavigationResult(): ShellBridgeResult {
    const current = LynxNavigator.currentEntry();
    if (current === null) return LynxNavigator.failure(1002, '当前页面不在 Lynx 导航会话中');
    const value = LynxNavigator.navigationResults.get(current.entryID);
    if (value === undefined) {
      const emptyResult: NavigationResultPayload = { hasResult: false, affectedCount: 0 };
      return LynxNavigator.success('当前页面没有待消费结果', 0, emptyResult);
    }
    LynxNavigator.navigationResults.delete(current.entryID);
    const payload: NavigationResultPayload = {
      hasResult: true,
      result: value.result,
      sourceEntryID: value.sourceEntryID,
      sourceRouteKey: value.sourceRouteKey,
      createdAt: value.createdAt,
      affectedCount: 1,
    };
    return LynxNavigator.success('页面结果读取成功', 0, payload);
  }

  static prepareRoute(url: string, optionsJSON: string): Promise<ShellBridgeResult> {
    const parsed = LynxRouteParser.parseWithOptions(url, optionsJSON);
    if (!parsed.isSuccess || parsed.request === null) return Promise.resolve(LynxNavigator.failure(1001, parsed.errorMessage));
    return ShellPreparedRouteStore.shared.prepare(parsed.request);
  }
  static cancelPreparedRoute(token: string): ShellBridgeResult { return ShellPreparedRouteStore.shared.cancel(token); }

  static markTransitionReady(transactionID: string): ShellBridgeResult {
    if (transactionID.trim().length === 0) return LynxNavigator.failure(1001, 'transactionID 不能为空');
    if (LynxNavigator.driver === null) return LynxNavigator.failure(1004, '尚未安装Native Navigation宿主');
    try { LynxNavigator.driver.markReady(transactionID); }
    catch (error) { return LynxNavigator.failure(1003, '转场不存在或已结束'); }
    return LynxNavigator.success('转场ready信号已接收', 0);
  }

  static getTransitionState(): ShellBridgeResult {
    if (LynxNavigator.driver !== null) return LynxNavigator.success('原生转场状态', 0, LynxNavigator.driver.transitionState());
    return LynxNavigator.failure(1004, '尚未安装Native Navigation宿主');
  }

  private static replaceCurrent(
    request: LynxPageRequest,
    current: InternalNavigationEntry,
    message: string
  ): Promise<ShellBridgeResult> {
    try {
      if (LynxNavigator.driver === null) return Promise.resolve(LynxNavigator.failure(1004, '尚未安装Native Navigation宿主'));
      const navigation = LynxNavigator.driver.push(request, true);
      return navigation.then(() => {
        current.routeKey = request.routeKey;
        current.lynxAppId = request.lynxAppId;
        LynxNavigator.driver?.routeCommitted(request.nativeViewID);
        LynxNavigator.currentEntryID = current.entryID;
        return LynxNavigator.success(message, 1, LynxNavigator.entryData(current));
      }).catch((error: Error) => LynxNavigator.failure(1500, `替换 Lynx 页面失败: ${error.message}`));
    } catch (error) {
      return Promise.resolve(LynxNavigator.failure(1500, `替换 Lynx 页面失败: ${error}`));
    }
  }

  private static admitCommand(options: ShellNavigationCommandOptions, key: string): ShellBridgeResult | null {
    if (LynxNavigator.driver?.isBusy()) return LynxNavigator.failure(1006, '原生导航正在转场');
    if (!options.deduplicate || options.deduplicateWindowMs === 0) return null;
    const now = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
    if (now < LynxNavigator.busyUntil) return LynxNavigator.failure(1006, key === LynxNavigator.lastCommand ? '重复导航已抑制' : '上一笔导航命令仍在抑制窗口');
    LynxNavigator.lastCommand = key; LynxNavigator.busyUntil = now + (options.animated ? options.deduplicateWindowMs : Math.min(options.deduplicateWindowMs, 80));
    return null;
  }

  private static currentEntry(): InternalNavigationEntry | null {
    if (LynxNavigator.currentEntryID.length === 0) return null;
    const index = LynxNavigator.entries.findIndex((item: InternalNavigationEntry) =>
      item.entryID === LynxNavigator.currentEntryID);
    return index >= 0 ? LynxNavigator.entries[index] : null;
  }

  private static currentIndex(): number {
    if (LynxNavigator.currentEntryID.length === 0) return -1;
    return LynxNavigator.entries.findIndex((item: InternalNavigationEntry) =>
      item.entryID === LynxNavigator.currentEntryID);
  }

  private static findEntryIndex(
    sessionID: string,
    routeKey: string,
    source: InternalNavigationEntry
  ): number {
    for (let index = LynxNavigator.entries.length - 1; index >= 0; index--) {
      const item = LynxNavigator.entries[index];
      if (item.sessionID === sessionID && item.routeKey === routeKey && item.index <= source.index) {
        return index;
      }
    }
    return -1;
  }

  private static removeCurrent(): void {
    const index = LynxNavigator.currentIndex();
    if (index < 0) return;
    LynxNavigator.entries.splice(index, 1);
    LynxNavigator.reindex();
    const target = LynxNavigator.entries.length > 0 ? LynxNavigator.entries[LynxNavigator.entries.length - 1] : null;
    LynxNavigator.currentEntryID = target?.entryID ?? '';
  }

  private static trimAfter(index: number): void {
    const removeCount = LynxNavigator.entries.length - index - 1;
    if (removeCount > 0) LynxNavigator.entries.splice(index + 1, removeCount);
    LynxNavigator.reindex();
  }

  private static reindex(): void {
    LynxNavigator.entries.forEach((entry: InternalNavigationEntry, index: number) => {
      entry.index = index;
    });
  }

  private static entryData(entry: InternalNavigationEntry): Object {
    const data: LynxNavigationEntry = {
      entryID: entry.entryID,
      routeKey: entry.routeKey,
      index: entry.index,
    };
    return data;
  }

  private static nextID(prefix: string): string {
    LynxNavigator.sequence += 1;
    return `${prefix}-${new Date().getTime()}-${LynxNavigator.sequence}`;
  }

  private static stackLength(): number {
    if (LynxNavigator.driver !== null) return LynxNavigator.driver.depth();
    try {
      const length = Number(router.getLength());
      return Number.isFinite(length) && length > 0 ? length : 1;
    } catch (error) {
      return 1;
    }
  }

  private static parseObject(value: string): Object | null {
    if (value.trim().length === 0) {
      const empty: Record<string, Object> = {};
      return empty;
    }
    try {
      const parsed = JSON.parse(value) as Object;
      if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object') return null;
      return parsed;
    } catch (error) {
      return null;
    }
  }

  private static success(message: string, affectedCount: number = 0, data?: Object): ShellBridgeResult {
    const result: ShellBridgeResult = { code: 0, message };
    if (data !== undefined) {
      const payload = data as Record<string, Object>;
      payload['affectedCount'] = affectedCount;
      result.data = payload;
    }
    return result;
  }

  private static failure(code: number, message: string): ShellBridgeResult {
    return { code, message };
  }

  private constructor() {
  }
}
