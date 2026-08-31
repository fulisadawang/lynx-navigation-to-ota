#!/usr/bin/env node

import crypto from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const DEFAULT_FIXTURE = path.join(REPO_ROOT, 'playground', 'fixtures', 'ota-store-v3-golden-100-v1-v2')
const DEFAULT_HOST = '127.0.0.1'
const DEFAULT_PORT = 18765
const PLATFORMS = ['ios', 'android', 'harmony']

function parseArgs(argv) {
  const args = { fixture: DEFAULT_FIXTURE, host: DEFAULT_HOST, publicHost: DEFAULT_HOST, port: DEFAULT_PORT }
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index]
    if (value === '--fixture') args.fixture = path.resolve(argv[++index])
    else if (value === '--host') args.host = argv[++index]
    else if (value === '--public-host') args.publicHost = argv[++index]
    else if (value === '--port') args.port = Number(argv[++index])
    else if (value === '--help' || value === '-h') {
      console.log('用法: node scripts/ota-store-v3/local-server.mjs [--fixture DIR] [--host HOST] [--public-host HOST] [--port PORT]')
      process.exit(0)
    } else throw new Error(`未知参数：${value}`)
  }
  if (!Number.isInteger(args.port) || args.port < 1 || args.port > 65535) {
    throw new Error(`端口不合法：${args.port}`)
  }
  return args
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

function loadFixture(fixtureRoot) {
  const metadata = readJson(path.join(fixtureRoot, 'fixture.json'))
  const manifests = new Map()
  for (const platform of PLATFORMS) {
    manifests.set(platform, new Map())
    for (const version of ['V1', 'V2']) {
      manifests.get(platform).set(version, readJson(path.join(fixtureRoot, 'manifests', platform, `${version}.json`)))
    }
  }
  return { fixtureRoot, metadata, manifests }
}

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

function sha256Buffer(buffer) {
  return `sha256:${crypto.createHash('sha256').update(buffer).digest('hex')}`
}

function canonicalDigest(manifest) {
  const copy = clone(manifest)
  delete copy.manifestSha256
  return sha256Buffer(Buffer.from(JSON.stringify(copy)))
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = []
    request.on('data', (chunk) => chunks.push(chunk))
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    request.on('error', reject)
  })
}

function jsonResponse(response, statusCode, value, headers = {}) {
  const body = Buffer.from(`${JSON.stringify(value)}\n`)
  response.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
    ...headers,
  })
  response.end(body)
}

function textResponse(response, statusCode, value, headers = {}) {
  const body = Buffer.from(value)
  response.writeHead(statusCode, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
    ...headers,
  })
  response.end(body)
}

function notFound(response, message = 'Not Found') {
  textResponse(response, 404, `${message}\n`)
}

function decodePath(value) {
  try {
    return decodeURIComponent(value)
  } catch {
    return null
  }
}

function parseJsonBody(body) {
  try {
    return body.trim() ? JSON.parse(body) : {}
  } catch {
    throw new Error('请求 JSON 不合法')
  }
}

function releaseVersionById(fixture, releaseId) {
  for (const version of ['V1', 'V2']) {
    if (fixture.manifests.get('ios').get(version).releaseId === releaseId) return version
  }
  return null
}

function sessionId(request) {
  const value = request.headers['x-ota-test-session-id']
  return typeof value === 'string' && value.trim() ? value.trim() : 'anonymous'
}

function createMetrics() {
  return {
    resetAt: new Date().toISOString(),
    requestCount: 0,
    latestRequestCount: 0,
    manifestRequestCount: 0,
    bundleRequestCount: 0,
    bundleBytes: 0,
    requests: [],
  }
}

function createServerState() {
  return {
    activeVersion: { ios: 'V1', android: 'V1', harmony: 'V1' },
    scenario: 'normal',
    metrics: createMetrics(),
  }
}

function recordRequest(state, request, statusCode, extra = {}) {
  state.metrics.requestCount += 1
  if (extra.kind === 'latest') state.metrics.latestRequestCount += 1
  if (extra.kind === 'manifest') state.metrics.manifestRequestCount += 1
  if (extra.kind === 'bundle') state.metrics.bundleRequestCount += 1
  if (extra.bytes) state.metrics.bundleBytes += extra.bytes
  state.metrics.requests.push({
    at: new Date().toISOString(),
    sessionId: sessionId(request),
    method: request.method,
    path: request.url,
    statusCode,
    ...extra,
  })
  if (state.metrics.requests.length > 5000) state.metrics.requests.shift()
}

function withScenario(manifest, scenario) {
  const value = clone(manifest)
  if (scenario === 'bad-sha') {
    const target = value.bundles.find((item) => item.bundlePath.endsWith('bundle-050.lynx.bundle'))
    if (target) target.bundleSha256 = `sha256:${'0'.repeat(64)}`
    value.changedBundles = value.bundles
  }
  if (scenario === 'bad-size') {
    const target = value.bundles.find((item) => item.bundlePath.endsWith('bundle-050.lynx.bundle'))
    if (target) target.size += 1
    value.changedBundles = value.bundles
  }
  value.manifestSha256 = canonicalDigest(value)
  return value
}

function latestResponse(manifest, version, publicBaseUrl) {
  const value = clone(manifest)
  value.changedBundles = value.changedBundles.map((bundle) => ({
    ...bundle,
    bundleUrl: `${publicBaseUrl}/ota/bundles/${encodeURIComponent(manifest.releaseId)}/${bundle.bundlePath
      .split('/')
      .map((part) => encodeURIComponent(part))
      .join('/')}`,
  }))
  value.manifestUrl = `${publicBaseUrl}/api/ota/v1/release/${encodeURIComponent(manifest.releaseId)}/manifest`
  value.manifestSha256 = manifest.manifestSha256
  value.fixtureVersion = version
  return value
}

async function handleRequest(request, response, fixture, state, publicBaseUrl) {
  const parsed = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`)
  const pathname = parsed.pathname

  if (pathname === '/__test__/health') {
    recordRequest(state, request, 200, { kind: 'control' })
    jsonResponse(response, 200, { ok: true, fixtureId: fixture.metadata.fixtureId, scenario: state.scenario })
    return
  }

  if (pathname === '/__test__/metrics' && request.method === 'GET') {
    recordRequest(state, request, 200, { kind: 'control' })
    jsonResponse(response, 200, { ...state.metrics, activeVersion: state.activeVersion, scenario: state.scenario })
    return
  }

  if (pathname === '/__test__/metrics/reset' && (request.method === 'POST' || request.method === 'PUT')) {
    state.metrics = createMetrics()
    recordRequest(state, request, 200, { kind: 'control' })
    jsonResponse(response, 200, { ok: true })
    return
  }

  if (pathname === '/__test__/active' && (request.method === 'POST' || request.method === 'PUT')) {
    const body = parseJsonBody(await readBody(request))
    const version = body.version
    if (!['V1', 'V2'].includes(version)) {
      recordRequest(state, request, 400, { kind: 'control' })
      jsonResponse(response, 400, { error: 'version 只支持 V1/V2' })
      return
    }
    const platform = typeof body.platform === 'string' ? body.platform : null
    if (platform && !PLATFORMS.includes(platform)) {
      recordRequest(state, request, 400, { kind: 'control' })
      jsonResponse(response, 400, { error: 'platform 不支持' })
      return
    }
    for (const item of platform ? [platform] : PLATFORMS) state.activeVersion[item] = version
    recordRequest(state, request, 200, { kind: 'control' })
    jsonResponse(response, 200, { ok: true, activeVersion: state.activeVersion })
    return
  }

  if (pathname === '/__test__/scenario' && (request.method === 'POST' || request.method === 'PUT')) {
    const body = parseJsonBody(await readBody(request))
    const supported = ['normal', 'latest-404', 'manifest-404', 'bundle-404', 'bad-sha', 'bad-size', 'empty', 'disconnect']
    if (!supported.includes(body.mode)) {
      recordRequest(state, request, 400, { kind: 'control' })
      jsonResponse(response, 400, { error: `scenario 不支持：${body.mode}` })
      return
    }
    state.scenario = body.mode
    recordRequest(state, request, 200, { kind: 'control' })
    jsonResponse(response, 200, { ok: true, scenario: state.scenario })
    return
  }

  if (pathname === '/api/ota/v1/releases/latest-bundle-list' && request.method === 'GET') {
    const platform = parsed.searchParams.get('platform') || 'ios'
    const version = state.activeVersion[platform] || 'V1'
    if (!PLATFORMS.includes(platform)) {
      recordRequest(state, request, 400, { kind: 'latest', platform })
      jsonResponse(response, 400, { error: 'platform 不支持' })
      return
    }
    if (state.scenario === 'latest-404') {
      recordRequest(state, request, 404, { kind: 'latest', platform, version })
      jsonResponse(response, 404, { error: 'fixture latest not found' })
      return
    }
    if (state.scenario === 'empty') {
      recordRequest(state, request, 200, { kind: 'latest', platform, version, empty: true })
      const appId = parsed.searchParams.get('lynxAppId')
      if (appId) jsonResponse(response, 200, { env: 'TEST', hostApp: 'capp', lynxAppId: appId, platform, platforms: [platform], changedBundles: [] })
      else jsonResponse(response, 200, { bundleLists: [] })
      return
    }
    const manifest = withScenario(fixture.manifests.get(platform).get(version), state.scenario)
    const value = latestResponse(manifest, version, publicBaseUrl)
    const etag = `"${manifest.manifestSha256}"`
    if (request.headers['if-none-match'] === etag) {
      recordRequest(state, request, 304, { kind: 'latest', platform, version, etag })
      response.writeHead(304, { ETag: etag })
      response.end()
      return
    }
    recordRequest(state, request, 200, { kind: 'latest', platform, version, etag, bundleCount: value.changedBundles.length })
    if (parsed.searchParams.get('lynxAppId')) {
      jsonResponse(response, 200, value, { ETag: etag })
    } else {
      jsonResponse(response, 200, {
        env: 'TEST',
        hostApp: 'capp',
        platform,
        bundleLists: [value],
      }, { ETag: etag })
    }
    return
  }

  const manifestMatch = pathname.match(/^\/api\/ota\/v1\/release\/([^/]+)\/manifest$/)
  if (manifestMatch && request.method === 'GET') {
    const releaseId = decodePath(manifestMatch[1])
    const version = releaseId ? releaseVersionById(fixture, releaseId) : null
    const platform = parsed.searchParams.get('platform') || 'ios'
    if (!version || !fixture.manifests.has(platform)) {
      recordRequest(state, request, 404, { kind: 'manifest', releaseId, platform })
      jsonResponse(response, 404, { error: 'fixture manifest not found' })
      return
    }
    if (state.scenario === 'manifest-404') {
      recordRequest(state, request, 404, { kind: 'manifest', releaseId, platform, version })
      jsonResponse(response, 404, { error: 'fixture manifest unavailable' })
      return
    }
    const manifest = withScenario(fixture.manifests.get(platform).get(version), state.scenario)
    const etag = `"${manifest.manifestSha256}"`
    if (request.headers['if-none-match'] === etag) {
      recordRequest(state, request, 304, { kind: 'manifest', releaseId, platform, version, etag })
      response.writeHead(304, { ETag: etag })
      response.end()
      return
    }
    recordRequest(state, request, 200, { kind: 'manifest', releaseId, platform, version, etag, bundleCount: manifest.bundles.length })
    jsonResponse(response, 200, manifest, { ETag: etag })
    return
  }

  if (pathname === '/api/ota/v1/release/report' && request.method === 'POST') {
    const body = parseJsonBody(await readBody(request))
    const event = typeof body.event === 'string' ? body.event : 'unknown'
    const releaseId = typeof body.releaseId === 'string' ? body.releaseId : null
    recordRequest(state, request, 200, { kind: 'report', event, releaseId })
    jsonResponse(response, 200, { accepted: true, releaseId, event })
    return
  }

  const bundleMatch = pathname.match(/^\/ota\/bundles\/([^/]+)\/(.+)$/)
  if (bundleMatch && request.method === 'GET') {
    const releaseId = decodePath(bundleMatch[1])
    const bundlePath = bundleMatch[2].split('/').map(decodePath)
    const version = releaseId ? releaseVersionById(fixture, releaseId) : null
    if (!version || bundlePath.some((part) => !part || part === '.' || part === '..')) {
      recordRequest(state, request, 404, { kind: 'bundle', releaseId, bundlePath: bundlePath.join('/') })
      notFound(response, 'fixture bundle not found')
      return
    }
    const relative = bundlePath.join('/')
    const file = path.resolve(fixture.fixtureRoot, version, 'bundles', relative)
    const allowedRoot = path.resolve(fixture.fixtureRoot, version, 'bundles')
    if (!file.startsWith(`${allowedRoot}${path.sep}`) || !fs.existsSync(file)) {
      recordRequest(state, request, 404, { kind: 'bundle', releaseId, version, bundlePath: relative })
      notFound(response, 'fixture bundle not found')
      return
    }
    if (state.scenario === 'bundle-404') {
      recordRequest(state, request, 404, { kind: 'bundle', releaseId, version, bundlePath: relative })
      notFound(response, 'fixture bundle intentionally unavailable')
      return
    }
    if (state.scenario === 'disconnect') {
      recordRequest(state, request, 599, { kind: 'bundle', releaseId, version, bundlePath: relative, disconnected: true })
      request.socket.destroy()
      return
    }
    const body = fs.readFileSync(file)
    recordRequest(state, request, 200, { kind: 'bundle', releaseId, version, bundlePath: relative, bytes: body.length })
    response.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Content-Length': body.length,
      'Cache-Control': 'no-store',
      ETag: `"${sha256Buffer(body)}"`,
    })
    response.end(body)
    return
  }

  recordRequest(state, request, 404, { kind: 'unknown' })
  notFound(response)
}

function main() {
  const args = parseArgs(process.argv.slice(2))
  const fixture = loadFixture(args.fixture)
  const state = createServerState()
  const publicBaseUrl = `http://${args.publicHost}:${args.port}`
  const server = http.createServer((request, response) => {
    handleRequest(request, response, fixture, state, publicBaseUrl).catch((error) => {
      recordRequest(state, request, 500, { kind: 'server', error: error instanceof Error ? error.message : String(error) })
      if (!response.headersSent) jsonResponse(response, 500, { error: error instanceof Error ? error.message : String(error) })
      else response.end()
    })
  })
  server.listen(args.port, args.host, () => {
    console.log(`OTA Store v3 local fixture server listening on ${publicBaseUrl}`)
    console.log(`fixture=${fixture.metadata.fixtureId} active=V1 bundleCount=${fixture.metadata.bundleCount}`)
    console.log('control: POST /__test__/active {"version":"V1"|"V2"}')
    console.log('control: POST /__test__/scenario {"mode":"normal|latest-404|manifest-404|bundle-404|bad-sha|bad-size|empty|disconnect"}')
    console.log('metrics: GET /__test__/metrics')
  })
  const shutdown = () => server.close(() => process.exit(0))
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)
}

try {
  main()
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exit(1)
}
