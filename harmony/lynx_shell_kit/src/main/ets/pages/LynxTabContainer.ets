import LynxNavigator from '../routing/LynxNavigator';
import ShellWindowController from '../common/ShellWindowController';
import ShellTransitionRuntime from '../transition/ShellTransitionRuntime';
import LynxOtaHealthGate from '../runtime/LynxOtaHealthGate';
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
import ShellLocaleState, { ShellLocaleStateValue } from '../common/ShellLocale';
import ShellLayoutState from '../common/ShellLayoutState';
import { ShellViewAppearPayload } from '../common/ShellTypes';
import XElementRuntime from '../common/XElementRuntime';
import LynxPageRequest from '../model/LynxPageRequest';
import { LynxShellModule } from '../module/LynxShellModule';
import HostNativeModules from '../common/HostNativeModules';
import ShellMessageHub from '../common/ShellMessageHub';
import ShellGenericResourceFetcher from '../provider/ShellGenericResourceFetcher';
import ShellMediaResourceFetcher from '../provider/ShellMediaResourceFetcher';
import ShellTemplateResourceFetcher from '../provider/ShellTemplateResourceFetcher';
import PageBundleRuntimeRegistry, { OtaBundleLease, PageBundleRuntime, PreparedPageBundle } from '../ota/OtaModels';
import OtaUserContextEvents from '../ota/OtaUserContextEvents';

/** 一个原生 Tab 的逻辑描述，不包含 Tabs、TabBar 或选中态。 */
export interface LynxTabSpec {
  tabId: string;
  bundleUrl: string;
  title: string;
  routeKey: string;
  initDataJson: string;
  globalPropsJson: string;
  lynxAppId: string;
  bundleName: string;
  backgroundColor: string;
}

/**
 * HarmonyOS 无 Tabs 的 Lynx 内容承载器。
 *
 * 业务宿主可以把它放进 ArkUI Tabs、Page 或其它 Container。OTA Tab 只读已经由
 * Application 启动/回前台同步产生的 current，不会在 Tab 切换时联网。
 */
@Component
export struct LynxTabContainer {
  @Prop @Watch('hostVisibilityChanged') hostVisible: boolean = true;
  spec: LynxTabSpec = {
    tabId: 'tab',
    bundleUrl: ShellConstants.DEFAULT_ROUTE,
    title: 'Lynx Tab',
    routeKey: 'native-tab',
    initDataJson: '{}',
    globalPropsJson: '{}',
    lynxAppId: '',
    bundleName: '',
    backgroundColor: '#FFFFFF'
  };

  /** 宿主主动刷新 OTA 成功后递增；普通 Tab 切换不会修改它。 */
  @Prop @Watch('onRefreshGenerationChanged')
  refreshGeneration: number = 0;

  @State @Watch('hostVisibilityChanged') private navigationCovered: boolean = false;
  @State private transitionOpacity: number = 1;
  @State private transitionX: number = 0;
  @State private transitionY: number = 0;
  @State private transitionScale: number = 1;
  private alive: boolean = true;
  @State private isLoading: boolean = true;
  @State private errorMessage: string = '';
  @State private showLynxView: boolean = false;

  private initialized: boolean = false;
  private pendingReload: boolean = false;
  private visible: boolean = false;
  private preparedBundle: PreparedPageBundle | null = null;
  private preparedRuntime: PageBundleRuntime | null = null;
  private rollbackAttempted: boolean = false;
  private recovering: boolean = false;
  private healthGate: LynxOtaHealthGate = new LynxOtaHealthGate(() => false);
  private request: LynxPageRequest = new LynxPageRequest();
  private modules: Map<string, ModuleClassWrapper> = new Map();
  private sendableModules: Map<string, SendableModuleClassWrapper> = new Map();
  private clients: ShellLynxViewClient[] = [];
  private behaviors: BehaviorRegistryMap = XElementRuntime.createBehaviors();
  private templateFetcher: ShellTemplateResourceFetcher =
    new ShellTemplateResourceFetcher(false);
  private genericFetcher: ShellGenericResourceFetcher = new ShellGenericResourceFetcher();
  private mediaFetcher: ShellMediaResourceFetcher = new ShellMediaResourceFetcher();
  private metaData: MetaData = new MetaData(
    new TemplateData('{}'),
    new TemplateData('{}')
  );
  private extraTiming: LynxExtraTiming = new LynxExtraTiming();
  private currentTransitionMetadataKey: string = '';
  private currentBundleMetadata?: ShellBundleMetadata;
  private lynxContext: LynxContext | null = null;
  private prepareGeneration: number = 0;
  private consumedRefreshGeneration: number = 0;
  private releaseLease: OtaBundleLease | null = null;
  private viewWidth: number | string = '100%';
  private viewHeight: number | string = '100%';
  private firstScreenReached: boolean = false;
  private nextLoadKind: 'initial' | 'retry' | 'reload' = 'initial';
  private contextCreated: (context: LynxContext) => void = () => {};
  private readonly userListener: (epoch: number) => void = () => {
    if (this.initialized && this.request.isOtaRequest()) this.reloadFromCurrent();
  };

  aboutToAppear(): void {
    this.visible = this.hostVisible && !this.navigationCovered;
    if (this.lynxContext !== null) HostNativeModules.contextVisibilityChanged(this.lynxContext);
    this.consumedRefreshGeneration = this.refreshGeneration;
    if (this.initialized) {
      if (this.pendingReload) { this.pendingReload = false; this.reloadFromCurrent(); return; }
      this.lynxContext?.onEnterForeground();
      this.clients[0]?.markVisible();
      return;
    }
    this.initialized = true;
    OtaUserContextEvents.subscribe(this.userListener);
    this.modules.set('LynxShellModule', { moduleClass: LynxShellModule });
    HostNativeModules.applyTo(this.modules);
    this.configureForLoad();
    this.startLoad();
  }

  private hostVisibilityChanged(): void {
    this.visible = this.hostVisible && !this.navigationCovered;
    const context = this.lynxContext;
    if (context !== null) {
      if (this.visible) {
        context.onEnterForeground(); this.clients[0]?.markVisible();
        context.sendGlobalEvent('viewAppear', [new ShellViewAppearPayload(this.request.bundleUrl)]);
        ShellMessageHub.sendLifecycle(this.request.entryID, 'active', 'native_tab_visible');
      } else { context.onEnterBackground(); this.clients[0]?.markHidden(); ShellMessageHub.sendLifecycle(this.request.entryID, 'covered', 'native_tab_covered'); }
      HostNativeModules.contextVisibilityChanged(context);
    }
    if (this.visible && this.pendingReload) { this.pendingReload = false; this.reloadFromCurrent(); }
  }

  aboutToDisappear(): void {
    this.visible = false;
    if (this.lynxContext !== null) HostNativeModules.contextVisibilityChanged(this.lynxContext);
    this.lynxContext?.onEnterBackground();
    this.clients[0]?.markHidden();
    if (this.lynxContext !== null) {
      ShellMessageHub.sendLifecycle(this.request.entryID, 'covered', 'arkui_tab_disappear');
    }
  }

  aboutToBeDeleted(): void {
    this.alive = false;
    ShellTransitionRuntime.shared.unbind(this.request.entryID, this.lynxContext ?? undefined);
    OtaUserContextEvents.unsubscribe(this.userListener);
    this.disposeCurrentView('arkui_tab_deleted');
    if (!LynxNavigator.hasSession(this.request.sessionID, this.request.lynxAppId) && !ShellMessageHub.hasContextsForSession(this.request.sessionID, undefined, this.request.lynxAppId)) {
      PageBundleRuntimeRegistry.current()?.releaseNavigationSnapshot(this.request.sessionID, this.request.lynxAppId);
    }
    this.initialized = false;
  }

  private onRefreshGenerationChanged(): void {
    if (this.refreshGeneration === this.consumedRefreshGeneration) return;
    this.consumedRefreshGeneration = this.refreshGeneration;
    if (!this.initialized) return;
    this.reloadFromCurrent();
  }

  private configureForLoad(): void {
    this.currentBundleMetadata = undefined; this.currentTransitionMetadataKey = '';
    this.healthGate.fail();
    this.preparedBundle = null;
    this.preparedRuntime = null;
    const generation = ++this.prepareGeneration;
    this.healthGate = new LynxOtaHealthGate(() => generation === this.prepareGeneration && (!this.request.isOtaRequest() ||
      (this.preparedRuntime === PageBundleRuntimeRegistry.current() && this.preparedBundle?.userIdentityEpoch === this.preparedRuntime?.userIdentityEpoch)));
    let monitorClient: ShellLynxViewClient | null = null;
    this.contextCreated = (context: LynxContext) => {
      if (generation !== this.prepareGeneration || (this.request.isOtaRequest() &&
        (this.preparedRuntime !== PageBundleRuntimeRegistry.current() || this.preparedBundle?.userIdentityEpoch !== this.preparedRuntime?.userIdentityEpoch))) {
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
      // 官方动态 API 设定首值，避免 Tab 首帧继续沿用旧主题。
      context.updateColorScheme(ShellThemeState.colorScheme());
      ShellMessageHub.register({ pageId: this.request.entryID, containerId: this.request.entryID,
        pageKey: this.request.routeKey, hostMode: 'arkui_tab_container', lynxAppId: this.request.lynxAppId, sessionID: this.request.sessionID, hasHostAnchor: this.request.hasHostAnchor, navigationSnapshotID: this.preparedBundle?.navigationSnapshotID }, context);
      ShellMessageHub.bindHealth(this.request.entryID, this.healthGate);
      ShellMessageHub.bindBackGestureEnabled(this.request.entryID, this.request.backGestureEnabled, (enabled: boolean) => { this.request.backGestureEnabled = enabled; });
      ShellMessageHub.bindVisibility(this.request.entryID, () => this.visible);
      monitorClient?.bindContext(context, this.request.entryID);
      this.bindTransitionView(generation);
      if (this.visible) {
        context.onEnterForeground();
        context.sendGlobalEvent('viewAppear', [new ShellViewAppearPayload(this.request.bundleUrl)]);
        ShellMessageHub.sendLifecycle(this.request.entryID, 'active', 'arkui_tab_appear');
      } else { context.onEnterBackground(); }
      const rawScreen = ShellLayoutState.rawScreenSize();
      const layout = ShellLayoutState.snapshot(this.request.entryID);
      context.updateScreenMetrics(rawScreen.width, rawScreen.height);
      context.updateViewport(layout.viewportWidth, 1, layout.viewportHeight, 1);
      context.setExtraTiming(this.extraTiming);
    };
    this.firstScreenReached = false;
    this.request = this.makeRequest();
    this.metaData = new MetaData(
      new TemplateData(this.request.initDataJson),
      new TemplateData(this.buildTabGlobalProps())
    );
    monitorClient = new ShellLynxViewClient(
      () => { if (generation === this.prepareGeneration) this.handleLoadSuccess(); },
      (failure: ShellLynxLoadFailure) => { if (generation === this.prepareGeneration) this.handleLoadError(failure); },
      () => { if (generation === this.prepareGeneration) this.handleFirstScreen(); },
      'tab',
      this.contextCreated
    );
    monitorClient.setLoadKind(this.nextLoadKind);
    this.clients = [monitorClient];
    this.bindTransitionView(generation);
    this.templateFetcher = new ShellTemplateResourceFetcher(false);
    this.genericFetcher = new ShellGenericResourceFetcher();
    this.mediaFetcher = new ShellMediaResourceFetcher();
    this.extraTiming = new LynxExtraTiming();
    this.viewWidth = '100%';
    this.viewHeight = '100%';
    const density = display.getDefaultDisplaySync().densityPixels;
    if (this.request.widthPx > 0) this.viewWidth = this.request.widthPx / density;
    if (this.request.heightPx > 0) this.viewHeight = this.request.heightPx / density;

    const now = new Date().getTime();
    this.extraTiming.openTime = now;
    this.extraTiming.containerInitStart = now;
    this.extraTiming.containerInitEnd = new Date().getTime();
    this.extraTiming.prepareTemplateStart = new Date().getTime();
    this.isLoading = true;
    this.errorMessage = '';
    this.showLynxView = false;
    LLog.d(ShellConstants.TAG, `created native Tab container ${this.request.entryID}`);
  }

  private startLoad(): void {
    if (this.request.isOtaRequest()) {
      this.resolveOtaCurrent();
      return;
    }
    const monitorClient = this.clients[0];
    const generation = this.prepareGeneration;
    const bundleUrl = this.request.bundleUrl;
    this.templateFetcher.cancelAll();
    this.templateFetcher = new ShellTemplateResourceFetcher(false, '', '', '', null, undefined,
      bundleUrl, monitorClient?.monitoringEnabled === true ? (sha256: string | null) => {
        if (generation === this.prepareGeneration) monitorClient.setDirectBundle(bundleUrl, sha256);
      } : undefined);
    this.extraTiming.prepareTemplateEnd = new Date().getTime();
    this.clients[0]?.markBundleUnavailable('direct_bundle_identity_unavailable', this.request.bundleUrl);
    this.clients[0]?.markLoadStarted();
    this.showLynxView = true;
  }

  private reloadFromCurrent(): void {
    if (!this.visible) { this.pendingReload = true; this.healthGate.fail('Tab 待可见时重新加载'); return; }
    PageBundleRuntimeRegistry.current()?.resetNavigationSnapshot(this.request.sessionID, this.request.lynxAppId);
    this.disposeCurrentView('arkui_tab_explicit_refresh');
    this.nextLoadKind = 'reload';
    this.configureForLoad();
    const generation = this.prepareGeneration;
    setTimeout(() => { if (generation === this.prepareGeneration) this.startLoad(); }, 0);
  }

  private disposeCurrentView(reason: string): void {
    ShellTransitionRuntime.shared.unbind(this.request.entryID, this.lynxContext ?? undefined);
    this.healthGate.fail();
    this.prepareGeneration += 1;
    this.templateFetcher.cancelAll();
    this.genericFetcher.cancelAll();
    this.clients[0]?.markDestroyed(reason);
    if (this.lynxContext !== null) {
      this.lynxContext.onEnterBackground();
      ShellMessageHub.sendLifecycle(this.request.entryID, 'destroyed', reason);
      HostNativeModules.destroyForContext(this.lynxContext);
    }
    if (this.lynxContext !== null) ShellMessageHub.unregisterContext(this.request.entryID, this.lynxContext);
    this.lynxContext = null;
    this.showLynxView = false;
    this.releaseCurrentLease();
  }

  private buildTabGlobalProps(bundleMetadata?: ShellBundleMetadata,
    localeState?: ShellLocaleStateValue): Object {
    const props = ShellGlobalPropsFactory.build(
      this.request.globalPropsJson,
      this.request,
      bundleMetadata,
      localeState
    ) as Record<string, Object>;
    props['__lynxRouterNavigationModel'] = 'native_tab_host';
    props['__lynxRouterPlatformContainer'] = 'arkui_tab_container';
    return props;
  }

  private makeRequest(): LynxPageRequest {
    const request = new LynxPageRequest();
    request.bundleUrl = this.spec.bundleUrl;
    request.lynxAppId = this.spec.lynxAppId;
    request.bundleName = this.spec.bundleName;
    request.routeKey = this.spec.routeKey;
    request.sessionID = 'native-tab-host';
    request.entryID = `lynx-tab-${this.spec.tabId}-${this.refreshGeneration}-${new Date().getTime()}`;
    request.hasHostAnchor = false;
    request.title = this.spec.title;
    request.initDataJson = this.spec.initDataJson;
    request.globalPropsJson = this.spec.globalPropsJson;
    request.backGestureEnabled = this.request.backGestureEnabled;
    request.hideNavigationBar = true;
    request.fullscreen = true;
    request.backgroundColor = this.spec.backgroundColor;
    return request;
  }

  /** 严格 cache-only：只消费已提交 current，缺失时不自动 repair。 */
  private resolveOtaCurrent(): void {
    const runtime: PageBundleRuntime | null = PageBundleRuntimeRegistry.current();
    if (runtime === null) {
      this.isLoading = false;
      this.errorMessage = '当前没有安装 HarmonyOS OTA runtime';
      return;
    }
    const generation = this.prepareGeneration;
    const epoch = runtime.userIdentityEpoch;
    let pendingLease: OtaBundleLease | null = null;
    this.isLoading = true;
    this.errorMessage = '';
    runtime.resolveCurrent(this.request.lynxAppId, this.request.bundleName, this.request.sessionID)
      .then((prepared) => {
        pendingLease = prepared?.lease ?? null;
        if (generation !== this.prepareGeneration || runtime !== PageBundleRuntimeRegistry.current() || epoch !== runtime.userIdentityEpoch ||
          (prepared?.userIdentityEpoch !== undefined && prepared.userIdentityEpoch !== epoch)) {
          pendingLease?.close();
          pendingLease = null;
          return;
        }
        if (prepared === null) {
          this.isLoading = false;
          this.errorMessage = `Tab ${this.spec.tabId} 没有 active Bundle；切换 Tab 不联网`;
          return;
        }
        this.preparedBundle = prepared;
        this.preparedRuntime = runtime;
        this.healthGate.configure(runtime, prepared);
        this.templateFetcher.cancelAll();
        this.templateFetcher = new ShellTemplateResourceFetcher(
          false,
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
          source: prepared.source ?? 'ota_current',
          loadPolicy: 'cache_only',
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
          new TemplateData(this.buildTabGlobalProps(bundleMetadata, localeState))
        );
        this.clients[0]?.setPreparedBundle(
          prepared.source ?? 'ota_current', prepared.lynxAppId, prepared.bundleName,
          prepared.releaseId, prepared.releaseSequence ?? null, prepared.sha256,
          prepared.env ?? null, prepared.hostApp ?? null, prepared.bundlePath ?? null
        );
        this.clients[0]?.markLoadResolved(null);
        this.clients[0]?.markLoadStarted();
        this.extraTiming.prepareTemplateEnd = new Date().getTime();
        console.info(`[${ShellConstants.TAG}] tab prepared ${prepared.lynxAppId}/${prepared.bundleName}, release=${prepared.releaseId}, manifest=${prepared.manifestId ?? 'embedded'}, snapshot=${prepared.navigationSnapshotID ?? 'none'}`);
        this.releaseCurrentLease();
        this.releaseLease = prepared.lease ?? null;
        pendingLease = null;
        // 保留 Loading 到 LynxView load success/first screen，避免 template 已解析但首帧未出时白闪。
        this.isLoading = true;
        this.showLynxView = true;
      })
      .catch((error: Error) => {
        pendingLease?.close();
        pendingLease = null;
        if (generation !== this.prepareGeneration || runtime !== PageBundleRuntimeRegistry.current() || epoch !== runtime.userIdentityEpoch) return;
        this.isLoading = false;
        this.errorMessage = `Tab active Bundle 读取失败：${error.message}`;
      });
  }

  private handleLoadSuccess(): void {
    // 首帧仅消费 SDK onFirstScreen。
  }

  private handleFirstScreen(): void {
    this.firstScreenReached = true;
    ShellTransitionRuntime.shared.firstScreen(this.request.entryID);
    this.healthGate.markFirstScreen();
    this.isLoading = false;
  }

  private handleLoadError(failure: ShellLynxLoadFailure): void {
    if (!failure.requiresErrorState()) return;
    const prepared = this.preparedBundle;
    const runtime = this.preparedRuntime;
    const candidate = this.healthGate.isCandidateTrial();
    const canRecover = prepared !== null && runtime !== null && runtime === PageBundleRuntimeRegistry.current() &&
      prepared.userIdentityEpoch === runtime.userIdentityEpoch && (candidate || !this.firstScreenReached) && !this.rollbackAttempted && !this.recovering;
    this.healthGate.fail('Tab 发生终止性加载错误');
    if (canRecover && prepared !== null && runtime !== null) {
      this.rollbackAttempted = true; this.recovering = true;
      this.disposeCurrentView('arkui_tab_ota_recovery');
      const generation = this.prepareGeneration;
      runtime.recoverFailedRelease(prepared.lynxAppId, failure.message, prepared.releaseId, prepared.userIdentityEpoch,
        this.request.sessionID, prepared.navigationSnapshotID ?? '', candidate).then((restored: boolean) => {
        if (generation !== this.prepareGeneration || runtime !== PageBundleRuntimeRegistry.current() || prepared.userIdentityEpoch !== runtime.userIdentityEpoch) return;
        this.recovering = false;
        if (!restored) { this.isLoading = false; this.errorMessage = `${failure.message}；没有可恢复的稳定版本`; return; }
        if (!this.visible) { this.pendingReload = true; return; }
        this.configureForLoad(); this.startLoad();
      }).catch((error: Error) => {
        if (generation !== this.prepareGeneration) return;
        this.recovering = false; this.isLoading = false; this.errorMessage = `Tab 恢复失败：${error.message}`;
      });
      return;
    }
    this.clients[0]?.markLoadFailed('lynx_load_error');
    this.disposeCurrentView('arkui_tab_load_failed');
    this.isLoading = false;
    this.errorMessage = failure.message.length > 0 ? failure.message : 'Lynx Tab 加载失败';
  }

  private releaseCurrentLease(): void {
    const lease = this.releaseLease;
    this.releaseLease = null;
    lease?.close();
  }

  private bindTransitionView(generation: number): void {
    ShellTransitionRuntime.shared.bind({ entryID: this.request.entryID, viewID: this.request.entryID, context: this.lynxContext ?? undefined,
      ui: this.getUIContext(), holderID: `lynx-tab-body-${this.request.entryID}`, sessionID: this.request.sessionID,
      applyWindowPolicy: () => { if (this.alive && generation === this.prepareGeneration) ShellWindowController.restore(); }, rootContent: true, setCovered: (covered: boolean) => { if (this.alive && generation === this.prepareGeneration) this.navigationCovered = covered; },
      presentationSpec: this.request.presentationSpec(), updateTransition: (id: string) => {
        if (!this.alive || generation !== this.prepareGeneration || this.lynxContext === null) return;
        const state = ShellTransitionRuntime.shared.currentState();
        const key = `${id}:${state.effectiveTransition}:${state.direction}:${state.reason}`;
        if (key === this.currentTransitionMetadataKey) return;
        this.currentTransitionMetadataKey = key; this.request.transitionID = id;
        this.lynxContext.updateMetaData(new MetaData(undefined, new TemplateData(this.buildTabGlobalProps(this.currentBundleMetadata))));
      },
      loadGeneration: generation, identityEpoch: this.preparedBundle?.userIdentityEpoch, backgroundColor: this.request.backgroundColor, firstScreen: this.firstScreenReached,
      isActive: () => this.alive && generation === this.prepareGeneration,
      getPresentation: () => ({ x: this.transitionX, y: this.transitionY, scale: this.transitionScale }),
      setPresentation: (value) => { if (this.alive && generation === this.prepareGeneration) { this.transitionX = value.x; this.transitionY = value.y; this.transitionScale = value.scale; } },
      getOpacity: () => this.transitionOpacity, setOpacity: (value: number) => { if (this.alive && generation === this.prepareGeneration) this.transitionOpacity = value; } });
  }

  /** 外层 ArkUI 区域是当前 Native Tab 的 viewport；切换 Tab 不会重建或联网。 */
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

  private retry(): void {
    this.reloadFromCurrent();
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
            Text('Tab 页面加载失败')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor('#111827')
            Text(this.errorMessage)
              .fontSize(13)
              .fontColor('#6B7280')
              .textAlign(TextAlign.Center)
              .maxLines(6)
            Button('重新读取 active Bundle')
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
            Text('正在读取 Tab active Bundle…')
              .fontSize(14)
              .fontColor('#6B7280')
          }
          .padding(22)
          .backgroundColor('#FFFFFF')
          .borderRadius(16)
        }
      }
      .id(`lynx-tab-body-${this.request.entryID}`)
      .opacity(this.transitionOpacity)
      .translate({ x: this.transitionX, y: this.transitionY })
      .scale({ x: this.transitionScale, y: this.transitionScale })
      .width('100%')
      .layoutWeight(1)
      .onAreaChange((oldValue: Area, newValue: Area) => this.onAreaChanged(newValue))
      .backgroundColor(this.request.backgroundColor)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.request.backgroundColor)
  }
}
