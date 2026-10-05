import { LengthMetricsUnit } from '@kit.ArkUI';
import ShellPresetFrame from './ShellPresetFrame';
import ShellTransitionColor from './ShellTransitionColor';
import ShellTransitionGeometry, { ShellCapturedImage, ShellSnapshotBudget, ShellTransitionRect } from './ShellTransitionGeometry';
import ShellTransitionSpec, { ShellRectStyle } from './ShellTransitionSpec';

export interface ShellTransitionPair { from: ShellCapturedImage; to: ShellCapturedImage; tween: string; shuttle: 'from' | 'to'; fromStyle?: ShellRectStyle; toStyle?: ShellRectStyle; }
interface ShellMaskedBody { bitmap: ImageBitmap; rect: ShellTransitionRect; bytes: number; }

/** 真实容器暂隐藏；原生Canvas独立body层减去所有洞，destination-out不会把重叠洞异或回来。 */
@Observed
export class ShellTransitionCanvasModel {
  visible: boolean = false; prepared: boolean = false; progress: number = 0; direction: 'push' | 'pop' = 'push';
  secondaryLinked: boolean = true; usePreset: boolean = true;
  effective: string = 'fade'; spec: ShellTransitionSpec = new ShellTransitionSpec();
  sourceBackdrop: ShellCapturedImage | null = null;
  source: ShellCapturedImage | null = null; target: ShellCapturedImage | null = null; pairs: ShellTransitionPair[] = [];
  sourceColor: string = '#FFFFFF'; targetColor: string = '#FFFFFF';
  redraw: (() => void) | null = null;
  budget: ShellSnapshotBudget | null = null;
  origin: ShellTransitionRect = { left: 0, top: 0, width: 1, height: 1 };
  private closed: boolean = false;
  private sourceMasked: ShellMaskedBody | null = null;
  private targetMasked: ShellMaskedBody | null = null;

  async prepareBodies(): Promise<void> {
    // Open展开页原图同时是shuttle；只处理关闭页背景，不复制/释放仍供morph的展开页资产。
    if (this.effective !== 'openContainer' || this.direction === 'push') {
      if (this.source !== null && this.sourceMasked === null) this.sourceMasked = await this.mask(this.source, this.pairs.map((pair) => pair.from.rect));
    }
    if (this.effective !== 'openContainer' || this.direction === 'pop') {
      if (this.target !== null && this.targetMasked === null) this.targetMasked = await this.mask(this.target, this.pairs.map((pair) => pair.to.rect));
    }
  }
  private async mask(body: ShellCapturedImage, holes: ShellTransitionRect[]): Promise<ShellMaskedBody> {
    const info = body.image.getImageInfoSync();
    const available = this.budget?.maskCapacity() ?? 0;
    const scale = Math.min(1, Math.sqrt(available / (info.size.width * info.size.height * 4)));
    if (scale < 0.25) throw new Error('snapshot_budget_exceeded');
    const width = Math.max(1, Math.floor(info.size.width * scale)); const height = Math.max(1, Math.floor(info.size.height * scale));
    const bytes = width * height * 4;
    this.budget?.reserveMask(bytes);
    try {
      const canvas = new OffscreenCanvas(width, height, LengthMetricsUnit.PX);
      const context = canvas.getContext('2d');
      if (context === null) throw new Error('snapshot_mask_unavailable');
      context.drawImage(body.image, 0, 0, width, height);
      context.globalCompositeOperation = 'destination-out';
      holes.forEach((hole) => context.fillRect((hole.left - body.rect.left) * width / body.rect.width,
        (hole.top - body.rect.top) * height / body.rect.height, hole.width * width / body.rect.width, hole.height * height / body.rect.height));
      const bitmap = canvas.transferToImageBitmap();
      await this.budget?.release(body);
      if (this.closed) { bitmap.close(); throw new Error('snapshot_owner_destroyed'); }
      return { bitmap: bitmap, rect: body.rect, bytes: bytes };
    } catch (error) { this.budget?.releaseMask(bytes); throw (error as Error); }
  }
  draw(context: CanvasRenderingContext2D): void {
    if (!this.visible) return;
    if (!this.prepared) {
      context.clearRect(0, 0, this.origin.width, this.origin.height);
      if (this.sourceBackdrop !== null) this.drawImage(context, this.sourceBackdrop, this.sourceBackdrop.rect, 1);
      else if (this.source !== null) this.drawImage(context, this.source, this.source.rect, 1);
      return;
    }
    const p = Math.max(0, Math.min(1, this.progress));
    const t = this.direction === 'push' ? p : 1 - p;
    context.clearRect(0, 0, this.origin.width, this.origin.height);
    // 部分/透明容器外保留真实更下层页面；不可用整屏纯色擦掉嵌套Dialog/Sheet的underlay。
    if (this.effective === 'openContainer' && this.spec.openContainer !== undefined && this.pairs.length > 0) {
      this.drawOpen(context, t); return;
    }
    if (this.usePreset && this.spec.style === 'default' && this.spec.presentation.routeType !== undefined) { this.drawPreset(context, p); return; }
    const push = this.direction === 'push'; const slide = this.effective === 'slide'; const up = this.effective === 'slideUp';
    const modal = ['cupertinoModal', 'cupertinoModalInside', 'modalNavigation'].includes(this.spec.presentation.mode);
    if (!push && (slide || up)) this.drawBody(context, this.targetMasked, 1, slide ? -this.origin.width * (1 - p) * 0.25 : 0, 0, modal ? 0.92 + p * 0.08 : 1);
    this.drawBody(context, this.sourceMasked, !this.secondaryLinked && push || slide || up ? 1 : 1 - p, slide ? (push ? this.secondaryLinked ? -this.origin.width * p * 0.25 : 0 : this.origin.width * p) : 0,
      up && !push ? this.origin.height * p : 0, modal && push ? 1 - p * 0.08 : 1);
    if (push || !(slide || up)) this.drawBody(context, this.targetMasked, this.effective === 'none' || slide || up ? 1 : p,
      slide && push ? this.origin.width * (1 - p) : 0, up && push ? this.origin.height * (1 - p) : 0, this.effective === 'zoom' ? 0.92 + p * 0.08 : 1);
    if (this.effective === 'sharedElement') this.pairs.forEach((pair) => {
      const rect = ShellTransitionGeometry.mix(pair.from.rect, pair.to.rect, p, pair.tween);
      const from = pair.fromStyle; const to = pair.toStyle;
      const radius = (from?.cornerRadius ?? 0) + ((to?.cornerRadius ?? 0) - (from?.cornerRadius ?? 0)) * p;
      context.save(); this.roundPath(context, rect, radius);
      context.shadowBlur = (from?.elevation ?? 0) + ((to?.elevation ?? 0) - (from?.elevation ?? 0)) * p; context.shadowColor = 'rgba(0,0,0,0.25)';
      context.fillStyle = ShellTransitionColor.mix(from?.backgroundColor ?? 'transparent', to?.backgroundColor ?? 'transparent', p); context.fill(); context.clip(); context.shadowBlur = 0;
      this.drawImage(context, pair.shuttle === 'from' ? pair.from : pair.to, rect, 1); context.restore();
    });
  }
  private drawPreset(context: CanvasRenderingContext2D, progress: number): void {
    const push = this.direction === 'push'; const p = push ? progress : 1 - progress;
    const primary = push ? this.targetMasked : this.sourceMasked; const secondary = push ? this.sourceMasked : this.targetMasked;
    const frame = ShellPresetFrame.at(this.spec.presentation, p, this.origin.width, this.origin.height, primary?.rect.height ?? this.origin.height, this.secondaryLinked);
    this.drawBody(context, secondary, frame.secondary.alpha, frame.secondary.x, frame.secondary.y, frame.secondary.scale);
    if (!this.spec.presentation.opaque && this.spec.presentation.mode !== 'heroSheet') { context.save(); context.globalAlpha = p; context.fillStyle = ShellTransitionColor.mix(this.spec.presentation.barrierColor, this.spec.presentation.barrierColor, 0); context.fillRect(0, 0, this.origin.width, this.origin.height); context.restore(); }
    const mode = this.spec.presentation.mode; const radius = mode === 'bottomSheet' ? this.spec.presentation.round ? 16 : 0 : ['cupertinoModal', 'cupertinoModalInside'].includes(mode) ? 26 : mode === 'modalNavigation' ? 24 : mode === 'modal' ? 20 : 0;
    this.drawBody(context, primary, frame.primary.alpha, frame.primary.x, frame.primary.y, frame.primary.scale, radius);
  }
  private roundPath(context: CanvasRenderingContext2D, rect: ShellTransitionRect, radius: number): void {
    const x = rect.left - this.origin.left; const y = rect.top - this.origin.top; const r = Math.min(radius, rect.width / 2, rect.height / 2);
    context.beginPath(); context.moveTo(x + r, y); context.lineTo(x + rect.width - r, y); context.quadraticCurveTo(x + rect.width, y, x + rect.width, y + r);
    context.lineTo(x + rect.width, y + rect.height - r); context.quadraticCurveTo(x + rect.width, y + rect.height, x + rect.width - r, y + rect.height);
    context.lineTo(x + r, y + rect.height); context.quadraticCurveTo(x, y + rect.height, x, y + rect.height - r); context.lineTo(x, y + r); context.quadraticCurveTo(x, y, x + r, y); context.closePath();
  }
  private drawBody(context: CanvasRenderingContext2D, body: ShellMaskedBody | null, opacity: number, dx: number, dy: number, scale: number, radius: number = 0): void {
    if (body === null) return;
    context.save(); context.globalAlpha = Math.max(0, Math.min(1, opacity));
    const x = body.rect.left - this.origin.left + dx + body.rect.width * (1 - scale) / 2; const y = body.rect.top - this.origin.top + dy + body.rect.height * (1 - scale) / 2;
    if (radius > 0) { this.roundPath(context, { left: x + this.origin.left, top: y + this.origin.top, width: body.rect.width * scale, height: body.rect.height * scale }, radius * scale); context.clip(); }
    context.fillStyle = body === this.sourceMasked ? this.sourceColor : this.targetColor;
    context.fillRect(x, y, body.rect.width * scale, body.rect.height * scale);
    context.drawImage(body.bitmap, x, y, body.rect.width * scale, body.rect.height * scale); context.restore();
  }
  private drawImage(context: CanvasRenderingContext2D, capture: ShellCapturedImage, rect: ShellTransitionRect, alpha: number): void {
    context.save(); context.globalAlpha = Math.max(0, Math.min(1, alpha));
    context.drawImage(capture.image, rect.left - this.origin.left, rect.top - this.origin.top, rect.width, rect.height); context.restore();
  }
  private drawOpen(context: CanvasRenderingContext2D, t: number): void {
    const open = this.spec.openContainer;
    if (open === undefined) return;
    const pair = this.pairs[0];
    const rect = ShellTransitionGeometry.mix(pair.from.rect, pair.to.rect, this.progress, 'materialRectArc');
    const radius = this.direction === 'push' ? open.closedCornerRadius + (open.openCornerRadius - open.closedCornerRadius) * t : open.openCornerRadius + (open.closedCornerRadius - open.openCornerRadius) * this.progress;
    const backdrop = this.direction === 'push' ? this.sourceMasked : this.targetMasked;
    this.drawBody(context, backdrop, 1, 0, 0, 1);
    context.save();
    const x = rect.left - this.origin.left; const y = rect.top - this.origin.top;
    const r = Math.min(radius, rect.width / 2, rect.height / 2);
    context.beginPath(); context.moveTo(x + r, y); context.lineTo(x + rect.width - r, y); context.quadraticCurveTo(x + rect.width, y, x + rect.width, y + r);
    context.lineTo(x + rect.width, y + rect.height - r); context.quadraticCurveTo(x + rect.width, y + rect.height, x + rect.width - r, y + rect.height);
    context.lineTo(x + r, y + rect.height); context.quadraticCurveTo(x, y + rect.height, x, y + rect.height - r); context.lineTo(x, y + r); context.quadraticCurveTo(x, y, x + r, y); context.closePath();
    context.shadowBlur = open.closedElevation + (open.openElevation - open.closedElevation) * t; context.shadowColor = 'rgba(0,0,0,0.25)';
    context.fillStyle = open.transitionType === 'fadeThrough' && open.middleColor !== undefined ? (t < 0.5 ? ShellTransitionColor.mix(open.closedColor, open.middleColor, t * 2) : ShellTransitionColor.mix(open.middleColor, open.openColor, t * 2 - 1)) : ShellTransitionColor.mix(open.closedColor, open.openColor, t);
    context.fill(); context.clip(); context.shadowBlur = 0;
    const closed = this.direction === 'push' ? pair.from : pair.to; const expanded = this.direction === 'push' ? pair.to : pair.from;
    const closedAlpha = open.transitionType === 'fadeThrough' ? Math.max(0, 1 - t * 2) : 1 - t;
    const openAlpha = open.transitionType === 'fadeThrough' ? Math.max(0, t * 2 - 1) : t;
    this.drawImage(context, closed, rect, closedAlpha); this.drawImage(context, expanded, rect, openAlpha); context.restore();
  }
  close(): void {
    this.closed = true; this.visible = false; this.prepared = false; this.redraw = null;
    if (this.sourceMasked !== null) { this.sourceMasked.bitmap.close(); this.budget?.releaseMask(this.sourceMasked.bytes); this.sourceMasked = null; }
    if (this.targetMasked !== null) { this.targetMasked.bitmap.close(); this.budget?.releaseMask(this.targetMasked.bytes); this.targetMasked = null; }
    this.sourceBackdrop = null; this.source = null; this.target = null; this.pairs = [];
  }
}

@Component
export struct ShellTransitionCanvas {
  @ObjectLink model: ShellTransitionCanvasModel;
  private readonly context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  build() {
    Canvas(this.context).width('100%').height('100%').onReady(() => {
      this.model.redraw = () => { if (this.model.visible) this.model.draw(this.context); };
      this.model.redraw();
    }).onDisAppear(() => { this.model.redraw = null; });
  }
}
