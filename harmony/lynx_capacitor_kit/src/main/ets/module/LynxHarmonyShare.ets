import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { fileUri } from '@kit.CoreFileKit';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';
import { LynxCapacitorHost } from './LynxCapacitorHost';
import { LynxHarmonyFilesystem } from './LynxHarmonyFilesystem';

/** 系统分享面板原生支持文本、链接及多文件；不会丢掉 files 参数后返回文本分享成功。 */
export class LynxHarmonyShare {
  private readonly owner: LynxHarmonyNativeOwner;
  private readonly host: () => LynxCapacitorHost;
  constructor(owner: LynxHarmonyNativeOwner, host: () => LynxCapacitorHost) { this.owner = owner; this.host = host; }

  public async dispatch(method: string, options: Record<string, Object>): Promise<Object> {
    this.owner.checkActive();
    if (method === 'canShare') return { value: canIUse('SystemCapability.Collaboration.SystemShare') };
    if (method !== 'share') throw new Error('UNIMPLEMENTED: Share.' + method);
    const host = this.host();
    if (!host.isVisible()) throw new Error('UNAVAILABLE: 分享需要当前前台页面');
    const records: Array<systemShare.SharedRecord> = [];
    const title = String(options['title'] ?? '');
    const text = String(options['text'] ?? '');
    const url = String(options['url'] ?? '');
    if (text.length > 0) records.push({ utd: uniformTypeDescriptor.UniformDataType.PLAIN_TEXT, content: text, title: title });
    if (url.length > 0) records.push({ utd: uniformTypeDescriptor.UniformDataType.HYPERLINK, content: url, title: title });
    const raw = options['files'] ?? (options['file'] === undefined ? [] : [options['file']]);
    if (!Array.isArray(raw) || raw.length > 16) throw new Error('INVALID_ARGUMENT: files 必须为最多 16 个本地文件 URI');
    for (const item of raw as Array<Object>) {
      if (typeof item !== 'string' || item.length === 0) throw new Error('INVALID_ARGUMENT: 分享文件必须为 URI/path 字符串');
      const path = LynxHarmonyFilesystem.resolve(host.abilityContext, item, 'CACHE');
      await LynxHarmonyFilesystem.stat(this.owner, path);
      this.owner.checkActive();
      const extension = path.substring(path.lastIndexOf('.'));
      const utd = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(extension, uniformTypeDescriptor.UniformDataType.FILE);
      records.push({ utd: utd, uri: fileUri.getUriFromPath(path), title: title });
    }
    if (records.length === 0) throw new Error('INVALID_ARGUMENT: 分享至少需要 text/url/files 一项');
    const data = new systemShare.SharedData(records[0]);
    for (let index = 1; index < records.length; index += 1) data.addRecord(records[index]);
    const controller = new systemShare.ShareController(data);
    this.owner.checkActive();
    await new Promise<void>((resolve, reject): void => {
      host.uiContext.runScopedTask((): void => controller.show(host.abilityContext, {}).then(resolve).catch(reject));
    });
    this.owner.checkActive();
    // 系统分享面板在宿主外管理，show 完成只代表面板打开，不伪造用户已分享。
    return {};
  }
}
