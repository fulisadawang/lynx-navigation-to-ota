import { LynxContext, MetaData, TemplateData } from '@lynx/lynx';
import { ShellRouterMessage, ShellRouterMessageHandler, ShellRouterMessageReply, ShellRouterPageInfo } from './ShellTypes';
import ShellThemeState, { ShellTheme } from './ShellTheme';
import ShellGlobalPropsFactory from './ShellGlobalPropsFactory';
import ShellLayoutState, { ShellLayoutSnapshot } from './ShellLayoutState';
import ShellLocaleState, { ShellLocaleStateValue } from './ShellLocale';

interface ShellThemeGlobalProps extends Record<string, Object> {
  theme: ShellTheme;
}

interface ShellLocaleChangedPayload {
  schemaVersion: number;
  revision: number;
  reason: string;
  state: ShellLocaleStateValue;
}

interface ShellLayoutChangedPayload {
  schemaVersion: number;
  revision: number;
  reason: string;
  snapshot: ShellLayoutSnapshot;
}

/**
 * HarmonyOS 进程内 Lynx 页面消息中心。
 *
 * ArkUI Page 的销毁由页面生命周期驱动；页面离开时必须注销 Context。消息中心不保存
 * 离线消息，只向仍在当前 Native Page Stack 中的页面发送事件。
 */
export default class ShellMessageHub {
  static readonly LIFECYCLE_EVENT: string = 'lynxRouterLifecycle';
  static readonly LOCALE_EVENT: string = 'lynxShellLocaleChanged';
  static readonly LAYOUT_EVENT: string = 'lynxShellLayoutChanged';
  private static infos: Map<string, ShellRouterPageInfo> = new Map();
  private static contexts: Map<string, LynxContext> = new Map();
  private static messageHandler: ShellRouterMessageHandler | null = null;

  static setMessageHandler(handler: ShellRouterMessageHandler | null): void {
    ShellMessageHub.messageHandler = handler;
  }

  static register(info: ShellRouterPageInfo, context: LynxContext): void {
    ShellMessageHub.infos.set(info.pageId, info);
    ShellMessageHub.contexts.set(info.pageId, context);
    ShellMessageHub.applyEnvironment(context, info.pageId);
  }

  static unregister(pageId: string): void {
    ShellMessageHub.infos.delete(pageId);
    ShellMessageHub.contexts.delete(pageId);
    ShellLayoutState.clearViewport(pageId);
  }

  /** 将已解析的主题同步到所有仍登记的 LynxContext；不重建 View 或重新加载 Bundle。 */
  static updateTheme(theme: ShellTheme): void {
    const globalProps: ShellThemeGlobalProps = { theme: theme };
    ShellMessageHub.contexts.forEach((context: LynxContext, pageId: string) => {
      context.updateColorScheme(ShellThemeState.colorScheme(theme));
      const environment = ShellGlobalPropsFactory.environmentProps(pageId);
      Object.keys(globalProps).forEach((key: string) => {
        environment[key] = globalProps[key];
      });
      context.updateMetaData(new MetaData(undefined, new TemplateData(environment)));
    });
  }

  /** 将完整 LocaleState 更新到所有存活 Context，并通知页面侧资源层。 */
  static updateLocale(reason: string): number {
    const state = ShellLocaleState.current();
    let affectedCount = 0;
    ShellMessageHub.contexts.forEach((context: LynxContext, pageId: string) => {
      ShellMessageHub.applyEnvironment(context, pageId);
      const payload: ShellLocaleChangedPayload = {
        schemaVersion: 1,
        revision: state.revision,
        reason: reason,
        state: state
      };
      context.sendGlobalEvent(ShellMessageHub.LOCALE_EVENT, [payload]);
      affectedCount += 1;
    });
    return affectedCount;
  }

  /** 将当前 Window/viewport LayoutSnapshot 更新到所有存活 Context。 */
  static updateLayout(reason: string): number {
    let affectedCount = 0;
    ShellMessageHub.contexts.forEach((context: LynxContext, pageId: string) => {
      const snapshot = ShellLayoutState.snapshot(pageId);
      const rawScreen = ShellLayoutState.rawScreenSize();
      context.updateScreenMetrics(rawScreen.width, rawScreen.height);
      // Harmony Lynx 4.0 binding 已公开 updateViewport；Mode=1 是 definite。
      context.updateViewport(snapshot.viewportWidth, 1, snapshot.viewportHeight, 1);
      context.updateMetaData(new MetaData(
        undefined,
        new TemplateData(ShellGlobalPropsFactory.environmentProps(pageId))
      ));
      const payload: ShellLayoutChangedPayload = {
        schemaVersion: 1,
        revision: snapshot.revision,
        reason: reason,
        snapshot: snapshot
      };
      context.sendGlobalEvent(ShellMessageHub.LAYOUT_EVENT, [payload]);
      affectedCount += 1;
    });
    return affectedCount;
  }

  static pages(): ShellRouterPageInfo[] {
    const result: ShellRouterPageInfo[] = [];
    ShellMessageHub.infos.forEach((info: ShellRouterPageInfo, pageId: string) => {
      if (ShellMessageHub.contexts.has(pageId)) {
        result.push(info);
      } else {
        ShellMessageHub.infos.delete(pageId);
      }
    });
    return result;
  }

  static pageId(context: LynxContext): string | null {
    let result: string | null = null;
    ShellMessageHub.contexts.forEach((otherContext: LynxContext, pageId: string) => {
      if (otherContext === context) {
        result = pageId;
      }
    });
    return result;
  }

  static dispatchFromPage(
    context: LynxContext,
    eventName: string,
    payload: Object
  ): ShellRouterMessageReply {
    const pageId = ShellMessageHub.pageId(context);
    if (pageId === null) {
      return { accepted: false, message: '页面已销毁或 pageId 已失效' };
    }
    const handler = ShellMessageHub.messageHandler;
    if (handler === null) {
      return { accepted: false, message: '宿主尚未安装 LynxRouterMessageHandler' };
    }
    if (!ShellMessageHub.isPublicEvent(eventName)) {
      return { accepted: false, message: '事件名为空、过长或属于宿主保留事件' };
    }
    const info = ShellMessageHub.infos.get(pageId);
    if (info === undefined) {
      return { accepted: false, message: '页面身份不存在' };
    }
    try {
      return handler({ source: info, eventName: eventName.trim(), payload: payload });
    } catch (error) {
      return { accepted: false, message: `宿主消息处理异常: ${error}` };
    }
  }

  static broadcast(eventName: string, payload: Object): number {
    if (!ShellMessageHub.isPublicEvent(eventName)) {
      throw new Error('事件名为空、过长或属于宿主保留事件');
    }
    const pages = ShellMessageHub.pages();
    pages.forEach((info: ShellRouterPageInfo) => {
      const context = ShellMessageHub.contexts.get(info.pageId);
      if (context !== undefined) {
        context.sendGlobalEvent(eventName.trim(), [payload]);
      }
    });
    return pages.length;
  }

  static sendToPage(pageId: string, eventName: string, payload: Object): boolean {
    if (!ShellMessageHub.isPublicEvent(eventName)) {
      throw new Error('事件名为空、过长或属于宿主保留事件');
    }
    const context = ShellMessageHub.contexts.get(pageId);
    if (context === undefined) {
      ShellMessageHub.unregister(pageId);
      return false;
    }
    context.sendGlobalEvent(eventName.trim(), [payload]);
    return true;
  }

  static sendLifecycle(pageId: string, state: string, reason: string): void {
    const info = ShellMessageHub.infos.get(pageId);
    const context = ShellMessageHub.contexts.get(pageId);
    if (info === undefined || context === undefined) {
      return;
    }
    context.sendGlobalEvent(ShellMessageHub.LIFECYCLE_EVENT, [{
      pageId: info.pageId,
      containerId: info.containerId,
      pageKey: info.pageKey,
      hostMode: info.hostMode,
      state: state,
      reason: reason,
      timestampMillis: new Date().getTime()
    }]);
  }

  private static isPublicEvent(eventName: string): boolean {
    const normalized = eventName.trim();
    return normalized.length > 0 && normalized.length <= 128 &&
      normalized !== ShellMessageHub.LIFECYCLE_EVENT &&
      normalized !== ShellMessageHub.LOCALE_EVENT &&
      normalized !== ShellMessageHub.LAYOUT_EVENT;
  }

  private static applyEnvironment(context: LynxContext, pageId: string): void {
    const snapshot = ShellLayoutState.snapshot(pageId);
    const rawScreen = ShellLayoutState.rawScreenSize();
    context.updateColorScheme(ShellThemeState.colorScheme());
    context.updateScreenMetrics(rawScreen.width, rawScreen.height);
    context.updateViewport(snapshot.viewportWidth, 1, snapshot.viewportHeight, 1);
    context.updateMetaData(new MetaData(
      undefined,
      new TemplateData(ShellGlobalPropsFactory.environmentProps(pageId))
    ));
  }

  private constructor() {
  }
}
