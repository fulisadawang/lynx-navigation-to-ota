import { createServer } from 'node:http';
import { readFile, realpath, readdir } from 'node:fs/promises';
import { resolve, relative, isAbsolute } from 'node:path';
import { createHash } from 'node:crypto';

// 只用于本机回归；真实模板字节和声明 hash 始终一起验证，不发布到远程。
const root = await realpath(resolve(process.argv[2]));
const requestedPort = Number(process.argv[3] ?? 0);
const appId = '10020000';
const hash = (bytes) => `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
const names = (await readdir(root)).filter((name) => name.endsWith('.lynx.bundle')).sort();
if (!names.includes('HomePage.lynx.bundle') || !names.includes('OtaEcommercePage.lynx.bundle')) {
  throw new Error('测试必须使用模板 HomePage 和 OtaEcommercePage 的真实构建产物');
}
const index = JSON.parse(await readFile(resolve(root, 'ota-resources.local.json'), 'utf8'));
const files = new Map();
async function cacheFile(path, expected) {
  const absolute = await realpath(resolve(root, path));
  const inside = relative(root, absolute);
  if (!inside || inside.startsWith('..') || isAbsolute(inside)) throw new Error('产物路径不在构建目录');
  const bytes = await readFile(absolute);
  if (expected && (bytes.length !== expected.size || hash(bytes) !== expected.sha256)) throw new Error('真实 Async 产物校验失败');
  files.set(path, bytes);
}
for (const name of names) await cacheFile(name);
for (const entry of index.asyncEntries) await cacheFile(entry.path, entry);

let origin;
let phase = 'v1';
let revision = 1;
let offline = false;
const requests = new Map();
const events = [];
const streams = [];
let asyncBytes;
let asyncRef;
function latest(platform, hostApp) {
  const sequence = phase === 'v1' ? '1' : '2';
  return {
    env: 'TEST', hostApp, lynxAppId: appId, platform, platforms: ['ios', 'android'],
    status: 'ACTIVE', releaseId: `template-${phase}`, releaseSequence: sequence,
    selectionSchemaVersion: 1,
    selection: { kind: 'full', policyRevision: String(revision), reason: 'latest_full' },
    versionCodeRange: { min: '1', max: '999999999' }, lynxSdkRange: { min: '4.1', max: '4.1.0' },
    asyncBundleManifest: asyncRef,
    changedBundles: names.map((name, index) => ({
      pageId: index + 1, bundlePath: name, bundleUrl: `${origin}/files/${name}`,
      bundleSha256: phase === 'bad-sha' ? `sha256:${'0'.repeat(64)}` : hash(files.get(name)),
      size: files.get(name).length, required: true, prefetch: false,
    })),
  };
}
function json(response, value, code = 200) {
  response.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  response.end(JSON.stringify(value));
}
const server = createServer(async (request, response) => {
  const url = new URL(request.url, 'http://127.0.0.1');
  try {
    if (url.pathname === '/_readiness/state') {
      json(response, { origin, phase, revision, offline, requests: Object.fromEntries(requests), events, streams,
        bundles: names.map((name) => ({ name, sha256: hash(files.get(name)), size: files.get(name).length })),
        asyncCount: index.asyncEntries.length });
      return;
    }
    if (url.pathname === '/_readiness/control' && request.method === 'POST') {
      let body = '';
      for await (const chunk of request) {
        body += chunk;
        if (Buffer.byteLength(body) > 4096) { json(response, { error: '控制请求过大' }, 413); return; }
      }
      const value = JSON.parse(body);
      if (value.phase !== undefined) {
        if (!['v1', 'v2', 'bad-sha'].includes(value.phase)) { json(response, { error: '测试阶段无效' }, 400); return; }
        phase = value.phase; revision++;
      }
      if (value.offline !== undefined) offline = value.offline === true;
      if (value.resetMetrics === true) { requests.clear(); events.length = 0; }
      json(response, { phase, revision, offline });
      return;
    }
    requests.set(url.pathname, (requests.get(url.pathname) ?? 0) + 1);
    if (offline) { json(response, { error: '本地测试网络故障' }, 503); return; }
    if (url.pathname === '/_readiness/stream') {
      // 固定慢流仅验证能力 IO 取消，不代替用户模板 Bundle。
      const stream = { id: String(streams.length + 1), started: true, closed: false, completed: false, sentBytes: 0 };
      streams.push(stream);
      if (streams.length > 32) streams.shift();
      const size = 2 * 1024 * 1024;
      response.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': size });
      const timer = setInterval(() => {
        if (stream.sentBytes === size) {
          stream.completed = true;
          clearInterval(timer);
          response.end();
        } else {
          const chunk = Buffer.alloc(Math.min(8192, size - stream.sentBytes), 97);
          response.write(chunk);
          stream.sentBytes += chunk.length;
        }
      }, 100);
      response.on('close', () => { stream.closed = true; clearInterval(timer); });
      return;
    }
    if (url.pathname === '/api/ota/v1/releases/latest-bundle-list') {
      const platform = url.searchParams.get('platform');
      const hostApp = url.searchParams.get('hostApp') ?? 'capp';
      if (!['ios', 'android'].includes(platform) || !/^[1-9]\d*$/.test(url.searchParams.get('versioncode') ?? '') ||
          !url.searchParams.get('lynxSdkVersion') || !['capp', 'gapp', 'template'].includes(hostApp)) { json(response, { error: '必须携带真实选择上下文' }, 400); return; }
      const selected = latest(platform, hostApp);
      if (url.searchParams.has('lynxAppId')) {
        if (url.searchParams.get('lynxAppId') === appId) json(response, selected);
        else json(response, { env: 'TEST', hostApp, platform, selectionSchemaVersion: 1,
          decision: { lynxAppId: url.searchParams.get('lynxAppId'), action: 'no_compatible_release',
            policyRevision: String(revision), reason: 'no_matching_release' } });
      } else json(response, { env: 'TEST', hostApp, platform,
        selectionSchemaVersion: 1, bundleLists: [selected], directives: [] });
      return;
    }
    if (url.pathname === '/api/ota/v1/release/report' && request.method === 'POST') {
      let body = '';
      for await (const chunk of request) { body += chunk; if (Buffer.byteLength(body) > 32768) break; }
      const event = JSON.parse(body);
      // 记录行为与 Release，测试日志不保存 token、请求头或用户标识。
      events.push({ event: event.event, releaseId: event.releaseId, reasonCode: event.reasonCode,
        eventResult: event.eventResult });
      if (events.length > 200) events.shift();
      json(response, { accepted: true, event: event.event, releaseId: event.releaseId });
      return;
    }
    if (url.pathname === '/async-manifest.json') {
      response.writeHead(200, { 'content-type': 'application/json', 'content-length': asyncBytes.length });
      response.end(asyncBytes); return;
    }
    if (url.pathname.startsWith('/files/')) {
      const path = decodeURIComponent(url.pathname.slice('/files/'.length));
      const bytes = files.get(path);
      if (!bytes) { json(response, { error: '没有对应真实产物' }, 404); return; }
      response.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': bytes.length });
      response.end(bytes); return;
    }
    json(response, { error: '没有此本地测试入口' }, 404);
  } catch {
    json(response, { error: '本地测试请求无效' }, 400);
  }
});
server.listen(requestedPort, '127.0.0.1', () => {
  origin = `http://127.0.0.1:${server.address().port}`;
  asyncBytes = Buffer.from(JSON.stringify({ schemaVersion: 1, entries: index.asyncEntries.map((entry) => ({
    ...entry, url: `${origin}/files/${entry.path}`,
  })) }));
  asyncRef = { schemaVersion: 1, url: `${origin}/async-manifest.json`, sha256: hash(asyncBytes), size: asyncBytes.length };
  process.stdout.write(JSON.stringify({ origin, appId, bundleCount: names.length, asyncCount: index.asyncEntries.length }) + '\n');
});
