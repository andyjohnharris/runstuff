# RunStuff

macOS menu bar app for supervising local dev servers and long-running processes.
Swift 6 / SwiftUI · deployment target macOS 14 · unsandboxed · hardened runtime · Developer ID.

**The build plan is `docs/runstuff-plan.md`. Read it before proposing any architecture.** It is the source of truth for scope, phasing, the data model and the design direction. If this file and the plan conflict, the plan wins. If you think the plan is wrong, say so and stop — don't quietly do something else.

---

## Current phase: 3

<!-- Update this line when a phase's exit criteria are met. Nothing else gates the work. -->

Phases are implementation gates, not prolonged soak periods. Do not write code belonging to a later phase than the one above, even if it seems trivial and even if you're already in the right file. If a phase-0 task seems to need a phase-2 thing, that's a signal the plan needs revisiting — raise it.

| Phase | Scope | Exit criteria |
|---|---|---|
| 0 | CLI spike: PTY spawn, drain, resize, kill, reap | Every phase-0-tagged assertion in `fixtures/` is green under `spike/`; deferred assertions report SKIPPED with their phase; no FAIL. No Xcode project exists yet. |
| 1 | Supervisor, model, persistence, status item, panel, detail, editor, SwiftTerm window, basic notifications | Clean Xcode build and tests; every phase-0 and phase-1 assertion passes; start, input, resize, stop and terminal rendering are verified end to end |
| 2 | Charts, sparklines, port detection, signal rules, notification actions, orphan recovery, a11y | Plan §4 and §6 fully implemented |
| 3 | Attach CLI + socket, terminal launch templates, Sparkle, Keychain env | — |
| 4 | Groups, health probes, URL scheme, App Intents | — |

**Phase 0 has no UI.** Not a window, not an app target, not a SwiftUI file. It is a command-line SwiftPM executable in `spike/`. Building UI on an unverified process layer is the specific failure this gate exists to prevent.

---

## Non-negotiables

These come from hard-won detail in the plan. Breaking one produces a bug that looks like something else entirely, so they don't get relaxed for convenience.

1. **Always drain the PTY**, from spawn to exit, whether or not anyone is watching. An undrained master fd fills the kernel buffer and the child blocks on `write()`. Symptom: the dev server "hangs" for no reason.
2. **Kill the whole job, never the pid.** `kill(-pid, SIGTERM)` is the fast path: `npm` exits, and the `node` it spawned would otherwise keep port 3000, which is why spawn uses `POSIX_SPAWN_SETSID` (pgid == pid). But a working controlling terminal turns on job control in an interactive login shell, and the shell then puts a compound command in its own process group, which `kill(-pid)` misses. So verify and escalate by session: enumerate live pids, compare `getsid(pid)` to the job's sid, and signal the stragglers. `stop()` sends SIGTERM to the group and the session, waits the grace period, then SIGKILLs whatever is left.
3. **Spawn through a login shell by default.** A GUI app inherits launchd's `PATH`, not yours. nvm/mise/asdf/Homebrew all break otherwise. See plan §1.
4. **Store raw bytes; match on a stripped copy.** Never strip ANSI from what SwiftTerm renders, never match patterns against bytes containing escape codes.
5. **`Supervisor` and everything under it must not import SwiftUI or AppKit.** It publishes `AsyncStream<SupervisorEvent>`. UI and notifications are both just consumers.
6. **`RunState` and `Health` stay separate types.** A running server that printed a compile error is `running` + `warning`. Collapsing them will be regretted.
7. **No invented error heuristics.** Detection is exit code, signal, spawn failure, and user-authored `SignalRule`s. Do not add built-in pattern matching for the word "error". The plan explains why at length.
8. **Never commit a `TODO` in place of a required behaviour.** If something can't be done, stop and say so.

---

## Working agreement

**Before writing code:** state which phase item you're implementing and which plan section covers it. If neither, stop and ask.

**Definition of done for any change:**
- Builds clean with warnings-as-errors.
- Behaviour verified against a fixture or test, not by reading the code back.
- No new dependency without asking first.

**C interop is the high-risk area.** `posix_spawn`, `openpty`, `ioctl`, `proc_pid_rusage`, `proc_pidfdinfo`, signal handling and their Darwin-specific quirks are where plausible-looking wrong code is easiest to produce. In that territory: verify each call's signature and flag semantics against Apple's headers or docs before using it (delegate to `apple-api-researcher`), and prove behaviour with a fixture rather than reasoning about it. Say when you're unsure — a flagged guess is far cheaper here than a confident one.

**Verbose output goes to a subagent.** `xcodebuild` produces enormous logs that will flood the main context for no benefit. Use `build-runner`. Same for anything that greps large log files.

**Don't ask permission for small reversible things** (renaming a local, adding a test, restructuring a private function). Do ask before: adding a dependency, changing a type in the plan's data model, deviating from a non-negotiable, or starting a new phase.

---

## Commands

```bash
# Phase 0
swift build --package-path spike
swift run --package-path spike runstuff-spike fixtures/<name>.sh
swift run --package-path spike runstuff-spike --all          # every fixture, per-assertion report
swift run --package-path spike runstuff-spike --manual fixtures/<name>.sh   # eyeball raw output in Terminal

# Phase 1+
xcodebuild -scheme RunStuff -destination 'platform=macOS' -skipPackagePluginValidation build 2>&1 | xcbeautify
xcodebuild -scheme RunStuff -destination 'platform=macOS' -skipPackagePluginValidation test 2>&1 | xcbeautify
swiftformat . && swiftlint
```

Run builds through `build-runner` so the log stays out of this conversation.

---

## Fixtures

`fixtures/` is the acceptance suite for the process layer. Every fixture is written in phase 0 and runs on every `--all`. Assertions, not fixtures, carry a phase tag: phase-0 assertions must pass before phase 0 closes; later-phase assertions report SKIPPED with their phase until that phase implements them, then must pass. The skip list is the inventory of what is still owed.

Rules:
- Fixtures depend only on the base system and the Command Line Tools. Anything else is a declared precondition, detected at run time; unmet → SKIPPED with the reason. Never FAIL on a missing tool, never PASS vacuously.
- POSIX sh. `/bin/sh` is bash 3.2: no `[[ ]]`, arrays, `local`, `read -p`, `$RANDOM`, `echo -e`, `\e` in printf (use `\033`).
- Fixtures spawn from a scrubbed launchd-like environment, never the harness's own.
- A hung child is a FAIL, not a reason to wait. Every run has a timeout.

| Fixture | Phase 0 asserts | Later assertions (phase) |
|---|---|---|
| `exit-clean.sh` | Exit 0; every byte captured, in order; EOF observed once | — |
| `exit-fail.sh` | Exit 1, distinguished from a signal | — |
| `not-found.sh` | Shell modes: exit 127 within 2s. Direct: spawn fails ENOENT, no child, no fd leak | Shell-mode hint copy (1) |
| `crash-delayed.sh` | Death by `SIGSEGV` after 5s, reported as a signal, in direct and login modes | — |
| `crash-loop.sh` | 20 crashes in a row each detected and reaped; no zombies; fd census unchanged | Backoff, `maxRestarts` (1) |
| `firehose.sh` | 300 MB drained with no consumer as fast as with one and as into `/dev/null`; byte count exact; child never blocks | Ring evicts correctly (1) |
| `colours.sh` | Raw bytes arrive unmodified, including a CSI split across writes; `TERM` reaches the child | SwiftTerm renders colour (1); stripped copy matches plain patterns (1) |
| `progress-bar.sh` | `\r` redraws captured; child reports the new `stty size` after `TIOCSWINSZ` + SIGWINCH and wraps at it | Redraw renders correctly in SwiftTerm (1) |
| `prompt-wait.sh` | Prompt bytes observed; input written to the master reaches the child; echo and response captured | — |
| `ctty-probe.sh` | Child can `open("/dev/tty", O_RDWR)`; its fd 0 and `e_tdev` are the slave; tty foreground pgrp is the job pgid | — |
| `ctrl-c.sh` + `ctrl-c-raw.c` | `0x03` written to the master kills both a shell fixture and a raw binary by SIGINT | — |
| `winch-fg.c` | Raw binary owns the ctty; resize reaches a foreground child group distinct from the job pgid; interactive login retains a foreground group | — |
| `eof-isolation` | One job reaches EOF promptly while a sibling job remains running | — |
| `binds-port.sh` | Listener accepts connections while running; port refused within 1s of group stop | Port detected via `proc_pidfdinfo` (2) |
| `spawns-children.sh` | Three descendants incl. a grandchild share the pgid; all die on one group kill; sweep empty | Metrics sum across them (1) |
| `job-control.sh` | Compound command under `-l -i`: one `stop()` catches every descendant, found by session not group | — |
| `ignores-sigterm.sh` | Alive through the grace period; SIGKILL escalation fires; group swept | — |
| `nvm-project/` | Precondition: nvm installed. Under `-l -i` the nvm node runs; under `-l` it does not; direct mode fails ENOENT | Hint copy (1) |
| `mise-project/` | Precondition: mise on the login PATH with the pinned node. Under `-l` the mise node runs at the pinned version; direct mode fails ENOENT | — |

---

## Conventions

- Swift 6 strict concurrency on. Raw fds and C callbacks stay confined to the `JobRuntime` actor; `@unchecked Sendable` only at one reviewed boundary, never sprinkled to silence a warning.
- `swift-format` config in repo. No force-unwraps outside tests.
- Commit messages: imperative, reference the phase (`phase 0: drain PTY on a dedicated read source`).
- "Stuff" is the user-facing word. `Job` is the code word. Don't mix them.
