import { LynxContext, ModuleClassWrapper } from '@lynx/lynx';

/** 额外能力由 Entry 安装，Shell HAR 不依赖具体能力 HAR。 */
export interface HostNativeModuleRegistration {
  name: string;
  props: ModuleClassWrapper;
  onContextDestroyed: (context: LynxContext) => void;
  onBackPress: (context: LynxContext) => boolean;
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

  static destroyForContext(context: LynxContext): void {
    HostNativeModules.registrations.forEach((registration: HostNativeModuleRegistration) => {
      registration.onContextDestroyed(context);
    });
  }

  static dispatchBackPress(context: LynxContext): boolean {
    const registrations = Array.from(HostNativeModules.registrations.values());
    for (const registration of registrations) {
      if (registration.onBackPress(context)) return true;
    }
    return false;
  }
}
