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

interface PreparedRouteRecord {
  routeKey: string;
  expiresAt: number;
}

interface PreparedRouteData {
  token: string;
  routeKey: string;
  expiresAt: number;
  sizeBytes: number;
}

interface NavigationResultPayload {
  hasResult: boolean;
  result?: Object;
  sourceEntryID?: string;
  sourceRouteKey?: string;
  createdAt?: number;
  affectedCount: number;
}

interface TransitionStateData {
  transactionID: string;
  status: string;
  requestedTransition: string;
  effectiveTransition: string;
  direction: string;
  progress: number;
  reason: string;
  updatedAt: number;
}

/**
 * HarmonyOS Router 的薄适配层；后续可在不改公开契约的前提下替换为 NavPathStack。
 *
 * ArkUI Router 只提供页面 index，不提供业务 routeKey/session，因此这里把
 * session 元数据写入 Router params，并在进程内维护可序列化的 Lynx 栈状态。
 * 所有 Native Module 导航方法都集中到本类，避免出现“页面能打开但桥方法不存在”的
 * 部分接入状态。
 */
export default class LynxNavigator {
  private static entries: InternalNavigationEntry[] = [];
  private static currentEntryID: string = '';
  private static sequence: number = 0;
  private static navigationResults: Map<string, NavigationResultRecord> = new Map();
  private static preparedRoutes: Map<string, PreparedRouteRecord> = new Map();
  private static transitionReady: Map<string, boolean> = new Map();

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
  static openResult(
    request: LynxPageRequest,
    replace: boolean = false,
    optionsJSON: string = ''
  ): Promise<ShellBridgeResult> {
    const options = LynxNavigator.parseObject(optionsJSON);
    const launchMode = LynxNavigator.optionString(options, 'launchMode') ?? 'push';
    const source = LynxNavigator.currentEntry();
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
        try {
          router.back(target.routerIndex);
          LynxNavigator.trimAfter(targetIndex);
          LynxNavigator.currentEntryID = target.entryID;
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

    const sessionID = source?.sessionID ?? LynxNavigator.nextID('session');
    const entryID = LynxNavigator.nextID('entry');
    request.sessionID = sessionID;
    request.entryID = entryID;
    request.routerIndex = LynxNavigator.stackLength() + 1;
    request.hasHostAnchor = source?.hasHostAnchor ?? true;
    const target: router.RouterOptions = {
      url: ShellConstants.LYNX_PAGE,
      params: request.toRouterParams()
    };
    try {
      const navigation = replace ? router.replaceUrl(target) : router.pushUrl(target);
      return navigation.then(() => {
        const entry: InternalNavigationEntry = {
          entryID,
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
        LLog.d(ShellConstants.TAG, `open Lynx page: ${request.bundleUrl}, routeKey=${routeKey}`);
        return LynxNavigator.success('已提交打开动作', 1, LynxNavigator.entryData(entry));
      }).catch((error: Error) => LynxNavigator.failure(1500, `打开 Lynx 页面失败: ${error.message}`));
    } catch (error) {
      return Promise.resolve(LynxNavigator.failure(1500, `打开 Lynx 页面失败: ${error}`));
    }
  }

  /** 页面进入/恢复时登记；同时清理系统返回造成的静态栈尾部残留。 */
  static register(request: LynxPageRequest): void {
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
  static hasEntry(entryID: string): boolean {
    return LynxNavigator.entries.some((entry: InternalNavigationEntry) => entry.entryID === entryID);
  }

  static close(): void {
    try {
      router.back();
      LynxNavigator.removeCurrent();
    } catch (error) {
      LLog.e(ShellConstants.TAG, `close failed: ${error}`);
    }
  }

  static closeResult(): ShellBridgeResult {
    const current = LynxNavigator.currentEntry();
    if (current === null) return LynxNavigator.failure(1002, '当前页面不在 Lynx 导航会话中');
    try {
      router.back();
      LynxNavigator.removeCurrent();
      return LynxNavigator.success('当前页面已关闭', 1);
    } catch (error) {
      return LynxNavigator.failure(1500, `关闭页面失败: ${error}`);
    }
  }

  static back(delta: number, optionsJSON: string = ''): ShellBridgeResult {
    if (delta <= 0) return LynxNavigator.failure(1001, 'delta 必须大于 0');
    const currentIndex = LynxNavigator.currentIndex();
    if (currentIndex <= 0) return LynxNavigator.failure(1005, '当前已是 Lynx session 首页');
    const targetIndex = Math.max(0, currentIndex - delta);
    const current = LynxNavigator.entries[currentIndex];
    const target = LynxNavigator.entries[targetIndex];
    const result = LynxNavigator.parseResultOption(optionsJSON);
    if (result !== null) {
      LynxNavigator.navigationResults.set(target.entryID, {
        result,
        sourceEntryID: current.entryID,
        sourceRouteKey: current.routeKey,
        createdAt: new Date().getTime(),
      } as NavigationResultRecord);
    }
    try {
      router.back(target.routerIndex);
      LynxNavigator.trimAfter(targetIndex);
      LynxNavigator.currentEntryID = target.entryID;
      return LynxNavigator.success(`已回退 ${currentIndex - targetIndex} 页`, currentIndex - targetIndex, {
        requestedDelta: delta,
        actualDelta: currentIndex - targetIndex,
        targetEntryID: target.entryID,
        targetRouteKey: target.routeKey,
      } as NavigationCommandData);
    } catch (error) {
      return LynxNavigator.failure(1500, `回退页面失败: ${error}`);
    }
  }

  static popTo(routeKey: string, optionsJSON: string = ''): ShellBridgeResult {
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
    const result = LynxNavigator.parseResultOption(optionsJSON);
    if (result !== null && current.entryID !== target.entryID) {
      LynxNavigator.navigationResults.set(target.entryID, {
        result,
        sourceEntryID: current.entryID,
        sourceRouteKey: current.routeKey,
        createdAt: new Date().getTime(),
      } as NavigationResultRecord);
    }
    try {
      if (targetIndex < currentIndex) router.back(target.routerIndex);
      LynxNavigator.trimAfter(targetIndex);
      LynxNavigator.currentEntryID = target.entryID;
      return LynxNavigator.success(`已回退到 ${normalized}`, currentIndex - targetIndex, {
        targetEntryID: target.entryID,
        targetRouteKey: target.routeKey,
      } as NavigationCommandData);
    } catch (error) {
      return LynxNavigator.failure(1500, `popTo 失败: ${error}`);
    }
  }

  static closeAll(): ShellBridgeResult {
    if (LynxNavigator.currentIndex() < 0) return LynxNavigator.failure(1002, '当前页面不在 Lynx 导航会话中');
    try {
      router.back(1);
      const affected = LynxNavigator.entries.length;
      LynxNavigator.entries = [];
      LynxNavigator.currentEntryID = '';
      return LynxNavigator.success('已关闭全部 Lynx 页面并返回宿主页', affected);
    } catch (error) {
      return LynxNavigator.failure(1500, `关闭全部页面失败: ${error}`);
    }
  }

  static reLaunch(): ShellBridgeResult {
    return LynxNavigator.closeAll();
  }

  static redirectResult(request: LynxPageRequest): Promise<ShellBridgeResult> {
    const current = LynxNavigator.currentEntry();
    if (current === null) return Promise.resolve(LynxNavigator.failure(1002, '当前页面不在 Lynx 导航会话中'));
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
    LynxNavigator.navigationResults.set(target.entryID, {
      result,
      sourceEntryID: current.entryID,
      sourceRouteKey: current.routeKey,
      createdAt: new Date().getTime(),
    } as NavigationResultRecord);
    return LynxNavigator.back(1);
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

  static prepareRoute(url: string, optionsJSON: string): ShellBridgeResult {
    const token = LynxNavigator.nextID('prepared');
    const routeKey = LynxNavigator.optionString(LynxNavigator.parseObject(optionsJSON), 'routeKey') ?? url;
    LynxNavigator.preparedRoutes.set(token, {
      routeKey,
      expiresAt: new Date().getTime() + 30000,
    } as PreparedRouteRecord);
    const prepared: PreparedRouteData = {
      token,
      routeKey,
      expiresAt: new Date().getTime() + 30000,
      sizeBytes: 0,
    };
    return LynxNavigator.success('路由已预解析（鸿蒙使用普通加载）', 0, prepared);
  }

  static cancelPreparedRoute(token: string): ShellBridgeResult {
    if (token.trim().length === 0) return LynxNavigator.failure(1001, 'prepared route token 不能为空');
    if (!LynxNavigator.preparedRoutes.delete(token)) {
      return LynxNavigator.failure(1003, 'prepared route 不存在、已过期或已消费');
    }
    return LynxNavigator.success('prepared route 已取消', 1);
  }

  static markTransitionReady(transactionID: string): ShellBridgeResult {
    if (transactionID.trim().length === 0) return LynxNavigator.failure(1001, 'transactionID 不能为空');
    LynxNavigator.transitionReady.set(transactionID, true);
    return LynxNavigator.success('转场 ready 信号已接收（鸿蒙降级为 Router 转场）', 0);
  }

  static getTransitionState(): ShellBridgeResult {
    const state: TransitionStateData = {
      transactionID: '',
      status: 'degraded',
      requestedTransition: 'default',
      effectiveTransition: 'default',
      direction: 'push',
      progress: 1,
      reason: 'HarmonyOS Router 当前未接入共享元素转场协调器',
      updatedAt: new Date().getTime(),
    };
    return LynxNavigator.success('转场状态读取成功', 0, state);
  }

  private static replaceCurrent(
    request: LynxPageRequest,
    current: InternalNavigationEntry,
    message: string
  ): Promise<ShellBridgeResult> {
    const target: router.RouterOptions = {
      url: ShellConstants.LYNX_PAGE,
      params: request.toRouterParams()
    };
    try {
      return router.replaceUrl(target).then(() => {
        current.routeKey = request.routeKey;
        LynxNavigator.currentEntryID = current.entryID;
        return LynxNavigator.success(message, 1, LynxNavigator.entryData(current));
      }).catch((error: Error) => LynxNavigator.failure(1500, `替换 Lynx 页面失败: ${error.message}`));
    } catch (error) {
      return Promise.resolve(LynxNavigator.failure(1500, `替换 Lynx 页面失败: ${error}`));
    }
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

  private static optionString(options: Object | null, key: string): string | null {
    if (options === null) return null;
    const value = (options as Record<string, Object>)[key];
    return typeof value === 'string' ? value : null;
  }

  private static parseResultOption(optionsJSON: string): Object | null {
    const options = LynxNavigator.parseObject(optionsJSON);
    if (options === null) return null;
    const value = (options as Record<string, Object>)['result'];
    if (value === undefined || value === null || Array.isArray(value) || typeof value !== 'object') return null;
    return value as Object;
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
