#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
HDC_TARGET="${HDC_TARGET:-127.0.0.1:5557}"
OTA_SERVER="${OTA_SERVER:-http://127.0.0.1:18766}"
APP_BUNDLE="${APP_BUNDLE:-com.example.lynxshell}"
ARTIFACT="${ARTIFACT:-$REPO_ROOT/harmony/build/outputs/default/harmony-default-unsigned.app}"
OUTPUT="${OUTPUT:-$REPO_ROOT/docs/assets/harmony-ota-store-v3/process-crash-results.jsonl}"

if [[ ! -x "$HDC" ]]; then
  echo "HDC 不存在或不可执行：$HDC" >&2
  exit 1
fi
if [[ ! -f "$ARTIFACT" ]]; then
  echo "HarmonyOS App 产物不存在：$ARTIFACT" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
: > "$OUTPUT"

control() {
  curl -fsS "$@" >/dev/null
}

set_active() {
  control -X POST "$OTA_SERVER/__test__/active" \
    -H 'content-type: application/json' \
    --data "{\"version\":\"$1\",\"platform\":\"android\"}"
}

set_scenario() {
  control -X POST "$OTA_SERVER/__test__/scenario" \
    -H 'content-type: application/json' \
    --data "{\"mode\":\"$1\"}"
}

reset_metrics() {
  control -X POST "$OTA_SERVER/__test__/metrics/reset"
}

install_clean_v1() {
  set_active V1
  set_scenario normal
  reset_metrics
  "$HDC" -t "$HDC_TARGET" uninstall "$APP_BUNDLE" >/dev/null 2>&1 || true
  "$HDC" -t "$HDC_TARGET" install "$ARTIFACT" >/dev/null
  "$HDC" -t "$HDC_TARGET" shell 'aa start -a EntryAbility -b com.example.lynxshell -W' >/dev/null
  sleep 4
}

force_stop() {
  "$HDC" -t "$HDC_TARGET" shell "aa force-stop $APP_BUNDLE" >/dev/null
}

clear_hilog() {
  "$HDC" -t "$HDC_TARGET" shell 'hilog -r' >/dev/null 2>&1 || true
}

dump_inspector() {
  local case_name="$1"
  local remote_path="/data/local/tmp/ota_store_v3_crash_$case_name.json"
  local host_path="/tmp/ota-store-v3-crash-$case_name.json"
  local index_remote_path="/data/local/tmp/ota_store_v3_crash_index_$case_name.json"
  local index_host_path="/tmp/ota-store-v3-crash-index-$case_name.json"
  "$HDC" -t "$HDC_TARGET" shell 'uitest uiInput keyEvent Back' >/dev/null 2>&1 || true
  sleep 1
  "$HDC" -t "$HDC_TARGET" shell "uitest dumpLayout -b $APP_BUNDLE -p $index_remote_path" >/dev/null 2>&1 || true
  "$HDC" -t "$HDC_TARGET" file recv "$index_remote_path" "$index_host_path" >/dev/null 2>&1 || true
  local center
  center="$(LAYOUT_FILE="$index_host_path" node -e '
    const fs = require("fs");
    try {
      const layout = JSON.parse(fs.readFileSync(process.env.LAYOUT_FILE, "utf8"));
      let result = "";
      const walk = node => {
        if (!node || typeof node !== "object" || result) return;
        const attrs = node.attributes;
        if (attrs && attrs.text === "查看 OTA 磁盘目录" && attrs.bounds) {
          const match = attrs.bounds.match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
          if (match) result = String(Math.floor((Number(match[1]) + Number(match[3])) / 2)) + " " + String(Math.floor((Number(match[2]) + Number(match[4])) / 2));
        }
        if (Array.isArray(node.children)) node.children.forEach(walk);
      };
      walk(layout);
      process.stdout.write(result);
    } catch (error) {}
  ' 2>/dev/null)"
  if [[ -n "$center" ]]; then
    read -r center_x center_y <<< "$center"
    "$HDC" -t "$HDC_TARGET" shell "uitest uiInput click $center_x $center_y" >/dev/null 2>&1 || true
  else
    "$HDC" -t "$HDC_TARGET" shell 'uitest uiInput click 500 2300' >/dev/null 2>&1 || true
  fi
  sleep 1
  "$HDC" -t "$HDC_TARGET" shell "uitest dumpLayout -b $APP_BUNDLE -p $remote_path" >/dev/null 2>&1 || true
  "$HDC" -t "$HDC_TARGET" file recv "$remote_path" "$host_path" >/dev/null 2>&1 || true
  printf '%s' "$host_path"
}
start_with_pause() {
  local pause_point="$1"
  local pause_token="$2"
  "$HDC" -t "$HDC_TARGET" shell \
    "aa start --ps lynx_ota_pause_point $pause_point --ps lynx_ota_pause_millis 15000 --ps lynx_ota_pause_token $pause_token -a EntryAbility -b com.example.lynxshell -W" >/dev/null
}

start_with_capacity_guard() {
  "$HDC" -t "$HDC_TARGET" shell \
    "aa start --ps lynx_ota_capacity_override 0 -a EntryAbility -b com.example.lynxshell -W" >/dev/null
}

wait_for_pause() {
  local pause_point="$1"
  local pause_token="$2"
  local attempt
  for attempt in $(seq 1 50); do
    if "$HDC" -t "$HDC_TARGET" shell 'hilog -x' 2>/dev/null | grep -F "TEST pause reached: $pause_point, token=$pause_token" >/dev/null; then
      return
    fi
    sleep 0.2
  done
  echo "未在超时时间内到达暂停点：$pause_point" >&2
  exit 1
}

record_metrics() {
  CASE_NAME="$1" PHASE="$2" INSPECTOR_FILE="$3" \
    curl -fsS "$OTA_SERVER/__test__/metrics" | \
    CASE_NAME="$1" PHASE="$2" INSPECTOR_FILE="$3" node -e '
      const fs = require("fs");
      let raw = "";
      process.stdin.on("data", chunk => { raw += chunk; });
      process.stdin.on("end", () => {
        const metrics = JSON.parse(raw);
        const bundles = metrics.requests.filter(item => item.kind === "bundle");
        const latest = metrics.requests.filter(item => item.kind === "latest");
        let inspectorSummary = [];
        try {
          const layout = JSON.parse(fs.readFileSync(process.env.INSPECTOR_FILE, "utf8"));
          const texts = [];
          const walk = node => {
            if (!node || typeof node !== "object") return;
            if (node.attributes && typeof node.attributes.text === "string" && node.attributes.text.length > 0) {
              texts.push(node.attributes.text);
            }
            if (Array.isArray(node.children)) node.children.forEach(walk);
          };
          walk(layout);
          const inspectorText = texts.find(text => text.includes("OTA Store v3 磁盘浏览器")) || "";
          inspectorSummary = inspectorText.split("\n").filter(line =>
            /^(apps:|files:|disk:|current:|previous:|CAS objects:|Manifests:|App ID )/.test(line)
          );
        } catch (error) {
          inspectorSummary = ["Inspector unavailable"];
        }
        console.log(JSON.stringify({
          case: process.env.CASE_NAME,
          phase: process.env.PHASE,
          latestRequestCount: metrics.latestRequestCount,
          bundleRequestCount: metrics.bundleRequestCount,
          bundleBytes: metrics.bundleBytes,
          latestStatuses: latest.map(item => item.statusCode),
          bundleStatuses: bundles.map(item => item.statusCode),
          bundlePaths: bundles.map(item => item.bundlePath),
          activeVersion: metrics.activeVersion,
          scenario: metrics.scenario,
          inspectorSummary
        }));
      });
    ' >> "$OUTPUT"
}

run_crash_case() {
  local pause_point="$1"
  local pause_token="$(date +%s)-$$-$pause_point"
  install_clean_v1
  set_active V2
  set_scenario normal
  reset_metrics
  force_stop
  clear_hilog
  start_with_pause "$pause_point" "$pause_token"
  wait_for_pause "$pause_point" "$pause_token"
  force_stop

  set_active V2
  set_scenario normal
  reset_metrics
  start_with_capacity_guard
  sleep 4
  local interrupted_inspector
  interrupted_inspector="$(dump_inspector "interrupted-$pause_point")"
  record_metrics "crash-$pause_point" "after_force_stop_capacity_guard" "$interrupted_inspector"

  force_stop
  set_active V2
  set_scenario normal
  reset_metrics
  "$HDC" -t "$HDC_TARGET" shell 'aa start -a EntryAbility -b com.example.lynxshell -W' >/dev/null
  sleep 4
  local recovery_inspector
  recovery_inspector="$(dump_inspector "recovery-$pause_point")"
  record_metrics "recovery-$pause_point" "after_cold_start" "$recovery_inspector"
}

for pause_point in \
  after_object_publish \
  after_objects_ready \
  after_manifest_commit \
  before_state_commit \
  after_state_commit
do
  run_crash_case "$pause_point"
done

assert_status=0
node "$REPO_ROOT/scripts/ota-store-v3/assert-harmony-results.mjs" process-crash "$OUTPUT" || assert_status=$?
set_active V1
set_scenario normal
if [[ "$assert_status" -ne 0 ]]; then
  exit "$assert_status"
fi

echo "HarmonyOS process crash smoke 完成并通过机器断言：$OUTPUT"
