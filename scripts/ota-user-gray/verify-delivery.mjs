#!/usr/bin/env node
// 只读核对本次已采集证据；不运行 App、不请求服务、不把宿主结果升级为设备认证。
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const read = path => readFileSync(resolve(root, path));
const json = path => JSON.parse(read(path));
const sha = path => createHash('sha256').update(read(path)).digest('hex');
const runs = {
  ios: 'ios-20260906-run6',
  android: 'android-20260906-final-gate2',
  harmony: 'harmony-20260906-final3',
};
const evidence = platform => `docs/evidence/ota-user-gray/${runs[platform]}`;
const ios = json(`${evidence('ios')}/summary.json`);
const android = json(`${evidence('android')}/summary.json`);
const harmony = json(`${evidence('harmony')}/summary.json`);

assert.equal(ios.summary.passedTests, 4);
assert.equal(ios.summary.totalTestCount, 4);
assert.equal(ios.summary.failedTests + ios.summary.skippedTests, 0);
assert.equal(ios.sdkPassed, 83);
assert.equal(ios.scenes.length, 19);
assert.equal(ios.stores.reduce((sum, store) => sum + store.shaVerifiedCount, 0), 401);
assert.ok(ios.stores.every(store => store.objectCount === store.shaVerifiedCount));
const iosSources = json(`${evidence('ios')}/sources.json`);
for (const source of iosSources) assert.equal(sha(source.file), source.sha256, source.file);

assert.equal(android.nonDeviceGate.passed, true);
assert.ok(android.nonDeviceGate.checks.every(check => check.pass === true));
assert.equal(android.junit.passed, 87);
assert.equal(android.junit.total, 87);
assert.equal(android.junit.failures + android.junit.errors + android.junit.skipped, 0);
assert.equal(android.device.scenariosPassed, 0);
assert.equal(android.device.scenariosUnverified, 19);
assert.equal(android.device.deviceTestedInThisGate, false);
assert.equal(sha(android.apk.path), android.apk.sha256);

assert.equal(harmony.nonDeviceGate.passed, true);
assert.ok(harmony.nonDeviceGate.checks.every(check => check.passed === true));
assert.equal(harmony.host.counts.passed, 18);
assert.equal(harmony.core.counts.passed, 25);
assert.equal(harmony.host.httpTestCount, 5);
assert.equal(harmony.device.tested, false);
assert.equal(harmony.device.passed, false);
assert.equal(harmony.nativeIO.validated, false);
assert.equal(harmony.candidate.countedAsPassed, false);
for (const artifact of Object.values(harmony.artifacts)) assert.equal(sha(artifact.path), artifact.sha256, artifact.path);
for (const source of harmony.sources.files) assert.equal(sha(source.file), source.testedSha256, source.file);
assert.equal(sha('harmony/lynx_shell_kit/BuildProfile.ets'), 'c228e42f3466fd4c7ef6ae4c1f65d00d38e77beec620be876fe28ef448d0414b');

let localLinks = 0;
for (const platform of Object.keys(runs)) {
  const path = `docs/${platform}-ota-user-gray-test-report.html`;
  const html = read(path).toString();
  assert.ok(html.length > 1000, `${platform} report is empty`);
  for (const match of html.matchAll(/\b(?:src|href)=["']([^"']+)["']/g)) {
    const url = match[1];
    if (/^(?:#|[a-z][a-z\d+.-]*:|\/\/)/i.test(url)) continue;
    const target = decodeURIComponent(url.split(/[?#]/)[0]);
    if (!target) continue;
    assert.ok(existsSync(resolve(root, dirname(path), target)), `${platform}: missing ${target}`);
    localLinks++;
  }
}
console.log(JSON.stringify({ passed: true, evidenceOnly: true, iosSimulatorFlows: 4, iosScreenshots: 19, iosVerifiedObjects: 401, iosSourceHashes: iosSources.length, androidJUnit: 87, androidDeviceAccepted: false, harmonyHost: 43, harmonySourceHashes: harmony.sources.files.length, harmonyDeviceAccepted: false, nativeHarmonyIOValidated: false, protectedBuildProfileUnchanged: true, localLinks }, null, 2));
