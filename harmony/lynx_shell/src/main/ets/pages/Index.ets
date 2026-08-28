import router from '@ohos.router';
import {
  ShellConstants,
  LynxRouter,
  LynxTabContainer,
  LynxTabSpec
} from '@lynx/lynx-shell-kit';

/**
 * 原生 ArkUI 启动页。
 * 它既可以作为开发调试入口，也负责消费 Ability 收到的外部深链。
 */
@Entry
@Component
struct Index {
  @State private errorMessage: string = '';
  @State private isOpening: boolean = false;
  @State private otaStatusMessage: string = '';
  @State private showNativeTabDemo: boolean = false;
  @State private selectedNativeTab: number = 0;
  @State private isRefreshingOta: boolean = false;
  @State private tabStatusMessage: string = '';
  @State private tabReloadGeneration: number = 0;
  @State private tabLynxAppId: string = '';
  @State private tabBundleName: string = '';

  @StorageLink('lynx_initial_uri')
  private initialUri: string = '';

  @StorageLink('lynx_initial_uri_version')
  @Watch('onInitialUriVersionChanged')
  private initialUriVersion: number = 0;

  private consumedInitialVersion: number = -1;
  private hasRequestedDefaultHome: boolean = false;
  private readonly otaTestAppId: string = '10000001';
  private readonly otaHomeBundleName: string = 'home.lynx.bundle';
  private readonly playgroundBundleName: string = 'main.lynx.bundle';

  aboutToAppear(): void {
    this.prepareTabIdentity(false);
    if (!this.consumeInitialRoute()) {
      this.openDefaultOtaHome();
    }
  }

  private onInitialUriVersionChanged(): void {
    this.consumeInitialRoute();
  }

  private consumeInitialRoute(): boolean {
    if (this.consumedInitialVersion === this.initialUriVersion) {
      return this.initialUri.trim().length > 0;
    }
    this.consumedInitialVersion = this.initialUriVersion;
    const route = this.initialUri.trim();
    if (route.length === 0) {
      return false;
    }
    this.hasRequestedDefaultHome = true;
    this.openRoute(route);
    return true;
  }

  private openDefaultOtaHome(): void {
    if (this.hasRequestedDefaultHome) return;
    this.hasRequestedDefaultHome = true;
    // 让原生 Index 先完成首轮 build，再提交默认 OTA Page；返回时仍能回到这个宿主页锚点。
    setTimeout(() => this.openOtaHome(), 0);
  }

  private openRoute(route: string): void {
    if (this.isOpening) {
      return;
    }
    this.errorMessage = '';
    this.isOpening = true;
    LynxRouter.open(route).then((result) => {
      if (result.code !== 0) {
        this.errorMessage = result.message;
      }
    }).catch((error: Error) => {
      this.errorMessage = `打开失败: ${error.message}`;
      console.error(`[${ShellConstants.TAG}] ${this.errorMessage}`);
    }).finally(() => {
      this.isOpening = false;
    });
  }

  private openOtaHome(): void {
    if (this.isOpening) {
      return;
    }
    this.isOpening = true;
    this.otaStatusMessage = `正在打开 ${this.otaTestAppId}/${this.otaHomeBundleName}…`;
    const params: Record<string, Object> = {};
    params['source'] = 'harmony-ota-acceptance-home';
    params['acceptance'] = true;
    const options: Record<string, Object> = {};
    options['title'] = 'OTA 验收首页';
    options['fullscreen'] = true;
    options['showNavigationBar'] = false;
    LynxRouter.openEmbedded(
      this.otaHomeBundleName,
      params,
      options,
      this.otaTestAppId
    ).then((result) => {
      this.otaStatusMessage = result.code === 0 ? '已打开 OTA 验收首页' : result.message;
    }).catch((error: Error) => {
      this.otaStatusMessage = `打开 OTA 页面失败：${error.message}`;
    }).finally(() => {
      this.isOpening = false;
    });
  }

  private openPlaygroundHome(): void {
    if (this.isOpening) {
      return;
    }
    this.isOpening = true;
    this.otaStatusMessage = `正在打开 ${this.otaTestAppId}/${this.playgroundBundleName}…`;
    const params: Record<string, Object> = {};
    params['source'] = 'harmony-playground-ota-home';
    const options: Record<string, Object> = {};
    options['title'] = 'Playground OTA 首页';
    options['fullscreen'] = true;
    options['showNavigationBar'] = false;
    LynxRouter.openEmbedded(
      this.playgroundBundleName,
      params,
      options,
      this.otaTestAppId
    ).then((result) => {
      this.otaStatusMessage = result.code === 0 ? '已打开 Playground OTA 首页' : result.message;
    }).catch((error: Error) => {
      this.otaStatusMessage = `打开 Playground 首页失败：${error.message}`;
    }).finally(() => {
      this.isOpening = false;
    });
  }

  private prepareTabIdentity(showWhenReady: boolean): void {
    if (this.tabLynxAppId.length > 0 && this.tabBundleName.length > 0) {
      if (showWhenReady) {
        this.selectedNativeTab = 0;
        this.tabStatusMessage = '';
        this.showNativeTabDemo = true;
      }
      return;
    }
    this.otaStatusMessage = `正在解析 ${this.otaTestAppId}/${this.playgroundBundleName} 的 Manifest 身份…`;
    LynxRouter.embeddedIdentity(this.playgroundBundleName, this.otaTestAppId)
      .then((identity) => {
        if (identity === null) {
          this.otaStatusMessage = `内置 Manifest 没有找到 ${this.otaTestAppId}/${this.playgroundBundleName}`;
          return;
        }
        this.tabLynxAppId = identity.lynxAppId;
        this.tabBundleName = identity.bundleName;
        this.otaStatusMessage = `Tab 已绑定 ${identity.lynxAppId}/${identity.bundleName}`;
        if (showWhenReady) {
          this.selectedNativeTab = 0;
          this.tabStatusMessage = '';
          this.showNativeTabDemo = true;
        }
      })
      .catch((error: Error) => {
        this.otaStatusMessage = `Tab Manifest 身份解析失败：${error.message}`;
      });
  }

  private openNativeTabDemo(): void {
    this.prepareTabIdentity(true);
  }

  /** 原生只读 Inspector 作为独立 Page 推入，保留下方 Native Tab 的活体 lease。 */
  private openStorageInspector(): void {
    router.pushUrl({ url: 'pages/OtaStorageInspector' }).catch((error: Error) => {
      this.otaStatusMessage = `打开 OTA 磁盘浏览器失败：${error.message}`;
    });
  }

  private refreshNativeTabs(): void {
    if (this.isRefreshingOta) return;
    this.isRefreshingOta = true;
    this.tabStatusMessage = '正在同步全部 OTA Bundle…';
    LynxRouter.refreshAllOtaBundles()
      .then((success: boolean) => {
        if (success) {
          this.tabReloadGeneration += 1;
          this.tabStatusMessage = 'OTA 同步完成，Home/Settings 已重新读取 current';
        } else {
          this.tabStatusMessage = 'OTA 同步失败，保留当前 Tab 版本';
        }
      })
      .catch((error: Error) => {
        this.tabStatusMessage = `OTA 同步失败，保留当前 Tab 版本：${error.message}`;
      })
      .finally(() => {
        this.isRefreshingOta = false;
      });
  }

  private syncAllOtaBundles(): void {
    if (this.isRefreshingOta) return;
    this.isRefreshingOta = true;
    this.otaStatusMessage = '正在执行原生全量 OTA 同步…';
    LynxRouter.refreshAllOtaBundles()
      .then((success: boolean) => {
        this.otaStatusMessage = success ? '全量 OTA 同步完成' : '全量 OTA 同步失败，保留本地版本';
      })
      .catch((error: Error) => {
        this.otaStatusMessage = `全量 OTA 同步失败：${error.message}`;
      })
      .finally(() => {
        this.isRefreshingOta = false;
      });
  }

  private deleteAllOtaBundles(): void {
    this.otaStatusMessage = '正在删除全部 OTA Bundle…';
    LynxRouter.deleteAllOtaBundles().then((result) => {
      this.otaStatusMessage = result.message;
    }).catch((error: Error) => {
      this.otaStatusMessage = `删除失败：${error.message}`;
    });
  }

  private tabSpec(tabId: string, title: string): LynxTabSpec {
    return {
      tabId: tabId,
      bundleUrl: `assets://${ShellConstants.DEFAULT_LOCAL_BUNDLE}`,
      title: title,
      routeKey: `native-tab-${tabId}`,
      initDataJson: '{"source":"harmony-native-tab-demo"}',
      globalPropsJson: `{"queryItems":{"native_tab_id":"${tabId}"}}`,
      lynxAppId: this.tabLynxAppId,
      bundleName: this.tabBundleName,
      backgroundColor: '#FFFFFF'
    };
  }

  build() {
    if (this.showNativeTabDemo) {
      Column() {
        Row() {
          Button('返回原生壳首页')
            .height(44)
            .fontSize(14)
            .fontColor($r('app.color.shell_text_primary'))
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: $r('app.color.shell_brand') })
            .borderRadius(12)
            .onClick(() => this.showNativeTabDemo = false)

          Blank()

          Button('磁盘')
            .height(44)
            .fontSize(14)
            .fontColor($r('app.color.shell_text_primary'))
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: $r('app.color.shell_brand') })
            .borderRadius(12)
            .onClick(() => this.openStorageInspector())

          Button(this.isRefreshingOta ? '正在同步 OTA…' : '刷新 OTA')
            .height(44)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .backgroundColor($r('app.color.shell_brand'))
            .borderRadius(12)
            .enabled(!this.isRefreshingOta)
            .onClick(() => this.refreshNativeTabs())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        if (this.tabStatusMessage.length > 0) {
          Text(this.tabStatusMessage)
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 8 })
            .fontSize(12)
            .fontColor($r('app.color.shell_text_secondary'))
        }

        Tabs({
          barPosition: BarPosition.End,
          index: this.selectedNativeTab
        }) {
          TabContent() {
            LynxTabContainer({
              spec: this.tabSpec('home', '首页'),
              refreshGeneration: this.tabReloadGeneration
            })
          }
          .tabBar('首页')

          TabContent() {
            LynxTabContainer({
              spec: this.tabSpec('settings', '设置'),
              refreshGeneration: this.tabReloadGeneration
            })
          }
          .tabBar('设置')
        }
        .barMode(BarMode.Fixed)
        .onChange((index: number) => this.selectedNativeTab = index)
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.shell_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    } else {
      Scroll() {
      Column({ space: 20 }) {
        Column({ space: 8 }) {
          Text('Lynx Router 原生壳')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.shell_text_primary'))
          Text('默认进入 10000001 OTA 验收首页；返回后可打开 Playground 或原生 ArkUI Tabs Demo。')
            .fontSize(16)
            .fontColor($r('app.color.shell_text_secondary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 14 }) {
          Text('OTA 验收入口')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.shell_text_primary'))
            .width('100%')

          Text('全量 latest-bundle-list → 按返回的 App ID 存储 → 本地 SHA 校验\n当前 Demo 临时用 platform=android 请求现有服务端；后端开放 harmony 后再切回正式平台。')
            .fontSize(14)
            .lineHeight(22)
            .fontColor($r('app.color.shell_text_secondary'))
            .width('100%')

          Button('打开 Playground 首页（OTA）')
            .width('100%')
            .height(56)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .backgroundColor($r('app.color.shell_brand'))
            .borderRadius(12)
            .onClick(() => this.openPlaygroundHome())

          Button('打开 OTA 验收首页（10000001）')
            .width('100%')
            .height(52)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.shell_text_primary'))
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: $r('app.color.shell_brand') })
            .borderRadius(12)
            .onClick(() => this.openOtaHome())

          Button('打开原生 Tabs 承载 Demo')
            .width('100%')
            .height(52)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.shell_text_primary'))
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: $r('app.color.shell_brand') })
            .borderRadius(12)
            .onClick(() => this.openNativeTabDemo())

          Button('查看 OTA 磁盘目录')
            .width('100%')
            .height(52)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.shell_text_primary'))
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: $r('app.color.shell_brand') })
            .borderRadius(12)
            .onClick(() => this.openStorageInspector())

          Button(this.isRefreshingOta ? '正在同步全部 OTA…' : '手动触发全量 OTA 同步')
            .width('100%')
            .height(52)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.shell_text_primary'))
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: $r('app.color.shell_brand') })
            .borderRadius(12)
            .enabled(!this.isRefreshingOta)
            .onClick(() => this.syncAllOtaBundles())

          Button('删除全部 OTA Bundle')
            .width('100%')
            .height(52)
            .fontSize(16)
            .fontColor($r('app.color.shell_text_primary'))
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: $r('app.color.shell_brand') })
            .borderRadius(12)
            .onClick(() => this.deleteAllOtaBundles())

          Text('删除只影响 files/lynx-ota-store 中的 OTA 下载缓存，不会删除 HAP 内置资源；不生成 .delete-* 备份目录。')
            .fontSize(12)
            .lineHeight(19)
            .fontColor($r('app.color.shell_text_secondary'))
            .width('100%')

          if (this.otaStatusMessage.length > 0) {
            Text(this.otaStatusMessage)
              .fontSize(13)
              .fontColor('#D93025')
              .width('100%')
          }

          if (this.errorMessage.length > 0) {
            Text(`外部深链打开失败：${this.errorMessage}`)
              .fontSize(13)
              .fontColor('#D93025')
              .width('100%')
          }
        }
        .width('100%')
        .padding(20)
        .backgroundColor($r('app.color.shell_surface'))
        .borderRadius(18)
        .border({ width: 2, color: $r('app.color.shell_brand') })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 48, bottom: 36 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.shell_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
  }

}
