import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import util from '@ohos.util';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';
import { LynxHarmonyNativeIO } from './LynxHarmonyNativeIO';

export interface LynxHarmonyCaptureTarget {
  directory: string;
  path: string;
  uri: string;
}

/** CameraPicker 要求 saveUri 指向已存在、可写的文件；不传会自动写入公共媒体库。 */
export async function createHarmonyCaptureTarget(owner: LynxHarmonyNativeOwner, context: common.UIAbilityContext, video: boolean): Promise<LynxHarmonyCaptureTarget> {
  const directory = context.cacheDir + '/lynx-media-capture/' + util.generateRandomUUID(false);
  const path = directory + (video ? '/video.mp4' : '/photo.jpg');
  const uri = fileUri.getUriFromPath(path);
  const target: LynxHarmonyCaptureTarget = { directory: directory, path: path, uri: uri };
  const roots: Array<string> = [context.filesDir, context.cacheDir, context.tempDir];
  const key = 'media-file:' + path;
  return await LynxHarmonyNativeIO.run(owner, async (): Promise<Object> => {
    try {
      await LynxHarmonyNativeIO.directTask('stageWrite', [path, '', 'UTF8', roots]);
      owner.checkActive();
      const file = await fileIo.open(uri, fileIo.OpenMode.READ_WRITE);
      try {
        owner.checkActive();
        owner.own(key, (): void => {
          removeHarmonyCaptureTarget(target).catch((_error: Object): void => {
            console.error('LynxHarmonyMedia', '未返回拍摄文件清理失败');
          });
        });
      } finally { await fileIo.close(file); }
      owner.checkActive();
      return target;
    } catch (error) {
      owner.disown(key);
      // 等实际写入工作结束再清理，避免 owner 提前关闭后后台又生成孤儿文件。
      try { await removeHarmonyCaptureTarget(target); }
      catch (_cleanupError) { console.error('LynxHarmonyMedia', '失败拍摄目标清理失败'); }
      throw error;
    }
  }) as LynxHarmonyCaptureTarget;
}

export async function removeHarmonyCaptureTarget(target: LynxHarmonyCaptureTarget): Promise<void> {
  try { await fileIo.unlink(target.path); }
  catch (error) { if ((error as Record<string, Object>)['code'] !== 13900002) throw error; }
  try { await fileIo.rmdir(target.directory); }
  catch (error) { if ((error as Record<string, Object>)['code'] !== 13900002) throw error; }
}
