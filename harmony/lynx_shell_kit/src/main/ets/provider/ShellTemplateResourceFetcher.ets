import { AsyncCallback, BusinessError } from '@ohos.base';
import http from '@ohos.net.http';
import resourceManager from '@ohos.resourceManager';
import fs from '@ohos.file.fs';
import { LynxResourceRequest, LynxTemplateResourceFetcher, TemplateProviderResult } from '@lynx/lynx';
import ShellConstants from '../common/ShellConstants';
import ShellSecurityPolicy from '../common/ShellSecurityPolicy';
import { OtaUserContext } from '../ota/OtaUserContext';

/**
 * Lynx Bundle / SSR 数据加载器。
 *
 * 本地资源只允许 rawfile 相对路径；远程模板必须通过 HTTPS、后缀和体积校验。
 * Direct HTTPS 优先读取应用私有的 URL 级缓存，并在命中后后台重新下载；不写 OTA Store，
 * 也不参与 appId、Manifest、release、current/previous 或回滚。需要 OTA 的页面仍必须由
 * 独立 OTA SDK 先交付已校验 Bundle。
 */
export default class ShellTemplateResourceFetcher extends LynxTemplateResourceFetcher {
  private readonly allowHttpInDebug: boolean;
  private readonly preparedUrl: string;
  private readonly preparedFilePath: string;
  private readonly preparedStorageRoot: string;
  private readonly preparedBytes: ArrayBuffer | null;
  private preparedConsumed: boolean = false;
  private readonly activeRequests: Set<http.HttpRequest> = new Set();
  private requestGeneration: number = 0;

  constructor(
    allowHttpInDebug: boolean = false,
    preparedUrl: string = '',
    preparedFilePath: string = '',
    preparedStorageRoot: string = '',
    preparedBytes: ArrayBuffer | null = null
  ) {
    super();
    this.allowHttpInDebug = allowHttpInDebug;
    this.preparedUrl = preparedUrl;
    this.preparedFilePath = preparedFilePath;
    this.preparedStorageRoot = preparedStorageRoot;
    this.preparedBytes = preparedBytes;
  }

  fetchTemplate(
    request: LynxResourceRequest,
    callback: AsyncCallback<TemplateProviderResult, void>
  ): void {
    this.loadBinary(request.url, (error: BusinessError, data: ArrayBuffer) => {
      callback(error, { binary: data });
    });
  }

  fetchSSRData(request: LynxResourceRequest, callback: AsyncCallback<ArrayBuffer, void>): void {
    this.loadBinary(request.url, callback);
  }

  private loadBinary(rawUrl: string, callback: AsyncCallback<ArrayBuffer, void>): void {
    const generation = this.requestGeneration;
    if (!this.preparedConsumed && this.preparedUrl.length > 0 && rawUrl === this.preparedUrl) {
      this.preparedConsumed = true;
      this.loadPreparedBundle(callback, generation);
      return;
    }
    if (ShellSecurityPolicy.isRemoteUrl(rawUrl)) {
      this.loadRemote(rawUrl, callback, generation);
      return;
    }
    this.loadLocal(rawUrl, callback, generation);
  }

  /**
   * OTA 根 Bundle 已经在 ContentAddressedOtaStore 中完成 size/SHA 校验；Fetcher 对远程文件仍二次
   * 限制路径、普通文件和体积；embedded rawfile 则直接消费已校验的 ArrayBuffer。
   */
  private loadPreparedBundle(
    callback: AsyncCallback<ArrayBuffer, void>,
    generation: number
  ): void {
    if (generation !== this.requestGeneration) return;
    if (this.preparedBytes !== null) {
      if (generation === this.requestGeneration) callback(undefined, this.preparedBytes.slice(0));
      return;
    }
    const root = this.preparedStorageRoot.endsWith('/') ?
      this.preparedStorageRoot.substring(0, this.preparedStorageRoot.length - 1) : this.preparedStorageRoot;
    if (root.length === 0 || !this.preparedFilePath.startsWith(`${root}/`)) {
      if (generation === this.requestGeneration) {
        callback(this.createError(1101, 'OTA Bundle 路径不在受控 Store 内'), new ArrayBuffer(0));
      }
      return;
    }
    try {
      if (this.containsSymbolicLink(root, this.preparedFilePath)) {
        if (generation === this.requestGeneration) {
          callback(this.createError(1102, 'OTA Bundle 路径包含符号链接'), new ArrayBuffer(0));
        }
        return;
      }
      const stat = fs.lstatSync(this.preparedFilePath);
      if (!stat.isFile() || stat.isSymbolicLink()) {
        if (generation === this.requestGeneration) {
          callback(this.createError(1102, 'OTA Bundle 不是普通文件'), new ArrayBuffer(0));
        }
        return;
      }
      if (stat.size <= 0 || stat.size > ShellConstants.MAX_BUNDLE_BYTES) {
        if (generation === this.requestGeneration) {
          callback(this.createError(1103, 'OTA Bundle 大小越界'), new ArrayBuffer(0));
        }
        return;
      }
      const file = fs.openSync(this.preparedFilePath, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const binary = new ArrayBuffer(stat.size);
        const count = fs.readSync(file.fd, binary);
        if (count !== stat.size) {
          if (generation === this.requestGeneration) {
            callback(this.createError(1104, 'OTA Bundle 读取不完整'), new ArrayBuffer(0));
          }
          return;
        }
        if (generation === this.requestGeneration) callback(undefined, binary);
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      if (generation === this.requestGeneration) {
        callback(this.createError(1105, `读取 OTA Bundle 失败：${error}`), new ArrayBuffer(0));
      }
    }
  }

  /** 从受控 Store 根目录逐段 lstat，禁止通过父目录 symlink 绕出 Store。 */
  private containsSymbolicLink(root: string, filePath: string): boolean {
    if (fs.lstatSync(root).isSymbolicLink()) {
      return true;
    }
    const relative = filePath.substring(root.length + 1);
    let current = root;
    for (const segment of relative.split('/')) {
      current = `${current}/${segment}`;
      if (fs.lstatSync(current).isSymbolicLink()) {
        return true;
      }
    }
    return false;
  }

  private loadRemote(
    rawUrl: string,
    callback: AsyncCallback<ArrayBuffer, void>,
    generation: number
  ): void {
    if (generation !== this.requestGeneration) return;
    const validation = ShellSecurityPolicy.validateTemplateUrl(rawUrl, this.allowHttpInDebug);
    if (!validation.valid) {
      if (generation === this.requestGeneration) {
        callback(this.createError(1001, validation.message), new ArrayBuffer(0));
      }
      return;
    }

    const isHttps = rawUrl.toLowerCase().startsWith('https://');
    const cachePath = isHttps ? this.remoteCachePath(rawUrl) : '';
    if (cachePath.length > 0) {
      const cached = ShellTemplateResourceFetcher.readRemoteCache(cachePath);
      if (cached !== null) {
        if (generation !== this.requestGeneration) return;
        callback(undefined, cached);
        ShellTemplateResourceFetcher.scheduleRemoteRefresh(
          rawUrl,
          cachePath,
          this.allowHttpInDebug
        );
        return;
      }
    }

    this.loadRemoteFromNetwork(rawUrl, cachePath, callback, generation);
  }

  private loadRemoteFromNetwork(
    rawUrl: string,
    cachePath: string,
    callback: AsyncCallback<ArrayBuffer, void>,
    generation: number
  ): void {

    const httpRequest = http.createHttp();
    this.activeRequests.add(httpRequest);
    httpRequest.request(rawUrl, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15_000,
      readTimeout: 30_000
    }, (error: BusinessError, response: http.HttpResponse) => {
      try {
        if (error && error.code !== 0) {
          if (generation === this.requestGeneration) callback(error, new ArrayBuffer(0));
          return;
        }
        if (response.responseCode < 200 || response.responseCode >= 300) {
          if (generation === this.requestGeneration) {
            callback(this.createError(response.responseCode, `Bundle HTTP 状态异常: ${response.responseCode}`), new ArrayBuffer(0));
          }
          return;
        }

        const binary = response.result as ArrayBuffer;
        if (binary === undefined || binary.byteLength === 0) {
          if (generation === this.requestGeneration) {
            callback(this.createError(1002, '远程 Bundle 内容为空'), new ArrayBuffer(0));
          }
          return;
        }
        if (binary.byteLength > ShellConstants.MAX_BUNDLE_BYTES) {
          if (generation === this.requestGeneration) {
            callback(this.createError(1003, `远程 Bundle 超过 ${ShellConstants.MAX_BUNDLE_BYTES} 字节`), new ArrayBuffer(0));
          }
          return;
        }
        if (cachePath.length > 0) {
          ShellTemplateResourceFetcher.writeRemoteCache(cachePath, binary);
        }
        if (generation === this.requestGeneration) callback(undefined, binary);
      } finally {
        httpRequest.destroy();
        this.activeRequests.delete(httpRequest);
      }
    });
  }

  private remoteCachePath(rawUrl: string): string {
    const context: Context = getContext(this);
    const cacheRoot = `${context.filesDir}/lynx-https-bundles`;
    // 只用 URL 生成文件名；这里不计算、不校验 Bundle 内容 SHA-256。
    const key = OtaUserContext.hash(rawUrl).replace(':', '-');
    return `${cacheRoot}/${key}.lynx.bundle`;
  }

  private static refreshingRemoteUrls: Set<string> = new Set<string>();

  private static readRemoteCache(path: string): ArrayBuffer | null {
    try {
      const stat = fs.lstatSync(path);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0 ||
        stat.size > ShellConstants.MAX_BUNDLE_BYTES) {
        return null;
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const binary = new ArrayBuffer(stat.size);
        const count = fs.readSync(file.fd, binary);
        return count === stat.size ? binary : null;
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      return null;
    }
  }

  private static scheduleRemoteRefresh(
    rawUrl: string,
    cachePath: string,
    allowHttpInDebug: boolean
  ): void {
    if (this.refreshingRemoteUrls.has(rawUrl)) return;
    this.refreshingRemoteUrls.add(rawUrl);
    const httpRequest = http.createHttp();
    try {
      httpRequest.request(rawUrl, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15_000,
        readTimeout: 30_000,
        usingCache: false
      }, (error: BusinessError, response: http.HttpResponse) => {
        try {
          if (error && error.code !== 0) return;
          if (response.responseCode < 200 || response.responseCode >= 300) return;
          const binary = response.result as ArrayBuffer;
          if (binary === undefined || binary.byteLength === 0 ||
            binary.byteLength > ShellConstants.MAX_BUNDLE_BYTES) return;
          const validation = ShellSecurityPolicy.validateTemplateUrl(rawUrl, allowHttpInDebug);
          if (!validation.valid) return;
          this.writeRemoteCache(cachePath, binary);
        } finally {
          httpRequest.destroy();
          this.refreshingRemoteUrls.delete(rawUrl);
        }
      });
    } catch (error) {
      httpRequest.destroy();
      this.refreshingRemoteUrls.delete(rawUrl);
    }
  }

  /** 临时文件写完后再替换正式缓存；后台失败不影响当前页面。 */
  private static writeRemoteCache(path: string, binary: ArrayBuffer): void {
    if (binary.byteLength === 0 || binary.byteLength > ShellConstants.MAX_BUNDLE_BYTES) return;
    const directory = path.substring(0, path.lastIndexOf('/'));
    const temporary = `${path}.part-${new Date().getTime()}-${Math.floor(Math.random() * 1000000)}`;
    try {
      if (!fs.accessSync(directory)) fs.mkdirSync(directory, true);
    } catch (error) {
      try { fs.mkdirSync(directory, true); } catch (mkdirError) { return; }
    }
    try {
      const file = fs.openSync(temporary, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        const count = fs.writeSync(file.fd, binary);
        if (count !== binary.byteLength) throw new Error('远程 Bundle 缓存写入不完整');
        fs.fsyncSync(file.fd);
      } finally {
        fs.closeSync(file);
      }
      fs.moveFileSync(temporary, path, 0);
    } catch (error) {
      try {
        if (fs.accessSync(temporary)) fs.unlinkSync(temporary);
      } catch (cleanupError) {
        // 临时文件清理失败不影响当前页面，下一次缓存读取会忽略它。
      }
    }
  }

  /** 页面退出或重试时释放尚未结束的模板请求。 */
  cancelAll(): void {
    this.requestGeneration += 1;
    this.activeRequests.forEach((request: http.HttpRequest) => request.destroy());
    this.activeRequests.clear();
  }

  private loadLocal(
    path: string,
    callback: AsyncCallback<ArrayBuffer, void>,
    generation: number
  ): void {
    if (generation !== this.requestGeneration) return;
    // LynxView 的本地模板 URL 使用 assets://；ResourceManager 只接受 rawfile 相对路径，
    // 因此在安全校验前统一去掉本地 scheme，避免 direct Bundle 被误判为非法 URL。
    let rawPath = path;
    if (rawPath.startsWith('local://')) {
      rawPath = rawPath.substring('local://'.length);
    } else if (rawPath.startsWith('assets://')) {
      rawPath = rawPath.substring('assets://'.length);
    }

    const validation = ShellSecurityPolicy.validateLocalRawFilePath(rawPath);
    if (!validation.valid) {
      if (generation === this.requestGeneration) {
        callback(this.createError(1004, validation.message), new ArrayBuffer(0));
      }
      return;
    }

    const context: Context = getContext(this);
    const manager: resourceManager.ResourceManager = context.resourceManager;
    manager.getRawFileContent(rawPath, (error: BusinessError, data: Uint8Array) => {
      if (generation !== this.requestGeneration) return;
      if (error && error.code !== 0) {
        callback(error, new ArrayBuffer(0));
        return;
      }
      if (data.byteLength === 0) {
        callback(this.createError(1005, '本地 Bundle 内容为空'), new ArrayBuffer(0));
        return;
      }
      if (data.byteLength > ShellConstants.MAX_BUNDLE_BYTES) {
        callback(this.createError(1006, `本地 Bundle 超过 ${ShellConstants.MAX_BUNDLE_BYTES} 字节`), new ArrayBuffer(0));
        return;
      }
      callback(undefined, data.buffer as ArrayBuffer);
    });
  }

  private createError(code: number, message: string): BusinessError {
    return {
      code: code,
      message: message,
      name: 'LynxShellTemplateError'
    };
  }
}
