import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { fixtureSpec } from './spec.mjs';

export function inspectRuntimeScripts(bundlePath, externalPaths, dependencyRoot = fixtureSpec.defaultDependencies) {
  const require = createRequire(realpathSync(join(dependencyRoot, '@lynx-js/react-rsbuild-plugin/dist/index.js')));
  const { parse } = require('acorn');
  const { analyze } = require('eslint-scope');
  const { decode_napi } = require('@lynx-js/tasm');
  const decoded = decode_napi(readFileSync(bundlePath));
  const inline = decoded['background-thread-script'];
  assert(Array.isArray(inline) && inline.length > 0, 'Bundle 须包含真实背景脚本');
  const scripts = [
    ...inline.filter((entry) => entry.type === 'source').map((entry) => ({ path: entry.path, source: entry.content, inline: true })),
    ...externalPaths.map((path) => ({ path, source: readFileSync(path, 'utf8'), inline: false })),
  ];
  assert(scripts.some((script) => script.inline), '须解析真实内联背景源码');
  for (const script of scripts) {
    const ast = parse(script.source, { ecmaVersion: 'latest', sourceType: 'script', ranges: true, locations: true });
    const scopes = analyze(ast, { ecmaVersion: 2022, sourceType: 'script' });
    // 只检查没有本地声明的可执行标识符，排除字串、注释和同名属性。
    const references = scopes.globalScope.through.filter((reference) => reference.identifier.name === 'process');
    assert.equal(references.length, 0, `${script.path} 存在未替换 process，位置 ${references.map((reference) => `${reference.identifier.loc.start.line}:${reference.identifier.loc.start.column}`).join(',')}`);
  }
  return {
    freeProcessReferences: 0,
    inlineScriptsChecked: scripts.filter((script) => script.inline).length,
    externalScriptsChecked: scripts.filter((script) => !script.inline).length,
    parser: `acorn@${require('acorn/package.json').version}`,
    scopeAnalyzer: `eslint-scope@${require('eslint-scope/package.json').version}`,
    scripts: scripts.map((script) => ({ inline: script.inline,
      size: Buffer.byteLength(script.source), sha256: createHash('sha256').update(script.source).digest('hex') })),
  };
}
