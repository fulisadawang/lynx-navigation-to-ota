#!/usr/bin/env node

import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const DEFAULT_FIXTURE = path.join(REPO_ROOT, 'playground', 'fixtures', 'ota-store-v3-golden-100-v1-v2')
const EXPECTED_COUNT = 100
const EXPECTED_CHANGED_INDEX = 50
const PLATFORMS = ['ios', 'android', 'harmony']

function parseArgs(argv) {
  const args = { fixture: DEFAULT_FIXTURE }
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--fixture') args.fixture = path.resolve(argv[++index])
    else if (argv[index] === '--help' || argv[index] === '-h') {
      console.log('用法: node scripts/verify-ota-store-v3-fixture.mjs [--fixture DIR]')
      process.exit(0)
    } else throw new Error(`未知参数：${argv[index]}`)
  }
  return args
}

function sha256(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`
}

function manifestSha256(manifest) {
  const copy = { ...manifest }
  delete copy.manifestSha256
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(copy)).digest('hex')}`
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

function assert(condition, message) {
  if (!condition) throw new Error(`Fixture 校验失败：${message}`)
}

function bundleFiles(fixtureRoot, version) {
  const directory = path.join(fixtureRoot, version, 'bundles', 'pages', '10000001')
  return fs.readdirSync(directory)
    .filter((file) => file.endsWith('.lynx.bundle'))
    .sort()
    .map((file) => path.join(directory, file))
}

function main() {
  const { fixture } = parseArgs(process.argv.slice(2))
  const metadata = readJson(path.join(fixture, 'fixture.json'))
  assert(metadata.fixtureId === 'ota-store-v3-golden-100-v1-v2', 'fixtureId 不匹配')
  assert(metadata.bundleCount === EXPECTED_COUNT, `bundleCount=${metadata.bundleCount}`)
  const v1Files = bundleFiles(fixture, 'V1')
  const v2Files = bundleFiles(fixture, 'V2')
  assert(v1Files.length === EXPECTED_COUNT, `V1 文件数=${v1Files.length}`)
  assert(v2Files.length === EXPECTED_COUNT, `V2 文件数=${v2Files.length}`)

  const v1Digests = v1Files.map(sha256)
  const v2Digests = v2Files.map(sha256)
  assert(new Set(v1Digests).size === EXPECTED_COUNT, 'V1 存在重复对象，无法验证 100 个唯一 Object')
  assert(new Set(v2Digests).size === EXPECTED_COUNT, 'V2 存在重复对象，无法验证 100 个唯一 Object')

  const differences = []
  for (let index = 0; index < EXPECTED_COUNT; index += 1) {
    if (v1Digests[index] !== v2Digests[index]) differences.push(index)
  }
  assert(differences.length === 1 && differences[0] === EXPECTED_CHANGED_INDEX,
    `V1/V2 SHA 差异=${differences.join(',')}`)

  for (const platform of PLATFORMS) {
    for (const version of ['V1', 'V2']) {
      const manifest = readJson(path.join(fixture, 'manifests', platform, `${version}.json`))
      assert(manifest.platform === platform, `${platform}/${version} platform 不匹配`)
      assert(manifest.bundles.length === EXPECTED_COUNT, `${platform}/${version} bundles 数量错误`)
      assert(manifest.changedBundles.length === EXPECTED_COUNT, `${platform}/${version} changedBundles 数量错误`)
      assert(manifest.manifestSha256 === manifestSha256(manifest), `${platform}/${version} manifest SHA 错误`)
      for (let index = 0; index < EXPECTED_COUNT; index += 1) {
        const file = path.join(fixture, version, 'bundles', manifest.bundles[index].bundlePath)
        assert(fs.existsSync(file), `${platform}/${version} 缺少 ${manifest.bundles[index].bundlePath}`)
        assert(manifest.bundles[index].bundleSha256 === sha256(file), `${platform}/${version} Bundle SHA 错误`)
      }
    }
  }

  console.log(JSON.stringify({
    fixtureId: metadata.fixtureId,
    bundleCount: EXPECTED_COUNT,
    changedBundleIndex: EXPECTED_CHANGED_INDEX,
    changedBundleCount: differences.length,
    platforms: PLATFORMS,
    result: 'PASS',
  }, null, 2))
}

try {
  main()
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exit(1)
}
