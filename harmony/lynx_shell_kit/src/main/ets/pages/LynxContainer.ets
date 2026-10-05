import ShellRoutePresentationSpec from '../transition/ShellRoutePresentationSpec';
import ShellPreparedRouteStore from '../transition/ShellPreparedRouteStore';
import ShellTransitionRuntime from '../transition/ShellTransitionRuntime';
import { ShellPageParams } from '../common/ShellTypes';
import LynxOtaHealthGate from '../runtime/LynxOtaHealthGate';
import router from '@ohos.router';
import { display } from '@kit.ArkUI';
import {
  BehaviorRegistryMap,
  LynxContext,
  LynxExtraTiming,
  LLog,
  LynxView,
  MetaData,
  ModuleClassWrapper,
  SendableModuleClassWrapper,
  TemplateData
} from '@lynx/lynx';
import ShellLynxViewClient, { ShellLynxLoadFailure } from '../client/ShellLynxViewClient';
import ShellConstants from '../common/ShellConstants';
import ShellGlobalPropsFactory, { ShellBundleMetadata } from '../common/ShellGlobalPropsFactory';
import ShellThemeState from '../common/ShellTheme';
import ShellLocaleState from '../common/ShellLocale';
import ShellLayoutState from '../common/ShellLayoutState';
import OtaUserContextEvents from '../ota/OtaUserContextEvents';
import { ShellViewAppearPayload } from '../common/ShellTypes';
import ShellWindowController from '../common/ShellWindowController';
import XElementRuntime from '../common/XElementRuntime';
import LynxPageRequest from '../model/LynxPageRequest';
import { LynxShellModule } from '../module/LynxShellModule';
import HostNativeModules from '../common/HostNativeModules';
import LynxNavigator from '../routing/LynxNavigator';
import ShellMessageHub from '../common/ShellMessageHub';
import ShellGenericResourceFetcher from '../provider/ShellGenericResourceFetcher';
import ShellMediaResourceFetcher from '../provider/ShellMediaResourceFetcher';
import ShellTemplateResourceFetcher from '../provider/ShellTemplateResourceFetcher';
import PageBundleRuntimeRegistry, {
  OtaBundleLease,
  OtaPrepareSignal,
  PageBundleRuntime,
  PreparedPageBundle
} from '../ota/OtaModels';

/**
 * 单页面 Lynx 宿主。
 * 页面只组装 LynxView 输入和原生状态层，Runtime/路由/下载/Bridge 均由独立模块负责。
 */
@Component
export struct LynxContainer {
  @Prop nativeParams: ShellPageParams = {};
  @Prop @Watch('nativeVisibilityChanged') nativeShown: boolean = true;
  @State @Watch('nativeVisibilityChanged') private navigationCovered: boolean = false;
  @State private transitionOpacity: number = 1;
  @State private transitionX: number = 0;
  @State private transitionY: number = 0;
  @State private transitionScale: number = 1;
  private alive: boolean = true;
  private nativeInitialized: boolean = false;
  @State private isLoading: boolean = true;
  @State private errorMessage: string = '';
  @State private showLynxView: boolean = false;

  private visible: boolean = false;
  private preparedSnapshotID: string = '';
  private healthGate: LynxOtaHealthGate = new LynxOtaHealthGate(() => false);
  private request: LynxPageRequest = LynxPageRequest.fromRouterParams(router.getParams());
  private modules: Map<string, ModuleClassWrapper> = new Map();
  private sendableModules: Map<string, SendableModuleClassWrapper> = new Map();
  private clients: ShellLynxViewClient[] = [];
  private behaviors: BehaviorRegistryMap = XElementRuntime.createBehaviors();
  private templateFetcher: ShellTemplateResourceFetcher =
    new ShellTemplateResourceFetcher(this.request.allowHttpInDebug);
  private genericFetcher: ShellGenericResourceFetcher = new ShellGenericResourceFetcher();
  private mediaFetcher: ShellMediaResourceFetcher = new ShellMediaResourceFetcher();
  private metaData: MetaData = new MetaData(
    new TemplateData(this.request.initDataJson),
    new TemplateData(ShellGlobalPropsFactory.build(this.request.globalPropsJson, this.request))
  );
  private extraTiming: LynxExtraTiming = new LynxExtraTiming();
  private presentation: ShellRoutePresentationSpec = new ShellRoutePresentationSpec();
  private currentTransitionMetadataKey: string = '';
  private currentBundleMetadata?: ShellBundleMetadata;
  private lynxContext: LynxContext | null = null;
  private prepareSignal: OtaPrepareSignal = new OtaPrepareSignal();
  private prepareGeneration: number = 0;
  private preparing: boolean = false;
  private releaseLease: OtaBundleLease | null = null;
  private rollbackAttempted: boolean = false;
  private rollbackInProgress: boolean = false;
  private pendingRecoveryLoad: boolean = false;
  private preparedRuntime: PageBundleRuntime | null = null;
  private preparedEpoch: number | undefined = undefined;
  private preparedReleaseId: string | undefined = undefined;
  private firstScreenReached: boolean = false;
  private nextLoadKind: 'initial' | 'retry' | 'reload' = 'initial';
  private contextCreated: (context: LynxContext) => void = () => {};
  private readonly userListener: (epoch: number) => void = () => {
    if (this.request.isOtaRequest() && !this.isPreparedUserCurrent()) this.healthGate.fail('OTA 用户身份已变化');
    if (this.request.isOtaRequest() && this.preparedRuntime !== null && !this.firstScreenReached && !this.isPreparedUserCurrent()) {
      this.cancelPendingRequests();
      this.cancelViewResources();
      this.isLoading = false;
      this.errorMessage = 'OTA 用户已切换，请重新打开页面';
    }
  };
  private viewWidth: number | string = '100%';
  private viewHeight: number | string = '100%';

  aboutToAppear(): void {
    if (!this.nativeInitialized && this.nativeParams.nativeNavigationHosted === true) { this.request = LynxPageRequest.fromRouterParams(this.nativeParams); this.nativeInitialized = true; }
    this.presentation = this.request.presentationSpec();
    this.alive = true;
    this.visible = this.request.nativeNavigationHosted ? this.nativeShown && !this.navigationCovered : true;
    if (this.lynxContext !== null) HostNativeModules.contextVisibilityChanged(this.lynxContext);
    OtaUserContextEvents.subscribe(this.userListener);
    LynxNavigator.register(this.request);
    // 页面级 keyboardBehavior 在 Window/UIContext 层生效；LynxView 不需要重复计算键盘高度。
    if (!this.request.nativeNavigationHosted || !ShellTransitionRuntime.shared.isBusy()) ShellWindowController.apply(this.request);

    if (this.pendingRecoveryLoad) {
      this.pendingRecoveryLoad = false;
      this.prepareOtaBundle();
      return;
    }

    // 被下一页覆盖时保留 LynxView 和 LynxContext；返回当前 Page 后恢复前台事件。
    // 首次创建仍由 LynxView.onCreate 完成 register/viewAppear，避免重复注册。
    if (this.lynxContext !== null) {
      this.lynxContext.onEnterForeground();
      this.lynxContext.sendGlobalEvent('viewAppear', [new ShellViewAppearPayload(this.request.bundleUrl)]);
      this.clients[0]?.markVisible();
      ShellMessageHub.sendLifecycle(this.request.entryID, 'active', 'arkui_page_appear');
      return;
    }

    this.modules.set('LynxShellModule', { moduleClass: LynxShellModule });
    HostNativeModules.applyTo(this.modules);
    LLog.d(ShellConstants.TAG, 'registered LynxShellModule with full Harmony bridge contract');
    if (!this.request.isOtaRequest()) {
      // Native params接收后重建direct输入，避免旧ArkUI Router数据污染独立页面。
      this.templateFetcher = new ShellTemplateResourceFetcher(this.request.allowHttpInDebug);
      this.metaData = new MetaData(new TemplateData(this.request.initDataJson), new TemplateData(ShellGlobalPropsFactory.build(this.request.globalPropsJson, this.request)));
      this.configureClients(this.prepareGeneration);
    }

    const density = display.getDefaultDisplaySync().densityPixels;
    if (this.request.widthPx > 0) {
      this.viewWidth = this.request.widthPx / density;
    }
    if (this.request.heightPx > 0) {
      this.viewHeight = this.request.heightPx / density;
    }

    const now = new Date().getTime();
    this.extraTiming.openTime = now;
    this.extraTiming.containerInitStart = now;
    this.extraTiming.containerInitEnd = new Date().getTime();
    this.extraTiming.prepareTemplateStart = new Date().getTime();
    if (this.request.isOtaRequest()) {
      this.prepareOtaBundle();
    } else {
      this.prepareDirectBundle();
    }
  }

  aboutToBeDeleted(): void {
    this.alive = false;
    ShellTransitionRuntime.shared.unbind(this.transitionViewID(), this.lynxContext ?? undefined);
    OtaUserContextEvents.unsubscribe(this.userListener);
    this.cancelPendingRequests();
    this.cancelViewResources();
    if (this.request.nativeNavigationHosted) {
      LynxNavigator.reconcileWithDriver();
      if (!LynxNavigator.hasSession(this.request.sessionID, this.request.lynxAppId) && !ShellMessageHub.hasContextsForSession(this.request.sessionID, undefined, this.request.lynxAppId)) {
        PageBundleRuntimeRegistry.current()?.releaseNavigationSnapshot(this.request.sessionID, this.request.lynxAppId);
      }
    }
  }

  private configureClients(generation: number): void {
    this.healthGate.fail();
    this.transitionOpacity = 1;
    this.healthGate = new LynxOtaHealthGate(() => generation === this.prepareGeneration &&
      (!this.request.isOtaRequest() || this.isPreparedUserCurrent()));
    this.clients[0]?.markDestroyed('view_reconfigured');
    if (this.lynxContext !== null) {
      ShellMessageHub.unregisterContext(this.request.entryID, this.lynxContext!);
      HostNativeModules.destroyForContext(this.lynxContext);
      this.lynxContext = null;
    }
    let monitorClient: ShellLynxViewClient | null = null;
    this.contextCreated = (context: LynxContext) => {
      if (generation !== this.prepareGeneration || (this.request.isOtaRequest() && !this.isPreparedUserCurrent())) {
        context.onEnterBackground();
        HostNativeModules.destroyForContext(context);
        return;
      }
      if (this.lynxContext === context) return;
      this.lynxContext = context;
      HostNativeModules.attachContext(context, this.getUIContext(), () => this.visible);
      monitorClient?.markCreated();
      if (this.visible) monitorClient?.markVisible(); else monitorClient?.markHidden();
      // Harmony LynxView 的 colorScheme 字段由 SDK 保持私有；Context 建立后立即使用
      // 官方动态 API 设定首值，早于壳层登记和前台事件，不重载 Bundle。
      context.updateColorScheme(ShellThemeState.colorScheme());
      ShellMessageHub.register({ pageId: this.request.entryID, containerId: this.request.entryID,
        pageKey: this.request.routeKey.length > 0 ? this.request.routeKey : this.request.bundleUrl, hostMode: 'arkui_page', lynxAppId: this.request.lynxAppId, sessionID: this.request.sessionID, hasHostAnchor: this.request.hasHostAnchor, navigationSnapshotID: this.preparedSnapshotID }, context);
      ShellMessageHub.bindHealth(this.request.entryID, this.healthGate);
      ShellMessageHub.bindVisibility(this.request.entryID, () => this.visible && LynxNavigator.isCurrentEntry(this.request.entryID));
      ShellMessageHub.bindBackGestureEnabled(this.request.entryID, this.request.backGestureEnabled, (enabled: boolean) => {
        this.request.backGestureEnabled = enabled;
        LynxNavigator.updateBackGesture(this.transitionViewID(), enabled);
      });
      monitorClient?.bindContext(context, this.request.entryID);
      this.bindTransitionView(generation);
      context.onEnterForeground();
      if (this.visible) {
        context.sendGlobalEvent('viewAppear', [new ShellViewAppearPayload(this.request.bundleUrl)]);
        ShellMessageHub.sendLifecycle(this.request.entryID, 'active', 'arkui_page_appear');
      }
      const rawScreen = ShellLayoutState.rawScreenSize();
      const layout = ShellLayoutState.snapshot(this.request.entryID);
      context.updateScreenMetrics(rawScreen.width, rawScreen.height);
      context.updateViewport(layout.viewportWidth, 1, layout.viewportHeight, 1);
      context.setExtraTiming(this.extraTiming);
    };
    monitorClient = new ShellLynxViewClient(
      (url: string) => { if (generation === this.prepareGeneration) this.handleLoadSuccess(url); },
      (failure: ShellLynxLoadFailure) => { if (generation === this.prepareGeneration) this.handleLoadError(failure); },
      () => { if (generation === this.prepareGeneration) this.handleFirstScreen(); },
      'page',
      this.contextCreated
    );
    monitorClient.setLoadKind(this.nextLoadKind);
    this.clients = [monitorClient];
    this.bindTransitionView(generation);
  }

  private isPreparedUserCurrent(): boolean {
    return this.preparedRuntime === PageBundleRuntimeRegistry.current() && this.preparedEpoch === this.preparedRuntime?.userIdentityEpoch;
  }

  aboutToDisappear(): void {
    if (this.request.nativeNavigationHosted) {
      this.visible = false;
      if (this.lynxContext !== null) { this.lynxContext.onEnterBackground(); this.clients[0]?.markHidden(); HostNativeModules.contextVisibilityChanged(this.lynxContext); }
      return;
    }
    this.visible = false;
    if (this.lynxContext !== null) HostNativeModules.contextVisibilityChanged(this.lynxContext);
    const disappearingContext = this.lynxContext;
    const disappearingClient = this.clients[0];
    if (disappearingContext !== null) {
      disappearingContext.onEnterBackground();
      disappearingClient?.markHidden();
      // aboutToDisappear 既可能表示被下一页覆盖，也可能表示从 NavPathStack 移除；先
      // 发 covered，下一轮根据逻辑栈是否还存在来决定是否真正销毁。被覆盖时
      // 不能取消 Provider 请求或丢弃 Context，否则返回后页面无法恢复。
      ShellMessageHub.sendLifecycle(this.request.entryID, 'covered', 'arkui_page_disappear');
    }
    // 下载阶段还没有 LynxContext，也必须在 Page 真正移除后取消 prepare；被下一页覆盖则保留。
    setTimeout(() => {
      LynxNavigator.reconcileWithRouter();
      if (LynxNavigator.hasEntry(this.request.entryID)) {
        return;
      }
      ShellMessageHub.sendLifecycle(this.request.entryID, 'destroyed', 'arkui_page_removed');
      disappearingClient?.markDestroyed('arkui_page_removed');
      if (disappearingContext !== null) ShellMessageHub.unregisterContext(this.request.entryID, disappearingContext);
      this.cancelPendingRequests();
      if (this.lynxContext === disappearingContext) {
        if (disappearingContext !== null) {
          HostNativeModules.destroyForContext(disappearingContext);
        }
        this.lynxContext = null;
      }
      if (!LynxNavigator.hasSession(this.request.sessionID, this.request.lynxAppId)) {
        PageBundleRuntimeRegistry.current()?.releaseNavigationSnapshot(
          this.request.sessionID,
          this.request.lynxAppId
        );
      }
    }, 0);
    ShellWindowController.restore();
  }

  onBackPress(): boolean {
    if (!ShellMessageHub.backGestureEnabled(this.request.entryID)) return true;
    if (this.lynxContext !== null && HostNativeModules.dispatchBackPress(this.lynxContext)) {
      return true;
    }
    // 由壳主动提交返回并同步移除逻辑栈；如果交给系统默认返回，静态 entries 会残留，
    // MessageHub 也无法判断当前 LynxContext 已经被真正移除。
    const result = LynxNavigator.closeResult();
    return result.code === 0;
  }

  /**
   * `@ohos.router` 没有逐次 push 的 animated 参数；默认不声明时沿用系统转场。
   * open/replace 传 animated=false 时，目标 Page 用零时长转场覆盖系统默认动画。
   */
  pageTransition() {
    if (!this.request.animated) {
      PageTransitionEnter({ type: RouteType.None, duration: 0 });
      PageTransitionExit({ type: RouteType.None, duration: 0 });
    }
  }

  private handleLoadSuccess(url: string): void {
    // 首屏必须由 SDK 真正完成布局的回调收敛，load success 不等于首帧。
  }

  private handleFirstScreen(): void {
    if (this.request.isOtaRequest() && !this.isPreparedUserCurrent()) return;
    this.firstScreenReached = true;
    ShellTransitionRuntime.shared.firstScreen(this.transitionViewID());
    this.healthGate.markFirstScreen();
    this.isLoading = false;
  }

  private handleLoadError(failure: ShellLynxLoadFailure): void {
    if (!failure.requiresErrorState()) return;
    const message = failure.message;
    const candidate = this.healthGate.isCandidateTrial();
    this.healthGate.fail('页面发生终止性加载错误');
    if (this.request.isOtaRequest() && this.isPreparedUserCurrent() && (candidate || !this.firstScreenReached) && !this.rollbackAttempted && !this.rollbackInProgress) {
      this.attemptRollback(message.length > 0 ? message : 'Lynx 首屏加载失败', candidate);
      return;
    }
    ShellTransitionRuntime.shared.failure(this.transitionViewID());
    this.clients[0]?.markLoadFailed('lynx_load_error');
    this.cancelViewResources();
    this.isLoading = false;
    this.errorMessage = message.length > 0 ? message : 'Lynx 页面加载失败';
  }

  private retry(): void {
    this.cancelPendingRequests();
    this.cancelViewResources();
    this.currentTransitionMetadataKey = '';
    this.isLoading = true;
    this.errorMessage = '';
    this.showLynxView = false;
    this.configureClients(this.prepareGeneration);
    this.nextLoadKind = 'retry';
    this.clients[0]?.setLoadKind(this.nextLoadKind);
    if (this.request.isOtaRequest()) {
      // 用户主动重试会重新检查 current/repair，但一次页面生命周期内仍不重复自动回滚。
      this.prepareOtaBundle();
      return;
    }
    this.templateFetcher = new ShellTemplateResourceFetcher(this.request.allowHttpInDebug);
    this.metaData = new MetaData(new TemplateData(this.request.initDataJson), new TemplateData(ShellGlobalPropsFactory.build(this.request.globalPropsJson, this.request)));
    this.prepareDirectBundle();
  }

  private prepareDirectBundle(): void {
    const generation = this.prepareGeneration; const signal = this.prepareSignal;
    const token = this.request.preparedRouteToken; this.request.preparedRouteToken = '';
    const prepared = token.length > 0 ? ShellPreparedRouteStore.shared.consume(token, this.request, signal) : Promise.resolve<PreparedPageBundle | null>(null);
    prepared.then((bundle: PreparedPageBundle | null) => {
      if (!this.alive || generation !== this.prepareGeneration || signal.cancelled) { bundle?.lease?.close(); return; }
      if (bundle !== null) {
        this.templateFetcher.cancelAll();
        this.templateFetcher = new ShellTemplateResourceFetcher(this.request.allowHttpInDebug, this.request.bundleUrl, '', '', bundle.bytes ?? null, bundle.asyncResolver);
      } else if (token.length > 0) { this.clients[0]?.markBundleUnavailable('prepared_route_expired', this.request.bundleUrl); }
      this.extraTiming.prepareTemplateEnd = Date.now();
      this.clients[0]?.markBundleUnavailable('direct_bundle_identity_unavailable', this.request.bundleUrl);
      this.clients[0]?.markLoadStarted(); this.showLynxView = true;
    }).catch((error: Error) => {
      if (!this.alive || generation !== this.prepareGeneration || signal.cancelled) return;
      this.isLoading = false; this.errorMessage = `预置Bundle消费失败：${error.message}`;
      ShellTransitionRuntime.shared.failure(this.transitionViewID());
    });
  }

  /** OTA 页面必须先拿到已校验文件，再创建 LynxView，避免下载期间出现白/黑闪屏。 */
  private prepareOtaBundle(): void {
    if (this.preparing) {
      return;
    }
    const runtime = PageBundleRuntimeRegistry.current();
    if (runtime === null) {
      this.isLoading = false;
      this.errorMessage = '当前没有安装 HarmonyOS OTA runtime';
      return;
    }
    this.preparing = true;
    this.preparedRuntime = runtime;
    this.preparedEpoch = runtime.userIdentityEpoch;
    this.preparedReleaseId = undefined;
    this.firstScreenReached = false;
    // 先尝试 cache-only；本地命中时不让 OTA Loading 盖住页面/转场。
    this.isLoading = false;
    this.errorMessage = '';
    this.showLynxView = false;
    this.prepareSignal.cancel();
    this.prepareSignal = new OtaPrepareSignal();
    const signal = this.prepareSignal;
    const generation = ++this.prepareGeneration;
    const epoch = this.preparedEpoch;
    this.configureClients(generation);
    let pendingLease: OtaBundleLease | null = null;
    const token = this.request.preparedRouteToken; this.request.preparedRouteToken = '';
    const preloaded = token.length > 0 ? ShellPreparedRouteStore.shared.consume(token, this.request, signal) : Promise.resolve<PreparedPageBundle | null>(null);
    preloaded.then((prepared: PreparedPageBundle | null) => {
      if (prepared !== null) return prepared;
      if (token.length > 0) this.clients[0]?.markBundleUnavailable('prepared_route_expired', this.request.bundleUrl);
      return runtime.resolvePage(this.request.lynxAppId, this.request.bundleName, this.request.sessionID, this.request.sourceSnapshotID, signal);
    }).then((cached: PreparedPageBundle | null) => {
        if (signal.cancelled || generation !== this.prepareGeneration || !this.isPreparedUserCurrent() ||
          (cached?.userIdentityEpoch !== undefined && cached.userIdentityEpoch !== epoch)) {
          cached?.lease?.close();
          throw new Error('stale_identity');
        }
        if (cached !== null) {
          if (cached.source !== 'embedded_baseline') {
            runtime.refreshAppBundleIfNeeded(this.request.lynxAppId);
          }
          return cached;
        }
        this.isLoading = true;
        return runtime.prepare(this.request.lynxAppId, this.request.bundleName, signal, this.request.sessionID, this.request.sourceSnapshotID);
      })
      .then((prepared: PreparedPageBundle) => {
        pendingLease = prepared.lease ?? null;
        if (signal.cancelled || generation !== this.prepareGeneration || !this.isPreparedUserCurrent() ||
          (prepared.userIdentityEpoch !== undefined && prepared.userIdentityEpoch !== epoch) ||
          !LynxNavigator.hasEntry(this.request.entryID)) {
          pendingLease?.close();
          pendingLease = null;
          return;
        }
        this.preparedReleaseId = prepared.releaseId;
        this.preparedSnapshotID = prepared.navigationSnapshotID ?? '';
        this.healthGate.configure(runtime, prepared);
        this.templateFetcher.cancelAll();
        this.templateFetcher = new ShellTemplateResourceFetcher(
          this.request.allowHttpInDebug,
          this.request.bundleUrl,
          prepared.filePath,
          runtime.storageRoot(),
          prepared.bytes ?? null,
          prepared.asyncResolver
        );
        this.genericFetcher.cancelAll();
        this.genericFetcher = new ShellGenericResourceFetcher(prepared.asyncResolver);
        this.mediaFetcher = new ShellMediaResourceFetcher(prepared.asyncResolver);
        const localeState = ShellLocaleState.current();
        const bundleMetadata: ShellBundleMetadata = {
          lynxAppId: prepared.lynxAppId,
          releaseId: prepared.releaseId,
          manifestId: prepared.manifestId,
          navigationSnapshotID: prepared.navigationSnapshotID,
          source: this.rollbackAttempted && prepared.source === 'embedded_baseline' ? 'rollback_fallback' : (prepared.source ?? 'ota_current'),
          userIdentityEpoch: prepared.userIdentityEpoch,
          selectionKind: prepared.selectionKind,
          releaseSequence: prepared.releaseSequence,
          policyRevision: prepared.policyRevision,
          bundleName: prepared.bundleName,
          sha256: prepared.sha256
        };
        this.currentBundleMetadata = bundleMetadata;
        this.metaData = new MetaData(
          new TemplateData(this.request.initDataJson),
          new TemplateData(ShellGlobalPropsFactory.build(
            this.request.globalPropsJson,
            this.request,
            bundleMetadata,
            localeState
          ))
        );
        this.clients[0]?.setPreparedBundle(
          prepared.source ?? 'ota_current', prepared.lynxAppId, prepared.bundleName,
          prepared.releaseId, prepared.releaseSequence ?? null, prepared.sha256
        );
        this.clients[0]?.markLoadResolved(null);
        this.clients[0]?.markLoadStarted();
        this.extraTiming.prepareTemplateEnd = new Date().getTime();
        console.info(`[${ShellConstants.TAG}] prepared ${prepared.lynxAppId}/${prepared.bundleName}, release=${prepared.releaseId}, manifest=${prepared.manifestId ?? 'embedded'}, snapshot=${prepared.navigationSnapshotID ?? 'none'}`);
        this.preparing = false;
        this.releaseCurrentLease();
        this.releaseLease = prepared.lease ?? null;
        pendingLease = null;
        this.isLoading = true;
        this.showLynxView = true;
      })
      .catch((error: Error) => {
        pendingLease?.close();
        pendingLease = null;
        if (signal.cancelled || generation !== this.prepareGeneration) {
          return;
        }
        this.preparing = false;
        this.isLoading = false;
        this.errorMessage = `OTA Bundle 准备失败：${error.message}`;
      });
  }

  /** 首屏失败时按 appId 自动回滚一次；回滚成功后重新 prepare，第二次失败直接进入错误页。 */
  private attemptRollback(reason: string, candidate: boolean): void {
    const runtime: PageBundleRuntime | null = PageBundleRuntimeRegistry.current();
    if (runtime === null || !this.isPreparedUserCurrent()) {
      this.isLoading = false;
      this.errorMessage = reason;
      return;
    }
    // recover调用先同步取得确切失败版本票据，后续Native取消/节点删除不能抹掉恢复身份。
    const recovery = runtime.recoverFailedRelease(this.request.lynxAppId, reason, this.preparedReleaseId ?? '', this.preparedEpoch, this.request.sessionID, this.preparedSnapshotID, candidate);
    ShellTransitionRuntime.shared.failure(this.transitionViewID());
    this.rollbackAttempted = true;
    this.rollbackInProgress = true;
    this.isLoading = true;
    this.errorMessage = '';
    this.showLynxView = false;
    this.cancelViewResources();
    const generation = this.prepareGeneration;
    recovery.then((restored: boolean) => {
        if (generation !== this.prepareGeneration || !this.isPreparedUserCurrent()) return;
        this.rollbackInProgress = false;
        if (!restored) {
          this.isLoading = false;
          this.errorMessage = `${reason}；没有可回滚的上一版本`;
          return;
        }
        this.request.sourceSnapshotID = '';
        if (!this.visible) { this.pendingRecoveryLoad = true; return; }
        this.prepareOtaBundle();
      })
      .catch((error: Error) => {
        if (generation !== this.prepareGeneration || !this.isPreparedUserCurrent()) return;
        this.rollbackInProgress = false;
        this.isLoading = false;
        this.errorMessage = `${reason}；回滚失败：${error.message}`;
      });
  }

  /** 避免旧页面请求在新页面/重试后继续回调。 */
  private cancelPendingRequests(): void {
    this.healthGate.fail();
    this.prepareSignal.cancel();
    this.prepareGeneration += 1;
    this.preparing = false;
    this.templateFetcher.cancelAll();
    this.genericFetcher.cancelAll();
    this.releaseCurrentLease();
  }

  private cancelViewResources(): void {
    ShellTransitionRuntime.shared.unbind(this.transitionViewID(), this.lynxContext ?? undefined);
    this.healthGate.fail();
    this.templateFetcher.cancelAll();
    this.genericFetcher.cancelAll();
    this.clients[0]?.markDestroyed('view_resources_cancelled');
    if (this.lynxContext !== null) {
      ShellMessageHub.unregisterContext(this.request.entryID, this.lynxContext!);
      HostNativeModules.destroyForContext(this.lynxContext);
      this.lynxContext = null;
    }
    this.releaseCurrentLease();
  }

  private releaseCurrentLease(): void {
    const lease = this.releaseLease;
    this.releaseLease = null;
    lease?.close();
  }

  private nativeBodyBackground(): string { return this.presentation.opaque ? this.request.backgroundColor : '#00000000'; }
  private transitionViewID(): string { return this.request.nativeViewID.length > 0 ? this.request.nativeViewID : this.request.entryID; }
  private transitionHolderID(): string { return `lynx-page-body-${this.transitionViewID()}`; }
  private bindTransitionView(generation: number): void {
    if (!this.alive) return;
    ShellTransitionRuntime.shared.bind({ entryID: this.request.entryID, viewID: this.transitionViewID(), context: this.lynxContext ?? undefined,
      ui: this.getUIContext(), holderID: this.transitionHolderID(), sessionID: this.request.sessionID,
      applyWindowPolicy: () => { if (this.alive && generation === this.prepareGeneration) ShellWindowController.apply(this.request); },
      setCovered: (covered: boolean) => { if (this.alive && generation === this.prepareGeneration) this.navigationCovered = covered; },
      presentationSpec: this.presentation, updateTransition: (id: string) => {
        if (!this.alive || generation !== this.prepareGeneration || this.lynxContext === null) return;
        const state = ShellTransitionRuntime.shared.currentState();
        const key = `${id}:${state.effectiveTransition}:${state.direction}:${state.reason}`;
        if (key === this.currentTransitionMetadataKey) return;
        this.currentTransitionMetadataKey = key; this.request.transitionID = id;
        this.lynxContext.updateMetaData(new MetaData(undefined, new TemplateData(ShellGlobalPropsFactory.build(this.request.globalPropsJson, this.request, this.currentBundleMetadata))));
      },
      loadGeneration: generation, identityEpoch: this.preparedEpoch, backgroundColor: this.nativeBodyBackground(), firstScreen: this.firstScreenReached,
      isActive: () => this.alive && generation === this.prepareGeneration,
      getPresentation: () => ({ x: this.transitionX, y: this.transitionY, scale: this.transitionScale }),
      setPresentation: (value) => { if (this.alive && generation === this.prepareGeneration) { this.transitionX = value.x; this.transitionY = value.y; this.transitionScale = value.scale; } },
      getOpacity: () => this.transitionOpacity, setOpacity: (value: number) => { if (this.alive && generation === this.prepareGeneration) this.transitionOpacity = value; } });
  }
  private nativeVisibilityChanged(): void {
    if (!this.request.nativeNavigationHosted) return;
    this.visible = this.nativeShown && !this.navigationCovered;
    const context = this.lynxContext;
    if (context !== null) {
      if (this.visible) {
        ShellMessageHub.register({ pageId: this.request.entryID, containerId: this.request.entryID, pageKey: this.request.routeKey,
          hostMode: 'arkui_page', lynxAppId: this.request.lynxAppId, sessionID: this.request.sessionID, hasHostAnchor: this.request.hasHostAnchor, navigationSnapshotID: this.preparedSnapshotID }, context);
        ShellMessageHub.bindHealth(this.request.entryID, this.healthGate);
        ShellMessageHub.bindBackGestureEnabled(this.request.entryID, this.request.backGestureEnabled, (enabled: boolean) => {
          this.request.backGestureEnabled = enabled; LynxNavigator.updateBackGesture(this.transitionViewID(), enabled);
        });
        ShellMessageHub.bindVisibility(this.request.entryID, () => this.visible && LynxNavigator.isCurrentEntry(this.request.entryID));
        context.onEnterForeground(); this.clients[0]?.markVisible();
        context.sendGlobalEvent('viewAppear', [new ShellViewAppearPayload(this.request.bundleUrl)]);
        ShellMessageHub.sendLifecycle(this.request.entryID, 'active', 'native_navigation_shown');
        if (!this.request.nativeNavigationHosted || !ShellTransitionRuntime.shared.isBusy()) ShellWindowController.apply(this.request);
      } else { context.onEnterBackground(); this.clients[0]?.markHidden(); ShellMessageHub.sendLifecycle(this.request.entryID, 'covered', 'native_navigation_hidden'); }
      HostNativeModules.contextVisibilityChanged(context);
    }
    if (this.visible && this.pendingRecoveryLoad) { this.pendingRecoveryLoad = false; this.prepareOtaBundle(); }
  }

  /** 外层 ArkUI 区域是当前 LynxView 的 viewport；只提交尺寸，更新由状态层合帧处理。 */
  private onAreaChanged(area: Area): void {
    ShellLayoutState.updateViewport(
      this.request.entryID,
      Number(area.width),
      Number(area.height),
      Number(area.globalPosition.x),
      Number(area.globalPosition.y),
      this.getUIContext().vp2px(1)
    );
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        if (this.showLynxView) {
          LynxView({
            clients: this.clients,
            url: this.request.bundleUrl,
            genericResourceFetcher: this.genericFetcher,
            mediaResourceFetcher: this.mediaFetcher,
            templateResourceFetcher: this.templateFetcher,
            modules: this.modules,
            sendableModules: this.sendableModules,
            behaviors: this.behaviors,
            metaData: this.metaData,
            screenSize: ShellLayoutState.rawScreenSize(),
            onCreate: this.contextCreated
          })
            .width(this.viewWidth)
            .height(this.viewHeight)
        }

        if (this.errorMessage.length > 0) {
          Column({ space: 14 }) {
            Text('页面加载失败')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor('#111827')
            Text(this.errorMessage)
              .fontSize(13)
              .fontColor('#6B7280')
              .textAlign(TextAlign.Center)
              .maxLines(6)
            Button('重新加载')
              .height(44)
              .padding({ left: 26, right: 26 })
              .backgroundColor('#FF4E5A')
              .borderRadius(12)
              .onClick(() => this.retry())
          }
          .width('82%')
          .padding(24)
          .backgroundColor('#FFFFFF')
          .borderRadius(18)
        }

        if (this.isLoading && this.errorMessage.length === 0) {
          Column({ space: 12 }) {
            LoadingProgress()
              .width(34)
              .height(34)
              .color('#FF4E5A')
            Text(this.request.isOtaRequest() ? '正在准备 OTA 页面…' : '正在加载页面…')
              .fontSize(14)
              .fontColor('#6B7280')
          }
          .padding(22)
          .backgroundColor('#FFFFFF')
          .borderRadius(16)
        }
      }
      .id(this.transitionHolderID())
      .opacity(this.transitionOpacity)
      .translate({ x: this.transitionX, y: this.transitionY })
      .scale({ x: this.transitionScale, y: this.transitionScale })
      .width('100%')
      .layoutWeight(1)
      .onAreaChange((oldValue: Area, newValue: Area) => this.onAreaChanged(newValue))
      .backgroundColor(this.nativeBodyBackground())
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.nativeBodyBackground())
  }

}
