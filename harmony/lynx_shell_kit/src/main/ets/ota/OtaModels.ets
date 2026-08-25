import { common } from '@kit.AbilityKit';

/** HarmonyOS Router 内置 OTA 的宿主配置。敏感令牌只由宿主运行时注入，不写入 HAR。 */
export class LynxOtaConfig {
  apiBaseUrl: string;
  hostApp: string = 'capp';
  environment: string = 'PROD';
  /** 当前宿主平台；页面 AppInfo/GlobalProps 仍然报告 harmony。 */
  platform: string = 'harmony';
  /**
   * 临时服务端兼容值。
   *
   * 现有 OTA 服务端只接受 android/ios 时，Demo 可以把这里设为 android；
   * 路由、容器和本地事务仍然运行在 HarmonyOS，后端开放 harmony 后清空即可。
   * 为空时自动使用 platform，避免把兼容逻辑散落到请求代码里。
   */
  serverPlatform: string = '';
  clientToken: string = '';
  storageDirectory: string = '';
  pageRefreshIntervalMillis: number = 30 * 60 * 1000;

  constructor(apiBaseUrl: string) {
    this.apiBaseUrl = apiBaseUrl;
  }

  validate(context: common.UIAbilityContext): void {
    const normalized = this.apiBaseUrl.trim();
    if (!normalized.startsWith('https://')) {
      throw new Error('OTA apiBaseUrl 必须使用 HTTPS');
    }
    if (this.hostApp.trim().length === 0 || this.environment.trim().length === 0) {
      throw new Error('OTA hostApp/environment 不能为空');
    }
    if (this.platform.trim().length === 0) {
      throw new Error('OTA platform 不能为空');
    }
    if (this.serverPlatform.trim().length === 0) {
      this.serverPlatform = this.platform.trim();
    }
    if (this.serverPlatform.trim().length === 0) {
      throw new Error('OTA serverPlatform 不能为空');
    }
    if (this.pageRefreshIntervalMillis < 0) {
      throw new Error('pageRefreshIntervalMillis 不能为负数');
    }
    if (this.storageDirectory.trim().length === 0) {
      this.storageDirectory = `${context.filesDir}/lynx-ota-store`;
    }
  }

  /** 所有服务端请求和 Release 校验统一使用这一值。 */
  requestPlatform(): string {
    return this.serverPlatform.trim().length > 0 ? this.serverPlatform.trim() : this.platform.trim();
  }
}

/** latest-bundle-list / Manifest 中的单个 Bundle。 */
export interface OtaBundleArtifact {
  pageId: number;
  bundlePath: string;
  bundleSha256: string;
  bundleUrl: string;
  size?: number;
}

/** 服务端 Release Snapshot；changedBundles 在当前服务端契约中是完整 Bundle 快照。 */
export interface OtaReleaseSnapshot {
  env: string;
  hostApp: string;
  lynxAppId: string;
  releaseId: string;
  platform: string;
  status: string;
  changedBundles: OtaBundleArtifact[];
}

/** 全量 latest-bundle-list 响应。定向接口也可能直接返回单个 Snapshot。 */
export interface OtaLatestBundleLists {
  env: string;
  hostApp: string;
  platform?: string;
  bundleLists: OtaReleaseSnapshot[];
}

/** 写入 releases/<releaseId>/release-manifest.json 的本地 Manifest。 */
export interface OtaLocalManifest {
  env: string;
  hostApp: string;
  lynxAppId: string;
  releaseId: string;
  platform: string;
  status: string;
  bundles: OtaBundleArtifact[];
  installedAt: number;
}

/** states/<appId>.json；state 始终在 Release 完整发布后最后原子提交。 */
export interface OtaReleaseState {
  env: string;
  hostApp: string;
  lynxAppId: string;
  platform: string;
  generation: number;
  current: OtaReleaseRef;
  previous?: OtaReleaseRef;
  /** 旧 state 兼容读取字段；canonical 写入不再生成。 */
  currentReleaseId?: string;
  previousReleaseId?: string;
}

export interface OtaReleaseRef {
  kind: 'embedded' | 'downloaded';
  releaseId: string;
}

/** Router 容器只消费已校验的文件或 rawfile bytes；绝对路径不会写入 ArkUI Router 参数。 */
export interface PreparedPageBundle {
  lynxAppId: string;
  bundleName: string;
  filePath: string;
  /** 内置 rawfile 直接读取时使用；远程 OTA 文件保持 bytes 未定义。 */
  bytes?: ArrayBuffer;
  releaseId: string;
  sha256: string;
  /** 页面可见的来源标签；不参与 Bundle 解析或 OTA 激活。 */
  source?: string;
}

/** 页面关闭时只置位，异步任务完成后必须检查，防止过期结果创建 LynxView。 */
export class OtaPrepareSignal {
  cancelled: boolean = false;

  cancel(): void {
    this.cancelled = true;
  }

  throwIfCancelled(): void {
    if (this.cancelled) {
      throw new Error('OTA 页面准备已取消');
    }
  }
}

/** Router 与具体 OTA Runtime 的最小真实接缝。 */
export interface PageBundleRuntime {
  onApplicationStarted(): void;
  onApplicationForeground(): void;
  prepare(lynxAppId: string, bundleName: string, signal: OtaPrepareSignal): Promise<PreparedPageBundle>;
  /** 只读已经提交的 current；Tab 切换禁止触发网络、repair 或后台刷新。 */
  resolveCurrent(lynxAppId: string, bundleName: string): Promise<PreparedPageBundle | null>;
  /** 普通页面命中 remote current 后的非阻塞 App ID 级 30 分钟后台检查；Tab 不调用。 */
  refreshAppBundleIfNeeded(lynxAppId: string): void;
  rollback(lynxAppId: string, reason: string): Promise<boolean>;
  deleteBundles(lynxAppId: string): Promise<void>;
  deleteAllBundles(): Promise<void>;
  /** Provider 只允许读取受控 prepared file，或消费已校验的 embedded rawfile bytes。 */
  storageRoot(): string;
}

/** 进程级 Runtime 注册表，避免把文件路径写入页面参数或全局 Props。 */
export default class PageBundleRuntimeRegistry {
  private static runtime: PageBundleRuntime | null = null;

  static install(runtime: PageBundleRuntime | null): void {
    PageBundleRuntimeRegistry.runtime = runtime;
  }

  static current(): PageBundleRuntime | null {
    return PageBundleRuntimeRegistry.runtime;
  }

  private constructor() {
  }
}
