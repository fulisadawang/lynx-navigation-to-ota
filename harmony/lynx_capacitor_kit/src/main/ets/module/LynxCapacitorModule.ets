import { common } from '@kit.AbilityKit';
import { LynxContext, LynxModule } from '@lynx/lynx';
import { LynxCapacitorHost, LynxCapacitorHosts } from './LynxCapacitorHost';
import { LynxHarmonyCapabilityRuntime } from './LynxHarmonyCapabilityRuntime';

/** SDK facade 不持有第二个 owner；旧 Shell 先调用和 SDK 懒初始化共享 exact Context runtime。 */
export class LynxCapacitorModule extends LynxModule {
  public static syncMethods: Array<string> = ['getPlatform', 'getPluginHeaders', 'getCapabilityStatus'];
  private runtime: LynxHarmonyCapabilityRuntime;
  constructor(context: LynxContext, param?: Object) {
    super(context, param);
    this.runtime = LynxHarmonyCapabilityRuntime.forContext(context);
  }
  public getPlatform(): string { return this.runtime.getPlatform(); }
  public getPluginHeaders(): string { return this.runtime.getPluginHeaders(); }
  public getCapabilityStatus(): string { return this.runtime.getCapabilityStatus(); }
  public handleCall(payload: string, callback: (json: string) => void): void { this.runtime.handleCall(payload, callback); }
  public destroy(): void { this.runtime.destroy(); }
  public static handleLegacyMedia(context: LynxContext, method: string, optionsJSON: string, callback: (json: string) => void): void {
    try { LynxHarmonyCapabilityRuntime.forContext(context).handleLegacyMedia(method, optionsJSON, callback); }
    catch (error) { callback(JSON.stringify({ code: -1, msg: String(error) })); }
  }
  public static onHostVisibilityChanged(context: LynxContext): void { LynxHarmonyCapabilityRuntime.onHostVisibilityChanged(context); }
  public static bindHost(context: LynxContext, host: LynxCapacitorHost): void { LynxCapacitorHosts.bind(context, host); }
  public static destroyForContext(context: LynxContext | null): void { LynxHarmonyCapabilityRuntime.destroyForContext(context); }
  public static setHostContext(context: common.UIAbilityContext): void { LynxHarmonyCapabilityRuntime.setHostContext(context); }
  public static clearHostContext(context: common.UIAbilityContext): void { LynxHarmonyCapabilityRuntime.clearHostContext(context); }
  public static setLaunchUrl(url: string): void { LynxHarmonyCapabilityRuntime.setLaunchUrl(url); }
  public static emitAppUrlOpen(url: string): void { LynxHarmonyCapabilityRuntime.emitAppUrlOpen(url); }
  public static emitAppState(active: boolean): void { LynxHarmonyCapabilityRuntime.emitAppState(active); }
  public static emitPushRegistration(token: string): void { LynxHarmonyCapabilityRuntime.emitPushRegistration(token); }
  public static emitPushRegistrationError(message: string): void { LynxHarmonyCapabilityRuntime.emitPushRegistrationError(message); }
  public static emitPushNotification(data: Record<string, Object>): void { LynxHarmonyCapabilityRuntime.emitPushNotification(data); }
  public static dispatchBackButton(): boolean { return LynxHarmonyCapabilityRuntime.dispatchBackButton(); }
  public static dispatchBackButtonForContext(context: LynxContext): boolean { return LynxHarmonyCapabilityRuntime.dispatchBackButtonForContext(context); }
}
