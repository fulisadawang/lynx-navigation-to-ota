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
  /** 仅 TEST + Want 显式注入时启用；生产默认永远关闭。 */
  debugMockEnabled: boolean = false;
  /** 仅本地 TEST OTA Server 使用；生产和普通远程地址仍强制 HTTPS。 */
  allowLocalHTTPForTest: boolean = false;
  /** 仅 TEST 启动参数可注入的故障点；生产环境校验时会清空。 */
  testFaultPoint: string = '';
  /** 仅 TEST 启动参数可注入的容量探针，-1 表示读取真实 statfs。 */
  testAvailableCapacityBytes: number = -1;
  /** 仅 TEST 启动参数可注入的提交边界暂停点；用于 HDC force-stop 验证。 */
  testPausePoint: string = '';
  /** TEST 提交边界暂停时长，单位毫秒。 */
  testPauseMillis: number = 0;
  /** TEST 暂停实例标识，只用于匹配当前 HDC 日志，不进入 Store State。 */
  testPauseToken: string = '';
  storageDirectory: string = '';
  pageRefreshIntervalMillis: number = 30 * 60 * 1000;

  constructor(apiBaseUrl: string) {
    this.apiBaseUrl = apiBaseUrl;
  }

  validate(context: common.UIAbilityContext): void {
    const isTestEnvironment = this.environment.toUpperCase() === 'TEST';
    if (!isTestEnvironment) {
      this.debugMockEnabled = false;
      this.allowLocalHTTPForTest = false;
      this.testFaultPoint = '';
      this.testAvailableCapacityBytes = -1;
      this.testPausePoint = '';
      this.testPauseMillis = 0;
      this.testPauseToken = '';
    }
    if (this.testAvailableCapacityBytes < -1) {
      throw new Error('testAvailableCapacityBytes 不能小于 -1');
    }
    if (isTestEnvironment && !LynxOtaConfig.isSupportedTestFaultPoint(this.testFaultPoint)) {
      throw new Error(`TEST fault point 不支持：${this.testFaultPoint}`);
    }
    if (this.testPauseMillis < 0 || this.testPauseMillis > 30000 || this.testPauseMillis !== Math.floor(this.testPauseMillis)) {
      throw new Error('testPauseMillis 必须是 0 到 30000 的整数');
    }
    if (isTestEnvironment && !LynxOtaConfig.isSupportedTestPausePoint(this.testPausePoint)) {
      throw new Error(`TEST pause point 不支持：${this.testPausePoint}`);
    }
    const normalized = this.apiBaseUrl.trim();
    const localHttp = LynxOtaConfig.isTestHttpUrl(normalized);
    if (!normalized.startsWith('https://') &&
      !(this.allowLocalHTTPForTest && this.environment.toUpperCase() === 'TEST' && localHttp)) {
      throw new Error('OTA apiBaseUrl 必须使用 HTTPS；仅 TEST + loopback 调试地址允许 HTTP');
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

  private static isTestHttpUrl(value: string): boolean {
    if (!value.startsWith('http://')) return false;
    const hostPort = value.substring('http://'.length).split('/')[0].split(':')[0];
    return hostPort === '127.0.0.1' || hostPort === 'localhost' || hostPort === '[::1]' ||
      hostPort === '10.0.2.2' || hostPort.startsWith('10.') || hostPort.startsWith('192.168.') ||
      hostPort.startsWith('172.16.') || hostPort.startsWith('172.17.') || hostPort.startsWith('172.18.') ||
      hostPort.startsWith('172.19.') || hostPort.startsWith('172.20.') || hostPort.startsWith('172.21.') ||
      hostPort.startsWith('172.22.') || hostPort.startsWith('172.23.') || hostPort.startsWith('172.24.') ||
      hostPort.startsWith('172.25.') || hostPort.startsWith('172.26.') || hostPort.startsWith('172.27.') ||
      hostPort.startsWith('172.28.') || hostPort.startsWith('172.29.') || hostPort.startsWith('172.30.') ||
      hostPort.startsWith('172.31.');
  }

  private static isSupportedTestFaultPoint(value: string): boolean {
    return value.trim().length === 0 || [
      'before_object_publish',
      'after_object_publish',
      'after_objects_ready',
      'before_manifest_commit',
      'after_manifest_commit',
      'before_state_commit',
      'after_state_commit_report_failure',
      'enospc_object_publish',
      'enospc_manifest_commit',
      'enospc_state_commit'
    ].includes(value.trim().toLowerCase());
  }

  private static isSupportedTestPausePoint(value: string): boolean {
    return value.trim().length === 0 || [
      'after_object_publish',
      'after_objects_ready',
      'after_manifest_commit',
      'before_state_commit',
      'after_state_commit'
    ].includes(value.trim().toLowerCase());
  }
}

/** latest-bundle-list / Manifest 中的单个 Bundle。 */
export interface OtaBundleArtifact {
  pageId: number;
  bundlePath: string;
  bundleSha256: string;
  bundleUrl: string;
  size?: number;
  /** Store v3 的对象 ID；服务端缺省时由客户端使用 bundleSha256。 */
  objectId?: string;
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

/** 写入 apps/<lynxAppId>/manifests/<manifestId>.json 的本地 Store v3 Manifest。 */
export interface OtaLocalManifest {
  schemaVersion: number;
  manifestId?: string;
  env: string;
  hostApp: string;
  lynxAppId: string;
  releaseId: string;
  platform: string;
  status: string;
  bundles: OtaBundleArtifact[];
  installedAt: number;
}

/** apps/<appId>/state.json；state 始终在 Release 完整发布后最后原子提交。 */
export interface OtaReleaseState {
  schemaVersion: number;
  env: string;
  hostApp: string;
  lynxAppId: string;
  platform: string;
  generation: number;
  current: OtaReleaseRef;
  previous?: OtaReleaseRef;
}

export interface OtaReleaseRef {
  kind: 'embedded' | 'downloaded';
  releaseId: string;
  manifestId?: string;
}

/** 远程 Release 的进程内生命周期租约；rawfile baseline 不需要租约。 */
export class OtaBundleLease {
  private closed: boolean = false;
  private readonly releaseAction: () => void;

  constructor(releaseAction: () => void) {
    this.releaseAction = releaseAction;
  }

  /** 幂等释放；最后一个 lease 释放后由 Store 执行 app-scoped prune。 */
  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.releaseAction();
  }
}

/** Router 容器只消费已校验的文件或 rawfile bytes；绝对路径不会写入 ArkUI Router 参数。 */
export interface PreparedPageBundle {
  lynxAppId: string;
  bundleName: string;
  filePath: string;
  /** 内置 rawfile 直接读取时使用；远程 OTA 文件保持 bytes 未定义。 */
  bytes?: ArrayBuffer;
  releaseId: string;
  /** 远程 current 对应的完整 Manifest ID；用于 session 级 NavigationSnapshot。 */
  manifestId?: string;
  /** 进程内 session 级快照 ID；不会写入持久化 State。 */
  navigationSnapshotID?: string;
  sha256: string;
  /** 页面可见的来源标签；不参与 Bundle 解析或 OTA 激活。 */
  source?: string;
  /** 远程 current 的容器级租约；embedded rawfile 不设置。 */
  lease?: OtaBundleLease;
}

export enum OtaStorageReleaseRole {
  CURRENT = 'current',
  PREVIOUS = 'previous',
  LEASED = 'leased',
  ORPHAN = 'orphan'
}

export interface OtaStorageFileSnapshot {
  relativePath: string;
  byteCount: number;
  modifiedAt: number;
}

export interface OtaStorageStateSnapshot {
  generation: number;
  currentReleaseId: string;
  currentKind: string;
  previousReleaseId?: string;
  previousKind?: string;
  currentManifestId?: string;
  previousManifestId?: string;
}

export interface OtaStorageReleaseSnapshot {
  releaseId: string;
  roles: OtaStorageReleaseRole[];
  totalBytes: number;
  fileCount: number;
  manifestValid: boolean;
  files: OtaStorageFileSnapshot[];
  truncated: boolean;
  manifestId?: string;
  bundleCount?: number;
  objectIds?: string[];
}

export interface OtaStorageStagingSnapshot {
  transactionName: string;
  totalBytes: number;
  fileCount: number;
  files: OtaStorageFileSnapshot[];
  truncated: boolean;
}

export interface OtaStorageAppSnapshot {
  appId: string;
  state?: OtaStorageStateSnapshot;
  releases: OtaStorageReleaseSnapshot[];
  staging: OtaStorageStagingSnapshot[];
  totalBytes: number;
  fileCount: number;
  objectCount?: number;
  objectBytes?: number;
  manifestBytes?: number;
  lastOperation?: string;
}

export interface OtaStorageSnapshot {
  rootPath: string;
  totalBytes: number;
  fileCount: number;
  generatedAt: number;
  apps: OtaStorageAppSnapshot[];
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
  prepare(lynxAppId: string, bundleName: string, signal: OtaPrepareSignal, navigationSessionID?: string): Promise<PreparedPageBundle>;
  /** 只读已经提交的 current；Tab 切换禁止触发网络、repair 或后台刷新。 */
  resolveCurrent(lynxAppId: string, bundleName: string, navigationSessionID?: string): Promise<PreparedPageBundle | null>;
  /** 普通页面命中 remote current 后的非阻塞 App ID 级 30 分钟后台检查；Tab 不调用。 */
  refreshAppBundleIfNeeded(lynxAppId: string): void;
  rollback(lynxAppId: string, reason: string): Promise<boolean>;
  deleteBundles(lynxAppId: string): Promise<void>;
  deleteAllBundles(): Promise<void>;
  /** 只读快照；不触发网络、SHA、prune 或目录写入。 */
  storageSnapshot(): Promise<OtaStorageSnapshot | null>;
  /** Provider 只允许读取受控 prepared file，或消费已校验的 embedded rawfile bytes。 */
  storageRoot(): string;
  /** 释放一个 session consumer 的 Snapshot lease。 */
  releaseNavigationSnapshot(navigationSessionID: string, lynxAppId: string): void;
  /** 主动刷新后重置 Snapshot，旧页面 lease 仍由页面生命周期保护。 */
  resetNavigationSnapshot(navigationSessionID: string, lynxAppId: string): void;
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
