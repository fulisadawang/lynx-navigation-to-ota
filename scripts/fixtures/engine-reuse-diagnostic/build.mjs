import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, readdirSync, realpathSync, symlinkSync, existsSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { inspectRuntimeScripts } from '../engine-reuse/runtime-preflight.mjs';

const root = dirname(fileURLToPath(import.meta.url));
const dependencies = realpathSync('/Users/nieyutan/Documents/hbc-git/codex/LynxWorkspace/repos/LynxAppPackagesAndTemplates/templates/lynx-template/node_modules');
const out = resolve(process.argv[2] ?? '/tmp/codex-engine-reuse-20261010/engine-lifecycle-diagnostic/fixture-out');
assert(!out.startsWith(root) && !out.startsWith(dependencies), '产物不得覆盖源码或依赖');
mkdirSync(out, { recursive: true });
assert.equal(readdirSync(out).length, 0, '输出目录必须为空');
if (!existsSync(join(root, 'node_modules'))) symlinkSync(dependencies, join(root, 'node_modules'), 'dir');
process.env.NODE_ENV = 'production';
const { createRspeedy, defineConfig } = await import(pathToFileURL(join(dependencies, '@lynx-js/rspeedy/dist/index.js')).href);
const { pluginReactLynx } = await import(pathToFileURL(join(dependencies, '@lynx-js/react-rsbuild-plugin/dist/index.js')).href);
const version = (name) => JSON.parse(readFileSync(join(dependencies, name, 'package.json'), 'utf8')).version;
assert.equal(version('@lynx-js/react'), '0.123.3');
assert.equal(version('@lynx-js/react-rsbuild-plugin'), '0.18.3');
assert.equal(version('@lynx-js/rspeedy'), '0.16.3');
const name = 'EngineReuseLifecycleProbe';
let entryRecord;
const config = defineConfig({ mode: 'production', environments: { lynx: {} },
  source: { entry: { [name]: join(root, 'src/Probe.tsx') }, define: { 'process.env.NODE_ENV': JSON.stringify('production') } },
  output: { inlineScripts: true, sourceMap: false, filename: { bundle: '[name].[platform].bundle' },
    cleanDistPath: true, distPath: { root: out } },
  plugins: [pluginReactLynx({ enableNewGesture: true, engineVersion: '4.1' })],
  tools: { rspack(value) {
    const main = value.entry[`${name}__main-thread`];
    assert.equal(main.layer, 'react:main-thread');
    const original = Array.isArray(main.import) ? [...main.import] : [main.import];
    main.import = [...original, join(root, 'src/main-thread-observer.js')];
    entryRecord = { name: `${name}__main-thread`, layer: main.layer, originalImports: original, finalImports: main.import };
    value.optimization.splitChunks = false;
    return value;
  } },
});
const rspeedy = await createRspeedy({ cwd: root, rspeedyConfig: config, loadEnv: false, environment: ['lynx'] });
await rspeedy.build();
const bundle = join(out, `${name}.lynx.bundle`);
const bytes = readFileSync(bundle);
assert(bytes.includes(Buffer.from('ENGINE_REUSE_DIAG_V1')), '真实Bundle缺诊断marker');
const require = createRequire(realpathSync(join(dependencies, '@lynx-js/react-rsbuild-plugin/dist/index.js')));
const decoded = require('@lynx-js/tasm').decode_napi(bytes);
const mainBytecode = Buffer.from(decoded['main-thread-script'].lepus_code);
for (const marker of ['observer.installed', 'hook.unavailable', 'MTS-', 'engineReuseDiagnosticRead']) {
  assert(mainBytecode.includes(Buffer.from(marker)), `真实MTS bytecode缺${marker}`);
}
const metadata = { schemaVersion: 1, fixture: 'ENGINE_REUSE_DIAGNOSTIC_V1',
  toolchain: { reactLynx: version('@lynx-js/react'), reactPlugin: version('@lynx-js/react-rsbuild-plugin'), rspeedy: version('@lynx-js/rspeedy'), engineVersion: '4.1' },
  bundle: { path: `${name}.lynx.bundle`, size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') },
  mainEntry: entryRecord, runtimePreflight: inspectRuntimeScripts(bundle, dependencies, []),
  mainObserverInjection: 'actualMainThreadEntryAppend', mainObserverVerifiedInBytecode: true,
  frozenAcceptanceFixture: false };
writeFileSync(join(out, 'fixture-metadata.json'), JSON.stringify(metadata, null, 2));
console.log(JSON.stringify({ out, bundle: metadata.bundle, runtimePreflight: metadata.runtimePreflight }));
