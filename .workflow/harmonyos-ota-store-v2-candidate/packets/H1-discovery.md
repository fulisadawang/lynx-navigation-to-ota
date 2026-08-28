# H1 — Harmony discovery

Objective: confirm the existing Harmony implementation and define the migration boundary.

Findings:

- `lynx_shell_kit` owns OTA Runtime, ReleaseTransaction, rawfile registry, Page and Tab containers.
- `lynx_shell` owns Stage/Ability, native Launcher and ArkUI Tabs; it consumes the HAR.
- Existing Store is globally rooted at `releases/`, `states/` and `.staging/`.
- Existing Tab is cache-only but returns unleased prepared files; Page/Tab do not retain Release lifetime.
- Existing Harmony code has no candidate state machine; this packet keeps it that way.

Decision: use `apps/<lynxAppId>/state.json`, `apps/<lynxAppId>/releases/` and app-scoped `.staging/`; add
lease and diagnostics in the HAR, and add the Inspector Page in the Demo Entry.
