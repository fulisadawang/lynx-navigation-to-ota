import { AsyncCallback, BusinessError } from '@ohos.base';
import http from '@ohos.net.http';
import resourceManager from '@ohos.resourceManager';
import fs from '@ohos.file.fs';
import { LynxResourceRequest, LynxTemplateResourceFetcher, TemplateProviderResult } from '@lynx/lynx';
import ShellConstants from '../common/ShellConstants';
import ShellSecurityPolicy from '../common/ShellSecurityPolicy';

/**
 * Lynx Bundle / SSR 数据加载器。
 *
 * 本地资源只允许 rawfile 相对路径；远程模板必须通过 HTTPS、后缀和体积校验。
 * 这里的 HTTPS 请求只负责 DirectRemoteBundle，不写 OTA 缓存，也不参与 Manifest、
 * current/previous 或回滚；需要 OTA 的页面必须由独立 OTA SDK 先交付已校验 Bundle。
 */
export default class ShellTemplateResourceFetcher extends LynxTemplateResourceFetcher {
  private readonly allowHttpInDebug: boolean;
  private readonly preparedUrl: string;
  private readonly preparedFilePath: string;
  private readonly preparedStorageRoot: string;
  private readonly preparedBytes: ArrayBuffer | null;
  private preparedConsumed: boolean = false;
  private readonly activeRequests: Set<http.HttpRequest> = new Set();

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
    if (!this.preparedConsumed && this.preparedUrl.length > 0 && rawUrl === this.preparedUrl) {
      this.preparedConsumed = true;
      this.loadPreparedBundle(callback);
      return;
    }
    if (ShellSecurityPolicy.isRemoteUrl(rawUrl)) {
      this.loadRemote(rawUrl, callback);
      return;
    }
    this.loadLocal(rawUrl, callback);
  }

  /**
   * OTA 根 Bundle 已经在 ReleaseTransaction 中完成 size/SHA 校验；Fetcher 对远程文件仍二次
   * 限制路径、普通文件和体积；embedded rawfile 则直接消费已校验的 ArrayBuffer。
   */
  private loadPreparedBundle(callback: AsyncCallback<ArrayBuffer, void>): void {
    if (this.preparedBytes !== null) {
      callback(undefined, this.preparedBytes.slice(0));
      return;
    }
    const root = this.preparedStorageRoot.endsWith('/') ?
      this.preparedStorageRoot.substring(0, this.preparedStorageRoot.length - 1) : this.preparedStorageRoot;
    if (root.length === 0 || !this.preparedFilePath.startsWith(`${root}/`)) {
      callback(this.createError(1101, 'OTA Bundle 路径不在受控 Store 内'), new ArrayBuffer(0));
      return;
    }
    try {
      if (this.containsSymbolicLink(root, this.preparedFilePath)) {
        callback(this.createError(1102, 'OTA Bundle 路径包含符号链接'), new ArrayBuffer(0));
        return;
      }
      const stat = fs.lstatSync(this.preparedFilePath);
      if (!stat.isFile() || stat.isSymbolicLink()) {
        callback(this.createError(1102, 'OTA Bundle 不是普通文件'), new ArrayBuffer(0));
        return;
      }
      if (stat.size <= 0 || stat.size > ShellConstants.MAX_BUNDLE_BYTES) {
        callback(this.createError(1103, 'OTA Bundle 大小越界'), new ArrayBuffer(0));
        return;
      }
      const file = fs.openSync(this.preparedFilePath, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const binary = new ArrayBuffer(stat.size);
        const count = fs.readSync(file.fd, binary);
        if (count !== stat.size) {
          callback(this.createError(1104, 'OTA Bundle 读取不完整'), new ArrayBuffer(0));
          return;
        }
        callback(undefined, binary);
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      callback(this.createError(1105, `读取 OTA Bundle 失败：${error}`), new ArrayBuffer(0));
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

  private loadRemote(rawUrl: string, callback: AsyncCallback<ArrayBuffer, void>): void {
    const validation = ShellSecurityPolicy.validateTemplateUrl(rawUrl, this.allowHttpInDebug);
    if (!validation.valid) {
      callback(this.createError(1001, validation.message), new ArrayBuffer(0));
      return;
    }

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
          callback(error, new ArrayBuffer(0));
          return;
        }
        if (response.responseCode < 200 || response.responseCode >= 300) {
          callback(this.createError(response.responseCode, `Bundle HTTP 状态异常: ${response.responseCode}`), new ArrayBuffer(0));
          return;
        }

        const binary = response.result as ArrayBuffer;
        if (binary === undefined || binary.byteLength === 0) {
          callback(this.createError(1002, '远程 Bundle 内容为空'), new ArrayBuffer(0));
          return;
        }
        if (binary.byteLength > ShellConstants.MAX_BUNDLE_BYTES) {
          callback(this.createError(1003, `远程 Bundle 超过 ${ShellConstants.MAX_BUNDLE_BYTES} 字节`), new ArrayBuffer(0));
          return;
        }
        callback(undefined, binary);
      } finally {
        httpRequest.destroy();
        this.activeRequests.delete(httpRequest);
      }
    });
  }

  /** 页面退出或重试时释放尚未结束的模板请求。 */
  cancelAll(): void {
    this.activeRequests.forEach((request: http.HttpRequest) => request.destroy());
    this.activeRequests.clear();
  }

  private loadLocal(path: string, callback: AsyncCallback<ArrayBuffer, void>): void {
    const validation = ShellSecurityPolicy.validateLocalRawFilePath(path);
    if (!validation.valid) {
      callback(this.createError(1004, validation.message), new ArrayBuffer(0));
      return;
    }

    const context: Context = getContext(this);
    const manager: resourceManager.ResourceManager = context.resourceManager;
    manager.getRawFileContent(path, (error: BusinessError, data: Uint8Array) => {
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
