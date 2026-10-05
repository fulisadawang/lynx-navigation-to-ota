import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import util from '@ohos.util';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';
import { LYNX_INLINE_BYTES, LynxHarmonyNativeIO, lynxUTF8Bytes } from './LynxHarmonyNativeIO';

interface PreferenceQueue { serial: Promise<void>; waiting: number; }

/** 同一 Preferences store 串行写入，keys 从真实 provider 获取，不保存跨页面易失效的索引。 */
export class LynxHarmonyPreferences {
  private static queues: Map<string, PreferenceQueue> = new Map();
  private readonly owner: LynxHarmonyNativeOwner;
  private readonly context: () => common.UIAbilityContext;
  constructor(owner: LynxHarmonyNativeOwner, context: () => common.UIAbilityContext) { this.owner = owner; this.context = context; }

  public dispatch(method: string, options: Record<string, Object>): Promise<Object> {
    return this.serial(async (store: preferences.Preferences): Promise<Object> => {
      const key = String(options['key'] ?? '');
      if (method !== 'keys' && (key.length === 0 || key.startsWith('__lynx_capacitor_'))) throw new Error('INVALID_ARGUMENT: Preferences key 为空或保留');
      if (method === 'get') {
        const value = await store.get(key, null);
        this.owner.checkActive();
        if (value !== null && lynxUTF8Bytes(String(value)) > LYNX_INLINE_BYTES) throw new Error('RESULT_TOO_LARGE: Preferences value 超过 512 KiB');
        return { value: value === null ? null : String(value) };
      }
      if (method === 'set') {
        const value = String(options['value'] ?? '');
        if (lynxUTF8Bytes(value) > LYNX_INLINE_BYTES) throw new Error('PAYLOAD_TOO_LARGE: Preferences value 超过 512 KiB');
        this.owner.checkActive();
        await store.put(key, value);
        // provider mutation开始即进入提交段；取消回执不留下只改内存却未持久化的值。
        await store.flush();
        this.owner.checkActive();
        return { saved: true };
      }
      if (method === 'remove') {
        this.owner.checkActive();
        await store.delete(key);
        await store.flush();
        this.owner.checkActive();
        return { removed: true };
      }
      if (method === 'keys') {
        const values = await store.getAll() as Record<string, Object>;
        this.owner.checkActive();
        return { keys: Object.keys(values).filter((name: string): boolean => !name.startsWith('__lynx_capacitor_')) };
      }
      throw new Error('UNIMPLEMENTED: Preferences.' + method);
    });
  }

  public deviceIdentifier(): Promise<Object> {
    return this.serial(async (store: preferences.Preferences): Promise<Object> => {
      const key = '__lynx_capacitor_device_identifier';
      const existing = await store.get(key, null);
      this.owner.checkActive();
      if (typeof existing === 'string' && existing.length > 0) return { identifier: existing };
      const identifier = 'harmony-' + util.generateRandomUUID(false);
      await store.put(key, identifier);
      await store.flush();
      this.owner.checkActive();
      return { identifier: identifier };
    });
  }

  private serial(work: (store: preferences.Preferences) => Promise<Object>): Promise<Object> {
    this.owner.checkActive();
    const context = this.context();
    const key = context.filesDir;
    let queue = LynxHarmonyPreferences.queues.get(key);
    if (queue === undefined) { queue = { serial: Promise.resolve(), waiting: 0 }; LynxHarmonyPreferences.queues.set(key, queue); }
    if (queue.waiting >= 16) return Promise.reject(new Error('BUSY: Preferences 等待队列已满'));
    const current = queue;
    current.waiting += 1;
    const previous = current.serial;
    let signal: () => void = (): void => {};
    let started = false;
    const ended = new Promise<void>((resolve): void => { signal = resolve; });
    // 同store等待发生在进入IO池前，避免占用全局槽阻塞不相关文件/网络任务。
    const operation = previous.then((): Promise<Object> => LynxHarmonyNativeIO.run(this.owner, async (): Promise<Object> => {
      started = true;
      try {
        this.owner.checkActive();
        const store = await preferences.getPreferences(context, { name: 'lynx_capacitor_preferences' });
        this.owner.checkActive();
        return await work(store);
      } finally { signal(); }
    })).catch((error: Object): Object => { if (!started) signal(); throw error; });
    current.serial = previous.then((): Promise<void> => ended).finally((): void => {
      current.waiting -= 1;
      if (current.waiting === 0 && LynxHarmonyPreferences.queues.get(key) === current) LynxHarmonyPreferences.queues.delete(key);
    });
    return operation;
  }
}
