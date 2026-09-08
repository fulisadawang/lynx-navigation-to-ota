import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { performance } from 'node:perf_hooks';

export const HOST_EVIDENCE_KIND = 'host-transpiled-arkts-node-adapters';

/** 仅映射源码已使用的系统方法；不模拟 OTA 选择、Store 状态机或 Native IO 保证。 */
export function createNodeAdapters(directory, { allowedOrigins = [], rawResources = new Map() } = {}) {
  const inputRoot = path.resolve(directory);
  fs.mkdirSync(inputRoot, { recursive: true });
  const root = fs.realpathSync(inputRoot);
  const allowed = new Set(allowedOrigins.map((origin) => {
    const parsed = new URL(origin);
    if (parsed.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(parsed.hostname) || parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== '/') {
      throw new Error('host adapter 仅允许显式 loopback HTTP origin');
    }
    return parsed.origin;
  }));
  const openFiles = new Map();
  const audit = { fileCalls: {}, binaryWrites: 0, copiedFiles: 0, http: [], resources: [], digestCalls: 0, randomCalls: 0 };

  function guard(value) {
    if (typeof value !== 'string') throw new Error('host_fs_path_must_be_string');
    let target = path.resolve(value);
    if (target === inputRoot || target.startsWith(`${inputRoot}${path.sep}`)) target = path.join(root, path.relative(inputRoot, target));
    if (target !== root && !target.startsWith(`${root}${path.sep}`)) throw new Error('host_fs_outside_temporary_root');
    let current = target;
    while (current !== root) {
      if (fs.existsSync(current) && fs.lstatSync(current).isSymbolicLink()) throw new Error('host_fs_symlink_not_supported');
      current = path.dirname(current);
    }
    return target;
  }

  function count(name) { audit.fileCalls[name] = (audit.fileCalls[name] ?? 0) + 1; }
  function descriptor(value) {
    const fd = typeof value === 'number' ? value : value?.fd;
    if (!openFiles.has(fd)) throw new Error('host_fs_descriptor_not_owned');
    return fd;
  }
  function buffer(value) {
    if (typeof value === 'string') return Buffer.from(value, 'utf8');
    if (ArrayBuffer.isView(value)) return Buffer.from(value.buffer, value.byteOffset, value.byteLength);
    return Buffer.from(value);
  }
  function stat(value, follow) {
    count(follow ? 'statSync' : 'lstatSync');
    const result = follow ? fs.statSync(guard(value)) : fs.lstatSync(guard(value));
    return { size: result.size, mtime: Math.floor(result.mtimeMs / 1000), ctime: Math.floor(result.ctimeMs / 1000),
      isDirectory: () => result.isDirectory(), isFile: () => result.isFile(), isSymbolicLink: () => result.isSymbolicLink() };
  }
  const fileSystem = {
    OpenMode: { READ_ONLY: fs.constants.O_RDONLY, WRITE_ONLY: fs.constants.O_WRONLY, READ_WRITE: fs.constants.O_RDWR,
      CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC, APPEND: fs.constants.O_APPEND,
      DIR: fs.constants.O_DIRECTORY ?? 0, NOFOLLOW: fs.constants.O_NOFOLLOW ?? 0 },
    accessSync(value) { count('accessSync'); return fs.existsSync(guard(value)); },
    mkdirSync(value, recursive = false) { count('mkdirSync'); fs.mkdirSync(guard(value), { recursive }); },
    readTextSync(value) { count('readTextSync'); return fs.readFileSync(guard(value), 'utf8'); },
    listFileSync(value) { count('listFileSync'); return fs.readdirSync(guard(value)); },
    statSync(value) { return stat(value, true); },
    lstatSync(value) { return stat(value, false); },
    openSync(value, flags) { count('openSync'); const target = guard(value); const fd = fs.openSync(target, flags, 0o600); openFiles.set(fd, target); return { fd, path: target }; },
    closeSync(value) { count('closeSync'); const fd = descriptor(value); fs.closeSync(fd); openFiles.delete(fd); },
    fsyncSync(value) { count('fsyncSync'); fs.fsyncSync(descriptor(value)); },
    writeSync(value, data) {
      count('writeSync');
      if (typeof data !== 'string') audit.binaryWrites++;
      return fs.writeSync(descriptor(value), buffer(data));
    },
    readSync(value, data) { count('readSync'); const target = buffer(data); return fs.readSync(descriptor(value), target, 0, target.byteLength, null); },
    renameSync(from, to) { count('renameSync'); fs.renameSync(guard(from), guard(to)); },
    moveFileSync(from, to, mode = 0) { if (mode !== 0) throw new Error('host_moveFile_mode_not_implemented'); count('moveFileSync'); fs.renameSync(guard(from), guard(to)); },
    copyFileSync(from, to) { count('copyFileSync'); audit.copiedFiles++; fs.copyFileSync(guard(from), guard(to)); },
    unlinkSync(value) { count('unlinkSync'); fs.unlinkSync(guard(value)); },
    rmdirSync(value) { count('rmdirSync'); fs.rmdirSync(guard(value)); },
  };
  const cryptoFramework = {
    createMd(algorithm) {
      if (algorithm !== 'SHA256') throw new Error('host_digest_algorithm_not_implemented');
      audit.digestCalls++;
      const hash = crypto.createHash('sha256');
      return { updateSync(blob) { hash.update(buffer(blob.data)); }, digestSync() { return { data: new Uint8Array(hash.digest()) }; } };
    },
    createRandom() { return { generateRandomSync(size) { audit.randomCalls++; return { data: new Uint8Array(crypto.randomBytes(size)) }; } }; },
  };
  const requests = new Set();
  const http = {
    RequestMethod: { GET: 'GET', POST: 'POST' }, HttpDataType: { STRING: 0, ARRAY_BUFFER: 1 },
    createHttp() {
      const controller = new AbortController();
      let destroyed = false;
      const handle = {
        async request(rawUrl, options) {
          if (destroyed) throw new Error('host_http_request_destroyed');
          const url = new URL(rawUrl);
          if (!allowed.has(url.origin) || url.username || url.password) throw new Error('host_http_origin_not_allowed');
          const user = url.searchParams.get('userId');
          const entry = { method: options.method, path: url.pathname, completed: false,
            audience: !user ? 'anonymous' : user === 'user_demo_A' ? 'A' : user === 'user_demo_B' ? 'B' : 'other',
            platform: url.searchParams.get('platform'), versioncode: url.searchParams.get('versioncode'), lynxSdkVersion: url.searchParams.get('lynxSdkVersion'),
            clientTokenPresent: Object.keys(options.header ?? {}).some((key) => key.toLowerCase() === 'x-ota-client-token'),
            conditional: Object.keys(options.header ?? {}).some((key) => key.toLowerCase() === 'if-none-match') };
          audit.http.push(entry);
          const timer = setTimeout(() => controller.abort(), options.readTimeout ?? 30000);
          try {
            const response = await fetch(url, { method: options.method, headers: options.header, signal: controller.signal, redirect: 'error' });
            const bytes = new Uint8Array(await response.arrayBuffer());
            entry.statusCode = response.status; entry.bytes = bytes.byteLength; entry.completed = true;
            return { responseCode: response.status, result: options.expectDataType === http.HttpDataType.ARRAY_BUFFER ? bytes.buffer : new TextDecoder().decode(bytes), header: Object.fromEntries(response.headers.entries()) };
          } catch (error) { entry.error = error.name; throw error; }
          finally { clearTimeout(timer); }
        },
        destroy() { destroyed = true; controller.abort(); requests.delete(handle); },
      };
      requests.add(handle);
      return handle;
    },
  };
  const resourceManager = {
    getRawFileContent(name, callback) {
      audit.resources.push(name);
      const value = rawResources.get(name);
      queueMicrotask(() => {
        if (value === undefined) callback({ code: 9001005, message: 'host resource fixture missing' }, undefined);
        else callback(undefined, new Uint8Array(value));
      });
    },
  };
  const modules = {
    '@ohos.file.fs': fileSystem,
    '@ohos.security.cryptoFramework': cryptoFramework,
    '@ohos.net.http': http,
    '@ohos.systemDateTime': { TimeType: { STARTUP: 0 }, getUptime() { return Math.floor(performance.now()); } },
    '@kit.CoreFileKit': { statfs: { getFreeSizeSync(value) { const result = fs.statfsSync(guard(value)); return Number(result.bavail) * Number(result.bsize); } } },
    '@kit.AbilityKit': { common: {} },
  };
  return {
    root, audit, modules, context: { filesDir: root, resourceManager },
    metadata: { evidenceKind: HOST_EVIDENCE_KIND, deviceTested: false, nativeIOValidated: false,
      adapters: Object.keys(modules).concat('context.resourceManager'),
      limitations: ['Node FS/rename/fsync/statfs，不证明 Harmony native IO、掉电或 ENOSPC 语义', 'Node crypto，不证明 Harmony cryptoFramework 实现',
        'Node fetch/AbortController，不证明 Harmony 网络线程或系统取消', 'resourceManager 只读取显式传入的宿主资源 Map', '不支持 ArkUI struct/真实 View/首屏信号'] },
    close() { for (const request of [...requests]) request.destroy(); for (const fd of openFiles.keys()) fs.closeSync(fd); openFiles.clear(); },
  };
}
