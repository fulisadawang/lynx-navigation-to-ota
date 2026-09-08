import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'
import test from 'node:test'
import { normalizeVersionCode, normalizeLynxSdkVersion, parseArgs, parseLatestBundleLists, syncOtaBundles, validateTransportUrl } from './sync_ota_bundles_to_assets.mjs'

const SCRIPT = fileURLToPath(new URL('./sync_ota_bundles_to_assets.mjs', import.meta.url))
const TEST_ENV = { LYNX_OTA_CLIENT_TOKEN: 'c22-synthetic-local-token' }
const SHA = (bytes) => `sha256:${crypto.createHash('sha256').update(bytes).digest('hex')}`

function argv({ baseUrl = 'https://api.example.invalid', target = 'ios', versioncode = '150', sdk = '4.0.0', outputDirectory, local = false, dryRun = false } = {}) {
  return [
    '--base-url', baseUrl, '--target', target,
    ...(versioncode === undefined ? [] : ['--versioncode', versioncode]),
    ...(sdk === undefined ? [] : ['--lynx-sdk-version', sdk]),
    ...(outputDirectory ? ['--output-dir', outputDirectory] : []),
    ...(local ? ['--allow-local-http'] : []), ...(dryRun ? ['--dry-run'] : []),
  ]
}

function temporaryOutput(t, target = 'ios') {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lynx-c22-embedded-test-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const embeddedRoot = path.join(root, target === 'ios' ? 'lynx' : 'bundles/lynx')
  fs.mkdirSync(embeddedRoot, { recursive: true })
  const sentinel = path.join(embeddedRoot, 'existing-baseline.txt')
  fs.writeFileSync(sentinel, 'keep-existing-baseline')
  return { root, embeddedRoot, sentinel }
}

function snapshot({ platform = 'ios', origin = 'https://cdn.example.invalid', releaseId = 'full_fixture', bytes = [Buffer.from('unit-bundle-1'), Buffer.from('unit-bundle-2')] } = {}) {
  return {
    selectionSchemaVersion: 1, env: 'TEST', hostApp: 'capp', lynxAppId: '10000001', releaseId,
    releaseSequence: '9007199254740993', platform, platforms: [platform], status: 'ACTIVE',
    selection: { kind: 'full', policyRevision: '9007199254740994', reason: 'latest_full' },
    changedBundles: bytes.map((value, index) => ({
      pageId: 10000001 + index, bundlePath: `pages/10000001/bundle-${index}.lynx.bundle`,
      bundleUrl: `${origin}/bundle/${index}`, bundleSha256: SHA(value), size: value.length, required: true, prefetch: false,
    })),
  }
}

function envelope(item = snapshot()) {
  return { selectionSchemaVersion: 1, env: item.env, hostApp: item.hostApp, platform: item.platform, bundleLists: [item], directives: [] }
}

async function mockHttp(t) {
  const bytes = [Buffer.from('unit-bundle-1'), Buffer.from('unit-bundle-2')]
  const requests = []
  let transform = (body) => body
  let origin
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, origin)
    requests.push({ path: url.pathname, query: Object.fromEntries(url.searchParams), headers: request.headers })
    if (url.pathname === '/api/ota/v1/releases/latest-bundle-list') {
      const body = transform(envelope(snapshot({ platform: url.searchParams.get('platform'), origin, bytes })))
      response.writeHead(200, { 'content-type': 'application/json' })
      response.end(JSON.stringify(body))
    } else if (/^\/bundle\/[01]$/.test(url.pathname)) {
      response.writeHead(200, { 'content-type': 'application/octet-stream' })
      response.end(bytes[Number(url.pathname.at(-1))])
    } else {
      response.writeHead(404)
      response.end()
    }
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  origin = `http://127.0.0.1:${server.address().port}`
  t.after(async () => { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)) })
  return { origin, requests, bytes, change: (callback) => { transform = callback } }
}

test('C22 versioncode normalization matches positive decimal int64 semantics without Number rounding', () => {
  assert.equal(normalizeVersionCode(' 000150 '), '150')
  assert.equal(normalizeVersionCode('0009007199254740993'), '9007199254740993')
  assert.equal(normalizeVersionCode('9223372036854775807'), '9223372036854775807')
  for (const invalid of ['', '0', '000', '-1', '+1', '1.2', '1e3', '0xff', '1_000', '１２', '9223372036854775808', null, 150]) {
    assert.throws(() => normalizeVersionCode(invalid), TypeError)
  }
})

test('C22 SDK normalization pads stable numeric components and rejects unsupported formats', () => {
  for (const [raw, normalized] of [['4', '4.0.0'], ['4.10', '4.10.0'], [' 004.009.000 ', '4.9.0'], ['0', '0.0.0']]) {
    assert.equal(normalizeLynxSdkVersion(raw), normalized)
  }
  for (const invalid of ['', '4-beta', '4.0.0+build', 'v4', '4.*', '^4', '-4', '4..1', '4.0.0.1', '4.1e3', null, 4]) {
    assert.throws(() => normalizeLynxSdkVersion(invalid), TypeError)
  }
})

test('C22 version parameters are mandatory and platform defaults to target with no downgrade', () => {
  assert.throws(() => parseArgs(['--base-url', 'https://api.example.invalid', '--lynx-sdk-version', '4'], TEST_ENV), /--versioncode/)
  assert.throws(() => parseArgs(['--base-url', 'https://api.example.invalid', '--versioncode', '1'], TEST_ENV), /--lynx-sdk-version/)
  for (const target of ['android', 'ios', 'harmony']) {
    const parsed = parseArgs(argv({ target, versioncode: '000150', sdk: '4' }), TEST_ENV)
    assert.equal(parsed.platform, target)
    assert.equal(parsed.versioncode, '150')
    assert.equal(parsed.lynxSdkVersion, '4.0.0')
    assert.equal(parseArgs([...argv({ target }), '--platform', target], TEST_ENV).platform, target)
    for (const other of ['android', 'ios', 'harmony'].filter((platform) => platform !== target)) {
      assert.throws(() => parseArgs([...argv({ target }), '--platform', other], TEST_ENV), /必须与 --target 一致/)
    }
  }
  assert.throws(() => parseArgs(argv({ target: 'harmonyos' }), TEST_ENV), /不支持的 target/)
})

test('C22 downloader remains anonymous and does not accept userId or per-App selection', () => {
  for (const extra of [['--userId', 'private-test-user'], ['--user-id', 'private-test-user'], ['userId=private-test-user'], ['--app-id', '10000001']]) {
    assert.throws(() => parseArgs([...argv(), ...extra], TEST_ENV), /不接受 userId 或指定 App ID/)
  }
  assert.throws(() => parseArgs(argv({ baseUrl: 'https://api.example.invalid?userId=private-test-user' }), TEST_ENV), /必须匿名/)
})

test('C22 HTTP requires explicit loopback allowance and never weakens production HTTPS', () => {
  assert.equal(validateTransportUrl('https://cdn.example.invalid/bundle', false).protocol, 'https:')
  for (const origin of ['http://127.0.0.1:1234', 'http://127.12.0.1', 'http://localhost:1234', 'http://[::1]:1234']) {
    assert.throws(() => validateTransportUrl(origin), /HTTPS/)
    assert.equal(validateTransportUrl(origin, true).protocol, 'http:')
  }
  for (const url of ['http://example.invalid', 'http://10.0.2.2', 'http://192.168.1.1', 'http://localhost.example.invalid', 'file:///tmp/bundle', 'https://name:password@example.invalid']) {
    assert.throws(() => validateTransportUrl(url, true))
  }
  assert.throws(() => parseArgs(argv({ baseUrl: 'http://127.0.0.1:1234' }), TEST_ENV), /HTTPS/)
  assert.equal(parseArgs(argv({ baseUrl: 'http://127.0.0.1:1234', local: true }), TEST_ENV).allowLocalHttp, true)
})

test('C22 exact anonymous HTTP query and complete embedded manifests use isolated outputs for all targets', async (t) => {
  const mock = await mockHttp(t)
  for (const target of ['ios', 'android', 'harmony']) {
    const output = temporaryOutput(t, target)
    const result = await syncOtaBundles(argv({ baseUrl: mock.origin, target, versioncode: ' 000150 ', sdk: '4', outputDirectory: output.root, local: true }), TEST_ENV)
    assert.equal(result.embeddedRoot, output.embeddedRoot)
    const manifest = JSON.parse(fs.readFileSync(path.join(output.embeddedRoot, 'embedded-bundles.json')))
    assert.equal(manifest.schemaVersion, 1)
    assert.equal(manifest.apps.length, 1)
    assert.equal(manifest.apps[0].bundles.length, 2)
    for (const [index, bundle] of manifest.apps[0].bundles.entries()) {
      const bytes = fs.readFileSync(path.join(output.embeddedRoot, '10000001/releases/full_fixture', bundle.bundlePath))
      assert.deepEqual(bytes, mock.bytes[index])
      assert.equal(bundle.sha256, SHA(bytes))
    }
    const request = mock.requests.filter((item) => item.path === '/api/ota/v1/releases/latest-bundle-list').at(-1)
    assert.deepEqual(request.query, { env: 'TEST', hostApp: 'capp', platform: target, versioncode: '150', lynxSdkVersion: '4.0.0' })
    assert.equal(request.headers['x-ota-client-token'], TEST_ENV.LYNX_OTA_CLIENT_TOKEN)
  }
  for (const request of mock.requests.filter((item) => item.path.startsWith('/bundle/'))) {
    assert.equal(request.headers['x-ota-client-token'], undefined)
    assert.equal(request.headers.authorization, undefined)
    assert.deepEqual(request.query, {})
  }
})

test('C22 rejects old/gray/directive/empty/wrong-scope responses before touching existing output', async (t) => {
  const mock = await mockHttp(t)
  const output = temporaryOutput(t)
  const mutations = [
    (body) => ({ ...body, selectionSchemaVersion: undefined }),
    (body) => ({ ...body, bundleLists: [] }),
    (body) => ({ ...body, directives: [{ lynxAppId: '10000002', action: 'no_compatible_release', policyRevision: '2', reason: 'none' }] }),
    (body) => ({ ...body, directives: [{ lynxAppId: '10000001', action: 'use_embedded', policyRevision: '2', reason: 'fallback' }] }),
    (body) => ({ ...body, directives: undefined }),
    (body) => ({ ...body, platform: 'android' }),
    (body) => ({ ...body, bundleLists: [{ ...body.bundleLists[0], platform: 'android' }] }),
    (body) => ({ ...body, bundleLists: [{ ...body.bundleLists[0], selection: { kind: 'gray', policyRevision: '3' } }] }),
    (body) => ({ ...body, bundleLists: [body.bundleLists[0], { ...body.bundleLists[0], lynxAppId: '10000002', selection: { kind: 'gray', policyRevision: '3' } }] }),
    (body) => ({ ...body, bundleLists: [{ ...body.bundleLists[0], status: 'DRAFT' }] }),
    (body) => ({ ...body, bundleLists: [{ ...body.bundleLists[0], releaseId: '..' }] }),
  ]
  for (const change of mutations) {
    mock.change(change)
    await assert.rejects(() => syncOtaBundles(argv({ baseUrl: mock.origin, outputDirectory: output.root, local: true }), TEST_ENV))
    assert.equal(fs.readFileSync(output.sentinel, 'utf8'), 'keep-existing-baseline')
    assert.deepEqual(fs.readdirSync(output.root), ['lynx'])
  }
  assert.equal(mock.requests.filter((item) => item.path.startsWith('/bundle/')).length, 0)
})

test('C22 native and SDK ranges are inclusive, conjunctive and preserve integer precision', () => {
  const options = parseArgs(argv({ sdk: '4.10' }), TEST_ENV)
  const constrained = { ...snapshot(), versionCodeRange: { min: '120', max: '199' }, lynxSdkRange: { min: '4.9', max: '4.10' } }
  for (const versioncode of ['120', '199']) {
    assert.equal(parseLatestBundleLists(envelope(constrained), { ...options, versioncode }).length, 1)
  }
  for (const context of [{ versioncode: '119' }, { versioncode: '200' }, { lynxSdkVersion: '4.8.0' }, { lynxSdkVersion: '4.10.1' }]) {
    assert.throws(() => parseLatestBundleLists(envelope(constrained), { ...options, ...context }), /范围不兼容/)
  }
  const large = { ...snapshot(), versionCodeRange: { min: '9007199254740993', max: '9007199254740993' } }
  assert.equal(parseLatestBundleLists(envelope(large), { ...options, versioncode: '9007199254740993' }).length, 1)
  assert.throws(() => parseLatestBundleLists(envelope(large), { ...options, versioncode: '9007199254740992' }), /范围不兼容/)
  for (const range of [{ min: '0' }, { min: '199', max: '120' }, { max: '9223372036854775808' }, null, 'invalid', { other: '1' }]) {
    assert.throws(() => parseLatestBundleLists(envelope({ ...snapshot(), versionCodeRange: range }), options), /范围不兼容/)
  }
  for (const range of [{ min: '4-beta' }, { min: '4.10', max: '4.9' }]) {
    assert.throws(() => parseLatestBundleLists(envelope({ ...snapshot(), lynxSdkRange: range }), options), /范围不兼容/)
  }
  assert.equal(parseLatestBundleLists(envelope({ ...snapshot(), versionCodeRange: {}, lynxSdkRange: {} }), options).length, 1)
})

test('C22 failed bundle verification keeps the previous baseline and removes only temporary staging', async (t) => {
  const mock = await mockHttp(t)
  const output = temporaryOutput(t)
  mock.change((body) => { body.bundleLists[0].changedBundles[1].bundleSha256 = `sha256:${'0'.repeat(64)}`; return body })
  await assert.rejects(() => syncOtaBundles(argv({ baseUrl: mock.origin, outputDirectory: output.root, local: true }), TEST_ENV), /SHA-256 校验失败/)
  assert.equal(fs.readFileSync(output.sentinel, 'utf8'), 'keep-existing-baseline')
  assert.deepEqual(fs.readdirSync(output.root), ['lynx'])
  assert.equal(mock.requests.filter((item) => item.path.startsWith('/bundle/')).length, 2)
})

test('C22 dry-run downloads complete snapshots without replacing any existing embedded files', async (t) => {
  const mock = await mockHttp(t)
  const output = temporaryOutput(t)
  const result = await syncOtaBundles(argv({ baseUrl: mock.origin, outputDirectory: output.root, local: true, dryRun: true }), TEST_ENV)
  assert.equal(result.dryRun, true)
  assert.equal(result.apps[0].bundles.length, 2)
  assert.equal(fs.readFileSync(output.sentinel, 'utf8'), 'keep-existing-baseline')
  assert.deepEqual(fs.readdirSync(output.root), ['lynx'])
})

test('C22 CLI entry runs using only Node builtins and a temporary output directory', async (t) => {
  const mock = await mockHttp(t)
  const output = temporaryOutput(t)
  const result = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [SCRIPT, ...argv({ baseUrl: mock.origin, outputDirectory: output.root, local: true })], {
      env: TEST_ENV, stdio: ['ignore', 'pipe', 'pipe'],
    })
    let stdout = ''
    let stderr = ''
    child.stdout.on('data', (chunk) => { stdout += chunk })
    child.stderr.on('data', (chunk) => { stderr += chunk })
    child.on('error', reject)
    child.on('close', (code) => resolve({ code, stdout, stderr }))
  })
  assert.equal(result.code, 0, result.stderr)
  assert.equal(result.stdout.includes(TEST_ENV.LYNX_OTA_CLIENT_TOKEN), false)
  assert.ok(fs.existsSync(path.join(output.embeddedRoot, 'embedded-bundles.json')))
})

test('C22 real Server anonymously embeds only compatible full 100-bundle releases and preserves output on directives', {
  skip: process.env.OTA_C22_SERVER_MODULE ? false : '设置 OTA_C22_SERVER_MODULE 指向隔离编译后的真实 Server dist/app.js',
}, async (t) => {
  const { createFixtureAdapter, CLIENT_TOKEN, CONTROL_HEADER, CONTROL_VALUE } = await import('../../../scripts/ota-user-gray/server.mjs')
  const adapter = await createFixtureAdapter({ serverModule: process.env.OTA_C22_SERVER_MODULE, port: 0 })
  t.after(() => adapter.close())
  // 下载器必须拒绝混有 directives 的全量替换。独立 host 排除无发布的种子 App，
  // selection 仍交给真实 createApp；原 fixture 仅提供实际编译 Bundle 字节。
  const { createApp } = await import(pathToFileURL(path.resolve(process.env.OTA_C22_SERVER_MODULE)).href)
  const app = await createApp()
  app.log.level = 'silent'
  t.after(() => app.close())
  const login = await app.inject({ method: 'POST', url: '/api/admin/ota/auth/login', payload: { username: 'fixture-admin', password: 'fixture-local-password' } })
  assert.equal(login.statusCode, 200)
  const adminHeaders = { authorization: `Bearer ${login.json().token}` }
  async function admin(method, url, payload, expectedStatus = 200) {
    const response = await app.inject({ method, url, payload, headers: adminHeaders })
    assert.equal(response.statusCode, expectedStatus, response.body)
    return response.json()
  }
  const scope = { env: 'TEST', hostApp: 'c22-tool-test', lynxAppId: '10000001' }
  await admin('POST', '/api/admin/ota/host-apps', { hostApp: scope.hostApp, name: 'C22 isolated tool test' }, 201)
  await admin('POST', '/api/admin/ota/lynx-apps', { hostApp: scope.hostApp, lynxAppId: scope.lynxAppId, name: 'C22 test app' }, 201)
  const latestRequests = []
  const proxy = http.createServer(async (request, response) => {
    const parsed = new URL(request.url, 'http://127.0.0.1')
    latestRequests.push(Object.fromEntries(parsed.searchParams))
    const result = await app.inject({ method: request.method, url: request.url, headers: { 'x-ota-client-token': request.headers['x-ota-client-token'] } })
    response.writeHead(result.statusCode, { 'content-type': result.headers['content-type'] || 'application/json' })
    response.end(result.rawPayload)
  })
  await new Promise((resolve) => proxy.listen(0, '127.0.0.1', resolve))
  t.after(async () => { proxy.closeAllConnections(); await new Promise((resolve) => proxy.close(resolve)) })
  const apiOrigin = `http://127.0.0.1:${proxy.address().port}`
  const output = temporaryOutput(t)
  const env = { LYNX_OTA_CLIENT_TOKEN: CLIENT_TOKEN }
  async function control(endpoint, body) {
    const response = await fetch(`${adapter.origin}/_fixture/${endpoint}`, {
      method: body === undefined ? 'GET' : 'POST', headers: { [CONTROL_HEADER]: CONTROL_VALUE, 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
    assert.equal(response.status, 200)
    return response.json()
  }
  async function fixtureSnapshot(userId) {
    const query = new URLSearchParams({ env: 'TEST', hostApp: 'capp', lynxAppId: '10000001', platform: 'ios', versioncode: '150', lynxSdkVersion: '4.0.0' })
    if (userId) query.set('userId', userId)
    const response = await fetch(`${adapter.origin}/api/ota/v1/releases/latest-bundle-list?${query}`, { headers: { 'x-ota-client-token': CLIENT_TOKEN } })
    assert.equal(response.status, 200)
    return response.json()
  }
  const fullSnapshot = await fixtureSnapshot()
  const full = (await admin('POST', '/api/admin/ota/releases', {
    ...scope, platforms: ['ios'], createdBy: 'fixture-admin', versionCodeRange: { min: '1', max: '999' },
    lynxSdkRange: { min: '4', max: '4' }, changedBundles: fullSnapshot.changedBundles,
  }, 201)).data[0]
  await admin('POST', `/api/admin/ota/releases/${full.releaseId}/publish`, { type: 'full' })
  await control('stage', { stage: 'gray6' })
  const graySnapshot = await fixtureSnapshot('user_demo_A')
  const gray = (await admin('POST', '/api/admin/ota/releases', {
    ...scope, platforms: ['ios'], createdBy: 'fixture-admin', changedBundles: graySnapshot.changedBundles,
    versionCodeRange: { min: '1', max: '999' }, lynxSdkRange: { min: '4', max: '4' },
  }, 201)).data[0]
  await admin('POST', '/api/admin/ota/rules', { ...scope, ruleId: 'c22-gray-rule', userWhitelist: ['user_demo_A'], targetReleaseId: gray.releaseId }, 201)
  await admin('POST', `/api/admin/ota/releases/${gray.releaseId}/publish`, { type: 'gray', ruleId: 'c22-gray-rule' })
  const grayResponse = await app.inject({ method: 'GET', url: `/api/ota/v1/releases/latest-bundle-list?${new URLSearchParams({ ...scope, platform: 'ios', versioncode: '150', lynxSdkVersion: '4', userId: 'user_demo_A' })}`, headers: { 'x-ota-client-token': CLIENT_TOKEN } })
  assert.equal(grayResponse.json().releaseId, gray.releaseId)
  await control('metrics/reset', {})
  const downloadArgs = (versioncode = '150') => [...argv({ baseUrl: apiOrigin, outputDirectory: output.root, local: true, versioncode }), '--host-app', scope.hostApp]
  const result = await syncOtaBundles(downloadArgs(), env)
  assert.equal(result.apps[0].releaseId, full.releaseId)
  assert.equal(result.apps[0].bundles.length, 100)
  const manifestFile = path.join(output.embeddedRoot, 'embedded-bundles.json')
  const manifest = JSON.parse(fs.readFileSync(manifestFile))
  assert.equal(manifest.apps[0].bundles.length, 100)
  for (const bundle of manifest.apps[0].bundles) {
    const bytes = fs.readFileSync(path.join(output.embeddedRoot, '10000001/releases', result.apps[0].releaseId, bundle.bundlePath))
    assert.equal(bytes.length, bundle.size)
    assert.equal(SHA(bytes), bundle.sha256)
  }
  const metrics = await control('metrics')
  assert.equal(metrics.latestRequestCount, 0, '字节 fixture 不参与这次版本选择')
  assert.equal(metrics.bundleRequestCount, 100)
  assert.deepEqual(latestRequests, [{ env: 'TEST', hostApp: scope.hostApp, platform: 'ios', versioncode: '150', lynxSdkVersion: '4.0.0' }])
  assert.ok(metrics.requests.filter((item) => item.kind === 'bundle').every((item) => !item.clientTokenPresent && !item.userQueryPresent))

  const before = fs.readFileSync(manifestFile, 'utf8')
  await assert.rejects(() => syncOtaBundles(downloadArgs('1000'), env), /指令/)
  assert.equal(fs.readFileSync(manifestFile, 'utf8'), before)
  await admin('POST', '/api/admin/ota/policies/fallback', { ...scope, enabled: true, platform: 'ios' })
  await assert.rejects(() => syncOtaBundles(downloadArgs(), env), /指令/)
  assert.equal(fs.readFileSync(manifestFile, 'utf8'), before)
  assert.equal((await control('metrics')).bundleRequestCount, 100)
})
