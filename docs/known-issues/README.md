# Known issues

Local placeholders for bugs discovered against external Animus plugins / tooling, before they're filed upstream.

| File | Plugin / component | Severity | Filed upstream |
|---|---|---|---|
| [animus-subject-linear-missing-methods.md](#animus-subject-linear-v014--missing-subjectcreate--subjectcomment) | `animus-subject-linear` v0.1.4 | blocker for our discovery flow | [issue #2](https://github.com/launchapp-dev/animus-subject-linear/issues/2) |
| [animus-queue-default-init-fails.md](./animus-queue-default-init-fails.md) | `animus-queue-default` v0.2.0 | non-blocking (daemon falls back) | not yet |
| [animus-workflow-runner-default-init-fails.md](./animus-workflow-runner-default-init-fails.md) | `animus-workflow-runner-default` v0.3.0 | non-blocking (legacy fallback) | not yet |

## animus-subject-linear v0.1.4 — missing subject/create + subject/comment

Filed upstream at https://github.com/launchapp-dev/animus-subject-linear/issues/2. No local placeholder file — see the GitHub issue for full details. Summary: plugin advertises only `subject/list`, `subject/get`, `subject/update`, `subject/schema`, `health/check`. Missing `subject/create` (needed to file new Linear tickets) and `subject/comment` (needed to post progress comments). Declared `subject_kind` is `issue`, not `linear` as the README example implies. Both are blockers for the discovery flow's ticket-creation and ticket-loopback paths.

## Pattern note: queue-default + workflow-runner-default share a failure mode

Both reference plugins (queue + workflow runner) ship installed in v0.5.4 but fail `plugin ping` with `plugin initialize failed exit_code 1` and no stderr. The daemon falls back to bundled implementations so workflows still execute, but the v0.5 plugin replacement path isn't actually active. The identical symptom across two independent plugins suggests a shared root cause — possibly a regression in the plugin SDK's initialize handshake or an undocumented config dependency. Worth investigating together.
