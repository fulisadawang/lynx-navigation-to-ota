import { UIContext } from '@kit.ArkUI';
import { FrameCallback } from '@ohos.arkui.UIContext';

/** 窗口选项Promise返回后继续等实际布局连续两帧稳定，避免用旋转前的旧几何截屏。 */
class StableWindowFrame extends FrameCallback {
  private readonly ui: UIContext; private readonly alive: () => boolean; private readonly done: (error?: Error) => void;
  private previous: string = ''; private stable: number = 0; private closed: boolean = false;
  constructor(ui: UIContext, alive: () => boolean, done: (error?: Error) => void) { super(); this.ui = ui; this.alive = alive; this.done = done; }
  close(): void { this.closed = true; }
  onFrame(time: number): void {}
  onIdle(time: number): void {
    if (this.closed) return;
    if (!this.alive()) { this.closed = true; this.done(new Error('navigation_owner_destroyed')); return; }
    try {
      const rect = this.ui.getComponentUtils().getRectangleById('lynx-navigation-overlay-root');
      const values = [rect.size.width, rect.size.height, rect.windowOffset.x, rect.windowOffset.y, this.ui.vp2px(1)];
      if (!values.every((value) => Number.isFinite(value)) || values[0] <= 0 || values[1] <= 0) throw new Error('window_geometry_invalid');
      const key = values.map((value) => Math.round(value * 1000) / 1000).join(':');
      this.stable = key === this.previous ? this.stable + 1 : 0; this.previous = key;
      if (this.stable >= 2) { this.closed = true; this.done(); } else this.ui.postFrameCallback(this);
    } catch (error) { this.closed = true; this.done(error as Error); }
  }
}

export default class ShellWindowPolicyFrame {
  static wait(ui: UIContext, timeoutMs: number, alive: () => boolean): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let settled = false; let timer = -1;
      const frame = new StableWindowFrame(ui, alive, (error?: Error) => { if (settled) return; settled = true; clearTimeout(timer); error === undefined ? resolve() : reject(error); });
      timer = setTimeout(() => { if (settled) return; settled = true; frame.close(); reject(new Error('window_layout_not_ready')); }, timeoutMs);
      ui.postFrameCallback(frame);
    });
  }
}
