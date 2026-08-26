#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
platform="ios"
tier="sdk"
case_id="all"

usage() {
  cat <<'EOF'
用法：
  bash scripts/ota-fault/run.sh [--platform ios|android] [--tier sdk|device] [--case F01|...|all]

平台说明：
  ios      sdk 执行 Swift Package 故障矩阵；device 执行 XCUITest/Simulator 矩阵
  android  sdk 执行 lynx-shell JVM 故障矩阵；device 由 AndroMeld 真机工作流执行
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      platform="$2"
      shift 2
      ;;
    --tier)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      tier="$2"
      shift 2
      ;;
    --case)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      case_id="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$platform" != "ios" && "$platform" != "android" ]]; then
  echo "不支持的平台：$platform（只支持 ios 或 android）。" >&2
  exit 2
fi

if [[ "$platform" == "android" ]]; then
  if [[ "$tier" == "device" ]]; then
    echo "UNAVAILABLE: Android device 故障矩阵需要 AndroMeld Phone Screen；请使用 Android 真机验收工作流。" >&2
    exit 2
  fi
  if [[ "$tier" != "sdk" ]]; then
    echo "不支持的 Android tier：$tier（只支持 sdk 或 device）。" >&2
    exit 2
  fi

  gradle_bin="${GRADLE_BIN:-}"
  if [[ -z "$gradle_bin" ]] && command -v gradle >/dev/null 2>&1; then
    gradle_bin="$(command -v gradle)"
  fi
  if [[ -z "$gradle_bin" ]]; then
    gradle_bin="/Users/nieyutan/.gradle/wrapper/dists/gradle-8.11.1-bin/bpt9gzteqjrbo1mjrsomdt32c/gradle-8.11.1/bin/gradle"
  fi
  [[ -x "$gradle_bin" ]] || { echo "找不到可执行 Gradle：$gradle_bin" >&2; exit 2; }
  android_java_home="${ANDROID_JAVA_HOME:-${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}}"
  [[ -d "$android_java_home" ]] || { echo "找不到 Android JDK：$android_java_home" >&2; exit 2; }
  case "$case_id" in
    all|A-SDK-01|F01|F03|F04|F06|F07|F08|F09|F12|F17|F18)
      echo "[Android OTA] :lynx-shell:testDebugUnitTest"
      JAVA_HOME="$android_java_home" "$gradle_bin" -p "$repo_root/android" :lynx-shell:testDebugUnitTest --console=plain --no-daemon
      ;;
    A-VC-01|A-VC-02|A-PAR-01|A-LIFE-01|A-TAB-01|A-TAB-02|A-TAB-03|A-ROLL-01|A-ROLL-02|A-REC-01a|A-REC-01b|A-REC-01c|A-ERR-01|A-CONF-01|A-RACE-01)
      echo "UNAVAILABLE: $case_id 当前需要 Android instrumentation/AndroMeld 真机；不以 JVM 单测冒充通过。" >&2
      exit 2
      ;;
    *)
      echo "未知 Android case：$case_id" >&2
      usage >&2
      exit 2
      ;;
  esac
  exit 0
fi

if [[ "$tier" == "device" ]]; then
  echo "UNAVAILABLE: iOS 设备故障矩阵需要 XCUITest Target、simctl 重启和可替换 Lynx Runtime。" >&2
  echo "已实现的 SDK 层可先运行：bash scripts/ota-fault/run.sh --platform ios --tier sdk --case all" >&2
  exit 2
fi

if [[ "$tier" != "sdk" ]]; then
  echo "不支持的 tier：$tier（只支持 sdk 或 device）。" >&2
  exit 2
fi

package_dir="$repo_root/ios/OtaIOSSDK"
run_filter() {
  local filter="$1"
  echo "[iOS OTA] swift test --filter $filter"
  swift test --filter "$filter"
}

case "$case_id" in
  all)
    (cd "$package_dir" && swift test)
    ;;
  F01|F03|F04|F06|F17|F18)
    (cd "$package_dir" && run_filter OtaSDKFaultPathTests)
    ;;
  F05)
    (cd "$package_dir" && run_filter OtaSDKTests)
    ;;
  F07|F08|F12)
    (cd "$package_dir" && run_filter OtaTransactionFaultTests)
    ;;
  F09)
    (cd "$package_dir" && run_filter OtaCandidateActivationTests)
    ;;
  F10|F11|F13|F14|F15|F16)
    echo "UNAVAILABLE: $case_id 当前需要 iOS UI/设备测试目标；SDK 层没有对应的真实运行态证据。" >&2
    exit 2
    ;;
  *)
    echo "未知 case：$case_id" >&2
    usage >&2
    exit 2
    ;;
esac
