import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import util from '@ohos.util';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';
import { LYNX_FILE_BYTES, LynxHarmonyNativeIO } from './LynxHarmonyNativeIO';
import { LynxHarmonyFilesystem } from './LynxHarmonyFilesystem';

export interface LynxHarmonyMediaInfo {
  type: number;
  mimeType: string;
  size: number;
  width?: number;
  height?: number;
  duration?: number;
}

/** 只读文件头和平台元数据，不将整个媒体或 PixelMap 搬到 ArkTS/UI 内存。 */
export async function inspectHarmonyMedia(owner: LynxHarmonyNativeOwner, path: string, requiredType: number = 2): Promise<LynxHarmonyMediaInfo> {
  return await LynxHarmonyNativeIO.run(owner, async (): Promise<Object> => {
    const stat = await LynxHarmonyFilesystem.stat(owner, path, LYNX_FILE_BYTES, true);
    if (!stat.isFile() || stat.size <= 0) throw new Error('NOT_FOUND: 本地媒体不存在或不是非空文件');
    const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
    let source: image.ImageSource | null = null;
    let extractor: media.AVMetadataExtractor | null = null;
    let fileClosed = false;
    const key = 'media-metadata:' + util.generateRandomUUID(false);
    const release = async (): Promise<void> => {
      const ownedSource = source;
      const ownedExtractor = extractor;
      source = null;
      extractor = null;
      try {
        if (ownedSource !== null) await ownedSource.release();
      } finally {
        try {
          if (ownedExtractor !== null) await ownedExtractor.release();
        } finally {
          if (!fileClosed) { fileClosed = true; await fileIo.close(file); }
        }
      }
    };
    try {
      owner.own(key, (): void => {
        release().catch((_error: Object): void => {
          console.error('LynxHarmonyMedia', '媒体元数据资源清理失败');
        });
      });
      owner.checkActive();
      if (requiredType !== 1) {
        let info: image.ImageInfo | null = null;
        try {
          source = image.createImageSource(file.fd);
          info = await source.getImageInfo();
        } catch (_error) {
          // 混合选择允许继续向真实 AV 元数据探测；图片专用入口不接受视频或未知内容。
          if (requiredType === 0) throw new Error('INVALID_ARGUMENT: 文件不是可解码的图片');
        }
        owner.checkActive();
        if (info !== null && info.mimeType.startsWith('image/')) {
          if (info.size.width <= 0 || info.size.height <= 0 || info.size.width * info.size.height > 64 * 1024 * 1024) {
            throw new Error('FILE_TOO_LARGE: 图片像素超过预览预算');
          }
          return { type: 0, mimeType: info.mimeType, size: stat.size, width: info.size.width, height: info.size.height } as LynxHarmonyMediaInfo;
        }
        if (requiredType === 0) throw new Error('INVALID_ARGUMENT: 文件不具有真实图片 MIME');
        if (source !== null) { const currentSource = source; source = null; await currentSource.release(); }
      }
      extractor = await media.createAVMetadataExtractor();
      owner.checkActive();
      if (extractor === null || extractor === undefined) throw new Error('UNAVAILABLE: 系统 AV 元数据服务不可用');
      extractor.fdSrc = { fd: file.fd, offset: 0, length: stat.size };
      const metadata = await extractor.fetchMetadata();
      owner.checkActive();
      const mimeType = metadata.mimeType;
      if (mimeType === undefined || !mimeType.startsWith('video/')) throw new Error('INVALID_ARGUMENT: 文件不是具有真实 MIME 的视频');
      const result: LynxHarmonyMediaInfo = { type: 1, mimeType: mimeType, size: stat.size };
      const width = Number(metadata.videoWidth);
      const height = Number(metadata.videoHeight);
      const duration = Number(metadata.duration);
      if (Number.isFinite(width) && width > 0) result.width = width;
      if (Number.isFinite(height) && height > 0) result.height = height;
      if (Number.isFinite(duration) && duration >= 0) result.duration = duration;
      return result;
    } finally {
      owner.disown(key);
      await release();
    }
  }) as LynxHarmonyMediaInfo;
}
