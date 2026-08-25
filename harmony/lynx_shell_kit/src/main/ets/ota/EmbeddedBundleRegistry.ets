import { common } from '@kit.AbilityKit';
import { BusinessError } from '@ohos.base';
import cryptoFramework from '@ohos.security.cryptoFramework';
import {
  OtaPrepareSignal,
  PageBundleRuntime,
  PreparedPageBundle
} from './OtaModels';

interface EmbeddedManifestBundle {
  bundleName: string;
  assetPath: string;
  size: number;
  sha256: string;
}

interface EmbeddedManifestApp {
  lynxAppId: string;
  releaseId: string;
  bundles: EmbeddedManifestBundle[];
}

interface EmbeddedManifest {
  schemaVersion: number;
  apps: EmbeddedManifestApp[];
}

/** Manifest 中可公开给宿主使用的稳定身份；不暴露 rawfile 路径或 Bundle bytes。 */
export interface EmbeddedBundleIdentity {
  lynxAppId: string;
  bundleName: string;
  releaseId: string;
}

/**
 * HarmonyOS rawfile 内置 Bundle Registry。
 *
 * rawfile 不是普通文件，Registry 在首次命中时直接读取并校验 ArrayBuffer，交给 Lynx
 * Provider；不再把内置 Bundle 复制到 filesDir。目录结构只负责 OTA 下载，App ID/BundleName
 * 仍由 Manifest 索引，避免按文件名猜测业务归属。
 */
export default class EmbeddedBundleRegistry {
  private static readonly MANIFEST_PATH: string = 'bundles/lynx/embedded-bundles.json';
  private readonly context: common.UIAbilityContext;
  private readonly manifestPromise: Promise<EmbeddedManifestApp[]>;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.manifestPromise = this.loadManifest();
  }

  async resolve(lynxAppId: string, bundleName: string): Promise<PreparedPageBundle | null> {
    const apps = await this.manifestPromise;
    const app = apps.find((item: EmbeddedManifestApp) => item.lynxAppId === lynxAppId);
    const descriptor = app?.bundles.find((item: EmbeddedManifestBundle) => item.bundleName === bundleName);
    if (app === undefined || descriptor === undefined) {
      return null;
    }

    const assetPath = this.validateAssetPath(descriptor.assetPath);
    const raw = await this.readRawFile(assetPath);
    if (raw.byteLength !== descriptor.size) {
      throw new Error(`内置 Bundle size 校验失败：${assetPath}`);
    }
    const actualSha = this.sha256(raw.buffer as ArrayBuffer);
    if (actualSha.toLowerCase() !== descriptor.sha256.toLowerCase()) {
      throw new Error(`内置 Bundle SHA-256 校验失败：${assetPath}`);
    }

    const bytes = raw.slice().buffer as ArrayBuffer;
    return {
      lynxAppId: lynxAppId,
      bundleName: descriptor.bundleName,
      filePath: '',
      bytes: bytes,
      releaseId: app.releaseId,
      sha256: descriptor.sha256,
      source: 'embedded_baseline'
    };
  }

  /**
   * 按 BundleName 解析 Manifest 身份。
   *
   * preferredLynxAppId 用于 Demo/宿主明确选择业务 App；找不到时直接失败，不按文件路径或
   * Manifest 首条目猜测身份。未传 preferred 时与 iOS embeddedIdentity 一致，返回第一个
   * 精确包含该 BundleName 的 App。
   */
  async identity(
    bundleName: string,
    preferredLynxAppId: string = ''
  ): Promise<EmbeddedBundleIdentity | null> {
    const normalizedBundleName = bundleName.trim();
    const normalizedAppId = preferredLynxAppId.trim();
    if (normalizedBundleName.length === 0) return null;

    const apps = await this.manifestPromise;
    const candidates = normalizedAppId.length > 0 ?
      apps.filter((item: EmbeddedManifestApp) => item.lynxAppId === normalizedAppId) : apps;
    for (const app of candidates) {
      const descriptor = app.bundles.find(
        (item: EmbeddedManifestBundle) => item.bundleName === normalizedBundleName
      );
      if (descriptor !== undefined) {
        return {
          lynxAppId: app.lynxAppId,
          bundleName: descriptor.bundleName,
          releaseId: app.releaseId
        };
      }
    }
    return null;
  }

  async containsApp(lynxAppId: string): Promise<boolean> {
    const normalized = lynxAppId.trim();
    if (normalized.length === 0) return false;
    const apps = await this.manifestPromise;
    return apps.some((item: EmbeddedManifestApp) => item.lynxAppId === normalized);
  }

  async firstAvailable(): Promise<PreparedPageBundle | null> {
    const apps = await this.manifestPromise;
    const app = apps[0];
    const bundle = app?.bundles[0];
    if (app === undefined || bundle === undefined) return null;
    return this.resolve(app.lynxAppId, bundle.bundleName);
  }

  /** rawfile bytes 不依赖磁盘路径；该目录只作为 Provider 的安全根边界。 */
  storageRoot(): string {
    return this.context.filesDir;
  }

  private async loadManifest(): Promise<EmbeddedManifestApp[]> {
    try {
      const raw = await this.readRawFile(EmbeddedBundleRegistry.MANIFEST_PATH);
      const text = this.decodeAscii(raw);
      const manifest = JSON.parse(text) as EmbeddedManifest;
      if (manifest.schemaVersion !== 1 || !Array.isArray(manifest.apps)) {
        throw new Error('内置 Bundle Manifest schemaVersion/apps 不合法');
      }
      return manifest.apps;
    } catch (error) {
      // 没有内置 Manifest 的宿主继续使用原有 OTA/Direct Bundle 链路；Manifest 存在但损坏时
      // 仍然抛错，不能悄悄把错误资源当成正常内置版本。
      const message = `${error}`;
      if (message.startsWith(`embedded_rawfile_error:${EmbeddedBundleRegistry.MANIFEST_PATH}:`)) {
        return [];
      }
      throw error instanceof Error ? error : new Error(`${error}`);
    }
  }

  private readRawFile(path: string): Promise<Uint8Array> {
    return new Promise((resolve, reject) => {
      this.context.resourceManager.getRawFileContent(
          path,
        (error: BusinessError, data: Uint8Array) => {
          if (error !== undefined && error.code !== 0) {
            reject(new Error(`embedded_rawfile_error:${path}:${error.code}:${error.message}`));
            return;
          }
          resolve(data);
        }
      );
    });
  }

  private decodeAscii(data: Uint8Array): string {
    let text = '';
    data.forEach((value: number) => {
      text += String.fromCharCode(value);
    });
    return text;
  }

  private validateAssetPath(value: string): string {
    const segments = value.split('/');
    if (!value.startsWith('bundles/') || !value.endsWith('.lynx.bundle') ||
      value.startsWith('/') || value.includes('\\') ||
      segments.some((segment: string) => segment.length === 0 || segment === '.' || segment === '..')) {
      throw new Error(`内置 Bundle assetPath 不安全：${value}`);
    }
    return value;
  }

  private sha256(buffer: ArrayBuffer): string {
    const digest = cryptoFramework.createMd('SHA256');
    digest.updateSync({ data: new Uint8Array(buffer) });
    const bytes = digest.digestSync().data;
    let hex = '';
    bytes.forEach((value: number) => {
      hex += value.toString(16).padStart(2, '0');
    });
    return `sha256:${hex}`;
  }

}

/** 没有远程 OTA 配置时的 HarmonyOS embedded-only runtime；所有读取仍走 Registry 校验。 */
export class EmbeddedOnlyRuntime implements PageBundleRuntime {
  private readonly registry: EmbeddedBundleRegistry;

  constructor(context: common.UIAbilityContext) {
    this.registry = new EmbeddedBundleRegistry(context);
  }

  onApplicationStarted(): void {
  }

  onApplicationForeground(): void {
  }

  async prepare(
    lynxAppId: string,
    bundleName: string,
    signal: OtaPrepareSignal
  ): Promise<PreparedPageBundle> {
    signal.throwIfCancelled();
    const result = await this.registry.resolve(lynxAppId, bundleName);
    signal.throwIfCancelled();
    if (result === null) {
      throw new Error(`没有内置 Bundle：${lynxAppId}/${bundleName}`);
    }
    return result;
  }

  resolveCurrent(lynxAppId: string, bundleName: string): Promise<PreparedPageBundle | null> {
    return this.registry.resolve(lynxAppId, bundleName);
  }

  refreshAppBundleIfNeeded(lynxAppId: string): void {
  }

  rollback(lynxAppId: string, reason: string): Promise<boolean> {
    return Promise.resolve(false);
  }

  deleteBundles(lynxAppId: string): Promise<void> {
    return Promise.resolve();
  }

  deleteAllBundles(): Promise<void> {
    return Promise.resolve();
  }

  storageRoot(): string {
    return this.registry.storageRoot();
  }
}
