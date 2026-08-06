import { common } from '@kit.AbilityKit';
import { LLog, LynxEnv, LynxServiceCenter, LynxServiceType } from '@lynx/lynx';
import { LynxBaseServiceCenter, LynxBaseServiceType } from '@lynx/lynx_base';
import { LynxDevToolService } from '@lynx/lynx_devtool_service';
import { LynxHttpService } from '@lynx/lynx_http_service';
import { LynxImageService } from '@lynx/lynx_image_service';
import { LynxLogService } from '@lynx/lynx_log_service';
import ShellConstants from './ShellConstants';
import XElementRuntime from './XElementRuntime';

/**
 * 进程级 Lynx Runtime 初始化器。
 *
 * 官方 Explorer 明确要求先注册 Service，再执行 LynxEnv.initialize，
 * 因为 LynxEnv 初始化阶段会查询 DevToolService。
 */
export default class LynxRuntimeInitializer {
  private static initialized: boolean = false;

  static initialize(context: common.UIAbilityContext): void {
    if (LynxRuntimeInitializer.initialized) {
      return;
    }

    LLog.useSysLog(true);
    LynxRuntimeInitializer.registerServices();
    LynxEnv.initialize(context);

    const appInfo = new Map<string, string>();
    appInfo.set('App', ShellConstants.APP_NAME);
    appInfo.set('AppVersion', ShellConstants.APP_VERSION);
    appInfo.set('BuildNumber', ShellConstants.BUILD_NUMBER);
    appInfo.set('Platform', 'HarmonyOS');
    LynxEnv.setAppInfo(appInfo);

    XElementRuntime.initialize();
    LynxRuntimeInitializer.initialized = true;
    LLog.d(ShellConstants.TAG, 'Lynx Runtime initialized');
  }

  private static registerServices(): void {
    LynxBaseServiceCenter.registerService(LynxBaseServiceType.Log, LynxLogService.instance);
    LynxServiceCenter.registerService(LynxServiceType.DevTool, LynxDevToolService.instance);
    LynxServiceCenter.registerService(LynxServiceType.Http, LynxHttpService.instance);
    LynxServiceCenter.registerService(LynxServiceType.Image, LynxImageService.instance);
  }

  private constructor() {
  }
}
