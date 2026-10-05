import ShellTransitionColor from './ShellTransitionColor';
import ShellWindowController from '../common/ShellWindowController';
import LynxPageRequest from '../model/LynxPageRequest';
import ShellTransitionSpec from './ShellTransitionSpec';
import ShellRoutePresentationSpec from './ShellRoutePresentationSpec';
import HostNativeModules from '../common/HostNativeModules';
import { LynxContainer } from '../pages/LynxContainer';
import LynxNavigator from '../routing/LynxNavigator';
import ShellMessageHub from '../common/ShellMessageHub';
import { ShellPageParams } from '../common/ShellTypes';
import ShellNavigationAdapter from './ShellNavigationAdapter';
import ShellTransitionRuntime from './ShellTransitionRuntime';
import { ShellTransitionCanvas, ShellTransitionCanvasModel } from './ShellTransitionCanvas';

@Component
struct ShellNavigationDestination {
  params: ShellPageParams = {};
  @State private shown: boolean = false;
  @State private keepContent: boolean = true;
  @State private heightVh: number = 100;
  private gestureSpec: ShellTransitionSpec = new ShellTransitionSpec();
  private spec: ShellRoutePresentationSpec = new ShellRoutePresentationSpec();
  private viewportHeight: number = 1;
  private dragStart: number = 0;
  private alive: boolean = true;
  private removeTerminal: (() => void) | null = null;
  aboutToAppear(): void {
    const request = LynxPageRequest.fromRouterParams(this.params); this.spec = request.presentationSpec(); this.gestureSpec = request.transitionSpec();
    this.heightVh = this.spec.mode === 'bottomSheet' ? this.spec.heightVh : ['cupertinoModal', 'cupertinoModalInside'].includes(this.spec.mode) ? 92 : this.spec.mode === 'modalNavigation' ? 86 : this.spec.mode === 'modal' ? 56 : 100;
  }
  aboutToBeDeleted(): void { this.alive = false; this.removeTerminal?.(); this.removeTerminal = null; }
  private hide(): void {
    this.shown = false;
    if (this.spec.maintainState) return;
    // interactive隐藏不能删除Context，等唯一native终态后再按maintainState释放。
    const release = (committed: boolean) => { this.removeTerminal = null; if (committed && this.alive && !this.shown) this.keepContent = false; };
    if (ShellTransitionRuntime.shared.isBusy()) this.removeTerminal = ShellTransitionRuntime.shared.afterTerminal(release); else release(true);
  }
  private dismiss(): void {
    if (ShellTransitionRuntime.shared.isBusy() || !this.shown) return;
    LynxNavigator.closeResult();
  }
  private judgeSheet(event: GestureEvent): boolean {
    if (this.spec.mode !== 'bottomSheet' || !this.gestureSpec.popGesture.enabled || this.gestureSpec.popGesture.direction === 'horizontal' || ShellTransitionRuntime.shared.isBusy() || !this.shown || !ShellMessageHub.backGestureEnabled(this.params.entryID ?? '')) return false;
    if (Math.abs(event.offsetY) < Math.abs(event.offsetX) * 1.2) return false;
    const point = event.fingerList[0]; const view = ShellTransitionRuntime.shared.view(this.params.nativeViewID ?? '');
    if (point === undefined || view === undefined) return false;
    if (!this.gestureSpec.popGesture.fullScreen && point.localY - event.offsetY > this.gestureSpec.popGesture.edgeWidth) return false;
    return !view.context?.canConsumeTouchEvent(view.ui.vp2px(point.localX - event.offsetX), view.ui.vp2px(point.localY - event.offsetY));
  }
  build() {
    NavDestination() {
      Stack({ alignContent: this.spec.mode === 'modal' || this.spec.mode === 'modalNavigation' ? Alignment.Center : Alignment.Bottom }) {
        if (this.spec.mode !== 'heroSheet' && !this.spec.opaque) {
          Column().width('100%').height('100%').backgroundColor(ShellTransitionColor.mix(this.spec.barrierColor, this.spec.barrierColor, 0))
            .accessibilityText(this.spec.barrierLabel ?? '').onClick(() => { if (this.spec.barrierDismissible) this.dismiss(); });
        }
        Column() {
          if (this.keepContent) { LynxContainer({ nativeParams: this.params, nativeShown: this.shown }); }
        }.width(this.spec.mode === 'modal' ? '86%' : this.spec.mode === 'modalNavigation' ? '92%' : ['cupertinoModal', 'cupertinoModalInside'].includes(this.spec.mode) ? '96%' : '100%').height(`${this.heightVh}%`).backgroundColor(this.spec.opaque ? this.params.backgroundColor ?? '#FFFFFF' : Color.Transparent)
          .borderRadius(this.spec.mode === 'bottomSheet' ? this.spec.round ? { topLeft: 16, topRight: 16 } : 0 : ['cupertinoModal', 'cupertinoModalInside'].includes(this.spec.mode) ? 26 : this.spec.mode === 'modalNavigation' ? 24 : this.spec.mode === 'modal' ? 20 : 0).clip(true)
          .onGestureJudgeBegin((info: GestureInfo, event: BaseGestureEvent) => info.tag === 'lynx-native-sheet-drag' && !this.judgeSheet(event as GestureEvent) ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
          .priorityGesture(PanGesture({ direction: PanDirection.Vertical, distance: 12 }).tag('lynx-native-sheet-drag')
            .onActionStart(() => { this.dragStart = this.heightVh; })
            .onActionUpdate((event: GestureEvent) => { this.heightVh = Math.max(this.spec.detentsVh[0] * 0.55, Math.min(100, this.dragStart - event.offsetY / this.viewportHeight * 100)); })
            .onActionEnd((event: GestureEvent) => {
              if (this.heightVh < this.spec.detentsVh[0] * 0.75 && event.offsetY > 0) { this.heightVh = this.spec.detentsVh[0]; this.dismiss(); return; }
              let selected = this.spec.detentsVh[0]; this.spec.detentsVh.forEach((value: number) => { if (Math.abs(value - this.heightVh) < Math.abs(selected - this.heightVh)) selected = value; });
              this.heightVh = selected;
            }).onActionCancel(() => { this.heightVh = this.dragStart; }));
      }.width('100%').height('100%').onAreaChange((previous: Area, area: Area) => { this.viewportHeight = Number(area.height); })
    }.mode(this.spec.opaque ? NavDestinationMode.STANDARD : NavDestinationMode.DIALOG).backgroundColor(Color.Transparent)
      .hideTitleBar(true).onWillShow(() => { this.removeTerminal?.(); this.removeTerminal = null; this.keepContent = true; }).onWillHide(() => { this.shown = false; }).onShown(() => { this.removeTerminal?.(); this.removeTerminal = null; this.keepContent = true; this.shown = true; }).onHidden(() => this.hide())
      .onBackPressed(() => {
        if (ShellTransitionRuntime.shared.isBusy()) { ShellTransitionRuntime.shared.cancel('system_back'); return true; }
        const view = ShellTransitionRuntime.shared.view(this.params.nativeViewID ?? this.params.entryID ?? '');
        if (!ShellMessageHub.backGestureEnabled(this.params.entryID ?? '')) return true;
        if (view?.context !== undefined && HostNativeModules.dispatchBackPress(view.context)) return true;
        LynxNavigator.closeResult(); return true;
      });
  }
}

/** 业务首页保持原内容；Navigation只负责原生栈/可取消转场，标题与导航仍由Lynx自绘。 */
@Component
export struct ShellNavigationHost {
  @BuilderParam home: (visible: boolean) => void;
  @State private homeVisible: boolean = true;
  private readonly stack: NavPathStack = new NavPathStack();
  @State private homeOpacity: number = 1;
  @State private homeX: number = 0;
  @State private homeY: number = 0;
  @State private homeScale: number = 1;
  @State private canvas: ShellTransitionCanvasModel = ShellTransitionRuntime.shared.model;
  private adapter: ShellNavigationAdapter | null = null;
  private attached: boolean = false;
  private alive: boolean = true;
  private gestureAccepted: boolean = false;
  private gestureProgress: number = 0;
  private gestureAxis: 'horizontal' | 'vertical' = 'horizontal';

  aboutToAppear(): void {
    LynxNavigator.expectNavigationHost();
    ShellTransitionRuntime.shared.setModelListener((model: ShellTransitionCanvasModel) => { if (this.alive) this.canvas = model; });
    this.adapter = new ShellNavigationAdapter(this.stack, this.getUIContext(), () => LynxNavigator.reconcileWithDriver());
    ShellMessageHub.setNavigationBusyReader(() => this.adapter?.isBusy() ?? false);
  }
  aboutToBeDeleted(): void {
    this.alive = false;
    ShellTransitionRuntime.shared.setModelListener(null);
    ShellMessageHub.setNavigationBusyReader(null);
    LynxNavigator.installNavigationDriver(null);
    this.adapter?.destroy(); this.adapter = null;
  }
  @Builder private destination(name: string, param: Object) { ShellNavigationDestination({ params: param as ShellPageParams }); }
  private acceptGesture(event: GestureEvent): boolean {
    const spec = this.adapter?.gestureSpec();
    if (spec?.presentation.mode === 'bottomSheet' && spec.popGesture.direction === 'vertical') return false;
    if (spec === null || spec === undefined || !spec.popGesture.enabled || this.adapter?.isBusy()) return false;
    const view = ShellTransitionRuntime.shared.view(this.adapter.currentViewID());
    if (view === undefined || !view.isActive() || !ShellMessageHub.backGestureEnabled(view.entryID)) return false;
    const point = event.fingerList[0]; if (point === undefined) return false;
    this.gestureAxis = spec.popGesture.direction === 'vertical' ? 'vertical' : spec.popGesture.direction === 'multi' && Math.abs(event.offsetY) > Math.abs(event.offsetX) ? 'vertical' : 'horizontal';
    if (this.gestureAxis === 'horizontal' ? event.offsetX <= 0 || Math.abs(event.offsetX) < Math.abs(event.offsetY) * 1.2 : event.offsetY <= 0 || Math.abs(event.offsetY) < Math.abs(event.offsetX) * 1.2) return false;
    const startX = point.localX - event.offsetX; const startY = point.localY - event.offsetY;
    const edge = (this.gestureAxis === 'horizontal' ? startX : startY) <= spec.popGesture.edgeWidth;
    if (spec.popGesture.fullScreen && !edge && view.context?.canConsumeTouchEvent(view.ui.vp2px(startX), view.ui.vp2px(startY))) return false;
    return spec.popGesture.fullScreen || (this.gestureAxis === 'horizontal' ? point.localX - event.offsetX : point.localY - event.offsetY) <= spec.popGesture.edgeWidth;
  }
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Navigation(this.stack) { Column() { this.home(this.homeVisible); }.id('lynx-navigation-home').opacity(this.homeOpacity).translate({ x: this.homeX, y: this.homeY }).scale({ x: this.homeScale, y: this.homeScale }).width('100%').height('100%'); }
        .hideTitleBar(true).hideToolBar(true).mode(NavigationMode.Stack).navDestination(this.destination)
        .onNavBarStateChange((visible: boolean) => { this.homeVisible = visible && this.stack.size() === 0; })
        .customNavContentTransition((from: NavContentInfo, to: NavContentInfo, operation: NavigationOperation) => this.adapter?.transition(from, to, operation))
      if (this.canvas.visible) { ShellTransitionCanvas({ model: this.canvas }); }
    }.id('lynx-navigation-overlay-root').width('100%').height('100%')
      .onAreaChange((oldArea: Area, area: Area) => {
        const width = Number(area.width); const height = Number(area.height);
        if (width <= 0 || height <= 0) return;
        if (!this.attached && this.adapter !== null) {
          this.attached = true;
          ShellTransitionRuntime.shared.bind({ entryID: 'native-home', viewID: '', ui: this.getUIContext(), holderID: 'lynx-navigation-home', sessionID: '',
            backgroundColor: '#FFFFFF', firstScreen: true, applyWindowPolicy: () => ShellWindowController.restore(), isActive: () => this.alive,
            getPresentation: () => ({ x: this.homeX, y: this.homeY, scale: this.homeScale }),
            setPresentation: (value) => { if (this.alive) { this.homeX = value.x; this.homeY = value.y; this.homeScale = value.scale; } },
            getOpacity: () => this.homeOpacity, setOpacity: (value: number) => { if (this.alive) this.homeOpacity = value; } });
          LynxNavigator.installNavigationDriver(this.adapter);
        } else {
          const rect = this.getUIContext().getComponentUtils().getRectangleById('lynx-navigation-overlay-root');
          ShellTransitionRuntime.shared.hostLayoutChanged(width, height, this.getUIContext().px2vp(rect.windowOffset.x), this.getUIContext().px2vp(rect.windowOffset.y));
        }
      })
      .onGestureJudgeBegin((info: GestureInfo, event: BaseGestureEvent) => {
        if (info.tag !== 'lynx-shell-back-pan') return GestureJudgeResult.CONTINUE;
        return this.acceptGesture(event as GestureEvent) ? GestureJudgeResult.CONTINUE : GestureJudgeResult.REJECT;
      })
      .priorityGesture(PanGesture({ direction: PanDirection.All, distance: 12 }).tag('lynx-shell-back-pan')
        .onActionStart((event: GestureEvent) => {
          this.gestureProgress = 0;
          this.gestureAccepted = this.acceptGesture(event);
          if (this.gestureAccepted) this.adapter?.beginGesture().catch(() => { this.gestureAccepted = false; });
        }).onActionUpdate((event: GestureEvent) => {
          if (!this.gestureAccepted) return;
          const rect = this.canvas.origin;
          this.gestureProgress = Math.max(0, Math.min(1, this.gestureAxis === 'horizontal' ? event.offsetX / rect.width : event.offsetY / rect.height));
          this.adapter?.updateGesture(this.gestureProgress);
        }).onActionEnd((event: GestureEvent) => {
          if (!this.gestureAccepted) return;
          this.adapter?.endGesture(this.gestureProgress >= 0.42 || (this.gestureProgress >= 0.12 && (this.gestureAxis === 'horizontal' ? event.velocityX : event.velocityY) >= 700));
          this.gestureAccepted = false;
        }).onActionCancel(() => { if (this.gestureAccepted) this.adapter?.endGesture(false); this.gestureAccepted = false; }));
  }
}
