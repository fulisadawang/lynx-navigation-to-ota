import ShellPresetFrame from './ShellPresetFrame';
import PageBundleRuntimeRegistry from '../ota/OtaModels';
import { UIContext } from '@kit.ArkUI';
import { FrameCallback } from '@ohos.arkui.UIContext';
import { AnimatorResult } from '@ohos.animator';
import ShellTransitionSpec from './ShellTransitionSpec';
import ShellTransitionGeometry, { ShellTransitionView, ShellSnapshotBudget, ShellCapturedImage, ShellTransitionPresentation } from './ShellTransitionGeometry';
import { ShellTransitionCanvasModel, ShellTransitionPair } from './ShellTransitionCanvas';

export interface ShellTransitionStatus {
  transactionID: string; status: string; requestedTransition: string; effectiveTransition: string;
  direction: string; progress: number; reason: string; updatedAt: number;
}
interface PersistedPresentation { view: ShellTransitionView; base: ShellTransitionPresentation; value: ShellTransitionPresentation; opacity: number; baseOpacity: number; }
export interface ShellTransitionCommit { success: boolean; reason: string; }

class AfterRenderedFrame extends FrameCallback {
  private readonly ui: UIContext; private readonly completion: () => void; private frames: number = 0;
  constructor(ui: UIContext, completion: () => void) { super(); this.ui = ui; this.completion = completion; }
  onFrame(time: number): void { this.frames += 1; if (this.frames < 2) this.ui.postFrameCallback(this); }
  onIdle(time: number): void { if (this.frames >= 2) this.completion(); }
}

export class TransitionSession {
  readonly model: ShellTransitionCanvasModel = new ShellTransitionCanvasModel();
  id: string; from: string; to: string; spec: ShellTransitionSpec; direction: 'push' | 'pop'; interactive: boolean;
  proxy: NavigationTransitionProxy | null = null; budget: ShellSnapshotBudget = new ShellSnapshotBudget();
  beginIdentityEpoch?: number;
  rootGeometryValid: boolean = false;
  deadlineExpired: boolean = false; density: number = 1;
  failed: boolean = false; navigationCancelled: boolean = false;
  liveFallback: boolean = false; nativeDecisionRequested: boolean = false; cleaned: boolean = false; nativeEnded: boolean = false; gateClosed: boolean = false; ready: boolean = false; settling: boolean = false;
  requestedFinish: boolean | null = null; requestedProgress: number = 0; reason: string = '';
  animator: AnimatorResult | null = null; deadline: number = -1; watchdog: number = -1;
  sourceElements: Map<string, ShellCapturedImage> = new Map();
  transforms: Map<ShellTransitionView, ShellTransitionPresentation> = new Map();
  saved: Map<ShellTransitionView, number> = new Map();
  normalizedTarget: PersistedPresentation | null = null;
  eventSent: boolean = false;
  terminalPayload: Record<string, Object> | null = null;
  eventViews: ShellTransitionView[] = [];
  resolve: (result: ShellTransitionCommit) => void = () => {};
  constructor(id: string, from: string, to: string, spec: ShellTransitionSpec, direction: 'push' | 'pop', interactive: boolean) {
    this.id = id; this.from = from; this.to = to; this.spec = spec; this.direction = direction; this.interactive = interactive;
  }
}

/** 唯一原生动画所有者。PixelMap/ArkUI帧在本层，不向Lynx JS逐帧发送progress。 */
export default class ShellTransitionRuntime {
  static readonly shared: ShellTransitionRuntime = new ShellTransitionRuntime();
  private currentModel: ShellTransitionCanvasModel = new ShellTransitionCanvasModel();
  private modelListener: ((model: ShellTransitionCanvasModel) => void) | null = null;
  get model(): ShellTransitionCanvasModel { return this.currentModel; }
  setModelListener(listener: ((model: ShellTransitionCanvasModel) => void) | null): void { this.modelListener = listener; }
  private readonly persisted: Map<string, PersistedPresentation> = new Map();
  private readonly views: Map<string, ShellTransitionView> = new Map();
  private readonly waiters: Map<string, () => void> = new Map();
  private topViewID: string = '';
  private navigationStarted: boolean = false;
  private readonly terminalListeners: Set<(committed: boolean) => void> = new Set();
  private active: TransitionSession | null = null;
  private sequence: number = 0;
  private ui: UIContext | null = null;
  private status: ShellTransitionStatus = { transactionID: '', status: 'idle', requestedTransition: 'default', effectiveTransition: 'default', direction: 'push', progress: 0, reason: '', updatedAt: 0 };

  install(ui: UIContext): void { this.ui = ui; }
  isBusy(): boolean { return this.active !== null; }
  bind(view: ShellTransitionView): void {
    const former = this.views.get(view.viewID);
    if (former !== undefined && former.context !== undefined && former.context !== view.context && this.references(view.viewID)) this.cancel('context_replaced');
    const persisted = this.persisted.get(view.viewID);
    if (persisted !== undefined) {
      if (persisted.view.context !== view.context || persisted.view.loadGeneration !== view.loadGeneration) this.persisted.delete(view.viewID);
      else persisted.view = view;
    }
    this.views.set(view.viewID, view);
    if (this.navigationStarted) view.setCovered?.(view.viewID !== this.topViewID && !(this.topViewID === '' && view.rootContent === true));
    if (this.active?.to === view.viewID) { view.updateTransition?.(this.active.id); if (this.active.liveFallback && !this.active.ready) this.hide(this.active, view); }
    this.waiters.get(view.viewID)?.();
  }
  unbind(entryID: string, context?: Object): void {
    const view = this.views.get(entryID);
    if (view === undefined || (context !== undefined && view.context !== context)) return;
    if (this.references(entryID) && this.active?.nativeDecisionRequested !== true) this.cancel('context_destroyed');
    this.persisted.delete(entryID);
    this.views.delete(entryID); this.waiters.delete(entryID);
  }
  firstScreen(entryID: string): void {
    const view = this.views.get(entryID); if (view !== undefined) view.firstScreen = true;
    this.waiters.get(entryID)?.();
  }
  failure(entryID: string): void { if (this.references(entryID) && this.active !== null) { this.active.failed = true; this.cancel('target_load_failed'); } }
  layoutChanged(entryID: string): void {
    if (!this.references(entryID)) return;
    const view = this.views.get(entryID); const captured = this.active?.from === entryID ? this.active?.model.source : this.active?.model.target;
    if (view !== undefined && captured !== null && captured !== undefined) {
      const rect = ShellTransitionGeometry.holder(view);
      if (Math.abs(rect.left - captured.rect.left) > 0.5 || Math.abs(rect.top - captured.rect.top) > 0.5 || Math.abs(rect.width - captured.rect.width) > 0.5 || Math.abs(rect.height - captured.rect.height) > 0.5) this.cancel('window_geometry_changed');
    }
  }
  hostLayoutChanged(width: number, height: number, left: number, top: number): void {
    if (this.active !== null && (Math.abs(width - this.model.origin.width) > 0.5 || Math.abs(height - this.model.origin.height) > 0.5 || Math.abs(left - this.model.origin.left) > 0.5 || Math.abs(top - this.model.origin.top) > 0.5)) this.cancel('window_geometry_changed');
  }
  currentState(): ShellTransitionStatus {
    return { transactionID: this.status.transactionID, status: this.status.status, requestedTransition: this.status.requestedTransition,
      effectiveTransition: this.status.effectiveTransition, direction: this.status.direction, progress: this.status.progress,
      reason: this.status.reason, updatedAt: this.status.updatedAt };
  }
  markReady(id: string): void {
    if (this.active?.id !== id) throw new Error('transition_not_found');
    this.waiters.get(this.active.to)?.();
  }
  setNavigationTop(id: string): void { this.navigationStarted = true; this.topViewID = id; this.views.forEach((view) => view.setCovered?.(view.viewID !== id && !(id === '' && view.rootContent === true))); }
  afterTerminal(listener: (committed: boolean) => void): () => void { this.terminalListeners.add(listener); return () => this.terminalListeners.delete(listener); }
  reportNavigationFailure(id: string, error: Error): void {
    const view = this.views.get(id);
    if (view?.context !== undefined && view.isActive()) view.context.sendGlobalEvent('onTransitionSettled', [{ transactionID: '', status: 'failed', reason: error.message, failed: true, completed: false, cancelled: false, direction: 'pop', frameDriver: 'native' }]);
  }
  view(entryID: string): ShellTransitionView | undefined { return this.views.get(entryID); }
  viewIDForEntry(entryID: string): string | undefined {
    let id: string | undefined; this.views.forEach((view, key) => { if (view.entryID === entryID && view.isActive()) id = key; }); return id;
  }
  viewIDForContext(context: Object): string { let id = ''; this.views.forEach((view, key) => { if (view.context === context) id = key; }); return id; }

  async begin(from: string, to: string, spec: ShellTransitionSpec, direction: 'push' | 'pop', interactive: boolean): Promise<TransitionSession> {
    const ui = this.ui;
    if (this.active !== null || ui === null) throw new Error('navigation_busy_or_host_unavailable');
    const scene = new TransitionSession(`lynx-transition-${Date.now()}-${++this.sequence}`, from, to, spec, direction, interactive);
    scene.density = ui.vp2px(1); scene.beginIdentityEpoch = PageBundleRuntimeRegistry.current()?.userIdentityEpoch;
    this.active = scene; this.currentModel = scene.model; this.modelListener?.(scene.model);
    scene.model.spec = spec; scene.model.direction = direction; scene.model.progress = 0;
    scene.model.effective = spec.effectiveStyle();
    scene.model.budget = scene.budget;
    this.updateStatus(scene, 'preparing');
    try {
      const root = ui.getComponentUtils().getRectangleById('lynx-navigation-overlay-root');
      scene.model.origin = { left: ui.px2vp(root.windowOffset.x), top: ui.px2vp(root.windowOffset.y), width: ui.px2vp(root.size.width), height: ui.px2vp(root.size.height) };
      ShellTransitionGeometry.validate(scene.model.origin); scene.rootGeometryValid = true;
      const source = this.views.get(from);
      const targetView = this.views.get(to); targetView?.updateTransition?.(scene.id);
      const sourceConfig = source?.presentationSpec;
      const targetConfig = direction === 'push' ? spec.presentation : targetView?.presentationSpec;
      scene.model.secondaryLinked = direction === 'push' ? spec.presentation.canTransitionTo : spec.presentation.canTransitionFrom;
      if (sourceConfig?.allowExitRouteSnapshotting === false || targetConfig?.allowEnterRouteSnapshotting === false) { scene.liveFallback = true; scene.reason = 'route_snapshotting_disabled'; }
      this.updateStatus(scene, 'preparing');
      if (scene.liveFallback) { this.normalizePopTarget(scene); return scene; }
      if (source === undefined) {
        if (spec.style === 'sharedElement' || spec.style === 'openContainer') throw new Error('source_context_unavailable');
      } else {
        scene.model.sourceColor = ShellTransitionGeometry.nativeBackdropColor(source.backgroundColor);
        scene.model.source = await this.captureBody(scene, source);
        if (direction === 'pop' && this.persisted.has(to) && source.presentationSpec?.opaque === false) {
          // 部分页只盖住小矩形；临时完整viewport快照先遮住真实underlay归一，纳入同64MiB预算。
          scene.model.sourceBackdrop = await scene.budget.capture(scene.model.origin, ui, (scale) => ui.getComponentSnapshot().get('lynx-navigation-overlay-root', { scale: scale, waitUntilRenderFinished: true }), () => this.active === scene && source.isActive());
        }
        if (spec.style === 'sharedElement') {
          for (const item of spec.sharedElements) {
            if (interactive && !item.transitionOnGesture) continue;
            const id = direction === 'push' ? item.sourceSelector : item.targetSelector;
            scene.sourceElements.set(item.key, await this.captureElement(scene, source, id));
          }
        } else if (spec.style === 'openContainer' && spec.openContainer !== undefined && direction === 'push') {
          scene.sourceElements.set('open-card', await this.captureElement(scene, source, spec.openContainer.sourceSelector));
        }
      }
      if (this.active !== scene) throw new Error('transition_cancelled');
      await this.showOverlay(scene);
      this.normalizePopTarget(scene);
      return scene;
    } catch (error) {
      const sourceAlive = this.views.get(scene.from)?.isActive() === true;
      if (this.active === scene && scene.rootGeometryValid && sourceAlive && scene.model.source === null) {
        // Native视频/受保护Surface/预算失败仍能由真实活体容器完成有理由fallback；不伪造截图。
        scene.liveFallback = true; this.degrade(scene, (error as Error).message || 'source_snapshot_unavailable');
        this.normalizePopTarget(scene); return scene;
      }
      if (this.active === scene && sourceAlive && scene.model.source !== null && (error as Error).message !== 'overlay_frame_unavailable') {
        this.degrade(scene, (error as Error).message);
        try { await this.showOverlay(scene); this.normalizePopTarget(scene); return scene; } catch (overlayError) { this.cleanup(scene); throw (overlayError as Error); }
      }
      this.cleanup(scene); throw (error as Error);
    }
  }

  private showOverlay(scene: TransitionSession): Promise<void> {
    const ui = this.ui;
    if (ui === null) return Promise.reject(new Error('navigation_host_destroyed'));
    scene.model.visible = true; scene.model.redraw?.();
    return new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('overlay_frame_unavailable')), scene.spec.readyTimeout);
      ui.postFrameCallback(new AfterRenderedFrame(ui, () => {
        clearTimeout(timeout);
        if (this.active !== scene || scene.model.redraw === null) reject(new Error('overlay_frame_unavailable'));
        else { scene.model.redraw?.(); resolve(); }
      }));
    });
  }

  attachProxy(scene: TransitionSession, proxy: NavigationTransitionProxy): void {
    if (this.active !== scene) { proxy.cancelTransition?.(); return; }
    scene.proxy = proxy;
    scene.watchdog = setTimeout(() => { if (this.active === scene && !scene.nativeDecisionRequested) this.cancel('native_frame_deadline'); }, scene.spec.readyTimeout + Math.max(scene.spec.duration, scene.spec.reverseDuration) + 500);
    scene.deadline = setTimeout(() => {
      if (this.active === scene && !scene.ready) { scene.deadlineExpired = true; this.degrade(scene, 'target_not_ready'); this.prepareTarget(scene, false); }
    }, scene.spec.readyTimeout);
    this.waiters.set(scene.to, () => this.prepareTarget(scene, true));
    this.prepareTarget(scene, true);
  }

  result(scene: TransitionSession): Promise<ShellTransitionCommit> {
    return new Promise((resolve) => { scene.resolve = resolve; });
  }

  private async prepareTarget(scene: TransitionSession, requireFirstScreen: boolean): Promise<void> {
    if (this.active !== scene || scene.ready || scene.gateClosed) return;
    const target = this.views.get(scene.to);
    if (target === undefined && scene.deadlineExpired) { this.cancel('target_context_unavailable'); return; }
    if (target === undefined || (requireFirstScreen && !target.firstScreen)) return;
    scene.gateClosed = true;
    const attemptImages: ShellCapturedImage[] = [];
    try {
      if (!target.isActive()) throw new Error('target_context_destroyed');
      const source = this.views.get(scene.from);
      target.updateTransition?.(scene.id);
      scene.model.targetColor = ShellTransitionGeometry.nativeBackdropColor(target.backgroundColor);
      if (scene.liveFallback) throw new Error(scene.reason || 'route_snapshotting_disabled');
      if (scene.model.target !== null && !scene.model.target.released) await scene.budget.release(scene.model.target);
      scene.model.target = await this.captureBody(scene, target);
      const pairs: ShellTransitionPair[] = [];
      if (source !== undefined && scene.model.effective === 'sharedElement') {
        for (const item of scene.spec.sharedElements) {
          if (scene.interactive && !item.transitionOnGesture) continue;
          const sourceId = scene.direction === 'push' ? item.sourceSelector : item.targetSelector;
          const targetId = scene.direction === 'push' ? item.targetSelector : item.sourceSelector;
          const from = scene.sourceElements.get(item.key);
          if (from === undefined) throw new Error('source_snapshot_unavailable');
          const to = await this.captureElement(scene, target, targetId);
          attemptImages.push(to);
          pairs.push({ from: from, to: to, tween: item.rectTweenType, shuttle: scene.direction === 'push' ? item.shuttleOnPush : item.shuttleOnPop,
            fromStyle: scene.direction === 'push' ? item.sourceStyle : item.targetStyle, toStyle: scene.direction === 'push' ? item.targetStyle : item.sourceStyle });
        }
        if (pairs.length === 0) throw new Error('shared_elements_gesture_disabled');
      } else if (source !== undefined && scene.model.effective === 'openContainer' && scene.spec.openContainer !== undefined) {
        const cardView = scene.direction === 'push' ? source : target;
        const card = scene.direction === 'push' ? scene.sourceElements.get('open-card') : await this.captureElement(scene, cardView, scene.spec.openContainer.sourceSelector);
        if (card === undefined) throw new Error('source_snapshot_unavailable');
        if (scene.direction === 'pop') attemptImages.push(card);
        const expanded = scene.direction === 'push' ? scene.model.target : scene.model.source;
        if (expanded === null) throw new Error('target_snapshot_unavailable');
        pairs.push({ from: scene.direction === 'push' ? card : expanded, to: scene.direction === 'push' ? expanded : card, tween: 'materialRectArc', shuttle: 'to' });
      }
      if (this.active !== scene || !target.isActive() || (source !== undefined && !source.isActive())) throw new Error('transition_owner_destroyed');
      scene.model.pairs = pairs;
      await scene.model.prepareBodies();
      scene.model.prepared = true;
      if (scene.model.sourceBackdrop !== null) { const backdrop = scene.model.sourceBackdrop; scene.model.sourceBackdrop = null; await scene.budget.release(backdrop); }
      if (source !== undefined) this.hide(scene, source);
      this.hide(scene, target);
      scene.ready = true; this.waiters.delete(scene.to); if (scene.deadline >= 0) clearTimeout(scene.deadline);
      scene.model.redraw?.(); this.updateStatus(scene, scene.interactive ? 'interactive' : 'running');
      if (!scene.interactive) this.settle(scene, true);
      else { this.setProgress(scene.requestedProgress); if (scene.requestedFinish !== null) this.settle(scene, scene.requestedFinish); }
    } catch (error) {
      for (const image of attemptImages) await scene.budget.release(image);
      if (this.active !== scene) return;
      const reason = (error as Error).message;
      if (!target.isActive()) { this.cancel('target_context_destroyed'); return; }
      if (!scene.deadlineExpired && (reason.startsWith('selector_') || reason.startsWith('target_snapshot'))) {
        scene.gateClosed = false;
        if (this.ui !== null) this.ui.postFrameCallback(new AfterRenderedFrame(this.ui, () => this.prepareTarget(scene, true)));
        return;
      }
      if (!scene.liveFallback) this.degrade(scene, reason);
      // 快照/预算失败走真实活体容器fade，不再拿已释放或残缺掩膜伪造共享元素。
      scene.liveFallback = true; scene.model.visible = false;
      const source = this.views.get(scene.from); if (source !== undefined) this.hide(scene, source);
      this.hide(scene, target); scene.ready = true;
      this.setProgress(scene.requestedProgress);
      if (!scene.interactive) this.settle(scene, true);
      else if (scene.requestedFinish !== null) this.settle(scene, scene.requestedFinish);
    }
  }

  setProgress(value: number): void {
    const scene = this.active; if (scene === null) return;
    if (this.ui === null || Math.abs(this.ui.vp2px(1) - scene.density) > 0.001) { this.cancel('window_density_changed'); return; }
    scene.requestedProgress = Math.max(0, Math.min(1, value));
    if (!scene.ready) return;
    const source = this.views.get(scene.from); const target = this.views.get(scene.to);
    const epoch = PageBundleRuntimeRegistry.current()?.userIdentityEpoch;
    if (scene.beginIdentityEpoch !== epoch) { this.cancel('identity_changed'); return; }
    if ((source !== undefined && !source.isActive()) || (target !== undefined && !target.isActive())) { this.cancel('transition_owner_destroyed'); return; }
    scene.model.progress = scene.requestedProgress;
    if (scene.liveFallback) {
      const p = scene.requestedProgress;
      const direct = scene.model.effective === 'none';
      if (scene.model.usePreset && scene.spec.style === 'default' && scene.spec.presentation.routeType !== undefined) {
        const push = scene.direction === 'push'; const primary = push ? target : source; const secondary = push ? source : target;
        const rect = primary === undefined ? scene.model.origin : ShellTransitionGeometry.holder(primary);
        const frame = ShellPresetFrame.at(scene.spec.presentation, push ? p : 1 - p, scene.model.origin.width, scene.model.origin.height, rect.height, scene.model.secondaryLinked);
        if (primary !== undefined) { const saved = scene.transforms.get(primary) ?? primary.getPresentation(); primary.setPresentation({ x: saved.x + frame.primary.x, y: saved.y + frame.primary.y, scale: saved.scale * frame.primary.scale }); primary.setOpacity((scene.saved.get(primary) ?? primary.getOpacity()) * frame.primary.alpha); }
        if (secondary !== undefined) { const saved = this.persisted.get(secondary.viewID)?.base ?? scene.transforms.get(secondary) ?? secondary.getPresentation(); secondary.setPresentation({ x: saved.x + frame.secondary.x, y: saved.y + frame.secondary.y, scale: saved.scale * frame.secondary.scale }); secondary.setOpacity((this.persisted.get(secondary.viewID)?.baseOpacity ?? scene.saved.get(secondary) ?? secondary.getOpacity()) * frame.secondary.alpha); }
      } else {
      const push = scene.direction === 'push'; const primary = push ? target : source; const secondary = push ? source : target;
      const shown = push ? p : 1 - p; const slide = scene.model.effective === 'slide'; const upward = scene.model.effective === 'slideUp'; const zoom = scene.model.effective === 'zoom';
      if (primary !== undefined) {
        const saved = scene.transforms.get(primary) ?? primary.getPresentation();
        primary.setOpacity((scene.saved.get(primary) ?? primary.getOpacity()) * (direct || slide || upward ? 1 : shown));
        primary.setPresentation({ x: saved.x + (slide ? scene.model.origin.width * (1 - shown) : 0), y: saved.y + (upward ? scene.model.origin.height * (1 - shown) : 0), scale: saved.scale * (zoom ? 0.92 + 0.08 * shown : 1) });
      }
      if (secondary !== undefined) {
        const persisted = this.persisted.get(secondary.viewID);
        const saved = persisted?.base ?? scene.transforms.get(secondary) ?? secondary.getPresentation();
        if (!push && persisted !== undefined) {
          secondary.setOpacity(persisted.opacity + (persisted.baseOpacity - persisted.opacity) * p);
          secondary.setPresentation({ x: persisted.value.x + (persisted.base.x - persisted.value.x) * p, y: persisted.value.y + (persisted.base.y - persisted.value.y) * p, scale: persisted.value.scale + (persisted.base.scale - persisted.value.scale) * p });
        } else {
          secondary.setOpacity((persisted?.baseOpacity ?? scene.saved.get(secondary) ?? secondary.getOpacity()) * (direct && push ? 0 : 1));
          secondary.setPresentation({ x: saved.x - (slide && scene.model.secondaryLinked ? scene.model.origin.width * shown * 0.25 : 0), y: saved.y, scale: saved.scale });
        }
      }
      }
    } else { scene.model.redraw?.(); }
    scene.proxy?.updateTransition?.(scene.requestedProgress);
    this.status.progress = scene.requestedProgress; this.status.updatedAt = Date.now();
  }
  finishGesture(commit: boolean): void {
    const scene = this.active; if (scene === null) return;
    scene.requestedFinish = commit;
    if (scene.ready) this.settle(scene, commit);
    else if (!commit) this.cancel('gesture_cancelled');
  }
  cancel(reason: string): void {
    const scene = this.active; if (scene === null) return;
    scene.navigationCancelled = true;
    scene.reason = reason; scene.animator?.cancel(); scene.animator = null;
    if (scene.proxy !== null) scene.proxy.cancelTransition?.();
    else { scene.resolve({ success: false, reason: reason }); this.cleanup(scene); }
  }
  nativeEnded(scene: TransitionSession, success: boolean): void {
    if (scene.nativeEnded) return; scene.nativeEnded = true;
    const terminal = success ? (scene.reason.length > 0 ? 'degraded' : 'completed') : scene.failed ? 'failed' : 'cancelled';
    if (this.active === scene) this.updateStatus(scene, terminal);
    const payload: Record<string, Object> = { transactionID: scene.id, status: terminal,
      requestedTransition: scene.spec.style, effectiveTransition: scene.model.effective, direction: scene.direction, progress: success ? 1 : 0,
      reason: scene.reason, updatedAt: Date.now(), completed: success, cancelled: !success && !scene.failed, degraded: success && scene.reason.length > 0, failed: !success && scene.failed,
      frameDriver: 'native', workletReason: 'module_only_native_tween_no_js_frame_bridge' };
    scene.terminalPayload = payload;
    const from = this.views.get(scene.from); const to = this.views.get(scene.to);
    if (from !== undefined) scene.eventViews.push(from);
    if (to !== undefined) scene.eventViews.push(to);
    scene.resolve({ success: success, reason: scene.reason }); this.cleanup(scene);
    if (!success && scene.normalizedTarget !== null && scene.normalizedTarget.view.isActive()) {
      scene.normalizedTarget.view.setPresentation(scene.normalizedTarget.value); scene.normalizedTarget.view.setOpacity(scene.normalizedTarget.opacity);
    } else if (success && scene.direction === 'pop') {
      const former = scene.normalizedTarget ?? this.persisted.get(scene.to);
      if (former !== undefined && former !== null && former.view.isActive()) { former.view.setPresentation(former.base); former.view.setOpacity(former.baseOpacity); }
      this.persisted.delete(scene.to);
    }
    else if (success && scene.direction === 'push' && scene.model.usePreset && scene.spec.style === 'default' && scene.spec.presentation.routeType !== undefined && from !== undefined && from.isActive()) {
      const base = from.getPresentation(); const baseOpacity = from.getOpacity();
      const frame = ShellPresetFrame.at(scene.spec.presentation, 1, scene.model.origin.width, scene.model.origin.height, scene.model.origin.height, scene.model.secondaryLinked).secondary;
      const value: ShellTransitionPresentation = { x: base.x + frame.x, y: base.y + frame.y, scale: base.scale * frame.scale };
      const saved: PersistedPresentation = { view: from, base: base, value: value, opacity: baseOpacity * frame.alpha, baseOpacity: baseOpacity };
      this.persisted.set(scene.from, saved); from.setPresentation(value); from.setOpacity(saved.opacity);
    }
    const current = success ? to : from; current?.applyWindowPolicy?.();
    if (!success) this.emitTerminal(scene, false);
  }
  emitTerminal(scene: TransitionSession, committed: boolean): void {
    if (scene.eventSent || scene.terminalPayload === null) return;
    scene.eventSent = true;
    const emitted = new Set<Object>();
    scene.eventViews.forEach((view) => {
      const context = view.context;
      if (context === undefined || !view.isActive() || emitted.has(context)) return;
      emitted.add(context);
      context.sendGlobalEvent('onTransitionSettled', [scene.terminalPayload!]);
      if (committed) { context.sendGlobalEvent('onRouteDone', [scene.terminalPayload!]); context.sendGlobalEvent('lynxRouteDone', [scene.terminalPayload!]); }
    });
    scene.eventViews = [];
  }

  destroy(): void {
    const scene = this.active;
    this.cancel('host_destroyed');
    if (scene !== null) this.nativeEnded(scene, false);
    this.persisted.forEach((saved) => { if (saved.view.isActive()) { saved.view.setPresentation(saved.base); saved.view.setOpacity(saved.baseOpacity); } }); this.persisted.clear();
    this.views.clear(); this.waiters.clear(); this.ui = null; this.navigationStarted = false; this.topViewID = ''; this.terminalListeners.clear();
  }

  private normalizePopTarget(scene: TransitionSession): void {
    if (scene.direction !== 'pop') return;
    const saved = this.persisted.get(scene.to);
    if (saved !== undefined && saved.view.isActive()) {
      scene.normalizedTarget = saved;
      if (!scene.liveFallback && (scene.model.sourceBackdrop !== null || scene.model.source !== null && Math.abs(scene.model.source.rect.left - scene.model.origin.left) < 0.5 && Math.abs(scene.model.source.rect.top - scene.model.origin.top) < 0.5 && Math.abs(scene.model.source.rect.width - scene.model.origin.width) < 0.5 && Math.abs(scene.model.source.rect.height - scene.model.origin.height) < 0.5)) { saved.view.setPresentation(saved.base); saved.view.setOpacity(saved.baseOpacity); }
    }
  }
  private settle(scene: TransitionSession, commit: boolean): void {
    if (scene.settling || this.active !== scene || this.ui === null) return;
    scene.settling = true; scene.navigationCancelled = !commit;
    const begin = scene.model.progress; const end = commit ? 1 : 0;
    const clock = this.ui.createAnimator({ duration: Math.round((scene.direction === 'pop' ? scene.spec.reverseDuration : scene.spec.duration) * Math.abs(end - begin)), easing: 'linear', delay: 0,
      fill: 'forwards', iterations: 1, playMode: 'normal', begin: begin, end: end });
    scene.animator = clock;
    clock.onFrame = (value: number) => { if (this.active === scene) this.setProgress(value); };
    clock.onFinish = () => {
      if (this.active !== scene || this.ui === null) return;
      this.setProgress(end);
      this.ui.postFrameCallback(new AfterRenderedFrame(this.ui, () => {
        if (this.active !== scene) return;
        scene.nativeDecisionRequested = true;
        if (commit) scene.proxy?.finishTransition(); else scene.proxy?.cancelTransition?.();
      }));
    };
    clock.play();
  }
  private captureBody(scene: TransitionSession, view: ShellTransitionView): Promise<ShellCapturedImage> {
    const rect = ShellTransitionGeometry.holder(view);
    return scene.budget.capture(rect, view.ui, (scale) => view.ui.getComponentSnapshot().get(view.holderID, { scale: scale, waitUntilRenderFinished: true }), () => this.active === scene && view.isActive());
  }
  private captureElement(scene: TransitionSession, view: ShellTransitionView, id: string): Promise<ShellCapturedImage> {
    const rect = ShellTransitionGeometry.element(view, id);
    return scene.budget.capture(rect, view.ui, (scale) => view.context!.getComponentSnapshot(id, { scale: scale, waitUntilRenderFinished: true }), () => this.active === scene && view.isActive());
  }
  private hide(scene: TransitionSession, view: ShellTransitionView): void {
    if (!scene.saved.has(view)) scene.saved.set(view, view.getOpacity());
    if (!scene.transforms.has(view)) scene.transforms.set(view, view.getPresentation());
    view.setOpacity(0);
  }
  private degrade(scene: TransitionSession, reason: string): void {
    scene.reason = reason; scene.model.usePreset = false; scene.model.effective = scene.spec.fallback; this.updateStatus(scene, 'degraded');
  }
  private cleanup(scene: TransitionSession): void {
    if (scene.cleaned) return; scene.cleaned = true;
    if (scene.deadline >= 0) clearTimeout(scene.deadline);
    if (scene.watchdog >= 0) clearTimeout(scene.watchdog);
    if (this.active === scene) this.waiters.delete(scene.to);
    scene.saved.forEach((opacity, view) => { if (view.isActive()) view.setOpacity(opacity); }); scene.saved.clear();
    scene.transforms.forEach((value, view) => { if (view.isActive()) view.setPresentation(value); }); scene.transforms.clear();
    scene.model.close();
    if (scene.terminalPayload?.['completed'] !== true && scene.normalizedTarget !== null && scene.normalizedTarget.view.isActive()) {
      scene.normalizedTarget.view.setPresentation(scene.normalizedTarget.value); scene.normalizedTarget.view.setOpacity(scene.normalizedTarget.opacity);
    }
    if (this.active === scene) { this.active = null; this.terminalListeners.forEach((listener) => listener(scene.terminalPayload?.['completed'] === true)); this.terminalListeners.clear(); }
    scene.budget.close();
  }
  private references(entryID: string): boolean { return this.active !== null && (this.active.from === entryID || this.active.to === entryID); }
  private updateStatus(scene: TransitionSession, state: string): void {
    this.status = { transactionID: scene.id, status: state, requestedTransition: scene.spec.style, effectiveTransition: scene.model.effective,
      direction: scene.direction, progress: scene.model.progress, reason: scene.reason, updatedAt: Date.now() };
  }
}
