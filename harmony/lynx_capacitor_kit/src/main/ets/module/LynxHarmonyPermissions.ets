import { PermissionRequestResult } from '@ohos.abilityAccessCtrl';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';
import { LynxCapacitorHost } from './LynxCapacitorHost';

/** 一个 Ability 同时只能呈现一个系统授权请求；排队后重新检查 owner 与前台。 */
export class LynxHarmonyPermissions {
  private static queues: Map<common.UIAbilityContext, Promise<void>> = new Map();
  public static ensure(owner: LynxHarmonyNativeOwner, host: LynxCapacitorHost, permissions: Array<Permissions>): Promise<void> {
    const manager = abilityAccessCtrl.createAtManager();
    const run = async (): Promise<void> => {
      owner.checkActive();
      if (!host.isVisible()) throw new Error('UNAVAILABLE: 页面不在前台，不能打开授权界面');
      const needed = permissions.filter((permission: Permissions): boolean => manager.getSelfPermissionStatus(permission) !== abilityAccessCtrl.PermissionStatus.GRANTED);
      if (needed.length === 0) return;
      const result = await new Promise<PermissionRequestResult>((resolve, reject): void => {
        host.uiContext.runScopedTask((): void => { manager.requestPermissionsFromUser(host.abilityContext, needed).then(resolve).catch(reject); });
      });
      owner.checkActive();
      if (result.authResults.some((status: number): boolean => status !== abilityAccessCtrl.PermissionStatus.GRANTED)) throw new Error('PERMISSION_DENIED: 系统权限未授予');
    };
    const previous = LynxHarmonyPermissions.queues.get(host.abilityContext) ?? Promise.resolve();
    const operation = previous.then(run);
    const tail = operation.catch((_error: Object): void => {});
    LynxHarmonyPermissions.queues.set(host.abilityContext, tail);
    tail.finally((): void => {
      if (LynxHarmonyPermissions.queues.get(host.abilityContext) === tail) LynxHarmonyPermissions.queues.delete(host.abilityContext);
    });
    return operation;
  }
}
