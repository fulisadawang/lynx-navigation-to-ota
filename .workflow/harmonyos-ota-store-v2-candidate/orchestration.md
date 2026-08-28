# Orchestration: HarmonyOS OTA Store v2 无 Candidate 对齐

## Execution Rules

- Keep the original objective intact.
- Ask for approval before risky, expensive, external, or destructive actions.
- Keep immediate blocking work local.
- Delegate only bounded, disjoint, materially useful packets.
- Integrate packet results before final verification.
- Current task is executed by the main agent with isolated packet notes; no programmable subagent runner is available.

## Branching Rules

- If DevEco/Hvigor is unavailable, finish source/static/store contract checks and mark build/runtime as pending.
- If the real OTA server is unreachable, use deterministic local fixtures or existing rawfile data; never claim a live pass.
- If a state file is malformed, cold maintenance skips that App ID conservatively; explicit user delete may still clean known files.
- If a lease is active, prune/delete must retain its Release until the lease closes.
- Candidate-related code is rejected during integration, even if it appears in copied Android/iOS examples.

## Packet Prompts

- H1: identify actual Harmony call chain, old paths, duplicate Entry files and build commands; do not edit.
- H2: implement only `lynx_shell_kit` OTA models/Store/runtime/container lease and tests/static seams.
- H3: implement only Harmony Demo Inspector/Launcher/Tab entry and documentation.
- H4: run final source/static/build/runtime checks, synthesize evidence, sync Obsidian; do not alter Android.

## Completion Audit

- Confirm no Harmony implementation/reference contains `candidate`, `trial` or `candidate.json`.
- Confirm all remote file paths include `apps/<appId>` and no production code uses top-level `releases`/`states`.
- Confirm current/previous, no-copy rawfile, lease release, cold prune, capacity and Inspector have separate evidence.
