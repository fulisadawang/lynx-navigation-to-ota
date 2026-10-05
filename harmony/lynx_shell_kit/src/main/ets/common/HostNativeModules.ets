import { LynxContext, ModuleClassWrapper } from '@lynx/lynx';
import { UIContext } from '@ohos.arkui.UIContext';
import ShellMessageHub from './ShellMessageHub';
import ShellLayoutState from './ShellLayoutState';

interface MissingMediaHandlerResult {
  code: number;
  msg: string;
}

/** 额外能力由 Entry 安装，Shell HAR 不依赖具体能力 HAR。 */
export interface HostNativeModuleRegistration {
  name: string;
  props: ModuleClassWrapper;
  onContextDestroyed: (context: LynxContext) => void;
  onBackPress: (context: LynxContext) => boolean;
  onContextAttached?: (context: LynxContext, uiContext: UIContext, isVisible: () => boolean) => void;
  onContextVisibilityChanged?: (context: LynxContext) => void;
  onContextIsVisible?: (context: LynxContext) => boolean;
  onMediaCall?: (context: LynxContext, method: string, optionsJSON: string, callback: (resultJSON: string) => void) => void;
}

export default class HostNativeModules {
  private static registrations: Map<string, HostNativeModuleRegistration> = new Map();

  static register(registration: HostNativeModuleRegistration): void {
    if (registration.name === 'LynxShellModule') {
      throw new Error('额外能力模块不能覆盖 Shell 导航模块');
    }
    HostNativeModules.registrations.set(registration.name, registration);
  }

  static applyTo(modules: Map<string, ModuleClassWrapper>): void {
    HostNativeModules.registrations.forEach((registration: HostNativeModuleRegistration) => {
      modules.set(registration.name, registration.props);
    });
  }

  /** 页面提供真实UI作用域，具体能力仍由Entry组合，不在Shell引入Cap实现。 */
  static attachContext(context: LynxContext, uiContext: UIContext, isVisible: () => boolean): void {
    ShellLayoutState.updateDensity(uiContext.vp2px(1));
    HostNativeModules.registrations.forEach((registration: HostNativeModuleRegistration): void => {
      registration.onContextAttached?.(context, uiContext, isVisible);
    });
  }

  static callMedia(context: LynxContext, method: string, optionsJSON: string, callback: (resultJSON: string) => void): void {
    const providers = Array.from(HostNativeModules.registrations.values());
    const registration = providers.find((item: HostNativeModuleRegistration): boolean => item.onMediaCall !== undefined);
    if (registration === undefined || registration.onMediaCall === undefined) {
      const result: MissingMediaHandlerResult = { code: -1, msg: '当前宿主未安装原生媒体处理器' };
      callback(JSON.stringify(result));
      return;
    }
    registration.onMediaCall(context, method, optionsJSON, callback);
  }

  static contextVisibilityChanged(context: LynxContext): void {
    HostNativeModules.registrations.forEach((registration: HostNativeModuleRegistration): void => {
      registration.onContextVisibilityChanged?.(context);
    });
  }

  static isContextVisible(context: LynxContext): boolean {
    const providers = Array.from(HostNativeModules.registrations.values());
    return providers.every((provider: HostNativeModuleRegistration): boolean =>
      provider.onContextIsVisible === undefined || provider.onContextIsVisible(context));
  }

  static destroyForContext(context: LynxContext): void {
    HostNativeModules.registrations.forEach((registration: HostNativeModuleRegistration) => {
      registration.onContextDestroyed(context);
    });
  }

  static dispatchBackPress(context: LynxContext): boolean {
    const pageId = ShellMessageHub.pageId(context);
    if (pageId !== null && !ShellMessageHub.backGestureEnabled(pageId)) return true;
    const registrations = Array.from(HostNativeModules.registrations.values());
    for (const registration of registrations) {
      if (registration.onBackPress(context)) return true;
    }
    return false;
  }
}
