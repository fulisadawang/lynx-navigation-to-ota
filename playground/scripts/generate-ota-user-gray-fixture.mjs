#!/usr/bin/env node
import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const PLAYGROUND = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const OWNED_ROOT = path.resolve(PLAYGROUND, '../scripts/ota-user-gray')
export const DEFAULT_FIXTURE = path.join(OWNED_ROOT, '.generated/fixture')
const DEFAULT_BASE = path.join(PLAYGROUND, 'fixtures/ota-store-v3-golden-100-v1-v2')
export const ALIASES = ['full5', 'gray6', 'full7', 'gray8']
export const BUNDLE_NAME = 'pages/10000001/bundle-050.lynx.bundle'
const digest = (bytes) => `sha256:${crypto.createHash('sha256').update(bytes).digest('hex')}`

function writeJson(file, value) {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`)
}

export function loadUserGrayFixture(directory = DEFAULT_FIXTURE) {
  const root = path.resolve(directory)
  const metadata = JSON.parse(fs.readFileSync(path.join(root, 'fixture.json'), 'utf8'))
  assert.equal(metadata.fixtureId, 'ota-user-gray-real-server-100')
  const objects = new Map()
  for (const alias of ALIASES) {
    const bundles = metadata.versions[alias]?.bundles
    assert.equal(bundles?.length, 100, `${alias} 必须是完整 100 Bundle 快照`)
    assert.equal(new Set(bundles.map((bundle) => bundle.bundlePath)).size, 100)
    for (let index = 0; index < 100; index++) {
      const bundle = bundles[index]
      assert.equal(bundle.bundlePath, `pages/10000001/bundle-${String(index).padStart(3, '0')}.lynx.bundle`)
      assert.match(bundle.bundleSha256, /^sha256:[a-f0-9]{64}$/)
      const file = path.join(root, 'objects', `${bundle.bundleSha256.slice(7)}.lynx.bundle`)
      if (!objects.has(bundle.bundleSha256)) objects.set(bundle.bundleSha256, fs.readFileSync(file))
      const bytes = objects.get(bundle.bundleSha256)
      assert.equal(bytes.length, bundle.size, `${alias}/${index} size`)
      assert.equal(digest(bytes), bundle.bundleSha256, `${alias}/${index} SHA`)
    }
  }
  for (let version = 1; version < ALIASES.length; version++) {
    const before = metadata.versions[ALIASES[version - 1]].bundles
    const after = metadata.versions[ALIASES[version]].bundles
    const changed = after.filter((bundle, index) => bundle.bundleSha256 !== before[index].bundleSha256)
    assert.deepEqual(changed.map((bundle) => bundle.bundlePath), [BUNDLE_NAME])
  }
  assert.equal(objects.size, 103, '99 个共享对象和 4 个不同的 050 对象')
  return { root, metadata, objects }
}

export function generateUserGrayFixture({ output = DEFAULT_FIXTURE, baseFixture = DEFAULT_BASE } = {}) {
  output = path.resolve(output)
  if (fs.existsSync(output)) throw new Error('输出目录已存在；请使用新的 --output，已有产物可直接复用')
  const baseManifest = JSON.parse(fs.readFileSync(path.join(baseFixture, 'manifests/ios/V1.json'), 'utf8'))
  assert.equal(baseManifest.bundles.length, 100, '需要现有真实编译的 100 Bundle V1 fixture')
  const base = baseManifest.bundles.map((bundle, index) => {
    assert.equal(bundle.bundlePath, `pages/10000001/bundle-${String(index).padStart(3, '0')}.lynx.bundle`)
    const bytes = fs.readFileSync(path.join(baseFixture, 'V1/bundles', bundle.bundlePath))
    assert.equal(digest(bytes), bundle.bundleSha256, '复用前校验基础 Bundle SHA')
    assert.equal(bytes.length, bundle.size)
    return { bundle, bytes }
  })

  fs.mkdirSync(path.join(OWNED_ROOT, '.generated'), { recursive: true })
  const build = fs.mkdtempSync(path.join(OWNED_ROOT, '.generated/build-'))
  fs.symlinkSync(path.join(PLAYGROUND, 'node_modules'), path.join(build, 'node_modules'), 'dir')
  fs.copyFileSync(path.join(PLAYGROUND, 'package.json'), path.join(build, 'package.json'))
  fs.copyFileSync(path.join(PLAYGROUND, 'tsconfig.json'), path.join(build, 'tsconfig.json'))
  const entry = {}
  for (const alias of ALIASES) {
    entry[alias] = path.join(build, `${alias}.tsx`)
    fs.writeFileSync(entry[alias], `import { root } from '@lynx-js/react'\n
function FixturePage() {
  return <view style={{ width: '100%', height: '100%', backgroundColor: '${alias.startsWith('gray') ? '#fff1dc' : '#eaf6ee'}', padding: '24px' }}>
    <text style={{ fontSize: '22px', color: '#172b24' }}>OTA User Gray Fixture</text>
    <text style={{ fontSize: '40px', color: '#172b24' }}>${alias.toUpperCase()}</text>
    <text style={{ fontSize: '26px', color: '#172b24' }}>Page 050</text>
    <text style={{ fontSize: '20px', color: '#172b24' }}>Marker: ${alias.toUpperCase()}-050</text>
    <text style={{ fontSize: '16px', color: '#172b24' }}>App 10000001 / 100 bundles</text>
  </view>
}
root.render(<FixturePage />)\n`)
  }
  const config = path.join(build, 'lynx.config.mjs')
  fs.writeFileSync(config, `import { defineConfig } from '@lynx-js/rspeedy'
import { pluginReactLynx } from '@lynx-js/react-rsbuild-plugin'
export default defineConfig({
  source: { entry: ${JSON.stringify(entry)} },
  output: { distPath: { root: ${JSON.stringify(path.join(build, 'dist'))} }, assetPrefix: 'asset:///bundles/', filename: { bundle: '[name].lynx.bundle' } },
  plugins: [pluginReactLynx()],
})\n`)
  // 独立配置只编译四个 050 页面，不加载常规 Playground 的资源同步插件。
  const result = spawnSync('pnpm', ['exec', 'rspeedy', 'build', '--mode', 'production', '--config', config, '--root', PLAYGROUND], {
    cwd: PLAYGROUND, stdio: 'inherit', env: process.env,
  })
  if (result.error) throw result.error
  if (result.status !== 0) throw new Error(`四个标记页编译失败，exit=${result.status}`)

  fs.mkdirSync(path.join(output, 'objects'), { recursive: true })
  const objects = new Map()
  const versions = {}
  for (const alias of ALIASES) {
    const changed = fs.readFileSync(path.join(build, 'dist', `${alias}.lynx.bundle`))
    const bundles = base.map(({ bundle, bytes: original }, index) => {
      const bytes = index === 50 ? changed : original
      const sha = digest(bytes)
      if (!objects.has(sha)) {
        fs.writeFileSync(path.join(output, 'objects', `${sha.slice(7)}.lynx.bundle`), bytes)
        objects.set(sha, bytes.length)
      }
      return {
        pageId: bundle.pageId, bundlePath: bundle.bundlePath, bundleSha256: sha, size: bytes.length,
        required: true, prefetch: false,
      }
    })
    versions[alias] = { visibleMarker: `${alias.toUpperCase()}-050`, bundles }
  }
  const metadata = {
    fixtureId: 'ota-user-gray-real-server-100', schemaVersion: 1, env: 'TEST', hostApp: 'capp', lynxAppId: '10000001',
    bundleCount: 100, bundleName: BUNDLE_NAME, versions,
    buildEvidence: {
      baseFixture: path.resolve(baseFixture), reusedBundleCount: 99, compiledMarkerCount: 4,
      buildDirectory: build, uniqueObjects: objects.size, uniqueObjectBytes: [...objects.values()].reduce((sum, size) => sum + size, 0),
      compiler: '@lynx-js/rspeedy', base: 'V1',
    },
  }
  writeJson(path.join(output, 'fixture.json'), metadata)
  loadUserGrayFixture(output)
  console.log(JSON.stringify({ fixture: output, ...metadata.buildEvidence, bundleName: BUNDLE_NAME }, null, 2))
  return output
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = {}
    for (let index = 2; index < process.argv.length; index++) {
      const flag = process.argv[index]
      if (flag === '--output' || flag === '--base-fixture') {
        if (!process.argv[index + 1]) throw new Error(`缺少 ${flag} 参数`)
        args[flag === '--output' ? 'output' : 'baseFixture'] = path.resolve(process.argv[++index])
      } else if (flag === '--verify') args.verify = true
      else if (flag === '--help') {
        console.log('node playground/scripts/generate-ota-user-gray-fixture.mjs [--output DIR] [--base-fixture DIR] [--verify]')
        process.exit(0)
      } else throw new Error(`未知参数：${flag}`)
    }
    if (args.verify) {
      const fixture = loadUserGrayFixture(args.output)
      console.log(JSON.stringify({ verified: true, fixture: fixture.root, uniqueObjects: fixture.objects.size, bundleCount: 100 }))
    } else generateUserGrayFixture(args)
  } catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}
