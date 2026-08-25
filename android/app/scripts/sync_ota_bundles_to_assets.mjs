#!/usr/bin/env node

/**
 * 三端 Demo 的手动 OTA baseline 同步脚本。
 *
 * 它复用 Android 原生 OtaApiClient 的同一个全量接口和响应契约：
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

function targetPaths(target) {
  if (target === 'android') {
    const assetsRoot = path.join(repoRoot, 'android/app/src/main/assets')
    return { label: 'Android', assetsRoot, embeddedRoot: path.join(assetsRoot, 'bundles/lynx') }
  }
  if (target === 'ios') {
    const assetsRoot = path.join(repoRoot, 'ios/LynxShellSample/Resources/Bundles')
    return { label: 'iOS', assetsRoot, embeddedRoot: path.join(assetsRoot, 'lynx') }
  }
  if (target === 'harmony') {
    const assetsRoot = path.join(repoRoot, 'harmony/lynx_shell/src/main/resources/rawfile')
    return { label: 'HarmonyOS', assetsRoot, embeddedRoot: path.join(assetsRoot, 'bundles/lynx') }
  }
  throw new Error(`不支持的 target：${target}，可选 android/ios/harmony`)
}

function parseArgs(argv) {
  const options = {
    baseUrl: process.env.LYNX_OTA_API_BASE_URL || '',
    token: process.env.LYNX_OTA_CLIENT_TOKEN || '',
    env: 'TEST',
    hostApp: 'capp',
    platform: 'android',
    target: 'android',
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
    else if (arg === '--dry-run') options.dryRun = true
    else if (arg === '--help' || arg === '-h') printHelp(0)
    else throw new Error(`未知参数：${arg}`)

    if (arg.startsWith('--') && arg !== '--dry-run' && arg !== '--help' && arg !== '-h') {
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
  if (!/^https:\/\//i.test(options.baseUrl)) {
    throw new Error('OTA API 地址必须使用 HTTPS')
  }
  targetPaths(options.target)
  return options
}

function printHelp(exitCode) {
  console.log(`用法：
  LYNX_OTA_API_BASE_URL='https://ota.example.com' \\
  LYNX_OTA_CLIENT_TOKEN='<本机临时注入，不要写入 Git>' \\
  node android/app/scripts/sync_ota_bundles_to_assets.mjs \\
    --target android \\
    --env TEST \\
    --host-app capp \\
    --platform android

--target 决定写入 android/ios/harmony 哪个 Demo；--platform 是服务端查询平台。
Harmony 当前服务端兼容配置使用 --target harmony --platform android。
脚本只请求全量 latest-bundle-list，不支持指定 --app-id。
App ID、releaseId、bundlePath、size、SHA 和 Bundle URL 均来自服务端响应。
--dry-run 会下载并校验，但不会替换目标平台的 embedded 目录。
`)
  process.exit(exitCode)
}

function safeSegment(value, field) {
  if (!value || !/^[A-Za-z0-9._-]+$/.test(value)) {
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

function parseLatestBundleLists(body) {
  const rawLists = Array.isArray(body?.bundleLists) ? body.bundleLists : [body]
  if (rawLists.length === 0 || rawLists.some((item) => !item || typeof item !== 'object')) {
    throw new Error('latest-bundle-list 响应缺少 bundleLists')
  }

  const appIds = new Set()
  return rawLists.map((snapshot) => {
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
    return { lynxAppId, releaseId, bundles }
  })
}

async function downloadAndValidate(bundle, stagePath) {
  const bundlePath = safeBundlePath(String(bundle.bundlePath || ''))
  const bundleUrl = String(bundle.bundleUrl || bundle.bundleURL || bundle.remoteUrl || '')
  const expectedSize = validateSize(bundle.size)
  const expectedSha = validateSha(String(bundle.bundleSha256 || ''))
  let url
  try {
    url = new URL(bundleUrl)
  } catch {
    throw new Error(`Bundle URL 无效：${bundleUrl || '(empty)'}`)
  }
  if (url.protocol !== 'https:') {
    throw new Error(`Bundle URL 必须使用 HTTPS：${bundleUrl}`)
  }

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
  const backupRoot = path.join(parent, `.lynx-backup-${process.pid}`)
  let movedExisting = false

  try {
    if (fs.existsSync(paths.embeddedRoot)) {
      fs.renameSync(paths.embeddedRoot, backupRoot)
      movedExisting = true
    }
    fs.renameSync(stageEmbeddedRoot, paths.embeddedRoot)
    if (movedExisting) fs.rmSync(backupRoot, { recursive: true, force: true })
  } catch (error) {
    if (fs.existsSync(paths.embeddedRoot)) fs.rmSync(paths.embeddedRoot, { recursive: true, force: true })
    if (movedExisting && fs.existsSync(backupRoot)) fs.renameSync(backupRoot, paths.embeddedRoot)
    throw error
  } finally {
    fs.rmSync(stageRoot, { recursive: true, force: true })
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2))
  const paths = targetPaths(options.target)
  const latestUrl = resolveUrl(options.baseUrl, apiPath, {
    env: options.env,
    hostApp: options.hostApp,
    platform: options.platform,
  })
  const response = await requestJson(latestUrl, options.token)
  const snapshots = parseLatestBundleLists(response)
  const stageRoot = fs.mkdtempSync(path.join(paths.assetsRoot, '.lynx-stage-'))
  const stageEmbeddedRoot = path.join(stageRoot, 'lynx')
  const apps = []

  try {
    for (const snapshot of snapshots) {
      const bundleDescriptors = []
      for (const bundle of snapshot.bundles) {
        const descriptor = await downloadAndValidate(
          bundle,
          path.join(stageEmbeddedRoot, snapshot.lynxAppId, 'releases', snapshot.releaseId),
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
      return
    }
    replaceEmbeddedRoot(stageRoot, paths)
    console.log(`${paths.label} Demo embedded assets 已更新：${apps.length} 个 App、${apps.reduce((count, app) => count + app.bundles.length, 0)} 个 Bundle`)
    for (const app of apps) console.log(`  ${app.lynxAppId}/${app.releaseId}: ${app.bundles.length} bundles`)
  } catch (error) {
    fs.rmSync(stageRoot, { recursive: true, force: true })
    throw error
  }
}

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  printHelp(0)
}

main().catch((error) => {
  console.error(`Android Demo OTA assets 未更新：${error.message}`)
  process.exitCode = 1
})
