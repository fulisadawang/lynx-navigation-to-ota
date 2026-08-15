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
import ShellLynxViewClient from '../client/ShellLynxViewClient';
import ShellConstants from '../common/ShellConstants';
import ShellGlobalPropsFactory from '../common/ShellGlobalPropsFactory';
import { ShellViewAppearPayload } from '../common/ShellTypes';
import ShellWindowController from '../common/ShellWindowController';
import XElementRuntime from '../common/XElementRuntime';
import LynxPageRequest from '../model/LynxPageRequest';
import { LynxShellModule } from '../module/LynxShellModule';
import LynxNavigator from '../routing/LynxNavigator';
import ShellMessageHub from '../common/ShellMessageHub';
import ShellGenericResourceFetcher from '../provider/ShellGenericResourceFetcher';
import ShellMediaResourceFetcher from '../provider/ShellMediaResourceFetcher';
import ShellTemplateResourceFetcher from '../provider/ShellTemplateResourceFetcher';
import PageBundleRuntimeRegistry, {
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
  @State private isLoading: boolean = true;
  @State private errorMessage: string = '';
  @State private showLynxView: boolean = false;

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
  private lynxContext: LynxContext | null = null;
  private prepareSignal: OtaPrepareSignal = new OtaPrepareSignal();
  private prepareGeneration: number = 0;
  private preparing: boolean = false;
  private rollbackAttempted: boolean = false;
  private rollbackInProgress: boolean = false;
  private viewWidth: number | string = '100%';
  private viewHeight: number | string = '100%';

  aboutToAppear(): void {
    LynxNavigator.register(this.request);
    // 页面级 keyboardBehavior 在 Window/UIContext 层生效；LynxView 不需要重复计算键盘高度。
    ShellWindowController.apply(this.request);

    // 被下一页覆盖时保留 LynxView 和 LynxContext；返回当前 Page 后恢复前台事件。
    // 首次创建仍由 LynxView.onCreate 完成 register/viewAppear，避免重复注册。
    if (this.lynxContext !== null) {
      this.lynxContext.onEnterForeground();
      this.lynxContext.sendGlobalEvent('viewAppear', [new ShellViewAppearPayload(this.request.bundleUrl)]);
      ShellMessageHub.sendLifecycle(this.request.entryID, 'active', 'arkui_page_appear');
      return;
    }

    this.modules.set('LynxShellModule', { moduleClass: LynxShellModule });
    LLog.d(ShellConstants.TAG, 'registered LynxShellModule with full Harmony bridge contract');
    this.clients = [new ShellLynxViewClient(
      (url: string) => this.handleLoadSuccess(url),
      (message: string) => this.handleLoadError(message),
      () => this.handleFirstScreen()
    )];

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
      this.extraTiming.prepareTemplateEnd = new Date().getTime();
      this.showLynxView = true;
    }
  }

  aboutToDisappear(): void {
    const disappearingContext = this.lynxContext;
    if (disappearingContext !== null) {
      disappearingContext.onEnterBackground();
      // aboutToDisappear 既可能表示被下一页覆盖，也可能表示从 NavPathStack 移除；先
      // 发 covered，下一轮根据逻辑栈是否还存在来决定是否真正销毁。被覆盖时
      // 不能取消 Provider 请求或丢弃 Context，否则返回后页面无法恢复。
      ShellMessageHub.sendLifecycle(this.request.entryID, 'covered', 'arkui_page_disappear');
    }
    // 下载阶段还没有 LynxContext，也必须在 Page 真正移除后取消 prepare；被下一页覆盖则保留。
    setTimeout(() => {
      if (LynxNavigator.hasEntry(this.request.entryID)) {
        return;
      }
      ShellMessageHub.sendLifecycle(this.request.entryID, 'destroyed', 'arkui_page_removed');
      ShellMessageHub.unregister(this.request.entryID);
      this.cancelPendingRequests();
      if (this.lynxContext === disappearingContext) {
        this.lynxContext = null;
      }
    }, 0);
    ShellWindowController.restore();
  }

  onBackPress(): boolean {
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
    this.isLoading = false;
    this.errorMessage = '';
  }

  private handleFirstScreen(): void {
    this.isLoading = false;
  }

  private handleLoadError(message: string): void {
    if (this.request.isOtaRequest() && !this.rollbackAttempted && !this.rollbackInProgress) {
      this.attemptRollback(message.length > 0 ? message : 'Lynx 首屏加载失败');
      return;
    }
    this.isLoading = false;
    this.errorMessage = message.length > 0 ? message : 'Lynx 页面加载失败';
  }

  private retry(): void {
    this.cancelPendingRequests();
    this.isLoading = true;
    this.errorMessage = '';
    this.showLynxView = false;
    if (this.request.isOtaRequest()) {
      // 用户主动重试会重新检查 current/repair，但一次页面生命周期内仍不重复自动回滚。
      this.prepareOtaBundle();
      return;
    }
    setTimeout(() => {
      this.showLynxView = true;
    }, 0);
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
    this.isLoading = true;
    this.errorMessage = '';
    this.showLynxView = false;
    this.prepareSignal.cancel();
    this.prepareSignal = new OtaPrepareSignal();
    const signal = this.prepareSignal;
    const generation = ++this.prepareGeneration;
    runtime.prepare(this.request.lynxAppId, this.request.bundleName, signal)
      .then((prepared: PreparedPageBundle) => {
        if (signal.cancelled || generation !== this.prepareGeneration ||
          !LynxNavigator.hasEntry(this.request.entryID)) {
          return;
        }
        this.templateFetcher.cancelAll();
        this.templateFetcher = new ShellTemplateResourceFetcher(
          this.request.allowHttpInDebug,
          this.request.bundleUrl,
          prepared.filePath,
          runtime.storageRoot()
        );
        this.extraTiming.prepareTemplateEnd = new Date().getTime();
        this.preparing = false;
        this.showLynxView = true;
      })
      .catch((error: Error) => {
        if (signal.cancelled || generation !== this.prepareGeneration) {
          return;
        }
        this.preparing = false;
        this.isLoading = false;
        this.errorMessage = `OTA Bundle 准备失败：${error.message}`;
      });
  }

  /** 首屏失败时按 appId 自动回滚一次；回滚成功后重新 prepare，第二次失败直接进入错误页。 */
  private attemptRollback(reason: string): void {
    const runtime: PageBundleRuntime | null = PageBundleRuntimeRegistry.current();
    if (runtime === null) {
      this.isLoading = false;
      this.errorMessage = reason;
      return;
    }
    this.rollbackAttempted = true;
    this.rollbackInProgress = true;
    this.isLoading = true;
    this.errorMessage = '';
    this.showLynxView = false;
    this.cancelViewResources();
    runtime.rollback(this.request.lynxAppId, reason)
      .then((restored: boolean) => {
        this.rollbackInProgress = false;
        if (!restored) {
          this.isLoading = false;
          this.errorMessage = `${reason}；没有可回滚的上一版本`;
          return;
        }
        this.prepareOtaBundle();
      })
      .catch((error: Error) => {
        this.rollbackInProgress = false;
        this.isLoading = false;
        this.errorMessage = `${reason}；回滚失败：${error.message}`;
      });
  }

  /** 避免旧页面请求在新页面/重试后继续回调。 */
  private cancelPendingRequests(): void {
    this.prepareSignal.cancel();
    this.prepareGeneration += 1;
    this.preparing = false;
    this.templateFetcher.cancelAll();
    this.genericFetcher.cancelAll();
  }

  private cancelViewResources(): void {
    this.templateFetcher.cancelAll();
    this.genericFetcher.cancelAll();
    if (this.lynxContext !== null) {
      ShellMessageHub.unregister(this.request.entryID);
      this.lynxContext = null;
    }
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
                pageKey: this.request.routeKey.length > 0 ? this.request.routeKey : this.request.bundleUrl,
                hostMode: 'arkui_page'
              }, context);
              context.onEnterForeground();
              context.sendGlobalEvent('viewAppear', [new ShellViewAppearPayload(this.request.bundleUrl)]);
              ShellMessageHub.sendLifecycle(this.request.entryID, 'active', 'arkui_page_appear');
              if (this.request.widthPx > 0 && this.request.heightPx > 0) {
                context.updateScreenMetrics(this.request.widthPx, this.request.heightPx);
              }
              context.setExtraTiming(this.extraTiming);
            }
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
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(this.request.backgroundColor)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.request.backgroundColor)
  }

}
