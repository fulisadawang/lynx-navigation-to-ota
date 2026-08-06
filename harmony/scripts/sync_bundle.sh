#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "用法: $0 /absolute/path/to/main.lynx.bundle" >&2
  exit 64
fi

SOURCE="$1"
if [[ ! -f "$SOURCE" ]]; then
  echo "Bundle 不存在: $SOURCE" >&2
  exit 66
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="$ROOT_DIR/lynx_shell/src/main/resources/rawfile/bundles"
mkdir -p "$TARGET_DIR"
cp "$SOURCE" "$TARGET_DIR/main.lynx.bundle"
echo "已同步 HarmonyOS Bundle -> $TARGET_DIR/main.lynx.bundle"
