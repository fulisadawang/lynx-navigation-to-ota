#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "用法: $0 /absolute/path/to/bundle-or-dist-dir" >&2
  exit 64
fi

SOURCE="$1"
if [[ ! -e "$SOURCE" ]]; then
  echo "Bundle 文件或目录不存在: $SOURCE" >&2
  exit 66
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android/app/src/main/assets/bundles"
IOS_DIR="$ROOT_DIR/ios/LynxShellSample/Resources/Bundles"
HARMONY_DIR="$ROOT_DIR/harmony/lynx_shell/src/main/resources/rawfile/bundles"

mkdir -p "$ANDROID_DIR" "$IOS_DIR" "$HARMONY_DIR"

if [[ -f "$SOURCE" ]]; then
  BUNDLE_FILES=("$SOURCE")
  SOURCE_DIR="$(dirname "$SOURCE")"
elif [[ -d "$SOURCE" ]]; then
  SOURCE_DIR="$SOURCE"
  shopt -s nullglob
  BUNDLE_FILES=("$SOURCE_DIR"/*.lynx.bundle)
  shopt -u nullglob
  if [[ ${#BUNDLE_FILES[@]} -eq 0 ]]; then
    echo "目录中没有 .lynx.bundle: $SOURCE" >&2
    exit 66
  fi
else
  echo "参数必须是 Bundle 文件或目录: $SOURCE" >&2
  exit 64
fi

for bundle in "${BUNDLE_FILES[@]}"; do
  name="$(basename "$bundle")"
  cp "$bundle" "$ANDROID_DIR/$name"
  cp "$bundle" "$IOS_DIR/$name"
  cp "$bundle" "$HARMONY_DIR/$name"
done

if [[ -d "$SOURCE_DIR/static" ]]; then
  mkdir -p "$ANDROID_DIR/static" "$IOS_DIR/static" "$HARMONY_DIR/static"
  cp -R "$SOURCE_DIR/static/." "$ANDROID_DIR/static/"
  cp -R "$SOURCE_DIR/static/." "$IOS_DIR/static/"
  cp -R "$SOURCE_DIR/static/." "$HARMONY_DIR/static/"
fi

echo "已同步 ${#BUNDLE_FILES[@]} 个 Bundle:"
for bundle in "${BUNDLE_FILES[@]}"; do
  echo "  $(basename "$bundle")"
done
echo "  Android  -> $ANDROID_DIR"
echo "  iOS      -> $IOS_DIR"
echo "  Harmony  -> $HARMONY_DIR"
