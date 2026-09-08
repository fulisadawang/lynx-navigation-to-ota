#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import test, { after } from 'node:test';
import { setTimeout as pause } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { createArkTsHost } from './harmony-host-loader.mjs';
import { HOST_EVIDENCE_KIND } from './harmony-host-adapters.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const options = { mode: 'pure', output: path.join(ROOT, 'scripts/ota-user-gray/.generated', `harmony-host-${Date.now()}`) };
for (let index = 2; index < process.argv.length; index++) {
  const key = { '--mode': 'mode', '--output': 'output', '--server-origin': 'serverOrigin', '--typescript': 'typescript' }[process.argv[index]];
  if (process.argv[index] === '--help') {
    console.log('node scripts/ota-user-gray/harmony-host-tests.mjs [--mode pure|server|all] [--server-origin http://127.0.0.1:18770] [--output DIR] [--typescript /absolute/typescript/module]\n执行真实普通 .ets 源码，系统 API 由 Node adapters 提供；不执行 Hvigor/HDC/设备。server/all 会改变明确指定的本地 fixture 阶段。');
    process.exit(0);
  }
  if (!key || !process.argv[index + 1]) throw new Error('未知或缺少参数，使用 --help');
  options[key] = process.argv[++index];
}
if (!['pure', 'server', 'all'].includes(options.mode)) throw new Error('mode 只支持 pure/server/all');
if (options.mode !== 'pure' && !options.serverOrigin) throw new Error('server/all 必须显式指定 --server-origin');
options.output = path.resolve(options.output);
if (fs.existsSync(path.join(options.output, 'summary.json'))) throw new Error('输出已存在，请使用新目录保留历史证据');
fs.mkdirSync(options.output, { recursive: true });
const results = [];
const hosts = [];
const plain = (value) => JSON.parse(JSON.stringify(value));

function hostFor(t, server = false, overrides = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'lynx-harmony-host-'));
  const host = createArkTsHost({ directory, typescript: options.typescript, allowedOrigins: server ? [options.serverOrigin] : [], ...overrides });
  hosts.push(host);
  t.after(() => { host.close(); fs.rmSync(directory, { recursive: true, force: true }); });
  return host;
}

function checked(name, body) {
  test(name, async (t) => {
    const entry = { name, status: 'RUNNING', evidenceKind: HOST_EVIDENCE_KIND, deviceTested: false, nativeIOValidated: false };
    results.push(entry);
    try { await body(t, entry); entry.status = 'PASS'; }
    catch (error) { entry.status = 'FAIL'; entry.error = error.message; throw error; }
  });
}

function configFor(host, name = 'store', overrides = {}) {
  const { LynxOtaConfig } = host.load('ota/OtaModels.ets');
  const config = new LynxOtaConfig(options.serverOrigin ?? 'http://127.0.0.1:18770');
  Object.assign(config, { environment: 'TEST', hostApp: 'capp', platform: 'harmony', allowLocalHTTPForTest: true,
    versionCode: '150', lynxSdkVersion: '4.0.0', storageDirectory: path.join(host.root, name), ...overrides });
  config.validate(host.context);
  return config;
}

function sampleRelease(overrides = {}) {
  return {
    selectionSchemaVersion: 1, env: 'TEST', hostApp: 'capp', lynxAppId: '10000001', releaseId: 'host-fixture-full',
    platform: 'harmony', platforms: ['android', 'ios', 'harmony'], status: 'ACTIVE', releaseSequence: '9007199254740993',
    selection: { kind: 'full', policyRevision: '9007199254740994', reason: 'latest_full' },
    changedBundles: [{ pageId: 10000001, bundlePath: 'pages/10000001/main.lynx.bundle', bundleUrl: 'https://example.invalid/main.lynx.bundle', bundleSha256: `sha256:${'1'.repeat(64)}`, size: 16 }],
    ...overrides,
  };
}

async function fixtureControl(name, body) {
  const response = await fetch(new URL(`/_fixture/${name}`, options.serverOrigin), { method: body === undefined ? 'GET' : 'POST',
    headers: { 'x-ota-fixture-control': 'local-fixture-only', 'content-type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  assert.equal(response.status, 200); return response.json();
}

function realStore(host, name, overrides = {}) {
  const { OtaUserContextBox: Box } = host.load('ota/OtaUserContext.ets');
  const { OtaPrepareSignal: Signal } = host.load('ota/OtaModels.ets');
  const Api = host.load('ota/OtaApiClient.ets').default;
  const Store = host.load('ota/ContentAddressedOtaStore.ets').default;
  const config = configFor(host, name, { clientToken: 'ota-user-gray-local-client-token', ...overrides });
  const box = new Box(config); const api = new Api(config, null, box); const store = new Store(config, api, box);
  const current = () => {
    const prepared = store.acquireCurrentBundleLease('10000001', 'pages/10000001/bundle-050.lynx.bundle', box.capture());
    if (prepared === null) return null;
    const result = { releaseId: prepared.releaseId, source: prepared.source, selectionKind: prepared.selectionKind, userIdentityEpoch: prepared.userIdentityEpoch };
    prepared.lease?.close();
    return result;
  };
  const sync = async (captured = box.capture()) => {
    const signal = new Signal();
    const selected = await api.fetchLatestSelection('10000001', signal, captured);
    store.recordDecision('10000001', selected, captured);
    if (selected.release) await store.install(selected.release, signal, captured);
    return selected;
  };
  const state = () => JSON.parse(fs.readFileSync(path.join(config.storageDirectory, 'apps/10000001/state.json'), 'utf8'));
  return { config, box, api, store, current, sync, state };
}

if (options.mode !== 'server') {
  checked('实际 OtaUserContext：构建号规范化、int64 与超过 2^53 比较', (t) => {
    const host = hostFor(t);
    const { OtaUserContext: U } = host.load('ota/OtaUserContext.ets');
    assert.equal(U.normalizeVersionCode(' 000150 '), '150');
    assert.equal(U.normalizeVersionCode('9223372036854775807'), '9223372036854775807');
    assert.equal(U.compareDecimal('9007199254740993', '9007199254740992'), 1);
    for (const raw of ['0', '-1', '+1', '1.2', '1e3', '9223372036854775808']) assert.throws(() => U.normalizeVersionCode(raw));
  });

  checked('实际 OtaUserContext：稳定 SDK 数字段排序及 UTF-8 身份规范化', (t) => {
    const host = hostFor(t);
    const { OtaUserContext: U } = host.load('ota/OtaUserContext.ets');
    assert.equal(U.normalizeLynxSdkVersion('004.010'), '4.10.0');
    assert.equal(U.compareVersion('4.10', '4.9'), 1);
    for (const raw of ['4-beta', '4.0.0+build', '4.*', '4.0.0.1']) assert.throws(() => U.normalizeLynxSdkVersion(raw));
    assert.equal(U.normalizeUserId(' 000AbC '), '000AbC');
    assert.equal(U.normalizeUserId('   '), undefined);
    assert.equal(U.normalizeUserId('😀'.repeat(64)), '😀'.repeat(64));
    assert.throws(() => U.normalizeUserId('😀'.repeat(65)));
    assert.throws(() => U.normalizeUserId('synthetic\n'));
    assert.deepEqual(Buffer.from(U.utf8('用😀\ud800')), Buffer.from('用😀\ud800'));
  });

  checked('实际 ContextBox：同身份幂等，旧 epoch/旧 owner 操作拒绝', (t) => {
    const host = hostFor(t);
    const { OtaUserContextBox: Box } = host.load('ota/OtaUserContext.ets');
    const config = configFor(host);
    const box = new Box(config);
    const anonymous = box.capture();
    assert.equal(box.registerUserId(undefined), false);
    assert.equal(box.identityEpoch, 0);
    assert.equal(box.registerUserId('user_demo_A'), true);
    const a = box.capture();
    assert.equal(box.registerUserId(' user_demo_A '), false);
    assert.equal(box.identityEpoch, 1);
    box.registerUserId('user_demo_B');
    assert.throws(() => box.validate(a), /stale_identity/);
    assert.throws(() => box.capture(a.identityEpoch), /stale_identity/);
    assert.throws(() => box.validate(anonymous), /stale_identity/);
    const otherOwner = new Box(config).capture();
    assert.throws(() => box.validate(otherOwner), /stale_identity/);
    const b = box.capture();
    box.invalidate();
    assert.throws(() => box.validate(b), /stale_identity/);
  });

  checked('实际 ContextBox：盐在宿主 FS 持久化，同根冷 Context 归属稳定', (t) => {
    const host = hostFor(t);
    const { OtaUserContextBox: Box } = host.load('ota/OtaUserContext.ets');
    const config = configFor(host, 'salt-store', { userId: 'user_demo_A' });
    const first = new Box(config).capture();
    const cold = new Box(config).capture();
    assert.notEqual(first.ownerId, cold.ownerId);
    assert.equal(first.audienceKey, cold.audienceKey);
    assert.equal(first.clientContextKey, cold.clientContextKey);
    assert.notEqual(first.audienceKey, new Box(configFor(host, 'other-store', { userId: 'user_demo_A' })).capture().audienceKey);
    const disk = fs.readFileSync(path.join(config.storageDirectory, 'selection-salt'), 'utf8');
    assert.match(disk, /^[0-9a-f]{64}$/);
    assert.equal(disk.includes('user_demo_A'), false);
    fs.writeFileSync(path.join(config.storageDirectory, 'selection-salt'), 'broken');
    assert.throws(() => new Box(config), /invalid_selection_salt/);
  });

  checked('实际 Context：旧无上下文兼容模式与不完整新上下文边界', (t) => {
    const host = hostFor(t);
    const { OtaUserContextBox: Box } = host.load('ota/OtaUserContext.ets');
    const legacy = new Box(configFor(host, 'legacy', { versionCode: undefined, lynxSdkVersion: undefined }));
    assert.equal(legacy.capture().selectionEnabled, false);
    assert.throws(() => legacy.register('user_demo_A'), /missing_version_code/);
    assert.throws(() => configFor(host, 'missing-sdk', { lynxSdkVersion: undefined }), /missing_selection_context/);
    assert.throws(() => configFor(host, 'missing-code', { versionCode: undefined }), /missing_selection_context/);
    // 另外验证绕过 Config.validate 的低层调用仍有自身防线。
    const lowLevelMissingSdk = configFor(host, 'low-level-sdk'); lowLevelMissingSdk.lynxSdkVersion = undefined;
    assert.throws(() => new Box(lowLevelMissingSdk), /missing_sdk_version/);
    const lowLevelMissingCode = configFor(host, 'low-level-code'); lowLevelMissingCode.versionCode = undefined;
    assert.throws(() => new Box(lowLevelMissingCode), /missing_version_code/);
  });

  checked('实际 OtaJson：单个/全量选择、Harmony 与指令结构保持', (t) => {
    const host = hostFor(t);
    const Json = host.load('ota/OtaJson.ets').default;
    const release = sampleRelease();
    const single = Json.parseLatestLists(JSON.stringify(release));
    assert.equal(single.bundleLists[0].releaseSequence, '9007199254740993');
    assert.equal(single.bundleLists[0].platform, 'harmony');
    assert.deepEqual(plain(single.bundleLists[0].platforms), ['android', 'ios', 'harmony']);
    const directive = { lynxAppId: '10000002', action: 'use_embedded', policyRevision: '9007199254740995', reason: 'server_rollback' };
    const batch = Json.parseLatestLists(JSON.stringify({ selectionSchemaVersion: 1, env: 'TEST', hostApp: 'capp', platform: 'harmony', bundleLists: [release], directives: [directive] }));
    assert.equal(batch.bundleLists.length, 1);
    assert.deepEqual(plain(batch.directives), [directive]);
    const decision = Json.parseLatestLists(JSON.stringify({ selectionSchemaVersion: 1, env: 'TEST', hostApp: 'capp', platform: 'harmony', decision: directive }));
    assert.equal(decision.bundleLists.length, 0);
    assert.equal(decision.directives[0].action, 'use_embedded');
  });

  checked('实际 OtaJson/Selection：错误字段、范围、平台和匿名灰度失败关闭', (t) => {
    const host = hostFor(t);
    const Json = host.load('ota/OtaJson.ets').default;
    const { OtaSelection: Selection } = host.load('ota/OtaSelection.ets');
    const { OtaUserContextBox: Box } = host.load('ota/OtaUserContext.ets');
    const context = new Box(configFor(host)).capture();
    for (const release of [sampleRelease({ releaseSequence: 3 }), sampleRelease({ platform: 'web' }), sampleRelease({ versionCodeRange: { other: '1' } }), sampleRelease({ selection: { kind: 'unknown' } })]) {
      assert.throws(() => Json.parseLatestLists(JSON.stringify(release)));
    }
    const anonymousGray = Json.parseLatestLists(JSON.stringify(sampleRelease({ selection: { kind: 'gray', ruleId: 'rule-A', policyRevision: '1', reason: 'matched_gray' } }))).bundleLists[0];
    assert.throws(() => Selection.fromRelease(anonymousGray, context), /invalid_selection_metadata/);
    assert.throws(() => Selection.fromRelease(sampleRelease({ selectionSchemaVersion: 2 }), context), /missing_selection_metadata/);
    assert.throws(() => Selection.fromRelease(sampleRelease({ versionCodeRange: { min: '200', max: '100' } }), context), /invalid_version_range/);
  });

  checked('实际 Selection：双兼容门禁、灰度归属与完整 State JSON 往返', (t) => {
    const host = hostFor(t);
    const { OtaSelection: Selection } = host.load('ota/OtaSelection.ets');
    const { OtaUserContextBox: Box } = host.load('ota/OtaUserContext.ets');
    const Json = host.load('ota/OtaJson.ets').default;
    const box = new Box(configFor(host, 'selection', { userId: 'user_demo_A', lynxSdkVersion: '4.10' }));
    const a = box.capture();
    const release = sampleRelease({ versionCodeRange: { min: '120', max: '199' }, lynxSdkRange: { min: '4.9', max: '4.10' }, selection: { kind: 'gray', ruleId: 'rule-A', policyRevision: '10', reason: 'matched_gray' } });
    const stored = Selection.fromRelease(release, a);
    assert.equal(Selection.compatible(stored, a), true);
    box.registerUserId('user_demo_B');
    assert.equal(Selection.compatible(stored, box.capture()), false);
    assert.equal(Selection.compatible({ ...stored, kind: 'full', audienceKey: undefined }, box.capture()), true);
    assert.equal(Selection.compatible({ ...stored, versionCodeRange: { max: '149' } }, a), false);
    assert.equal(Selection.compatible({ ...stored, lynxSdkRange: { max: '4.9' } }, a), false);
    const decision = Selection.decision({ release }, a);
    const state = { schemaVersion: 3, selectionSchemaVersion: 1, env: 'TEST', hostApp: 'capp', lynxAppId: '10000001', platform: 'harmony', generation: 1,
      current: { kind: 'downloaded', releaseId: release.releaseId, manifestId: 'manifest-test', selection: stored }, lastDecision: decision };
    const decoded = Json.parseState(JSON.stringify(state));
    assert.equal(decoded.current.selection.releaseSequence, release.releaseSequence);
    assert.equal(decoded.lastDecision.clientContextKey, a.clientContextKey);
    assert.equal(decoded.lastDecision.action, 'use_release');
  });

  checked('实际 PageRefreshGate：30 分钟上下界、并发占位与零间隔', (t) => {
    const host = hostFor(t); const Gate = host.load('ota/OtaPageRefreshGate.ets').default;
    const gate = new Gate(1); const interval = 30 * 60 * 1000;
    assert.equal(gate.reserve('10000001', 1, 0, interval), true);
    assert.equal(gate.reserve('10000001', 1, 0, interval), false);
    gate.markSuccess('10000001', 1, 0); gate.complete('10000001', 1);
    assert.equal(gate.reserve('10000001', 1, interval - 1, interval), false);
    assert.equal(gate.reserve('10000001', 1, interval, interval), true);
    gate.complete('10000001', 1);
    assert.equal(gate.reserve('10000001', 1, 1, 0), true);
  });

  checked('实际 PageRefreshGate：旧 reserve/complete/mark/clear 不得修改新 epoch', (t) => {
    const host = hostFor(t); const Gate = host.load('ota/OtaPageRefreshGate.ets').default;
    const gate = new Gate(1);
    assert.equal(gate.reserve('10000001', 1, 0, 100), true);
    gate.reset(2);
    assert.equal(gate.reserve('10000001', 1, 0, 100), false);
    assert.equal(gate.reserve('10000001', 2, 0, 100), true);
    gate.complete('10000001', 1); gate.clearApp('10000001', 1); gate.clearAll(1);
    assert.equal(gate.reserve('10000001', 2, 1, 100), false);
    gate.complete('10000001', 2); gate.markSuccess('10000001', 2, 10);
    gate.markSuccess('10000001', 1, 1000000); gate.clearApp('10000001', 1); gate.clearAll(1);
    assert.equal(gate.reserve('10000001', 2, 109, 100), false);
    assert.equal(gate.reserve('10000001', 2, 110, 100), true);
  });

  checked('实际 PageRefreshGate：多 App 隔离、clearApp/clearAll 与 reset', (t) => {
    const host = hostFor(t); const Gate = host.load('ota/OtaPageRefreshGate.ets').default;
    const gate = new Gate(3);
    assert.equal(gate.reserve('10000001', 3, 0, 100), true);
    assert.equal(gate.reserve('10000002', 3, 0, 100), true);
    gate.clearApp('10000001', 3);
    assert.equal(gate.reserve('10000001', 3, 1, 100), true);
    assert.equal(gate.reserve('10000002', 3, 1, 100), false);
    gate.clearAll(3);
    assert.equal(gate.reserve('10000002', 3, 2, 100), true);
    gate.markSuccess('10000001', 3, 200); gate.reset(4);
    assert.equal(gate.reserve('10000001', 4, 0, 100), true);
    assert.equal(gate.reserve('10000002', 4, 0, 100), true);
  });

  checked('实际身份事件：订阅幂等、解除与异常监听隔离，仅传 epoch', (t) => {
    const host = hostFor(t); const Events = host.load('ota/OtaUserContextEvents.ets').default;
    const values = [];
    const first = (epoch) => values.push(['first', epoch]);
    const second = (epoch) => values.push(['second', epoch]);
    const broken = () => { throw new Error('synthetic-listener-failure'); };
    Events.subscribe(first); Events.subscribe(first); Events.subscribe(broken); Events.subscribe(second); Events.emit(5);
    assert.deepEqual(values, [['first', 5], ['second', 5]]);
    Events.unsubscribe(first); Events.unsubscribe(broken); Events.emit(6);
    assert.deepEqual(values.at(-1), ['second', 6]);
    Events.unsubscribe(second); Events.emit(7);
    assert.equal(values.length, 3);
  });

  checked('实际 EmbeddedBundleRegistry：缺少 Manifest 时按源码承诺提供空 registry', async (t) => {
    const host = hostFor(t);
    const Registry = host.load('ota/EmbeddedBundleRegistry.ets').default;
    const registry = new Registry(host.context);
    assert.equal(await registry.firstAvailable(), null);
  });
}

// 真实 Server 扩展入口；pure 模式不会请求网络或改变 fixture。
if (options.mode !== 'pure') {
  checked('实际 OtaApiClient + 真实 Server：Harmony Query、全量优先、ETag 与指令', async (t, entry) => {
    const host = hostFor(t, true);
    const control = async (name, body) => {
      const response = await fetch(new URL(`/_fixture/${name}`, options.serverOrigin), { method: body === undefined ? 'GET' : 'POST',
        headers: { 'x-ota-fixture-control': 'local-fixture-only', 'content-type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
      assert.equal(response.status, 200); return response.json();
    };
    const state = await control('reset', {}); const ids = state.actualReleaseIds;
    const { OtaUserContextBox: Box } = host.load('ota/OtaUserContext.ets');
    const Api = host.load('ota/OtaApiClient.ets').default;
    const config = configFor(host, 'real-api', { clientToken: 'ota-user-gray-local-client-token' });
    const box = new Box(config); const api = new Api(config, null, box);
    const phases = [];
    for (const stage of ['full5', 'gray6', 'full7', 'gray8']) {
      await control('stage', { stage });
      for (const user of [undefined, 'user_demo_A', 'user_demo_B']) {
        box.registerUserId(user);
        const result = await api.fetchLatestSelection('10000001', undefined, box.capture());
        const expected = stage === 'gray6' ? (user === 'user_demo_A' ? 'gray6' : 'full5') : stage === 'gray8' ? (user === 'user_demo_A' ? 'gray8' : 'full7') : stage;
        assert.equal(result.release.releaseId, ids[expected]);
        phases.push({ stage, audience: user === undefined ? 'anonymous' : user.endsWith('_A') ? 'A' : 'B', releaseId: result.release.releaseId });
      }
    }
    await api.fetchLatestSelection('10000001', undefined, box.capture());
    assert.equal(host.audit.http.at(-1).statusCode, 304);
    await control('fallback', { enabled: true, platforms: ['harmony'] });
    const forced = await api.fetchLatestSelection('10000001', undefined, box.capture());
    assert.equal(forced.directive.action, 'use_embedded');
    assert.ok(host.audit.http.every((request) => request.platform === 'harmony' && request.versioncode === '150' && request.lynxSdkVersion === '4.0.0'));
    entry.phases = phases;
    entry.adapterEvidence = host.evidence();
  });

  checked('实际 Store + 真实 Server：100→1、全量化、回滚、指令冷读与有界 CAS', async (t, entry) => {
    const host = hostFor(t, true);
    const ids = (await fixtureControl('reset', {})).actualReleaseIds;
    const s = realStore(host, 'server-store');
    const phases = [];
    async function phase(name) {
      const snapshot = s.store.storageSnapshot().apps.find((app) => app.appId === '10000001');
      const metrics = await fixtureControl('metrics');
      phases.push({ phase: name, current: s.current(), state: s.state(), objectCount: snapshot?.objectCount,
        bundleRequests: metrics.bundleRequestCount, bundleBytes: metrics.bundleBytes, latestRequests: metrics.latestRequestCount,
        hostBinaryWrites: host.audit.binaryWrites, hostFileCopies: host.audit.copiedFiles });
      return { snapshot, metrics };
    }
    await fixtureControl('metrics/reset', {}); await s.sync();
    assert.equal(s.current().releaseId, ids.full5);
    let observed = await phase('anonymous-full5');
    assert.equal(observed.metrics.bundleRequestCount, 100); assert.equal(observed.snapshot.objectCount, 100);
    await fixtureControl('stage', { stage: 'gray6' }); s.box.register('user_demo_A'); s.store.reconcileUserContext(s.box.capture());
    await fixtureControl('metrics/reset', {}); await s.sync();
    assert.equal(s.current().releaseId, ids.gray6);
    observed = await phase('A-gray6');
    assert.equal(observed.metrics.bundleRequestCount, 1); assert.equal(observed.snapshot.objectCount, 101); assert.equal(host.audit.copiedFiles, 0);
    s.box.register('user_demo_B'); s.store.reconcileUserContext(s.box.capture());
    assert.equal(s.current().releaseId, ids.full5);
    await fixtureControl('metrics/reset', {}); await s.sync();
    assert.equal((await phase('B-full5')).metrics.bundleRequestCount, 0);
    await fixtureControl('stage', { stage: 'full7' }); s.box.register('user_demo_A'); s.store.reconcileUserContext(s.box.capture());
    await fixtureControl('metrics/reset', {}); await s.sync();
    assert.equal(s.current().releaseId, ids.full7); assert.equal((await phase('A-newer-full7')).metrics.bundleRequestCount, 1);
    await fixtureControl('stage', { stage: 'gray8' }); await fixtureControl('metrics/reset', {}); await s.sync();
    assert.equal(s.current().releaseId, ids.gray8); await phase('A-gray8');
    await fixtureControl('publish', { alias: 'gray8', type: 'full' }); await fixtureControl('metrics/reset', {}); await s.sync();
    assert.equal(s.state().current.selection.kind, 'full');
    assert.equal((await phase('same-release-promoted-full')).metrics.bundleRequestCount, 0);
    s.box.register('user_demo_B'); s.store.reconcileUserContext(s.box.capture());
    assert.equal(s.current().releaseId, ids.gray8);
    await fixtureControl('rollback', { from: 'gray8', target: 'full5' }); await fixtureControl('metrics/reset', {}); await s.sync();
    assert.equal(s.current().releaseId, ids.full5);
    observed = await phase('server-rollback-full5');
    assert.equal(s.state().lastDecision.reason, 'server_rollback');
    assert.equal(observed.metrics.bundleRequestCount, 1); assert.equal(observed.snapshot.objectCount, 101);
    await fixtureControl('fallback', { enabled: true, platforms: ['harmony'] }); await fixtureControl('metrics/reset', {}); await s.sync();
    assert.equal(s.current(), null); assert.equal(s.state().lastDecision.action, 'use_embedded');
    const cold = realStore(host, 'server-store', { userId: 'user_demo_B' });
    assert.equal(cold.current(), null); await phase('directive-cold-read');
    entry.phases = phases; entry.adapterEvidence = host.evidence();
  });

  checked('实际 API/Store：旧 A 在 B 完成后返回，不得改写 B State', async (t, entry) => {
    const host = hostFor(t, true); const ids = (await fixtureControl('reset', {})).actualReleaseIds;
    const s = realStore(host, 'held-identity', { userId: 'user_demo_B' }); await s.sync();
    await fixtureControl('stage', { stage: 'gray6' }); await fixtureControl('delay-latest', { audience: 'A', count: 1, milliseconds: 0 });
    s.box.register('user_demo_A'); s.store.reconcileUserContext(s.box.capture());
    const held = s.sync(s.box.capture()).then(() => ({ succeeded: true }), (error) => ({ succeeded: false, message: error.message }));
    for (let attempt = 0; attempt < 100; attempt++) {
      if ((await fixtureControl('metrics')).pendingLatestCount === 1) break;
      if (attempt === 99) assert.fail('A 未进入真实 Server 延迟队列');
      await pause(20);
    }
    s.box.register('user_demo_B'); s.store.reconcileUserContext(s.box.capture()); await s.sync();
    assert.equal(s.current().releaseId, ids.full5);
    const before = fs.readFileSync(path.join(s.config.storageDirectory, 'apps/10000001/state.json'));
    await fixtureControl('release-delays', {});
    const result = await held;
    assert.equal(result.succeeded, false); assert.match(result.message, /stale_identity/);
    assert.deepEqual(fs.readFileSync(path.join(s.config.storageDirectory, 'apps/10000001/state.json')), before);
    entry.current = s.current(); entry.stateByteIdentical = true; entry.oldResponseError = result.message; entry.adapterEvidence = host.evidence();
  });

  checked('实际 Runtime：显式系统版本 mocks、cache-only 零请求、旧身份会话与撤销', async (t, entry) => {
    const host = hostFor(t, true, { rawResources: new Map([
      ['bundles/lynx/embedded-bundles.json', new TextEncoder().encode(JSON.stringify({ schemaVersion: 1, apps: [] }))],
    ]), mocks: {
      '@ohos.bundle.bundleManager': { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 }, getBundleInfoForSelfSync: () => ({ versionCode: 1, versionName: '1.0.0' }) },
      '@lynx/lynx': { LynxEnv: { getLynxVersion: () => '4.0.0' } },
    } });
    const ids = (await fixtureControl('reset', {})).actualReleaseIds;
    const Runtime = host.load('ota/LynxOtaRuntime.ets').default;
    const Registry = host.load('ota/OtaModels.ets').default;
    const config = configFor(host, 'runtime', { versionCode: undefined, lynxSdkVersion: undefined, clientToken: 'ota-user-gray-local-client-token' });
    const runtime = new Runtime(host.context, config); Registry.install(runtime); t.after(() => runtime.close());
    const result = await runtime.refreshAllBundles(); assert.equal(typeof result, 'boolean');
    let prepared = await runtime.resolveCurrent('10000001', 'pages/10000001/bundle-050.lynx.bundle', 'host-tab');
    assert.equal(prepared.releaseId, ids.full5); prepared.lease?.close();
    const before = host.audit.http.length;
    prepared = await runtime.resolveCurrent('10000001', 'pages/10000001/bundle-050.lynx.bundle', 'host-tab'); prepared.lease?.close();
    assert.equal(host.audit.http.length, before);
    assert.equal(runtime.registerUserId('user_demo_A'), true);
    assert.equal(runtime.registerUserId(' user_demo_A '), false);
    await fixtureControl('stage', { stage: 'gray6' }); await runtime.refreshAllBundles();
    await assert.rejects(() => runtime.resolveCurrent('10000001', 'pages/10000001/bundle-050.lynx.bundle', 'host-tab'), /旧用户导航会话/);
    runtime.resetNavigationSnapshot('host-tab', '10000001');
    prepared = await runtime.resolveCurrent('10000001', 'pages/10000001/bundle-050.lynx.bundle', 'host-tab');
    assert.equal(prepared.releaseId, ids.gray6); prepared.lease?.close();
    await fixtureControl('fallback', { enabled: true, platforms: ['harmony'] });
    const directiveResult = await runtime.refreshAllBundles();
    assert.equal(typeof directiveResult, 'boolean');
    runtime.resetNavigationSnapshot('host-tab', '10000001');
    assert.equal(await runtime.resolveCurrent('10000001', 'pages/10000001/bundle-050.lynx.bundle', 'host-tab'), null);
    entry.systemMetadataMock = { versionCode: 1, sdkVersion: '4.0.0', nativeMetadataValidated: false };
    entry.initialRefreshResult = result; entry.directiveRefreshResult = directiveResult; entry.adapterEvidence = host.evidence();
  });

  checked('实际 Runtime.prepare：空 session 缺包 repair 只交付一个可释放 lease', async (t, entry) => {
    const host = hostFor(t, true, { rawResources: new Map([
      ['bundles/lynx/embedded-bundles.json', new TextEncoder().encode(JSON.stringify({ schemaVersion: 1, apps: [] }))],
    ]), mocks: {
      '@ohos.bundle.bundleManager': { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 }, getBundleInfoForSelfSync: () => ({ versionCode: 1, versionName: '1.0.0' }) },
      '@lynx/lynx': { LynxEnv: { getLynxVersion: () => '4.0.0' } },
    } });
    const ids = (await fixtureControl('reset', {})).actualReleaseIds;
    const Runtime = host.load('ota/LynxOtaRuntime.ets').default;
    const { default: Registry, LynxOtaConfig, OtaPrepareSignal: Signal, OtaStorageReleaseRole: Role } = host.load('ota/OtaModels.ets');
    const config = new LynxOtaConfig(options.serverOrigin);
    Object.assign(config, { environment: 'TEST', hostApp: 'capp', platform: 'harmony', allowLocalHTTPForTest: true,
      storageDirectory: path.join(host.root, 'prepare-repair-empty-session'), clientToken: 'ota-user-gray-local-client-token', userId: 'user_demo_A' });
    const runtime = new Runtime(host.context, config); Registry.install(runtime); t.after(() => runtime.close());
    assert.equal((await runtime.storageSnapshot()).apps.length, 0, 'repair 用例必须从全新临时 Store 开始');
    assert.equal(host.audit.http.length, 0, 'prepare 前不能先后台预下载');
    await fixtureControl('metrics/reset', {});

    // 空 session 不产生额外 NavigationSnapshot lease；唯一所有者就是返回给调用方的 lease。
    const prepared = await runtime.prepare('10000001', 'pages/10000001/bundle-050.lynx.bundle', new Signal(), '');
    assert.ok(prepared.lease, '真实缺包 repair 必须返回带 lease 的 Prepared');
    let leasedSnapshot;
    try {
      assert.equal(prepared.releaseId, ids.full5);
      assert.equal(prepared.source, 'ota_current');
      assert.equal(prepared.userIdentityEpoch, runtime.userIdentityEpoch);
      leasedSnapshot = (await runtime.storageSnapshot()).apps.find((app) => app.appId === '10000001');
      assert.ok(leasedSnapshot);
      assert.equal(leasedSnapshot.objectCount, 100);
      const leasedReleases = leasedSnapshot.releases.filter((release) => release.roles.includes(Role.LEASED));
      assert.equal(leasedReleases.length, 1);
      assert.equal(leasedReleases[0].releaseId, ids.full5);
      assert.ok(leasedReleases[0].roles.includes(Role.CURRENT));

      const latest = host.audit.http.filter((request) => request.path === '/api/ota/v1/releases/latest-bundle-list');
      assert.equal(latest.length, 1);
      assert.equal(latest[0].platform, 'harmony');
      assert.equal(latest[0].versioncode, '1');
      assert.equal(latest[0].lynxSdkVersion, '4.0.0');
      assert.equal(latest[0].audience, 'A', '实际 Query 必须携带已注册的合成 userId');
      const downloads = host.audit.http.filter((request) => request.path.startsWith('/ota/bundles/'));
      assert.equal(downloads.length, 100);
      assert.ok(downloads.every((request) => request.completed && request.statusCode === 200 && !request.clientTokenPresent));
    } finally { prepared.lease.close(); }

    const afterClose = (await runtime.storageSnapshot()).apps.find((app) => app.appId === '10000001');
    assert.ok(afterClose);
    assert.equal(afterClose.releases.filter((release) => release.roles.includes(Role.LEASED)).length, 0,
      '关闭 returned.lease 后不能残留 ensureBundleReady 被丢弃所产生的永久额外 lease');
    assert.ok(afterClose.releases.find((release) => release.releaseId === ids.full5)?.roles.includes(Role.CURRENT),
      '关闭 lease 只释放引用，不删除仍为 current 的发布');
    assert.equal(afterClose.objectCount, 100);
    const metrics = await fixtureControl('metrics');
    assert.equal(metrics.latestRequestCount, 1);
    assert.equal(metrics.bundleRequestCount, 100);
    assert.equal(metrics.bundleSuccessCount, 100);
    entry.navigationSessionID = '';
    entry.systemMetadataMock = { versionCode: 1, sdkVersion: '4.0.0', nativeMetadataValidated: false };
    entry.prepared = { releaseId: prepared.releaseId, bundleName: prepared.bundleName, source: prepared.source,
      userIdentityEpoch: prepared.userIdentityEpoch, selectionKind: prepared.selectionKind, releaseSequence: prepared.releaseSequence };
    entry.beforeClose = plain(leasedSnapshot);
    entry.afterClose = plain(afterClose);
    entry.metrics = { latestRequestCount: metrics.latestRequestCount, bundleRequestCount: metrics.bundleRequestCount,
      bundleSuccessCount: metrics.bundleSuccessCount, bundleBytes: metrics.bundleBytes };
    entry.adapterEvidence = host.evidence();
  });
}

after(() => {
  const evidence = { schemaVersion: 1, evidenceKind: HOST_EVIDENCE_KIND, deviceTested: false, nativeIOValidated: false,
    mode: options.mode, serverOrigin: options.serverOrigin ?? null, serverIntegrationExecuted: options.mode !== 'pure',
    tests: results, summary: { total: results.length, passed: results.filter((item) => item.status === 'PASS').length, failed: results.filter((item) => item.status === 'FAIL').length },
    hosts: hosts.map((host) => host.evidence()),
    boundary: '实际 .ets 转译后运行于宿主 Node；系统 API 是明确 adapters，不证明 ArkTS 编译器、设备、UI 首屏、native FS/crypto/HTTP。' };
  fs.writeFileSync(path.join(options.output, 'summary.json'), `${JSON.stringify(evidence, null, 2)}\n`);
  console.log(`Harmony host evidence: ${options.output}`);
});
