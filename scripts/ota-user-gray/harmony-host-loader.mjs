import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { createNodeAdapters } from './harmony-host-adapters.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const DEFAULT_ETS_ROOT = path.join(ROOT, 'harmony/lynx_shell_kit/src/main/ets');

function typescriptModule(explicit) {
  if (explicit) return createRequire(import.meta.url)(path.resolve(explicit));
  for (const file of [path.join(ROOT, 'playground/package.json'), '/Applications/DevEco-Studio.app/Contents/tools/hvigor/package.json']) {
    try { return createRequire(file)('typescript'); } catch { /* 尝试已有工具模块；不安装生产依赖。 */ }
  }
  throw new Error('找不到已有 TypeScript；使用 --typescript 指定本机模块路径');
}

export function createArkTsHost({ directory, sourceRoot = DEFAULT_ETS_ROOT, typescript, allowedOrigins = [], rawResources, mocks = {} }) {
  const adapters = createNodeAdapters(directory, { allowedOrigins, rawResources });
  const ts = typescriptModule(typescript);
  const root = fs.realpathSync(sourceRoot);
  const modules = new Map();
  const sources = new Map();
  const systemModules = { ...adapters.modules, ...mocks };
  const logs = [];
  const context = vm.createContext({
    console: Object.fromEntries(['info', 'warn', 'error', 'log'].map((level) => [level, (...values) => {
      const text = values.map(String).join(' ').replace(/(token=)[^,\s]+/gi, '$1[REDACTED]');
      logs.push({ level, text });
    }])),
    setTimeout, clearTimeout, queueMicrotask, URL, TextEncoder, TextDecoder,
    ArrayBuffer, Uint8Array, Uint16Array, Uint32Array, Int8Array, Int32Array,
  });

  function sourceFile(value) {
    let file = path.resolve(root, value);
    if (!path.extname(file)) file += '.ets';
    if (!file.startsWith(`${root}${path.sep}`) || !file.endsWith('.ets') || fs.lstatSync(file).isSymbolicLink()) throw new Error('host_source_outside_explicit_ets_root');
    return file;
  }

  function load(value) {
    const file = sourceFile(value);
    if (modules.has(file)) return modules.get(file).exports;
    const source = fs.readFileSync(file, 'utf8');
    if (/\b(?:export\s+)?struct\s+\w+/.test(source)) throw new Error('ArkUI struct 不属于 Node host 执行范围');
    const compiled = ts.transpileModule(source, { fileName: file.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS, esModuleInterop: true, experimentalDecorators: true } });
    const errors = (compiled.diagnostics ?? []).filter((item) => item.category === ts.DiagnosticCategory.Error);
    if (errors.length) throw new Error(errors.map((item) => ts.flattenDiagnosticMessageText(item.messageText, '\n')).join('\n'));
    sources.set(file, { file, sha256: crypto.createHash('sha256').update(source).digest('hex'), emittedSha256: crypto.createHash('sha256').update(compiled.outputText).digest('hex') });
    const module = { exports: {} };
    modules.set(file, module);
    const require = (specifier) => {
      if (Object.hasOwn(systemModules, specifier)) return systemModules[specifier];
      if (specifier.startsWith('.')) return load(path.resolve(path.dirname(file), specifier));
      throw new Error(`未显式适配的宿主模块：${specifier}`);
    };
    try {
      const wrapper = new vm.Script(`(function(require,module,exports,__filename,__dirname){\n${compiled.outputText}\n})`, { filename: file });
      wrapper.runInContext(context, { timeout: 10000 })(require, module, module.exports, file, path.dirname(file));
      return module.exports;
    } catch (error) { modules.delete(file); throw error; }
  }

  return {
    ...adapters, load, logs,
    evidence() {
      return { ...adapters.metadata, typescriptVersion: ts.version, sourceRoot: root, sources: [...sources.values()],
        sourceChangedAfterLoad: [...sources.values()].filter((item) => crypto.createHash('sha256').update(fs.readFileSync(item.file)).digest('hex') !== item.sha256).map((item) => item.file),
        suppliedMocks: Object.keys(mocks), io: JSON.parse(JSON.stringify(adapters.audit)) };
    },
  };
}
