import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import { checkManifest, resolveEvent } from './cli.mjs'

// 自测只在临时目录创建最小归档，不读取或修改仓库里的业务 Bundle。
function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex')
}

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lynx-monitor-artifacts-'))
const entryRoot = path.join(root, 'entries', 'main')
fs.mkdirSync(entryRoot, { recursive: true })
const bundle = Buffer.from('selftest bundle')
const metadata = {
  artifacts: [
    {
      kind: 'background',
      filename: 'background.js',
      path: 'background.js',
      debugSources: [{
        kind: 'source-map',
        filename: 'background.js.map',
        path: 'background.js.map',
        key: 'selftest-key',
        map: {
          version: 3,
          file: 'background.js',
          sources: ['src/known.ts'],
          sourcesContent: ['throw new Error("selftest")'],
          names: [],
          mappings: 'AAAA',
        },
      }],
    },
    {
      kind: 'main-thread',
      filename: 'main-thread.js',
      path: 'main-thread.js',
      debugSources: [
        {
          kind: 'bytecode-debug-info',
          debugInfo: {
            lepusNG_debug_info: {
              function_info: [{
                function_id: 7,
                function_name: 'selftest',
                file_name: 'main-thread.js',
                line_number: 1,
                column_number: 0,
                pc2line_len: 1,
                pc2line_buf: [0],
                line_col: [{ line: 1, column: 0 }],
                pc2caller_info: {},
              }],
            },
          },
        },
        {
          kind: 'source-map',
          filename: 'main-thread.js.map',
          path: 'main-thread.js.map',
          key: 'selftest-main-key',
          map: {
            version: 3,
            file: 'main-thread.js',
            sources: ['src/main.ts'],
            sourcesContent: ['throw new Error("main selftest")'],
            names: [],
            mappings: 'AAAA',
          },
        },
      ],
    },
  ],
  uiSourceMap: { version: 1, sources: [], mappings: [], uiMaps: [] },
  buildInfo: { rspeedy: { entryFiles: ['src/main.tsx'], bundlePath: 'main/template.js' } },
}
const bundlePath = path.join(entryRoot, 'bundle.lynx.bundle')
const metadataPath = path.join(entryRoot, 'debug-metadata.json')
fs.writeFileSync(bundlePath, bundle)
fs.writeFileSync(metadataPath, JSON.stringify(metadata, null, 2) + '\n')
const manifest = {
  schemaVersion: '1.0',
  buildId: 'selftest-build',
  createdAt: new Date().toISOString(),
  source: { gitCommit: null, dirty: true, lockfileSha256: 'a'.repeat(64), sourceContext: 'sources_content' },
  toolchain: { engineTarget: '4.1.0', rspeedy: '0.17.0', reactLynx: '0.126.0', reactPlugin: '0.20.0', debugMetadataPlugin: '0.2.3' },
  entries: [{
    entryId: 'main',
    bundleName: 'main.lynx.bundle',
    lynxAppId: null,
    targetPlatforms: ['android', 'ios', 'harmony'],
    bundle: { path: 'entries/main/bundle.lynx.bundle', sha256: sha256(bundle), sizeBytes: bundle.length },
    debugMetadata: { path: 'entries/main/debug-metadata.json', sha256: sha256(fs.readFileSync(metadataPath)), sizeBytes: fs.statSync(metadataPath).size },
    scripts: [{
      artifactName: 'background.js',
      artifactKind: 'background',
      sourceMapKey: 'selftest-key',
      runtimeRelease: 'debugmetadata:selftest-key',
      sourceMapName: 'background.js.map',
      hasBytecodeDebugInfo: false,
    }, {
      artifactName: 'main-thread.js',
      artifactKind: 'main-thread',
      sourceMapKey: 'selftest-main-key',
      runtimeRelease: 'debugmetadata:selftest-main-key',
      sourceMapName: 'main-thread.js.map',
      hasBytecodeDebugInfo: true,
    }],
  }],
}
const manifestPath = path.join(root, 'manifest.json')
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n')
assert.equal(checkManifest(manifestPath).ok, true)

const eventPath = path.join(root, 'event.json')
const event = {
  eventId: '11111111-1111-4111-8111-111111111111',
  bundle: { sha256: manifest.entries[0].bundle.sha256 },
  payload: {
    frames: [{
      file: 'file:///background.js',
      runtimeRelease: 'debugmetadata:selftest-key',
      debugKey: 'selftest-key',
      positionKind: 'line_column',
      line: 1,
      column: 0,
    }, {
      file: 'file:///main-thread.js',
      runtimeRelease: 'debugmetadata:selftest-main-key',
      debugKey: 'selftest-main-key',
      positionKind: 'function_pc',
      functionId: 7,
      pc: 1,
    }],
  },
}
fs.writeFileSync(eventPath, JSON.stringify(event, null, 2) + '\n')
const resolved = resolveEvent(eventPath, manifestPath)
assert.equal(resolved.frames[0].status, 'mapped')
assert.deepEqual(resolved.frames[0].source, { file: 'src/known.ts', line: 1, column: 0 })
assert.equal(resolved.frames[1].status, 'mapped')
assert.deepEqual(resolved.frames[1].source, { file: 'src/main.ts', line: 1, column: 0 })

event.bundle.sha256 = 'b'.repeat(64)
fs.writeFileSync(eventPath, JSON.stringify(event, null, 2) + '\n')
const mismatch = resolveEvent(eventPath, manifestPath)
assert.equal(mismatch.frames[0].reason, 'identity_mismatch')
assert.equal(mismatch.frames[1].reason, 'identity_mismatch')

console.log('lynx-monitor-artifacts selftest 通过')
