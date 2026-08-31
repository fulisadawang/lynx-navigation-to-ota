#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
HDC_TARGET="${HDC_TARGET:-127.0.0.1:5557}"
OTA_SERVER="${OTA_SERVER:-http://127.0.0.1:18766}"
APP_BUNDLE="${APP_BUNDLE:-com.example.lynxshell}"
ARTIFACT="${ARTIFACT:-$REPO_ROOT/harmony/build/outputs/default/harmony-default-unsigned.app}"
OUTPUT="${OUTPUT:-$REPO_ROOT/docs/assets/harmony-ota-store-v3/fault-test-results.jsonl}"

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

start_with_fault() {
  "$HDC" -t "$HDC_TARGET" shell "aa start --ps lynx_ota_fault_point $1 -a EntryAbility -b com.example.lynxshell -W" >/dev/null
}

start_with_capacity_override() {
  "$HDC" -t "$HDC_TARGET" shell "aa start --ps lynx_ota_capacity_override $1 -a EntryAbility -b com.example.lynxshell -W" >/dev/null
}

force_stop() {
  "$HDC" -t "$HDC_TARGET" shell "aa force-stop $APP_BUNDLE" >/dev/null
}

dump_inspector() {
  local case_name="$1"
  local remote_path="/data/local/tmp/ota_store_v3_inspector_$case_name.json"
  local host_path="/tmp/ota-store-v3-inspector-$case_name.json"
  local index_remote_path="/data/local/tmp/ota_store_v3_index_$case_name.json"
  local index_host_path="/tmp/ota-store-v3-index-$case_name.json"
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
record_metrics() {
  CASE_NAME="$1" FAULT_POINT="$2" INSPECTOR_FILE="$3" \
    curl -fsS "$OTA_SERVER/__test__/metrics" | \
    CASE_NAME="$1" FAULT_POINT="$2" INSPECTOR_FILE="$3" node -e '
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
        const result = {
          case: process.env.CASE_NAME,
          faultPoint: process.env.FAULT_POINT,
          latestRequestCount: metrics.latestRequestCount,
          bundleRequestCount: metrics.bundleRequestCount,
          bundleBytes: metrics.bundleBytes,
          latestStatuses: latest.map(item => item.statusCode),
          bundlePaths: bundles.map(item => item.bundlePath),
          bundleStatuses: bundles.map(item => item.statusCode),
          activeVersion: metrics.activeVersion,
          scenario: metrics.scenario,
          inspectorSummary
        };
        console.log(JSON.stringify(result));
      });
    ' >> "$OUTPUT"
}

run_fault_case() {
  local fault_point="$1"
  install_clean_v1
  set_active V2
  set_scenario normal
  reset_metrics
  force_stop
  start_with_fault "$fault_point"
  sleep 4
  local inspector_file
  inspector_file="$(dump_inspector "fault-$fault_point")"
  record_metrics "fault-$fault_point" "$fault_point" "$inspector_file"
  case "$fault_point" in
    after_objects_ready|after_manifest_commit|before_state_commit|after_state_commit_report_failure|enospc_object_publish|enospc_manifest_commit|enospc_state_commit)
      set_active V2
      set_scenario normal
      reset_metrics
      force_stop
      "$HDC" -t "$HDC_TARGET" shell 'aa start -a EntryAbility -b com.example.lynxshell -W' >/dev/null
      sleep 4
      local retry_inspector_file
      retry_inspector_file="$(dump_inspector "retry-$fault_point")"
      record_metrics "retry-$fault_point" "normal_retry" "$retry_inspector_file"
      ;;
  esac
}

run_capacity_case() {
  install_clean_v1
  set_active V2
  set_scenario normal
  reset_metrics
  force_stop
  start_with_capacity_override 0
  sleep 4
  local inspector_file
  inspector_file="$(dump_inspector "capacity-zero")"
  record_metrics "capacity-zero" "capacity_override=0" "$inspector_file"
}

run_disconnect_case() {
  install_clean_v1
  set_active V2
  set_scenario disconnect
  reset_metrics
  force_stop
  "$HDC" -t "$HDC_TARGET" shell 'aa start -a EntryAbility -b com.example.lynxshell -W' >/dev/null
  sleep 4
  local inspector_file
  inspector_file="$(dump_inspector "server-disconnect")"
  record_metrics "server-disconnect" "server_scenario=disconnect" "$inspector_file"
}

for fault_point in \
  before_object_publish \
  after_object_publish \
  after_objects_ready \
  before_manifest_commit \
  after_manifest_commit \
  before_state_commit \
  after_state_commit_report_failure \
  enospc_object_publish \
  enospc_manifest_commit \
  enospc_state_commit
do
  run_fault_case "$fault_point"
done

run_capacity_case
run_disconnect_case

assert_status=0
node "$REPO_ROOT/scripts/ota-store-v3/assert-harmony-results.mjs" fault "$OUTPUT" || assert_status=$?
set_active V1
set_scenario normal
if [[ "$assert_status" -ne 0 ]]; then
  exit "$assert_status"
fi

echo "HarmonyOS fault smoke 完成并通过机器断言：$OUTPUT"
