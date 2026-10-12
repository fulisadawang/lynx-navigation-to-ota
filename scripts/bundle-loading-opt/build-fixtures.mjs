import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { asyncChecksum, fixtureSpec, makePayload, readyLabel, sparseChecksum } from '../fixtures/bundle-loading/spec.mjs';
import { verifyFixtures } from '../fixtures/bundle-loading/verify-fixtures.mjs';
import { inspectRuntimeScripts } from '../fixtures/bundle-loading/runtime-preflight.mjs';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const fixtureRoot = join(repositoryRoot, 'scripts/fixtures/bundle-loading');
const options = { dependencies: fixtureSpec.defaultDependencies, out: fixtureSpec.defaultOutput,
  'asset-prefix': fixtureSpec.defaultAssetPrefix };
for (let index = 2; index < process.argv.length; index += 2) {
  const name = process.argv[index].slice(2);
  if (!process.argv[index].startsWith('--') || !(name in options) || !process.argv[index + 1]) {
    throw new Error('参数仅支持 --dependencies、--out、--asset-prefix，均须提供值');
  }
  options[name] = process.argv[index + 1];
}
const dependencyRoot = realpathSync(resolve(options.dependencies));
const outputRoot = resolve(options.out);
const assetPrefix = new URL(options['asset-prefix']).href;
assert(assetPrefix.endsWith('/'), 'asset-prefix 须以 / 结尾');
assert(!outputRoot.startsWith(dependencyRoot), '产物不得写入借用的依赖目录');
assert(!outputRoot.startsWith(repositoryRoot), '生成产物须位于仓库之外');
const dependencyLink = join(fixtureRoot, 'node_modules');
if (existsSync(dependencyLink)) {
  assert(lstatSync(dependencyLink).isSymbolicLink(), '不覆盖已有真实 node_modules');
  assert.equal(realpathSync(dependencyLink), dependencyRoot, '既有依赖链接须与指定依赖一致');
} else {
  symlinkSync(dependencyRoot, dependencyLink, 'dir');
}
// ReactLynx 插件读取构建进程 NODE_ENV，单独设置 config.mode 不会覆盖其 nodeEnv=false。
process.env.NODE_ENV = 'production';
const { createRspeedy, defineConfig } = await import(pathToFileURL(join(dependencyRoot, '@lynx-js/rspeedy/dist/index.js')).href);
const { pluginReactLynx } = await import(pathToFileURL(join(dependencyRoot, '@lynx-js/react-rsbuild-plugin/dist/index.js')).href);
const versionOf = (name) => JSON.parse(readFileSync(join(dependencyRoot, name, 'package.json'), 'utf8')).version;
const toolchain = { reactLynx: versionOf('@lynx-js/react'), rspeedy: versionOf('@lynx-js/rspeedy'),
  reactPlugin: versionOf('@lynx-js/react-rsbuild-plugin'), engineVersion: '4.1', mode: 'production' };
assert.equal(toolchain.reactLynx, '0.123.3');
assert.equal(toolchain.rspeedy, '0.16.3');
assert.equal(toolchain.reactPlugin, '0.18.3');

const generatedRoot = join(fixtureRoot, 'generated');
mkdirSync(generatedRoot, { recursive: true });
const payload = makePayload(fixtureSpec.largePayloadLength);
const largeChecksum = sparseChecksum(payload);
writeFileSync(join(generatedRoot, 'payload.ts'), `import 'background-only';\nexport const payload = ${JSON.stringify(payload)};\nexport const expectedLength = ${payload.length};\nexport const expectedChecksum = ${largeChecksum};\nexport const sparseStride = ${fixtureSpec.sparseStride};\n`);
for (let index = 1; index <= fixtureSpec.asyncModuleCount; index += 1) {
  const number = String(index).padStart(2, '0');
  writeFileSync(join(generatedRoot, `module-${number}.ts`), `import 'background-only';\nexport function calculate(seed: number): number {\n  'background only';\n  return ${index * 1009} + seed * ${index};\n}\n`);
}
writeFileSync(join(generatedRoot, 'modules.ts'), `import 'background-only';\n${Array.from({ length: 10 }, (_, index) => `import { calculate as calculate${index + 1} } from './module-${String(index + 1).padStart(2, '0')}.js';`).join('\n')}\nexport const moduleCount = 10;\nexport const expectedChecksum = ${asyncChecksum()};\nexport function executeModules(seed: number): number[] {\n  'background only';\n  return [${Array.from({ length: 10 }, (_, index) => `calculate${index + 1}(seed)`).join(', ')}];\n}\n`);

const buildRoot = `${outputRoot}-build`;
mkdirSync(outputRoot, { recursive: true });
assert.equal(readdirSync(outputRoot).length, 0, '输出目录须为空，避免覆盖已有实验归档');
const metadata = { schemaVersion: fixtureSpec.schemaVersion, marker: fixtureSpec.marker,
  seed: fixtureSpec.seed, sparseStride: fixtureSpec.sparseStride, toolchain, assetPrefix, cases: [] };

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

for (const [caseName, entryName, entryFile] of [
  ['small', 'BundleLoadSmall', 'Small'], ['large', 'BundleLoadLarge', 'Large'], ['async', 'BundleLoadAsync', 'Async'],
]) {
  const caseOutput = join(buildRoot, caseName);
  let chunkGraph;
  const config = defineConfig({
    mode: 'production',
    source: { entry: { [entryName]: join(fixtureRoot, `src/${entryFile}.tsx`) },
      define: { 'process.env.NODE_ENV': JSON.stringify('production') } },
    output: { inlineScripts: caseName !== 'async', filename: { bundle: '[name].[platform].bundle' },
      sourceMap: false, assetPrefix, cleanDistPath: true, distPath: { root: caseOutput } },
    environments: { lynx: {} },
    tools: { rspack(config) {
      config.optimization ??= {};
      if (caseName === 'async') {
        config.optimization.splitChunks = {
          chunks: (chunk) => !chunk.name?.includes('__main-thread'), minSize: 0,
          cacheGroups: { default: false, defaultVendors: false,
            ...Object.fromEntries(Array.from({ length: 10 }, (_, index) => {
              const number = String(index + 1).padStart(2, '0');
              return [`module${number}`, { test: new RegExp(`[\\\\/]module-${number}\\.ts$`),
                name: `bench-module-${number}`, enforce: true, priority: 100 }];
            })),
          },
        };
      } else {
        config.optimization.splitChunks = false;
      }
      config.plugins ??= [];
      config.plugins.push({ apply(compiler) {
        compiler.hooks.done.tap('BundleFixtureGraph', (stats) => {
          chunkGraph = stats.toJson({ all: false, chunks: true, chunkModules: true, ids: true });
        });
      } });
      return config;
    } },
    plugins: [pluginReactLynx({ enableNewGesture: true, engineVersion: '4.1' })],
  });
  const rspeedy = await createRspeedy({ cwd: fixtureRoot, rspeedyConfig: config, loadEnv: false, environment: ['lynx'] });
  await rspeedy.build();
  const bundlePath = `${entryName}.lynx.bundle`;
  const available = listFiles(caseOutput);
  assert(available.includes(bundlePath), `${bundlePath} 缺失`);
  const externalScripts = caseName === 'async'
    ? available.filter((name) => name.endsWith('.js') && !name.endsWith('/main-thread.js')) : [];
  const copyPaths = [bundlePath, ...externalScripts];
  for (const path of copyPaths) {
    mkdirSync(dirname(join(outputRoot, path)), { recursive: true });
    cpSync(join(caseOutput, path), join(outputRoot, path));
  }
  const item = { caseName, path: bundlePath, ...identity(join(outputRoot, bundlePath)), inlineScripts: caseName !== 'async',
    expectedReadyPayload: { caseName, moduleCount: caseName === 'async' ? 10 : 0,
      payloadLength: caseName === 'large' ? payload.length : 0,
      checksum: caseName === 'large' ? largeChecksum : caseName === 'async' ? asyncChecksum() : 0 },
    asyncResources: externalScripts.sort().map((path) => ({ ownerBundlePath: bundlePath,
      requestKey: `/${path}`, path, url: new URL(path, assetPrefix).href,
      requestAliases: [new URL(path, assetPrefix).href, new URL(path, assetPrefix).pathname],
      ...identity(join(outputRoot, path)), kind: 'script' })),
    emittedChunks: (chunkGraph?.chunks ?? []).map((chunk) => ({ names: chunk.names, files: chunk.files })),
  };
  item.expectedReadyLabel = readyLabel(item.expectedReadyPayload);
  item.runtimePreflight = inspectRuntimeScripts(join(outputRoot, bundlePath),
    externalScripts.sort().map((path) => join(outputRoot, path)), dependencyRoot);
  metadata.cases.push(item);
  console.log(JSON.stringify({ caseName, size: item.size, externalScripts: externalScripts.length }));
}
writeFileSync(join(outputRoot, 'fixture-metadata.json'), `${JSON.stringify(metadata, null, 2)}\n`);
verifyFixtures(outputRoot);
console.log(JSON.stringify({ status: 'PASS', outputDirectory: outputRoot,
  metadataPath: join(outputRoot, 'fixture-metadata.json') }));
