import { fileIo, fileUri } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import util from '@ohos.util';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';
import { LynxHarmonyMediaCapabilities } from './LynxHarmonyMediaCapabilities';
import { LynxHarmonyTransfer } from './LynxHarmonyTransfer';
import { LynxHarmonyFilesystem } from './LynxHarmonyFilesystem';
import { LYNX_PAYLOAD_BYTES, LYNX_INLINE_BYTES, LYNX_FILE_BYTES, LYNX_RESULT_BYTES, LynxHarmonyNativeIO, lynxUTF8Bytes } from './LynxHarmonyNativeIO';

/** 仅转换 Shell 五方法旧 ABI；Camera/下载与 Capacitor 共用同一个 owner/backend。 */
export class LynxHarmonyLegacyMedia {
  private static dataURLBusy: boolean = false;
  private readonly owner: LynxHarmonyNativeOwner;
  private readonly context: () => common.UIAbilityContext;
  private readonly media: LynxHarmonyMediaCapabilities;
  private readonly transfer: LynxHarmonyTransfer;
  constructor(owner: LynxHarmonyNativeOwner, context: () => common.UIAbilityContext,
    media: LynxHarmonyMediaCapabilities, transfer: LynxHarmonyTransfer) { this.owner = owner; this.context = context; this.media = media; this.transfer = transfer; }

  public dispatch(method: string, optionsJSON: string, callback: (json: string) => void): void {
    let finished = false;
    const key = 'legacy:' + util.generateRandomUUID(false);
    const complete = (data: Object | null, error: Object | null): void => {
      if (finished) return;
      finished = true;
      this.owner.disown(key);
      const receipt = error === null ? { code: 0, msg: 'ok', data: data ?? {} } : { code: -1, msg: String(error) };
      const json = JSON.stringify(receipt);
      callback(lynxUTF8Bytes(json) > LYNX_RESULT_BYTES ? JSON.stringify({ code: -1, msg: 'RESULT_TOO_LARGE: 媒体结果超过 2 MiB' }) : json);
    };
    if (!this.owner.isActive) { complete(null, new Error('ACTIVITY_DESTROYED: 页面已销毁')); return; }
    this.owner.own(key, (): void => complete(null, new Error('ACTIVITY_DESTROYED: 页面关闭取消媒体调用')));
    let operation: Promise<Object>;
    try {
      if (method === 'saveDataURL') operation = this.saveDataURL(optionsJSON);
      else {
        if (lynxUTF8Bytes(optionsJSON) > LYNX_PAYLOAD_BYTES) throw new Error('PAYLOAD_TOO_LARGE: 普通媒体参数超过 1 MiB');
        const options = JSON.parse(optionsJSON) as Record<string, Object>;
        if (options === null || typeof options !== 'object' || Array.isArray(options)) throw new Error('INVALID_ARGUMENT: 媒体参数必须为 JSON 对象');
        if (method === 'chooseMedia') operation = this.choose(options);
        else if (method === 'downloadFile') {
          const extension = this.extension(options['extension']);
          const mapped: Record<string, Object> = { url: options['url'], directory: 'TEMPORARY', path: 'lynx-download-' + util.generateRandomUUID(false) + '.' + extension };
          if (options['header'] !== undefined) mapped['headers'] = options['header'];
          operation = this.transfer.dispatch('downloadFile', mapped).then((value: Object): Object => {
            const result = value as Record<string, Object>;
            return { httpCode: result['responseCode'], clientCode: 0, filePath: result['uri'] };
          });
        } else if (method === 'uploadFile' || method === 'uploadImage') operation = this.upload(options);
        else throw new Error('UNSUPPORTED: 未知旧媒体方法');
      }
    } catch (error) { complete(null, error as Object); return; }
    operation.then((data: Object): void => {
      if (!this.owner.isActive) complete(null, new Error('ACTIVITY_DESTROYED: 页面已关闭'));
      else complete(data, null);
    }).catch((error: Object): void => complete(null, error));
  }

  private choose(options: Record<string, Object>): Promise<Object> {
    let count = 1;
    ['count', 'maxCount'].forEach((name: string): void => {
      const value = options[name];
      if (value === undefined) return;
      if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 1 || value > 16) throw new Error('INVALID_ARGUMENT: ' + name + ' 必须为 1...16 整数');
      count = value;
    });
    const requested = Array.isArray(options['mediaTypes']) ? options['mediaTypes'] as Array<string> : ['image'];
    const mixed = requested.includes('image') && requested.includes('video');
    const video = requested.includes('video') && !requested.includes('image');
    const mapped: Record<string, Object> = { source: options['sourceType'] === 'camera' ? 'CAMERA' : 'PHOTOS', mediaType: mixed ? 2 : video ? 1 : 0, limit: count, resultType: 'URI' };
    ['cameraDirection', 'includeMicrophone', 'saveToGallery', 'videoDuration'].forEach((key: string): void => { if (options[key] !== undefined) mapped[key] = options[key]; });
    return new Promise<Object>((resolve, reject): void => {
      this.media.dispatch('-1', 'Camera', 'chooseFromGallery', mapped, (json: string): void => {
        try {
          const envelope = JSON.parse(json) as Record<string, Object>;
          if (envelope['success'] !== true) { const error = envelope['error'] as Record<string, Object>; reject(new Error(String(error['code']) + ': ' + String(error['message']))); return; }
          const data = envelope['data'] as Record<string, Object>;
          if (!Array.isArray(data['results'])) throw new Error('MEDIA_CONTRACT_ERROR: 媒体选择没有返回 results');
          const files = (data['results'] as Array<Record<string, Object>>).map((item: Record<string, Object>): Record<string, Object> => ({ tempFilePath: item['uri'], tempFileAbsolutePath: item['path'], size: item['size'], mediaType: Number(item['type']) === 1 ? 'video' : 'image', mimeType: item['mimeType'] }));
          resolve({ tempFiles: files });
        } catch (error) { reject(error as Object); }
      });
    });
  }

  private saveDataURL(optionsJSON: string): Promise<Object> {
    if (lynxUTF8Bytes(optionsJSON) > Math.ceil(LYNX_FILE_BYTES / 3) * 4 + 64 * 1024) throw new Error('PAYLOAD_TOO_LARGE: Data URL 超过 20 MiB');
    if (LynxHarmonyLegacyMedia.dataURLBusy) throw new Error('BUSY: 已有一个大 Data URL 正在处理');
    LynxHarmonyLegacyMedia.dataURLBusy = true;
    let started = false;
    const folder = this.context().tempDir;
    const identifier = util.generateRandomUUID(false);
    return LynxHarmonyNativeIO.run(this.owner, async (): Promise<Object> => {
      started = true;
      let part = '';
      try {
        const result = await LynxHarmonyNativeIO.directTask('stageLegacyDataURL', [optionsJSON, folder, identifier]) as Record<string, Object>;
        part = String(result['part']);
        this.owner.checkActive();
        const path = String(result['path']);
        fileIo.renameSync(part, path);
        return { filePath: fileUri.getUriFromPath(path) };
      } finally {
        // worker 即使抛错也在其自身 finally 删除失败的 part。
        if (part.length > 0 && fileIo.accessSync(part)) fileIo.unlinkSync(part);
        LynxHarmonyLegacyMedia.dataURLBusy = false;
      }
    }).catch((error: Object): Object => { if (!started) LynxHarmonyLegacyMedia.dataURLBusy = false; throw error; });
  }

  private upload(options: Record<string, Object>): Promise<Object> {
    return LynxHarmonyNativeIO.run(this.owner, async (): Promise<Object> => {
      const url = String(options['url'] ?? '');
      if (!/^https?:\/\//.test(url)) throw new Error('INVALID_ARGUMENT: 上传 URL 必须为 HTTP(S)');
      const path = LynxHarmonyFilesystem.resolve(this.context(), String(options['filePath'] ?? ''), 'CACHE');
      await LynxHarmonyFilesystem.stat(this.owner, path, LYNX_FILE_BYTES, true);
      const snapshot = this.context().tempDir + '/lynx-upload-' + util.generateRandomUUID(false) + '.part';
      let request: http.HttpRequest | null = null;
      const key = 'upload:' + util.generateRandomUUID(false);
      try {
        await LynxHarmonyNativeIO.directTask('copy', [path, snapshot, [this.context().filesDir, this.context().cacheDir, this.context().tempDir]]);
        this.owner.checkActive();
        request = http.createHttp();
        const activeRequest = request;
        this.owner.own(key, (): void => activeRequest.destroy());
        const config: http.HttpRequestOptions = { method: http.RequestMethod.POST, expectDataType: http.HttpDataType.STRING, maxLimit: LYNX_INLINE_BYTES, connectTimeout: 60000, readTimeout: 60000, multiFormDataList: [{ name: 'file', contentType: 'application/octet-stream', remoteFileName: path.substring(path.lastIndexOf('/') + 1), filePath: snapshot }] };
        if (options['header'] !== undefined) config.header = options['header'];
        const response = await request.request(url, config);
        this.owner.checkActive();
        if (response.responseCode < 200 || response.responseCode >= 300) throw new Error('HTTP_ERROR: 上传失败，HTTP ' + String(response.responseCode));
        const text = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
        if (lynxUTF8Bytes(text) > LYNX_INLINE_BYTES) throw new Error('RESPONSE_TOO_LARGE: 上传响应超过 512 KiB');
        let value: Object = text;
        if (text.length === 0) value = {};
        else { try { value = JSON.parse(text) as Object; } catch (_error) { value = text; } }
        return { url: url, clientCode: 0, response: value };
      } finally {
        this.owner.disown(key);
        request?.destroy();
        if (fileIo.accessSync(snapshot)) fileIo.unlinkSync(snapshot);
      }
    });
  }

  private extension(raw: Object | undefined): string {
    const extension = String(raw ?? 'bin').replace(/^\.+/, '');
    return /^[A-Za-z0-9]{1,10}$/.test(extension) ? extension.toLowerCase() : 'bin';
  }
}
