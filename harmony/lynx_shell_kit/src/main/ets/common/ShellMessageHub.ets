import { LynxContext } from '@lynx/lynx';
import { ShellRouterMessage, ShellRouterMessageHandler, ShellRouterMessageReply, ShellRouterPageInfo } from './ShellTypes';

/**
 * HarmonyOS 进程内 Lynx 页面消息中心。
 *
 * ArkUI Page 的销毁由页面生命周期驱动；页面离开时必须注销 Context。消息中心不保存
 * 离线消息，只向仍在当前 Native Page Stack 中的页面发送事件。
 */
export default class ShellMessageHub {
  static readonly LIFECYCLE_EVENT: string = 'lynxRouterLifecycle';
  private static infos: Map<string, ShellRouterPageInfo> = new Map();
  private static contexts: Map<string, LynxContext> = new Map();
  private static messageHandler: ShellRouterMessageHandler | null = null;

  static setMessageHandler(handler: ShellRouterMessageHandler | null): void {
    ShellMessageHub.messageHandler = handler;
  }

  static register(info: ShellRouterPageInfo, context: LynxContext): void {
    ShellMessageHub.infos.set(info.pageId, info);
    ShellMessageHub.contexts.set(info.pageId, context);
  }

  static unregister(pageId: string): void {
    ShellMessageHub.infos.delete(pageId);
    ShellMessageHub.contexts.delete(pageId);
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
    ShellMessageHub.contexts.forEach((candidate: LynxContext, pageId: string) => {
      if (candidate === context) {
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
      normalized !== ShellMessageHub.LIFECYCLE_EVENT;
  }

  private constructor() {
  }
}
