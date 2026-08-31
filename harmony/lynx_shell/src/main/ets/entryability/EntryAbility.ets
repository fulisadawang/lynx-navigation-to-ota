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
    const launchParameterKeys = want.parameters === undefined ? '' : Object.keys(want.parameters).join(',');
    // 三端统一入口：HarmonyOS 端 Native Page Stack 由 ArkUI Router Page 承载。
    // Debug Demo 默认指向本机 fixture：Harmony 模拟器通过 10.0.2.2 访问宿主机；业务
    // 接入时应从构建/宿主配置注入真实 HTTPS 地址，不要把这个测试地址带入生产包。
    const launchBaseUrl = (want.parameters?.lynx_ota_api_base_url as string) ??
      'http://10.0.2.2:18766';
    const otaConfig = new LynxOtaConfig(launchBaseUrl);
    otaConfig.environment = 'TEST';
    otaConfig.hostApp = 'capp';
    // 临时复用现有服务端的 Android release 数据；后端开放 harmony 后改为 'harmony' 或清空。
    otaConfig.platform = 'harmony';
    otaConfig.serverPlatform = 'android';
    otaConfig.allowLocalHTTPForTest = launchBaseUrl.trim().toLowerCase().startsWith('http://') &&
      otaConfig.environment === 'TEST';
    AppStorage.setOrCreate(
      'lynx_ota_local_fixture',
      otaConfig.allowLocalHTTPForTest ? '1' : '0'
    );
    // Demo 不写死客户端令牌；验收时可通过 Want 参数临时注入，真实宿主应改为自己的安全配置。
    const launchToken = (want.parameters?.lynx_ota_client_token as string) ?? '';
    if (launchToken.trim().length > 0) {
      otaConfig.clientToken = launchToken.trim();
    }
    const launchMock = (want.parameters?.lynx_ota_mock as string) ?? '';
    otaConfig.debugMockEnabled = otaConfig.environment === 'TEST' && launchMock === '1';
    const launchFaultPoint = (want.parameters?.lynx_ota_fault_point as string) ?? '';
    otaConfig.testFaultPoint = otaConfig.environment === 'TEST' ? launchFaultPoint.trim() : '';
    const launchCapacity = (want.parameters?.lynx_ota_capacity_override as string) ?? '';
    const parsedCapacity = Number(launchCapacity);
    if (otaConfig.environment === 'TEST' && launchCapacity.trim().length > 0) {
      if (parsedCapacity < 0 || parsedCapacity !== Math.floor(parsedCapacity) || parsedCapacity > 9007199254740991) {
        throw new Error('lynx_ota_capacity_override 必须是非负安全整数');
      }
      otaConfig.testAvailableCapacityBytes = parsedCapacity;
    } else {
      otaConfig.testAvailableCapacityBytes = -1;
    }
    const launchPausePoint = (want.parameters?.lynx_ota_pause_point as string) ?? '';
    otaConfig.testPausePoint = otaConfig.environment === 'TEST' ? launchPausePoint.trim() : '';
    const launchPauseMillis = (want.parameters?.lynx_ota_pause_millis as string) ?? '';
    const parsedPauseMillis = Number(launchPauseMillis);
    if (otaConfig.environment === 'TEST' && launchPauseMillis.trim().length > 0) {
      if (parsedPauseMillis < 0 || parsedPauseMillis > 30000 || parsedPauseMillis !== Math.floor(parsedPauseMillis)) {
        throw new Error('lynx_ota_pause_millis 必须是 0 到 30000 的整数');
      }
      otaConfig.testPauseMillis = parsedPauseMillis;
    } else {
      otaConfig.testPauseMillis = 0;
    }
    const launchPauseToken = (want.parameters?.lynx_ota_pause_token as string) ?? '';
    otaConfig.testPauseToken = otaConfig.environment === 'TEST' ? launchPauseToken.trim() : '';
    LynxRouter.install(this.context, otaConfig);
    console.info(`[${ShellConstants.TAG}] OTA base=${launchBaseUrl}, localHttp=${otaConfig.allowLocalHTTPForTest}, testFault=${otaConfig.testFaultPoint || 'none'}, capacityOverride=${otaConfig.testAvailableCapacityBytes}, testPause=${otaConfig.testPausePoint || 'none'}:${otaConfig.testPauseMillis}:${otaConfig.testPauseToken || 'none'}, wantKeys=${launchParameterKeys}`);
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
