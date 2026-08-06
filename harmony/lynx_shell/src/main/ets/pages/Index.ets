import { ShellConstants, LynxRouter } from '@lynx/lynx-shell-kit';

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

  @StorageLink('lynx_initial_uri')
  private initialUri: string = '';

  @StorageLink('lynx_initial_uri_version')
  @Watch('onInitialUriVersionChanged')
  private initialUriVersion: number = 0;

  private consumedInitialVersion: number = -1;

  aboutToAppear(): void {
    this.consumeInitialRoute();
  }

  private onInitialUriVersionChanged(): void {
    this.consumeInitialRoute();
  }

  private consumeInitialRoute(): void {
    if (this.consumedInitialVersion === this.initialUriVersion) {
      return;
    }
    this.consumedInitialVersion = this.initialUriVersion;
    const route = this.initialUri.trim();
    if (route.length === 0) {
      return;
    }
    this.openRoute(route);
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
    this.otaStatusMessage = '正在准备 10000001/home.lynx.bundle…';
    LynxRouter.openOta('10000001', 'home.lynx.bundle').then((result) => {
      this.otaStatusMessage = result.code === 0 ? '已提交 OTA 页面打开动作' : result.message;
    }).catch((error: Error) => {
      this.otaStatusMessage = `打开 OTA 页面失败：${error.message}`;
    }).finally(() => {
      this.isOpening = false;
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

  build() {
    Scroll() {
      Column({ space: 20 }) {
        Column({ space: 8 }) {
          Text('Lynx Router 原生壳')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.shell_text_primary'))
          Text('当前首页只验收 Native Page Stack 与 OTA 入口，不再进入旧的 main.lynx.bundle。')
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

          Text('10000001 / home.lynx.bundle\nCI/CD → OSS → latest-bundle-list → 本地 SHA 校验\n当前 Demo 临时用 platform=android 请求现有服务端；后端开放 harmony 后再切回正式平台。')
            .fontSize(14)
            .lineHeight(22)
            .fontColor($r('app.color.shell_text_secondary'))
            .width('100%')

          Button('打开 OTA 验收首页')
            .width('100%')
            .height(56)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .backgroundColor($r('app.color.shell_brand'))
            .borderRadius(12)
            .onClick(() => this.openOtaHome())

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
