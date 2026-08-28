# H2 — Store and runtime

Objective: implement Harmony Store v2 without candidate.

Ownership: `harmony/lynx_shell_kit/src/main/ets/ota`, Page/Tab lifecycle files.

Required: app-scoped path, schema v2, current/previous, bounded prune, cold cleanup, statfs preflight,
rawfile no-copy, Release lease and stale async result release.

Rejected: candidate/trial files or APIs, top-level global release paths, copying embedded bytes.
