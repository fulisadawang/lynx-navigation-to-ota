import ShellTransitionColor from './ShellTransitionColor';
import ShellRoutePresentationSpec from './ShellRoutePresentationSpec';
import ShellRectTween from './ShellRectTween';
import { FrameNode } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { LynxContext } from '@lynx/lynx';
import { UIContext } from '@kit.ArkUI';

export interface ShellTransitionRect { left: number; top: number; width: number; height: number; }
export interface ShellTransitionPresentation { x: number; y: number; scale: number; }
export interface ShellTransitionView {
  entryID: string; viewID: string; context?: LynxContext; ui: UIContext; holderID: string; sessionID: string;
  applyWindowPolicy?: () => void; rootContent?: boolean; setCovered?: (covered: boolean) => void; presentationSpec?: ShellRoutePresentationSpec; updateTransition?: (id: string) => void;
  loadGeneration?: number; identityEpoch?: number; backgroundColor: string; firstScreen: boolean;
  getPresentation: () => ShellTransitionPresentation; setPresentation: (value: ShellTransitionPresentation) => void;
  isActive: () => boolean; getOpacity: () => number; setOpacity: (value: number) => void;
}
export interface ShellCapturedImage { image: image.PixelMap; rect: ShellTransitionRect; bytes: number; released: boolean; }

/** 预留覆盖并行/迟到快照；实际PixelMap字节再次核验，禁止只按压缩图片大小计预算。 */
export class ShellSnapshotBudget {
  private static globalBytes: number = 0;
  private bytes: number = 0;
  private pending: number = 0;
  private closed: boolean = false;
  private readonly images: ShellCapturedImage[] = [];
  static readonly MAX_BYTES: number = 64 * 1024 * 1024;

  async capture(rect: ShellTransitionRect, ui: UIContext, fetch: (scale: number) => Promise<image.PixelMap>, alive: () => boolean): Promise<ShellCapturedImage> {
    ShellTransitionGeometry.validate(rect);
    const density = ui.vp2px(1);
    const estimate = Math.ceil(rect.width * density) * Math.ceil(rect.height * density) * 4;
    const available = ShellSnapshotBudget.MAX_BYTES - ShellSnapshotBudget.globalBytes;
    if (available <= 0) throw new Error('snapshot_budget_exceeded');
    const scale = Math.min(1, Math.sqrt(available / estimate));
    if (scale < 0.25) throw new Error('snapshot_budget_exceeded');
    const reservation = Math.ceil(estimate * scale * scale);
    this.pending += reservation; ShellSnapshotBudget.globalBytes += reservation;
    let pixel: image.PixelMap | null = null;
    try {
      pixel = await fetch(scale);
      const actual = pixel.getPixelBytesNumber();
      if (this.closed || !alive()) throw new Error('snapshot_owner_destroyed');
      if (actual <= 0 || ShellSnapshotBudget.globalBytes - reservation + actual > ShellSnapshotBudget.MAX_BYTES) throw new Error('snapshot_budget_exceeded');
      const result: ShellCapturedImage = { image: pixel, rect: rect, bytes: actual, released: false };
      this.images.push(result); this.bytes += actual; ShellSnapshotBudget.globalBytes += actual; pixel = null;
      return result;
    } finally { if (pixel !== null) await pixel.release(); this.pending -= reservation; ShellSnapshotBudget.globalBytes -= reservation; }
  }

  maskCapacity(): number { return ShellSnapshotBudget.MAX_BYTES - ShellSnapshotBudget.globalBytes; }
  reserveMask(bytes: number): void {
    if (this.closed || bytes <= 0 || ShellSnapshotBudget.globalBytes + bytes > ShellSnapshotBudget.MAX_BYTES) throw new Error('snapshot_budget_exceeded');
    this.bytes += bytes; ShellSnapshotBudget.globalBytes += bytes;
  }
  releaseMask(bytes: number): void { this.bytes -= bytes; ShellSnapshotBudget.globalBytes -= bytes; }
  async release(item: ShellCapturedImage): Promise<void> {
    if (item.released) return; item.released = true;
    await item.image.release(); this.bytes -= item.bytes; ShellSnapshotBudget.globalBytes -= item.bytes;
  }
  close(): void { if (this.closed) return; this.closed = true; this.images.forEach((item) => this.release(item).catch(() => { /* 释放失败仍占预算，不回收未确认释放额度。 */ })); }
}

export default class ShellTransitionGeometry {
  static nativeBackdropColor(value: string): string {
    // 普通request.backgroundColor沿既有ArkUI ARGB；高级wire颜色单独沿RRGGBBAA解析。
    const normalized = /^#[0-9a-fA-F]{8}$/.test(value) ? '#' + value.substring(3) + value.substring(1, 3) : value;
    return ShellTransitionColor.mix(normalized, normalized, 0);
  }
  static validate(rect: ShellTransitionRect): void {
    if (![rect.left, rect.top, rect.width, rect.height].every((v) => Number.isFinite(v)) || rect.width <= 0 || rect.height <= 0) throw new Error('selector_geometry_unavailable');
  }
  static element(view: ShellTransitionView, id: string): ShellTransitionRect {
    if (!view.isActive()) throw new Error('source_context_destroyed');
    if (view.context === undefined) throw new Error('selector_missing');
    const rect: ShellTransitionRect = { left: 0, top: 0, width: 0, height: 0 };
    view.ui.runScopedTask(() => {
      const info = view.context!.getRectangleById(id);
      rect.left = view.ui.px2vp(info.windowOffset.x); rect.top = view.ui.px2vp(info.windowOffset.y);
      rect.width = view.ui.px2vp(info.size.width); rect.height = view.ui.px2vp(info.size.height);
    });
    ShellTransitionGeometry.validate(rect);
    const holder = ShellTransitionGeometry.holder(view);
    if (rect.left + rect.width <= holder.left || rect.top + rect.height <= holder.top || rect.left >= holder.left + holder.width || rect.top >= holder.top + holder.height) throw new Error('selector_not_visible');
    const root = view.ui.getFrameNodeById(view.holderID);
    if (root === null) throw new Error('selector_visibility_unavailable');
    const pending: FrameNode[] = [root];
    let matches = 0; let visible = false; let visited = 0;
    while (pending.length > 0 && visited < 2048) {
      const node = pending.pop(); if (node === undefined) break; visited += 1;
      if (node.getId().endsWith(id)) {
        const pos = node.getPositionToWindowWithTransform(); const size = node.getMeasuredSize();
        if (Math.abs(pos.x - rect.left) < 1 && Math.abs(pos.y - rect.top) < 1 &&
          Math.abs(view.ui.px2vp(size.width) - rect.width) < 1 && Math.abs(view.ui.px2vp(size.height) - rect.height) < 1) {
          matches += 1; visible = node.isVisible() && node.getOpacity() > 0;
        }
      }
      let child = node.getFirstChild(); while (child !== null) { pending.push(child); child = child.getNextSibling(); }
    }
    if (pending.length > 0 || matches !== 1 || !visible) throw new Error('selector_not_visible_or_ambiguous');
    return rect;
  }
  static holder(view: ShellTransitionView): ShellTransitionRect {
    const info = view.ui.getComponentUtils().getRectangleById(view.holderID);
    const rect: ShellTransitionRect = { left: view.ui.px2vp(info.windowOffset.x), top: view.ui.px2vp(info.windowOffset.y), width: view.ui.px2vp(info.size.width), height: view.ui.px2vp(info.size.height) };
    ShellTransitionGeometry.validate(rect); return rect;
  }
  static mix(from: ShellTransitionRect, to: ShellTransitionRect, progress: number, tween: string = 'linear'): ShellTransitionRect {
    return ShellRectTween.mix(from, to, progress, tween);
  }

}
