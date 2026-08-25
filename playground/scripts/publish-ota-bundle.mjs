#!/usr/bin/env node

import OSS from 'ali-oss'
import crypto from 'node:crypto'
import fs from 'node:fs'
import { readFile, readdir, stat, writeFile } from 'node:fs/promises'
import path from 'node:path'

const DEFAULT_SERVER = 'https://lynx-ota-server.test.huangbaoche.com'
const MAX_BUNDLE_BYTES = 20 * 1024 * 1024
const isDryRun = process.argv.includes('--dry-run')

function requiredEnv(name) {
  const value = process.env[name]?.trim()
  if (!value) throw new Error(`缺少 ${name}`)
  return value
}

function booleanEnv(name, fallback) {
  const value = process.env[name]
  if (value === undefined || value === '') return fallback
  if (['1', 'true', 'yes', 'on'].includes(value.toLowerCase())) return true
  if (['0', 'false', 'no', 'off'].includes(value.toLowerCase())) return false
  throw new Error(`${name} 必须是布尔值`)
}

function safeBuildVersion(value) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value)) {
    throw new Error('LYNX_BUILD_VERSION 只能包含字母、数字、点、下划线和短横线')
  }
  return value
}

function safeBundlePath(value) {
  const normalized = value.replaceAll('\\', '/')
  const segments = normalized.split('/')
  if (
    !normalized ||
    normalized.startsWith('/') ||
    !normalized.endsWith('.lynx.bundle') ||
    segments.some((segment) => !segment || segment === '.' || segment === '..')
  ) {
    throw new Error(`Bundle 路径不安全：${value}`)
  }
  return normalized
}

function sha256(bytes) {
  return `sha256:${crypto.createHash('sha256').update(bytes).digest('hex')}`
}

function apiUrl(server, requestPath) {
  return `${server.replace(/\/+$/, '')}${requestPath}`
}

async function responseBody(response) {
  const text = await response.text()
  if (!text) return undefined
  try {
    return JSON.parse(text)
  } catch {
    return text.slice(0, 500)
  }
}

async function requestJson(server, token, method, requestPath, body) {
  const response = await fetch(apiUrl(server, requestPath), {
    method,
    headers: {
      Accept: 'application/json',
      Authorization: `Bearer ${token}`,
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const result = await responseBody(response)
  if (!response.ok) {
    const message = typeof result?.message === 'string' ? result.message : JSON.stringify(result)
    throw new Error(`${method} ${requestPath}：HTTP ${response.status} ${message}`)
  }
  return result
}

async function readOssConfig() {
  const configPath = process.env.LYNX_OSS_CONFIG?.trim()
  const localConfig = configPath && fs.existsSync(configPath)
    ? JSON.parse(await readFile(configPath, 'utf8'))
    : {}
  const accessKeyId = localConfig.accessKeyId || process.env.LYNX_OSS_ACCESS_KEY_ID
  const accessKeySecret = localConfig.accessKeySecret || process.env.LYNX_OSS_ACCESS_KEY_SECRET
  if (!accessKeyId || !accessKeySecret) {
    throw new Error('缺少 OSS 凭证；通过 LYNX_OSS_CONFIG 指向权限为 0600 的本地 JSON')
  }
  if (configPath) {
    const mode = (await stat(configPath)).mode & 0o777
    if (mode !== 0o600) throw new Error(`OSS 配置权限必须为 0600：${configPath}`)
  }
  return { accessKeyId, accessKeySecret }
}

async function readLatest(server, token, env, hostApp, appId, platform) {
  const query = new URLSearchParams({ env, hostApp, lynxAppId: appId, platform })
  const requestPath = `/api/admin/ota/releases/latest-bundle-list?${query}`
  const response = await fetch(apiUrl(server, requestPath), {
    headers: { Accept: 'application/json', Authorization: `Bearer ${token}` },
  })
  const result = await responseBody(response)
  if (response.status === 404) return null
  if (!response.ok) {
    const message = typeof result?.message === 'string' ? result.message : JSON.stringify(result)
    throw new Error(`读取 ${platform} latest 失败：HTTP ${response.status} ${message}`)
  }
  return result
}

function assertSameBaseline(androidLatest, iosLatest) {
  if (!androidLatest || !iosLatest) {
    throw new Error('Android/iOS 任一平台没有现有全量 Release；为避免发布不完整快照，本次停止')
  }
  const android = new Map((androidLatest.changedBundles || []).map((bundle) => [bundle.bundlePath, bundle]))
  const ios = new Map((iosLatest.changedBundles || []).map((bundle) => [bundle.bundlePath, bundle]))
  if (android.size === 0 || ios.size === 0 || android.size !== ios.size) {
    throw new Error('Android/iOS 现有全量 Bundle 快照数量不一致，不能合并发布')
  }
  for (const [bundlePath, bundle] of android) {
    const counterpart = ios.get(bundlePath)
    if (!counterpart || counterpart.bundleSha256 !== bundle.bundleSha256 || counterpart.bundleUrl !== bundle.bundleUrl) {
      throw new Error(`Android/iOS 现有 Bundle 快照不一致：${bundlePath}`)
    }
  }
  return [...android.values()]
}

async function listLocalBundles(bundleDir) {
  const entries = await readdir(bundleDir, { withFileTypes: true })
  const bundles = entries
    .filter((entry) => entry.isFile() && entry.name.endsWith('.lynx.bundle'))
    .map((entry) => ({
      bundlePath: safeBundlePath(entry.name),
      filePath: path.join(bundleDir, entry.name),
    }))
    .sort((left, right) => left.bundlePath.localeCompare(right.bundlePath))
  if (bundles.length === 0) throw new Error(`没有找到 Playground Bundle：${bundleDir}`)
  return bundles
}

function allocatePageIds(existingBundles, startPageId) {
  const used = new Set(existingBundles.map((bundle) => bundle.pageId).filter((id) => Number.isInteger(id) && id > 0))
  let next = Math.max(startPageId - 1, ...used, 0) + 1
  return (bundlePath, existing) => {
    if (Number.isInteger(existing?.pageId) && existing.pageId > 0) return existing.pageId
    while (used.has(next)) next += 1
    const result = next
    used.add(result)
    next += 1
    console.log(`为新增 Bundle 分配 pageId：${bundlePath} -> ${result}`)
    return result
  }
}

async function verifyPublicBundle(bundle) {
  const response = await fetch(bundle.bundleUrl, { headers: { Accept: 'application/octet-stream' } })
  const bytes = Buffer.from(await response.arrayBuffer())
  const actualSha = sha256(bytes)
  if (!response.ok || bytes.length !== bundle.size || actualSha !== bundle.bundleSha256) {
    throw new Error(
      `公网 Bundle 校验失败：${bundle.bundlePath} status=${response.status} size=${bytes.length}/${bundle.size} sha=${actualSha}/${bundle.bundleSha256}`,
    )
  }
}

async function main() {
  const env = (process.env.LYNX_OTA_ENV || 'TEST').toUpperCase()
  const hostApp = requiredEnv('LYNX_HOST_APP')
  const appId = requiredEnv('LYNX_APP_ID')
  const server = process.env.OTA_API?.trim() || DEFAULT_SERVER
  const token = process.env.CI_RELEASE_TOKEN || process.env.OTA_ADMIN_TOKEN
  const buildVersion = safeBuildVersion(requiredEnv('LYNX_BUILD_VERSION'))
  const platforms = [...new Set((process.env.LYNX_PLATFORMS || 'android,ios').split(',').map((value) => value.trim()).filter(Boolean))]
  const bundleDir = path.resolve(process.env.LYNX_BUNDLE_DIR || 'dist')
  const bundleListFile = path.join(bundleDir, 'bundle-list.json')
  const required = booleanEnv('LYNX_REQUIRED', false)
  const prefetch = booleanEnv('LYNX_PREFETCH', true)
  const createdBy = process.env.LYNX_CREATED_BY?.trim() || 'codex-playground'
  const startPageId = Number(process.env.LYNX_PAGE_ID || 1)

  if (!/^\d{8}$/.test(appId)) throw new Error('LYNX_APP_ID 必须是服务端返回的 8 位数字')
  if (env !== 'TEST') throw new Error('当前本地 Playground 发布脚本只允许 TEST')
  if (!['android', 'ios'].every((platform) => platforms.includes(platform))) {
    throw new Error('Playground 全量 Release 必须同时包含 android 和 ios')
  }
  if (!Number.isSafeInteger(startPageId) || startPageId <= 0) throw new Error('LYNX_PAGE_ID 必须是正整数')
  if (!token) throw new Error('缺少 CI_RELEASE_TOKEN；不写入仓库')

  const localBundles = await listLocalBundles(bundleDir)
  const [androidLatest, iosLatest] = await Promise.all([
    readLatest(server, token, env, hostApp, appId, 'android'),
    readLatest(server, token, env, hostApp, appId, 'ios'),
  ])
  const baselineBundles = assertSameBaseline(androidLatest, iosLatest)
  const baselineByPath = new Map(baselineBundles.map((bundle) => [bundle.bundlePath, bundle]))
  const pageIdFor = allocatePageIds(baselineBundles, startPageId)

  const ossConfig = isDryRun ? { accessKeyId: 'dry-run', accessKeySecret: 'dry-run' } : await readOssConfig()
  const oss = new OSS({
    region: requiredEnv('LYNX_OSS_REGION'),
    bucket: requiredEnv('LYNX_OSS_BUCKET'),
    accessKeyId: ossConfig.accessKeyId,
    accessKeySecret: ossConfig.accessKeySecret,
    timeout: 5_000_000,
  })
  const publicBaseUrl = requiredEnv('LYNX_OSS_PUBLIC_BASE_URL').replace(/\/+$/, '')
  const prefix = requiredEnv('LYNX_OSS_PREFIX').replace(/^\/+|\/+$/g, '')
  const completeBundles = [...baselineBundles]

  for (const local of localBundles) {
    const bytes = await readFile(local.filePath)
    if (bytes.length === 0 || bytes.length > MAX_BUNDLE_BYTES) {
      throw new Error(`Bundle 大小非法：${local.bundlePath}=${bytes.length}`)
    }
    const bundleSha256 = sha256(bytes)
    const fileStat = await stat(local.filePath)
    const previous = baselineByPath.get(local.bundlePath)
    const pageId = pageIdFor(local.bundlePath, previous)
    if (previous?.bundleSha256 === bundleSha256 && previous.bundleUrl) {
      const reused = {
        ...previous,
        pageId,
        size: fileStat.size,
        bundleSha256,
        required: previous.required ?? required,
        prefetch: previous.prefetch ?? prefetch,
      }
      const index = completeBundles.findIndex((bundle) => bundle.bundlePath === local.bundlePath)
      completeBundles[index] = reused
      console.log(`复用已有 Bundle：${local.bundlePath} pageId=${pageId}`)
      continue
    }

    const key = `${prefix}/${env.toLowerCase()}/${appId}/${buildVersion}/${local.bundlePath}`
    const bundleUrl = `${publicBaseUrl}/${key}`
    if (!isDryRun) {
      const upload = await oss.put(key, local.filePath)
      if (upload.res.status !== 200) throw new Error(`OSS 上传失败：${local.bundlePath}`)
      console.log(`已上传 Playground Bundle：${local.bundlePath} -> ${key}`)
    } else {
      console.log(`dry-run OSS 上传：${local.bundlePath} -> ${key}`)
    }
    const nextBundle = {
      pageId,
      bundlePath: local.bundlePath,
      bundleUrl,
      bundleSha256,
      size: fileStat.size,
      required,
      prefetch,
    }
    const index = completeBundles.findIndex((bundle) => bundle.bundlePath === local.bundlePath)
    if (index >= 0) completeBundles[index] = nextBundle
    else completeBundles.push(nextBundle)
  }

  completeBundles.sort((left, right) => left.pageId - right.pageId)
  const localBundlePaths = new Set(localBundles.map((bundle) => bundle.bundlePath))
  const preservedBundles = completeBundles.filter((bundle) => !localBundlePaths.has(bundle.bundlePath))
  if (preservedBundles.length === 0) throw new Error('完整快照没有保留现有 OTA Bundle，安全检查失败')

  const releasePayload = {
    env,
    hostApp,
    lynxAppId: appId,
    platforms,
    createdBy,
    changedBundles: completeBundles,
  }
  await writeFile(bundleListFile, `${JSON.stringify({ ...releasePayload, buildVersion }, null, 2)}\n`)
  console.log(`已写入完整 Bundle 清单：${bundleListFile}（${completeBundles.length} 个）`)

  if (isDryRun) {
    console.log(JSON.stringify({ buildVersion, localBundleCount: localBundles.length, preservedBundleCount: preservedBundles.length, releasePayload }, null, 2))
    return
  }

  for (const bundle of completeBundles) await verifyPublicBundle(bundle)
  console.log(`OSS/CDN 回读校验通过：${completeBundles.length}/${completeBundles.length}`)

  const created = await requestJson(server, token, 'POST', '/api/admin/ota/releases', releasePayload)
  const releases = Array.isArray(created?.data) ? created.data : []
  if (releases.length === 0 || releases.some((release) => !release.releaseId)) {
    throw new Error('创建 Release 响应缺少 releaseId')
  }
  const releaseIds = releases.map((release) => release.releaseId)
  console.log(`已创建完整 OTA Release：${releaseIds.join(', ')}`)

  for (const releaseId of releaseIds) {
    const validation = await requestJson(server, token, 'POST', `/api/admin/ota/releases/${encodeURIComponent(releaseId)}/validate`, {})
    if (validation?.validation?.valid !== true) throw new Error(`Release 校验失败：${releaseId}`)
    console.log(`已校验 Release：${releaseId}`)
  }

  const publishBody = process.env.LYNX_CICD_PUBLISH_BODY
    ? JSON.parse(process.env.LYNX_CICD_PUBLISH_BODY)
    : { type: 'full' }
  if (publishBody.type !== 'full') throw new Error('本地 Playground TEST 只允许 full publish')
  for (const releaseId of releaseIds) {
    await requestJson(server, token, 'POST', `/api/admin/ota/releases/${encodeURIComponent(releaseId)}/publish`, publishBody)
    console.log(`已发布完整 Release：${releaseId}`)
  }

  for (const platform of platforms) {
    const latest = await readLatest(server, token, env, hostApp, appId, platform)
    if (!latest || !releaseIds.includes(latest.releaseId) || latest.status !== 'ACTIVE') {
      throw new Error(`${platform} latest 未指向本次 ACTIVE Release`)
    }
    if ((latest.changedBundles || []).length !== completeBundles.length) {
      throw new Error(`${platform} latest Bundle 数量不一致：${latest.changedBundles?.length}/${completeBundles.length}`)
    }
    console.log(`${platform} latest 回读通过：${latest.releaseId}，${latest.changedBundles.length} 个 Bundle`)
  }
}

main().catch((error) => {
  console.error(`Playground OTA 全量发布失败：${error.message}`)
  process.exitCode = 1
})
