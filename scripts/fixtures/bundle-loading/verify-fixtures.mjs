import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { asyncChecksum, fixtureSpec, makePayload, readyLabel, sparseChecksum } from './spec.mjs';
import { inspectRuntimeScripts } from './runtime-preflight.mjs';

function filesUnder(directory) {
  return readdirSync(directory).flatMap((name) => {
    const fullPath = join(directory, name);
    return statSync(fullPath).isDirectory()
      ? filesUnder(fullPath).map((child) => `${name}/${child}`)
      : [name];
  });
}

export function verifyFixtures(outputDirectory) {
  const metadata = JSON.parse(readFileSync(join(outputDirectory, 'fixture-metadata.json'), 'utf8'));
  assert.equal(metadata.schemaVersion, fixtureSpec.schemaVersion);
  assert.equal(metadata.toolchain.reactLynx, '0.123.3');
  assert.equal(metadata.toolchain.rspeedy, '0.16.3');
  assert.equal(metadata.toolchain.reactPlugin, '0.18.3');
  assert.equal(metadata.toolchain.engineVersion, '4.1');
  assert.equal(metadata.toolchain.mode, 'production');
  assert.equal(metadata.cases.length, 3);

  const expected = {
    small: { caseName: 'small', moduleCount: 0, payloadLength: 0, checksum: 0 },
    large: { caseName: 'large', moduleCount: 0, payloadLength: fixtureSpec.largePayloadLength,
      checksum: sparseChecksum(makePayload(fixtureSpec.largePayloadLength)) },
    async: { caseName: 'async', moduleCount: fixtureSpec.asyncModuleCount, payloadLength: 0,
      checksum: asyncChecksum() },
  };
  const allowed = new Set(['fixture-metadata.json']);
  for (const item of metadata.cases) {
    assert.deepEqual(item.expectedReadyPayload, expected[item.caseName]);
    assert.equal(item.expectedReadyLabel, readyLabel(expected[item.caseName]));
    assert.equal(item.inlineScripts, item.caseName !== 'async');
    allowed.add(item.path);
    const bytes = readFileSync(join(outputDirectory, item.path));
    assert.equal(bytes.length, item.size, `${item.path} size`);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), item.sha256, `${item.path} SHA`);
    assert(bytes.length > 1024, `${item.path} 必须是编译产物`);
    if (item.caseName === 'large') {
      assert(bytes.length >= 2 * 1024 * 1024 && bytes.length <= 4 * 1024 * 1024, '大包须为实际 2–4 MiB');
    }
    assert.equal(item.asyncResources.length, item.caseName === 'async' ? 10 : 0);
    const requestKeys = new Set();
    for (const resource of item.asyncResources) {
      assert.equal(resource.ownerBundlePath, item.path);
      assert.equal(resource.kind, 'script');
      assert(!resource.path.includes('__main-thread') && !resource.path.endsWith('/main-thread.js'));
      assert.equal(resource.requestKey, `/${resource.path}`);
      assert.equal(resource.url, new URL(resource.path, metadata.assetPrefix).href);
      assert.deepEqual(resource.requestAliases, [resource.url, new URL(resource.url).pathname]);
      assert(!requestKeys.has(resource.requestKey), 'requestKey 必须唯一');
      requestKeys.add(resource.requestKey);
      allowed.add(resource.path);
      const script = readFileSync(join(outputDirectory, resource.path));
      assert.equal(script.length, resource.size, `${resource.path} size`);
      assert.equal(createHash('sha256').update(script).digest('hex'), resource.sha256, `${resource.path} SHA`);
      assert(script.length > 0);
    }
    assert.deepEqual(inspectRuntimeScripts(join(outputDirectory, item.path),
      item.asyncResources.map((resource) => join(outputDirectory, resource.path))), item.runtimePreflight,
    '必须从真实 Bundle 和外部脚本重新验证 process 残留');
  }
  assert.deepEqual(filesUnder(outputDirectory).sort(), [...allowed].sort(), '归档文件与 metadata 必须完全匹配');
  return metadata;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const directory = resolve(process.argv[2] ?? fixtureSpec.defaultOutput);
  const metadata = verifyFixtures(directory);
  console.log(JSON.stringify({ status: 'PASS', cases: metadata.cases.map((item) => ({
    caseName: item.caseName, size: item.size, scripts: item.asyncResources.length,
  })) }));
}
