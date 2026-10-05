import { camera, cameraPicker } from '@kit.CameraKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { Permissions } from '@kit.AbilityKit';
import dataSharePredicates from '@ohos.data.dataSharePredicates';
import Want from '@ohos.app.ability.Want';
import wantConstant from '@ohos.app.ability.wantConstant';
import LynxCapacitorEnvelope from './LynxCapacitorEnvelope';
import { LynxCapacitorHost } from './LynxCapacitorHost';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';
import { LynxHarmonyFilesystem } from './LynxHarmonyFilesystem';
import { LynxHarmonyPermissions } from './LynxHarmonyPermissions';
import { LYNX_INLINE_BYTES, LynxHarmonyNativeIO, lynxNativeErrorCode } from './LynxHarmonyNativeIO';
import { inspectHarmonyMedia, LynxHarmonyMediaInfo } from './LynxHarmonyMediaMetadata';
import { LynxHarmonyMediaDialog, LynxHarmonyPreviewImage, LynxHarmonyMediaMenu, LynxHarmonyMediaChoice } from './LynxHarmonyMediaDialog';
import { createHarmonyCaptureTarget, removeHarmonyCaptureTarget, LynxHarmonyCaptureTarget } from './LynxHarmonyCaptureTarget';

interface MediaRequest {
  callbackId: string;
  pluginId: string;
  methodName: string;
  callback: (json: string) => void;
  settled: boolean;
  paths: Array<string>;
}

interface SelectedMedia {
  uri: string;
  captured: boolean;
  type: number;
  privatePath?: string;
}

/** 每个 Lynx owner 的 Camera/FileViewer 后端；旧 Shell 与 SDK facade 由 Runtime 共用该实例。 */
export class LynxHarmonyMediaCapabilities {
  private owner: LynxHarmonyNativeOwner;
  private getHost: () => LynxCapacitorHost | null;
  private pending: MediaRequest | null = null;
  private preview: LynxHarmonyMediaDialog | null = null;
  private menu: LynxHarmonyMediaMenu | null = null;
  private grantedUris: Set<string> = new Set();
  private temporaryPaths: Set<string> = new Set();
  private captureTargets: Map<string, LynxHarmonyCaptureTarget> = new Map();
  private destroyed: boolean = false;

  constructor(owner: LynxHarmonyNativeOwner, getHost: () => LynxCapacitorHost | null) {
    this.owner = owner;
    this.getHost = getHost;
    owner.own('media-capabilities', (): void => this.destroy());
  }

  public dispatch(callbackId: string, pluginId: string, methodName: string, options: Record<string, Object>, callback: (json: string) => void): void {
    if (pluginId !== 'Camera' && pluginId !== 'FileViewer') {
      callback(LynxCapacitorEnvelope.failure(callbackId, pluginId, methodName, 'UNIMPLEMENTED', '媒体后端只处理 Camera/FileViewer'));
      return;
    }
    if (this.destroyed || !this.owner.isActive) {
      callback(LynxCapacitorEnvelope.failure(callbackId, pluginId, methodName, 'ACTIVITY_DESTROYED', '媒体 owner 已结束'));
      return;
    }
    if (this.pending !== null || this.preview !== null) {
      callback(LynxCapacitorEnvelope.failure(callbackId, pluginId, methodName, 'BUSY', '已有媒体选择或预览正在进行'));
      return;
    }
    const request: MediaRequest = { callbackId: callbackId, pluginId: pluginId, methodName: methodName, callback: callback, settled: false, paths: [] };
    this.pending = request;
    this.execute(request, options).then(async (data: Record<string, Object>): Promise<void> => {
      const dataJSON = String(await LynxHarmonyNativeIO.task(this.owner, 'stringify', [data]));
      this.owner.checkActive();
      // 已返回的选择文件与双端旧 Shell 一致，继续由系统 cache 生命周期持有。
      request.paths.forEach((path: string): void => this.retainFile(path));
      this.complete(request, LynxCapacitorEnvelope.successJSON(callbackId, pluginId, methodName, dataJSON));
    }).catch((error: Object): void => {
      this.closePreview();
      request.paths.forEach((path: string): void => this.removeStage(path));
      this.complete(request, LynxCapacitorEnvelope.failure(callbackId, pluginId, methodName, this.errorCode(error), this.errorMessage(error)));
    });
  }

  public retainFile(path: string): void {
    this.temporaryPaths.delete(path);
    this.captureTargets.delete(path);
    this.owner.disown('media-file:' + path);
  }

  /** 宿主 Page/Tab 的可见性改变时由 Runtime 调用；关闭后再次进入需显式重新预览。 */
  public onHostVisibilityChanged(): void {
    const host = this.getHost();
    if (host === null || !host.isVisible()) {
      this.closePreview();
      if (this.menu !== null) this.menu.cancel('UNAVAILABLE: 来源菜单所属页面已离开前台');
    }
  }

  public destroy(): void {
    if (this.destroyed) return;
    this.destroyed = true;
    const request = this.pending;
    if (request !== null) this.complete(request, LynxCapacitorEnvelope.failure(request.callbackId, request.pluginId, request.methodName, 'ACTIVITY_DESTROYED', '媒体 owner 已结束'));
    this.closePreview();
    if (this.menu !== null) this.menu.cancel('ACTIVITY_DESTROYED: 来源菜单 owner 已结束');
    this.grantedUris.clear();
    this.temporaryPaths.forEach((path: string): void => this.removeStage(path));
    this.temporaryPaths.clear();
    this.owner.disown('media-capabilities');
  }

  private async execute(request: MediaRequest, options: Record<string, Object>): Promise<Record<string, Object>> {
    const host = this.host();
    if (request.pluginId === 'FileViewer') return await this.previewFile(host, options, request.methodName);
    if (request.methodName === 'playVideo') {
      const path = this.localPath(host, options);
      const info = await inspectHarmonyMedia(this.owner, path, 1);
      this.checkHost(host);
      const uri = this.fileURI(path);
      await this.openPreview(host, [], 0, uri);
      return { playing: true, uri: uri, mimeType: info.mimeType };
    }
    if (request.methodName !== 'getPhoto' && request.methodName !== 'pickImages' && request.methodName !== 'chooseFromGallery' && request.methodName !== 'takePhoto' && request.methodName !== 'recordVideo') {
      throw new Error('UNIMPLEMENTED: 当前 Camera 方法不属于媒体操作');
    }
    const type = request.methodName === 'recordVideo' ? 1 : request.methodName === 'chooseFromGallery' ? this.mediaType(options) : 0;
    const limit = this.selectionLimit(options, request.methodName);
    const selected = await this.select(host, options, request.methodName, type, limit, request);
    this.checkHost(host);
    const results: Array<Record<string, Object>> = [];
    for (const item of selected) {
      this.checkHost(host);
      // 先取得不可变的私有缓存快照，再探测真实 MIME，避免 Provider 在两次读取间更换内容。
      const path = item.privatePath === undefined
        ? await LynxHarmonyFilesystem.copyToCache(this.owner, host.abilityContext, item.uri)
        : item.privatePath;
      this.owner.checkActive();
      if (this.destroyed) throw new Error('ACTIVITY_DESTROYED: 媒体 owner 已结束');
      if (!this.temporaryPaths.has(path)) {
        this.temporaryPaths.add(path);
        request.paths.push(path);
      }
      const info = await inspectHarmonyMedia(this.owner, path, item.type);
      if (request.methodName !== 'chooseFromGallery') {
        const resultType = this.resultType(options);
        if (resultType !== 'URI' && info.size > LYNX_INLINE_BYTES) {
          throw new Error('RESULT_TOO_LARGE: 请用 URI 接收超过 512 KiB 内联预算的媒体');
        }
      }
      this.checkHost(host);
      let saved = false;
      if ((item.captured || request.methodName !== 'chooseFromGallery') && this.boolean(options, 'saveToGallery', false)) {
        saved = await this.saveCapture(host, path, info);
      }
      results.push(await this.mediaResult(host, path, info, saved, options, request.methodName));
    }
    if (results.length === 0) throw new Error('CANCELLED: 用户取消了媒体选择');
    if (request.methodName === 'chooseFromGallery') return { results: results };
    if (request.methodName === 'pickImages') return { photos: results };
    return results[0];
  }

  private async select(host: LynxCapacitorHost, options: Record<string, Object>, method: string, type: number, limit: number, request: MediaRequest): Promise<Array<SelectedMedia>> {
    let source = method === 'takePhoto' || method === 'recordVideo' ? 'CAMERA' : this.string(options, 'source', method === 'getPhoto' ? 'PROMPT' : 'PHOTOS');
    if (source !== 'PHOTOS' && source !== 'CAMERA' && source !== 'PROMPT') throw new Error('INVALID_ARGUMENT: source 必须为 PHOTOS/CAMERA/PROMPT');
    let captureType = type;
    if (source === 'PROMPT' || (source === 'CAMERA' && type === 2)) {
      const choices: Array<LynxHarmonyMediaChoice> = [];
      if (source === 'PROMPT') choices.push({ value: 'PHOTOS', label: this.string(options, 'promptLabelPhotos', this.string(options, 'promptLabelPhoto', '从相册选择')) });
      if (type !== 1) choices.push({ value: 'PHOTO', label: this.string(options, 'promptLabelTakePhoto', this.string(options, 'promptLabelPicture', '拍照')) });
      if (type !== 0) choices.push({ value: 'VIDEO', label: this.string(options, 'promptLabelRecordVideo', '录像') });
      choices.push({ value: 'CANCEL', label: this.string(options, 'promptLabelCancel', '取消') });
      const menu = new LynxHarmonyMediaMenu(this.owner, host);
      this.menu = menu;
      let choice: string;
      try { choice = await menu.select(this.string(options, 'promptLabelHeader', '选择媒体'), choices); }
      finally { if (this.menu === menu) this.menu = null; }
      this.checkHost(host);
      if (choice === 'CANCEL') throw new Error('CANCELLED: 用户取消了来源选择');
      source = choice === 'PHOTOS' ? 'PHOTOS' : 'CAMERA';
      captureType = choice === 'VIDEO' ? 1 : choice === 'PHOTO' ? 0 : type;
    }
    if (source === 'PHOTOS') {
      const mime = type === 0 ? photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE : type === 1 ? photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE : photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
      const response = await this.scoped(host, (): Promise<photoAccessHelper.PhotoSelectResult> => new photoAccessHelper.PhotoViewPicker().select({ MIMEType: mime, maxSelectNumber: limit }));
      this.checkHost(host);
      if (response.photoUris.length === 0) throw new Error('CANCELLED: 用户取消了媒体选择');
      if (response.photoUris.length > limit) throw new Error('INVALID_ARGUMENT: 系统选择结果超过数量约束');
      const results: Array<SelectedMedia> = [];
      for (const uri of response.photoUris) {
        this.grantedUris.add(uri);
        const actualType = await this.assetType(host, uri);
        if (type !== 2 && actualType !== type) throw new Error('INVALID_ARGUMENT: 系统返回的媒体类型不符合过滤条件');
        results.push({ uri: uri, captured: false, type: actualType });
      }
      return results;
    }
    return [await this.capture(host, options, captureType, request)];
  }

  private async capture(host: LynxCapacitorHost, options: Record<string, Object>, type: number, request: MediaRequest): Promise<SelectedMedia> {
    const direction = this.string(options, 'cameraDirection', this.string(options, 'direction', 'BACK'));
    if (direction !== 'FRONT' && direction !== 'BACK') throw new Error('INVALID_ARGUMENT: cameraDirection 必须为 FRONT/BACK');
    const position = direction === 'FRONT' ? camera.CameraPosition.CAMERA_POSITION_FRONT : camera.CameraPosition.CAMERA_POSITION_BACK;
    if (type === 1 && !this.boolean(options, 'includeMicrophone', true)) throw new Error('UNSUPPORTED: 系统 CameraPicker 不支持关闭录像音轨');
    const permissions: Array<Permissions> = ['ohos.permission.CAMERA'];
    if (type === 1) permissions.push('ohos.permission.MICROPHONE');
    await LynxHarmonyPermissions.ensure(this.owner, host, permissions);
    this.checkHost(host);
    const devices = await this.scoped(host, (): Promise<Array<camera.CameraDevice>> => Promise.resolve(camera.getCameraManager(host.abilityContext).getSupportedCameras()));
    if (!devices.some((device: camera.CameraDevice): boolean => device.cameraPosition === position)) throw new Error('HARDWARE_UNAVAILABLE: 当前设备没有所请求方向的相机');
    const duration = options['videoDuration'] === undefined
      ? (options['duration'] === undefined ? (type === 1 ? 60 : undefined) : options['duration'])
      : options['videoDuration'];
    if (duration !== undefined && (typeof duration !== 'number' || !Number.isSafeInteger(duration) || duration <= 0)) throw new Error('INVALID_ARGUMENT: videoDuration 必须为正整数秒');
    const target = await createHarmonyCaptureTarget(this.owner, host.abilityContext, type === 1);
    this.owner.checkActive();
    if (this.destroyed) throw new Error('ACTIVITY_DESTROYED: 媒体 owner 已结束');
    this.temporaryPaths.add(target.path);
    this.captureTargets.set(target.path, target);
    request.paths.push(target.path);
    this.checkHost(host);
    const profile: cameraPicker.PickerProfile = duration === undefined
      ? { cameraPosition: position, saveUri: target.uri }
      : { cameraPosition: position, saveUri: target.uri, videoDuration: duration as number };
    const result = await this.scoped(host, (): Promise<cameraPicker.PickerResult> => cameraPicker.pick(host.abilityContext, [type === 1 ? cameraPicker.PickerMediaType.VIDEO : cameraPicker.PickerMediaType.PHOTO], profile));
    this.checkHost(host);
    if (result === undefined || result === null) throw new Error('UNAVAILABLE: 系统 CameraPicker 服务没有返回结果');
    if (result.resultCode !== 0) throw new Error('CANCELLED: 用户取消了拍摄');
    if (result.resultUri.length === 0) throw new Error('UNAVAILABLE: 系统没有返回可读取的拍摄文件');
    let resultPath: string;
    try { resultPath = LynxHarmonyFilesystem.resolve(host.abilityContext, result.resultUri, 'CACHE'); }
    catch (_error) { throw new Error('UNAVAILABLE: CAPTURE_PRIVATE_OUTPUT: 系统没有返回所请求的私有拍摄位置'); }
    if (resultPath !== target.path) throw new Error('UNAVAILABLE: CAPTURE_PRIVATE_OUTPUT: 系统没有遵循指定的私有拍摄位置');
    return { uri: target.uri, captured: true, type: type, privatePath: target.path };
  }

  private async assetType(host: LynxCapacitorHost, uri: string): Promise<number> {
    return Number(await LynxHarmonyNativeIO.run(this.owner, async (): Promise<Object> => {
      const helper = photoAccessHelper.getPhotoAccessHelper(host.abilityContext);
      try {
        const predicates = new dataSharePredicates.DataSharePredicates();
        predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uri);
        const result = await helper.getAssets({ fetchColumns: [photoAccessHelper.PhotoKeys.PHOTO_TYPE], predicates: predicates });
        try {
          this.owner.checkActive();
          const asset = await result.getFirstObject();
          this.owner.checkActive();
          if (asset.photoType === photoAccessHelper.PhotoType.IMAGE) return 0;
          if (asset.photoType === photoAccessHelper.PhotoType.VIDEO) return 1;
          throw new Error('INVALID_ARGUMENT: 所选资源不是图片或视频');
        } finally { result.close(); }
      } finally { await helper.release(); }
    }));
  }

  private async saveCapture(host: LynxCapacitorHost, path: string, info: LynxHarmonyMediaInfo): Promise<boolean> {
    this.checkHost(host);
    const helper = photoAccessHelper.getPhotoAccessHelper(host.abilityContext);
    try {
      const config: photoAccessHelper.PhotoCreationConfig = { title: 'LynxMedia', fileNameExtension: this.format(info.mimeType), photoType: info.type === 1 ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE };
      const results = await this.scoped(host, (): Promise<Array<string>> => helper.showAssetsCreationDialog([this.fileURI(path)], [config]));
      this.checkHost(host);
      if (results.length !== 1) throw new Error('CANCELLED: 用户取消了保存到相册');
      // 授权面板只创建可写的目标URI，实际内容写入完成后才能报告saved。
      await LynxHarmonyNativeIO.run(this.owner, async (): Promise<Object> => {
        this.owner.checkActive();
        const source = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
        try {
          const destination = await fileIo.open(results[0], fileIo.OpenMode.WRITE_ONLY);
          try {
            this.owner.checkActive();
            await fileIo.copyFile(source.fd, destination.fd);
            await fileIo.fsync(destination.fd);
            this.owner.checkActive();
          } finally { await fileIo.close(destination); }
        } finally { await fileIo.close(source); }
        return true;
      });
      this.checkHost(host);
      return true;
    } finally { await helper.release(); }
  }

  private async mediaResult(host: LynxCapacitorHost, path: string, info: LynxHarmonyMediaInfo, saved: boolean, options: Record<string, Object>, method: string): Promise<Record<string, Object>> {
    const uri = this.fileURI(path);
    const result: Record<string, Object> = { uri: uri, path: path, webPath: uri, type: info.type, mimeType: info.mimeType, format: this.format(info.mimeType), size: info.size, saved: saved };
    if (this.boolean(options, 'includeMetadata', false)) {
      const metadata: Record<string, Object> = { size: info.size, format: this.format(info.mimeType) };
      if (info.width !== undefined) { metadata['width'] = info.width; result['width'] = info.width; }
      if (info.height !== undefined) { metadata['height'] = info.height; result['height'] = info.height; }
      if (info.duration !== undefined) { metadata['duration'] = info.duration; result['duration'] = info.duration; }
      result['metadata'] = metadata;
    }
    if (method !== 'chooseFromGallery') {
      const resultType = this.resultType(options);
      if (resultType !== 'URI') {
        const roots: Array<string> = [host.abilityContext.filesDir, host.abilityContext.cacheDir, host.abilityContext.tempDir];
        const encoded = String(await LynxHarmonyNativeIO.task(this.owner, 'read', [path, 'BASE64', roots]));
        if (resultType === 'BASE64') result['base64String'] = encoded;
        else result['dataUrl'] = 'data:' + info.mimeType + ';base64,' + encoded;
      }
    }
    return result;
  }

  private async previewFile(host: LynxCapacitorHost, options: Record<string, Object>, method: string): Promise<Record<string, Object>> {
    if (method !== 'openDocumentFromLocalPath') throw new Error('UNIMPLEMENTED: FileViewer 只支持既有本地文档入口');
    const items = options['items'];
    if (items !== undefined) {
      if (options['uri'] !== undefined || options['path'] !== undefined || options['localPath'] !== undefined) throw new Error('INVALID_ARGUMENT: items 与单文件位置互斥');
      if (!Array.isArray(items) || items.length < 1 || items.length > 16) throw new Error('INVALID_ARGUMENT: items 必须包含 1 到 16 张本地图片');
      const initialIndex = options['initialIndex'] === undefined ? 0 : options['initialIndex'];
      if (typeof initialIndex !== 'number' || !Number.isSafeInteger(initialIndex) || initialIndex < 0 || initialIndex >= items.length) throw new Error('INVALID_ARGUMENT: initialIndex 超出图片列表范围');
      const images: Array<LynxHarmonyPreviewImage> = [];
      for (const item of items as Array<Object>) {
        if (item === null || typeof item !== 'object' || Array.isArray(item)) throw new Error('INVALID_ARGUMENT: 图片项必须提供本地 uri/path');
        const path = this.localPath(host, item as Record<string, Object>);
        const info = await inspectHarmonyMedia(this.owner, path, 0);
        this.checkHost(host);
        const width = info.width as number;
        const height = info.height as number;
        const ratio = Math.min(1, 1600 / Math.max(width, height));
        images.push({ uri: this.fileURI(path), width: Math.max(1, Math.floor(width * ratio)), height: Math.max(1, Math.floor(height * ratio)) });
      }
      await this.openPreview(host, images, initialIndex as number);
      return { opened: true, uri: images[initialIndex as number].uri, initialIndex: initialIndex, itemCount: images.length };
    }
    if (options['initialIndex'] !== undefined) throw new Error('INVALID_ARGUMENT: initialIndex 只适用于 items');
    const path = this.localPath(host, options);
    const stat = await LynxHarmonyFilesystem.stat(this.owner, path);
    if (!stat.isFile()) throw new Error('INVALID_ARGUMENT: 文档预览要求本地文件');
    this.checkHost(host);
    const uri = this.fileURI(path);
    const want: Want = { action: 'ohos.want.action.viewData', uri: uri, type: this.string(options, 'mimeType', '*/*'), flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION };
    try {
      await this.scoped(host, (): Promise<void> => host.abilityContext.startAbility(want));
    } catch (error) {
      if ((error as Record<string, Object>)['code'] === 16000001) throw new Error('NO_HANDLER: 系统没有本地文档查看器');
      throw error;
    }
    return { opened: true, uri: uri };
  }

  private async openPreview(host: LynxCapacitorHost, images: Array<LynxHarmonyPreviewImage>, index: number, video: string = ''): Promise<void> {
    this.checkHost(host);
    const dialog = new LynxHarmonyMediaDialog(this.owner, host, (): void => { if (this.preview === dialog) this.preview = null; });
    this.preview = dialog;
    await dialog.open(images, index, video);
    this.checkHost(host);
  }

  private closePreview(): void { const dialog = this.preview; this.preview = null; if (dialog !== null) dialog.close(); }

  private removeStage(path: string): void {
    if (!this.temporaryPaths.delete(path)) return;
    this.owner.disown('media-file:' + path);
    const target = this.captureTargets.get(path);
    if (target !== undefined) {
      this.captureTargets.delete(path);
      removeHarmonyCaptureTarget(target).catch((_error: Object): void => {
        console.error('LynxHarmonyMedia', '未返回拍摄目标清理失败');
      });
      return;
    }
    fileIo.unlink(path).catch((_error: Object): void => {
      console.error('LynxHarmonyMedia', '未返回媒体缓存清理失败');
    });
  }

  private localPath(host: LynxCapacitorHost, options: Record<string, Object>): string {
    const raw = options['uri'] === undefined ? (options['path'] === undefined ? options['localPath'] : options['path']) : options['uri'];
    if (typeof raw !== 'string' || raw.length === 0) throw new Error('INVALID_ARGUMENT: 需要非空本地 uri/path');
    if (raw.indexOf('://') >= 0 && !raw.startsWith('file://')) throw new Error('INVALID_ARGUMENT: 媒体预览只接受本地文件，请先下载远程资源');
    if (raw.startsWith('file://media/')) {
      if (!this.grantedUris.has(raw)) throw new Error('INVALID_ARGUMENT: 媒体 URI 不是当前 owner 的系统选择结果');
      return raw;
    }
    return LynxHarmonyFilesystem.resolve(host.abilityContext, raw, this.string(options, 'directory', 'CACHE'));
  }

  private host(): LynxCapacitorHost { const host = this.getHost(); if (host === null) throw new Error('UNAVAILABLE: 未绑定当前页面媒体宿主'); this.checkHost(host); return host; }
  private checkHost(host: LynxCapacitorHost): void { this.owner.checkActive(); if (this.destroyed) throw new Error('ACTIVITY_DESTROYED: 媒体 owner 已结束'); if (this.getHost() !== host || !host.isVisible()) throw new Error('UNAVAILABLE: 媒体页面已离开前台或宿主已变化'); }
  private scoped<T>(host: LynxCapacitorHost, work: () => Promise<T>): Promise<T> {
    this.checkHost(host);
    return new Promise<T>((resolve, reject): void => {
      host.uiContext.runScopedTask((): void => { try { this.checkHost(host); work().then(resolve).catch(reject); } catch (error) { reject(error); } });
    });
  }
  private complete(request: MediaRequest, json: string): void { if (request.settled) return; request.settled = true; if (this.pending === request) this.pending = null; request.callback(json); }
  private fileURI(path: string): string { return path.startsWith('file://') ? path : fileUri.getUriFromPath(path); }
  private mediaType(options: Record<string, Object>): number { const value = options['mediaType'] === undefined ? 0 : options['mediaType']; if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > 2) throw new Error('INVALID_ARGUMENT: mediaType 必须为 0/1/2'); return value as number; }
  private selectionLimit(options: Record<string, Object>, method: string): number {
    if (method === 'getPhoto' || method === 'takePhoto' || method === 'recordVideo') return 1;
    const multi = this.boolean(options, 'allowMultipleSelection', method === 'pickImages' || this.boolean(options, 'allowMultiple', false));
    const value = options['limit'] === undefined ? (multi ? 0 : 1) : options['limit'];
    if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0 || value > 16) throw new Error('INVALID_ARGUMENT: limit 必须为 0 到 16 的整数');
    return value === 0 ? 16 : value as number;
  }
  private string(options: Record<string, Object>, key: string, fallback: string): string { const value = options[key]; if (value === undefined) return fallback; if (typeof value !== 'string') throw new Error('INVALID_ARGUMENT: ' + key + ' 必须为字符串'); return value; }
  private resultType(options: Record<string, Object>): string { const value = this.string(options, 'resultType', 'URI').toUpperCase().replace(/_/g, ''); if (value !== 'URI' && value !== 'BASE64' && value !== 'DATAURL') throw new Error('INVALID_ARGUMENT: resultType 必须为 URI/BASE64/DATA_URL'); return value; }
  private boolean(options: Record<string, Object>, key: string, fallback: boolean): boolean { const value = options[key]; if (value === undefined) return fallback; if (typeof value !== 'boolean') throw new Error('INVALID_ARGUMENT: ' + key + ' 必须为布尔值'); return value; }
  private format(mime: string): string { const subtype = mime.substring(mime.indexOf('/') + 1).toLowerCase(); return subtype === 'jpeg' ? 'jpg' : subtype === 'quicktime' ? 'mov' : subtype.replace(/[^a-z0-9]/g, ''); }
  private errorCode(error: Object): string {
    if (String(error).indexOf('HARDWARE_UNAVAILABLE:') >= 0) return 'HARDWARE_UNAVAILABLE';
    if (String(error).indexOf('NO_HANDLER:') >= 0) return 'NO_HANDLER';
    if (String(error).indexOf('UNIMPLEMENTED:') >= 0) return 'UNIMPLEMENTED';
    const native = error as Record<string, Object>;
    if (native['code'] === 201 || native['code'] === 13900012) return 'PERMISSION_DENIED';
    if (native['code'] === 401 || native['code'] === 13900020) return 'INVALID_ARGUMENT';
    if (native['code'] === 13900002) return 'NOT_FOUND';
    if (native['code'] === 100001) return 'CANCELLED';
    return lynxNativeErrorCode(error);
  }
  private errorMessage(error: Object): string {
    if (String(error).indexOf('CAPTURE_PRIVATE_OUTPUT:') >= 0) return '系统相机未遵循私有 saveUri，拍摄结果不可用';
    const code = this.errorCode(error);
    if (code === 'UNSUPPORTED') return '系统 CameraPicker 不支持请求的录像音轨选项';
    if (code === 'CANCELLED') return '用户取消了媒体操作';
    if (code === 'PERMISSION_DENIED') return '系统没有授予媒体操作所需权限';
    if (code === 'BUSY') return '已有媒体操作或原生 IO 正在等待';
    if (code === 'FILE_TOO_LARGE' || code === 'RESULT_TOO_LARGE') return '媒体文件、像素或内联结果超过预算';
    if (code === 'ACTIVITY_DESTROYED') return '媒体 owner 已结束';
    if (code === 'HARDWARE_UNAVAILABLE') return '当前设备没有所请求方向的相机';
    if (code === 'INVALID_ARGUMENT') return '媒体参数、文件位置或真实媒体类型不符合契约';
    if (code === 'NOT_FOUND') return '本地媒体不存在或为空';
    if (code === 'NO_HANDLER') return '系统没有可打开本地文件的原生查看器';
    if (code === 'UNIMPLEMENTED') return '当前方法未接入媒体后端';
    return '系统媒体服务或本地文件处理不可用';
  }
}
