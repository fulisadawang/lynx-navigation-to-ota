import taskpool from '@ohos.taskpool';
import util from '@ohos.util';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';

export const LYNX_PAYLOAD_BYTES: number = 1024 * 1024;
export const LYNX_INLINE_BYTES: number = 512 * 1024;
export const LYNX_RESULT_BYTES: number = 2 * 1024 * 1024;
export const LYNX_FILE_BYTES: number = 20 * 1024 * 1024;

export function lynxUTF8Bytes(value: string): number {
  let bytes = 0;
  for (let i = 0; i < value.length; i += 1) {
    const unit = value.charCodeAt(i);
    if (unit < 0x80) bytes += 1;
    else if (unit < 0x800) bytes += 2;
    else if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < value.length && value.charCodeAt(i + 1) >= 0xDC00 && value.charCodeAt(i + 1) <= 0xDFFF) { bytes += 4; i += 1; }
    else bytes += 3;
  }
  return bytes;
}

interface IOJob {
  owner: LynxHarmonyNativeOwner;
  key: string;
  run: () => Promise<Object>;
  resolve: (value: Object) => void;
  reject: (error: Object) => void;
  started: boolean;
  cancelled: boolean;
}

/** 全应用共享的真实并发上限；等待队列不是活动任务历史表。 */
export class LynxHarmonyNativeIO {
  private static active: number = 0;
  private static queue: Array<IOJob> = [];

  public static run(owner: LynxHarmonyNativeOwner, work: () => Promise<Object>): Promise<Object> {
    owner.checkActive();
    if (LynxHarmonyNativeIO.active >= 2 && LynxHarmonyNativeIO.queue.length >= 16) return Promise.reject(new Error('BUSY: 原生 IO 等待队列已满'));
    return new Promise<Object>((resolve, reject): void => {
      const job: IOJob = { owner: owner, key: 'io:' + util.generateRandomUUID(false), run: work, resolve: resolve, reject: reject, started: false, cancelled: false };
      owner.own(job.key, (): void => {
        job.cancelled = true;
        if (!job.started) {
          const index = LynxHarmonyNativeIO.queue.indexOf(job);
          if (index >= 0) LynxHarmonyNativeIO.queue.splice(index, 1);
        }
        reject(new Error('ACTIVITY_DESTROYED: IO owner 已销毁'));
      });
      LynxHarmonyNativeIO.queue.push(job);
      LynxHarmonyNativeIO.drain();
    });
  }

  private static drain(): void {
    while (LynxHarmonyNativeIO.active < 2 && LynxHarmonyNativeIO.queue.length > 0) {
      const job = LynxHarmonyNativeIO.queue.shift();
      if (job === undefined || job.cancelled || !job.owner.isActive) continue;
      job.started = true;
      LynxHarmonyNativeIO.active += 1;
      Promise.resolve().then((): Promise<Object> => job.run()).then((value: Object): void => {
        if (!job.cancelled) { job.owner.checkActive(); job.resolve(value); }
      }).catch((error: Object): void => { if (!job.cancelled) job.reject(error); }).finally((): void => {
        job.owner.disown(job.key);
        LynxHarmonyNativeIO.active -= 1;
        LynxHarmonyNativeIO.drain();
      });
    }
  }

  public static directTask(command: string, values: Array<Object>): Promise<Object> {
    return taskpool.execute(new taskpool.Task(lynxIOWork, command, values));
  }

  /** 只传纯数据；Context、Window、owner、LynxModule 不进入工作线程。 */
  public static task(owner: LynxHarmonyNativeOwner, command: string, values: Array<Object>): Promise<Object> {
    return LynxHarmonyNativeIO.run(owner, (): Promise<Object> => taskpool.execute(new taskpool.Task(lynxIOWork, command, values)));
  }
}

/** 大文件、编码和序列化在 TaskPool；写入只生成 part，最终发布由 owner 门禁控制。 */
@Concurrent
export function lynxIOWork(command: string, values: Array<Object>): Object {
  const inline = 512 * 1024;
  const fileMax = 20 * 1024 * 1024;
  const resultMax = 2 * 1024 * 1024;
  const validate = (path: string, rootsValue: Object): void => {
    if (path.startsWith('file://media/')) return;
    const roots = Array.isArray(rootsValue) ? rootsValue as Array<string> : [];
    const root = roots.find((candidate: string): boolean => path === candidate || path.startsWith(candidate + '/'));
    if (root === undefined) throw new Error('INVALID_ARGUMENT: 文件必须位于宿主沙盒');
    let current = root;
    for (const component of path.substring(root.length).split('/')) {
      if (component.length === 0) continue;
      if (component === '..') throw new Error('INVALID_ARGUMENT: 不允许路径穿越');
      current += '/' + component;
      if (fileIo.accessSync(current) && fileIo.lstatSync(current).isSymbolicLink()) throw new Error('INVALID_ARGUMENT: 不允许符号链接逃逸沙盒');
    }
  };
  const writeAll = (fd: number, data: ArrayBuffer): void => {
    let offset = 0;
    while (offset < data.byteLength) {
      const written = fileIo.writeSync(fd, offset === 0 ? data : data.slice(offset));
      if (written <= 0) throw new Error('IO: 文件写入未前进');
      offset += written;
    }
  };
  if (command === 'validatePath') { validate(String(values[0]), values[1]); return {}; }

  if (command === 'stageLegacyDataURL') {
    const options = JSON.parse(String(values[0])) as Record<string, Object>;
    if (options === null || typeof options !== 'object' || Array.isArray(options)) throw new Error('INVALID_ARGUMENT: media options 必须为 JSON 对象');
    const url = String(options['dataURL'] ?? '');
    const comma = url.indexOf(',');
    if (comma < 0 || !url.startsWith('data:') || !url.substring(0, comma).endsWith(';base64')) throw new Error('INVALID_ARGUMENT: dataURL 必须为 Base64 Data URL');
    const encoded = url.substring(comma + 1);
    if (encoded.length > Math.ceil(fileMax / 3) * 4) throw new Error('PAYLOAD_TOO_LARGE: Data URL 超过 20 MiB');
    const decoded = new util.Base64Helper().decodeSync(encoded);
    if (decoded.byteLength > fileMax) throw new Error('PAYLOAD_TOO_LARGE: Data URL 超过 20 MiB');
    const name = String(options['filename'] ?? 'lynx-file').replace(/[^A-Za-z0-9._-]/g, '_');
    const rawExtension = String(options['extension'] ?? 'bin').replace(/^\.+/, '');
    const extension = /^[A-Za-z0-9]{1,10}$/.test(rawExtension) ? rawExtension.toLowerCase() : 'bin';
    const path = String(values[1]) + '/' + (name.length > 0 ? name : 'lynx-file') + '.' + extension;
    const part = path + '.' + String(values[2]) + '.part';
    let succeeded = false;
    const file = fileIo.openSync(part, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try { writeAll(file.fd, decoded.buffer); fileIo.fsyncSync(file.fd); succeeded = true; return { part: part, path: path }; }
    finally { fileIo.closeSync(file); if (!succeeded && fileIo.accessSync(part)) fileIo.unlinkSync(part); }
  }
  if (command === 'parseJSON') {
    const json = String(values[0]);
    if (new util.TextEncoder().encodeInto(json).byteLength > inline) throw new Error('RESULT_TOO_LARGE: 存储索引超过 512 KiB');
    return JSON.parse(json) as Object;
  }
  if (command === 'stringify') {
    const result = JSON.stringify(values[0]);
    if (new util.TextEncoder().encodeInto(result).byteLength > resultMax) throw new Error('RESULT_TOO_LARGE: 结果超过 2 MiB');
    return result;
  }
  if (command === 'encodeBytes') {
    const bytes = values[0] as Uint8Array;
    if (bytes.byteLength > inline) throw new Error('RESULT_TOO_LARGE: 二进制内联数据超过 512 KiB');
    return new util.Base64Helper().encodeToStringSync(bytes);
  }
  if (command === 'decodeBody') {
    const raw = String(values[0]);
    if (raw.length > Math.ceil(inline / 3) * 4) throw new Error('PAYLOAD_TOO_LARGE: HTTP Base64 请求超过 512 KiB');
    const data = new util.Base64Helper().decodeSync(raw);
    if (data.byteLength > inline) throw new Error('PAYLOAD_TOO_LARGE: HTTP 请求超过 512 KiB');
    return data.buffer;
  }
  if (command === 'multipartBody') {
    const data = values[0];
    if (!Array.isArray(data)) throw new Error('INVALID_ARGUMENT: FormData 必须为 entries 数组');
    const boundary = 'lynx-capacitor-' + String(Date.now());
    const encoder = new util.TextEncoder();
    const chunks: Array<Uint8Array> = [];
    let length = 0;
    for (const raw of data as Array<Object>) {
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('INVALID_ARGUMENT: FormData entry 必须为对象');
      const entry = raw as Record<string, Object>;
      const type = String(entry['type'] ?? '');
      if (type !== 'string' && type !== 'base64File') throw new Error('INVALID_ARGUMENT: 不支持的 FormData entry.type');
      const key = String(entry['key'] ?? '');
      const file = String(entry['type'] ?? '') === 'base64File';
      if (key.length === 0 || /[\r\n"]/.test(key) || (file && /[\r\n"]/.test(String(entry['fileName'] ?? 'file')))) throw new Error('INVALID_ARGUMENT: FormData 字段名/文件名非法');
      const contentType = String(entry['contentType'] ?? 'application/octet-stream');
      if (/[\r\n]/.test(contentType)) throw new Error('INVALID_ARGUMENT: FormData MIME 非法');
      const header = '--' + boundary + '\r\nContent-Disposition: form-data; name="' + key + '"' + (file ? '; filename="' + String(entry['fileName'] ?? 'file') + '"\r\nContent-Type: ' + contentType : '') + '\r\n\r\n';
      const bytes = file ? new util.Base64Helper().decodeSync(String(entry['value'])) : encoder.encodeInto(String(entry['value']));
      const prefix = encoder.encodeInto(header);
      const suffix = encoder.encodeInto('\r\n');
      length += prefix.byteLength + bytes.byteLength + suffix.byteLength;
      if (length > inline) throw new Error('PAYLOAD_TOO_LARGE: FormData 超过 512 KiB');
      chunks.push(prefix, bytes, suffix);
    }
    const ending = encoder.encodeInto('--' + boundary + '--\r\n');
    length += ending.byteLength;
    if (length > inline) throw new Error('PAYLOAD_TOO_LARGE: FormData 超过 512 KiB');
    chunks.push(ending);
    const output = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) { output.set(chunk, offset); offset += chunk.byteLength; }
    return { body: output.buffer, contentType: 'multipart/form-data; boundary=' + boundary };
  }
  if (command === 'httpResponse') {
    const data = values[0];
    const isJSON = Boolean(values[1]);
    const binaryResponse = Boolean(values[2]);
    let result: Object;
    if (data instanceof ArrayBuffer) {
      if (data.byteLength > inline) throw new Error('RESPONSE_TOO_LARGE: HTTP 响应超过 512 KiB');
      result = binaryResponse && !isJSON ? new util.Base64Helper().encodeToStringSync(new Uint8Array(data)) : new util.TextDecoder().decode(new Uint8Array(data));
    } else result = typeof data === 'string' ? data : JSON.stringify(data);
    if (!(data instanceof ArrayBuffer) && new util.TextEncoder().encodeInto(String(result)).byteLength > inline) throw new Error('RESPONSE_TOO_LARGE: HTTP 响应超过 512 KiB');
    if (isJSON) { try { result = JSON.parse(String(result)) as Object; } catch (_error) { throw new Error('INVALID_RESPONSE: HTTP JSON 响应无法解析'); } }
    return result;
  }
  const path = String(values[0]);
  if (command === 'read') {
    validate(path, values[2]);
    const stat = fileIo.statSync(path);
    if (stat.size > inline) throw new Error('RESULT_TOO_LARGE: 内联读取超过 512 KiB，请使用文件 URI');
    const encoding = String(values[1]).toUpperCase();
    if (encoding === 'UTF8' || encoding === 'UTF-8' || encoding === 'TEXT') return fileIo.readTextSync(path);
    if (encoding !== 'BASE64') throw new Error('UNSUPPORTED_ENCODING: 只支持 UTF8/TEXT/BASE64');
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const data = new ArrayBuffer(stat.size);
      const count = fileIo.readSync(file.fd, data);
      const encoded = new util.Base64Helper().encodeToStringSync(new Uint8Array(data, 0, count));
      return encoded;
    } finally { fileIo.closeSync(file); }
  }
  if (command === 'stageWrite' || command === 'stageDataURL') {
    validate(path, values[3]);
    const raw = String(values[1]);
    const encoding = String(values[2]).toUpperCase();
    let value: string | ArrayBuffer;
    if (encoding === 'UTF8' || encoding === 'UTF-8' || encoding === 'TEXT') {
      if (new util.TextEncoder().encodeInto(raw).byteLength > inline) throw new Error('PAYLOAD_TOO_LARGE: 文件内联数据超过 512 KiB');
      value = raw;
    } else {
      if (encoding !== 'BASE64') throw new Error('UNSUPPORTED_ENCODING: 只支持 UTF8/TEXT/BASE64');
      const max = command === 'stageDataURL' ? fileMax : inline;
      if (raw.length > Math.ceil(max / 3) * 4) throw new Error('PAYLOAD_TOO_LARGE: 编码文件超过预算');
      const bytes = new util.Base64Helper().decodeSync(raw);
      if (bytes.byteLength > max) throw new Error('PAYLOAD_TOO_LARGE: 文件超过预算');
      value = bytes.buffer;
    }
    const parent = path.substring(0, path.lastIndexOf('/'));
    if (parent.length > 0) fileIo.mkdirSync(parent, true);
    const file = fileIo.openSync(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try { writeAll(file.fd, typeof value === 'string' ? new util.TextEncoder().encodeInto(value).buffer : value); fileIo.fsyncSync(file.fd); }
    finally { fileIo.closeSync(file); }
    return path;
  }
  if (command === 'list') {
    validate(path, values[1]);
    const names = fileIo.listFileSync(path);
    const rows: Array<Record<string, Object>> = [];
    let bytes = 2;
    for (const name of names) {
      const stat = fileIo.statSync(path + '/' + name);
      const row: Record<string, Object> = { name: name, type: stat.isDirectory() ? 'directory' : 'file', size: stat.size, mtime: stat.mtime, uri: fileUri.getUriFromPath(path + '/' + name) };
      bytes += new util.TextEncoder().encodeInto(JSON.stringify(row)).byteLength + 1;
      if (bytes > resultMax) throw new Error('RESULT_TOO_LARGE: 目录结果超过 2 MiB');
      rows.push(row);
    }
    return rows;
  }
  if (command === 'copy') {
    const destination = String(values[1]);
    validate(path, values[2]);
    validate(destination, values[2]);
    const source = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    let target: fileIo.File | null = null;
    try {
      const stat = fileIo.statSync(source.fd);
      if (stat.size > fileMax) throw new Error('FILE_TOO_LARGE: 文件超过 20 MiB');
      const parent = destination.substring(0, destination.lastIndexOf('/'));
      fileIo.mkdirSync(parent, true);
      target = fileIo.openSync(destination, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      const chunk = new ArrayBuffer(64 * 1024);
      let total = 0;
      while (true) {
        const count = fileIo.readSync(source.fd, chunk);
        if (count === 0) break;
        total += count;
        if (total > fileMax) throw new Error('FILE_TOO_LARGE: 文件增长超过 20 MiB');
        writeAll(target.fd, count === chunk.byteLength ? chunk : chunk.slice(0, count));
      }
      fileIo.fsyncSync(target.fd);
      return total;
    } finally { fileIo.closeSync(source); if (target !== null) fileIo.closeSync(target); }
  }
  throw new Error('UNIMPLEMENTED: IO command ' + command);
}

export function lynxNativeErrorCode(error: Object, fallback: string = 'UNAVAILABLE'): string {
  const message = (error as Error).message;
  const text = typeof message === 'string' ? message : String(error);
  const codes = ['ACTIVITY_DESTROYED', 'BUSY', 'RESULT_TOO_LARGE', 'PAYLOAD_TOO_LARGE',
    'RESPONSE_TOO_LARGE', 'FILE_TOO_LARGE', 'INVALID_ARGUMENT', 'CANCELLED', 'NOT_FOUND',
    'PERMISSION_DENIED', 'UNSUPPORTED', 'UNIMPLEMENTED', 'UNAVAILABLE', 'INVALID_RESPONSE',
    'CONNECTION_NOT_FOUND', 'CONNECTION_READ_ONLY', 'UNSUPPORTED_ENCODING', 'NETWORK', 'HTTP_ERROR', 'IO',
    'USER_CANCELLED', 'AUTHENTICATION_TIMEOUT', 'BIOMETRY_LOCKOUT', 'AUTHENTICATION_FAILED',
    'HARDWARE_UNAVAILABLE', 'NO_HANDLER', 'MEDIA_CONTRACT_ERROR'];
  const code = text.replace(/^Error: /, '').split(':')[0];
  return codes.includes(code) ? code : fallback;
}
