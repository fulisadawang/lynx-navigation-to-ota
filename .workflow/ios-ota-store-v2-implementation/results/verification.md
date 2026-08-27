# Verification

Date: 2026-08-27

## TDD evidence

- Store v2 tests initially failed against the old global release layout.
- SDK init test initially observed old top-level pointer paths.
- Lease, diagnostics, cold-maintenance and capacity tests initially failed to compile because the APIs did not exist.
- Production code was then implemented until all focused and full tests passed.

## Final commands and results

- `cd ios/OtaIOSSDK && swift test`: 47 tests / 8 suites / 0 failures.
- `python3 scripts/static_check_android_ios.py`: 111 PASS / 0 WARN / 0 FAIL.
- `python3 scripts/static_check.py`: 191 PASS / 0 WARN / 0 FAIL.
- `git diff --check`: passed.
- XcodeBuildMCP `build_sim`: Debug iOS Simulator build passed; one pre-existing PrimJS script-output warning.
- HTML report JS parse: 1 script parsed; 18 case cards; 8 score cards; no duplicate IDs.
- Browser visual validation: not re-run because the built-in browser rejected opening a new local `file://` page by URL policy. No bypass was attempted.

## Simulator runtime

Device: iPhone 16 Pro / iOS 18.1 Simulator.

- Fresh uninstall/install and native Launcher launch succeeded.
- Real TEST OTA produced Store v2 app directories for 10000000, 10000001 and 10000002.
- No old top-level `releases`, `states` or `.staging` paths were present.
- Inspector showed 3 apps, 53 files and approximately 5.1 MB.
- Inspector refresh added zero OTA requests.
- Native Tab loaded 10000001 / r20260823_qc8ffc / OTA current / main.lynx.bundle.
- While Native Tab remained alive, Inspector marked the release as current and leased.
- After leaving Native Tab, Inspector no longer showed the leased marker.

No token value is recorded in this file.
