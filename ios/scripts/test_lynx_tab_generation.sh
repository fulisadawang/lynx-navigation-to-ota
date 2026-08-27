#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
ios_root="$(cd "$script_dir/.." && pwd)"
test_output="$(mktemp -d /tmp/lynx-tab-generation.XXXXXX)"
trap 'rm -rf "$test_output"' EXIT

xcrun swiftc \
  "$ios_root/LynxShellKit/Container/LynxTabLoadGeneration.swift" \
  "$ios_root/Tests/LynxTabLoadGenerationTests.swift" \
  -o "$test_output/LynxTabLoadGenerationTests"

"$test_output/LynxTabLoadGenerationTests"
