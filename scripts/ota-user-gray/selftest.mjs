#!/usr/bin/env node
import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import test, { after } from 'node:test'
import { setTimeout as pause } from 'node:timers/promises'
import { ALIASES, BUNDLE_NAME, DEFAULT_FIXTURE, loadUserGrayFixture } from '../../playground/scripts/generate-ota-user-gray-fixture.mjs'
import { CLIENT_TOKEN, CONTROL_HEADER, CONTROL_VALUE, createFixtureAdapter, USER_A, USER_B } from './server.mjs'

const options = { fixture: DEFAULT_FIXTURE, port: 0 }
const transportEvidence = []
for (let index = 2; index < process.argv.length; index++) {
  const key = { '--server-module': 'serverModule', '--fixture': 'fixture' }[process.argv[index]]
  if (!key || !process.argv[index + 1]) throw new Error('用法: node scripts/ota-user-gray/selftest.mjs --server-module /absolute/server/dist/app.js [--fixture DIR]')
  options[key] = process.argv[++index]
}
if (!options.serverModule) throw new Error('必须指定真实 Server 的 --server-module')
after(() => {
  const report = path.join(options.fixture, 'transport-selftest-evidence.json')
  fs.writeFileSync(report, `${JSON.stringify({
    serverModule: path.resolve(options.serverModule), fixture: path.resolve(options.fixture),
    boundary: '真实 Server 与 HTTP Bundle 传输；下载去重由测试客户端 SHA Set 模拟，不代表 Native Store/设备验收。',
    observations: transportEvidence,
  }, null, 2)}\n`)
  console.log(`Transport evidence: ${report}`)
})

async function harness(t, extra = {}) {
  const adapter = await createFixtureAdapter({ ...options, ...extra })
  t.after(() => adapter.close())
  async function control(endpoint, body) {
    const response = await fetch(`${adapter.origin}/_fixture/${endpoint}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { [CONTROL_HEADER]: CONTROL_VALUE, 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
    const data = await response.json()
    assert.equal(response.status, 200, JSON.stringify(data))
    return data
  }
  function latest(query = {}, headers = {}) {
    const params = new URLSearchParams({ env: 'TEST', hostApp: 'capp', lynxAppId: '10000001', platform: 'ios', versioncode: '150', lynxSdkVersion: '4.0.0', ...query })
    for (const [key, value] of Object.entries(query)) if (value === undefined) params.delete(key)
    return fetch(`${adapter.origin}/api/ota/v1/releases/latest-bundle-list?${params}`, { headers: { 'x-ota-client-token': CLIENT_TOKEN, ...headers } })
  }
  const initial = await control('state')
  async function selected(alias, userId, query = {}, headers = {}) {
    const response = await latest({ userId, ...query }, headers)
    assert.equal(response.status, 200)
    const data = await response.json()
    assert.equal(data.selectionSchemaVersion, 1)
    assert.equal(data.releaseId, initial.actualReleaseIds[alias])
    assert.equal(data.releaseSequence, initial.actualReleaseSequences[alias])
    assert.equal(data.changedBundles.length, 100)
    assert.equal(data.changedBundles[50].bundlePath, BUNDLE_NAME)
    return { data, etag: response.headers.get('etag') }
  }
  return { ...adapter, control, latest, selected, initial }
}

test('fixture verifies 100 actual bundles per stage, 99 shared bytes and 103 unique objects', () => {
  const fixture = loadUserGrayFixture(options.fixture)
  assert.equal(fixture.objects.size, 103)
  assert.equal(fixture.metadata.buildEvidence.compiledMarkerCount, 4)
  for (const alias of ALIASES) {
    assert.equal(fixture.metadata.versions[alias].visibleMarker, `${alias.toUpperCase()}-050`)
    assert.equal(fixture.metadata.versions[alias].bundles.length, 100)
  }
})

test('real Server stages select full5/gray6/full7/gray8 for A, B and anonymous using actual sequences', async (t) => {
  const h = await harness(t)
  const sequences = ALIASES.map((alias) => BigInt(h.initial.actualReleaseSequences[alias]))
  assert.ok(sequences.every((sequence, index) => index === 0 || sequence > sequences[index - 1]))
  const expectations = { full5: ['full5', 'full5', 'full5'], gray6: ['gray6', 'full5', 'full5'], full7: ['full7', 'full7', 'full7'], gray8: ['gray8', 'full7', 'full7'] }
  for (const alias of ALIASES) {
    const stage = await h.control('stage', { stage: alias })
    assert.equal(stage.expectedReleaseId, h.initial.actualReleaseIds[expectations[alias][0]])
    assert.deepEqual(stage.expectedReleaseIds, Object.fromEntries(['A', 'B', 'anonymous'].map((label, index) => [label, h.initial.actualReleaseIds[expectations[alias][index]]])))
    for (const [index, user] of [USER_A, USER_B, undefined].entries()) {
      const expected = expectations[alias][index]
      const { data } = await h.selected(expected, user)
      assert.equal(data.selection.kind, expected.startsWith('gray') ? 'gray' : 'full')
    }
  }
  const group = await h.latest({ userId: USER_A, lynxAppId: undefined })
  assert.equal(group.status, 200)
  const body = await group.json()
  assert.equal(body.selectionSchemaVersion, 1)
  assert.equal(body.bundleLists.find((item) => item.lynxAppId === '10000001').releaseId, h.initial.actualReleaseIds.gray8)
  assert.ok(Array.isArray(body.directives))
})

test('real Server handles normalization, precise bounds and ETag context without seed fallback', async (t) => {
  const h = await harness(t)
  await h.control('stage', { stage: 'gray6' })
  const normalized = await h.selected('gray6', ` ${USER_A} `, { versioncode: ' 000150 ', lynxSdkVersion: '4' })
  const cached = await h.latest({ userId: USER_A }, { 'if-none-match': normalized.etag })
  assert.equal(cached.status, 304)
  assert.equal(await cached.text(), '')
  await h.selected('full5', USER_B, {}, { 'if-none-match': normalized.etag })
  await h.selected('full5', 'USER_DEMO_A')
  await h.selected('full5', '   ')
  for (const platform of ['ios', 'android', 'harmony']) {
    for (const versioncode of ['1', '999']) await h.selected('gray6', USER_A, { platform, versioncode })
    for (const query of [{ versioncode: '1000' }, { lynxSdkVersion: '3.9' }, { lynxSdkVersion: '4.1' }]) {
      const response = await h.latest({ userId: USER_A, platform, ...query })
      assert.equal(response.status, 200)
      assert.equal((await response.json()).decision.action, 'no_compatible_release')
    }
  }
  for (const query of [{ versioncode: '0' }, { versioncode: '1e3' }, { versioncode: '9223372036854775808' }, { lynxSdkVersion: '4-beta' }, { versioncode: undefined }, { userId: 'private-account\n' }]) {
    const response = await h.latest(query)
    assert.equal(response.status, 400)
    assert.equal((await response.text()).includes('private-account'), false)
  }
})

test('latest metrics retain normalized synthetic version context without raw identity, token or invalid values', async (t) => {
  const h = await harness(t)
  await h.control('metrics/reset', {})
  await h.selected('full5', ` ${USER_A} `, { versioncode: ' 000150 ', lynxSdkVersion: '004.000.00' })
  await h.selected('full5', USER_B, { versioncode: '0001', lynxSdkVersion: '4' })
  const group = await h.latest({ userId: undefined, lynxAppId: undefined, versioncode: '00999', lynxSdkVersion: '4.0' })
  assert.equal(group.status, 200)
  await group.json()
  const metrics = await h.control('metrics')
  assert.deepEqual(metrics.requests.map(({ audience, scope, versioncode, lynxSdkVersion }) => ({ audience, scope, versioncode, lynxSdkVersion })), [
    { audience: 'A', scope: 'single', versioncode: '150', lynxSdkVersion: '4.0.0' },
    { audience: 'B', scope: 'single', versioncode: '1', lynxSdkVersion: '4.0.0' },
    { audience: 'anonymous', scope: 'all', versioncode: '999', lynxSdkVersion: '4.0.0' },
  ])
  for (const query of [
    { versioncode: 'invalid-native-private' }, { lynxSdkVersion: 'invalid-sdk-private' },
    { versioncode: undefined, lynxSdkVersion: undefined }, { userId: 'synthetic-unrecognized-account' },
  ]) {
    const response = await h.latest(query)
    await response.text()
  }
  for (const repeated of ['versioncode=151', `userId=${USER_B}`]) {
    const query = new URLSearchParams({ env: 'TEST', hostApp: 'capp', lynxAppId: '10000001', platform: 'ios', versioncode: '150', lynxSdkVersion: '4.0.0', userId: USER_A })
    const response = await fetch(`${h.origin}/api/ota/v1/releases/latest-bundle-list?${query}&${repeated}`, { headers: { 'x-ota-client-token': CLIENT_TOKEN } })
    assert.equal(response.status, 400)
    await response.text()
  }
  const final = await h.control('metrics')
  const contexts = final.requests.slice(3).map(({ versioncode, lynxSdkVersion }) => ({ versioncode, lynxSdkVersion }))
  assert.deepEqual(contexts, [
    { versioncode: undefined, lynxSdkVersion: '4.0.0' },
    { versioncode: '150', lynxSdkVersion: undefined },
    { versioncode: undefined, lynxSdkVersion: undefined },
    { versioncode: undefined, lynxSdkVersion: undefined },
    { versioncode: undefined, lynxSdkVersion: '4.0.0' },
    { versioncode: undefined, lynxSdkVersion: undefined },
  ])
  assert.equal(final.latestRequestCount, 9)
  const serialized = JSON.stringify(final)
  for (const raw of [USER_A, USER_B, CLIENT_TOKEN, 'invalid-native-private', 'invalid-sdk-private', 'synthetic-unrecognized-account']) {
    assert.equal(serialized.includes(raw), false)
  }
  for (const entry of final.requests) {
    assert.equal(Object.hasOwn(entry, 'userId'), false)
    assert.equal(Object.hasOwn(entry, 'token'), false)
    assert.equal(Object.hasOwn(entry, 'url'), false)
  }
})

test('real HTTP bundle counters measure 100 downloads then exactly one changed object per stage', async (t) => {
  const h = await harness(t)
  const downloaded = new Set()
  async function fetchMissing(snapshot) {
    const fetched = []
    for (const bundle of snapshot.changedBundles) {
      if (downloaded.has(bundle.bundleSha256)) continue
      const url = new URL(bundle.bundleUrl)
      assert.equal(url.origin, h.origin)
      assert.equal(url.search, '')
      const response = await fetch(url)
      assert.equal(response.status, 200)
      const bytes = Buffer.from(await response.arrayBuffer())
      assert.equal(bytes.length, bundle.size)
      assert.equal(`sha256:${crypto.createHash('sha256').update(bytes).digest('hex')}`, bundle.bundleSha256)
      downloaded.add(bundle.bundleSha256)
      fetched.push(bundle)
    }
    return fetched
  }
  await h.control('metrics/reset', {})
  let current = await h.selected('full5')
  const initial = await fetchMissing(current.data)
  assert.equal(initial.length, 100)
  let metrics = await h.control('metrics')
  assert.equal(metrics.latestRequestCount, 1)
  assert.equal(metrics.bundleRequestCount, 100)
  assert.equal(metrics.bundleSuccessCount, 100)
  assert.equal(metrics.bundleBytes, initial.reduce((sum, bundle) => sum + bundle.size, 0))
  transportEvidence.push({ stage: 'full5', latestRequestCount: metrics.latestRequestCount, bundleRequestCount: metrics.bundleRequestCount, bundleBytes: metrics.bundleBytes, uniqueDownloadedObjects: downloaded.size })
  for (const stage of ['gray6', 'full7', 'gray8']) {
    await h.control('stage', { stage })
    await h.control('metrics/reset', {})
    current = await h.selected(stage, USER_A)
    const fetched = await fetchMissing(current.data)
    assert.deepEqual(fetched.map((bundle) => bundle.bundlePath), [BUNDLE_NAME])
    metrics = await h.control('metrics')
    assert.equal(metrics.latestRequestCount, 1)
    assert.equal(metrics.bundleRequestCount, 1)
    assert.equal(metrics.bundleSuccessCount, 1)
    assert.equal(metrics.bundleBytes, fetched[0].size)
    assert.equal(metrics.requests.find((item) => item.kind === 'bundle').clientTokenPresent, false)
    assert.equal(metrics.requests.find((item) => item.kind === 'bundle').userQueryPresent, false)
    transportEvidence.push({ stage, latestRequestCount: metrics.latestRequestCount, bundleRequestCount: metrics.bundleRequestCount, bundleBytes: metrics.bundleBytes, uniqueDownloadedObjects: downloaded.size })
  }
  assert.equal(downloaded.size, 103)
  const grayEtag = current.etag
  await h.control('publish', { alias: 'gray8', type: 'full' })
  await h.control('metrics/reset', {})
  const promoted = await h.selected('gray8', USER_A, {}, { 'if-none-match': grayEtag })
  assert.equal(promoted.data.selection.kind, 'full')
  assert.notEqual(promoted.etag, grayEtag)
  assert.equal((await fetchMissing(promoted.data)).length, 0)
  metrics = await h.control('metrics')
  assert.equal(metrics.bundleRequestCount, 0)
  assert.equal(metrics.bundleBytes, 0)
  transportEvidence.push({ stage: 'gray8-to-full-same-release', latestRequestCount: metrics.latestRequestCount, bundleRequestCount: metrics.bundleRequestCount, bundleBytes: metrics.bundleBytes, uniqueDownloadedObjects: downloaded.size })
})

test('A delay captures the actual old gray response before B and newer full complete', async (t) => {
  const h = await harness(t)
  await h.control('stage', { stage: 'gray6' })
  await h.control('metrics/reset', {})
  await h.control('delay-latest', { audience: 'A', count: 1, milliseconds: 0 })
  let aFinished = false
  const aPromise = h.latest({ userId: USER_A }).then(async (response) => { aFinished = true; assert.equal(response.status, 200); return response.json() })
  t.after(() => h.control('release-delays', {}).catch(() => {}))
  for (let attempt = 0; attempt < 100; attempt++) {
    const metrics = await h.control('metrics')
    if (metrics.pendingLatestCount === 1) break
    if (attempt === 99) assert.fail('A 请求没有进入捕获后的延迟队列')
    await pause(10)
  }
  assert.equal(aFinished, false)
  const heldState = await h.control('state')
  assert.equal(heldState.delay.pending[0].releaseAlias, 'gray6')
  await h.selected('full5', USER_B)
  assert.equal(aFinished, false)
  await h.control('stage', { stage: 'full7' })
  const b = await h.selected('full7', USER_B)
  await h.control('release-delays', {})
  const a = await aPromise
  assert.equal(a.releaseId, h.initial.actualReleaseIds.gray6)
  assert.ok(BigInt(a.selection.policyRevision) < BigInt(b.data.selection.policyRevision))
  const metrics = await h.control('metrics')
  assert.equal(metrics.latestRequestCount, 3)
  assert.equal(metrics.latestCompletedCount, 3)
  assert.equal(metrics.delayedLatestCount, 1)
  assert.equal(metrics.pendingLatestCount, 0)
  assert.equal(JSON.stringify(metrics).includes(USER_A), false)
  assert.equal(JSON.stringify(metrics).includes(USER_B), false)
})

test('real rule status, forced embedded and rollback controls change actual Server decisions', async (t) => {
  const h = await harness(t)
  await h.control('stage', { stage: 'gray8' })
  await h.control('rule', { alias: 'gray8', enabled: false })
  await h.selected('full7', USER_A)
  await h.control('rule', { alias: 'gray8', enabled: true })
  await h.selected('gray8', USER_A)
  await h.control('fallback', { enabled: true, platforms: ['ios'] })
  let response = await h.latest({ userId: USER_A })
  assert.equal((await response.json()).decision.action, 'use_embedded')
  await h.selected('gray8', USER_A, { platform: 'harmony' })
  await h.control('fallback', { enabled: false, platforms: ['ios'] })
  await h.control('rollback', { from: 'gray8', target: 'full5' })
  const old = await h.selected('full5', USER_A)
  assert.equal(old.data.selection.reason, 'server_rollback')
  await h.control('publish', { alias: 'full7', type: 'full' })
  await h.selected('full7', USER_A)
  await h.control('rollback', { from: 'full7', target: 'embedded' })
  response = await h.latest({ userId: USER_A })
  const stopped = await response.json()
  assert.equal(stopped.decision.action, 'use_embedded')
  assert.equal(stopped.decision.reason, 'server_rollback')
})

test('control endpoints require loopback control header and public API keeps real token validation', async (t) => {
  const h = await harness(t)
  assert.equal(h.server.address().address, '127.0.0.1')
  const denied = await fetch(`${h.origin}/_fixture/stage`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ stage: 'gray8' }) })
  assert.equal(denied.status, 403)
  const crossOrigin = await fetch(`${h.origin}/_fixture/state`, { headers: { [CONTROL_HEADER]: CONTROL_VALUE, origin: 'https://example.invalid' } })
  assert.equal(crossOrigin.status, 403)
  assert.equal((await h.control('state')).stage, 'full5')
  const unauthorized = await fetch(`${h.origin}/api/ota/v1/releases/latest-bundle-list?env=TEST&hostApp=capp`)
  assert.equal(unauthorized.status, 401)
  const admin = await fetch(`${h.origin}/api/admin/ota/releases`)
  assert.equal(admin.status, 404)
})

test('bundle origin can target Harmony emulator without changing real selection or loopback controls', async (t) => {
  const h = await harness(t, { bundleOrigin: 'http://10.0.2.2:18766' })
  const selected = await h.selected('full5', undefined, { platform: 'harmony' })
  assert.ok(selected.data.changedBundles.every((bundle) => new URL(bundle.bundleUrl).origin === 'http://10.0.2.2:18766'))
  assert.equal(h.initial.bundleOrigin, 'http://10.0.2.2:18766')
  assert.equal(h.server.address().address, '127.0.0.1')
})

test('fixture reset rebuilds real in-memory Server data, restores full5 and clears counts and controls', async (t) => {
  const h = await harness(t)
  await h.control('stage', { stage: 'gray8' })
  await h.control('fallback', { enabled: true })
  await h.control('delay-latest', { audience: 'A', count: 1, milliseconds: 0 })
  await h.latest({ userId: USER_B }).then((response) => response.json())
  const reset = await h.control('reset', {})
  assert.equal(reset.stage, 'full5')
  assert.equal(reset.generation, 1)
  assert.equal(reset.ready, true)
  assert.equal(reset.expectedReleaseId, reset.actualReleaseIds.full5)
  assert.equal(reset.aliases.gray8.status, 'DRAFT')
  assert.equal(reset.delay.count, 0)
  assert.deepEqual(reset.delay.pending, [])
  const metrics = await h.control('metrics')
  assert.equal(metrics.latestRequestCount, 0)
  assert.equal(metrics.bundleRequestCount, 0)
  assert.equal(metrics.bundleBytes, 0)
  await h.selected('full5', USER_A)
})
