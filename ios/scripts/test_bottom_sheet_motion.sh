#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
ios_root="$(cd "$script_dir/.." && pwd)"
test_output="$(mktemp -d /tmp/lynx-bottom-sheet-motion.XXXXXX)"
trap 'rm -rf "$test_output"' EXIT

xcrun swiftc \
  "$ios_root/LynxShellKit/Transition/ShellBottomSheetMotion.swift" \
  "$ios_root/LynxShellKit/Transition/ShellHeroSheetMotion.swift" \
  "$ios_root/Tests/ShellBottomSheetMotionTests.swift" \
  -o "$test_output/ShellBottomSheetMotionTests"

"$test_output/ShellBottomSheetMotionTests"
