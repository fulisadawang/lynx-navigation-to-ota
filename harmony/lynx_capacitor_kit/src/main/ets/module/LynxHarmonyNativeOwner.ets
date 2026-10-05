import util from '@ohos.util';

/** 每个真实 LynxContext 只有一个 owner；Module 与旧 Shell 入口共享资源。 */
export class LynxHarmonyNativeOwner {
  public readonly id: string = util.generateRandomUUID(false);
  private active: boolean = true;
  private cleanups: Map<string, () => void> = new Map();

  public get isActive(): boolean { return this.active; }

  public checkActive(): void {
    if (!this.active) throw new Error('ACTIVITY_DESTROYED: Lynx owner 已销毁');
  }

  public own(key: string, cleanup: () => void): void {
    this.checkActive();
    const previous = this.cleanups.get(key);
    if (previous !== undefined) previous();
    this.cleanups.set(key, cleanup);
  }

  public disown(key: string): void { this.cleanups.delete(key); }

  public close(): void {
    if (!this.active) return;
    this.active = false;
    const cleanups = Array.from(this.cleanups.values());
    this.cleanups.clear();
    cleanups.forEach((cleanup: () => void): void => {
      try { cleanup(); } catch (error) {
        console.error('LynxCapacitor', 'Owner resource cleanup failed: ' + String(error));
      }
    });
  }
}
