import { common } from '@kit.AbilityKit';
import LynxRuntimeInitializer from '../common/LynxRuntimeInitializer';
import ShellMessageHub from '../common/ShellMessageHub';
import {
  ShellBridgeResult,
  ShellRouterMessageHandler,
  ShellRouterPageInfo,
  ShellRouterPayload
} from '../common/ShellTypes';
import LynxRouteParser from './LynxRouteParser';
import LynxNavigator from './LynxNavigator';
import LynxOtaRuntime from '../ota/LynxOtaRuntime';
import PageBundleRuntimeRegistry, { LynxOtaConfig } from '../ota/OtaModels';

/**
 * HarmonyOS 端与 Android `LynxRouter`、iOS `LynxRouter` 对齐的统一门面。
 *
 * 默认承载始终是 ArkUI Router + LynxContainer Page；NavPathStack 可以在本适配层内替换。
 * 业务只传 Bundle 与 params，不注册 routeId；旧的 LynxNavigator 仍导出给已有宿主使用。
 */
export default class LynxRouter {
  /** Application/Ability 创建第一个 Lynx Page 前调用一次。 */
  static install(context: common.UIAbilityContext, otaConfig?: LynxOtaConfig): LynxOtaRuntime | null {
    LynxRuntimeInitializer.initialize(context);
    if (otaConfig === undefined) {
      PageBundleRuntimeRegistry.install(null);
      return null;
    }
    const runtime = new LynxOtaRuntime(context, otaConfig);
    PageBundleRuntimeRegistry.install(runtime);
    runtime.onApplicationStarted();
    return runtime;
  }

  /** 宿主回到前台时调用；每次触发全量 latest-bundle-list，不受页面 30 分钟门控影响。 */
  static onApplicationForeground(): void {
    PageBundleRuntimeRegistry.current()?.onApplicationForeground();
  }

  /**
   * 打开 assets/HTTPS Bundle；params 同时作为 initData 和 queryItems。
   *
   * HTTPS 地址属于 DirectRemoteBundle：Fetcher 直接下载并交给 LynxView，不进入
   * Manifest、OTA 磁盘目录、appId 刷新门控或回滚链路，也不会从 URL 反推 appId。
   */
  static open(
    bundle: string,
    params: ShellRouterPayload = {},
    options: ShellRouterPayload = {}
  ): Promise<ShellBridgeResult> {
    const optionsJSON = LynxRouter.optionsJSON(params, options);
    const parsed = LynxRouteParser.parseWithOptions(bundle, optionsJSON);
    if (!parsed.isSuccess || parsed.request === null) {
      const failure: ShellBridgeResult = { code: 1001, message: parsed.errorMessage };
      return Promise.resolve(failure);
    }
    return LynxNavigator.openResult(parsed.request, false, optionsJSON);
  }

  /** 打开 hybrid://lynxview_page?... 兼容 Scheme。 */
  static openScheme(
    scheme: string,
    params: ShellRouterPayload = {},
    options: ShellRouterPayload = {}
  ): Promise<ShellBridgeResult> {
    return LynxRouter.open(scheme, params, options);
  }

  /**
   * 打开 OTA 页面。业务只传 `lynxAppId + bundleName + params`；容器先 prepare，成功后才
   * 创建 LynxView。ArkTS 不用运行时参数类型猜测重载，因此公开命名为 openOta。
   */
  static openOta(
    lynxAppId: string,
    bundleName: string,
    params: ShellRouterPayload = {},
    options: ShellRouterPayload = {}
  ): Promise<ShellBridgeResult> {
    if (PageBundleRuntimeRegistry.current() === null) {
      const result: ShellBridgeResult = { code: 1004, message: '当前宿主没有配置 HarmonyOS OTA runtime' };
      return Promise.resolve(result);
    }
    if (lynxAppId.trim().length === 0 || bundleName.trim().length === 0) {
      const result: ShellBridgeResult = { code: 1001, message: 'lynxAppId/bundleName 不能为空' };
      return Promise.resolve(result);
    }
    const logicalBundleName = LynxRouter.normalizeOtaBundleName(bundleName);
    const normalized = LynxRouter.normalizeOtaBundle(logicalBundleName);
    const optionsJSON = LynxRouter.optionsJSON(params, options);
    const parsed = LynxRouteParser.parseWithOptions(normalized, optionsJSON);
    if (!parsed.isSuccess || parsed.request === null) {
      const result: ShellBridgeResult = { code: 1001, message: parsed.errorMessage };
      return Promise.resolve(result);
    }
    parsed.request.lynxAppId = lynxAppId.trim();
    parsed.request.bundleName = logicalBundleName;
    parsed.request.routeKey = `${parsed.request.lynxAppId}/${parsed.request.bundleName}`;
    return LynxNavigator.openResult(parsed.request, false, optionsJSON);
  }

  /** 永久删除指定 appId 的磁盘 OTA Bundle，不生成备份目录。 */
  static deleteOtaBundles(lynxAppId: string): Promise<ShellBridgeResult> {
    const runtime = PageBundleRuntimeRegistry.current();
    if (runtime === null) {
      const result: ShellBridgeResult = { code: 1004, message: '当前没有安装 HarmonyOS OTA runtime' };
      return Promise.resolve(result);
    }
    return runtime.deleteBundles(lynxAppId)
      .then((): ShellBridgeResult => {
        return { code: 0, message: `已删除 ${lynxAppId} 的 OTA Bundle` };
      })
      .catch((error: Error): ShellBridgeResult => {
        return { code: 1500, message: `删除 OTA Bundle 失败：${error.message}` };
      });
  }

  /** 永久删除所有 appId 的磁盘 OTA Bundle；HAP rawfile 不受影响。 */
  static deleteAllOtaBundles(): Promise<ShellBridgeResult> {
    const runtime = PageBundleRuntimeRegistry.current();
    if (runtime === null) {
      const result: ShellBridgeResult = { code: 1004, message: '当前没有安装 HarmonyOS OTA runtime' };
      return Promise.resolve(result);
    }
    return runtime.deleteAllBundles()
      .then((): ShellBridgeResult => {
        return { code: 0, message: '已删除全部 OTA Bundle' };
      })
      .catch((error: Error): ShellBridgeResult => {
        return { code: 1500, message: `删除全部 OTA Bundle 失败：${error.message}` };
      });
  }

  /** 原位替换当前 Page，保留 entry 的 session/page 身份。 */
  static replace(
    bundle: string,
    params: ShellRouterPayload = {},
    options: ShellRouterPayload = {}
  ): Promise<ShellBridgeResult> {
    const optionsJSON = LynxRouter.optionsJSON(params, options);
    const parsed = LynxRouteParser.parseWithOptions(bundle, optionsJSON);
    if (!parsed.isSuccess || parsed.request === null) {
      const failure: ShellBridgeResult = { code: 1001, message: parsed.errorMessage };
      return Promise.resolve(failure);
    }
    return LynxNavigator.redirectResult(parsed.request);
  }

  /** 关闭当前 Page。 */
  static pop(): ShellBridgeResult {
    return LynxNavigator.closeResult();
  }

  /** 回到当前 session 中最近的目标 Bundle/pageKey。 */
  static popTo(pageKey: string): ShellBridgeResult {
    return LynxNavigator.popTo(pageKey);
  }

  /** 关闭当前 Lynx session。 */
  static closeAll(): ShellBridgeResult {
    return LynxNavigator.closeAll();
  }

  /** 清空当前 session 后打开新的目标 Bundle。 */
  static reLaunch(
    bundle: string,
    params: ShellRouterPayload = {},
    options: ShellRouterPayload = {}
  ): Promise<ShellBridgeResult> {
    const closed = LynxNavigator.closeAll();
    if (closed.code !== 0) {
      return Promise.resolve(closed);
    }
    return LynxRouter.open(bundle, params, options);
  }

  static setMessageHandler(handler: ShellRouterMessageHandler | null): void {
    ShellMessageHub.setMessageHandler(handler);
  }

  static activePages(): ShellRouterPageInfo[] {
    return ShellMessageHub.pages();
  }

  static broadcast(eventName: string, payload: ShellRouterPayload = {}): number {
    return ShellMessageHub.broadcast(eventName, payload);
  }

  static sendToPage(pageId: string, eventName: string, payload: ShellRouterPayload = {}): boolean {
    return ShellMessageHub.sendToPage(pageId, eventName, payload);
  }

  private static optionsJSON(params: ShellRouterPayload, options: ShellRouterPayload): string {
    let merged: Record<string, Object> = {};
    try {
      merged = JSON.parse(JSON.stringify(options)) as Record<string, Object>;
    } catch (error) {
      merged = {};
    }
    merged['initData'] = params;
    let globalProps: Record<string, Object> = {};
    if (merged['globalProps'] !== undefined) {
      try {
        globalProps = JSON.parse(JSON.stringify(merged['globalProps'])) as Record<string, Object>;
      } catch (error) {
        globalProps = {};
      }
    }
    globalProps['queryItems'] = params;
    merged['globalProps'] = globalProps;
    return JSON.stringify(merged);
  }

  private static normalizeOtaBundle(bundleName: string): string {
    const normalized = LynxRouter.normalizeOtaBundleName(bundleName);
    return normalized.includes('/') ? normalized : `bundles/${normalized}`;
  }

  private static normalizeOtaBundleName(bundleName: string): string {
    let normalized = bundleName.trim();
    while (normalized.startsWith('./')) {
      normalized = normalized.substring(2);
    }
    while (normalized.startsWith('/')) {
      normalized = normalized.substring(1);
    }
    return normalized;
  }

  private constructor() {
  }
}
