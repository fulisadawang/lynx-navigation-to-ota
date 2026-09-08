#!/usr/bin/env node
/** Android 非设备证据采集。只读输入；不执行 Gradle、ADB、模拟器或任何测试。 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const REPORT_PATH = path.join(ROOT, 'docs/android-ota-user-gray-test-report.html');
const EVIDENCE_ROOT = path.join(ROOT, 'docs/evidence/ota-user-gray');
const REAL_SERVER_CLASS = 'com.example.lynxshell.ota.OtaRealServerSelectionTest';
const REQUIRED_EVIDENCE = [
  ['01-real-selection-flow.json', 'real HTTP selects full gray newer full promotion rollback and forced embedded cold state', '真实 HTTP 选择、增量下载、全量化、回滚与冷状态'],
  ['02-held-identity-flow.json', 'held A response fails after B sync and cannot change B state', 'A 响应晚于 B：拒绝旧身份写入'],
  ['03-candidate-protocol-flow.json', 'candidate stays staged until explicit SDK health confirmation then logout and incompatibility reject it', 'JVM 候选协议、显式健康确认、退出与兼容边界'],
];

const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
const integer = (value, label) => {
  if (!/^[0-9]+$/.test(String(value ?? '')) || !Number.isSafeInteger(Number(value))) throw new Error(`${label} 缺少合法整数`);
  return Number(value);
};
const seconds = (value) => {
  const parsed = Number(value ?? 0);
  if (!Number.isFinite(parsed) || parsed < 0) throw new Error('JUnit time 不合法');
  return parsed;
};

function help() {
  console.log(`用法（仓库根目录）：
node scripts/collect-android-user-gray-report.mjs \\
  --junit-dir /absolute/test-results/testDebugUnitTest \\
  --build-log /absolute/final-build.log \\
  --real-server-evidence-dir /absolute/android-jvm-final \\
  --apk /absolute/app-debug.apk \\
  --sdk-build-config /absolute/lynx-shell/build/generated/source/buildConfig/debug/com/example/lynxshell/BuildConfig.java \\
  --run-id android-20260906-final \\
  --apkanalyzer /absolute/Android/sdk/cmdline-tools/latest/bin/apkanalyzer

必填参数：--junit-dir --build-log --real-server-evidence-dir --apk --sdk-build-config --run-id
可选参数：
  --apkanalyzer PATH       显式 APK Analyzer；未给出则从 PATH/Android SDK 常见目录查找。
  --app-build-config FILE  APK Analyzer 不可用时，使用指定生成的 App BuildConfig 提供元数据，并明确标注来源。
                          两者都提供时核对 applicationId/versionCode/versionName 一致。
  --validate-only         只读取、算 SHA、解析并打印门禁结果；不生成 HTML 或证据目录。
  --help                  只显示帮助。

JUnit 目录应来自一个无 --tests 筛选的完整测试任务；脚本读取其全部 XML，不写死测试数量。
门禁：全部 JUnit failure/error/skip=0；${REAL_SERVER_CLASS} 精确三项通过；
三份固定 JSON 必须对应同名测试，evidenceKind=desktop-sdk-real-server、deviceTested=false、screenshots=[]；
BUILD SUCCESSFUL 且无 BUILD FAILED/--tests；生成的 LYNX_RUNTIME_VERSION=4.0.0；APK 存在且元数据可验证。

输出：docs/android-ota-user-gray-test-report.html 与 docs/evidence/ota-user-gray/<run-id>/。
run-id 目录不可覆盖；HTML 更新为本次结果。输入不合格时不得显示门禁通过，退出码为 1。
APK 只记录路径、字节数、SHA-256、元数据，不复制 APK。不会导入/制造任何设备截图。
设备栏始终显示：用户取消，未完成；历史 0 场景通过、19 未验收、1 次 metadata 解析失败。
本脚本不执行 Gradle、ADB、模拟器、设备测试或 JVM 测试。`);
}

function parseArgs(argv) {
  const values = {};
  const known = new Set(['junit-dir', 'build-log', 'real-server-evidence-dir', 'apk', 'sdk-build-config', 'run-id', 'apkanalyzer', 'app-build-config']);
  for (let index = 0; index < argv.length; index++) {
    if (argv[index] === '--validate-only') { values.validateOnly = true; continue; }
    const key = argv[index].replace(/^--/, '');
    if (!argv[index].startsWith('--') || !known.has(key) || !argv[index + 1] || argv[index + 1].startsWith('--')) throw new Error('未知或缺少 CLI 参数，请使用 --help');
    if (values[key] !== undefined) throw new Error(`参数重复：--${key}`);
    values[key] = argv[++index];
  }
  for (const key of ['junit-dir', 'build-log', 'real-server-evidence-dir', 'apk', 'sdk-build-config', 'run-id']) {
    if (!values[key]) throw new Error(`需要 --${key}`);
  }
  if (!/^[a-z0-9][a-z0-9-]{0,79}$/.test(values['run-id'])) throw new Error('run-id 仅允许小写字母、数字、横线，最长 80 字符');
  for (const key of known) if (key !== 'run-id' && values[key]) values[key] = path.resolve(values[key]);
  return values;
}

function statInput(file, directory = false) {
  const stat = fs.lstatSync(file);
  if (stat.isSymbolicLink() || (directory ? !stat.isDirectory() : !stat.isFile())) throw new Error(`输入类型不符或是符号链接：${file}`);
  return stat;
}

async function fileInfo(file, kind) {
  const stat = statInput(file);
  const hash = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return { kind, path: path.resolve(file), bytes: stat.size, sha256: hash.digest('hex'), modifiedAt: stat.mtime.toISOString() };
}

function xmlFiles(directory) {
  statInput(directory, true);
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((item) => {
    const file = path.join(directory, item.name);
    if (item.isSymbolicLink()) throw new Error('JUnit 输入目录不允许符号链接');
    return item.isDirectory() ? xmlFiles(file) : item.isFile() && item.name.endsWith('.xml') ? [file] : [];
  }).sort();
}

function decodeXml(value) {
  return value.replace(/&#x([0-9a-f]+);|&#([0-9]+);|&(quot|apos|lt|gt|amp);/gi, (_, hex, number, named) => {
    if (hex) return String.fromCodePoint(parseInt(hex, 16));
    if (number) return String.fromCodePoint(Number(number));
    return { quot: '"', apos: "'", lt: '<', gt: '>', amp: '&' }[named.toLowerCase()];
  });
}

/** 只构建 JUnit 标签树，不求值 DTD/entity，不读取 system-out 的潜在凭证。 */
function parseXml(xml) {
  if (/<!DOCTYPE|<!ENTITY/i.test(xml)) throw new Error('JUnit XML 不允许 DTD 或外部 entity');
  const root = { name: '#document', attributes: {}, children: [] };
  const stack = [root];
  const tokens = /<!\[CDATA\[[\s\S]*?\]\]>|<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<\/?[A-Za-z_][\w:.-]*(?:"[^"]*"|'[^']*'|[^'">])*>/g;
  for (const match of xml.matchAll(tokens)) {
    const token = match[0];
    if (token.startsWith('<!') || token.startsWith('<?')) continue;
    const name = token.match(/^<\/?([\w:.-]+)/)?.[1];
    if (token.startsWith('</')) {
      if (stack.length <= 1 || stack.pop().name !== name) throw new Error('JUnit XML 标签不匹配');
      continue;
    }
    const attributes = {};
    for (const item of token.matchAll(/([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) {
      if (Object.hasOwn(attributes, item[1])) throw new Error('JUnit XML 存在重复属性');
      attributes[item[1]] = decodeXml(item[2] ?? item[3]);
    }
    const node = { name, attributes, children: [] };
    stack.at(-1).children.push(node);
    if (!token.endsWith('/>')) stack.push(node);
  }
  if (stack.length !== 1 || root.children.length !== 1 || !['testsuite', 'testsuites'].includes(root.children[0].name)) throw new Error('JUnit XML 不是完整 testsuite/testsuites 文档');
  return root;
}

function descendants(node, name) {
  return node.children.flatMap((child) => [...(child.name === name ? [child] : []), ...descendants(child, name)]);
}

function testCase(node, suite) {
  const name = node.attributes.name;
  if (!name) throw new Error('JUnit testcase 缺少名称');
  const statuses = ['failure', 'error', 'skipped'].filter((kind) => node.children.some((child) => child.name === kind));
  if (statuses.length > 1) throw new Error('JUnit testcase 出现互相冲突的结果');
  return { name, className: node.attributes.classname || suite, status: { failure: 'FAILED', error: 'ERROR', skipped: 'SKIPPED' }[statuses[0]] ?? 'PASS', seconds: seconds(node.attributes.time) };
}

function countCases(cases) {
  return { total: cases.length, passed: cases.filter((item) => item.status === 'PASS').length,
    failures: cases.filter((item) => item.status === 'FAILED').length, errors: cases.filter((item) => item.status === 'ERROR').length,
    skipped: cases.filter((item) => item.status === 'SKIPPED').length };
}

async function collectJUnit(directory, inputs) {
  const files = xmlFiles(directory);
  if (!files.length) throw new Error('JUnit 目录没有 XML 文件');
  const suites = [];
  const identities = new Set();
  for (const file of files) {
    const info = await fileInfo(file, 'junit-xml');
    inputs.push(info);
    const document = parseXml(fs.readFileSync(file, 'utf8'));
    for (const node of descendants(document, 'testsuite')) {
      const name = node.attributes.name;
      if (!name) throw new Error('JUnit testsuite 缺少名称');
      const cases = descendants(node, 'testcase').map((entry) => testCase(entry, name));
      const counts = countCases(cases);
      for (const [attribute, key] of [['tests', 'total'], ['failures', 'failures'], ['errors', 'errors'], ['skipped', 'skipped']]) {
        if (integer(node.attributes[attribute], `JUnit ${attribute}`) !== counts[key]) throw new Error(`JUnit ${name} 声明计数与 testcase 不一致`);
      }
      if (descendants(node, 'testsuite').length) continue;
      for (const entry of cases) {
        const identity = `${entry.className}\u0000${entry.name}`;
        if (identities.has(identity)) throw new Error('JUnit 有重复用例，可能混入不同 variant 或历史结果目录');
        identities.add(identity);
      }
      suites.push({ name, file: path.relative(directory, file), sha256: info.sha256, seconds: seconds(node.attributes.time), ...counts, cases });
    }
  }
  const cases = suites.flatMap((suite) => suite.cases);
  return { directory, xmlFileCount: files.length, suiteCount: suites.length, ...countCases(cases), suites,
    realServerCases: cases.filter((item) => item.className === REAL_SERVER_CLASS) };
}

function sanitizeText(value) {
  return String(value)
    .replace(/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/gi, 'Bearer [REDACTED]')
    .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, '[REDACTED_JWT]')
    .replace(/(\b[A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|COOKIE|AUTHORIZATION)[A-Za-z0-9_]*\s*(?:=|:)\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)/gi, '$1[REDACTED]')
    .replace(/https?:\/\/[^\s"'<>]+/g, (raw) => {
      try {
        const url = new URL(raw);
        if (url.username || url.password) { url.username = ''; url.password = ''; }
        for (const key of [...url.searchParams.keys()]) if (/token|secret|password|cookie|user.?id|authorization|api.?key/i.test(key)) url.searchParams.set(key, '[REDACTED]');
        return url.toString();
      } catch { return '[REDACTED_URL]'; }
    });
}

function stringArray(value, label) {
  if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) throw new Error(`${label} 需要字符串数组`);
  return value.map(sanitizeText);
}

function phaseRecord(phase) {
  if (!phase || typeof phase !== 'object' || typeof phase.phase !== 'string' || !['A', 'B', 'anonymous'].includes(phase.audience)) throw new Error('JVM phase 缺少名称或包含非合成身份');
  const result = { phase: sanitizeText(phase.phase), audience: phase.audience, assertions: stringArray(phase.assertions, 'phase.assertions') };
  for (const field of ['serverStage', 'currentReleaseId', 'selectionKind', 'policyRevision', 'candidateReleaseId', 'candidateStatus']) {
    if (phase[field] !== null && typeof phase[field] !== 'string') throw new Error(`JVM phase.${field} 类型不合法`);
    result[field] = phase[field] === null ? null : sanitizeText(phase[field]);
  }
  for (const field of ['casObjectCount', 'latestCompletedCount', 'bundleRequestCount', 'bundleSuccessCount']) result[field] = integer(phase[field], `phase.${field}`);
  if (result.bundleSuccessCount > result.bundleRequestCount) throw new Error('JVM Bundle 成功数大于请求数');
  return result;
}

async function collectRealServer(directory, junit, inputs) {
  statInput(directory, true);
  const entries = [];
  const problems = [];
  for (const [name, expectedTestName, title] of REQUIRED_EVIDENCE) {
    const file = path.join(directory, name);
    if (!fs.existsSync(file)) { problems.push(`缺少真实 Server 证据 ${name}`); continue; }
    try {
      inputs.push(await fileInfo(file, 'desktop-sdk-real-server-json'));
      const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (raw.schemaVersion !== 1 || raw.evidenceKind !== 'desktop-sdk-real-server' || raw.deviceTested !== false || raw.platform !== 'android' || raw.storeVersion !== 'v3') throw new Error('证据类型/平台/Store 标记不符合 JVM 非设备口径');
      if (!Array.isArray(raw.screenshots) || raw.screenshots.length !== 0) throw new Error('JVM 证据不得声明设备截图');
      if (raw.testName !== expectedTestName) throw new Error('JSON testName 与预期真实 Server 测试不对应');
      if (junit.realServerCases.filter((item) => item.name.replace(/\(\)$/, '') === expectedTestName && item.status === 'PASS').length !== 1) throw new Error('找不到该 JSON 对应的唯一通过 JUnit 用例');
      const origin = new URL(raw.serverOrigin);
      if (origin.protocol !== 'http:' || origin.hostname !== '127.0.0.1' || !origin.port || origin.username || origin.password || origin.search || origin.hash || origin.pathname !== '/') throw new Error('真实 Server 来源必须为显式 loopback HTTP origin');
      if (!Array.isArray(raw.phases) || !raw.phases.length) throw new Error('JVM 证据缺少实际 phase');
      const data = { schemaVersion: 1, evidenceKind: raw.evidenceKind, deviceTested: false, screenshots: [],
        platform: 'android', storeVersion: 'v3', serverOrigin: origin.origin, testName: raw.testName,
        assertions: stringArray(raw.assertions, 'assertions'), phases: raw.phases.map(phaseRecord) };
      entries.push({ name, title, data });
    } catch (error) { problems.push(`${name}: ${sanitizeText(error.message)}`); }
  }
  return { directory, requiredFileCount: 3, validFileCount: entries.length,
    phaseCount: entries.reduce((sum, entry) => sum + entry.data.phases.length, 0), entries, problems };
}

function generatedFields(file) {
  statInput(file);
  const text = fs.readFileSync(file, 'utf8');
  if (!/Automatically generated|automatically generated/.test(text)) throw new Error('BuildConfig 必须为实际生成文件');
  const fields = {};
  for (const match of text.matchAll(/public\s+static\s+final\s+String\s+(\w+)\s*=\s*("(?:\\.|[^"\\])*")\s*;/g)) {
    if (['APPLICATION_ID', 'BUILD_TYPE', 'VERSION_NAME', 'LYNX_RUNTIME_VERSION'].includes(match[1])) fields[match[1]] = JSON.parse(match[2]);
  }
  const code = text.match(/public\s+static\s+final\s+int\s+VERSION_CODE\s*=\s*([0-9]+)\s*;/);
  if (code) fields.VERSION_CODE = code[1];
  return fields;
}

function findApkAnalyzer(explicit) {
  if (explicit) { statInput(explicit); return explicit; }
  const sdk = process.env.ANDROID_SDK_ROOT || process.env.ANDROID_HOME || path.join(os.homedir(), 'Library/Android/sdk');
  const candidates = [...(process.env.PATH ?? '').split(path.delimiter).filter(Boolean).map((dir) => path.join(dir, 'apkanalyzer')),
    path.join(sdk, 'cmdline-tools/latest/bin/apkanalyzer')];
  return candidates.find((file) => { try { fs.accessSync(file, fs.constants.X_OK); return fs.statSync(file).isFile(); } catch { return false; } });
}

async function collectApk(options, inputs) {
  const info = await fileInfo(options.apk, 'apk');
  inputs.push(info);
  if (!options.apk.endsWith('.apk') || info.bytes < 4) throw new Error('APK 输入无效');
  const fd = fs.openSync(options.apk, 'r');
  const signature = Buffer.alloc(4);
  try { fs.readSync(fd, signature, 0, 4, 0); } finally { fs.closeSync(fd); }
  if (signature.toString('hex') !== '504b0304') throw new Error('APK 缺少 ZIP 文件头');
  const analyzer = findApkAnalyzer(options.apkanalyzer);
  let metadata;
  let analyzerError;
  if (analyzer) {
    try {
      const run = (command) => execFileSync(analyzer, ['manifest', command, options.apk], { encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] }).trim();
      metadata = { applicationId: run('application-id'), versionCode: run('version-code'), versionName: run('version-name'), sourceKind: 'apk-manifest-apkanalyzer', analyzer };
    } catch { analyzerError = 'APK Analyzer 无法读取 manifest；仅在提供 App BuildConfig 时允许标注来源后回退'; }
  }
  let appBuildConfig;
  if (options['app-build-config']) {
    const source = await fileInfo(options['app-build-config'], 'generated-app-buildconfig');
    inputs.push(source);
    const fields = generatedFields(options['app-build-config']);
    appBuildConfig = { source, applicationId: fields.APPLICATION_ID, versionCode: fields.VERSION_CODE, versionName: fields.VERSION_NAME, buildType: fields.BUILD_TYPE };
  }
  if (!metadata) {
    if (!appBuildConfig) throw new Error(analyzerError ?? '需要可用 apkanalyzer 或显式 --app-build-config 才能读取 APK 元数据');
    metadata = { applicationId: appBuildConfig.applicationId, versionCode: appBuildConfig.versionCode, versionName: appBuildConfig.versionName,
      sourceKind: 'generated-app-buildconfig', sourcePath: appBuildConfig.source.path, note: '元数据来自指定生成配置；未声称直接解析 APK manifest' };
  }
  if (!/^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+$/.test(metadata.applicationId ?? '') || !/^[1-9][0-9]*$/.test(metadata.versionCode ?? '') || typeof metadata.versionName !== 'string' || !metadata.versionName) throw new Error('APK 元数据缺少 applicationId/versionCode/versionName');
  const problems = [];
  if (appBuildConfig && metadata.sourceKind === 'apk-manifest-apkanalyzer') {
    for (const field of ['applicationId', 'versionCode', 'versionName']) if (appBuildConfig[field] !== metadata[field]) problems.push(`APK manifest 与 App BuildConfig 的 ${field} 不一致`);
  }
  return { ...info, metadata, appBuildConfig, analyzerError, copiedToEvidence: false, problems };
}

function gitState() {
  try {
    const run = (args) => execFileSync('git', args, { cwd: ROOT, encoding: 'utf8', timeout: 10000 }).trim();
    return { commit: run(['rev-parse', 'HEAD']), branch: run(['branch', '--show-current']),
      androidChanges: run(['status', '--short', '--', 'android', 'scripts/collect-android-user-gray-report.mjs']),
      note: '记录采集时源码状态，不把未提交工作树等同于某个已发布版本' };
  } catch { return { note: 'Git 状态不可用' }; }
}

async function collect(options) {
  const inputs = [];
  const junit = await collectJUnit(options['junit-dir'], inputs);
  const realServer = await collectRealServer(options['real-server-evidence-dir'], junit, inputs);
  const buildSource = await fileInfo(options['build-log'], 'build-log');
  inputs.push(buildSource);
  const buildText = fs.readFileSync(options['build-log'], 'utf8');
  const build = { source: buildSource, successfulMarkers: [...buildText.matchAll(/\bBUILD SUCCESSFUL\b/g)].length,
    failedMarkers: [...buildText.matchAll(/\bBUILD FAILED\b/g)].length,
    testFilterDetected: /(?:^|\s)--tests(?:\s|=)/m.test(buildText), logArtifact: 'build.log',
    scopeNote: '统计显式传入目录中的全部 JUnit；完整无筛选执行范围由调用方提供对应日志与结果目录' };
  const sdkSource = await fileInfo(options['sdk-build-config'], 'generated-sdk-buildconfig');
  inputs.push(sdkSource);
  const sdkVersion = generatedFields(options['sdk-build-config']).LYNX_RUNTIME_VERSION;
  if (typeof sdkVersion !== 'string' || !/^[0-9]+(?:\.[0-9]+){0,2}$/.test(sdkVersion)) throw new Error('生成的 BuildConfig 缺少合法 LYNX_RUNTIME_VERSION');
  const sdk = { resolvedVersion: sdkVersion, expectedFixtureVersion: '4.0.0', source: sdkSource,
    field: 'LYNX_RUNTIME_VERSION', provenance: '用户指定的实际生成 BuildConfig；不是 LynxEnv.getLynxVersion() 或手写请求覆盖' };
  const apk = await collectApk(options, inputs);
  const checks = [
    { id: 'junit', label: '全部传入 JUnit 无失败、错误或跳过', pass: junit.total > 0 && junit.failures === 0 && junit.errors === 0 && junit.skipped === 0 },
    { id: 'real-server-tests', label: 'OtaRealServerSelectionTest 精确三项通过', pass: junit.realServerCases.length === 3 && junit.realServerCases.every((item) => item.status === 'PASS') },
    { id: 'real-server-json', label: '三份非设备 JSON 存在、合法且与 JUnit 对应', pass: realServer.entries.length === 3 && realServer.problems.length === 0 },
    { id: 'build', label: '构建日志包含 BUILD SUCCESSFUL 且没有 BUILD FAILED', pass: build.successfulMarkers > 0 && build.failedMarkers === 0 },
    { id: 'full-suite', label: '日志未发现 --tests 筛选', pass: !build.testFilterDetected },
    { id: 'sdk-version', label: '生成的实际 Lynx Runtime 版本为 4.0.0', pass: sdkVersion === '4.0.0' },
    { id: 'apk', label: 'APK SHA/元数据可读且来源一致', pass: apk.problems.length === 0 },
  ];
  return {
    schemaVersion: 1, runId: options['run-id'], generatedAt: new Date().toISOString(), evidenceKind: 'android-non-device-report',
    nonDeviceGate: { passed: checks.every((item) => item.pass), checks, problems: [...realServer.problems, ...apk.problems] },
    junit, realServer, build, sdk, apk, inputs, sourceState: gitState(),
    device: {
      status: 'STOPPED_BY_USER_NOT_ACCEPTED', deviceTestedInThisGate: false, scenariosPassed: 0, scenariosUnverified: 19,
      historicalFailureCount: 1, screenshotsIncluded: 0,
      historyProvenance: '本任务首次driver输出及原始failure UI XML记录的历史；不从JVM推导',
      historicalFailure: '首次 driver 在 metadata XML 解析处失败退出，0 passed / 19 planned / 1 failure。',
      offlineFix: '随后修复单引号 XML 属性解析，23 项宿主 self-test 通过；没有设备重跑。',
      cancellation: '用户取消 Android/Harmony 模拟器门禁；设备栏保持未完成/按用户要求停止。',
    },
    boundaries: [
      'SDK/JVM 用例、桌面 OtaSdk + 真实 Server、APK 编译和设备是不同证据层。',
      '候选 health-confirm 为 JVM 显式 SDK 方法调用，不证明 Android onFirstScreen 或真实 UI 首屏。',
      'phase 请求计数为采集时刻/区间累计值，不擅自相加或拆分成单动作计数。',
      '没有导入设备截图；没有把 19 个未验收业务场景标记通过。',
      'APK 只计算 SHA 与读取元数据，不复制 APK 到 docs。',
    ],
    redactedBuildLog: sanitizeText(buildText),
  };
}

const PHASE_TITLES = {
  'anonymous-full5': '匿名正式 full5：首次下载', 'A-gray6': 'A 命中 gray6：复用 99 个对象',
  'B-full5': 'B 使用正式 full5', 'A-full7-wins': '更高全量 full7 覆盖旧灰度', 'A-gray8': 'A 命中新的 gray8',
  'B-gray8-promoted-full': '同版本全量化后 B 复用字节', 'server-rollback-full5': '服务端回滚 full5：按实际 CAS 保留情况补下载',
  'forced-embedded-cold-state': '持久化回退指令：冷 SDK 屏蔽远程', 'held-A-released-after-B': 'B 已完成，迟到 A 不得改写 State',
  'candidate-staged': '候选 pending，current 尚未切换', 'candidate-trial-lease': '候选 trial 与租约',
  'candidate-sdk-health-confirmed': 'JVM 显式 SDK health-confirm（非 UI 首屏）', 'logout-full5': '退出灰度身份',
  'incompatible-version-code': '构建号 1000 不兼容，拒绝远程入口',
};

function renderHtml(result) {
  const base = `evidence/ota-user-gray/${result.runId}`;
  const statusLabel = (status) => ({ PASS: '通过', FAILED: '失败', ERROR: '错误', SKIPPED: '跳过' }[status] ?? status);
  const suiteCards = result.junit.suites.map((suite) => `<article class="evidence-item" data-kind="jvm"><details><summary><span class="tag">SDK / JVM</span> ${esc(suite.name)} <small>${suite.passed}/${suite.total} · 失败 ${suite.failures} / 错误 ${suite.errors} / 跳过 ${suite.skipped}</small></summary><p>原始 XML SHA-256：<code>${esc(suite.sha256)}</code></p><div class="table"><table><thead><tr><th>实际 testcase</th><th>结果</th><th>耗时</th></tr></thead><tbody>${suite.cases.map((item) => `<tr><td>${esc(item.name)}</td><td>${esc(statusLabel(item.status))}</td><td>${item.seconds.toFixed(3)} s</td></tr>`).join('')}</tbody></table></div></details></article>`).join('\n');
  const realCards = result.realServer.entries.map((entry) => `<article class="evidence-item real-card" data-kind="server"><div class="caption"><span class="tag">桌面 SDK + 真实 Server</span><h3>${esc(entry.title)}</h3><p><code>${esc(entry.data.testName)}</code></p><p>${entry.data.phases.length} 个实际 phase · platform=android · Store v3 · deviceTested=false</p></div>${entry.name.startsWith('03-') ? '<p class="callout">此项由 JVM 显式调用 SDK 健康确认；没有验证 Android View、onFirstScreen 或设备候选首屏。</p>' : ''}<div class="table"><table><thead><tr><th>采集阶段</th><th>合成身份 / 选择</th><th>current / candidate</th><th>CAS</th><th>该采集区间 HTTP</th></tr></thead><tbody>${entry.data.phases.map((phase) => `<tr><td>${esc(PHASE_TITLES[phase.phase] ?? phase.phase)}<br><small>${esc(phase.phase)}</small></td><td>${esc(phase.audience)} / ${esc(phase.selectionKind ?? '无远程选择')}<br>revision ${esc(phase.policyRevision ?? '无')}</td><td><code>${esc(phase.currentReleaseId ?? '无')}</code><br><code>${esc(phase.candidateReleaseId ?? '无候选')}</code><br>${esc(phase.candidateStatus ?? '')}</td><td>${phase.casObjectCount} 对象</td><td>latest 完成 ${phase.latestCompletedCount}<br>Bundle 请求 ${phase.bundleRequestCount}<br>Bundle 成功 ${phase.bundleSuccessCount}</td></tr>`).join('')}</tbody></table></div><details><summary>展开测试自产的断言与完整 JSON</summary><p><a href="${base}/real-server/${entry.name}">下载该 JVM 证据 JSON</a></p><pre>${esc(JSON.stringify(entry.data, null, 2))}</pre></details></article>`).join('\n');
  const checks = result.nonDeviceGate.checks.map((item) => `<li><span class="check ${item.pass ? 'ok' : 'bad'}">${item.pass ? '通过' : '未通过'}</span> ${esc(item.label)}</li>`).join('');
  const metadataNote = result.apk.metadata.sourceKind === 'apk-manifest-apkanalyzer'
    ? 'applicationId / versionCode / versionName 由 APK Analyzer 从该 APK manifest 读取。'
    : 'applicationId / versionCode / versionName 来自指定生成的 App BuildConfig；未直接解析 APK manifest，来源已单独记录。';
  return `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Android 用户灰度 OTA · 非设备验证报告</title><style>
:root{--ink:#142d2a;--muted:#506964;--line:#cddad3;--paper:#f3f3e9;--accent:#b9ed68;--warn:#ffe1ab;--bad:#f4b4a6}*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.7 'PingFang SC','Helvetica Neue',sans-serif}main{max-width:1300px;margin:auto;padding:40px 36px 80px}header{border-top:7px solid var(--ink);padding:26px 0 34px;border-bottom:1px solid var(--ink)}.eyebrow{letter-spacing:.12em;font:12px Menlo,monospace}h1{font:600 clamp(30px,4.7vw,60px)/1.2 'Songti SC',serif;margin:24px 0;max-width:1000px}h2{font-size:27px;margin:0 0 18px}h3{font-size:19px;line-height:1.5;margin:8px 0}a{color:#176751}.badge{display:inline-block;background:${result.nonDeviceGate.passed ? 'var(--accent)' : 'var(--bad)'};padding:5px 14px;border-radius:3px;font-weight:700}.warning{background:var(--warn)}.intro{max-width:950px;color:var(--muted)}.stats{display:grid;grid-template-columns:repeat(4,1fr);border-bottom:1px solid var(--line)}.stat{padding:24px 15px;border-right:1px solid var(--line)}.stat b{display:block;font:32px/1.4 Menlo,monospace}.stat span{font-size:13px;color:var(--muted)}section{padding:32px 0;border-bottom:1px solid var(--line)}.callout{background:#e3ebdd;border-left:4px solid #2e6650;padding:16px 20px}.device-stop{background:#fff0d5;border-left-color:#95610e}.columns{display:grid;grid-template-columns:1fr 1fr;gap:28px}.checks{padding-left:0;list-style:none}.checks li{margin:10px 0}.check{display:inline-block;min-width:62px;font-weight:600;margin-right:7px}.ok{color:#286341}.bad{color:#a12c20}.table{overflow:auto}table{width:100%;border-collapse:collapse;min-width:650px}th,td{padding:12px 9px;text-align:left;border-bottom:1px solid var(--line);vertical-align:top}th,small{font-size:12px;color:var(--muted)}code,pre{font:12px/1.6 Menlo,monospace}code{overflow-wrap:anywhere}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#e5ebe1;padding:14px}.evidence-item{border:1px solid var(--line);background:#fafbf5;margin:16px 0;min-width:0}.caption{padding:18px 20px}.tag{display:inline-block;font-size:11px;letter-spacing:.05em;border:1px solid var(--line);padding:2px 7px;margin-right:8px}details{padding:14px 20px}summary{cursor:pointer;font-weight:600;overflow-wrap:anywhere}summary small{display:block;margin-top:6px}.real-card>details{border-top:1px solid var(--line)}.real-card>.callout{margin:0 20px 18px}.filters{display:grid;grid-template-columns:1fr 250px;gap:18px;margin-bottom:18px}input,select{width:100%;padding:11px;font:inherit;border:1px solid var(--line);background:#fff}label{display:block;font-size:13px;margin-bottom:6px}.sources dd{margin:4px 0 15px;overflow-wrap:anywhere}.sources dt{font-weight:600}button{font:inherit;background:transparent;border:1px solid var(--line);padding:7px 14px;cursor:pointer}footer{padding-top:25px;color:var(--muted);font-size:12px}[hidden]{display:none!important}@media(max-width:850px){main{padding:24px 18px}.columns{grid-template-columns:1fr}.stats{grid-template-columns:1fr 1fr}.filters{grid-template-columns:1fr}}@media print{.filters,.tools{display:none}article{break-inside:avoid}main{padding:15px}}
</style></head><body><main>
<header><div class="eyebrow">LYNX / OTA USER SELECTION / ANDROID / NON-DEVICE</div><h1>Android OTA 用户灰度<br>把证据边界写清楚。</h1><span class="badge">${result.nonDeviceGate.passed ? 'Android 非设备门禁通过' : 'Android 非设备门禁未通过'}</span> <span class="badge warning">设备验收未完成 · 按用户要求停止</span><p class="intro">本报告统计显式输入的 SDK/JVM JUnit、桌面 OtaSdk + loopback 真实 Server 证据、构建日志与 APK。设备业务场景仍为 0 通过、19 未验收；没有设备截图，也不将离线解析器修复或 APK 构建视为设备重跑。</p><p><a href="#evidence">筛选证据</a> · <a href="#apk">APK 与实际 Runtime 来源</a> · <a href="#device">历史设备失败与取消</a> · <a href="${base}/summary.json">机器可读汇总</a></p></header>
<div class="stats"><div class="stat"><b>${result.junit.passed}/${result.junit.total}</b><span>全部 SDK/JVM 用例通过；失败 ${result.junit.failures} / 错误 ${result.junit.errors} / 跳过 ${result.junit.skipped}</span></div><div class="stat"><b>${result.junit.realServerCases.filter((item) => item.status === 'PASS').length}/3</b><span>其中真实 Server 集成；有效 JSON ${result.realServer.validFileCount}/3 · ${result.realServer.phaseCount} phases</span></div><div class="stat"><b>${esc(result.sdk.resolvedVersion)}</b><span>实际生成 LYNX_RUNTIME_VERSION</span></div><div class="stat"><b>0/19</b><span>设备业务场景通过 / 尚未验收总数；当前已停止</span></div></div>
<section><h2>非设备门禁</h2><div class="columns"><ul class="checks">${checks}</ul><div><p>JUnit 来源：${result.junit.xmlFileCount} 个 XML、${result.junit.suiteCount} 个 suite。全部计数来自本次实际 XML，没有硬编码预估总数。</p><p>真实 Server JSON 必须与对应的三项通过测试关联，且保持 <code>evidenceKind=desktop-sdk-real-server</code>、<code>deviceTested=false</code>、<code>screenshots=[]</code>。</p>${result.nonDeviceGate.problems.length ? `<div class="callout device-stop"><strong>证据问题</strong><ul>${result.nonDeviceGate.problems.map((item) => `<li>${esc(item)}</li>`).join('')}</ul></div>` : '<p class="callout">绿色状态只表示本轮非设备门禁；设备栏仍保持未完成。</p>'}</div></div></section>
<section id="evidence"><h2>可筛选、可展开的验证证据</h2><div class="filters"><div><label for="filter">关键词</label><input id="filter" type="search" placeholder="例如：灰度、candidate、回滚、具体 testcase"></div><div><label for="kind">证据层</label><select id="kind"><option value="all">全部证据</option><option value="jvm">SDK / JVM JUnit</option><option value="server">桌面 SDK + 真实 Server</option></select></div></div><p class="tools"><button id="expand" type="button">展开当前结果</button> <button id="collapse" type="button">收起当前结果</button> <span id="matches" aria-live="polite"></span></p><p class="callout">HTTP 计数是 JSON 采集时刻的区间值，可能覆盖多个动作。候选确认来自桌面 SDK 的显式方法调用，不是 Android UI 首屏证明。</p>${realCards || '<p class="callout device-stop">没有可接受的真实 Server JSON，非设备门禁不能通过。</p>'}${suiteCards}</section>
<section id="apk"><h2>APK、构建与实际 SDK 版本</h2><div class="columns"><article><h3>APK 指纹</h3><dl class="sources"><dt>文件</dt><dd><code>${esc(result.apk.path)}</code></dd><dt>大小</dt><dd>${result.apk.bytes.toLocaleString('en-US')} 字节 / ${(result.apk.bytes / 1024 / 1024).toFixed(2)} MiB</dd><dt>SHA-256</dt><dd><code>${esc(result.apk.sha256)}</code></dd><dt>applicationId / versionCode / versionName</dt><dd><code>${esc(result.apk.metadata.applicationId)}</code><br>${esc(result.apk.metadata.versionCode)} / ${esc(result.apk.metadata.versionName)}</dd></dl><p>${esc(metadataNote)}</p><p>只读取原 APK，没有将 APK 复制进 docs。</p></article><article><h3>生成配置来源</h3><dl class="sources"><dt>Runtime 版本</dt><dd><code>${esc(result.sdk.field)}=${esc(result.sdk.resolvedVersion)}</code></dd><dt>实际生成文件</dt><dd><code>${esc(result.sdk.source.path)}</code></dd><dt>源文件 SHA-256</dt><dd><code>${esc(result.sdk.source.sha256)}</code></dd></dl><p>${esc(result.sdk.provenance)}</p><p>构建日志：BUILD SUCCESSFUL ${result.build.successfulMarkers} 次，BUILD FAILED ${result.build.failedMarkers} 次。</p><p><a href="${base}/build.log">经过脱敏的构建日志</a> · <a href="${base}/artifact-metadata.json">APK / BuildConfig 元数据与来源</a></p></article></div></section>
<section id="device"><h2>设备边界：未完成，按用户要求停止</h2><div class="callout device-stop"><p><strong>历史事实保持不变：</strong>${esc(result.device.historicalFailure)}</p><p>${esc(result.device.offlineFix)}</p><p>${esc(result.device.cancellation)}</p><p>0 个业务场景通过，19 个未验收，保留 1 次失败。该历史来自本任务首次 driver 输出及原始 failure UI XML 记录，不从 JVM 推导；本次采集不运行、重写或补造设备结果。</p></div><p>本报告没有截图画廊。JVM 真实 HTTP 与文件 Store 验证不证明 Native Tab、Android View 首屏、设备候选激活或模拟器磁盘行为。</p></section>
<section><h2>来源与复现边界</h2><ul>${result.boundaries.map((item) => `<li>${esc(item)}</li>`).join('')}<li>当前 Git：<code>${esc(result.sourceState.commit ?? '不可用')}</code> / ${esc(result.sourceState.branch ?? '不可用')}；${esc(result.sourceState.note)}。</li><li>输入原文件的大小、SHA 与 mtime 见 <a href="${base}/inputs.json">inputs.json</a>；JUnit 结构化计数见 <a href="${base}/junit-summary.json">junit-summary.json</a>。</li><li>BuildConfig 只提取允许的版本字段，不复制可能含 token 的完整生成文件。APK 不复制，设备截图不读取。</li></ul><details><summary>展开门禁及采集元数据</summary><pre>${esc(JSON.stringify({ runId: result.runId, nonDeviceGate: result.nonDeviceGate, sourceState: result.sourceState, device: result.device }, null, 2))}</pre></details></section>
<footer>生成于 ${esc(result.generatedAt)} · 运行标识 ${esc(result.runId)} · scripts/collect-android-user-gray-report.mjs · 本脚本不执行 Gradle/ADB/设备测试。</footer></main><script>
const items=[...document.querySelectorAll('.evidence-item')];function applyFilter(){const text=document.querySelector('#filter').value.trim().toLowerCase(),kind=document.querySelector('#kind').value;for(const item of items)item.hidden=(kind!=='all'&&item.dataset.kind!==kind)||!item.textContent.toLowerCase().includes(text);document.querySelector('#matches').textContent='显示 '+items.filter(item=>!item.hidden).length+' / '+items.length+' 项'}document.querySelector('#filter').addEventListener('input',applyFilter);document.querySelector('#kind').addEventListener('change',applyFilter);document.querySelector('#expand').addEventListener('click',()=>items.filter(item=>!item.hidden).forEach(item=>item.querySelectorAll('details').forEach(detail=>detail.open=true)));document.querySelector('#collapse').addEventListener('click',()=>items.forEach(item=>item.querySelectorAll('details').forEach(detail=>detail.open=false)));applyFilter();
</script></body></html>`;
}

function publishReport(result) {
  const destination = path.join(EVIDENCE_ROOT, result.runId);
  if (fs.existsSync(destination)) throw new Error('run-id 证据目录已存在；请使用新的 run-id 保留历史');
  fs.mkdirSync(EVIDENCE_ROOT, { recursive: true });
  if (fs.realpathSync(EVIDENCE_ROOT) !== path.resolve(EVIDENCE_ROOT)) throw new Error('证据根目录不能通过符号链接写入其他位置');
  const staging = fs.mkdtempSync(path.join(EVIDENCE_ROOT, `.staging-${result.runId}-`));
  const htmlTemporary = path.join(staging, 'report.html');
  const summary = { ...result };
  delete summary.redactedBuildLog;
  try {
    const writeJson = (file, value) => fs.writeFileSync(path.join(staging, file), `${JSON.stringify(value, null, 2)}\n`);
    writeJson('summary.json', summary);
    writeJson('inputs.json', result.inputs);
    writeJson('junit-summary.json', result.junit);
    writeJson('artifact-metadata.json', { apk: result.apk, sdk: result.sdk, build: result.build });
    fs.writeFileSync(path.join(staging, 'build.log'), result.redactedBuildLog);
    fs.mkdirSync(path.join(staging, 'real-server'));
    for (const entry of result.realServer.entries) writeJson(`real-server/${entry.name}`, entry.data);
    fs.writeFileSync(htmlTemporary, renderHtml(result));
    fs.renameSync(staging, destination);
    fs.renameSync(path.join(destination, 'report.html'), REPORT_PATH);
  } finally {
    if (fs.existsSync(staging)) fs.rmSync(staging, { recursive: true, force: true });
  }
  return { report: REPORT_PATH, evidenceDir: destination };
}

async function main() {
  if (process.argv.includes('--help')) { help(); return; }
  const options = parseArgs(process.argv.slice(2));
  const result = await collect(options);
  const output = options.validateOnly ? { written: false } : publishReport(result);
  console.log(JSON.stringify({ ...output, runId: result.runId, nonDeviceGatePassed: result.nonDeviceGate.passed,
    junit: { total: result.junit.total, passed: result.junit.passed, failures: result.junit.failures, errors: result.junit.errors, skipped: result.junit.skipped },
    realServerTests: result.junit.realServerCases.length, realServerJson: result.realServer.validFileCount, realServerPhases: result.realServer.phaseCount,
    sdkVersion: result.sdk.resolvedVersion, apkSha256: result.apk.sha256, deviceStatus: result.device.status,
    failedChecks: result.nonDeviceGate.checks.filter((item) => !item.pass).map((item) => item.label), problems: result.nonDeviceGate.problems }, null, 2));
  if (!result.nonDeviceGate.passed) process.exitCode = 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { console.error(sanitizeText(error.message)); process.exitCode = 1; });
}
