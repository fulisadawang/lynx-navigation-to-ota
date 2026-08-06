import { AsyncCallback, BusinessError } from '@ohos.base';
import http from '@ohos.net.http';
import resourceManager from '@ohos.resourceManager';
import { CacheStrategy, ImageKnife, ImageKnifeOption } from '@ohos/imageknifepro';
import {
  LynxError,
  LynxGenericResourceFetcher,
  LynxResourceRequest,
  LynxResourceType,
  LynxStreamDelegate,
  LynxSubErrorCode
} from '@lynx/lynx';
import ShellConstants from '../common/ShellConstants';
import ShellSecurityPolicy from '../common/ShellSecurityPolicy';

/** 字体、图片和通用二进制资源 Fetcher，支持真实取消而不是空实现。 */
export default class ShellGenericResourceFetcher extends LynxGenericResourceFetcher {
  private readonly activeRequests: Map<string, http.HttpRequest> = new Map();

  fetchResource(request: LynxResourceRequest, callback: AsyncCallback<ArrayBuffer, void>): void {
    if (ShellSecurityPolicy.isRemoteUrl(request.url)) {
      this.fetchRemote(request, callback);
      return;
    }
    this.fetchLocal(request.url, callback);
  }

  fetchResourcePath(request: LynxResourceRequest, callback: AsyncCallback<string, void>): void {
    if (request.type !== LynxResourceType.LYNX_RESOURCE_TYPE_IMAGE) {
      callback(this.createError(
        LynxError.LYNX_ERROR_CODE_RESOURCE,
        `不支持输出本地路径的资源类型: ${request.type}`
      ), '');
      return;
    }

    if (request.url.startsWith('local://') || request.url.startsWith('assets://')) {
      const prefix = request.url.startsWith('local://') ? 'local://' : 'assets://';
      const rawPath = request.url.substring(prefix.length);
      const localValidation = ShellSecurityPolicy.validateLocalRawFilePath(rawPath);
      if (!localValidation.valid) {
        callback(this.createError(LynxSubErrorCode.E_RESOURCE_IMAGE_PIC_SOURCE, localValidation.message), '');
        return;
      }
      callback(undefined, `resource://rawfile/${rawPath}`);
      return;
    }

    const validation = ShellSecurityPolicy.validateResourceUrl(request.url);
    if (!validation.valid) {
      callback(this.createError(LynxSubErrorCode.E_RESOURCE_IMAGE_PIC_SOURCE, validation.message), '');
      return;
    }

    const option = new ImageKnifeOption();
    option.loadSrc = request.url;
    option.writeCacheStrategy = CacheStrategy.FILE;
    ImageKnife.getInstance().preloadCache(option).then((path: string) => {
      if (path.length > 0) {
        callback(undefined, path);
      } else {
        callback(this.createError(
          LynxSubErrorCode.E_RESOURCE_IMAGE_PIC_SOURCE,
          'ImageKnife 未返回有效缓存路径'
        ), '');
      }
    }).catch((error: Error) => {
      callback(this.createError(
        LynxSubErrorCode.E_RESOURCE_IMAGE_FROM_NETWORK_OR_OTHERS,
        error.message
      ), '');
    });
  }

  fetchStream(request: LynxResourceRequest, delegate: LynxStreamDelegate): void {
    this.fetchResource(request, (error: BusinessError, data: ArrayBuffer) => {
      if (error && error.code !== 0) {
        delegate.onStart(0);
        delegate.onEnd();
        return;
      }
      delegate.onStart(data.byteLength);
      delegate.onData(data, 0, data.byteLength);
      delegate.onEnd();
    });
  }

  cancel(request: LynxResourceRequest): void {
    const active = this.activeRequests.get(request.url);
    if (active !== undefined) {
      active.destroy();
      this.activeRequests.delete(request.url);
    }
  }

  /** 容器销毁或重试时批量释放所有通用资源请求。 */
  cancelAll(): void {
    this.activeRequests.forEach((request: http.HttpRequest) => request.destroy());
    this.activeRequests.clear();
  }

  private fetchRemote(request: LynxResourceRequest, callback: AsyncCallback<ArrayBuffer, void>): void {
    const validation = ShellSecurityPolicy.validateResourceUrl(request.url);
    if (!validation.valid) {
      callback(this.createError(LynxError.LYNX_ERROR_CODE_RESOURCE, validation.message), new ArrayBuffer(0));
      return;
    }

    const httpRequest = http.createHttp();
    this.activeRequests.set(request.url, httpRequest);
    httpRequest.request(request.url, {
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
          callback(this.createError(
            LynxError.LYNX_ERROR_CODE_RESOURCE,
            `资源 HTTP 状态异常: ${response.responseCode}`
          ), new ArrayBuffer(0));
          return;
        }
        const binary = response.result as ArrayBuffer;
        if (binary === undefined || binary.byteLength === 0) {
          callback(this.createError(LynxError.LYNX_ERROR_CODE_RESOURCE, '远程资源内容为空'), new ArrayBuffer(0));
          return;
        }
        if (binary.byteLength > ShellConstants.MAX_BUNDLE_BYTES) {
          callback(this.createError(LynxError.LYNX_ERROR_CODE_RESOURCE, '资源体积超过 20 MB'), new ArrayBuffer(0));
          return;
        }
        callback(undefined, binary);
      } finally {
        httpRequest.destroy();
        this.activeRequests.delete(request.url);
      }
    });
  }

  private fetchLocal(path: string, callback: AsyncCallback<ArrayBuffer, void>): void {
    let rawPath = path;
    if (rawPath.startsWith('local://')) {
      rawPath = rawPath.substring('local://'.length);
    } else if (rawPath.startsWith('assets://')) {
      rawPath = rawPath.substring('assets://'.length);
    }

    const validation = ShellSecurityPolicy.validateLocalRawFilePath(rawPath);
    if (!validation.valid) {
      callback(this.createError(LynxError.LYNX_ERROR_CODE_RESOURCE, validation.message), new ArrayBuffer(0));
      return;
    }

    const context: Context = getContext(this);
    const manager: resourceManager.ResourceManager = context.resourceManager;
    manager.getRawFileContent(rawPath, (error: BusinessError, data: Uint8Array) => {
      if (error && error.code !== 0) {
        callback(error, new ArrayBuffer(0));
        return;
      }
      if (data.byteLength === 0) {
        callback(this.createError(LynxError.LYNX_ERROR_CODE_RESOURCE, '本地资源内容为空'), new ArrayBuffer(0));
        return;
      }
      if (data.byteLength > ShellConstants.MAX_BUNDLE_BYTES) {
        callback(this.createError(LynxError.LYNX_ERROR_CODE_RESOURCE, '本地资源体积超过 20 MB'), new ArrayBuffer(0));
        return;
      }
      callback(undefined, data.buffer as ArrayBuffer);
    });
  }

  private createError(code: number, message: string): BusinessError {
    return { code: code, message: message, name: 'LynxShellResourceError' };
  }
}
