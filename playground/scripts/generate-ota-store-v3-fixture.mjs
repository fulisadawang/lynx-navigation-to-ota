#!/usr/bin/env node

import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url))
const PLAYGROUND_ROOT = path.resolve(SCRIPT_DIR, '..')
const DEFAULT_OUTPUT = path.join(PLAYGROUND_ROOT, 'fixtures', 'ota-store-v3-golden-100-v1-v2')
const APP_ID = '10000001'
const BUNDLE_COUNT = 100
const CHANGED_INDEX = 50
const DEFAULT_PUBLIC_BASE_URL = 'http://127.0.0.1:18765'
const VERSIONS = {
  V1: 'ota-v3-golden-v1-100',
  V2: 'ota-v3-golden-v2-100-one-change',
}

function parseArgs(argv) {
  const args = { output: DEFAULT_OUTPUT, publicBaseUrl: DEFAULT_PUBLIC_BASE_URL, force: false }
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index]
    if (value === '--output') args.output = path.resolve(argv[++index])
    else if (value === '--public-base-url') args.publicBaseUrl = argv[++index].replace(/\/$/, '')
    else if (value === '--force') args.force = true
    else if (value === '--help' || value === '-h') {
      console.log('用法: node scripts/generate-ota-store-v3-fixture.mjs [--output DIR] [--public-base-url URL] [--force]')
      process.exit(0)
    } else {
      throw new Error(`未知参数：${value}`)
    }
  }
  return args
}

function ensureEmptyOutput(output, force) {
  if (!fs.existsSync(output)) return
  if (!force) {
    throw new Error(`输出目录已存在，避免覆盖用户数据；如确认重建请增加 --force：${output}`)
  }
  fs.rmSync(output, { recursive: true, force: true })
}

function writeFixtureEntry(sourceDirectory, version, index) {
  const name = `bundle-${String(index).padStart(3, '0')}`
  const marker = `${version}-${String(index).padStart(3, '0')}`
  const source = `import { root } from '@lynx-js/react'\n\nfunction FixturePage() {\n  return (\n    <view>\n      <text>OTA Store v3 Golden Fixture</text>\n      <text>版本：${version}</text>\n      <text>Bundle：${String(index).padStart(3, '0')}</text>\n      <text>标识：${marker}</text>\n    </view>\n  )\n}\n\nroot.render(<FixturePage />)\n`
  const file = path.join(sourceDirectory, `${name}.tsx`)
  fs.writeFileSync(file, source)
  return { name, file }
}

function writeRspeedyConfig(directory, entries, outputDirectory) {
  const entryObject = Object.fromEntries(entries.map((entry) => [entry.name, entry.file]))
  const source = [
    "import { defineConfig } from '@lynx-js/rspeedy'",
    "import { pluginQRCode } from '@lynx-js/qrcode-rsbuild-plugin'",
    "import { pluginReactLynx } from '@lynx-js/react-rsbuild-plugin'",
    '',
    'export default defineConfig({',
    '  source: {',
    `    entry: ${JSON.stringify(entryObject, null, 2)},`,
    '  },',
    '  output: {',
    `    distPath: { root: ${JSON.stringify(outputDirectory)} },`,
    "    assetPrefix: 'asset:///bundles/',",
    "    filename: { bundle: '[name].lynx.bundle' },",
    '  },',
    '  plugins: [',
    '    pluginQRCode({',
    '      schema(url) {',
    '        return url',
    '      },',
    '    }),',
    '    pluginReactLynx(),',
    '  ],',
    '})',
    '',
  ].join('\n')
  const file = path.join(directory, 'lynx.config.mjs')
  fs.writeFileSync(file, source)
  return file
}

function runRspeedyBuild(configFile, outputDirectory) {
  const result = spawnSync(
    'pnpm',
    ['exec', 'rspeedy', 'build', '--mode', 'production', '--config', configFile, '--root', PLAYGROUND_ROOT],
    { cwd: PLAYGROUND_ROOT, stdio: 'inherit', env: process.env },
  )
  if (result.error) throw result.error
  if (result.status !== 0) throw new Error(`Rspeedy 构建失败，exit=${result.status}`)
  return outputDirectory
}

function sha256(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`
}

function canonicalJson(value) {
  return JSON.stringify(value, Object.keys(value).sort())
}

function manifestDigest(manifest) {
  const digestInput = { ...manifest }
  delete digestInput.manifestSha256
  return sha256Buffer(Buffer.from(JSON.stringify(digestInput)))
}

function sha256Buffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`
}

function copyBundle(source, destination) {
  fs.mkdirSync(path.dirname(destination), { recursive: true })
  fs.copyFileSync(source, destination)
}

function collectBundles(versionDirectory, publicBaseUrl, releaseId, platform) {
  const bundlesRoot = path.join(versionDirectory, 'bundles')
  const entries = []
  for (let index = 0; index < BUNDLE_COUNT; index += 1) {
    const bundleName = `bundle-${String(index).padStart(3, '0')}.lynx.bundle`
    const bundlePath = `pages/${APP_ID}/${bundleName}`
    const file = path.join(bundlesRoot, bundlePath)
    const bundleSha256 = sha256(file)
    entries.push({
      pageId: 10100000 + index,
      bundlePath,
      bundleName,
      bundleUrl: `${publicBaseUrl}/ota/bundles/${encodeURIComponent(releaseId)}/${bundlePath
        .split('/')
        .map((part) => encodeURIComponent(part))
        .join('/')}`,
      bundleSha256,
      objectId: bundleSha256,
      size: fs.statSync(file).size,
      required: true,
      prefetch: false,
      platform,
    })
  }
  return entries
}

function writeManifests(output, publicBaseUrl) {
  const platforms = ['ios', 'android', 'harmony']
  const manifestFiles = {}
  for (const platform of platforms) {
    manifestFiles[platform] = {}
    for (const [version, releaseId] of Object.entries(VERSIONS)) {
      const entries = collectBundles(path.join(output, version), publicBaseUrl, releaseId, platform)
      const manifest = {
        protocolVersion: 'ota-release/2',
        schemaVersion: 2,
        env: 'TEST',
        hostApp: 'capp',
        lynxAppId: APP_ID,
        releaseId,
        platform,
        platforms: [platform],
        status: 'ACTIVE',
        createdAt: version === 'V1' ? '2026-08-30T00:00:00.000Z' : '2026-08-30T00:01:00.000Z',
        manifestSha256: '',
        bundles: entries,
        changedBundles: entries,
      }
      manifest.manifestSha256 = manifestDigest(manifest)
      const file = path.join(output, 'manifests', platform, `${version}.json`)
      fs.mkdirSync(path.dirname(file), { recursive: true })
      fs.writeFileSync(file, `${JSON.stringify(manifest, null, 2)}\n`)
      manifestFiles[platform][version] = path.relative(output, file)
    }
  }
  return manifestFiles
}

function writeFixtureMetadata(output, manifestFiles) {
  const fixture = {
    fixtureId: 'ota-store-v3-golden-100-v1-v2',
    schemaVersion: 1,
    env: 'TEST',
    hostApp: 'capp',
    lynxAppId: APP_ID,
    bundleCount: BUNDLE_COUNT,
    changedBundlePath: `pages/${APP_ID}/bundle-${String(CHANGED_INDEX).padStart(3, '0')}.lynx.bundle`,
    versions: {
      V1: { releaseId: VERSIONS.V1, manifestFiles: manifestFiles },
      V2: { releaseId: VERSIONS.V2, manifestFiles: manifestFiles },
    },
    notes: [
      'V1 与 V2 都是完整 100 Bundle Manifest。',
      '只有 bundle-050 的 bytes/size/SHA 变化。',
      '本 fixture 生成的 Bundle 均来自 Playground 的 ReactLynx/Rspeedy 编译链。',
      'generatedAt 不写入 fixture，避免机器时间导致 SHA 漂移。',
    ],
  }
  fs.writeFileSync(path.join(output, 'fixture.json'), `${JSON.stringify(fixture, null, 2)}\n`)
}

function buildVersion(tempRoot, version, indexes) {
  const sourceDirectory = path.join(tempRoot, version, 'src')
  const outputDirectory = path.join(tempRoot, version, 'dist')
  fs.mkdirSync(sourceDirectory, { recursive: true })
  const entries = indexes.map((index) => writeFixtureEntry(sourceDirectory, version, index))
  const configFile = writeRspeedyConfig(path.join(tempRoot, version), entries, outputDirectory)
  const dist = runRspeedyBuild(configFile, outputDirectory)
  return { dist, entries }
}

function materializeBundles(output, v1Dist, v2Dist) {
  for (let index = 0; index < BUNDLE_COUNT; index += 1) {
    const name = `bundle-${String(index).padStart(3, '0')}.lynx.bundle`
    const bundlePath = `pages/${APP_ID}/${name}`
    copyBundle(
      path.join(v1Dist, name),
      path.join(output, 'V1', 'bundles', bundlePath),
    )
    const v2Source = index === CHANGED_INDEX
      ? path.join(v2Dist, 'bundle-050.lynx.bundle')
      : path.join(v1Dist, name)
    copyBundle(
      v2Source,
      path.join(output, 'V2', 'bundles', bundlePath),
    )
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2))
  if (!args.publicBaseUrl.startsWith('http://') && !args.publicBaseUrl.startsWith('https://')) {
    throw new Error('--public-base-url 必须是 http:// 或 https:// URL')
  }
  ensureEmptyOutput(args.output, args.force)
  // 临时目录放在 Playground 下，确保 Rspeedy 配置可以沿目录树解析本地 node_modules。
  const tempRoot = fs.mkdtempSync(path.join(PLAYGROUND_ROOT, '.ota-store-v3-build-'))
  try {
    // Rspeedy 会从项目根读取 package/TypeScript 工程元数据；复制配置不复制 node_modules，
    // 依赖仍沿 Playground 父目录解析，构建结束后整个临时目录会被删除。
    fs.copyFileSync(path.join(PLAYGROUND_ROOT, 'package.json'), path.join(tempRoot, 'package.json'))
    fs.copyFileSync(path.join(PLAYGROUND_ROOT, 'tsconfig.json'), path.join(tempRoot, 'tsconfig.json'))
    const v1 = buildVersion(tempRoot, 'V1', Array.from({ length: BUNDLE_COUNT }, (_, index) => index))
    const v2 = buildVersion(tempRoot, 'V2', [CHANGED_INDEX])
    materializeBundles(args.output, v1.dist, v2.dist)
    const manifests = writeManifests(args.output, args.publicBaseUrl)
    writeFixtureMetadata(args.output, manifests)
    console.log(`OTA Store v3 Fixture 已生成：${args.output}`)
    console.log(`V1/V2：各 ${BUNDLE_COUNT} 个 Bundle；仅 bundle-${String(CHANGED_INDEX).padStart(3, '0')} 变化`)
    console.log('下一步：node scripts/verify-ota-store-v3-fixture.mjs --fixture <DIR>')
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true })
  }
}

try {
  main()
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exit(1)
}
