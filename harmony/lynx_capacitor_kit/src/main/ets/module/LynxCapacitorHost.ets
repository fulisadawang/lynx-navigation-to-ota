import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { UIContext } from '@ohos.arkui.UIContext';
import { LynxContext } from '@lynx/lynx';

export interface LynxCapacitorHost {
  abilityContext: common.UIAbilityContext;
  uiContext: UIContext;
  window: window.Window;
  isVisible: () => boolean;
  keyboardResizeMode?: string;
}

/** 宿主按实际页面 Context 登记；多 Page/Tab 不依赖最后创建的全局窗口。 */
export class LynxCapacitorHosts {
  private static hosts: Map<LynxContext, LynxCapacitorHost> = new Map();
  public static bind(context: LynxContext, host: LynxCapacitorHost): void {
    LynxCapacitorHosts.hosts.set(context, host);
  }
  public static find(context: LynxContext): LynxCapacitorHost | null {
    return LynxCapacitorHosts.hosts.get(context) ?? null;
  }
  public static unbind(context: LynxContext): void { LynxCapacitorHosts.hosts.delete(context); }
}

interface WindowLease {
  owners: Set<string>;
  serial: Promise<void>;
  baseline: boolean;
  revision: number;
}

/** 同一窗口的 keep-awake/privacy 使用多 owner lease；一页关闭不能取消另一页需求。 */
export class LynxCapacitorWindowLeases {
  private static awake: WeakMap<window.Window, WindowLease> = new WeakMap();
  private static privacy: WeakMap<window.Window, WindowLease> = new WeakMap();

  public static set(target: window.Window, ownerId: string, privacy: boolean, enabled: boolean): Promise<void> {
    const registry = privacy ? LynxCapacitorWindowLeases.privacy : LynxCapacitorWindowLeases.awake;
    let lease = registry.get(target);
    if (lease === undefined) {
      if (!enabled) return Promise.resolve();
      const properties = target.getWindowProperties();
      lease = { owners: new Set<string>(), serial: Promise.resolve(), baseline: privacy ? properties.isPrivacyMode : properties.isKeepScreenOn, revision: 0 };
      registry.set(target, lease);
    }
    const current = lease;
    const before = current.owners.has(ownerId);
    if (enabled) current.owners.add(ownerId); else current.owners.delete(ownerId);
    const revision = ++current.revision;
    const run = current.serial.then(async (): Promise<void> => {
      try {
        const value = current.baseline || current.owners.size > 0;
        if (privacy) await target.setWindowPrivacyMode(value);
        else await target.setWindowKeepScreenOn(value);
      } catch (error) {
        if (current.revision === revision) { if (before) current.owners.add(ownerId); else current.owners.delete(ownerId); }
        throw error;
      }
    });
    const tail = run.catch((_error: Object): void => {});
    current.serial = tail;
    tail.then((): void => {
      if (current.owners.size === 0 && current.serial === tail && registry.get(target) === current) registry.delete(target);
    });
    return run;
  }

  public static release(target: window.Window, ownerId: string): void {
    [false, true].forEach((privacy: boolean): void => {
      LynxCapacitorWindowLeases.set(target, ownerId, privacy, false).catch((error: Object): void => {
        console.error('LynxCapacitor', 'Window lease release failed: ' + String(error));
      });
    });
  }
}
