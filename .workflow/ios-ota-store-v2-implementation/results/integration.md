# Integration

## Store core

- Physical layout: `apps/<lynxAppId>/releases/<releaseId>`.
- State, staged and candidate pointers use schema version 2.
- Old Store migration and legacy fallback code were removed.
- Embedded bytes stay in the App Bundle; only metadata is written to `embedded.json`.
- Normal retention is current + previous; candidate adds at most one remote release.
- Cold maintenance and capacity preflight are implemented.

## Runtime and containers

- `OtaBundleLease` is acquired together with the exact current/candidate Bundle.
- `LynxContainerViewController` owns the lease until provider/view teardown.
- `LynxTabViewController` uses the same lease and remains cache-only.
- Cancelled or stale async resolutions close their unaccepted lease.
- Last lease close performs app-scoped pruning.

## Diagnostics and demo

- The snapshot API is read-only and serialized by the Store actor.
- Launcher and Native Tab can push `OtaStorageInspectorViewController`.
- Inspector displays paths, roles, state, candidate, files, bytes and staging.

## Preserved boundaries

- Existing project.pbxproj signing/resource changes were preserved.
- Existing `ShellTransitionCoordinator.swift` navigation changes were not redesigned.
- Android and HarmonyOS implementation files were not modified by this iOS packet.
- No Git commit, push or merge was performed.
