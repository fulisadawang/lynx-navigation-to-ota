# H2 Result — Store and runtime

Status: completed

- Replaced the global Harmony store layout with Store v2 App ID scoped directories.
- Added schema v2 state containing only current/previous.
- Added bounded prune, cold orphan/staging maintenance and `statfs.getFreeSizeSync` preflight.
- Added `OtaBundleLease` to prepared remote current Bundles and connected Page/Tab teardown paths.
- Routed lease-release pruning through the same Runtime operation queue as download/publish/delete.
- Removed legacy state fields and all candidate/trial implementation references from Harmony OTA source.
- HAR/App compilation passed after explicit ArkTS interfaces replaced inline object types.
