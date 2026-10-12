import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fixtureSpec } from './spec.mjs';

export function verifyFixtures(directory, dependencyRoot = fixtureSpec.defaultDependencies) {
  const metadata = JSON.parse(readFileSync(join(directory, 'fixture-metadata.json'), 'utf8'));
  assert.equal(metadata.marker, fixtureSpec.marker);
  assert.equal(metadata.toolchain.mode, 'production');
  assert.equal(metadata.toolchain.engineVersion, '4.1');
  assert.equal(metadata.toolchain.lazyBundleFetcher, 'FetchBundle');
  assert.equal(metadata.cases.length, 2);
  const require = createRequire(realpathSync(join(dependencyRoot, '@lynx-js/react-rsbuild-plugin/dist/index.js')));
  const { decode_napi } = require('@lynx-js/tasm');
  for (const item of metadata.cases) {
    assert.equal(item.runtimePreflight.freeProcessReferences, 0);
    assert(item.runtimePreflight.inlineScriptsChecked > 0);
    const bytes = readFileSync(join(directory, item.path));
    assert.equal(bytes.length, item.size);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), item.sha256);
    assert(Array.isArray(decode_napi(bytes)['background-thread-script']));
  }
  const lazy = metadata.cases.find((item) => item.caseName === 'lazy');
  assert.equal(lazy.path, fixtureSpec.lazyOwnerBundlePath);
  assert.equal(lazy.asyncResources.length, 1, '必须存在一个真实独立 lazy component Bundle');
  const resource = lazy.asyncResources[0];
  assert.equal(resource.kind, 'lazyBundle');
  assert.equal(resource.ownerBundlePath, lazy.path);
  assert.equal(resource.path, fixtureSpec.lazyBundlePath);
  assert.equal(resource.requestKey, `/${resource.path}`);
  const bytes = readFileSync(join(directory, resource.path));
  assert.equal(bytes.length, resource.size);
  assert.equal(createHash('sha256').update(bytes).digest('hex'), resource.sha256);
  assert.equal(resource.runtimePreflight.freeProcessReferences, 0);
  const decodedLazy = decode_napi(bytes);
  assert.equal(typeof decodedLazy['custom-sections']?.background, 'string', 'FetchBundle lazy须有可执行background自定义section');
  assert('main-thread' in decodedLazy['custom-sections'], 'FetchBundle lazy须有main-thread自定义section');
  const decodedOwner = decode_napi(readFileSync(join(directory, lazy.path)));
  const ownerSource = decodedOwner['background-thread-script'].filter((entry) => entry.type === 'source').map((entry) => entry.content).join('\n');
  assert(ownerSource.includes(resource.url), '消费者主包须包含确定的lazy URL');
  assert(ownerSource.includes('fetchBundle'), '消费者须使用真实FetchBundle loader');
  assert(!ownerSource.includes('engine-reuse-probe.lazy-ready'), 'lazy组件执行代码不得并入主包');
  assert(decodedLazy['custom-sections'].background.includes('engine-reuse-probe.lazy-ready'), 'lazy组件回执须属于独立bundle');
  assert.equal(metadata.externalScripts.length, 0, '禁止使用外置JS chunk冒充lazy component');
  return { status: 'PASS', mainBundles: 2, lazyBundles: 1, freeProcessReferences: 0 };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  console.log(JSON.stringify(verifyFixtures(process.argv[2] ?? fixtureSpec.defaultOutput)));
}
