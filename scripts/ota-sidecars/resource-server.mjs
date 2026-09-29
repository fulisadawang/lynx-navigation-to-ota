import { createServer } from 'node:http';
import { readFile, realpath, stat } from 'node:fs/promises';
import { resolve, relative, isAbsolute, extname } from 'node:path';

const root = await realpath(resolve(process.argv[2] ?? ''));
const port = Number(process.argv[3] ?? 3135);
if (!process.argv[2] || !Number.isInteger(port) || port < 1024 || port > 65535) {
  throw new Error('用法：node resource-server.mjs <本地构建目录> [端口]');
}
const counts = new Map();
const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, 'http://127.0.0.1');
    if (url.pathname === '/__metrics' && request.method === 'GET') {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ total: [...counts.values()].reduce((a, b) => a + b, 0), paths: Object.fromEntries(counts) }));
      return;
    }
    if (request.method !== 'GET') { response.writeHead(405); response.end(); return; }
    const pathname = decodeURIComponent(url.pathname);
    const file = await realpath(resolve(root, '.' + pathname));
    const inside = relative(root, file);
    if (!inside || inside.startsWith('..') || isAbsolute(inside) || !(await stat(file)).isFile()) {
      response.writeHead(404); response.end(); return;
    }
    const content = await readFile(file);
    counts.set(pathname, (counts.get(pathname) ?? 0) + 1);
    const type = { '.json': 'application/json', '.png': 'image/png', '.js': 'application/javascript', '.css': 'text/css' }[extname(file)] ?? 'application/octet-stream';
    response.writeHead(200, { 'content-type': type, 'content-length': content.length, 'cache-control': 'no-store' });
    response.end(content);
  } catch {
    response.writeHead(404); response.end();
  }
});
server.listen(port, '127.0.0.1', () => process.stdout.write(`本地资源服务：http://127.0.0.1:${port}\n`));
