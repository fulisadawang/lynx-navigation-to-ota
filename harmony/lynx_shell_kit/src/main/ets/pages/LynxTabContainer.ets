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
import ShellLynxViewClient from '../client/ShellLynxViewClient';
import ShellConstants from '../common/ShellConstants';
import ShellGlobalPropsFactory, { ShellBundleMetadata } from '../common/ShellGlobalPropsFactory';
import { ShellViewAppearPayload } from '../common/ShellTypes';
import XElementRuntime from '../common/XElementRuntime';
import LynxPageRequest from '../model/LynxPageRequest';
import { LynxShellModule } from '../module/LynxShellModule';
import ShellMessageHub from '../common/ShellMessageHub';
import ShellGenericResourceFetcher from '../provider/ShellGenericResourceFetcher';
import ShellMediaResourceFetcher from '../provider/ShellMediaResourceFetcher';
import ShellTemplateResourceFetcher from '../provider/ShellTemplateResourceFetcher';
import PageBundleRuntimeRegistry, { OtaBundleLease, PageBundleRuntime } from '../ota/OtaModels';

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

  @State private isLoading: boolean = true;
  @State private errorMessage: string = '';
  @State private showLynxView: boolean = false;

  private initialized: boolean = false;
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
  private lynxContext: LynxContext | null = null;
  private prepareGeneration: number = 0;
  private consumedRefreshGeneration: number = 0;
  private releaseLease: OtaBundleLease | null = null;
  private viewWidth: number | string = '100%';
  private viewHeight: number | string = '100%';

  aboutToAppear(): void {
    this.consumedRefreshGeneration = this.refreshGeneration;
    if (this.initialized) {
      this.lynxContext?.onEnterForeground();
      return;
    }
    this.initialized = true;
    this.modules.set('LynxShellModule', { moduleClass: LynxShellModule });
    this.configureForLoad();
    this.startLoad();
  }

  aboutToDisappear(): void {
    this.lynxContext?.onEnterBackground();
    if (this.lynxContext !== null) {
      ShellMessageHub.sendLifecycle(this.request.entryID, 'covered', 'arkui_tab_disappear');
    }
  }

  aboutToBeDeleted(): void {
    this.disposeCurrentView('arkui_tab_deleted');
    this.initialized = false;
  }

  private onRefreshGenerationChanged(): void {
    if (this.refreshGeneration === this.consumedRefreshGeneration) return;
    this.consumedRefreshGeneration = this.refreshGeneration;
    if (!this.initialized) return;
    this.reloadFromCurrent();
  }

  private configureForLoad(): void {
    this.request = this.makeRequest();
    this.metaData = new MetaData(
      new TemplateData(this.request.initDataJson),
      new TemplateData(this.buildTabGlobalProps())
    );
    this.clients = [new ShellLynxViewClient(
      () => this.handleLoadSuccess(),
      (message: string) => this.handleLoadError(message),
      () => this.handleFirstScreen()
    )];
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
    this.extraTiming.prepareTemplateEnd = new Date().getTime();
    this.showLynxView = true;
  }

  private reloadFromCurrent(): void {
    this.disposeCurrentView('arkui_tab_explicit_refresh');
    this.configureForLoad();
    setTimeout(() => this.startLoad(), 0);
  }

  private disposeCurrentView(reason: string): void {
    this.prepareGeneration += 1;
    this.templateFetcher.cancelAll();
    this.genericFetcher.cancelAll();
    if (this.lynxContext !== null) {
      this.lynxContext.onEnterBackground();
      ShellMessageHub.sendLifecycle(this.request.entryID, 'destroyed', reason);
    }
    ShellMessageHub.unregister(this.request.entryID);
    this.lynxContext = null;
    this.showLynxView = false;
    this.releaseCurrentLease();
  }

  private buildTabGlobalProps(bundleMetadata?: ShellBundleMetadata): Object {
    const props = ShellGlobalPropsFactory.build(
      this.request.globalPropsJson,
      this.request,
      bundleMetadata
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
    const generation = ++this.prepareGeneration;
    let pendingLease: OtaBundleLease | null = null;
    this.isLoading = true;
    this.errorMessage = '';
    runtime.resolveCurrent(this.request.lynxAppId, this.request.bundleName)
      .then((prepared) => {
        pendingLease = prepared?.lease ?? null;
        if (generation !== this.prepareGeneration) {
          pendingLease?.close();
          pendingLease = null;
          return;
        }
        if (prepared === null) {
          this.isLoading = false;
          this.errorMessage = `Tab ${this.spec.tabId} 没有 active Bundle；切换 Tab 不联网`;
          return;
        }
        this.templateFetcher.cancelAll();
        this.templateFetcher = new ShellTemplateResourceFetcher(
          false,
          this.request.bundleUrl,
          prepared.filePath,
          runtime.storageRoot(),
          prepared.bytes ?? null
        );
        const bundleMetadata: ShellBundleMetadata = {
          lynxAppId: prepared.lynxAppId,
          releaseId: prepared.releaseId,
          source: prepared.source ?? 'ota_current',
          loadPolicy: 'cache_only',
          bundleName: prepared.bundleName,
          sha256: prepared.sha256
        };
        this.metaData = new MetaData(
          new TemplateData(this.request.initDataJson),
          new TemplateData(this.buildTabGlobalProps(bundleMetadata))
        );
        this.extraTiming.prepareTemplateEnd = new Date().getTime();
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
        if (generation !== this.prepareGeneration) return;
        this.isLoading = false;
        this.errorMessage = `Tab active Bundle 读取失败：${error.message}`;
      });
  }

  private handleLoadSuccess(): void {
    this.isLoading = false;
    this.errorMessage = '';
  }

  private handleFirstScreen(): void {
    this.isLoading = false;
  }

  private handleLoadError(message: string): void {
    this.disposeCurrentView('arkui_tab_load_failed');
    this.isLoading = false;
    this.errorMessage = message.length > 0 ? message : 'Lynx Tab 加载失败';
  }

  private releaseCurrentLease(): void {
    if (this.releaseLease === null) return;
    const lease = this.releaseLease;
    this.releaseLease = null;
    lease.close();
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
            onCreate: (context: LynxContext) => {
              this.lynxContext = context;
              ShellMessageHub.register({
                pageId: this.request.entryID,
                containerId: this.request.entryID,
                pageKey: this.request.routeKey,
                hostMode: 'arkui_tab_container'
              }, context);
              context.onEnterForeground();
              context.sendGlobalEvent('viewAppear', [new ShellViewAppearPayload(this.request.bundleUrl)]);
              ShellMessageHub.sendLifecycle(this.request.entryID, 'active', 'arkui_tab_appear');
              context.setExtraTiming(this.extraTiming);
            }
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
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(this.request.backgroundColor)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.request.backgroundColor)
  }
}
