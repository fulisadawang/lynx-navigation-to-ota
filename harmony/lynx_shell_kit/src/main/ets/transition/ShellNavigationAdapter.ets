import ShellWindowController from '../common/ShellWindowController';
import PageBundleRuntimeRegistry from '../ota/OtaModels';
import ShellWindowPolicyFrame from './ShellWindowPolicyFrame';
import { UIContext } from '@kit.ArkUI';
import LynxPageRequest from '../model/LynxPageRequest';
import { ShellPageParams } from '../common/ShellTypes';
import { ShellNavigationDriver } from './ShellNavigationDriver';
import ShellTransitionRuntime, { TransitionSession } from './ShellTransitionRuntime';
import ShellTransitionSpec from './ShellTransitionSpec';

/** NavPathStack只承载平台节点；逻辑entries只有native onTransitionEnd成功后才提交。 */
export default class ShellNavigationAdapter implements ShellNavigationDriver {
  private readonly stack: NavPathStack; private readonly ui: UIContext;
  private readonly runtime: ShellTransitionRuntime = ShellTransitionRuntime.shared;
  private pending: TransitionSession | null = null;
  private preparing: boolean = false;
  private readonly requests: Map<string, LynxPageRequest> = new Map();
  private readonly reconcile: () => void;
  private sequence: number = 0;
  private readonly awaitingCommit: Map<string, TransitionSession> = new Map();
  private closed: boolean = false;
  private gestureProgress: number = 0;

  constructor(stack: NavPathStack, ui: UIContext, reconcile: () => void) { this.stack = stack; this.ui = ui; this.reconcile = reconcile; this.runtime.install(ui); }
  isBusy(): boolean { return this.preparing || this.pending !== null || this.runtime.isBusy(); }
  isStaged(entryID: string): boolean { const to = this.pending?.navigationCancelled ? undefined : this.pending?.to; return to !== undefined && this.requests.get(to)?.entryID === entryID; }
  contains(entryID: string): boolean { return this.stack.getAllPathName().some((name) => this.requests.get(name)?.entryID === entryID) || this.isStaged(entryID); }
  depth(): number { return this.stack.size() + 1; }
  isCurrent(entryID: string): boolean { const names = this.stack.getAllPathName(); return names.length > 0 && this.requests.get(names[names.length - 1])?.entryID === entryID; }
  currentViewID(): string { const names = this.stack.getAllPathName(); return names.length > 0 ? names[names.length - 1] : ''; }
  params(viewID: string): ShellPageParams { return this.requests.get(viewID)?.toRouterParams() ?? {}; }
  routeCommitted(viewID: string): void {
    const scene = this.awaitingCommit.get(viewID); if (scene === undefined) return;
    this.awaitingCommit.delete(viewID); this.runtime.emitTerminal(scene, true);
  }
  updateBackGesture(viewID: string, enabled: boolean): void {
    const request = this.requests.get(viewID); if (request !== undefined) request.backGestureEnabled = enabled;
    const index = this.stack.getAllPathName().indexOf(viewID);
    if (index >= 0) { const params = this.stack.getParamByIndex(index) as ShellPageParams; params.backGestureEnabled = enabled; }
  }
  markReady(id: string): void { this.runtime.markReady(id); }
  transitionState(): Object { return this.runtime.currentState(); }

  async push(request: LynxPageRequest, replace: boolean): Promise<void> {
    if (this.closed || this.isBusy()) throw new Error('navigation_busy');
    this.preparing = true;
    const from = request.sourceNativeViewID.length > 0 ? request.sourceNativeViewID : (this.runtime.viewIDForEntry(request.sourceEntryID) ?? this.currentViewID());
    const to = `${request.entryID}-native-${++this.sequence}`;
    const returnAnchor = replace ? (this.requests.get(from)?.sourceNativeViewID ?? '') : from;
    request.sourceNativeViewID = returnAnchor;
    request.nativeViewID = to; request.nativeNavigationHosted = true;
    this.requests.set(to, request);
    let scene: TransitionSession | null = null;
    try {
      const spec = request.transitionSpec();
      if (!request.animated) { spec.duration = 0; spec.reverseDuration = 0; spec.style = 'none'; }
      await ShellWindowController.applyAsync(request);
      await ShellWindowPolicyFrame.wait(this.ui, spec.readyTimeout, () => !this.closed && (this.runtime.view(from)?.isActive() ?? from.length === 0));
      PageBundleRuntimeRegistry.current()?.validateNavigationSource(request.sourceSnapshotID);
      scene = await this.runtime.begin(from, to, spec, 'push', false);
      if (this.closed) throw new Error('navigation_host_destroyed');
      request.transitionID = scene.id;
      this.pending = scene;
      const finished = this.runtime.result(scene);
      const info: NavPathInfo = { name: to, param: request.toRouterParams() };
      this.runtime.setNavigationTop(to);
      if (replace) this.stack.replacePath(info, true); else this.stack.pushPath(info, true);
      this.preparing = false;
      const result = await finished;
      if (this.closed) throw new Error('navigation_host_destroyed');
      if (!result.success) { this.requests.delete(to); throw new Error(result.reason || 'transition_cancelled'); }
      this.awaitingCommit.set(to, scene);
    } catch (error) { if (scene === null) this.runtime.view(from)?.applyWindowPolicy?.(); if (scene !== null && this.pending === scene) this.runtime.cancel('navigation_push_failed'); this.requests.delete(to); throw (error as Error); }
    finally { this.preparing = false; }
  }

  backTo(entryID: string, committed: () => void, failed?: (error: Error) => void, animated: boolean = true): void {
    if (this.closed || this.isBusy()) throw new Error('navigation_busy');
    const names = this.stack.getAllPathName();
    const to = entryID.length === 0 ? '' : (names.find((name) => this.requests.get(name)?.entryID === entryID) ?? '');
    if (to === this.currentViewID()) { committed(); return; }
    this.pop(to, false, committed, animated).catch((error: Error) => { if (failed !== undefined) failed(error); else this.runtime.reportNavigationFailure(this.currentViewID(), error); });
  }
  async beginGesture(): Promise<void> { await this.pop(this.previousViewID(), true, () => this.reconcile()); }
  updateGesture(progress: number): void { this.gestureProgress = progress; this.runtime.setProgress(progress); }
  endGesture(commit: boolean): void { this.runtime.finishGesture(commit); }
  private previousViewID(): string { const names = this.stack.getAllPathName(); return names.length > 1 ? names[names.length - 2] : ''; }
  gestureSpec(): ShellTransitionSpec | null { return this.requests.get(this.currentViewID())?.transitionSpec() ?? null; }
  private async pop(to: string, interactive: boolean, committed: () => void, animated: boolean = true): Promise<void> {
    if (this.closed || this.isBusy()) throw new Error('navigation_busy');
    const from = this.currentViewID(); if (from.length === 0) throw new Error('navigation_root');
    this.preparing = true;
    const spec = this.requests.get(from)?.transitionSpec() ?? new ShellTransitionSpec();
    if (!animated) { spec.style = 'none'; spec.duration = 0; spec.reverseDuration = 0; }
    try {
      const fromRequest = this.requests.get(from);
      const bottom = this.stack.getAllPathName()[0];
      const anchor = bottom === undefined ? '' : (this.requests.get(bottom)?.sourceNativeViewID ?? '');
      const visualTarget = to.length > 0 ? to : (this.runtime.view(anchor)?.isActive() ? anchor : '');
      const scene = await this.runtime.begin(from, visualTarget, spec, 'pop', interactive);
      if (this.closed) throw new Error('navigation_host_destroyed');
      this.pending = scene; const finished = this.runtime.result(scene);
      this.runtime.setNavigationTop(visualTarget);
      if (to.length === 0) this.stack.clear(true); else this.stack.popToName(to, true);
      this.preparing = false;
      if (interactive) this.runtime.setProgress(this.gestureProgress);
      const result = await finished;
      if (this.closed) throw new Error('navigation_host_destroyed');
      if (result.success) { committed(); this.runtime.emitTerminal(scene, true); } else throw new Error(result.reason || 'transition_cancelled');
    } finally { this.preparing = false; }
  }

  transition(from: NavContentInfo, to: NavContentInfo, operation: NavigationOperation): NavigationAnimatedTransition | undefined {
    const scene = this.pending;
    if (scene === null) return undefined;
    return {
      // 自动与手势都使用可撤销native proxy；scene.interactive只决定是否由用户驱动progress。
      isInteractive: true,
      timeout: scene.spec.readyTimeout + Math.max(scene.spec.duration, scene.spec.reverseDuration) + 1000,
      transition: (proxy: NavigationTransitionProxy) => this.runtime.attachProxy(scene, proxy),
      onTransitionEnd: (success: boolean) => {
        this.runtime.setNavigationTop(success ? scene.to : scene.from);
        this.runtime.nativeEnded(scene, success);
        if (this.pending === scene) { this.pending = null; if (success) { this.reconcile(); this.pruneRequests(); } }
      }
    };
  }
  private pruneRequests(): void {
    const live = new Set<string>(this.stack.getAllPathName());
    this.requests.forEach((request, id) => { if (!live.has(id)) this.requests.delete(id); });
  }
  destroy(): void { if (this.closed) return; this.closed = true; this.runtime.destroy(); this.pending = null; this.requests.clear(); this.awaitingCommit.clear(); }
}
