# H1 Result — Discovery

Status: completed

- Confirmed `lynx_shell_kit` owns OTA Runtime, ReleaseTransaction, rawfile registry, Page and Tab containers.
- Confirmed `lynx_shell` owns Ability, Launcher and ArkUI Tabs and consumes the HAR.
- Confirmed the old Harmony store used global `releases/`, `states/` and `.staging/`.
- Confirmed the existing Tab was cache-only but did not retain a Release lease.
- Locked the new layout to `apps/<8-digit appId>/state.json`, app-scoped `releases` and `.staging`.
