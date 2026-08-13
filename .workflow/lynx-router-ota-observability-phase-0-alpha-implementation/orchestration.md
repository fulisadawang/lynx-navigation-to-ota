# Orchestration: Lynx Router OTA Observability Phase 0 Alpha Implementation

## Execution Rules

- Keep the original objective intact.
- Ask for approval before risky, expensive, external, or destructive actions.
- Keep immediate blocking work local.
- Delegate only bounded, disjoint, materially useful packets.
- Integrate packet results before final verification.

## Branching Rules

- Root branch: `feature/telemetry-phase0-alpha`.
- Do not merge or push during this run.
- Preserve pre-existing dirty changes from `main`; only add owned files.
- Workers run in parallel; P0-CONTRACTS should finish first logically, but P1 workers may scaffold against the
  documented target field names and adapt once fixtures are available.

## Packet Prompts

### P0-CONTRACTS

```text
You own only schemas/telemetry/, fixtures/telemetry/, and docs/telemetry/ in the target repo.
You are not alone in the codebase; do not revert other workers' edits. Implement the D2 Phase 0 contract:
Wire Schema 3.0.0, Remote Config Schema 1.0.0, identity/state/Attempted+Resolved Bundle Snapshot fixtures,
and a deterministic validation command or tests. Keep fields platform-neutral, mark nullable IDs explicitly,
document navigation admission vs transition terminal, activeEligible, samplingGroup/sample denominator, and
DeliveryOwner. Use Chinese comments/docs. Do not add secrets or network code. Report files, commands, and gaps.
```

### P1-ANDROID

```text
You own only Android telemetry package/test files under android/lynx-shell. You are not alone in the codebase;
do not revert other workers' edits. Implement a minimal local Alpha Coordinator and pure Kotlin models for
entryId/pageViewId/renderAttemptId/activationId, AttemptedBundleSnapshot/ResolvedBundleSnapshot, admission vs
transition terminal, page/app state, and no-op/debug delivery. Use Chinese comments, bounded inputs, native-only
identity fields, and fail-open behavior. Add focused unit tests. Do not change OTA download semantics, Router
open callback semantics, production networking, or unrelated files. If existing SDK APIs block integration,
add a typed adapter and document the gap instead of faking a successful hook. Report compile/test evidence.
```

### P1-IOS-HARMONY

```text
You own only ios/LynxShellKit/Telemetry plus Swift tests and harmony/lynx_shell_kit/src/main/ets/telemetry plus
its tests/config. You are not alone in the codebase; do not revert other workers' edits. Implement matching local
Alpha identity/snapshot/state/coordinator/no-op-debug sink behavior, with Chinese comments and focused pure logic
tests where toolchains allow. Keep wire names aligned to shared D2 contracts. Connect only to existing lifecycle
surfaces; do not invent unsupported Lynx 4.0 callbacks, alter OTA/Router behavior, add network uploads, or touch
Android. For ArkTS/toolchain gaps, leave a typed boundary and report [待确认].
```

## Completion Audit

- [ ] All packets have an owner, owned paths, explicit non-goals, and verification evidence.
- [ ] Shared Schema and platform models agree on required/optional fields and enum values.
- [ ] No production upload/durable queue was accidentally introduced in Alpha.
- [ ] User dirty changes are preserved.
- [ ] Workflow verifier and project checks have been run.
