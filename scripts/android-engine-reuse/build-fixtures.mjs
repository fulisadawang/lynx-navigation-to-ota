import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { fixtureSpec } from '../fixtures/engine-reuse/spec.mjs';
import { inspectRuntimeScripts } from '../fixtures/engine-reuse/runtime-preflight.mjs';
import { verifyFixtures } from '../fixtures/engine-reuse/verify-fixtures.mjs';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const fixtureRoot = join(repositoryRoot, 'scripts/fixtures/engine-reuse');
const options = { dependencies: fixtureSpec.defaultDependencies, out: fixtureSpec.defaultOutput,
  'asset-prefix': fixtureSpec.defaultAssetPrefix };
for (let index = 2; index < process.argv.length; index += 2) {
  const name = process.argv[index].slice(2);
  assert(process.argv[index].startsWith('--') && name in options && process.argv[index + 1],
    '仅支持 --dependencies、--out、--asset-prefix，均须提供值');
  options[name] = process.argv[index + 1];
}
const dependencyRoot = realpathSync(resolve(options.dependencies));
const outputRoot = resolve(options.out);
const assetPrefix = new URL(options['asset-prefix']).href;
assert(assetPrefix.endsWith('/'), 'asset-prefix 须以 / 结尾');
assert(!outputRoot.startsWith(repositoryRoot) && !outputRoot.startsWith(dependencyRoot), '产物须写入仓库及依赖目录之外');
const dependencyLink = join(fixtureRoot, 'node_modules');
if (existsSync(dependencyLink)) {
  assert(lstatSync(dependencyLink).isSymbolicLink(), '不覆盖已有真实 node_modules');
  assert.equal(realpathSync(dependencyLink), dependencyRoot);
} else {
  symlinkSync(dependencyRoot, dependencyLink, 'dir');
}
// 插件在加载时读取 NODE_ENV 与 lazy loader 选择，需先固定真实生产构建环境。
process.env.NODE_ENV = 'production';
process.env.REACT_LAZY_BUNDLE_FETCHER = 'FetchBundle';
const { createRspeedy, defineConfig } = await import(pathToFileURL(join(dependencyRoot, '@lynx-js/rspeedy/dist/index.js')).href);
const { pluginReactLynx } = await import(pathToFileURL(join(dependencyRoot, '@lynx-js/react-rsbuild-plugin/dist/index.js')).href);
const versionOf = (name) => JSON.parse(readFileSync(join(dependencyRoot, name, 'package.json'), 'utf8')).version;
const toolchain = { reactLynx: versionOf('@lynx-js/react'), rspeedy: versionOf('@lynx-js/rspeedy'),
  reactPlugin: versionOf('@lynx-js/react-rsbuild-plugin'), engineVersion: '4.1', mode: 'production', lazyBundleFetcher: 'FetchBundle' };
assert.equal(toolchain.reactLynx, '0.123.3');
assert.equal(toolchain.rspeedy, '0.16.3');
assert.equal(toolchain.reactPlugin, '0.18.3');
mkdirSync(outputRoot, { recursive: true });
assert.equal(readdirSync(outputRoot).length, 0, '输出目录须为空，避免覆盖归档');

function listFiles(directory) {
  return readdirSync(directory).flatMap((name) => {
    const path = join(directory, name);
    return statSync(path).isDirectory() ? listFiles(path).map((child) => `${name}/${child}`) : [name];
  });
}
function identity(path) {
  const bytes = readFileSync(path);
  return { size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
}
async function build(entryName, sourceName, isLazyBundle = false) {
  const caseOutput = join(`${outputRoot}-build`, entryName);
  let graph;
  const config = defineConfig({
    mode: 'production', environments: { lynx: {} },
    source: { entry: { [entryName]: join(fixtureRoot, `src/${sourceName}.tsx`) }, define: {
      'process.env.NODE_ENV': JSON.stringify('production'),
      __ENGINE_REUSE_LAZY_URL__: JSON.stringify(new URL(fixtureSpec.lazyBundlePath, assetPrefix).href),
    } },
    output: { inlineScripts: true, filename: { bundle: '[name].[platform].bundle' }, sourceMap: false,
      assetPrefix, cleanDistPath: true, distPath: { root: caseOutput } },
    tools: { rspack(config) {
      config.optimization ??= {};
      config.optimization.splitChunks = false;
      config.plugins ??= [];
      config.plugins.push({ apply(compiler) {
        compiler.hooks.done.tap('EngineReuseFixtureGraph', (stats) => {
          graph = stats.toJson({ all: false, chunks: true, chunkModules: true, ids: true });
        });
      } });
      return config;
    } },
    plugins: [pluginReactLynx({ enableNewGesture: true, engineVersion: '4.1',
      ...(isLazyBundle ? { experimental_isLazyBundle: true } : {}) })],
  });
  const rspeedy = await createRspeedy({ cwd: fixtureRoot, rspeedyConfig: config, loadEnv: false, environment: ['lynx'] });
  await rspeedy.build();
  const available = listFiles(caseOutput);
  const bundlePath = `${entryName}.lynx.bundle`;
  assert(available.includes(bundlePath), `${bundlePath} 缺失`);
  const nonInternalJs = available.filter((path) => path.endsWith('.js') && !path.startsWith('.rspeedy/'));
  assert.equal(nonInternalJs.length, 0, '本Fixture禁止外置JS chunk');
  const finalPath = isLazyBundle ? fixtureSpec.lazyBundlePath : bundlePath;
  mkdirSync(dirname(join(outputRoot, finalPath)), { recursive: true });
  cpSync(join(caseOutput, bundlePath), join(outputRoot, finalPath));
  const emittedScriptPaths = available.filter((path) => path.endsWith('.js')).map((path) => join(caseOutput, path));
  return { path: finalPath, ...identity(join(outputRoot, finalPath)),
    runtimePreflight: inspectRuntimeScripts(join(outputRoot, finalPath), dependencyRoot, emittedScriptPaths),
    emittedChunks: (graph?.chunks ?? []).map((chunk) => ({ names: chunk.names, files: chunk.files })),
    standaloneLazyBundle: isLazyBundle };
}

const panel = await build('EngineReuseLazyPanel', 'LazyPanel', true);
const state = await build('EngineReuseStateProbe', 'StateProbe');
const lazy = await build('EngineReuseLazyProbe', 'LazyProbe');
const lazyResource = { ...panel, ownerBundlePath: lazy.path, requestKey: `/${panel.path}`,
  url: new URL(panel.path, assetPrefix).href,
  requestAliases: [new URL(panel.path, assetPrefix).href, `/${panel.path}`], kind: 'lazyBundle' };
const metadata = { schemaVersion: fixtureSpec.schemaVersion, marker: fixtureSpec.marker,
  toolchain, assetPrefix, externalScripts: [],
  hostInputContract: { initData: { marker: 'fresh marker per page', oldOnly: 'only present on first page' },
    globalProps: { probePageId: 'exact ShellMessageHub source pageId', marker: 'fresh global marker per page', oldOnly: 'only present on first page' } },
  eventContract: { ready: fixtureSpec.readyEvent, lazyReady: fixtureSpec.lazyReadyEvent, nativeAcceptCode: 0 },
  cases: [{ ...state, caseName: 'state', asyncResources: [] }, { ...lazy, caseName: 'lazy', asyncResources: [lazyResource] }],
};
writeFileSync(join(outputRoot, 'fixture-metadata.json'), `${JSON.stringify(metadata, null, 2)}\n`);
console.log(JSON.stringify({ ...verifyFixtures(outputRoot, dependencyRoot), outputDirectory: outputRoot,
  metadataPath: join(outputRoot, 'fixture-metadata.json') }));
