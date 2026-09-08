#!/usr/bin/env node
/** 只读既有 Harmony 非设备证据并生成 HTML；不执行测试、Hvigor、HDC 或设备命令。 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HTML_FILE = path.join(ROOT, 'docs/harmony-ota-user-gray-test-report.html');
const EVIDENCE_ROOT = path.join(ROOT, 'docs/evidence/ota-user-gray');
const HOST_KIND = 'host-transpiled-arkts-node-adapters';
const PROFILE_SHA = 'c228e42f3466fd4c7ef6ae4c1f65d00d38e77beec620be876fe28ef448d0414b';
const HOST_TEST_COUNT = 18;
const CORE_TEST_COUNT = 25;
const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
const isCount = (value) => Number.isSafeInteger(value) && value >= 0;
const showCount = (value) => isCount(value) ? value.toLocaleString('en-US') : '未提供';

function help() {
  console.log(`用法：
node scripts/collect-harmony-user-gray-report.mjs \\
  --host-summary /absolute/harmony-host-final2/summary.json \\
  --core-tap-log /absolute/core-25.tap.log \\
  --har-build-log /absolute/har-build-final2.log \\
  --app-build-log /absolute/app-build-final2.log \\
  --har /absolute/lynx_shell_kit.har \\
  --app /absolute/lynx_shell.app \\
  --run-id harmony-20260906-final2

必填：--host-summary --core-tap-log --har-build-log --app-build-log --har --app --run-id
可选：
  --build-profile FILE            默认 harmony/lynx_shell_kit/BuildProfile.ets。
  --expected-build-profile-sha SHA 默认本轮用户保护值 ${PROFILE_SHA}；不允许重定保护基线。
  --validate-only                 只读取、计算 SHA、检查门禁，不生成文件。
  --help                         只显示帮助。

严格门禁：host mode=all、实际 ${HOST_TEST_COUNT} 项且全部 PASS；core TAP 实际 ${CORE_TEST_COUNT} 项且无失败/错误/跳过/TODO/取消；
host/逐项/adapter 均声明 evidenceKind=${HOST_KIND}、deviceTested=false、nativeIOValidated=false；
真实 Server HTTP 证据存在；HAR/App 日志均有 BUILD SUCCESSFUL 且无 BUILD FAILED；构建文件非空；
被测源码 SHA 与当前文件一致，BuildProfile 采集前后 SHA 均等于用户保护值。

输出 docs/harmony-ota-user-gray-test-report.html 和 docs/evidence/ota-user-gray/<run-id>/。
证据目录不覆盖；报告更新为本轮结果。HAR/App 只记录大小、SHA、路径，不复制二进制。
candidate=设计不适用（不计 PASS）；页面、系统 I/O、设备仍未验证；模拟器按用户要求不执行；真机本轮未验收。
不会读取/制造截图，不运行 Hvigor/HDC/模拟器、Node 测试或真实 Server 请求。`);
}

function args(argv) {
  const values = { 'build-profile': path.join(ROOT, 'harmony/lynx_shell_kit/BuildProfile.ets'), 'expected-build-profile-sha': PROFILE_SHA };
  const allowed = new Set(['host-summary', 'core-tap-log', 'har-build-log', 'app-build-log', 'har', 'app', 'run-id', 'build-profile', 'expected-build-profile-sha']);
  const seen = new Set();
  for (let index = 0; index < argv.length; index++) {
    if (argv[index] === '--validate-only') { values.validateOnly = true; continue; }
    const key = argv[index].replace(/^--/, '');
    if (!argv[index].startsWith('--') || !allowed.has(key) || !argv[index + 1] || argv[index + 1].startsWith('--')) throw new Error('未知或缺少参数，请使用 --help');
    if (seen.has(key)) throw new Error(`参数重复：--${key}`);
    seen.add(key); values[key] = argv[++index];
  }
  for (const key of ['host-summary', 'core-tap-log', 'har-build-log', 'app-build-log', 'har', 'app', 'run-id']) if (!values[key]) throw new Error(`需要 --${key}`);
  if (!/^[a-z0-9][a-z0-9-]{0,79}$/.test(values['run-id'])) throw new Error('run-id 必须为安全的小写字母/数字/横线目录名，最长 80 字符');
  if (values['expected-build-profile-sha'].toLowerCase() !== PROFILE_SHA) throw new Error('expected-build-profile-sha 与用户保护基线不一致');
  for (const key of allowed) if (values[key] && !['run-id', 'expected-build-profile-sha'].includes(key)) values[key] = path.resolve(values[key]);
  return values;
}

async function fileInfo(file, kind) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`需要真实普通文件，拒绝符号链接：${file}`);
  const hash = crypto.createHash('sha256');
  for await (const bytes of fs.createReadStream(file)) hash.update(bytes);
  return { kind, path: path.resolve(file), bytes: stat.size, sha256: hash.digest('hex'), modifiedAt: stat.mtime.toISOString() };
}

function cleanText(value) {
  return String(value)
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/gi, 'Bearer [REDACTED]')
    .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, '[REDACTED_JWT]')
    .replace(/(\b[A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|COOKIE|AUTHORIZATION)[A-Za-z0-9_]*\s*(?:=|:)\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)/gi, '$1[REDACTED]')
    .replace(/https?:\/\/[^\s"'<>]+/g, (raw) => {
      try {
        const url = new URL(raw);
        url.username = ''; url.password = '';
        for (const key of [...url.searchParams.keys()]) if (/token|secret|password|user.?id|cookie|authorization/i.test(key)) url.searchParams.set(key, '[REDACTED]');
        return url.toString();
      } catch { return '[REDACTED_URL]'; }
    });
}

function cleanJson(value, key = '') {
  if (/^(?:userId|authorization|cookie|password|secret|clientToken|accessToken|refreshToken)$/i.test(key)) return '[REDACTED]';
  if (typeof value === 'string') return cleanText(value);
  if (Array.isArray(value)) return value.map((item) => cleanJson(item));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([name, item]) => [name, cleanJson(item, name)]));
  return value;
}

function proofFlags(value) {
  return value?.evidenceKind === HOST_KIND && value.deviceTested === false && value.nativeIOValidated === false;
}

function hasScreenshots(value) {
  if (!value || typeof value !== 'object') return false;
  if (Array.isArray(value)) return value.some(hasScreenshots);
  return Object.entries(value).some(([key, item]) => (/^screenshots?$/i.test(key) && (Array.isArray(item) ? item.length > 0 : Boolean(item))) || hasScreenshots(item));
}

function parseHost(raw) {
  if (!raw || !Array.isArray(raw.tests) || !raw.summary || !Array.isArray(raw.hosts)) throw new Error('host summary 结构不完整');
  const names = new Set();
  const tests = raw.tests.map((item) => {
    if (typeof item.name !== 'string' || !item.name.trim() || names.has(item.name)) throw new Error('host 测试名称缺失或重复');
    names.add(item.name);
    return { ...item, layer: isHttpTest(item) ? 'host-http' : 'host-pure' };
  });
  const counts = { total: tests.length, passed: tests.filter((item) => item.status === 'PASS').length,
    failed: tests.filter((item) => ['FAIL', 'FAILED', 'ERROR'].includes(item.status)).length,
    skipped: tests.filter((item) => ['SKIP', 'SKIPPED'].includes(item.status)).length,
    unfinished: tests.filter((item) => !['PASS', 'FAIL', 'FAILED', 'ERROR', 'SKIP', 'SKIPPED'].includes(item.status)).length };
  const consistent = raw.summary.total === counts.total && raw.summary.passed === counts.passed && raw.summary.failed === counts.failed &&
    (!Object.hasOwn(raw.summary, 'skipped') || raw.summary.skipped === counts.skipped) &&
    ['errors', 'cancelled', 'todo'].every((field) => !Object.hasOwn(raw.summary, field) || raw.summary[field] === 0);
  const allFlagsValid = proofFlags(raw) && tests.every(proofFlags) && raw.hosts.length > 0 && raw.hosts.every(proofFlags) &&
    tests.every((item) => item.adapterEvidence === undefined || proofFlags(item.adapterEvidence));
  let serverOriginValid = false;
  try {
    const origin = new URL(raw.serverOrigin);
    serverOriginValid = origin.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(origin.hostname) && Boolean(origin.port) &&
      !origin.username && !origin.password && !origin.search && !origin.hash && origin.pathname === '/';
  } catch { /* 非 all 输入或来源缺失不得当作真实 Server 验收。 */ }
  return { mode: raw.mode, counts, consistent, allFlagsValid, noScreenshots: !hasScreenshots(raw),
    serverOrigin: raw.serverOrigin, serverOriginValid, serverIntegrationExecuted: raw.serverIntegrationExecuted === true,
    httpTestCount: tests.filter(isHttpTest).length, phaseCount: tests.reduce((sum, item) => sum + (Array.isArray(item.phases) ? item.phases.length : 0), 0),
    tests: cleanJson(tests), hosts: cleanJson(raw.hosts), boundary: raw.boundary };
}

function isHttpTest(value) {
  const requests = value?.adapterEvidence?.io?.http;
  return Array.isArray(requests) && requests.some((request) => request.path === '/api/ota/v1/releases/latest-bundle-list' && request.completed === true && request.statusCode >= 200 && request.statusCode < 400);
}

function parseTap(text) {
  const source = text.replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, '');
  if (/^Bail out!/mi.test(source)) throw new Error('core TAP 包含 Bail out，测试未完整完成');
  const cases = [...source.matchAll(/^(ok|not ok)\s+(\d+)(?:\s+-\s*|\s+)?([^\r\n]*)$/gm)].map((match) => {
    const directive = match[3].match(/(?:^|[^\\])#\s*(SKIP|TODO)\b/i)?.[1]?.toUpperCase();
    return { index: Number(match[2]), name: cleanText(match[3].replace(/\s+#\s*(?:SKIP|TODO)\b.*$/i, '').trim()),
      status: directive === 'SKIP' ? 'SKIPPED' : directive === 'TODO' ? 'TODO' : match[1] === 'ok' ? 'PASS' : 'FAIL' };
  });
  if (!cases.length) throw new Error('core TAP 没有顶层测试记录');
  const plans = [...source.matchAll(/^1\.\.(\d+)(?:\s.*)?$/gm)];
  if (plans.length !== 1 || Number(plans[0][1]) !== cases.length || cases.some((item, index) => item.index !== index + 1)) throw new Error('core TAP plan/序号/逐项数量不一致，可能混入多轮日志');
  const footer = {};
  for (const key of ['tests', 'pass', 'fail', 'skipped', 'cancelled', 'todo']) {
    const matches = [...source.matchAll(new RegExp(`^# ${key} ([0-9]+)\\s*$`, 'gm'))];
    if (matches.length > 1) throw new Error(`core TAP 出现多份 ${key} 汇总`);
    if (matches.length) footer[key] = Number(matches[0][1]);
  }
  const counts = { total: cases.length, passed: cases.filter((item) => item.status === 'PASS').length,
    failed: cases.filter((item) => item.status === 'FAIL').length, skipped: cases.filter((item) => item.status === 'SKIPPED').length,
    todo: cases.filter((item) => item.status === 'TODO').length, cancelled: footer.cancelled ?? 0 };
  for (const [field, key] of [['tests', 'total'], ['pass', 'passed'], ['fail', 'failed'], ['skipped', 'skipped'], ['todo', 'todo']]) {
    if (footer[field] !== undefined && footer[field] !== counts[key]) throw new Error(`core TAP 的 ${field} 汇总与逐项记录不一致`);
  }
  return { counts, footer, cases, evidenceLayer: '核心 TAP 宿主测试日志，不代表设备或 Harmony 系统 IO' };
}

function buildResult(text, source) {
  const plain = text.replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, '');
  const successfulMarkers = [...plain.matchAll(/\bBUILD SUCCESSFUL\b/g)].length;
  const failedMarkers = [...plain.matchAll(/\bBUILD FAILED\b|\bBUILD FAILURE\b/g)].length;
  return { source, successfulMarkers, failedMarkers, passed: successfulMarkers > 0 && failedMarkers === 0,
    lastSuccessLine: cleanText(plain.split(/\r?\n/).filter((line) => line.includes('BUILD SUCCESSFUL')).at(-1) ?? '') };
}

async function sourceSnapshot(rawHosts) {
  const entries = new Map();
  const problems = [];
  for (const host of rawHosts) {
    if (!Array.isArray(host.sources) || !host.sources.length || !Array.isArray(host.sourceChangedAfterLoad)) { problems.push('host 缺少源码 SHA 或变更记录'); continue; }
    if (host.sourceChangedAfterLoad.length) problems.push('测试运行期间存在被测源码变化');
    for (const item of host.sources) {
      if (typeof item.file !== 'string' || !/^[a-f0-9]{64}$/.test(item.sha256 ?? '')) { problems.push('被测源码指纹不合法'); continue; }
      const file = path.resolve(item.file);
      if (!file.startsWith(`${path.join(ROOT, 'harmony')}${path.sep}`)) { problems.push('被测源码路径超出当前 Harmony 仓库，未读取该路径'); continue; }
      if (entries.has(file) && entries.get(file).testedSha256 !== item.sha256) problems.push(`同一源码在输入中存在不同快照：${path.relative(ROOT, file)}`);
      if (!entries.has(file)) entries.set(file, { file, testedSha256: item.sha256, emittedSha256: item.emittedSha256 });
    }
  }
  for (const item of entries.values()) {
    try {
      const current = await fileInfo(item.file, 'tested-arkts-source');
      item.currentSha256 = current.sha256; item.matchesCurrent = item.testedSha256 === current.sha256;
      if (!item.matchesCurrent) problems.push(`当前源码与被测 SHA 不一致：${path.relative(ROOT, item.file)}`);
    } catch { item.matchesCurrent = false; problems.push(`无法复核源码：${path.relative(ROOT, item.file)}`); }
  }
  return { files: [...entries.values()].sort((a, b) => a.file.localeCompare(b.file)), problems: [...new Set(problems)] };
}

async function collect(options) {
  const inputs = [];
  const profileBefore = await fileInfo(options['build-profile'], 'protected-build-profile-before'); inputs.push(profileBefore);
  const hostSource = await fileInfo(options['host-summary'], 'host-summary'); inputs.push(hostSource);
  const rawHost = JSON.parse(fs.readFileSync(options['host-summary'], 'utf8'));
  const host = parseHost(rawHost);
  const sources = await sourceSnapshot(rawHost.hosts);
  const coreSource = await fileInfo(options['core-tap-log'], 'core-tap-log'); inputs.push(coreSource);
  const coreText = fs.readFileSync(options['core-tap-log'], 'utf8'); const core = parseTap(coreText);
  const harLogSource = await fileInfo(options['har-build-log'], 'har-build-log'); inputs.push(harLogSource);
  const appLogSource = await fileInfo(options['app-build-log'], 'app-build-log'); inputs.push(appLogSource);
  const harText = fs.readFileSync(options['har-build-log'], 'utf8'); const appText = fs.readFileSync(options['app-build-log'], 'utf8');
  const builds = { har: buildResult(harText, harLogSource), app: buildResult(appText, appLogSource) };
  const har = { ...(await fileInfo(options.har, 'har-artifact')), copiedToEvidence: false }; inputs.push(har);
  const app = { ...(await fileInfo(options.app, 'app-artifact')), copiedToEvidence: false }; inputs.push(app);
  const profileAfter = await fileInfo(options['build-profile'], 'protected-build-profile-after'); inputs.push(profileAfter);
  const protectedProfile = { expectedSha256: PROFILE_SHA, before: profileBefore, after: profileAfter,
    unchanged: profileBefore.sha256 === PROFILE_SHA && profileAfter.sha256 === PROFILE_SHA };
  const checks = [
    { id: 'host-mode', label: 'host summary 为 mode=all', passed: host.mode === 'all' },
    { id: 'host-count', label: `host 逐项与汇总一致，实际 ${HOST_TEST_COUNT} 项全部通过且无跳过/未完成`, passed: host.consistent && host.counts.total === HOST_TEST_COUNT && host.counts.passed === HOST_TEST_COUNT && host.counts.failed === 0 && host.counts.skipped === 0 && host.counts.unfinished === 0 },
    { id: 'host-boundary', label: 'host、逐项和适配器保持明确非设备/非 native IO 标记', passed: host.allFlagsValid && host.noScreenshots },
    { id: 'real-http', label: '真实 Server HTTP 来源与五项集成证据完整', passed: host.serverIntegrationExecuted && host.serverOriginValid && host.httpTestCount === 5 },
    { id: 'core', label: `core TAP 实际 ${CORE_TEST_COUNT} 项全部通过，无失败/跳过/TODO/取消`, passed: core.counts.total === CORE_TEST_COUNT && core.counts.passed === CORE_TEST_COUNT && core.counts.failed === 0 && core.counts.skipped === 0 && core.counts.todo === 0 && core.counts.cancelled === 0 },
    { id: 'har-build', label: '真实 HAR Hvigor 构建日志成功', passed: builds.har.passed },
    { id: 'app-build', label: '真实 App Hvigor 构建日志成功', passed: builds.app.passed },
    { id: 'artifacts', label: 'HAR / App 构建文件存在且非空，SHA 已实际计算', passed: har.bytes > 0 && app.bytes > 0 },
    { id: 'profile', label: 'BuildProfile 采集前后 SHA 均等于用户保护值', passed: protectedProfile.unchanged },
    { id: 'sources', label: '被测实际 .ets 指纹完整，运行中和采集时无漂移', passed: sources.files.length > 0 && sources.problems.length === 0 },
  ];
  return {
    schemaVersion: 1, runId: options['run-id'], generatedAt: new Date().toISOString(), evidenceKind: 'harmony-non-device-report',
    nonDeviceGate: { passed: checks.every((item) => item.passed), checks, problems: sources.problems },
    host: { source: hostSource, ...host }, core: { source: coreSource, ...core }, builds, artifacts: { har, app }, protectedProfile, sources, inputs,
    candidate: { status: 'NOT_APPLICABLE_BY_DESIGN', countedAsPassed: false, reason: 'Harmony 固定采用 current/previous，不实现 candidate/trial；设计不适用不等于测试通过。' },
    device: { status: 'NOT_RUN_USER_CANCELLED', tested: false, passed: false, screenshots: [], reason: '模拟器按用户要求不执行；真机本轮未验收' },
    nativeIO: { status: 'NOT_VALIDATED', validated: false, reason: 'Node FS/crypto/fetch/systemDateTime/resourceManager 适配不证明 Harmony 系统 IO、线程、资源与原生取消语义。' },
    ui: { status: 'NOT_VALIDATED', validated: false, reason: 'ArkUI 页面、Native Tab、LynxView 渲染和真实首屏未进行设备验证。' },
    redacted: { host: cleanJson(rawHost), coreTap: cleanText(coreText), harLog: cleanText(harText), appLog: cleanText(appText) },
  };
}

function roles(value) {
  if (!Array.isArray(value?.releases)) return '未提供';
  return value.releases.filter((release) => Array.isArray(release.roles) && release.roles.includes('leased')).length;
}

function phaseTable(phases) {
  if (!Array.isArray(phases) || !phases.length) return '';
  return `<div class="table"><table><thead><tr><th>实际采集阶段</th><th>身份 / 发布</th><th>Node CAS 对象</th><th>采集区间 Bundle HTTP</th></tr></thead><tbody>${phases.map((phase) => `<tr><td>${esc(phase.phase ?? phase.stage ?? '未命名')}</td><td>${esc(phase.audience ?? '见 JSON 上下文')}<br><code>${esc(phase.current?.releaseId ?? phase.releaseId ?? '无远程 / 未提供')}</code></td><td>${showCount(phase.objectCount)}</td><td>请求 ${showCount(phase.bundleRequests)}<br>字节 ${showCount(phase.bundleBytes)}</td></tr>`).join('')}</tbody></table></div>`;
}

function render(result) {
  const base = `evidence/ota-user-gray/${result.runId}`;
  const testCards = result.host.tests.map((item, index) => `<article class="evidence-item" data-kind="${item.layer}"><details><summary><span class="tag">${item.layer === 'host-http' ? '实际 ArkTS + Node 适配 + 真实 HTTP' : '实际 ArkTS + Node 宿主'}</span> ${esc(item.name)} <small>${item.status === 'PASS' ? '宿主断言通过' : esc(item.status)} · deviceTested=false · nativeIOValidated=false</small></summary>${phaseTable(item.phases)}${item.beforeClose && item.afterClose ? `<div class="callout">空 session repair 的宿主 lease 角色：关闭前 ${showCount(roles(item.beforeClose))}，关闭后 ${showCount(roles(item.afterClose))}；CAS ${showCount(item.afterClose.objectCount)} 个。此为 Node 适配执行的实际引用逻辑，不是 native IO 验证。</div>` : ''}<p>未提供的计数显示“未提供”，不补为 0；区间计数不擅自相加或拆分为单次动作。</p><p><a href="${base}/host-tests/${String(index + 1).padStart(2, '0')}.json">该项完整宿主证据 JSON</a></p><pre>${esc(JSON.stringify(item, null, 2))}</pre></details></article>`).join('\n');
  const coreCards = result.core.cases.map((item) => `<article class="evidence-item compact" data-kind="core"><details><summary><span class="tag">核心 TAP / 宿主</span> ${esc(item.name)} <small>${item.status === 'PASS' ? '通过' : esc(item.status)}</small></summary><p>TAP 用例序号 ${item.index}；来源 <a href="${base}/core.tap.log">core.tap.log</a>。不计作设备或系统 IO 通过。</p></details></article>`).join('\n');
  const checkList = result.nonDeviceGate.checks.map((check) => `<li><span class="check ${check.passed ? 'ok' : 'bad'}">${check.passed ? '通过' : '未通过'}</span>${esc(check.label)}</li>`).join('');
  const artifactRows = [['HAR', result.artifacts.har, result.builds.har], ['App / HAP', result.artifacts.app, result.builds.app]].map(([label, artifact, build]) => `<tr><td>${label}</td><td><code>${esc(artifact.path)}</code><br>${showCount(artifact.bytes)} 字节 · ${(artifact.bytes / 1024 / 1024).toFixed(2)} MiB</td><td><code>${artifact.sha256}</code></td><td>${build.passed ? 'BUILD SUCCESSFUL' : '构建未通过'}<br><small>${esc(build.lastSuccessLine)}</small></td></tr>`).join('');
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Harmony 用户灰度 OTA · 非设备验证报告</title><style>
:root{--ink:#142d2a;--muted:#506964;--line:#cddad3;--paper:#f3f3e9;--accent:#b9ed68;--warn:#ffe1ab;--bad:#f4b4a6}*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.7 'PingFang SC','Helvetica Neue',sans-serif}main{max-width:1300px;margin:auto;padding:40px 36px 80px}header{border-top:7px solid var(--ink);padding:26px 0 34px;border-bottom:1px solid var(--ink)}.eyebrow{letter-spacing:.12em;font:12px Menlo,monospace}h1{font:600 clamp(30px,4.7vw,60px)/1.2 'Songti SC',serif;margin:24px 0;max-width:1050px}h2{font-size:27px;margin:0 0 18px}h3{font-size:19px}a{color:#176751}.badge{display:inline-block;padding:5px 14px;border-radius:3px;font-weight:700;background:${result.nonDeviceGate.passed ? 'var(--accent)' : 'var(--bad)'}}.warning{background:var(--warn)}.intro{max-width:980px;color:var(--muted)}.stats{display:grid;grid-template-columns:repeat(4,1fr);border-bottom:1px solid var(--line)}.stat{padding:24px 15px;border-right:1px solid var(--line)}.stat b{display:block;font:32px/1.4 Menlo,monospace}.stat span{font-size:13px;color:var(--muted)}section{padding:32px 0;border-bottom:1px solid var(--line)}.callout{background:#e3ebdd;border-left:4px solid #2e6650;padding:16px 20px;margin:16px 0}.stopped{background:#fff0d5;border-left-color:#95610e}.columns{display:grid;grid-template-columns:1fr 1fr;gap:28px}.checks{padding-left:0;list-style:none}.checks li{margin:10px 0}.check{display:inline-block;min-width:62px;font-weight:600;margin-right:7px}.ok{color:#286341}.bad{color:#a12c20}.table{overflow:auto}table{width:100%;border-collapse:collapse;min-width:650px}th,td{padding:12px 9px;text-align:left;border-bottom:1px solid var(--line);vertical-align:top}th,small{font-size:12px;color:var(--muted)}code,pre{font:12px/1.6 Menlo,monospace}code{overflow-wrap:anywhere}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#e5ebe1;padding:14px;max-height:520px;overflow:auto}.evidence-item{border:1px solid var(--line);background:#fafbf5;margin:16px 0;min-width:0}.tag{display:inline-block;font-size:11px;border:1px solid var(--line);padding:2px 7px;margin-right:8px}details{padding:14px 20px}summary{cursor:pointer;font-weight:600;overflow-wrap:anywhere}summary small{display:block;margin-top:6px}.filters{display:grid;grid-template-columns:1fr 300px;gap:18px;margin-bottom:18px}input,select{width:100%;padding:11px;font:inherit;border:1px solid var(--line);background:#fff}label{display:block;font-size:13px;margin-bottom:6px}button{font:inherit;background:transparent;border:1px solid var(--line);padding:7px 14px;cursor:pointer}footer{padding-top:25px;color:var(--muted);font-size:12px}[hidden]{display:none!important}@media(max-width:850px){main{padding:24px 18px}.columns{grid-template-columns:1fr}.stats{grid-template-columns:1fr 1fr}.filters{grid-template-columns:1fr}}@media print{.filters,.tools{display:none}article{break-inside:avoid}main{padding:15px}}
</style></head><body><main><header><div class="eyebrow">LYNX / OTA USER SELECTION / HARMONY / NON-DEVICE</div><h1>Harmony OTA 用户灰度<br>非设备验证报告</h1><span class="badge">${result.nonDeviceGate.passed ? 'Harmony 非设备门禁通过' : 'Harmony 非设备门禁未通过'}</span> <span class="badge warning">模拟器按用户要求不执行；真机本轮未验收</span><p class="intro">实际 .ets 源码转译到 Node，使用明确的系统 API 适配；其中 HTTP 调用连接真实本地 Server。Hvigor 的 HAR/App 编译作为另一层证据呈现。宿主通过不等于 Harmony 系统 I/O、ArkUI 页面或设备通过。</p><p><a href="#evidence">筛选与展开用例</a> · <a href="#build">构建文件指纹</a> · <a href="#profile">BuildProfile 保护</a> · <a href="#boundary">未验证边界</a> · <a href="${base}/summary.json">完整汇总 JSON</a></p></header>
<div class="stats"><div class="stat"><b>${result.host.counts.passed}/${result.host.counts.total}</b><span>实际源码 host 测试；模式 ${esc(result.host.mode)}；失败 ${result.host.counts.failed} / 跳过 ${result.host.counts.skipped}</span></div><div class="stat"><b>${result.core.counts.passed}/${result.core.counts.total}</b><span>核心 TAP 宿主测试；失败 ${result.core.counts.failed} / 跳过 ${result.core.counts.skipped}</span></div><div class="stat"><b>${Number(result.builds.har.passed) + Number(result.builds.app.passed)}/2</b><span>HAR / App Hvigor 构建日志成功</span></div><div class="stat"><b>未验收</b><span>模拟器按用户要求不执行；真机本轮未验收；candidate 为设计不适用</span></div></div>
<section><h2>非设备门禁</h2><div class="columns"><ul class="checks">${checkList}</ul><div><p>host 计数来自 JSON 的逐项结果并与 summary 校对；core 计数来自 TAP 的逐项、plan 和 footer。所有数值都读取输入，不把预期数量当作实际通过数。</p><p>实际 Server 来源：<code>${esc(result.host.serverOrigin ?? '未提供')}</code><br>对应 ${result.host.httpTestCount} 项 HTTP 集成、${result.host.phaseCount} 个采集 phase；它们是 host 总数的子集。</p>${result.nonDeviceGate.problems.length ? `<div class="callout stopped"><strong>来源问题</strong><ul>${result.nonDeviceGate.problems.map((item) => `<li>${esc(item)}</li>`).join('')}</ul></div>` : '<div class="callout">绿色状态仅认证本轮非设备门禁。未验证的系统 I/O、页面和设备仍保持未验证。</div>'}</div></div></section>
<section id="evidence"><h2>分层测试与真实 HTTP 证据</h2><div class="filters"><div><label for="filter">关键词</label><input id="filter" type="search" placeholder="例如：epoch、回滚、repair、lease、30 分钟"></div><div><label for="kind">证据层</label><select id="kind"><option value="all">全部</option><option value="host-pure">实际 .ets + Node 宿主</option><option value="host-http">实际 .ets + 真实 Server HTTP</option><option value="core">核心 TAP / 宿主</option></select></div></div><p class="tools"><button id="expand" type="button">展开当前结果</button> <button id="collapse" type="button">收起当前结果</button> <span id="matches" aria-live="polite"></span></p><div class="callout">证据类型：<code>${HOST_KIND}</code>；<code>deviceTested=false</code>；<code>nativeIOValidated=false</code>。Node 系统适配的说明与方法清单保留在各项 JSON 中。</div>${testCards}${coreCards}</section>
<section id="build"><h2>真正的 Hvigor 编译与构建文件</h2><div class="table"><table><thead><tr><th>构建</th><th>原文件 / 大小</th><th>实际 SHA-256</th><th>日志结果</th></tr></thead><tbody>${artifactRows}</tbody></table></div><p><a href="${base}/har-build.log">HAR 构建日志（脱敏）</a> · <a href="${base}/app-build.log">App 构建日志（脱敏）</a> · <a href="${base}/artifacts.json">文件元数据</a></p><p>HAR/App 二进制只读取并计算哈希，不复制进 docs；文件存在和编译成功不代表签名、安装或设备行为已验证。</p></section>
<section id="profile"><h2>用户 BuildProfile 修改保护</h2><p>文件：<code>${esc(result.protectedProfile.before.path)}</code></p><div class="table"><table><thead><tr><th>保护基线</th><th>采集前 SHA</th><th>采集后 SHA</th><th>结果</th></tr></thead><tbody><tr><td><code>${PROFILE_SHA}</code></td><td><code>${result.protectedProfile.before.sha256}</code></td><td><code>${result.protectedProfile.after.sha256}</code></td><td>${result.protectedProfile.unchanged ? '哈希保持一致' : '变化：非设备门禁不得通过'}</td></tr></tbody></table></div><p>不读取内容进报告，不修复、不覆盖此文件。被测 .ets 与当前源码的对应 SHA 见 <a href="${base}/sources.json">sources.json</a>。</p></section>
<section id="boundary"><h2>明确未验证与设计不适用</h2><div class="callout stopped"><p><strong>设备：</strong>${esc(result.device.reason)}</p><p><strong>Harmony 系统 I/O：</strong>${esc(result.nativeIO.reason)}</p><p><strong>页面与首屏：</strong>${esc(result.ui.reason)}</p><p><strong>candidate：</strong>${esc(result.candidate.reason)}</p></div><p>candidate 不适用不计入通过数，也不是 TAP skip；页面、系统 IO 和设备不从 Node 适配或编译结果推导通过。本报告没有设备截图画廊。</p></section>
<section><h2>来源与复现</h2><ul><li>host 输入与源文件 SHA、原始日志和二进制指纹见 <a href="${base}/inputs.json">inputs.json</a>。</li><li><a href="${base}/host-summary.json">host 输入摘要（脱敏副本）</a> · <a href="${base}/core.tap.log">核心 TAP（脱敏）</a> · <a href="${base}/core-summary.json">TAP 解析结果</a>。</li><li>测试源码在 host 加载后及当前采集时均做指纹核对；漂移会阻止门禁通过。</li><li>系统版本 mocks 是测试输入，不冒充原生 bundleManager/LynxEnv 的设备读取。</li><li>原始输入不修改；本采集器不执行 Node 测试、网络请求、Hvigor、HDC 或设备。</li></ul><details><summary>展开机器可读门禁与边界</summary><pre>${esc(JSON.stringify({ nonDeviceGate: result.nonDeviceGate, candidate: result.candidate, device: result.device, nativeIO: result.nativeIO, ui: result.ui }, null, 2))}</pre></details></section>
<footer>生成于 ${esc(result.generatedAt)} · runId ${esc(result.runId)} · scripts/collect-harmony-user-gray-report.mjs</footer></main><script>
const items=[...document.querySelectorAll('.evidence-item')];function filter(){const text=document.querySelector('#filter').value.trim().toLowerCase(),kind=document.querySelector('#kind').value;for(const item of items)item.hidden=(kind!=='all'&&item.dataset.kind!==kind)||!item.textContent.toLowerCase().includes(text);document.querySelector('#matches').textContent='显示 '+items.filter(item=>!item.hidden).length+' / '+items.length+' 项'}document.querySelector('#filter').addEventListener('input',filter);document.querySelector('#kind').addEventListener('change',filter);document.querySelector('#expand').addEventListener('click',()=>items.filter(item=>!item.hidden).forEach(item=>item.querySelectorAll('details').forEach(detail=>detail.open=true)));document.querySelector('#collapse').addEventListener('click',()=>items.forEach(item=>item.querySelectorAll('details').forEach(detail=>detail.open=false)));filter();
</script></body></html>`;
}

function writeReport(result) {
  const destination = path.join(EVIDENCE_ROOT, result.runId);
  if (fs.existsSync(destination)) throw new Error('证据目录已存在，请使用新 run-id 保留历史');
  fs.mkdirSync(EVIDENCE_ROOT, { recursive: true });
  if (fs.realpathSync(EVIDENCE_ROOT) !== path.resolve(EVIDENCE_ROOT)) throw new Error('证据根目录不能通过符号链接写入其他位置');
  const staging = fs.mkdtempSync(path.join(EVIDENCE_ROOT, `.staging-${result.runId}-`));
  const summary = { ...result }; delete summary.redacted;
  try {
    const json = (file, value) => fs.writeFileSync(path.join(staging, file), `${JSON.stringify(value, null, 2)}\n`);
    json('summary.json', summary); json('inputs.json', result.inputs); json('sources.json', result.sources);
    json('host-summary.json', result.redacted.host); json('core-summary.json', result.core);
    json('artifacts.json', { builds: result.builds, artifacts: result.artifacts, protectedProfile: result.protectedProfile });
    fs.mkdirSync(path.join(staging, 'host-tests'));
    result.host.tests.forEach((item, index) => json(`host-tests/${String(index + 1).padStart(2, '0')}.json`, item));
    fs.writeFileSync(path.join(staging, 'core.tap.log'), result.redacted.coreTap);
    fs.writeFileSync(path.join(staging, 'har-build.log'), result.redacted.harLog);
    fs.writeFileSync(path.join(staging, 'app-build.log'), result.redacted.appLog);
    fs.writeFileSync(path.join(staging, 'report.html'), render(result));
    fs.renameSync(staging, destination);
    fs.renameSync(path.join(destination, 'report.html'), HTML_FILE);
  } finally {
    if (fs.existsSync(staging)) fs.rmSync(staging, { recursive: true, force: true });
  }
  return { report: HTML_FILE, evidenceDir: destination };
}

async function main() {
  if (process.argv.includes('--help')) { help(); return; }
  const options = args(process.argv.slice(2));
  const result = await collect(options);
  const output = options.validateOnly ? { written: false } : writeReport(result);
  console.log(JSON.stringify({ ...output, runId: result.runId, nonDeviceGatePassed: result.nonDeviceGate.passed,
    host: result.host.counts, core: result.core.counts, realHttpTests: result.host.httpTestCount,
    harBuildPassed: result.builds.har.passed, appBuildPassed: result.builds.app.passed,
    harSha256: result.artifacts.har.sha256, appSha256: result.artifacts.app.sha256,
    buildProfileUnchanged: result.protectedProfile.unchanged,
    candidateStatus: result.candidate.status, deviceStatus: result.device.status, nativeIOValidated: false,
    failedChecks: result.nonDeviceGate.checks.filter((item) => !item.passed).map((item) => item.label), problems: result.nonDeviceGate.problems }, null, 2));
  if (!result.nonDeviceGate.passed) process.exitCode = 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { console.error(cleanText(error.message)); process.exitCode = 1; });
}
