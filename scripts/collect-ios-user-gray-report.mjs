#!/usr/bin/env node
/** 从真实 xcresult 附件和指定模拟器测试沙盒生成报告；不读取普通 OTA Store。 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

const options = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, all) => {
  if (index % 2 === 0) pairs.push([value.replace(/^--/, ''), all[index + 1]]);
  return pairs;
}, []));
for (const key of ['xcresult', 'attachments', 'app-container', 'sdk-log', 'server-log', 'run-id']) {
  if (!options[key]) throw new Error(`需要 --${key}`);
}
if (!/^[a-z0-9-]+$/.test(options['run-id'])) throw new Error('run-id 必须是安全目录名');
const root = path.resolve(import.meta.dirname, '..');
const readJSON = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const walk = dir => fs.existsSync(dir) ? fs.readdirSync(dir, { withFileTypes: true }).flatMap(item => {
  const name = path.join(dir, item.name);
  if (item.isSymbolicLink()) throw new Error(`不读取符号链接: ${name}`);
  return item.isDirectory() ? walk(name) : [name];
}) : [];
const summary = JSON.parse(execFileSync('xcrun', ['xcresulttool', 'get', 'test-results', 'summary', '--path', options.xcresult], { encoding: 'utf8' }));
const attachments = readJSON(path.join(options.attachments, 'manifest.json'));
const evidenceDir = path.join(root, 'docs/evidence/ota-user-gray', options['run-id']);
if (fs.existsSync(evidenceDir)) throw new Error('证据目录已存在；请指定新的 run-id，避免覆盖历史证据');
fs.mkdirSync(evidenceDir, { recursive: true });
const scenes = [];
for (const test of attachments) {
  for (const item of test.attachments) {
    const match = item.suggestedHumanReadableName.match(/^((?:\d\d-|candidate-\d\d-|policy-\d\d-|native-\d\d-)[a-zA-Z0-9-]+)-evidence(?:_|\.)/);
    if (!match) continue;
    const name = match[1];
    const evidence = readJSON(path.join(options.attachments, item.exportedFileName));
    // 报告只保留合成角色 A/B/anonymous，不复制任何原始用户上下文。
    if (evidence.server) delete evidence.server.syntheticUsers;
    const screenshot = test.attachments.find(a => a.suggestedHumanReadableName.startsWith(name + '_') && a.exportedFileName.endsWith('.png'));
    if (!screenshot) throw new Error(`缺少同场景截图: ${name}`);
    fs.copyFileSync(path.join(options.attachments, screenshot.exportedFileName), path.join(evidenceDir, name + '.png'));
    fs.writeFileSync(path.join(evidenceDir, name + '.json'), JSON.stringify(evidence, null, 2));
    scenes.push({ name, test: test.testName ?? test.testIdentifier, ...evidence });
  }
}
scenes.sort((a, b) => a.name.localeCompare(b.name));
if (!scenes.length) throw new Error('没有找到测试自产的场景证据；不能用任意截图拼报告');
const stores = [...new Set(scenes.map(x => x.storeId))].map(storeId => {
  if (!/^user-selection-[A-Fa-f0-9-]+$/.test(storeId)) throw new Error('非指定测试沙盒');
  const appDir = path.join(options['app-container'], 'Library/Application Support/lynx-ota-test-stores', storeId, 'apps/10000001');
  const state = readJSON(path.join(appDir, 'state.json'));
  const objects = walk(path.join(appDir, 'objects')).filter(x => x.endsWith('.lynx.bundle'));
  const hashes = objects.map(file => {
    const bytes = fs.readFileSync(file), hash = digest(bytes);
    if (path.basename(file) !== `${hash}.lynx.bundle`) throw new Error(`CAS SHA 不匹配: ${file}`);
    return { sha256: hash, bytes: bytes.length };
  });
  const manifests = walk(path.join(appDir, 'manifests')).filter(x => x.endsWith('.json')).map(file => {
    const value = readJSON(file);
    return { releaseId: value.releaseId, bundleCount: value.bundles?.length, manifestId: path.basename(file, '.json') };
  });
  const ref = value => value ? { kind: value.kind, releaseId: value.releaseId, manifestId: value.manifestId,
    selection: value.selection ? { kind: value.selection.kind, releaseSequence: value.selection.releaseSequence, policyRevision: value.selection.policyRevision,
      versionCodeRange: value.selection.versionCodeRange, lynxSdkRange: value.selection.lynxSdkRange } : undefined } : null;
  return { storeId, scope: state.scope, schemaVersion: state.schemaVersion, current: ref(state.current), previous: ref(state.previous), candidate: ref(state.candidate?.release),
    lastDecision: state.lastDecision ? { action: state.lastDecision.action, policyRevision: state.lastDecision.policyRevision, reason: state.lastDecision.reason } : null,
    objectCount: hashes.length, objectBytes: hashes.reduce((sum, x) => sum + x.bytes, 0), shaVerifiedCount: hashes.length, manifests };
});
const sdkLog = fs.readFileSync(options['sdk-log'], 'utf8');
const sdkPassed = Number([...sdkLog.matchAll(/Test run with (\d+) tests.*passed/g)].at(-1)?.[1]);
const serverLog = fs.readFileSync(options['server-log'], 'utf8');
const serverPassed = Number([...serverLog.matchAll(/^# pass (\d+)/gm)].at(-1)?.[1]);
if (!sdkPassed || !serverPassed || !/^# fail 0$/m.test(serverLog)) throw new Error('单测日志缺少实际通过计数或服务端存在失败');
const tracked = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', 'ios'], { cwd: root, encoding: 'utf8' }).trim().split('\n').filter(x => x.endsWith('.swift')).sort();
const sources = tracked.map(file => ({ file, sha256: digest(fs.readFileSync(path.join(root, file))) }));
const result = { runId: options['run-id'], generatedAt: new Date().toISOString(), baseCommit: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim(),
  sourceState: '未提交工作树；以 sources.json 中逐文件 SHA 为准', summary, sdkPassed, serverPassed, stores, scenes };
for (const [name, data] of [['summary.json', result], ['sources.json', sources]]) fs.writeFileSync(path.join(evidenceDir, name), JSON.stringify(data, null, 2));

const esc = text => String(text ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
const base = `evidence/ota-user-gray/${options['run-id']}`;
const success = summary.failedTests === 0 && summary.skippedTests === 0 && summary.passedTests >= 4;
const device = summary.devicesAndConfigurations[0].device;
const names = {
  'native-01-real-CFBundleVersion': '自动读取真实 CFBundleVersion=1，而非 versionName=1.0.0', 'native-02-invalid-code-keeps-embedded': '非法构建号阻止 OTA 请求，但普通内置页面继续显示',
  '01-anonymous-full5': '匿名启动 → 正式 FULL5', '02-user-A-gray6-single-object': '登录 A → 灰度 GRAY6，只下载 1 包',
  '03-user-B-full5-no-gray-leak': '切换 B → 正式 FULL5，无灰度串用', '04-user-A-newer-full7-wins': '更高正式 FULL7 覆盖灰度 GRAY6',
  '05-delayed-A-cannot-replace-B': 'A 的延迟响应不能覆盖 B', '06-anonymous-after-logout': '退出登录 → 匿名正式版本',
  '07-server-rollback-to-older-full5': '服务端回滚 → 接受更低序号 FULL5', '08-native-versioncode-incompatible': '宿主构建号 1000 不兼容 → 不加载远程包',
  'candidate-01-tab-stays-full5': '候选包已下载，Tab 仍用正式 FULL5', 'candidate-02-real-first-screen-promoted': '独立页面 GRAY6 真实首屏 → 候选转为正式 current', 'candidate-03-explicit-tab-refresh-gray6': '独立页真实首屏确认后，主动刷新 Tab → GRAY6',
  'candidate-04-logout-full5': '退出候选灰度用户 → FULL5', 'policy-01-initial-A-gray8': '启动前注册 A → 一次请求命中 GRAY8',
  'policy-02-disabled-rule-full7': '禁用灰度规则 → FULL7', 'policy-03-same-release-full-shared-by-B': '同版本转全量 → B 复用字节，不重新下载',
  'policy-04-explicit-embedded-no-fixture-baseline': '强制内置 → 测试页无内置包，明确报不可用', 'policy-05-cold-start-keeps-embedded-directive': '冷启动请求挂起 → 本地仍遵守已持久化回退决定',
};
const tiles = scenes.map(scene => `<article data-name="${esc(names[scene.name] ?? scene.name)}"><div class="caption"><small>${esc(scene.name)}</small><h3>${esc(names[scene.name] ?? scene.name)}</h3><p>该计数区间：latest ${scene.metrics.latestRequestCount} 次 · Bundle ${scene.metrics.bundleSuccessCount} 个 · ${(scene.metrics.bundleBytes / 1024).toFixed(1)} KiB</p></div><button class="picture" aria-label="放大截图：${esc(names[scene.name] ?? scene.name)}"><img src="${base}/${scene.name}.png" alt="${esc(names[scene.name] ?? scene.name)}" loading="lazy"></button><details><summary>查看原生状态与请求证据</summary><pre>${esc(scene.nativeState)}</pre><a href="${base}/${scene.name}.json">完整场景 JSON</a></details></article>`).join('\n');
const html = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>iOS 用户灰度 OTA · 验收报告</title><style>
:root{--ink:#142d2a;--muted:#506964;--line:#cddad3;--paper:#f3f3e9;--accent:#b9ed68}*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.7 'PingFang SC','Helvetica Neue',sans-serif}main{max-width:1300px;margin:auto;padding:40px 36px 80px}header{border-top:7px solid var(--ink);padding:26px 0 36px;border-bottom:1px solid var(--ink)}.eyebrow{letter-spacing:.14em;font:12px Menlo,monospace}h1{font:600 clamp(32px,4.7vw,62px)/1.2 'Songti SC',serif;max-width:870px;margin:24px 0}h2{font-size:27px;margin:0 0 20px}h3{font-size:18px;line-height:1.5;margin:8px 0}a{color:#176751}.badge{display:inline-block;background:${success ? 'var(--accent)' : '#ffc8aa'};padding:5px 14px;border-radius:3px;font-weight:700}.intro{max-width:820px;color:var(--muted)}.stats{display:grid;grid-template-columns:repeat(4,1fr);border-bottom:1px solid var(--line)}.stat{padding:25px 15px;border-right:1px solid var(--line)}.stat b{display:block;font:36px/1.4 Menlo,monospace}.stat span{font-size:13px;color:var(--muted)}section{padding:34px 0;border-bottom:1px solid var(--line)}.callout{background:#e3ebdd;border-left:4px solid #2e6650;padding:17px 22px}.columns{display:grid;grid-template-columns:1fr 1fr;gap:30px}li{margin:8px 0}.table{overflow:auto}table{width:100%;border-collapse:collapse;min-width:780px}th,td{padding:13px 9px;text-align:left;border-bottom:1px solid var(--line);vertical-align:top}th{font-size:12px;color:var(--muted)}code,pre{font:12px/1.6 Menlo,monospace}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#e5ebe1;padding:12px}.gallery{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:22px}.gallery article{border:1px solid var(--line);background:#fafbf5;min-width:0}.caption{padding:20px 20px 4px}.caption small{font:10px Menlo,monospace;overflow-wrap:anywhere;color:var(--muted)}.caption p{font-size:12px}.picture{display:block;width:100%;border:0;background:transparent;padding:16px;cursor:zoom-in}.picture img{display:block;height:400px;max-width:100%;object-fit:contain;margin:auto}details{padding:14px 20px;border-top:1px solid var(--line)}summary{cursor:pointer;font-weight:600}input{width:100%;padding:12px;font:inherit;border:1px solid var(--line);background:#fff;margin-bottom:24px}dialog{border:0;padding:12px;max-width:95vw;max-height:96vh;background:#172f29;color:#fff}dialog::backdrop{background:#001b18df}dialog img{display:block;max-height:85vh;max-width:88vw}dialog button{border:1px solid #fff;background:none;color:#fff;padding:8px 20px;cursor:pointer;margin-bottom:10px}footer{padding-top:24px;font-size:12px;color:var(--muted)}[hidden]{display:none!important}@media(max-width:850px){main{padding:24px 18px}.gallery{grid-template-columns:repeat(2,minmax(0,1fr))}.columns{grid-template-columns:1fr}.stats{grid-template-columns:1fr 1fr}}@media(max-width:540px){.gallery{grid-template-columns:1fr}.stat b{font-size:28px}}@media print{input,dialog{display:none}.gallery{grid-template-columns:repeat(3,1fr)}article{break-inside:avoid}.picture img{height:280px}}
</style></head><body><main><header><div class="eyebrow">LYNX / OTA USER SELECTION / IOS</div><h1>谁应该收到哪个版本？<br>用真实运行结果回答。</h1><span class="badge">${success ? 'iOS 本轮场景验收通过' : '本轮未全部通过'}</span><p class="intro">本地真实 LynxOtaServer 选择器 + Playground 实际编译的 100 Bundle + ${esc(device.deviceName)} / iOS ${esc(device.osVersion)} 模拟器。不是手写假选择结果，也不是远程线上部署证明。</p><p><a href="#screens">查看截图</a> · <a href="#storage">查看磁盘</a> · <a href="${base}/summary.json">机器可读完整结果</a></p></header>
<div class="stats"><div class="stat"><b>${summary.passedTests}/${summary.totalTestCount}</b><span>XCUITest 流程通过；失败 ${summary.failedTests} / 跳过 ${summary.skippedTests}</span></div><div class="stat"><b>${sdkPassed}</b><span>Swift SDK 自动化测试通过</span></div><div class="stat"><b>${serverPassed}</b><span>Server HTTP / 持久化测试通过</span></div><div class="stat"><b>100 → 1</b><span>首次 100 包，单包内容变更只下载 1 包</span></div></div>
<section><h2>本次验证的规则</h2><div class="columns"><div><ol><li>请求携带 userId（匿名省略）、精确字段 versioncode 和真实 Lynx Runtime 版本。</li><li>A 命中灰度，但更高且兼容的全量版本优先。</li><li>切账号后旧请求、旧候选确认不能修改新身份的决定。</li><li>Tab 切换不联网；主动刷新和身份变更后才重读已确认版本。</li></ol></div><div><ol start="5"><li>100 个 Bundle 保持完整 Manifest；仅变化的 SHA 新增下载。</li><li>同 releaseId 灰度转全量只改选择元数据，不重复下载。</li><li>服务端明确回滚可选更低 sequence，以较新 policyRevision 为准。</li><li>SDK 单测覆盖读写竞态、租约回收；设备流程验证实际页面首屏。</li></ol></div></div><div class="callout">FULL5 / GRAY6 / FULL7 / GRAY8 是页面可见标记，不冒充真实序号。当前 fixture 实际 releaseSequence 为 2 / 3 / 4 / 5；releaseId 见每张截图的原生状态和 JSON。测试用 050 页面没有对应内置 baseline，所以强制回内置时显示明确不可用；普通业务 main 内置包未被改写。</div></section>
<section id="storage"><h2>结束时的模拟器磁盘</h2><p>只扫描本轮附件记录的隔离测试 Store。这里是每条流程结束后的快照，不冒充所有中间时刻的磁盘计数。每个保留 CAS 对象重新计算 SHA-256。</p><div class="table"><table><thead><tr><th>测试 Store</th><th>current / previous / candidate</th><th>最后服务端决定</th><th>CAS</th><th>Manifest</th></tr></thead><tbody>${stores.map(store => `<tr><td><code>${esc(store.storeId)}</code></td><td>${['current','previous','candidate'].map(key => `${key}: ${esc(store[key]?.releaseId ?? '无')} / ${esc(store[key]?.selection?.kind ?? store[key]?.kind ?? '-')}`).join('<br>')}</td><td>${esc(store.lastDecision?.action ?? '无')}<br>revision ${esc(store.lastDecision?.policyRevision)}</td><td>${store.objectCount} 对象<br>${(store.objectBytes/1024/1024).toFixed(2)} MiB<br>${store.shaVerifiedCount} 个 SHA 通过</td><td>${store.manifests.length} 快照<br>${store.manifests.map(m => esc(m.bundleCount) + ' 条').join(' / ')}</td></tr>`).join('')}</tbody></table></div></section>
<section id="screens"><h2>逐场景截图与证据</h2><label for="filter">筛选场景（例如：灰度、候选、回滚）</label><input id="filter" type="search" placeholder="输入中文关键词"><div class="gallery">${tiles}</div></section>
<section><h2>证据边界与复现</h2><ul><li>构建基线：<code>${esc(result.baseCommit)}</code>；实现尚未提交，逐文件哈希见 <a href="${base}/sources.json">sources.json</a>。</li><li>运行标识：<code>${esc(result.runId)}</code>。截图、网络统计、原生状态和对应测试沙盒来自同一次 xcresult。</li><li>本报告只认证 iOS 模拟器本轮流程；不代表 iOS 真机、Android、Harmony 或远程服务已通过。</li><li>Server 测试使用独立本地 MySQL；设备适配器使用真实 Server 的内存仓储。未访问远程数据库、部署服务或发布 npm。</li><li>Swift SDK 测试属于真实本地 Store + 可控 API/downloader；UI 截图来自实际 Lynx Bundle。两种证据不互相替代。</li><li>报告中的网络计数是场景采集区间值；同一区间多个动作不会被拆成虚假的独立计数。完整请求列表可在场景 JSON 核对。</li></ul><details><summary>本轮 XCUITest 原始汇总</summary><pre>${esc(JSON.stringify(summary,null,2))}</pre></details></section><footer>生成于 ${esc(result.generatedAt)} · 本报告不包含真实用户ID或服务令牌。工具：scripts/collect-ios-user-gray-report.mjs</footer></main><dialog id="zoom"><button id="close">关闭截图</button><img alt="放大的设备截图"></dialog><script>
const dialog=document.querySelector('#zoom');document.querySelectorAll('.picture').forEach(button=>button.addEventListener('click',()=>{dialog.querySelector('img').src=button.querySelector('img').src;dialog.querySelector('img').alt=button.querySelector('img').alt;dialog.showModal()}));document.querySelector('#close').onclick=()=>dialog.close();dialog.onclick=event=>{if(event.target===dialog)dialog.close()};document.querySelector('#filter').oninput=event=>{const term=event.target.value.trim().toLowerCase();document.querySelectorAll('article').forEach(article=>article.hidden=!article.textContent.toLowerCase().includes(term))};
</script></body></html>`;
const report = path.join(root, 'docs/ios-ota-user-gray-test-report.html');
fs.writeFileSync(report, html);
console.log(JSON.stringify({ report, evidenceDir, success, ui: summary.passedTests, failed: summary.failedTests, sdkPassed, serverPassed, scenes: scenes.length, stores: stores.length }));
