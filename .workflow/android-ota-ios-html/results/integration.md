# Android integration decision

## Accepted

- Android current/previous/embedded transaction behavior and candidate opt-in state machine。
- Activity candidate trial/healthy confirmation and one-shot first-screen recovery wiring。
- Tab cache-only boundary and explicit host refresh boundary。
- Manifest-derived unique demo identity instead of filename/appId guessing。
- No-token runtime gate and direct APK AssetManager embedded loading without startup copy。
- Android fault runner lane and standalone HTML report。

## Rejected or deferred

- No instrumentation target was invented to make UI coverage appear complete。
- No live release delta was inferred while the server latest equals the embedded release。
- No token was written to source, report, workflow artifacts, or Obsidian。

## Remaining risks

- Need a server-published higher Android release for a real V1 -> V2 visual update proof。
- Need a future debug-only first-screen fault injector and instrumentation target for complete device rollback/force-stop automation。
