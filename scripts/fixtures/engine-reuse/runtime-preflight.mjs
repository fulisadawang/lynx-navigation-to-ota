import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';

export function inspectRuntimeScripts(bundlePath, dependencyRoot, emittedScriptPaths = []) {
  const require = createRequire(realpathSync(join(dependencyRoot, '@lynx-js/react-rsbuild-plugin/dist/index.js')));
  const { parse } = require('acorn');
  const { analyze } = require('eslint-scope');
  const decoded = require('@lynx-js/tasm').decode_napi(readFileSync(bundlePath));
  assert.equal(decoded['engine-version'], '4.1');
  const background = decoded['background-thread-script'];
  const lazyBackground = decoded['custom-sections']?.background;
  assert(Array.isArray(background), '背景线程字段须可解码');
  const scripts = [
    ...background.filter((entry) => entry.type === 'source').map((entry) => ({ path: entry.path, source: entry.content, inline: true })),
    ...(typeof lazyBackground === 'string' ? [{ path: 'custom-sections/background', source: lazyBackground, inline: true }] : []),
    ...emittedScriptPaths.map((path) => ({ path, source: readFileSync(path, 'utf8'), inline: false })),
  ];
  assert(scripts.some((script) => script.inline), '须检查真实Bundle内联背景源码');
  for (const script of scripts) {
    const ast = parse(script.source, { ecmaVersion: 'latest', sourceType: 'script', ranges: true, locations: true });
    const scopes = analyze(ast, { ecmaVersion: 2022, sourceType: 'script' });
    const processReferences = scopes.globalScope.through.filter((reference) => reference.identifier.name === 'process');
    assert.equal(processReferences.length, 0, `${script.path} 存在未替换自由 process 引用`);
  }
  return {
    engineVersion: decoded['engine-version'], freeProcessReferences: 0,
    inlineScriptsChecked: scripts.filter((script) => script.inline).length,
    emittedScriptsChecked: scripts.filter((script) => !script.inline).length,
    mainThreadEncoding: decoded['is-lepusng-binary'] ? 'bytecode' : 'source',
    customSections: Object.keys(decoded['custom-sections'] ?? {}),
    parser: `acorn@${require('acorn/package.json').version}`,
    scopeAnalyzer: `eslint-scope@${require('eslint-scope/package.json').version}`,
    scripts: scripts.map((script) => ({ inline: script.inline, size: Buffer.byteLength(script.source),
      sha256: createHash('sha256').update(script.source).digest('hex') })),
  };
}
