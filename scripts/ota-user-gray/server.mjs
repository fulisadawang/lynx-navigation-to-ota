#!/usr/bin/env node
import assert from 'node:assert/strict'
import http from 'node:http'
import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { ALIASES, BUNDLE_NAME, DEFAULT_FIXTURE, loadUserGrayFixture } from '../../playground/scripts/generate-ota-user-gray-fixture.mjs'

export const USER_A = 'user_demo_A'
export const USER_B = 'user_demo_B'
export const CLIENT_TOKEN = 'ota-user-gray-local-client-token'
export const CONTROL_HEADER = 'x-ota-fixture-control'
export const CONTROL_VALUE = 'local-fixture-only'
const SCOPE = { env: 'TEST', hostApp: 'capp', lynxAppId: '10000001' }
const PLATFORMS = ['ios', 'android', 'harmony']
const DEFAULT_PORT = 18766

function isolateEnvironment() {
  process.env.NODE_ENV = 'test'
  process.env.RUNTIME_PROFILE = 'TEST'
  process.env.AUTH_JWT_SECRET = 'ota-user-gray-local-dummy-jwt-secret-32'
  process.env.ADMIN_BOOTSTRAP_USERNAME = 'fixture-admin'
  process.env.ADMIN_BOOTSTRAP_PASSWORD = 'fixture-local-password'
  process.env.DIRECT_URL = ''
  for (const prefix of ['', 'TEST_', 'PROD_', 'STAGING_']) {
    for (const key of ['DB_URL', 'DATABASE_URL', 'REDIS_URL', 'ALERT_FEISHU_WEBHOOK_URL', 'OSS_ENDPOINT', 'OSS_BUCKET', 'OSS_INTERNAL_BUCKET', 'OSS_CDN_BASE_URL', 'MANIFEST_SIGN_PRIVATE_KEY', 'MANIFEST_SIGN_PUBLIC_KEY']) {
      process.env[`${prefix}${key}`] = ''
    }
    process.env[`${prefix}OTA_CLIENT_TOKEN`] = CLIENT_TOKEN
    process.env[`${prefix}OTA_CLIENT_PREVIOUS_TOKEN`] = ''
    process.env[`${prefix}CI_RELEASE_TOKEN`] = ''
    process.env[`${prefix}OTA_CLIENT_RATE_LIMIT_MAX`] = '100000'
    process.env[`${prefix}ALERT_ADMIN_BASE_URL`] = 'http://127.0.0.1'
  }
}

function createMetrics() {
  return { requestCount: 0, latestRequestCount: 0, latestCompletedCount: 0, manifestRequestCount: 0, reportRequestCount: 0, bundleRequestCount: 0, bundleSuccessCount: 0, bundleBytes: 0, delayedLatestCount: 0, requests: [] }
}

function sendJson(response, status, value) {
  const bytes = Buffer.from(JSON.stringify(value))
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': bytes.length, 'cache-control': 'no-store' })
  response.end(bytes)
}

function invalid(message, status = 400) {
  return Object.assign(new Error(message), { status })
}

async function readBytes(request) {
  const chunks = []
  let size = 0
  for await (const chunk of request) {
    size += chunk.length
    if (size > 1024 * 1024) throw invalid('请求体超过本地 fixture 限制', 413)
    chunks.push(chunk)
  }
  return Buffer.concat(chunks)
}

async function readJson(request) {
  try { return JSON.parse((await readBytes(request)).toString('utf8') || '{}') }
  catch { throw invalid('需要 JSON 请求体') }
}

function audience(query) {
  const value = query.get('userId')?.trim()
  return !value ? 'anonymous' : value === USER_A ? 'A' : value === USER_B ? 'B' : 'other'
}

function isLoopback(address) {
  return address === '::1' || address === '127.0.0.1' || address?.startsWith('::ffff:127.')
}

export async function createFixtureAdapter({ serverModule, fixture: fixtureDirectory = DEFAULT_FIXTURE, port = DEFAULT_PORT, bundleOrigin } = {}) {
  if (!serverModule) throw new Error('必须通过 --server-module 指定真实 Server 的 dist/app.js')
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('port 必须为 0..65535')
  const fixture = loadUserGrayFixture(fixtureDirectory)
  isolateEnvironment()
  const serverURL = pathToFileURL(path.resolve(serverModule))
  const { createApp } = await import(serverURL.href)
  if (typeof createApp !== 'function') throw new Error('server-module 必须导出 createApp')
  // 使用被测 Server 实际消费的契约 helpers，避免指标规范化与 API 校验发生漂移。
  const contractsPath = createRequire(serverURL).resolve('@cclx/lynx-ota-contracts')
  const { normalizeVersionCode, normalizeLynxSdkVersion, normalizeOtaUserId } = await import(pathToFileURL(contractsPath).href)
  let realApp = await createApp()
  realApp.log.level = 'silent'
  let metrics = createMetrics()
  let requestSequence = 0
  let stageIndex = -1
  let ready = false
  let generation = 0
  let origin
  let resolvedBundleOrigin
  let adminHeaders
  let delay = { audience: 'A', count: 0, milliseconds: 0 }
  const pending = new Map()
  const releases = {}
  const rules = { gray6: 'fixture-gray6-rule', gray8: 'fixture-gray8-rule' }
  let controls = Promise.resolve()

  async function admin(method, url, payload, status = 200) {
    const result = await realApp.inject({ method, url, headers: adminHeaders, payload })
    assert.equal(result.statusCode, status, `真实 Server fixture setup ${method} ${url}: ${result.body}`)
    return result.json()
  }

  async function publish(alias, type = alias.startsWith('gray') ? 'gray' : 'full') {
    if (!ALIASES.includes(alias)) throw invalid('未知发布别名')
    if (!['full', 'gray'].includes(type) || (type === 'gray' && !rules[alias])) throw invalid('发布类型不合法')
    return admin('POST', `/api/admin/ota/releases/${releases[alias].releaseId}/publish`, {
      type, ...(type === 'gray' ? { ruleId: rules[alias] } : {}),
    })
  }

  async function advance(stage) {
    const target = ALIASES.indexOf(stage)
    if (target < stageIndex || target < 0) throw invalid('阶段只能向前推进；POST /_fixture/reset 可恢复 full5', 409)
    while (stageIndex < target) {
      await publish(ALIASES[stageIndex + 1])
      stageIndex++
    }
  }

  async function state() {
    const aliases = {}
    for (const alias of ALIASES) {
      const detail = await admin('GET', `/api/admin/ota/releases/${releases[alias].releaseId}`)
      aliases[alias] = {
        releaseId: detail.releaseId, releaseSequence: detail.releaseSequence, status: detail.status,
        publishType: detail.publishType, ruleId: rules[alias],
        bundleCount: fixture.metadata.versions[alias].bundles.length,
        marker: fixture.metadata.versions[alias].visibleMarker,
        markerSha256: fixture.metadata.versions[alias].bundles[50].bundleSha256,
      }
    }
    const expectedSelections = {}
    for (const [label, userId] of [['A', USER_A], ['B', USER_B], ['anonymous', undefined]]) {
      const query = new URLSearchParams({ ...SCOPE, platform: 'ios', versioncode: '150', lynxSdkVersion: '4.0.0' })
      if (userId) query.set('userId', userId)
      const response = await realApp.inject({ method: 'GET', url: `/api/ota/v1/releases/latest-bundle-list?${query}`, headers: { 'x-ota-client-token': CLIENT_TOKEN } })
      assert.equal(response.statusCode, 200)
      const result = response.json()
      expectedSelections[label] = result.decision ? { decision: result.decision } : {
        releaseId: result.releaseId, releaseSequence: result.releaseSequence, selection: result.selection,
      }
    }
    return {
      fixtureId: fixture.metadata.fixtureId, realServerModule: path.resolve(serverModule), ready, stage: ALIASES[stageIndex],
      generation,
      ...SCOPE, bundleName: BUNDLE_NAME, origin, bundleOrigin: resolvedBundleOrigin,
      actualReleaseIds: Object.fromEntries(ALIASES.map((alias) => [alias, aliases[alias].releaseId])),
      actualReleaseSequences: Object.fromEntries(ALIASES.map((alias) => [alias, aliases[alias].releaseSequence])),
      expectedReleaseId: expectedSelections.A.releaseId ?? null,
      expectedReleaseIds: Object.fromEntries(Object.entries(expectedSelections).map(([key, value]) => [key, value.releaseId ?? null])),
      expectedSelections,
      aliases, syntheticUsers: { A: USER_A, B: USER_B, anonymous: null },
      clientConfig: { ...SCOPE, versioncode: '150', lynxSdkVersion: '4.0.0', platforms: PLATFORMS, versionCodeRange: { min: '1', max: '999' }, lynxSdkRange: { min: '4.0.0', max: '4.0.0' } },
      delay: { ...delay, pending: [...pending.values()].map((item) => item.info) },
      uniqueObjects: fixture.objects.size,
    }
  }

  function releaseDelays() {
    const count = pending.size
    for (const item of [...pending.values()]) item.release()
    return count
  }

  async function holdLatest(id, response, captured, options) {
    let body
    try { body = captured.json() } catch { body = {} }
    const selected = body.releaseId ? body : body.bundleLists?.find((item) => item.lynxAppId === SCOPE.lynxAppId)
    const releaseAlias = ALIASES.find((alias) => releases[alias].releaseId === selected?.releaseId)
    metrics.delayedLatestCount++
    await new Promise((resolve) => {
      const release = () => {
        clearTimeout(timer)
        pending.delete(id)
        response.off('close', release)
        resolve()
      }
      const timer = setTimeout(release, options.milliseconds || 60000)
      timer.unref()
      pending.set(id, { release, abort: () => { response.destroy(); release() }, info: { requestId: id, audience: options.audience, captured: true, releaseAlias, releaseId: selected?.releaseId } })
      response.once('close', release)
    })
  }

  function recordStart(request, response, parsed, kind, extra = {}) {
    const entry = { requestId: ++requestSequence, kind, method: request.method, completed: false, ...extra }
    metrics.requestCount++
    const activeMetrics = metrics
    if (kind === 'latest') {
      activeMetrics.latestRequestCount++
      entry.audience = audience(parsed.searchParams)
      entry.scope = parsed.searchParams.has('lynxAppId') ? 'single' : 'all'
      entry.platform = PLATFORMS.includes(parsed.searchParams.get('platform')) ? parsed.searchParams.get('platform') : 'unknown'
      const query = parsed.searchParams
      let syntheticAudience = false
      try {
        const userId = normalizeOtaUserId(query.get('userId') ?? undefined)
        syntheticAudience = query.getAll('userId').length <= 1 && [undefined, USER_A, USER_B].includes(userId)
      } catch { /* 不记录非法身份关联的版本上下文。 */ }
      if (syntheticAudience && query.get('env') === SCOPE.env && query.get('hostApp') === SCOPE.hostApp &&
          (!query.has('lynxAppId') || query.get('lynxAppId') === SCOPE.lynxAppId)) {
        for (const [field, normalize] of [['versioncode', normalizeVersionCode], ['lynxSdkVersion', normalizeLynxSdkVersion]]) {
          const values = query.getAll(field)
          if (values.length !== 1) continue
          try { entry[field] = normalize(values[0]) }
          catch { /* 缺失、重复或非法值省略，不回显原始 Query。 */ }
        }
      }
    }
    if (kind === 'manifest') activeMetrics.manifestRequestCount++
    if (kind === 'report') activeMetrics.reportRequestCount++
    if (kind === 'bundle') {
      activeMetrics.bundleRequestCount++
      entry.clientTokenPresent = Boolean(request.headers['x-ota-client-token'] || request.headers.authorization)
      entry.userQueryPresent = parsed.searchParams.has('userId')
    }
    activeMetrics.requests.push(entry)
    if (activeMetrics.requests.length > 2000) activeMetrics.requests.shift()
    response.once('finish', () => {
      entry.completed = true
      entry.statusCode = response.statusCode
      if (kind === 'latest') activeMetrics.latestCompletedCount++
      if (kind === 'bundle' && response.statusCode === 200 && request.method === 'GET') {
        activeMetrics.bundleSuccessCount++
        activeMetrics.bundleBytes += entry.bytes
      }
    })
    return entry
  }

  async function control(request, response, parsed) {
    if (!isLoopback(request.socket.remoteAddress) || request.headers[CONTROL_HEADER] !== CONTROL_VALUE ||
        (request.headers.origin && request.headers.origin !== origin)) {
      throw invalid('fixture controls 只接受 loopback 与显式本地控制 header', 403)
    }
    if (request.method === 'GET' && parsed.pathname === '/_fixture/state') return sendJson(response, 200, await state())
    if (request.method === 'GET' && parsed.pathname === '/_fixture/metrics') {
      return sendJson(response, 200, { ...metrics, pendingLatestCount: pending.size })
    }
    if (request.method !== 'POST') throw invalid('未知 fixture control', 404)
    const body = await readJson(request)
    if (parsed.pathname === '/_fixture/delay-latest') {
      if (body.audience !== 'A' || !Number.isInteger(body.count) || body.count < 0 || body.count > 100 ||
          !Number.isInteger(body.milliseconds ?? 0) || (body.milliseconds ?? 0) < 0 || (body.milliseconds ?? 0) > 30000) throw invalid('delay 仅支持 A、count 0..100、milliseconds 0..30000；0 表示手动释放')
      delay = { audience: 'A', count: body.count, milliseconds: body.milliseconds ?? 0 }
      return sendJson(response, 200, { delay })
    }
    if (parsed.pathname === '/_fixture/release-delays') return sendJson(response, 200, { released: releaseDelays() })
    if (parsed.pathname === '/_fixture/metrics/reset') {
      if (pending.size) throw invalid('存在延迟请求时不能清零计数', 409)
      metrics = createMetrics()
      return sendJson(response, 200, { reset: true })
    }
    // 管理操作串行执行；版本筛选始终由真实 Server 内部事务负责。
    const operation = controls.then(async () => {
      if (parsed.pathname === '/_fixture/reset') await reset()
      else if (parsed.pathname === '/_fixture/stage') await advance(body.stage)
      else if (parsed.pathname === '/_fixture/rule') {
        if (!rules[body.alias] || typeof body.enabled !== 'boolean') throw invalid('rule 需要 gray6/gray8 alias 与 enabled')
        await admin('PATCH', `/api/admin/ota/rules/${rules[body.alias]}/status`, { status: body.enabled ? 'ENABLED' : 'DISABLED' })
      } else if (parsed.pathname === '/_fixture/publish') await publish(body.alias, body.type)
      else if (parsed.pathname === '/_fixture/fallback') {
        const platforms = body.platforms ?? PLATFORMS
        if (typeof body.enabled !== 'boolean' || !Array.isArray(platforms) || !platforms.length || platforms.some((item) => !PLATFORMS.includes(item))) throw invalid('fallback 需要 enabled 和合法 platforms')
        for (const platform of platforms) await admin('POST', '/api/admin/ota/policies/fallback', {
          ...SCOPE, platform, enabled: body.enabled, reasonCode: 'local_fixture_fallback', reasonText: 'Local fixture fallback',
        })
      } else if (parsed.pathname === '/_fixture/rollback') {
        if (!releases[body.from] || (!releases[body.target] && body.target !== 'embedded')) throw invalid('rollback 需要 from 与 target 发布别名或 embedded')
        await admin('POST', `/api/admin/ota/releases/${releases[body.from].releaseId}/rollback`, {
          hostApp: SCOPE.hostApp, lynxAppId: SCOPE.lynxAppId,
          targetReleaseId: body.target === 'embedded' ? 'embedded' : releases[body.target].releaseId,
          reason: 'Local fixture rollback', reasonCode: 'manual_release_rollback',
        })
      } else throw invalid('未知 fixture control', 404)
      return state()
    })
    controls = operation.catch(() => {})
    return sendJson(response, 200, await operation)
  }

  async function handle(request, response) {
    const parsed = new URL(request.url ?? '/', origin)
    if (!ready) return sendJson(response, 503, { message: 'fixture setup in progress' })
    if (parsed.pathname.startsWith('/_fixture/')) return control(request, response, parsed)
    const bundleMatch = parsed.pathname.match(/^\/ota\/bundles\/(full5|gray6|full7|gray8)\/(pages\/10000001\/bundle-\d{3}\.lynx\.bundle)$/)
    if (bundleMatch) {
      const [, alias, bundlePath] = bundleMatch
      const bundle = fixture.metadata.versions[alias].bundles.find((item) => item.bundlePath === bundlePath)
      recordStart(request, response, parsed, 'bundle', { alias, bundlePath, bytes: bundle?.size ?? 0 })
      if (!bundle || !['GET', 'HEAD'].includes(request.method)) return sendJson(response, 404, { message: 'bundle not found' })
      const bytes = fixture.objects.get(bundle.bundleSha256)
      response.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': bytes.length, etag: `"${bundle.bundleSha256}"`, 'cache-control': 'public, max-age=31536000, immutable' })
      return response.end(request.method === 'HEAD' ? undefined : bytes)
    }
    if (!parsed.pathname.startsWith('/api/ota/v1/') && parsed.pathname !== '/health') return sendJson(response, 404, { message: 'fixture route not found' })
    const kind = parsed.pathname === '/api/ota/v1/releases/latest-bundle-list' ? 'latest'
      : parsed.pathname.endsWith('/manifest') ? 'manifest' : parsed.pathname.endsWith('/report') ? 'report' : 'api'
    const entry = recordStart(request, response, parsed, kind)
    const delayed = kind === 'latest' && audience(parsed.searchParams) === delay.audience && delay.count > 0 ? { ...delay } : undefined
    if (delayed) delay.count--
    const headers = {}
    for (const name of ['x-ota-client-token', 'if-none-match', 'content-type']) {
      if (request.headers[name] !== undefined) headers[name] = request.headers[name]
    }
    const payload = ['GET', 'HEAD'].includes(request.method) ? undefined : await readBytes(request)
    const captured = await realApp.inject({ method: request.method, url: `${parsed.pathname}${parsed.search}`, headers, payload })
    // 先运行真正的选择器并捕获响应，再延迟交付；用于验证旧 A 响应在 B 后到达。
    if (delayed) await holdLatest(entry.requestId, response, captured, delayed)
    if (response.destroyed) return
    const outputHeaders = {}
    for (const name of ['content-type', 'content-length', 'cache-control', 'etag']) {
      if (captured.headers[name] !== undefined) outputHeaders[name] = captured.headers[name]
    }
    response.writeHead(captured.statusCode, outputHeaders)
    response.end(captured.rawPayload)
  }

  const server = http.createServer((request, response) => {
    handle(request, response).catch((error) => {
      if (!response.headersSent && !response.destroyed) sendJson(response, error.status ?? 500, { message: error.status ? error.message : '真实 Server fixture 操作失败，请检查终端' })
      if (!error.status) console.error(error)
    })
  })
  const close = async () => {
    releaseDelays()
    server.closeAllConnections()
    await new Promise((resolve) => server.close(resolve))
    await realApp.close()
  }
  async function prepareData() {
    const health = (await realApp.inject({ method: 'GET', url: '/health' })).json()
    assert.equal(health.dbConfigured, false)
    assert.equal(health.redisConfigured, false)
    const login = await realApp.inject({ method: 'POST', url: '/api/admin/ota/auth/login', payload: { username: 'fixture-admin', password: 'fixture-local-password' } })
    assert.equal(login.statusCode, 200)
    adminHeaders = { authorization: `Bearer ${login.json().token}` }
    await admin('GET', `/api/admin/ota/lynx-apps/${SCOPE.lynxAppId}?hostApp=${SCOPE.hostApp}`)
    const seedReleases = await admin('GET', `/api/admin/ota/releases?${new URLSearchParams({ ...SCOPE, pageSize: '100' })}`)
    for (const seed of seedReleases.data) {
      if (seed.status === 'ACTIVE') await admin('POST', `/api/admin/ota/releases/${seed.releaseId}/disable`, { reasonCode: 'local_fixture_seed_disable' })
    }
    const seedRules = await admin('GET', `/api/admin/ota/rules?${new URLSearchParams({ ...SCOPE, pageSize: '100' })}`)
    for (const rule of seedRules.data) await admin('PATCH', `/api/admin/ota/rules/${rule.ruleId}/status`, { status: 'DISABLED' })
    for (const alias of ALIASES) {
      const created = await admin('POST', '/api/admin/ota/releases', {
        ...SCOPE, createdBy: 'fixture-admin', platforms: PLATFORMS,
        versionCodeRange: { min: '1', max: '999' }, lynxSdkRange: { min: '4.0.0', max: '4.0.0' },
        changedBundles: fixture.metadata.versions[alias].bundles.map((bundle) => ({
          ...bundle, bundleUrl: `${resolvedBundleOrigin}/ota/bundles/${alias}/${bundle.bundlePath}`,
        })),
      }, 201)
      assert.equal(created.data.length, 1)
      releases[alias] = created.data[0]
      assert.match(releases[alias].releaseSequence, /^[1-9][0-9]*$/)
      const validation = await admin('POST', `/api/admin/ota/releases/${releases[alias].releaseId}/validate`)
      assert.equal(validation.validation.valid, true, JSON.stringify(validation.validation.issues))
      if (rules[alias]) await admin('POST', '/api/admin/ota/rules', {
        ...SCOPE, ruleId: rules[alias], targetReleaseId: releases[alias].releaseId, stickyBy: 'userId', userWhitelist: [USER_A],
      }, 201)
    }
    await advance('full5')
  }
  async function reset() {
    ready = false
    for (const item of [...pending.values()]) item.abort()
    delay = { audience: 'A', count: 0, milliseconds: 0 }
    const previous = realApp
    try {
      isolateEnvironment()
      realApp = await createApp()
      realApp.log.level = 'silent'
      stageIndex = -1
      for (const alias of ALIASES) delete releases[alias]
      await prepareData()
      metrics = createMetrics()
      requestSequence = 0
      generation++
      ready = true
    } finally { await previous.close() }
  }
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve) })
    origin = `http://127.0.0.1:${server.address().port}`
    const url = new URL(bundleOrigin ?? origin)
    if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '10.0.2.2'].includes(url.hostname) || url.username || url.password || url.pathname !== '/' || url.search || url.hash) throw new Error('--bundle-origin 仅接受本地 http origin（127.0.0.1/localhost/10.0.2.2）')
    resolvedBundleOrigin = url.origin
    await prepareData()
    ready = true
    return { origin, bundleOrigin: resolvedBundleOrigin, state, close, server, fixture }
  } catch (error) {
    await close()
    throw error
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = {}
    for (let index = 2; index < process.argv.length; index++) {
      const flag = process.argv[index]
      if (flag === '--help') {
        console.log('node scripts/ota-user-gray/server.mjs --server-module /absolute/server/dist/app.js [--fixture DIR] [--port 18766] [--bundle-origin http://127.0.0.1:18766]')
        process.exit(0)
      }
      const key = { '--server-module': 'serverModule', '--fixture': 'fixture', '--port': 'port', '--bundle-origin': 'bundleOrigin' }[flag]
      if (!key || !process.argv[index + 1]) throw new Error('未知或缺少 CLI 参数；使用 --help')
      const value = process.argv[++index]
      options[key] = key === 'port' ? Number(value) : value
    }
    const adapter = await createFixtureAdapter(options)
    console.log(JSON.stringify({ ready: true, ...(await adapter.state()) }, null, 2))
    console.log(`Local synthetic client token: ${CLIENT_TOKEN}`)
    let closing = false
    const shutdown = async () => { if (!closing) { closing = true; await adapter.close() } }
    process.once('SIGINT', shutdown)
    process.once('SIGTERM', shutdown)
  } catch (error) {
    console.error(error)
    process.exitCode = 1
  }
}
