import { common } from '@kit.AbilityKit';
import systemDateTime from '@ohos.systemDateTime';
import OtaApiClient from './OtaApiClient';
import {
  LynxOtaConfig,
  OtaPrepareSignal,
  OtaReleaseSnapshot,
  PageBundleRuntime,
  PreparedPageBundle
} from './OtaModels';
import ReleaseTransaction from './ReleaseTransaction';
import EmbeddedBundleRegistry from './EmbeddedBundleRegistry';

/** 把所有会修改 current/state 的事务串行化；网络等待期间不会阻塞 ArkUI 线程。 */
class OtaOperationQueue {
  private tail: Promise<void> = Promise.resolve();

  run<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.tail.then(operation, operation);
    this.tail = result.then(() => undefined, () => undefined);
    return result;
  }
}

/**
 * HarmonyOS Router 内置 OTA Runtime。
 *
 * 启动/回前台每次全量检查；页面命中本地 current 时立即打开并按 appId 做 30 分钟后台检查；
 * 缺包或 SHA 损坏忽略时间门控，在原生 Loading 中等待 repair。
 */
export default class LynxOtaRuntime implements PageBundleRuntime {
  private readonly config: LynxOtaConfig;
  private readonly api: OtaApiClient;
  private readonly transaction: ReleaseTransaction;
  private readonly embeddedBundleRegistry: EmbeddedBundleRegistry;
  private readonly queue: OtaOperationQueue = new OtaOperationQueue();
  private readonly lastPageRefreshAt: Map<string, number> = new Map();
  private readonly pageRefreshInFlight: Set<string> = new Set();
  private fullSyncInFlight: boolean = false;
  private fullSyncPending: boolean = false;
  private readonly fullSyncWaiters: Array<(success: boolean) => void> = [];

  constructor(context: common.UIAbilityContext, config: LynxOtaConfig) {
    config.validate(context);
    this.config = config;
    this.api = new OtaApiClient(config);
    this.transaction = new ReleaseTransaction(config, this.api);
    this.embeddedBundleRegistry = new EmbeddedBundleRegistry(context);
  }

  onApplicationStarted(): void {
    this.syncAllBundlesAsync();
  }

  onApplicationForeground(): void {
    this.syncAllBundlesAsync();
  }

  async prepare(
    lynxAppId: string,
    bundleName: string,
    signal: OtaPrepareSignal
  ): Promise<PreparedPageBundle> {
    this.validateLogicalAddress(lynxAppId, bundleName);
    signal.throwIfCancelled();
    const local = this.transaction.currentBundle(lynxAppId, bundleName);
    if (local !== null) {
      this.syncAppBundleAsync(lynxAppId);
      return local;
    }
    const embedded = await this.embeddedBundleRegistry.resolve(lynxAppId, bundleName);
    if (embedded !== null) {
      return embedded;
    }
    // 缺包/损坏不走 30 分钟门控，必须在创建 LynxView 前完成定向 repair。
    return this.queue.run(() => this.transaction.ensureBundleReady(lynxAppId, bundleName, signal));
  }

  /**
   * Native Tab 专用 cache-only 入口。
   *
   * 只读取并校验已经提交的 current，不调用定向清单接口，也不进入 repair 或后台刷新。
   */
  async resolveCurrent(
    lynxAppId: string,
    bundleName: string
  ): Promise<PreparedPageBundle | null> {
    this.validateLogicalAddress(lynxAppId, bundleName);
    const current = this.transaction.currentBundle(lynxAppId, bundleName);
    if (current !== null) {
      return current;
    }
    return this.embeddedBundleRegistry.resolve(lynxAppId, bundleName);
  }

  /** cache-first 普通页面使用的后台刷新入口；syncAppBundleAsync 自带 AppId 门控。 */
  refreshAppBundleIfNeeded(lynxAppId: string): void {
    this.syncAppBundleAsync(lynxAppId);
  }

  /** 用户主动刷新使用；等待最后一轮合并后的全量同步完成，再由 Tab Host 重读 current。 */
  refreshAllBundles(): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      this.fullSyncWaiters.push(resolve);
      this.syncAllBundlesAsync();
    });
  }

  rollback(lynxAppId: string, reason: string): Promise<boolean> {
    return this.queue.run(async () => {
      const restoredRemote = this.transaction.rollback(lynxAppId);
      if (restoredRemote) {
        console.info(`LynxShellOTA rollback appId=${lynxAppId}, restored=previous, reason=${reason}`);
        return true;
      }
      if (!await this.embeddedBundleRegistry.containsApp(lynxAppId)) {
        console.info(`LynxShellOTA rollback appId=${lynxAppId}, restored=false, reason=${reason}`);
        return false;
      }
      try {
        // 没有 previous remote 时删除坏的 downloaded current；下一次 prepare 直接读取 rawfile
        // baseline，不把内置 Bundle 复制到 filesDir。
        this.transaction.deleteBundles(lynxAppId);
        this.lastPageRefreshAt.delete(lynxAppId);
        this.pageRefreshInFlight.delete(lynxAppId);
        console.info(`LynxShellOTA rollback appId=${lynxAppId}, restored=embedded, reason=${reason}`);
        return true;
      } catch (error) {
        console.error(`LynxShellOTA embedded fallback 失败：${lynxAppId}, ${error}`);
        return false;
      }
    });
  }

  deleteBundles(lynxAppId: string): Promise<void> {
    return this.queue.run(async () => {
      this.transaction.deleteBundles(lynxAppId);
      this.lastPageRefreshAt.delete(lynxAppId);
      this.pageRefreshInFlight.delete(lynxAppId);
    });
  }

  deleteAllBundles(): Promise<void> {
    return this.queue.run(async () => {
      this.transaction.deleteAllBundles();
      this.lastPageRefreshAt.clear();
      this.pageRefreshInFlight.clear();
    });
  }

  storageRoot(): string {
    return this.transaction.storageRoot();
  }

  /** 生命周期全量请求不限次数；重叠事件合并为当前请求结束后的补发。 */
  private syncAllBundlesAsync(): void {
    if (this.fullSyncInFlight) {
      this.fullSyncPending = true;
      return;
    }
    this.fullSyncInFlight = true;
    let succeeded = true;
    this.queue.run(async () => {
      const signal = new OtaPrepareSignal();
      const latest = await this.api.fetchLatestBundleLists(signal);
      for (const snapshot of latest.bundleLists) {
        await this.transaction.install(snapshot, signal);
        this.lastPageRefreshAt.set(snapshot.lynxAppId, this.uptimeMillis());
      }
    }).catch((error: Error) => {
      // 生命周期刷新失败不能影响已提交 current，后续页面仍可定向 repair。
      succeeded = false;
      console.error(`LynxShellOTA 全量同步失败：${error.message}`);
    }).finally(() => {
      this.fullSyncInFlight = false;
      if (this.fullSyncPending) {
        this.fullSyncPending = false;
        this.syncAllBundlesAsync();
        return;
      }
      const waiters = this.fullSyncWaiters.splice(0, this.fullSyncWaiters.length);
      waiters.forEach((waiter: (success: boolean) => void) => {
        try {
          waiter(succeeded);
        } catch (error) {
          console.error(`LynxShellOTA 主动刷新回调失败：${error}`);
        }
      });
    });
  }

  /** 页面已有合法 current 时才进入 appId 级时间门控，后台失败不阻塞旧版本。 */
  private syncAppBundleAsync(lynxAppId: string): void {
    const now = this.uptimeMillis();
    const last = this.lastPageRefreshAt.get(lynxAppId);
    if (this.fullSyncInFlight || this.pageRefreshInFlight.has(lynxAppId) ||
      (last !== undefined && this.config.pageRefreshIntervalMillis > 0 &&
        now - last < this.config.pageRefreshIntervalMillis)) {
      return;
    }
    this.pageRefreshInFlight.add(lynxAppId);
    this.queue.run(async () => {
      const signal = new OtaPrepareSignal();
      const latest = await this.api.fetchLatestBundleList(lynxAppId, signal);
      await this.transaction.install(latest, signal);
      // 只有清单和事务都成功后才刷新时间戳。
      this.lastPageRefreshAt.set(lynxAppId, this.uptimeMillis());
    }).catch((error: Error) => {
      console.error(`LynxShellOTA appId 后台刷新失败：${lynxAppId}, ${error.message}`);
    }).finally(() => {
      this.pageRefreshInFlight.delete(lynxAppId);
    });
  }

  private validateLogicalAddress(lynxAppId: string, bundleName: string): void {
    if (lynxAppId.trim().length === 0 || bundleName.trim().length === 0) {
      throw new Error('lynxAppId/bundleName 不能为空');
    }
    if (!bundleName.trim().endsWith('.lynx.bundle')) {
      throw new Error('OTA bundleName 必须以 .lynx.bundle 结尾');
    }
  }

  /** 使用开机单调时间，避免用户修改系统时间绕过或拉长 30 分钟门控。 */
  private uptimeMillis(): number {
    return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
  }
}
