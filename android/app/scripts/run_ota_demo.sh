#!/usr/bin/env bash

# Android Demo 手动 OTA 验收脚本。
#
# 这个脚本只负责构建、安装和启动 Demo，不实现 HTTP 请求，也不接触 App ID。
# App 启动后由 LynxShellSampleApplication 调用现有的
# LynxRouter -> LynxOtaRuntime -> OtaSdk.syncLatestBundleLists() 链路；
# latest-bundle-list 返回的每个 lynxAppId 由原生 SDK 原样写入私有 OTA Store。

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
APK_PATH="$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
GRADLE_BIN="${GRADLE_BIN:-$(command -v gradle || true)}"
ADB_BIN="${ADB_BIN:-$(command -v adb || true)}"

if [[ -z "$GRADLE_BIN" ]]; then
  echo "找不到 Gradle，请通过 GRADLE_BIN 指定 Gradle 8.14.4 的可执行文件" >&2
  exit 1
fi

if [[ -z "$ADB_BIN" ]]; then
  echo "找不到 adb，请通过 ADB_BIN 指定 Android SDK 的 adb" >&2
  exit 1
fi

if [[ -n "${ADB_SERIAL:-}" ]]; then
  ADB_ARGS=(-s "$ADB_SERIAL")
else
  ADB_ARGS=()
fi

"$GRADLE_BIN" -p "$ANDROID_DIR" :app:assembleDebug
"$ADB_BIN" "${ADB_ARGS[@]}" install -r "$APK_PATH"
"$ADB_BIN" "${ADB_ARGS[@]}" shell am start \
  -n com.example.lynxshell.debug/com.example.lynxshell.sample.MainActivity \
  --ez lynx_shell.show_native_launcher true

echo "Demo 已启动：Application 会使用原生全量 OTA 接口；需要手动重试时点击 Demo 内的全量同步按钮。"
