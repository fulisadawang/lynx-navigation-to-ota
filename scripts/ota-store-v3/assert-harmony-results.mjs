#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(new URL('.', import.meta.url).pathname, '../..')
const kind = process.argv[2]
const resultPath = path.resolve(
  process.argv[3] || path.join(repoRoot, 'docs/assets/harmony-ota-store-v3', `${kind}-results.jsonl`),
)

function fail(message) {
  throw new Error(`[Harmony OTA v3] ${message}`)
}

function assert(condition, message) {
  if (!condition) fail(message)
}

function readRows() {
  assert(kind === 'fault' || kind === 'process-crash', `不支持的结果类型：${kind || '(empty)'}`)
  assert(fs.existsSync(resultPath), `结果文件不存在：${resultPath}`)
  const lines = fs.readFileSync(resultPath, 'utf8').trim().split(/\n+/).filter(Boolean)
  assert(lines.length > 0, `结果文件为空：${resultPath}`)
  try {
    return lines.map((line, index) => JSON.parse(line, (key, value) => {
      if (key === 'token' || key.toLowerCase().includes('credential')) return undefined
      return value
    }))
  } catch (error) {
    fail(`JSONL 解析失败：${error.message}`)
  }
}

function inspectorValue(row, prefix) {
  return row.inspectorSummary.find((line) => line.startsWith(prefix)) || ''
}

function assertCommon(row, label) {
  assert(row.latestRequestCount === 1, `${label} latest 请求数应为 1，实际 ${row.latestRequestCount}`)
  assert(!row.inspectorSummary.includes('Inspector unavailable'), `${label} Inspector 不可用`)
  assert(inspectorValue(row, 'App ID 10000001') === 'App ID 10000001', `${label} 缺少 App ID 10000001`)
}

function assertCurrent(row, label, releaseId, previousReleaseId, objectCount) {
  assertCommon(row, label)
  const current = inspectorValue(row, 'current:')
  const previous = inspectorValue(row, 'previous:')
  const objects = inspectorValue(row, 'CAS objects:')
  assert(current.includes(releaseId), `${label} current 应为 ${releaseId}，实际 ${current}`)
  if (previousReleaseId) assert(previous.includes(previousReleaseId), `${label} previous 应为 ${previousReleaseId}，实际 ${previous}`)
  assert(objects.startsWith(`CAS objects: ${objectCount} `), `${label} CAS 应为 ${objectCount}，实际 ${objects}`)
}

function runProcessAssertions(rows) {
  assert(rows.length === 10, `process-crash 应有 10 行，实际 ${rows.length}`)
  const points = [
    'after_object_publish',
    'after_objects_ready',
    'after_manifest_commit',
    'before_state_commit',
  ]
  for (const point of points) {
    const crash = rows.find((row) => row.case === `crash-${point}`)
    const recovery = rows.find((row) => row.case === `recovery-${point}`)
    assert(crash && recovery, `缺少 process-crash 场景：${point}`)
    assert(crash.phase === 'after_force_stop_capacity_guard', `${crash.case} phase 不正确`)
    assert(crash.bundleRequestCount === 0 && crash.bundleBytes === 0, `${crash.case} 不应下载 Bundle`)
    assertCurrent(crash, crash.case, 'ota-v3-golden-v1-100', '', 101)
    assert(recovery.phase === 'after_cold_start', `${recovery.case} phase 不正确`)
    assert(recovery.bundleRequestCount === 0 && recovery.bundleBytes === 0, `${recovery.case} 恢复不应重复下载 Bundle`)
    assertCurrent(recovery, recovery.case, 'ota-v3-golden-v2-100-one-change', 'ota-v3-golden-v1-100', 101)
  }
  const committedCrash = rows.find((row) => row.case === 'crash-after_state_commit')
  const committedRecovery = rows.find((row) => row.case === 'recovery-after_state_commit')
  assert(committedCrash && committedRecovery, '缺少 after_state_commit 场景')
  assert(committedCrash.bundleRequestCount === 0 && committedCrash.bundleBytes === 0, 'after_state_commit 中断不应下载 Bundle')
  assertCurrent(committedCrash, committedCrash.case, 'ota-v3-golden-v2-100-one-change', 'ota-v3-golden-v1-100', 101)
  assert(committedRecovery.bundleRequestCount === 0 && committedRecovery.bundleBytes === 0, 'after_state_commit 恢复不应下载 Bundle')
  assertCurrent(committedRecovery, committedRecovery.case, 'ota-v3-golden-v2-100-one-change', 'ota-v3-golden-v1-100', 101)
  console.log(`[Harmony OTA v3] process-crash assertions PASS: ${resultPath}`)
}

function runFaultAssertions(rows) {
  assert(rows.length === 19, `fault 矩阵应有 19 行，实际 ${rows.length}`)
  const expectedFaults = new Map([
    ['before_object_publish', ['ota-v3-golden-v1-100', 1, 100]],
    ['after_object_publish', ['ota-v3-golden-v1-100', 1, 101]],
    ['after_objects_ready', ['ota-v3-golden-v1-100', 1, 101]],
    ['before_manifest_commit', ['ota-v3-golden-v1-100', 1, 101]],
    ['after_manifest_commit', ['ota-v3-golden-v1-100', 1, 101]],
    ['before_state_commit', ['ota-v3-golden-v1-100', 1, 101]],
    ['after_state_commit_report_failure', ['ota-v3-golden-v2-100-one-change', 1, 101]],
    ['enospc_object_publish', ['ota-v3-golden-v1-100', 1, 100]],
    ['enospc_manifest_commit', ['ota-v3-golden-v1-100', 1, 101]],
    ['enospc_state_commit', ['ota-v3-golden-v1-100', 1, 101]],
  ])
  for (const [point, [releaseId, bundleCount, objectCount]] of expectedFaults) {
    const row = rows.find((item) => item.case === `fault-${point}`)
    assert(row, `缺少 fault 场景：${point}`)
    assert(row.bundleRequestCount === bundleCount, `${row.case} Bundle 请求应为 ${bundleCount}，实际 ${row.bundleRequestCount}`)
    assert(row.bundleBytes >= 0, `${row.case} Bundle 字节数非法`)
    assertCurrent(row, row.case, releaseId, '', objectCount)
  }
  const retryExpectations = new Map([
    ['after_objects_ready', 0],
    ['after_manifest_commit', 0],
    ['before_state_commit', 0],
    ['after_state_commit_report_failure', 0],
    ['enospc_object_publish', 1],
    ['enospc_manifest_commit', 0],
    ['enospc_state_commit', 0],
  ])
  for (const [point, bundleCount] of retryExpectations) {
    const row = rows.find((item) => item.case === `retry-${point}`)
    assert(row, `缺少 retry 场景：${point}`)
    assert(row.bundleRequestCount === bundleCount, `${row.case} Bundle 请求应为 ${bundleCount}，实际 ${row.bundleRequestCount}`)
    assertCurrent(row, row.case, 'ota-v3-golden-v2-100-one-change', 'ota-v3-golden-v1-100', 101)
  }
  const capacity = rows.find((row) => row.case === 'capacity-zero')
  assert(capacity, '缺少 capacity-zero 场景')
  assert(capacity.bundleRequestCount === 0 && capacity.bundleBytes === 0, 'capacity-zero 不应下载 Bundle')
  assertCurrent(capacity, capacity.case, 'ota-v3-golden-v1-100', '', 100)
  const disconnect = rows.find((row) => row.case === 'server-disconnect')
  assert(disconnect, '缺少 server-disconnect 场景')
  assert(disconnect.bundleBytes === 0, 'server-disconnect 不应写入 Bundle 字节')
  assertCurrent(disconnect, disconnect.case, 'ota-v3-golden-v1-100', '', 100)
  console.log(`[Harmony OTA v3] fault assertions PASS: ${resultPath}`)
}

const rows = readRows()
if (kind === 'process-crash') runProcessAssertions(rows)
else runFaultAssertions(rows)
