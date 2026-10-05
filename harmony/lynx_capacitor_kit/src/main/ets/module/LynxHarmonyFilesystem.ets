import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import util from '@ohos.util';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';
import { LYNX_FILE_BYTES, LynxHarmonyNativeIO } from './LynxHarmonyNativeIO';

/** 仅暴露当前 Ability 沙盒及系统授予的媒体 URI；远程资源必须先下载。 */
export class LynxHarmonyFilesystem {
  private static roots: Set<string> = new Set();
  public static resolve(context: common.UIAbilityContext, raw: string, directory: string = 'CACHE'): string {
    if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(raw) && !raw.startsWith('file://')) throw new Error('INVALID_ARGUMENT: 只接受本地文件路径/URI');
    [context.filesDir, context.cacheDir, context.tempDir].forEach((root: string): void => { LynxHarmonyFilesystem.roots.add(root); });
    let path = raw;
    if (path.startsWith('file://')) path = new fileUri.FileUri(path).path;
    if (path.indexOf('\u0000') >= 0 || path.split('/').includes('..')) throw new Error('INVALID_ARGUMENT: 不允许路径穿越');
    if (path.startsWith('/')) {
      const roots = [context.filesDir, context.cacheDir, context.tempDir];
      if (!roots.some((root: string): boolean => path === root || path.startsWith(root + '/'))) throw new Error('INVALID_ARGUMENT: 路径必须位于当前应用沙盒');
      return path;
    }
    const selected = directory.toUpperCase();
    let root = context.filesDir;
    if (selected === 'CACHE') root = context.cacheDir;
    else if (selected === 'TEMPORARY') root = context.tempDir;
    else if (selected === 'DOCUMENTS') root += '/Documents';
    else if (selected === 'LIBRARY') root += '/Library';
    else if (selected === 'APPLICATION_SUPPORT') root += '/Library/Application Support';
    else if (selected !== 'DATA' && selected !== 'FILES') throw new Error('INVALID_ARGUMENT: 不支持的 directory');
    const resolved = path.length === 0 ? root : root + '/' + path;
    return resolved;
  }

  public static async validate(owner: LynxHarmonyNativeOwner, path: string, withinIO: boolean = false): Promise<void> {
    if (path.startsWith('file://media/')) return;
    if (withinIO) await LynxHarmonyNativeIO.directTask('validatePath', [path, Array.from(LynxHarmonyFilesystem.roots)]);
    else await LynxHarmonyNativeIO.task(owner, 'validatePath', [path, Array.from(LynxHarmonyFilesystem.roots)]);
    owner.checkActive();
  }

  public static mediaPath(context: common.UIAbilityContext, raw: string): string {
    if (raw.startsWith('http://') || raw.startsWith('https://')) throw new Error('INVALID_ARGUMENT: 媒体预览只接受本地 URI，请先下载');
    // PhotoViewPicker 的授权 file://media 路径由系统 Provider 校验，不转换成伪沙盒路径。
    if (raw.startsWith('file://media/')) return raw;
    return LynxHarmonyFilesystem.resolve(context, raw, 'CACHE');
  }

  public static async stat(owner: LynxHarmonyNativeOwner, path: string, maxBytes: number = LYNX_FILE_BYTES, withinIO: boolean = false): Promise<fileIo.Stat> {
    const work = async (): Promise<Object> => {
      owner.checkActive();
      await LynxHarmonyFilesystem.validate(owner, path, true);
      let stat: fileIo.Stat;
      if (path.startsWith('file://media/')) {
        const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
        try { stat = await fileIo.stat(file.fd); } finally { await fileIo.close(file); }
      } else stat = await fileIo.stat(path);
      owner.checkActive();
      if (stat.size > maxBytes) throw new Error('FILE_TOO_LARGE: 文件超过 ' + String(maxBytes) + ' 字节');
      return stat;
    };
    return (withinIO ? await work() : await LynxHarmonyNativeIO.run(owner, work)) as fileIo.Stat;
  }

  public static async copyToCache(owner: LynxHarmonyNativeOwner, context: common.UIAbilityContext, source: string, extension: string = ''): Promise<string> {
    const path = context.cacheDir + '/lynx-media/' + util.generateRandomUUID(false) + extension;
    const part = path + '.part';
    return String(await LynxHarmonyNativeIO.run(owner, async (): Promise<Object> => {
      try {
        await LynxHarmonyNativeIO.directTask('copy', [source, part, [context.filesDir, context.cacheDir, context.tempDir]]);
        owner.checkActive();
        owner.own('media-file:' + path, (): void => { fileIo.unlink(path).catch((error: Object): void => console.error('LynxCapacitor', '未返回媒体缓存释放失败: ' + String(error))); });
        fileIo.renameSync(part, path);
        return path;
      } finally { if (fileIo.accessSync(part)) fileIo.unlinkSync(part); }
    }));
  }

  public static async dispatch(owner: LynxHarmonyNativeOwner, context: common.UIAbilityContext, method: string, options: Record<string, Object>): Promise<Record<string, Object>> {
    const path = LynxHarmonyFilesystem.resolve(context, String(options['path'] ?? ''), String(options['directory'] ?? 'CACHE'));
    if (method === 'getUri') { await LynxHarmonyFilesystem.validate(owner, path); return { uri: fileUri.getUriFromPath(path) }; }
    if (method === 'mkdir') {
      await LynxHarmonyNativeIO.run(owner, async (): Promise<Object> => { await LynxHarmonyFilesystem.validate(owner, path, true); owner.checkActive(); await fileIo.mkdir(path, Boolean(options['recursive'] ?? true)); return {}; });
      owner.checkActive();
      return { created: true };
    }
    if (method === 'stat') {
      const stat = await LynxHarmonyFilesystem.stat(owner, path);
      return { name: path.substring(path.lastIndexOf('/') + 1), type: stat.isDirectory() ? 'directory' : 'file', size: stat.size, mtime: stat.mtime, uri: fileUri.getUriFromPath(path) };
    }
    if (method === 'readFile') return { data: await LynxHarmonyNativeIO.task(owner, 'read', [path, String(options['encoding'] ?? 'UTF8'), [context.filesDir, context.cacheDir, context.tempDir]]) };
    if (method === 'readdir') return { files: await LynxHarmonyNativeIO.task(owner, 'list', [path, [context.filesDir, context.cacheDir, context.tempDir]]) };
    if (method === 'writeFile') {
      const part = path + '.' + util.generateRandomUUID(false) + '.part';
      // 保留运行中的工作任务直到其真实结束，避免取消先 unlink 后后台继续写出 orphan part。
      await LynxHarmonyNativeIO.run(owner, async (): Promise<Object> => {
        try {
          const stage = await LynxHarmonyNativeIO.directTask('stageWrite', [part, String(options['data'] ?? ''), String(options['encoding'] ?? 'UTF8'), [context.filesDir, context.cacheDir, context.tempDir]]);
          owner.checkActive();
          fileIo.renameSync(String(stage), path);
          return {};
        } finally { if (fileIo.accessSync(part)) fileIo.unlinkSync(part); }
      });
      return { uri: fileUri.getUriFromPath(path) };
    }
    throw new Error('UNIMPLEMENTED: Filesystem.' + method);
  }
}
