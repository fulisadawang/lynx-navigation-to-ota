import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, symlinkSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { inspectRuntimeScripts } from '../engine-reuse/runtime-preflight.mjs';

const root = dirname(fileURLToPath(import.meta.url));
const dependencyRoot = realpathSync('/Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxAppPackagesAndTemplates/templates/lynx-template/node_modules');
const output = resolve(process.argv[2] ?? '/tmp/codex-engine-reuse-20261010/engine-static/fixture-out');
assert(!output.startsWith(root) && !output.startsWith(dependencyRoot), '产物不得覆盖源码或借用依赖');
mkdirSync(output, { recursive: true });
assert.equal(readdirSync(output).length, 0, '输出目录必须为空，避免覆盖已有证据');

const link = join(root, 'node_modules');
if (existsSync(link)) {
  assert(lstatSync(link).isSymbolicLink(), '不覆盖真实node_modules');
  assert.equal(realpathSync(link), dependencyRoot, 'node_modules必须指向固定模板依赖');
} else {
  symlinkSync(dependencyRoot, link, 'dir');
}

const source = readFileSync(join(root, 'src/StaticProbe.tsx'), 'utf8');
for (const forbidden of ['useEffect', 'useState', 'NativeModules', 'getShellModule', 'setTimeout', 'setInterval']) {
  assert(!source.includes(forbidden), `静态Fixture源码禁止 ${forbidden}`);
}
assert(source.includes('useInitData') && source.includes('useGlobalProps') && source.includes('root.render'),
  '静态Fixture必须读取新的init/global参数并真实渲染');

process.env.NODE_ENV = 'production';
const { createRspeedy, defineConfig } = await import(pathToFileURL(join(dependencyRoot, '@lynx-js/rspeedy/dist/index.js')).href);
const { pluginReactLynx } = await import(pathToFileURL(join(dependencyRoot, '@lynx-js/react-rsbuild-plugin/dist/index.js')).href);
const versionOf = (name) => JSON.parse(readFileSync(join(dependencyRoot, name, 'package.json'), 'utf8')).version;
const toolchain = {
  reactLynx: versionOf('@lynx-js/react'),
  reactPlugin: versionOf('@lynx-js/react-rsbuild-plugin'),
  rspeedy: versionOf('@lynx-js/rspeedy'),
  engineVersion: '4.1',
  mode: 'production',
};
assert.equal(toolchain.reactLynx, '0.123.3');
assert.equal(toolchain.reactPlugin, '0.18.3');
assert.equal(toolchain.rspeedy, '0.16.3');

const name = 'EngineReuseStaticProbe';
const config = defineConfig({
  mode: 'production',
  environments: { lynx: {} },
  source: {
    entry: { [name]: join(root, 'src/StaticProbe.tsx') },
    define: { 'process.env.NODE_ENV': JSON.stringify('production') },
  },
  output: {
    inlineScripts: true,
    sourceMap: false,
    filename: { bundle: '[name].[platform].bundle' },
    cleanDistPath: true,
    distPath: { root: output },
  },
  tools: { rspack(value) { value.optimization ??= {}; value.optimization.splitChunks = false; return value; } },
  plugins: [pluginReactLynx({ enableNewGesture: true, engineVersion: '4.1' })],
});
const rspeedy = await createRspeedy({ cwd: root, rspeedyConfig: config, loadEnv: false, environment: ['lynx'] });
await rspeedy.build();

const bundleName = `${name}.lynx.bundle`;
const bundle = join(output, bundleName);
const bytes = readFileSync(bundle);
const require = createRequire(realpathSync(join(dependencyRoot, '@lynx-js/react-rsbuild-plugin/dist/index.js')));
const decoded = require('@lynx-js/tasm').decode_napi(bytes);
assert.equal(decoded['engine-version'], '4.1');
assert(Array.isArray(decoded['background-thread-script']), 'Bundle必须有真实背景线程脚本');
const metadata = {
  schemaVersion: 1,
  fixture: 'ENGINE_REUSE_STATIC_V1',
  toolchain,
  bundle: { path: bundleName, size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') },
  hostInputContract: { initData: ['marker'], globalProps: ['marker', 'probePageId'] },
  staticSourceChecks: { noEffects: true, noState: true, noNative: true, noTimers: true },
  runtimePreflight: inspectRuntimeScripts(bundle, dependencyRoot, []),
};
writeFileSync(join(output, 'fixture-metadata.json'), `${JSON.stringify(metadata, null, 2)}\n`);
console.log(JSON.stringify({ status: 'PASS', output, metadata }));
