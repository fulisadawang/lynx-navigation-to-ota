import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { Configuration } from '@ohos.app.ability.Configuration';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import { ConfigurationConstant } from '@kit.AbilityKit';
import window from '@ohos.window';
import { ShellConstants, LynxOtaConfig, LynxRouter } from '@lynx/lynx-shell-kit';

/**
 * Stage 模型入口。
 * 只负责进程初始化、窗口管理和深链暂存；实际路由解析统一交给 LynxRouteParser。
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.updateInitialRoute(want);
    // 三端统一入口：HarmonyOS 端 Native Page Stack 由 ArkUI Router Page 承载。
    const otaConfig = new LynxOtaConfig('https://lynx-ota-server.test.huangbaoche.com');
    otaConfig.environment = 'TEST';
    otaConfig.hostApp = 'capp';
    // 临时复用现有服务端的 Android release 数据；后端开放 harmony 后改为 'harmony' 或清空。
    otaConfig.platform = 'harmony';
    otaConfig.serverPlatform = 'android';
    // Demo 不写死客户端令牌；验收时可通过 Want 参数临时注入，真实宿主应改为自己的安全配置。
    const launchToken = (want.parameters?.lynx_ota_client_token as string) ?? '';
    if (launchToken.trim().length > 0) {
      otaConfig.clientToken = launchToken.trim();
    }
    LynxRouter.install(this.context, otaConfig);
    AppStorage.setOrCreate(ShellConstants.STORAGE_COLOR_MODE, this.context.config.colorMode);
    console.info(`[${ShellConstants.TAG}] EntryAbility created, launchReason=${launchParam.launchReason}`);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    AppStorage.setOrCreate(ShellConstants.STORAGE_WINDOW_STAGE, windowStage);
    windowStage.getMainWindow().then((currentWindow: window.Window) => {
      currentWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
    }).catch((error: Error) => {
      console.error(`[${ShellConstants.TAG}] getMainWindow failed: ${error.message}`);
    });

    windowStage.loadContent(ShellConstants.HOME_PAGE, (error) => {
      if (error.code) {
        console.error(`[${ShellConstants.TAG}] loadContent failed: ${JSON.stringify(error)}`);
      }
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.updateInitialRoute(want);
    console.info(`[${ShellConstants.TAG}] onNewWant, launchReason=${launchParam.launchReason}`);
  }

  onWindowStageDestroy(): void {
    AppStorage.delete(ShellConstants.STORAGE_WINDOW_STAGE);
  }

  /** 每次回到前台都触发全量 latest-bundle-list，不走页面 30 分钟门控。 */
  onForeground(): void {
    LynxRouter.onApplicationForeground();
  }

  /** UIAbility 进入后台；页面 aboutToDisappear 不等同于 App background。 */
  onBackground(): void {
    LynxRouter.onApplicationBackground();
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    const current = AppStorage.get<ConfigurationConstant.ColorMode>(ShellConstants.STORAGE_COLOR_MODE);
    if (current !== newConfig.colorMode) {
      AppStorage.setOrCreate(ShellConstants.STORAGE_COLOR_MODE, newConfig.colorMode);
    }
  }

  private updateInitialRoute(want: Want): void {
    const routeFromParameters = (want.parameters?.lynx_initial_url as string) ?? '';
    const initialRoute = routeFromParameters.length > 0 ? routeFromParameters : (want.uri ?? '');
    AppStorage.setOrCreate(ShellConstants.STORAGE_INITIAL_URI, initialRoute);

    const previousVersion = AppStorage.get<number>(ShellConstants.STORAGE_INITIAL_URI_VERSION) ?? 0;
    AppStorage.setOrCreate(ShellConstants.STORAGE_INITIAL_URI_VERSION, previousVersion + 1);
  }
}
