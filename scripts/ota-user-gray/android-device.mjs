#!/usr/bin/env node
import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { setTimeout as pause } from 'node:timers/promises'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const STATE_PREFIX = 'ota-user-debug-state|'
const CONTROL_HEADERS = { 'x-ota-fixture-control': 'local-fixture-only', 'content-type': 'application/json' }
const APP_ID = '10000001'
export const CASES = [
  ['core-01', 'core', '匿名冷启动 full5，100 Bundle，一次 latest'],
  ['core-02', 'core', 'A 命中 gray6，100→1；原生 Tab 零请求且实例稳定'],
  ['core-03', 'core', 'B 回到 full5，复用已有正式对象'],
  ['core-04', 'core', 'full7 高于 gray6；重复 A 注册幂等'],
  ['core-05', 'core', '延迟 A，B 先完成，旧 A 不覆盖 B'],
  ['core-06', 'core', '退出为匿名并保留兼容 full7'],
  ['core-07', 'core', '显式回滚到更旧 full5'],
  ['core-08', 'core', '真实 APK versionCode=1000 后原 Store 不再加载受限远程'],
  ['policy-01', 'policy', 'install 前 A 身份，一次启动选择 gray8'],
  ['policy-02', 'policy', '禁用规则回 full7，仅一个新对象'],
  ['policy-03', 'policy', '同 release gray→full 零字节，B 可使用'],
  ['policy-04', 'policy', '强制 embedded 后不加载远程 050'],
  ['policy-05', 'policy', '网络 A 响应挂起时，冷读遵守持久化 embedded 指令'],
  ['candidate-01', 'candidate', '候选模式冷启动，Tab 仍使用 full5'],
  ['candidate-02', 'candidate', '独立打开 050，真实首屏后 promote gray6'],
  ['candidate-03', 'candidate', '显式刷新后 Tab 才消费 gray6'],
  ['candidate-04', 'candidate', '退出候选灰度身份回 full5'],
  ['native-01', 'native', '默认 PackageInfo versionCode=1 与实际 SDK 请求一致'],
  ['native-02', 'native', '真实构建号 1000 不兼容时不恢复旧远程入口'],
].map(([id, flow, title]) => ({ id, flow, title }))

function decodeXml(value) {
  return value.replace(/&#x([0-9a-f]+);|&#([0-9]+);|&(quot|apos|lt|gt|amp);/gi, (_, hex, number, named) => {
    if (hex) return String.fromCodePoint(parseInt(hex, 16))
    if (number) return String.fromCodePoint(Number(number))
    return { quot: '"', apos: "'", lt: '<', gt: '>', amp: '&' }[named.toLowerCase()]
  })
}

export function parseUiDump(xml) {
  // Android 的 XML serializer 可用单引号包住含 JSON 双引号的属性。
  // 属性内合法的 > 也不能提前终止节点；不把解析失败误报为 native Store 未就绪。
  return [...xml.matchAll(/<node\b((?:"[^"]*"|'[^']*'|[^'">])*)>/g)].map((match) => Object.fromEntries(
    [...match[1].matchAll(/([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)]
      .map((attribute) => [attribute[1], decodeXml(attribute[2] ?? attribute[3])]),
  ))
}

export function centerFromNode(node) {
  const match = node.bounds?.match(/^\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]$/)
  if (!match || node.enabled === 'false' || node.clickable !== 'true') throw new Error('UI 节点没有可点击的有效 bounds')
  const [left, top, right, bottom] = match.slice(1).map(Number)
  if (right <= left || bottom <= top) throw new Error('UI bounds 不可见')
  return [Math.floor((left + right) / 2), Math.floor((top + bottom) / 2)]
}

function exactNode(nodes, description) {
  const matches = nodes.filter((node) => node['content-desc'] === description)
  if (matches.length !== 1) throw new Error(`UI 节点必须唯一：${description}，实际 ${matches.length}`)
  return matches[0]
}

function debugState(nodes) {
  const value = nodes.find((node) => node['content-desc']?.startsWith(STATE_PREFIX))?.['content-desc']
  if (!value) return undefined
  return JSON.parse(value.slice(STATE_PREFIX.length))
}

function isReady(value = '') {
  const explicit = value.match(/\bready=(true|false)\b/)
  return explicit ? explicit[1] === 'true' : /\berror=ready\b|\bstatus=ready\b|\bstate=ready\b|^ready:/.test(value)
}

function fragmentReady(value = '') {
  return /(?:^|;)error=ready(?:;|$)/.test(value)
}

function chineseUiState(state, standalone) {
  if (standalone) return `独立页面：${isReady(standalone) ? '真实首屏已就绪' : '首屏未就绪'}；${/\bpromoted=true\b/.test(standalone) ? '候选已提交' : '未确认候选提交'}`
  const user = { A: '用户 A（灰度）', B: '用户 B（普通）', anonymous: '匿名' }[state.audience] ?? '未知测试身份'
  const tabs = Object.entries(state.tabs ?? {}).map(([key, tab]) => {
    const release = tab.state.match(/(?:^|;)release=([^;]+)/)?.[1] ?? '无'
    return `${key === 'home' ? '首页' : '设置'}：${fragmentReady(tab.state) ? '真实首屏已就绪' : '首屏未就绪/无可用包'}，发布=${release}`
  })
  return `${user}；真实 APK 构建号=${state.versioncode}；epoch=${state.epoch}；${tabs.join('；')}`
}

function hasRelease(value, releaseId) {
  return value.split(/[;|\s]/).some((field) => field === `release=${releaseId}`) || value.includes(`ready:${releaseId}:`)
}

function validateStoreId(value) {
  if (!/^[A-Za-z0-9_-]{1,96}$/.test(value ?? '')) throw new Error('nativeStoreId 只能是合成的字母数字/横线/下划线 ID')
  return value
}

function bootstrapPayload(storeId, audience, candidateMode) {
  validateStoreId(storeId)
  if (!['A', 'B', 'anonymous'].includes(audience)) throw new Error('只允许合成身份枚举')
  return { nativeStoreId: storeId, audience, ...(candidateMode === undefined ? {} : { candidateMode }) }
}

function plan() {
  return {
    deviceActionsExecuted: false,
    requiredBuildEnvironment: {
      LYNX_TEST_OTA_USER_SELECTION: '1', LYNX_OTA_LOCAL_SERVER: '1', LYNX_OTA_LOCAL_BASE_URL: 'http://127.0.0.1:18770',
      LYNX_OTA_CLIENT_TOKEN: '使用 fixture 的合成本地 token',
    },
    upgradeBuildEnvironment: { LYNX_OTA_DEBUG_VERSION_CODE: '1000' },
    defaultApkVersionCode: 1,
    cases: CASES.map((item) => ({ ...item, status: 'PLANNED', requiredApkVersionCode: ['core-08', 'native-02'].includes(item.id) ? 1000 : 1 })),
    instructions: [
      '主线程完成构建/安装并明确通知后，才运行 --execute；脚本不会构建、安装 APK 或清 App 数据。',
      '--flow all 先执行 versionCode=1 的 17 个场景；core-08/native-02 记录 BLOCKED_NEEDS_APK_1000。',
      '主线程安装同包名 versionCode=1000 的 APK 后，用同一个 --output 和 --flow upgrade 续跑两个真实升级场景。',
      'candidateMode 通过 Demo 原生 CheckBox 写入枚举测试 prefs，下次冷启动生效。',
      '点击坐标全部来自实时 UIAutomator XML bounds；截图、JSON、原始 XML 和 Store state 都来自实际设备。',
    ],
  }
}

function help() {
  console.log(`用法（仓库根目录）：
  node scripts/ota-user-gray/android-device.mjs --plan
  node scripts/ota-user-gray/android-device.mjs --self-test
  node scripts/ota-user-gray/android-device.mjs --execute --serial emulator-5554 --origin http://127.0.0.1:18770 --reverse --flow all --output scripts/ota-user-gray/.generated/android-p06

精确 flags：
  --help                  显示帮助；即使同时出现 --execute，也不访问设备。
  --plan                  输出 4 流程/19 场景 JSON 计划，不访问设备。
  --self-test             只运行宿主 Node 解析自检，不访问 ADB。
  --execute               主线程允许后显式开启设备操作；脚本不构建或安装 APK。
  --serial SERIAL         必填；明确指定唯一设备，如 emulator-5554。
  --adb PATH              adb 路径，默认 adb。
  --package NAME          默认 com.example.lynxshell.debug，只允许 .debug 包。
  --origin URL            默认 http://127.0.0.1:18770，只允许 loopback HTTP。
  --reverse               为 origin 的显式端口配置 adb reverse；已配置时可省略。
  --flow NAME             all/core/policy/candidate/native/upgrade，默认 all。
  --expected-sdk VERSION  验证实际捕获的 SDK Query，默认 fixture 支持的 4.0.0；不覆盖 App SDK 版本。
  --output DIR            输出目录；升级续跑必须使用基础流程相同的目录。

构建环境（由主线程构建/安装）：
  LYNX_TEST_OTA_USER_SELECTION=1 LYNX_OTA_LOCAL_SERVER=1 LYNX_OTA_LOCAL_BASE_URL=http://127.0.0.1:18770
  默认真实 APK versionCode=1；1000 APK 另加 LYNX_OTA_DEBUG_VERSION_CODE=1000。
  code1 跑 all 后，两个升级场景保持 BLOCKED；主线程安装 code1000 APK，再跑 --flow upgrade。

产物 schema：
  android-device-report.json
    schemaVersion/runId/package/serial/origin/storeIds
    cases[]: {id,flow,title,status,nativeStoreId?,evidence?,screenshot?}
    summary: {passed,blocked,planned,failed}; failure?: {flow,message}; previousFailures?: []
  <case-id>.json
    {id,nativeStoreId,nativeState,uiStateSummary,server,metrics,nativeStore,notes,proof}
    nativeStore: {nativeStoreId,runtimeStoreRoot,state,objects[]}
  <case-id>.png            实际 adb screencap PNG。
  <case-id>.ui.xml         原始 UIAutomator 树，点击坐标来自其中唯一节点 bounds。
  failure.json/.png/.ui.xml 失败时实际可取得的证据，不伪造缺失数据。
  bootstrap-<storeId>.json 仅含 A/B/anonymous、合成 Store ID、可选 candidateMode。

PASS 仅在实际断言完成后记录；未执行为 PLANNED，待 code1000 为 BLOCKED_NEEDS_APK_1000。
退出码：0=本次执行成功，1=失败，2=仍需 code1000 续跑。首屏依据 Fragment onFirstScreen 的 error=ready。
脚本不执行 pm clear，不清普通 Store，不改三端 embedded assets。`)
}

function runProcess(command, args, { allowFailure = false, timeout = 30000 } = {}) {
  return new Promise((resolve, reject) => {
    const process = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'] })
    const stdout = []
    const stderr = []
    const timer = setTimeout(() => { process.kill('SIGTERM'); reject(new Error('ADB 命令超时')) }, timeout)
    process.stdout.on('data', (data) => stdout.push(data))
    process.stderr.on('data', (data) => stderr.push(data))
    process.on('error', (error) => { clearTimeout(timer); reject(error) })
    process.on('close', (code) => {
      clearTimeout(timer)
      const result = { code, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr).toString('utf8') }
      if (code !== 0 && !allowFailure) reject(new Error(`ADB 退出 ${code}: ${result.stderr.trim() || result.stdout.toString('utf8').trim()}`))
      else resolve(result)
    })
  })
}

async function execute(options) {
  if (!options.serial) throw new Error('--execute 必须显式指定 --serial，不自动选择设备')
  if (!/^[A-Za-z0-9_.-]+$/.test(options.serial)) throw new Error('serial 不合法')
  if (!/^[A-Za-z0-9_.]+\.debug$/.test(options.package)) throw new Error('只允许独立 .debug 包名')
  const origin = new URL(options.origin)
  if (origin.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(origin.hostname) || origin.username || origin.password || origin.search || origin.hash || origin.pathname !== '/') throw new Error('fixture origin 必须为显式本地 HTTP origin')
  fs.mkdirSync(options.output, { recursive: true })
  const reportFile = path.join(options.output, 'android-device-report.json')
  const report = fs.existsSync(reportFile) ? JSON.parse(fs.readFileSync(reportFile, 'utf8')) : {
    schemaVersion: 1, runId: `android-${crypto.randomUUID()}`, package: options.package, serial: options.serial,
    origin: origin.origin, storeIds: {}, cases: CASES.map((item) => ({ ...item, status: 'PLANNED' })),
  }
  assert.equal(report.package, options.package)
  assert.equal(report.serial, options.serial)
  if (report.failure) {
    report.previousFailures = [...(report.previousFailures ?? []), report.failure]
    delete report.failure
  }
  const adb = (args, extra) => runProcess(options.adb, ['-s', options.serial, ...args], extra)
  const dumpFile = `/data/local/tmp/ota-user-gray-ui-${report.runId}.xml`
  let lastNativeState
  let lastXml = ''
  const saveReport = () => fs.writeFileSync(reportFile, `${JSON.stringify(report, null, 2)}\n`)

  async function control(endpoint, body) {
    const response = await fetch(new URL(`/_fixture/${endpoint}`, origin), {
      method: body === undefined ? 'GET' : 'POST', headers: CONTROL_HEADERS,
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
    const result = await response.json()
    if (!response.ok) throw new Error(`fixture ${endpoint}: HTTP ${response.status}`)
    return result
  }

  async function dump() {
    await adb(['shell', 'uiautomator', 'dump', '--compressed', dumpFile])
    const result = await adb(['exec-out', 'cat', dumpFile])
    lastXml = result.stdout.toString('utf8')
    const nodes = parseUiDump(lastXml)
    const state = debugState(nodes)
    if (state) lastNativeState = state
    return { nodes, state }
  }

  async function waitFor(description, check, timeout = 45000) {
    const end = Date.now() + timeout
    let lastError
    while (Date.now() < end) {
      try { const value = await check(); if (value) return value } catch (error) { lastError = error }
      await pause(200)
    }
    throw new Error(`等待失败：${description}${lastError ? `；${lastError.message}` : ''}`)
  }

  async function click(description) {
    const node = await waitFor(description, async () => {
      const { nodes } = await dump()
      const selected = exactNode(nodes, description)
      return selected.enabled !== 'false' ? selected : undefined
    })
    const [x, y] = centerFromNode(node)
    await adb(['shell', 'input', 'tap', String(x), String(y)])
  }

  async function metricAtLeast(name, minimum) {
    return waitFor(`${name} >= ${minimum}`, async () => {
      const metrics = await control('metrics')
      return metrics[name] >= minimum ? metrics : undefined
    })
  }

  async function currentState() {
    return waitFor('Demo 实际独立 Store 状态', async () => {
      const { state } = await dump()
      if (!state?.testMode || !state.storeVerified) return undefined
      validateStoreId(state.nativeStoreId)
      assert.equal(state.apiOrigin.replace(/\/$/, ''), origin.origin)
      assert.ok(state.runtimeStoreRoot.endsWith(`/ota-user-gray-test/stores/${state.nativeStoreId}`))
      return state
    })
  }

  async function waitRelease(releaseId, both = false) {
    return waitFor(`真实 Tab ready/release=${releaseId}`, async () => {
      const { state } = await dump()
      const tabs = both ? [state?.tabs?.home, state?.tabs?.settings] : [state?.tabs?.home]
      return tabs.every((tab) => tab && fragmentReady(tab.state) && hasRelease(tab.state, releaseId)) ? state : undefined
    })
  }

  async function noRemote(releaseId) {
    return waitFor('当前入口不再使用被撤销/不兼容的远程', async () => {
      const { state } = await dump()
      const tabs = Object.values(state?.tabs ?? {})
      if (tabs.length !== 2) return undefined
      return tabs.every((tab) => !hasRelease(tab.state, releaseId) &&
        (/source=embedded_baseline\b/.test(tab.state) || /没有.*(?:active|可用)|ready=false|release=(?:none|unknown|null)/.test(tab.state))) ? state : undefined
    })
  }

  async function bootstrap(storeId, audience = 'anonymous', candidateMode) {
    const payload = bootstrapPayload(storeId, audience, candidateMode)
    await adb(['shell', 'am', 'force-stop', options.package])
    const inputFile = path.join(options.output, `bootstrap-${storeId}.json`)
    fs.writeFileSync(inputFile, JSON.stringify(payload))
    const remote = `/data/local/tmp/ota-user-gray-bootstrap-${storeId}.json`
    await adb(['push', inputFile, remote])
    await adb(['shell', 'run-as', options.package, 'mkdir', '-p', 'files/ota-user-gray-test'])
    await adb(['shell', 'run-as', options.package, 'cp', remote, 'files/ota-user-gray-test/bootstrap.json'])
    await adb(['shell', 'rm', remote])
    await adb(['shell', 'am', 'start', '-n', `${options.package}/com.example.lynxshell.sample.MainActivity`, '--ez', 'lynx_shell.show_native_launcher', 'true'])
    const state = await currentState()
    assert.equal(state.nativeStoreId, storeId)
    assert.equal(state.audience, audience)
    return state
  }

  async function openTabs() { await click('ota-open-native-tabs'); return currentState() }
  async function choose(value) { await click({ A: 'ota-user-a', B: 'ota-user-b', anonymous: 'ota-user-anonymous' }[value]) }
  async function refresh() {
    const before = (await currentState()).syncGeneration
    await click('ota-refresh')
    await waitFor('本次显式刷新完成', async () => {
      const { state } = await dump()
      return state?.syncGeneration > before && state.syncStatus === 'complete' ? state : undefined
    })
  }

  async function nativeStore(state = lastNativeState) {
    const id = validateStoreId(state?.nativeStoreId)
    assert.equal(state.storeVerified, true)
    const relative = `files/ota-user-gray-test/stores/${id}/apps/${APP_ID}`
    const record = await adb(['exec-out', 'run-as', options.package, 'cat', `${relative}/state.json`], { allowFailure: true })
    const files = await adb(['exec-out', 'run-as', options.package, 'find', `${relative}/objects`, '-type', 'f'], { allowFailure: true })
    return {
      nativeStoreId: id, runtimeStoreRoot: state.runtimeStoreRoot,
      state: record.code === 0 ? JSON.parse(record.stdout.toString('utf8')) : null,
      objects: files.code === 0 ? files.stdout.toString('utf8').trim().split('\n').filter((name) => /[a-f0-9]{64}\.lynx\.bundle$/.test(name)).map((name) => path.basename(name)).sort() : [],
    }
  }

  async function capture(id, notes = {}, standalone) {
    const { state } = await dump()
    if (state) lastNativeState = state
    const metrics = await control('metrics')
    for (const request of metrics.requests.filter((item) => item.kind === 'latest')) {
      assert.equal(request.platform, 'android')
      assert.equal(request.versioncode, lastNativeState.versioncode)
      assert.equal(request.lynxSdkVersion, options.expectedSdk)
    }
    const evidence = {
      id, nativeStoreId: lastNativeState.nativeStoreId, nativeState: standalone ?? lastNativeState,
      uiStateSummary: chineseUiState(lastNativeState, standalone),
      server: await control('state'), metrics, nativeStore: await nativeStore(), notes,
      proof: '实际 Android ADB/UIAutomator/截图/私有 Store 读取',
    }
    fs.writeFileSync(path.join(options.output, `${id}.ui.xml`), lastXml)
    fs.writeFileSync(path.join(options.output, `${id}.png`), (await adb(['exec-out', 'screencap', '-p'])).stdout)
    fs.writeFileSync(path.join(options.output, `${id}.json`), `${JSON.stringify(evidence, null, 2)}\n`)
    Object.assign(report.cases.find((item) => item.id === id), { status: 'PASS', nativeStoreId: evidence.nativeStoreId, evidence: `${id}.json`, screenshot: `${id}.png` })
    saveReport()
    console.log(`PASS ${id}`)
    return evidence
  }

  async function begin(flow, { stage = 'full5', audience = 'anonymous', candidateMode = false, storeId } = {}) {
    await control('reset', {})
    if (stage !== 'full5') await control('stage', { stage })
    const id = storeId ?? `${flow}-${crypto.randomUUID()}`
    report.storeIds[flow] = id
    saveReport()
    await control('metrics/reset', {})
    const state = await bootstrap(id, audience, candidateMode)
    assert.equal(state.versioncode, '1', '基础流程需安装真实 versionCode=1 的验收 Debug APK')
    return (await control('state')).actualReleaseIds
  }

  async function core() {
    const ids = await begin('core')
    await metricAtLeast('bundleSuccessCount', 100)
    assert.equal((await control('metrics')).latestRequestCount, 1)
    await openTabs(); await waitRelease(ids.full5)
    assert.equal((await nativeStore()).objects.length, 100)
    const baseline = await capture('core-01')
    await control('stage', { stage: 'gray6' }); await control('metrics/reset', {})
    await choose('A'); await waitRelease(ids.gray6)
    const incrementalMetrics = await control('metrics')
    assert.equal(incrementalMetrics.bundleSuccessCount, 1)
    const incremental = await nativeStore()
    assert.equal(incremental.objects.filter((name) => !baseline.nativeStore.objects.includes(name)).length, 1)
    await click('ota-tab-settings'); await click('ota-tab-home'); await waitRelease(ids.gray6, true)
    const beforeTabs = (await currentState()).tabs
    for (const tab of Object.values(beforeTabs)) {
      assert.match(tab.state, /(?:^|;)instance=\S+/)
      assert.match(tab.state, /(?:^|;)load=[0-9]+;render=[0-9]+/)
    }
    await control('metrics/reset', {})
    for (let count = 0; count < 3; count++) { await click('ota-tab-settings'); await click('ota-tab-home') }
    assert.deepEqual((await currentState()).tabs, beforeTabs)
    assert.equal((await control('metrics')).latestRequestCount, 0)
    await capture('core-02', { incrementalMetrics, nativeStoreAfterIncrement: incremental, tabsBeforeSwitches: beforeTabs, unchangedFragmentAndLoadRenderCounts: true })
    await control('metrics/reset', {}); await choose('B'); await waitRelease(ids.full5)
    await metricAtLeast('latestCompletedCount', 1)
    assert.equal((await control('metrics')).bundleSuccessCount, 0)
    await capture('core-03')
    await control('stage', { stage: 'full7' }); await control('metrics/reset', {})
    await choose('A'); await waitRelease(ids.full7)
    const newerFullMetrics = await control('metrics')
    assert.equal(newerFullMetrics.bundleSuccessCount, 1)
    const epoch = (await currentState()).epoch
    await control('metrics/reset', {}); await choose('A')
    assert.equal((await currentState()).epoch, epoch)
    assert.equal((await control('metrics')).latestRequestCount, 0)
    await capture('core-04', { newerFullMetrics, epochBeforeRepeatedRegistration: epoch })
    await choose('B'); await waitRelease(ids.full7); await metricAtLeast('latestCompletedCount', 1)
    await control('stage', { stage: 'gray8' }); await control('metrics/reset', {})
    await control('delay-latest', { audience: 'A', count: 1, milliseconds: 0 })
    await choose('A'); await metricAtLeast('delayedLatestCount', 1)
    await choose('B')
    await waitFor('B 在延迟 A 前完成', async () => (await control('metrics')).requests.some((item) => item.kind === 'latest' && item.audience === 'B' && item.completed))
    await control('release-delays', {}); await waitRelease(ids.full7)
    assert.equal((await currentState()).audience, 'B')
    const delayed = (await control('metrics')).requests.find((item) => item.audience === 'A')
    await capture('core-05', { delayedAResponseCompleted: delayed?.completed === true, outcome: delayed?.completed ? '旧 A 响应完成后 B 保持 full7' : 'A 请求已被取消，B 保持 full7' })
    await choose('anonymous'); await waitRelease(ids.full7); await capture('core-06')
    await control('rollback', { from: 'full7', target: 'full5' }); await refresh(); await waitRelease(ids.full5)
    await capture('core-07')
    Object.assign(report.cases.find((item) => item.id === 'core-08'), { status: 'BLOCKED_NEEDS_APK_1000', nativeStoreId: report.storeIds.core })
    saveReport()
  }

  async function policy() {
    const ids = await begin('policy', { stage: 'gray8', audience: 'A' })
    await metricAtLeast('bundleSuccessCount', 100)
    assert.equal((await control('metrics')).latestRequestCount, 1)
    await openTabs(); await waitRelease(ids.gray8); await capture('policy-01')
    await control('rule', { alias: 'gray8', enabled: false }); await control('metrics/reset', {})
    await refresh(); await waitRelease(ids.full7)
    assert.equal((await control('metrics')).bundleSuccessCount, 1)
    await capture('policy-02')
    await control('rule', { alias: 'gray8', enabled: true }); await control('metrics/reset', {})
    await refresh(); await waitRelease(ids.gray8)
    assert.equal((await control('metrics')).bundleSuccessCount, 0)
    await control('publish', { alias: 'gray8', type: 'full' }); await control('metrics/reset', {})
    await refresh(); await waitRelease(ids.gray8)
    assert.match((await currentState()).tabs.home.state, /kind=full\b/)
    await choose('B'); await waitRelease(ids.gray8)
    assert.equal((await control('metrics')).bundleBytes, 0)
    await capture('policy-03')
    await choose('A'); await waitRelease(ids.gray8)
    await control('fallback', { enabled: true, platforms: ['android'] }); await refresh(); await noRemote(ids.gray8)
    await capture('policy-04')
    await control('metrics/reset', {}); await control('delay-latest', { audience: 'A', count: 1, milliseconds: 0 })
    await bootstrap(report.storeIds.policy, 'A', false); await metricAtLeast('pendingLatestCount', 1)
    await openTabs(); await noRemote(ids.gray8)
    assert.ok((await control('metrics')).pendingLatestCount > 0)
    await capture('policy-05', { localReadBeforeHeldNetworkResponse: true })
    await control('release-delays', {})
  }

  async function candidate() {
    const ids = await begin('candidate')
    await metricAtLeast('bundleSuccessCount', 100); await openTabs(); await waitRelease(ids.full5)
    await adb(['shell', 'input', 'keyevent', '4'])
    await click('ota-candidate-next')
    const checkbox = exactNode((await dump()).nodes, 'ota-candidate-next')
    assert.equal(checkbox.checked, 'true')
    await control('stage', { stage: 'gray6' }); await control('metrics/reset', {})
    const initial = await bootstrap(report.storeIds.candidate, 'A', undefined)
    assert.equal(initial.candidateMode, true, '必须从 Demo checkbox 持久化值启用冷启动候选模式')
    await metricAtLeast('bundleSuccessCount', 1); await openTabs(); await waitRelease(ids.full5)
    await capture('candidate-01')
    await click('ota-open-050')
    const standalone = await waitFor('独立 050 真实首屏与候选提交', async () => {
      const { nodes } = await dump()
      const node = nodes.find((item) => item['content-desc']?.startsWith('lynx-debug-ota-state') || item['resource-id']?.endsWith('/lynx-debug-ota-state'))
      const raw = node ? `${node.text ?? ''} ${node['content-desc'] ?? ''}` : ''
      return isReady(raw.trim()) && (hasRelease(raw, ids.gray6) || raw.includes(`:${ids.gray6}:`)) && /\bpromoted=true\b|\bcandidateCommitted=true\b/.test(raw) ? raw : undefined
    })
    assert.equal((await nativeStore()).state?.current?.releaseId, ids.gray6)
    await capture('candidate-02', {}, standalone)
    await adb(['shell', 'input', 'keyevent', '4']); await waitRelease(ids.full5)
    await refresh(); await waitRelease(ids.gray6); await capture('candidate-03')
    await choose('anonymous'); await waitRelease(ids.full5); await capture('candidate-04')
  }

  async function nativeDefault() {
    const ids = await begin('native')
    await metricAtLeast('bundleSuccessCount', 100)
    const requests = (await control('metrics')).requests.filter((item) => item.kind === 'latest')
    assert.equal(requests.length, 1)
    assert.equal(requests[0].versioncode, '1')
    await openTabs(); await waitRelease(ids.full5); await capture('native-01')
    Object.assign(report.cases.find((item) => item.id === 'native-02'), { status: 'BLOCKED_NEEDS_APK_1000', nativeStoreId: report.storeIds.native })
    saveReport()
  }

  async function upgrade() {
    for (const [flow, id] of [['core', 'core-08'], ['native', 'native-02']]) {
      const storeId = report.storeIds[flow]
      if (!storeId) throw new Error(`先完成 ${flow} versionCode=1 流程，并使用同一个 --output 续跑`)
      await control('reset', {}); await control('metrics/reset', {})
      const state = await bootstrap(storeId, 'anonymous', false)
      assert.equal(state.versioncode, '1000', '请主线程安装实际 versionCode=1000 的 Debug APK；脚本不伪装 Query')
      await metricAtLeast('latestCompletedCount', 1)
      await openTabs(); const ids = (await control('state')).actualReleaseIds; await noRemote(ids.full5)
      assert.equal((await control('metrics')).bundleSuccessCount, 0)
      await capture(id)
    }
  }

  try {
    await control('state')
    if (options.reverse) {
      if (!origin.port) throw new Error('--reverse 要求显式 fixture port')
      await adb(['reverse', `tcp:${origin.port}`, `tcp:${origin.port}`])
    }
    // 只验证指定调试包可被 run-as 访问，不清数据、不安装 APK。
    await adb(['shell', 'run-as', options.package, 'id'])
    const flows = { core, policy, candidate, native: nativeDefault, upgrade }
    for (const flow of options.flow === 'all' ? ['core', 'policy', 'candidate', 'native'] : [options.flow]) {
      if (!flows[flow]) throw new Error('flow 只支持 all/core/policy/candidate/native/upgrade')
      report.activeFlow = flow
      saveReport()
      await flows[flow]()
    }
    report.activeFlow = null
  } catch (error) {
    report.failure = { flow: report.activeFlow, message: error.message }
    await dump().catch(() => {})
    fs.writeFileSync(path.join(options.output, 'failure.ui.xml'), lastXml)
    const screenshot = await adb(['exec-out', 'screencap', '-p'], { allowFailure: true }).catch(() => null)
    if (screenshot?.code === 0) fs.writeFileSync(path.join(options.output, 'failure.png'), screenshot.stdout)
    fs.writeFileSync(path.join(options.output, 'failure.json'), `${JSON.stringify({
      ...report.failure, nativeState: lastNativeState ?? null,
      metrics: await control('metrics').catch(() => null), server: await control('state').catch(() => null),
      screenshotCaptured: screenshot?.code === 0,
    }, null, 2)}\n`)
    throw error
  } finally {
    report.summary = {
      passed: report.cases.filter((item) => item.status === 'PASS').length,
      blocked: report.cases.filter((item) => item.status.startsWith('BLOCKED')).length,
      planned: report.cases.filter((item) => item.status === 'PLANNED').length,
      failed: report.failure ? 1 : 0,
    }
    saveReport()
    console.log(JSON.stringify({ report: reportFile, summary: report.summary }, null, 2))
    await adb(['shell', 'rm', dumpFile], { allowFailure: true })
  }
  return report
}

function selfTest() {
  const xml = '<hierarchy><node text="A &amp; B" content-desc="ota-user-a" enabled="true" clickable="true" bounds="[10,20][110,80]"/><node text="" content-desc="ota-user-debug-state|{&quot;testMode&quot;:true,&quot;nativeStoreId&quot;:&quot;unit-1&quot;}" enabled="true" clickable="false" bounds="[0,0][100,10]"/></hierarchy>'
  const nodes = parseUiDump(xml)
  assert.equal(nodes[0].text, 'A & B')
  assert.deepEqual(centerFromNode(exactNode(nodes, 'ota-user-a')), [60, 50])
  assert.equal(debugState(nodes).nativeStoreId, 'unit-1')
  assert.throws(() => exactNode([...nodes, nodes[0]], 'ota-user-a'))
  assert.throws(() => centerFromNode({ ...nodes[0], bounds: '[10,20][10,20]' }))
  assert.throws(() => centerFromNode({ ...nodes[0], clickable: 'false' }))
  assert.throws(() => validateStoreId('../normal-store'))
  assert.equal(isReady('ready=false release=x error=ready'), false)
  assert.equal(isReady('ready=true release=x'), true)
  assert.equal(isReady('state=ready;release=r002;source=ota_current;promoted=true'), true)
  assert.equal(hasRelease('instance=123;load=1;render=1;error=ready;release=r002;source=ota_current;kind=gray;sequence=2;epoch=1', 'r002'), true)
  assert.equal(hasRelease('release=r0020;kind=full', 'r002'), false)
  assert.equal(Object.hasOwn(bootstrapPayload('unit-1', 'A', undefined), 'candidateMode'), false)
  assert.equal(bootstrapPayload('unit-1', 'anonymous', false).candidateMode, false)
  assert.equal(fragmentReady('instance=1;error=ready;release=r2'), true)
  assert.equal(fragmentReady('instance=1;error=loading;release=r2'), false)
  const singleQuoted = `<hierarchy><node text='Debug&#10;独立 Store' content-desc='ota-user-debug-state|{"testMode":true,"storeVerified":true,"nativeStoreId":"unit-2","message":"1 > 0"}' enabled='true' clickable='false' bounds='[24,24][1056,223]'/></hierarchy>`
  const singleNodes = parseUiDump(singleQuoted)
  assert.equal(singleNodes.length, 1)
  assert.equal(singleNodes[0].text, 'Debug\n独立 Store')
  assert.equal(debugState(singleNodes).storeVerified, true)
  assert.equal(debugState(singleNodes).nativeStoreId, 'unit-2')
  assert.equal(debugState(singleNodes).message, '1 > 0')
  assert.equal(CASES.length, 19)
  assert.equal(new Set(CASES.map((item) => item.id)).size, 19)
  console.log(JSON.stringify({ selfTest: 'PASS', assertions: 23, deviceActionsExecuted: false, scenarios: CASES.length }))
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2)
    if (args.includes('--self-test')) selfTest()
    else if (args.includes('--help')) help()
    else if (args.includes('--plan')) console.log(JSON.stringify(plan(), null, 2))
    else {
      const options = { execute: false, reverse: false, adb: 'adb', serial: '', package: 'com.example.lynxshell.debug', origin: 'http://127.0.0.1:18770', flow: 'all', expectedSdk: '4.0.0', output: path.join(ROOT, 'scripts/ota-user-gray/.generated/android-device') }
      for (let index = 0; index < args.length; index++) {
        if (args[index] === '--execute') options.execute = true
        else if (args[index] === '--reverse') options.reverse = true
        else if (['--plan', '--help'].includes(args[index])) options.execute = false
        else {
          const key = { '--adb': 'adb', '--serial': 'serial', '--package': 'package', '--origin': 'origin', '--flow': 'flow', '--expected-sdk': 'expectedSdk', '--output': 'output' }[args[index]]
          if (!key || !args[index + 1]) throw new Error('未知或缺少参数；使用 --plan 查看要求')
          options[key] = args[++index]
        }
      }
      options.output = path.resolve(options.output)
      if (!options.execute) console.log(JSON.stringify(plan(), null, 2))
      else {
        const result = await execute(options)
        if (result.summary.blocked) process.exitCode = 2
      }
    }
  } catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}
