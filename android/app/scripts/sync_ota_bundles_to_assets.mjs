#!/usr/bin/env node

/**
 * 三端 Demo 的手动 OTA baseline 同步脚本。
 *
 * 它匿名请求真实 Server 的新版全量接口，只内置兼容的 full 发布：
 *   GET /api/ota/v1/releases/latest-bundle-list
 *   -> bundleLists[*].lynxAppId
 *   -> bundleLists[*].changedBundles[*]
 *
 * 脚本不接收 --app-id，也不生成 App ID。返回什么就按什么身份写入目标平台资源：
 *   <target resources>/bundles/lynx/<lynxAppId>/releases/<releaseId>/...
 *
 * 只有所有 active Release 的 Bundle 都完成 size/SHA-256 校验后，才替换 embedded 目录；
 * API 返回 HTML、非 JSON、非 2xx、字段缺失或任一 Bundle 校验失败，都不会修改现有 assets。
 */

import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const scriptDir = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(scriptDir, '../../..')
const maxBundleBytes = 20 * 1024 * 1024
const apiPath = '/api/ota/v1/releases/latest-bundle-list'

function targetPaths(target, outputDirectory) {
  if (target === 'android') {
    const assetsRoot = outputDirectory || path.join(repoRoot, 'android/app/src/main/assets')
    return { label: 'Android', assetsRoot, embeddedRoot: path.join(assetsRoot, 'bundles/lynx') }
  }
  if (target === 'ios') {
    const assetsRoot = outputDirectory || path.join(repoRoot, 'ios/LynxShellSample/Resources/Bundles')
    return { label: 'iOS', assetsRoot, embeddedRoot: path.join(assetsRoot, 'lynx') }
  }
  if (target === 'harmony') {
    const assetsRoot = outputDirectory || path.join(repoRoot, 'harmony/lynx_shell/src/main/resources/rawfile')
    return { label: 'HarmonyOS', assetsRoot, embeddedRoot: path.join(assetsRoot, 'bundles/lynx') }
  }
  throw new Error(`不支持的 target：${target}，可选 android/ios/harmony`)
}

// 与 LynxContracts otaSelection helpers 对齐；CLI 只使用 Node 内置模块。
export function normalizeVersionCode(raw) {
  if (typeof raw !== 'string' || !/^[0-9]+$/.test(raw.trim())) {
    throw new TypeError('versioncode 必须为正十进制整数字符串')
  }
  const normalized = raw.trim().replace(/^0+/, '')
  const maximum = '9223372036854775807'
  if (!normalized || normalized.length > maximum.length || (normalized.length === maximum.length && normalized > maximum)) {
    throw new TypeError('versioncode 必须在 1..9223372036854775807 范围内')
  }
  return normalized
}

export function normalizeLynxSdkVersion(raw) {
  if (typeof raw !== 'string' || !/^[0-9]+(?:\.[0-9]+){0,2}$/.test(raw.trim())) {
    throw new TypeError('lynxSdkVersion 必须是 1..3 段非负整数的稳定版本')
  }
  const components = raw.trim().split('.').map((item) => item.replace(/^0+(?=[0-9])/, ''))
  while (components.length < 3) components.push('0')
  return components.join('.')
}

export function validateTransportUrl(raw, allowLocalHttp = false) {
  let url
  try { url = new URL(raw) } catch { throw new Error('OTA URL 不合法') }
  const loopback = url.hostname === 'localhost' || url.hostname === '[::1]' || /^127\.[0-9]+\.[0-9]+\.[0-9]+$/.test(url.hostname)
  if (url.username || url.password) throw new Error('OTA URL 不允许内嵌认证信息')
  if (url.searchParams.has('userId')) throw new Error('内置下载必须匿名，URL 不允许 userId')
  if (url.protocol !== 'https:' && !(allowLocalHttp && url.protocol === 'http:' && loopback)) {
    throw new Error('OTA URL 必须使用 HTTPS；仅 --allow-local-http 可放行 loopback HTTP')
  }
  return url
}

export function parseArgs(argv, env = process.env) {
  const options = {
    baseUrl: env.LYNX_OTA_API_BASE_URL || '',
    token: env.LYNX_OTA_CLIENT_TOKEN || '',
    env: 'TEST',
    hostApp: 'capp',
    platform: undefined,
    target: 'android',
    versioncode: undefined,
    lynxSdkVersion: undefined,
    outputDirectory: undefined,
    allowLocalHttp: false,
    dryRun: false,
  }

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    const next = argv[index + 1]
    if (arg === '--base-url') options.baseUrl = next
    else if (arg === '--env') options.env = next
    else if (arg === '--host-app') options.hostApp = next
    else if (arg === '--platform') options.platform = next
    else if (arg === '--target') options.target = next
    else if (arg === '--versioncode') options.versioncode = next
    else if (arg === '--lynx-sdk-version') options.lynxSdkVersion = next
    else if (arg === '--output-dir') options.outputDirectory = next
    else if (arg === '--allow-local-http') options.allowLocalHttp = true
    else if (arg === '--dry-run') options.dryRun = true
    else if (arg === '--help' || arg === '-h') printHelp(0)
    else throw new Error('不支持的 CLI 参数；内置下载不接受 userId 或指定 App ID，请使用 --help')

    if (arg.startsWith('--') && !['--dry-run', '--allow-local-http', '--help', '-h'].includes(arg)) {
      if (!next || next.startsWith('--')) throw new Error(`${arg} 缺少参数值`)
      index += 1
    }
  }

  if (!options.baseUrl) {
    throw new Error('缺少 OTA API 地址：请通过 --base-url 或 LYNX_OTA_API_BASE_URL 注入')
  }
  if (!options.token) {
    throw new Error('缺少 OTA Token：请通过 LYNX_OTA_CLIENT_TOKEN 注入')
  }
  if (options.versioncode === undefined) throw new Error('缺少必填 --versioncode')
  if (options.lynxSdkVersion === undefined) throw new Error('缺少必填 --lynx-sdk-version')
  options.versioncode = normalizeVersionCode(options.versioncode)
  options.lynxSdkVersion = normalizeLynxSdkVersion(options.lynxSdkVersion)
  targetPaths(options.target)
  options.platform ??= options.target
  if (options.platform !== options.target) throw new Error('--platform 必须与 --target 一致，不允许平台降级')
  validateTransportUrl(options.baseUrl, options.allowLocalHttp)
  if (options.outputDirectory) options.outputDirectory = path.resolve(options.outputDirectory)
  return options
}

function printHelp(exitCode) {
  console.log(`用法：
  LYNX_OTA_API_BASE_URL='https://ota.example.com' \\
  LYNX_OTA_CLIENT_TOKEN='<本机临时注入，不要写入 Git>' \\
  node android/app/scripts/sync_ota_bundles_to_assets.mjs \\
    --target ios \\
    --env TEST \\
    --host-app capp \\
    --versioncode 150 \\
    --lynx-sdk-version 4.1.0

--versioncode 和 --lynx-sdk-version 必填；按目标宿主构建号及实际 Runtime 填写。
HTTP 字段精确为 versioncode / lynxSdkVersion；前导零规范化，SDK 补齐三段。
--target 决定写入 android/ios/harmony 哪个 Demo；--platform 默认 target，显式指定也必须一致。
始终匿名，不接受 userId；只接受 selectionSchemaVersion=1 且 selection.kind=full 的完整快照。
任何 directive、灰度、无可用发布或不兼容范围都会中止，保留现有 embedded 目录。
脚本只请求全量 latest-bundle-list，不支持指定 --app-id。
App ID、releaseId、bundlePath、size、SHA 和 Bundle URL 均来自服务端响应。
--dry-run 会下载并校验，但不会替换目标平台的 embedded 目录。
--output-dir DIR 将资源根目录改为指定目录，适合临时测试，避免触碰真实 Demo assets。
--allow-local-http 仅放行 localhost / 127.0.0.0/8 / ::1 的 API 和 Bundle HTTP；生产仍要求 HTTPS。
`)
  process.exit(exitCode)
}

function safeSegment(value, field) {
  if (!value || value === '.' || value === '..' || !/^[A-Za-z0-9._-]+$/.test(value)) {
    throw new Error(`${field} 含有不安全字符：${value || '(empty)'}`)
  }
  return value
}

function safeBundlePath(value) {
  if (
    !value ||
    value.startsWith('/') ||
    value.includes('\\') ||
    !value.endsWith('.lynx.bundle') ||
    value.split('/').some((part) => !part || part === '.' || part === '..')
  ) {
    throw new Error(`bundlePath 不安全：${value || '(empty)'}`)
  }
  return value
}

function validateSize(value) {
  if (!Number.isInteger(value) || value <= 0 || value > maxBundleBytes) {
    throw new Error(`Bundle size 不合法：${value}`)
  }
  return value
}

function validateSha(value) {
  if (!/^sha256:[0-9a-fA-F]{64}$/.test(value || '')) {
    throw new Error(`bundleSha256 格式错误：${value || '(empty)'}`)
  }
  return value
}

function resolveUrl(baseUrl, pathname, query) {
  const url = new URL(pathname, `${baseUrl.replace(/\/$/, '')}/`)
  for (const [key, value] of Object.entries(query)) {
    url.searchParams.set(key, String(value))
  }
  return url
}

async function requestJson(url, token) {
  const response = await fetch(url, {
    headers: {
      Accept: 'application/json',
      'x-ota-client-token': token,
    },
    redirect: 'error',
  })
  const contentType = response.headers.get('content-type') || ''
  const body = await response.text()
  if (!response.ok) {
    throw new Error(`OTA API 请求失败：HTTP ${response.status}`)
  }
  if (!contentType.toLowerCase().includes('application/json')) {
    throw new Error(`OTA API 返回非 JSON：HTTP ${response.status}，Content-Type=${contentType || '(empty)'}`)
  }
  try {
    return JSON.parse(body)
  } catch {
    throw new Error('OTA API JSON 解析失败')
  }
}

function compareNumericVersion(left, right) {
  const a = left.split('.')
  const b = right.split('.')
  for (let index = 0; index < a.length; index++) {
    if (BigInt(a[index]) !== BigInt(b[index])) return BigInt(a[index]) < BigInt(b[index]) ? -1 : 1
  }
  return 0
}

function matchesRange(value, range, normalize) {
  if (range === undefined) return true
  if (!range || typeof range !== 'object' || Array.isArray(range) || Object.keys(range).some((key) => key !== 'min' && key !== 'max')) return false
  try {
    const min = range.min === undefined ? undefined : normalize(range.min)
    const max = range.max === undefined ? undefined : normalize(range.max)
    if (min !== undefined && max !== undefined && compareNumericVersion(min, max) > 0) return false
    return (min === undefined || compareNumericVersion(value, min) >= 0) && (max === undefined || compareNumericVersion(value, max) <= 0)
  } catch { return false }
}

export function parseLatestBundleLists(body, options) {
  if (body?.selectionSchemaVersion !== 1 || !Array.isArray(body.bundleLists) || !Array.isArray(body.directives)) {
    throw new Error('需要 selectionSchemaVersion=1 的完整 latest 响应')
  }
  if (body.env !== options.env || body.hostApp !== options.hostApp || body.platform !== options.platform) {
    throw new Error('latest 响应 scope 或平台不一致')
  }
  if (body.directives.length) throw new Error('latest 含回退或无可用发布指令，保留现有内置 Bundle')
  const rawLists = body.bundleLists
  if (rawLists.length === 0 || rawLists.some((item) => !item || typeof item !== 'object')) {
    throw new Error('latest-bundle-list 响应缺少 bundleLists')
  }

  const appIds = new Set()
  return rawLists.map((snapshot) => {
    if (snapshot.selectionSchemaVersion !== 1 || snapshot.selection?.kind !== 'full') {
      throw new Error('内置 Bundle 只接受新版 full selection，拒绝灰度或未知归属')
    }
    if (snapshot.env !== options.env || snapshot.hostApp !== options.hostApp || snapshot.platform !== options.platform) {
      throw new Error('快照 scope 或平台与目标不一致')
    }
    if (typeof snapshot.releaseSequence !== 'string' || !/^[1-9][0-9]*$/.test(snapshot.releaseSequence) ||
        typeof snapshot.selection.policyRevision !== 'string' || !/^[0-9]+$/.test(snapshot.selection.policyRevision)) {
      throw new Error('快照缺少合法发布序号或策略修订')
    }
    if (!matchesRange(options.versioncode, snapshot.versionCodeRange, normalizeVersionCode) ||
        !matchesRange(options.lynxSdkVersion, snapshot.lynxSdkRange, normalizeLynxSdkVersion)) {
      throw new Error('快照的原生构建号或 Lynx SDK 范围不兼容')
    }
    const lynxAppId = safeSegment(String(snapshot.lynxAppId || ''), 'lynxAppId')
    const releaseId = safeSegment(String(snapshot.releaseId || ''), 'releaseId')
    if (appIds.has(lynxAppId)) {
      throw new Error(`latest-bundle-list 返回重复 lynxAppId：${lynxAppId}`)
    }
    appIds.add(lynxAppId)
    if (String(snapshot.status || '').toUpperCase() !== 'ACTIVE') {
      throw new Error(`latest-bundle-list 返回的 Release 不是 ACTIVE：${lynxAppId}/${releaseId}`)
    }

    const bundles = snapshot.changedBundles
    if (!Array.isArray(bundles) || bundles.length === 0) {
      throw new Error(`Release 没有 changedBundles：${lynxAppId}/${releaseId}`)
    }
    const bundlePaths = bundles.map((bundle) => safeBundlePath(bundle?.bundlePath))
    if (new Set(bundlePaths).size !== bundlePaths.length) throw new Error('完整快照含重复 Bundle 路径')
    return { lynxAppId, releaseId, bundles }
  })
}

async function downloadAndValidate(bundle, stagePath, allowLocalHttp) {
  const bundlePath = safeBundlePath(String(bundle.bundlePath || ''))
  const bundleUrl = String(bundle.bundleUrl || bundle.bundleURL || bundle.remoteUrl || '')
  const expectedSize = validateSize(bundle.size)
  const expectedSha = validateSha(String(bundle.bundleSha256 || ''))
  const url = validateTransportUrl(bundleUrl, allowLocalHttp)

  // 与原生 OtaIO 一致：OTA token 只给 JSON API，不透传给 OSS/CDN。
  const response = await fetch(url, { redirect: 'error' })
  if (!response.ok) {
    throw new Error(`Bundle 下载失败：HTTP ${response.status}`)
  }
  const bytes = Buffer.from(await response.arrayBuffer())
  if (bytes.length !== expectedSize) {
    throw new Error(`Bundle size 校验失败：expected=${expectedSize}, actual=${bytes.length}`)
  }
  const actualSha = `sha256:${crypto.createHash('sha256').update(bytes).digest('hex')}`
  if (actualSha.toLowerCase() !== expectedSha.toLowerCase()) {
    throw new Error(`Bundle SHA-256 校验失败：expected=${expectedSha}, actual=${actualSha}`)
  }

  const destination = path.join(stagePath, bundlePath)
  fs.mkdirSync(path.dirname(destination), { recursive: true })
  fs.writeFileSync(destination, bytes)
  const parsedPageId = Number(bundle.pageId ?? 0)
  if (!Number.isSafeInteger(parsedPageId) || parsedPageId < 0) {
    throw new Error(`pageId 不合法：${bundle.pageId}`)
  }
  return {
    pageId: parsedPageId,
    bundleName: path.posix.basename(bundlePath),
    bundlePath,
    size: expectedSize,
    sha256: expectedSha,
  }
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true })
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`)
}

function replaceEmbeddedRoot(stageRoot, paths) {
  const stageEmbeddedRoot = path.join(stageRoot, 'lynx')
  const parent = path.dirname(paths.embeddedRoot)
  fs.mkdirSync(parent, { recursive: true })
  const backupDirectory = fs.mkdtempSync(path.join(parent, '.lynx-backup-'))
  const backupRoot = path.join(backupDirectory, 'lynx')
  let movedExisting = false
  let installed = false

  try {
    if (fs.existsSync(paths.embeddedRoot)) {
      fs.renameSync(paths.embeddedRoot, backupRoot)
      movedExisting = true
    }
    fs.renameSync(stageEmbeddedRoot, paths.embeddedRoot)
    installed = true
  } catch (error) {
    if (movedExisting && fs.existsSync(backupRoot)) fs.renameSync(backupRoot, paths.embeddedRoot)
    throw error
  } finally {
    fs.rmSync(stageRoot, { recursive: true, force: true })
    // 备份恢复失败时保留备份，不能误删唯一可恢复的数据。
    if (installed || !fs.existsSync(backupRoot)) fs.rmSync(backupDirectory, { recursive: true, force: true })
  }
}

export async function syncOtaBundles(argv, env = process.env) {
  const options = parseArgs(argv, env)
  const paths = targetPaths(options.target, options.outputDirectory)
  const latestUrl = resolveUrl(options.baseUrl, apiPath, {
    env: options.env,
    hostApp: options.hostApp,
    platform: options.platform,
    versioncode: options.versioncode,
    lynxSdkVersion: options.lynxSdkVersion,
  })
  const response = await requestJson(latestUrl, options.token)
  const snapshots = parseLatestBundleLists(response, options)
  if (!options.dryRun) fs.mkdirSync(paths.assetsRoot, { recursive: true })
  const stageRoot = fs.mkdtempSync(path.join(options.dryRun ? os.tmpdir() : paths.assetsRoot, '.lynx-stage-'))
  const stageEmbeddedRoot = path.join(stageRoot, 'lynx')
  const apps = []

  try {
    for (const snapshot of snapshots) {
      const bundleDescriptors = []
      for (const bundle of snapshot.bundles) {
        const descriptor = await downloadAndValidate(
          bundle,
          path.join(stageEmbeddedRoot, snapshot.lynxAppId, 'releases', snapshot.releaseId),
          options.allowLocalHttp,
        )
        descriptor.assetPath = `bundles/lynx/${snapshot.lynxAppId}/releases/${snapshot.releaseId}/${descriptor.bundlePath}`
        bundleDescriptors.push(descriptor)
      }
      apps.push({
        lynxAppId: snapshot.lynxAppId,
        releaseId: snapshot.releaseId,
        bundles: bundleDescriptors,
      })
    }

    writeJson(path.join(stageEmbeddedRoot, 'embedded-bundles.json'), {
      schemaVersion: 1,
      apps,
    })

    if (options.dryRun) {
      console.log(`dry-run：${paths.label} 已校验 ${apps.length} 个 App、${apps.reduce((count, app) => count + app.bundles.length, 0)} 个 Bundle，未修改 assets`)
      fs.rmSync(stageRoot, { recursive: true, force: true })
      return { dryRun: true, apps, embeddedRoot: paths.embeddedRoot }
    }
    replaceEmbeddedRoot(stageRoot, paths)
    console.log(`${paths.label} Demo embedded assets 已更新：${apps.length} 个 App、${apps.reduce((count, app) => count + app.bundles.length, 0)} 个 Bundle`)
    for (const app of apps) console.log(`  ${app.lynxAppId}/${app.releaseId}: ${app.bundles.length} bundles`)
    return { dryRun: false, apps, embeddedRoot: paths.embeddedRoot }
  } catch (error) {
    fs.rmSync(stageRoot, { recursive: true, force: true })
    throw error
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.includes('--help') || process.argv.includes('-h')) printHelp(0)
  syncOtaBundles(process.argv.slice(2)).catch((error) => {
    console.error(`Demo OTA assets 未更新：${error.message}`)
    process.exitCode = 1
  })
}
