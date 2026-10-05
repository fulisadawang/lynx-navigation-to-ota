import { http } from '@kit.NetworkKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import util from '@ohos.util';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';
import { LynxHarmonyFilesystem } from './LynxHarmonyFilesystem';
import { LYNX_FILE_BYTES, LYNX_INLINE_BYTES, LynxHarmonyNativeIO } from './LynxHarmonyNativeIO';

interface TransferRecord {
  operationId: string;
  state: string;
  bytes: number;
  total: number | null;
  cancelled: boolean;
  completed: boolean;
  request: http.HttpRequest | null;
  result: Record<string, Object>;
  reject: ((error: Object) => void) | null;
}

/** 下载流式写入 part；内存队列超过 512 KiB 主动失败，避免慢磁盘时无界持有网络块。 */
export class LynxHarmonyTransfer {
  private records: Map<string, TransferRecord> = new Map();
  private readonly owner: LynxHarmonyNativeOwner;
  private readonly context: () => common.UIAbilityContext;
  private readonly progress: (operationId: string, url: string, bytes: number, total: number) => void;
  constructor(owner: LynxHarmonyNativeOwner, context: () => common.UIAbilityContext,
    progress: (operationId: string, url: string, bytes: number, total: number) => void) { this.owner = owner; this.context = context; this.progress = progress; }

  public dispatch(method: string, options: Record<string, Object>): Promise<Object> {
    if (method === 'getStatus' || method === 'cancel') {
      const record = this.records.get(String(options['operationId'] ?? ''));
      if (record === undefined) return Promise.reject(new Error('NOT_FOUND: 文件任务不存在'));
      if (method === 'getStatus') return Promise.resolve(record.result);
      if (record.completed) return Promise.resolve({ operationId: record.operationId, state: record.state, cancelled: false });
      record.cancelled = true;
      record.completed = true;
      record.state = 'cancelled';
      record.result = { operationId: record.operationId, state: 'cancelled', cancelled: true, code: 'CANCELLED' };
      record.request?.destroy();
      record.reject?.(new Error('CANCELLED: 下载已取消'));
      record.reject = null;
      return Promise.resolve({ operationId: record.operationId, state: 'cancelling', cancelled: true });
    }
    if (method !== 'downloadFile') return Promise.reject(new Error('UNIMPLEMENTED: FileTransfer.' + method));
    const url = String(options['url'] ?? '');
    if (!/^https?:\/\//.test(url)) return Promise.reject(new Error('INVALID_ARGUMENT: url 必须为 HTTP(S)'));
    const path = LynxHarmonyFilesystem.resolve(this.context(), String(options['path'] ?? ''), String(options['directory'] ?? 'CACHE'));
    if (String(options['path'] ?? '').length === 0) return Promise.reject(new Error('INVALID_ARGUMENT: path 不能为空'));
    const id = util.generateRandomUUID(false);
    const record: TransferRecord = { operationId: id, state: 'pending', bytes: 0, total: null, cancelled: false, completed: false, request: null, result: { operationId: id, state: 'pending' }, reject: null };
    this.records.set(id, record);
    this.trim();
    return new Promise<Object>((resolve, reject): void => {
      record.reject = reject;
      LynxHarmonyNativeIO.run(this.owner, (): Promise<Object> => this.download(record, url, path, options)).then((value: Object): void => {
        record.reject = null;
        resolve(value);
      }).catch((error: Object): void => {
        record.completed = true;
        record.state = record.cancelled ? 'cancelled' : 'failed';
        record.result = { operationId: id, state: record.state, code: record.cancelled ? 'CANCELLED' : String(error), cancelled: record.cancelled };
        record.reject = null;
        reject(error);
      });
    });
  }

  public destroy(): void {
    this.records.forEach((record: TransferRecord): void => {
      record.cancelled = true;
      record.request?.destroy();
      record.reject?.(new Error('ACTIVITY_DESTROYED: 下载 owner 已销毁'));
      record.reject = null;
    });
    this.records.clear();
  }

  private async download(record: TransferRecord, url: string, path: string, options: Record<string, Object>): Promise<Object> {
    this.owner.checkActive();
    if (record.cancelled) throw new Error('CANCELLED: 下载已取消');
    const part = path + '.' + record.operationId + '.part';
    const request = http.createHttp();
    record.request = request;
    const key = 'transfer:' + record.operationId;
    this.owner.own(key, (): void => request.destroy());
    let file: fileIo.File | null = null;
    let writes: Promise<void> = Promise.resolve();
    let queuedBytes = 0;
    let failed: Object | null = null;
    let endResolve: () => void = (): void => {};
    let endReject: (error: Object) => void = (_error: Object): void => {};
    const ended = new Promise<void>((resolve, reject): void => { endResolve = resolve; endReject = reject; });
    const fail = (error: Object): void => {
      if (failed !== null) return;
      failed = error;
      request.destroy();
      endReject(error);
    };
    // 原生请求失败可能先于 await Promise.all；立即登记 rejection 观察。
    ended.catch((_error: Object): void => {});
    try {
      await LynxHarmonyFilesystem.validate(this.owner, path, true);
      this.owner.checkActive();
      const parent = path.substring(0, path.lastIndexOf('/'));
      await fileIo.mkdir(parent, true);
      this.owner.checkActive();
      file = await fileIo.open(part, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      this.owner.checkActive();
      const target = file;
      request.on('headersReceive', (headers: Object): void => {
        const values = headers as Record<string, Object>;
        const name = Object.keys(values).find((value: string): boolean => value.toLowerCase() === 'content-length');
        const total = name === undefined ? NaN : Number(values[name]);
        if (Number.isFinite(total)) {
          record.total = total;
          if (total > LYNX_FILE_BYTES) fail(new Error('FILE_TOO_LARGE: 下载超过 20 MiB'));
        }
      });
      request.on('dataReceive', (chunk: ArrayBuffer): void => {
        if (failed !== null) return;
        if (!this.owner.isActive || record.cancelled) { fail(new Error(record.cancelled ? 'CANCELLED: 下载已取消' : 'ACTIVITY_DESTROYED: 页面已销毁')); return; }
        record.bytes += chunk.byteLength;
        queuedBytes += chunk.byteLength;
        if (record.bytes > LYNX_FILE_BYTES) { fail(new Error('FILE_TOO_LARGE: 下载超过 20 MiB')); return; }
        if (queuedBytes > LYNX_INLINE_BYTES) { fail(new Error('BUSY: 下载写入队列超过 512 KiB')); return; }
        writes = writes.then(async (): Promise<void> => {
          this.owner.checkActive();
          if (record.cancelled) throw new Error('CANCELLED: 下载已取消');
          let offset = 0;
          while (offset < chunk.byteLength) {
            const count = await fileIo.write(target.fd, chunk.slice(offset));
            if (count <= 0) throw new Error('IO: 下载写入未前进');
            offset += count;
            this.owner.checkActive();
          }
          record.state = 'running';
          record.result = { operationId: record.operationId, state: 'running', bytes: record.bytes, total: record.total };
          this.progress(record.operationId, url, record.bytes, record.total ?? -1);
        }).catch((error: Object): void => fail(error)).finally((): void => { queuedBytes -= chunk.byteLength; });
      });
      request.on('dataEnd', (): void => endResolve());
      const config: http.HttpRequestOptions = { method: http.RequestMethod.GET, maxLimit: LYNX_FILE_BYTES };
      if (options['headers'] !== undefined) config.header = options['headers'];
      const timeout = Number(options['timeout'] ?? 60000);
      if (!Number.isSafeInteger(timeout) || timeout < 1) throw new Error('INVALID_ARGUMENT: timeout 必须为正整数');
      config.connectTimeout = timeout; config.readTimeout = timeout;
      const response = request.requestInStream(url, config);
      response.catch((error: Object): void => fail(error));
      const status = await response;
      await ended;
      await writes;
      if (failed !== null) throw failed;
      this.owner.checkActive();
      if (record.cancelled) throw new Error('CANCELLED: 下载已取消');
      if (status < 200 || status >= 300) throw new Error('NETWORK: HTTP ' + String(status));
      await fileIo.fsync(target.fd);
      await fileIo.close(target);
      file = null;
      this.owner.checkActive();
      fileIo.renameSync(part, path);
      record.completed = true;
      record.state = 'completed';
      record.result = { operationId: record.operationId, state: 'completed', path: path, uri: fileUri.getUriFromPath(path), bytes: record.bytes, responseCode: status };
      return record.result;
    } finally {
      request.destroy();
      this.owner.disown(key);
      record.request = null;
      await writes;
      if (file !== null) await fileIo.close(file);
      if (fileIo.accessSync(part)) fileIo.unlinkSync(part);
    }
  }

  private trim(): void {
    const removable: Array<string> = [];
    this.records.forEach((record: TransferRecord, key: string): void => { if (record.completed) removable.push(key); });
    while (this.records.size > 32 && removable.length > 0) { const id = removable.shift(); if (id !== undefined) this.records.delete(id); }
  }
}
