# RunStuff phase 0 — historical handover

> This records the Phase 0 starting point. RunStuff has since progressed through Phase 3. Use `CLAUDE.md` and `docs/runstuff-plan.md` for current status.

The text below describes the original Phase 0 handover and is retained for its process-layer findings.

## How to work here

- Builds/tests/fixture runs go through a subagent (`build-runner` pattern) to keep logs out of context. Commands:
  - `swift build --package-path spike`
  - `swift test --package-path spike` (needs Xcode selected, see below)
  - `spike/.build/debug/runstuff-spike --all` (whole suite, per-assertion report)
  - `spike/.build/debug/runstuff-spike <fixtures/name.sh | bare-scenario-name>`
  - Give fixture runs a timeout: `perl -e 'alarm N; exec @ARGV' -- <cmd>` (`timeout` isn't installed).
- C-interop questions: verify against SDK headers / xnu source before coding (the `apple-api-researcher` pattern). Prove behaviour with a fixture, don't reason about it. This has already caught two wrong conclusions (see Findings).
- Toolchain: `xcode-select` is now `/Applications/Xcode.app/Contents/Developer`, licence accepted (2026-09-11). `swift test` works. If a build behaves oddly, re-check `xcode-select -p`.
- The user wants findings surfaced, not papered over. "If assertions have to be rewritten to pass, that's a signal, not a chore." Show diffs to CLAUDE.md / docs/runstuff-plan.md before applying.

## Current suite status (before the in-progress change)

Last full run: **102 PASS, 0 FAIL, 10 deferred, 1 skipped**; 13 unit tests pass. The 1 skip is the controlling-terminal finding below.

## The two findings driving the current work

The user's decision: **investigate the ctty findings now; phase 1 does not open until they are resolved.** Rationale: the fixture suite is the phase-1 entry gate, and finding 1 means the gate currently certifies something untrue.

**Finding 1 — a raw (non-shell) program spawned by our `posix_spawn` + `POSIX_SPAWN_SETSID` gets NO controlling terminal.** `winch-fg.c` proved `open("/dev/tty")` returns -1 and `tcgetpgrp(fd0)` returns -1 for a raw binary. `ctty-probe.sh` and `ctrl-c.sh` passed only because they run via `/bin/sh`, and the shell acquires the ctty on startup. So those green assertions were testing the shell, not our spawn.

**Finding 2 — an interactive login shell (`-l -i -c`) leaves the tty with `tcgetpgrp == 0`** (no foreground group), so tty signals reach nothing. **Do NOT treat this as independent:** it was measured against the already-broken ctty state from finding 1. Fix finding 1 first, then RE-MEASURE finding 2 against a correct ctty. It may be an artefact.

## Audit result (done, for the plan)

Assertions that secretly rode on the shell's ctty, needing raw-binary coverage: `ctty-probe.sh` (ctty acquisition), `ctrl-c.sh` (0x03 → SIGINT), and `progress-bar.sh`'s "SIGWINCH reached the child" (resize delivery). Everything else (exit codes, output capture, drain, group kill, reap) does not depend on a ctty and stays valid. Action: add raw-binary fixtures for ctty / SIGINT / SIGWINCH once the helper lands; `winch-fg.c` is the right shape (extend it or add siblings).

## The fix for finding 1 (decided): bring the helper back

`posix_spawn` cannot acquire a ctty (no hook between SETSID and exec; no `POSIX_SPAWN_SETCTTY`). So spawn a tiny C helper that runs `ioctl(0, TIOCSCTTY, 0)` then `execv`s the real command. `exec` preserves the pid, so the reap/signal paths are unchanged. This is option 1 from the user; option 2 (`fork`+`login_tty`) was rejected as too risky in a multithreaded Swift host.

**Note for the plan:** this same helper target was written and deleted last round — deleted for the right reason (it looked unnecessary) on wrong evidence (a shell-based probe showed a ctty that the shell, not our spawn, had provided). That is twice a shell-based probe produced a misleading conclusion; name the pattern in the plan.

## Work in progress — STOPPED MID-EDIT here

Done this round (files written, compile not yet re-verified):
- `spike/Sources/runstuff-tty-helper/main.c` — the helper (TIOCSCTTY + execv). DONE.
- `spike/Package.swift` — re-added the `runstuff-tty-helper` executable C target. DONE.
- `spike/Sources/SpikeCore/SpawnSpec.swift` — added `ttyHelperPath: String?`. DONE.

**NOT yet done — do these next, in order:**

1. **`spike/Sources/SpikeCore/PTYSpawner.swift` — route through the helper and add CLOEXEC.** Currently `spawn()` calls `resolve(spec)` → `(realPath, realArgv)`, then `allocationQueue.sync { allocate(spec:path:argv:) }`, and `allocate` runs openpty…posix_spawn using `path`/`argv`. Change:
   - In `spawn()`, after `resolve`, build the exec target:
     ```swift
     let execPath: String
     let childArgv: [String]
     if let helper = spec.ttyHelperPath {
         execPath = helper
         childArgv = [helper, path] + argv.dropFirst()   // path is the resolved real command
     } else {
         execPath = path
         childArgv = argv
     }
     ```
     Pass `execPath`/`childArgv` into `allocate` (rename its params) and use them for `posix_spawn`. `resolve()` still validates the real command exists on the job PATH, so not-found still throws `executableNotFound` pre-spawn.
   - In `allocate`, immediately after the openpty retry loop succeeds, set close-on-exec on BOTH fds so a concurrent spawn's child cannot inherit them:
     ```swift
     _ = fcntl(master, F_SETFD, FD_CLOEXEC)
     _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
     ```
     The child's fds 0/1/2 come from `addopen(slavePath)` (a fresh open) + `adddup2`, so CLOEXEC on the parent's slave does not affect them. This is the user's preferred mechanism for the reap-stress race (fd inheritance) — keep the existing allocation serialization too (cheap belt-and-braces), but CLOEXEC is the real fix and also guards against fds opened elsewhere in the app.

2. **`spike/Sources/runstuff-spike/Harness.swift` — set `ttyHelperPath` on every spec.** Add a `let ttyHelperPath: String?` field to `Harness` and put it into every `SpawnSpec` built by `spec(...)` and `scriptSpec(...)`. 

3. **`spike/Sources/runstuff-spike/main.swift` — locate the helper.** `Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("runstuff-tty-helper").path`; if missing, fail loudly (it is now essential, not optional). Pass into `Harness`.

4. **Guard every negated `kill` (live bug).** `kill(-0, sig)` == `kill(0, sig)` signals RunStuff's own process group. `resize()` already guards `foreground > 0`. Centralise: add a private helper in `JobRuntime`
   ```swift
   @discardableResult private func killProcessGroup(_ pgid: pid_t, _ sig: Int32) -> Int32 {
       guard pgid > 0 else { assertionFailure("negated kill with non-positive pgid \(pgid)"); return -1 }
       return kill(-pgid, sig)
   }
   ```
   and route `signalGroup(_:)` and `resize()`'s SIGWINCH through it. Add a fixture asserting the zero case is refused (e.g. a job whose `tcgetpgrp(master)` is 0 — the interactive-login case — must not have RunStuff signal itself). Also document that the explicit SIGWINCH is belt-and-braces: `TIOCSWINSZ` already makes the kernel signal the foreground group.

5. **Re-measure finding 2** once the helper lands: rerun the `winch-fg` scenario's interactive-login observation. If `tcgetpgrp` is now a real foreground group, finding 2 was an artefact of finding 1; record that. If still 0, it is real and needs its own resolution (see next).

6. **Investigate dropping `-i` per job (finding 2 class-fix).** We only need interactive-login because nvm is a `.zshrc` shell function, so `-l` alone misses it — but that is needed for ENVIRONMENT, not execution. Approach (VS Code's shell-env resolution): once at app launch, capture the environment with `zsh -l -i -c 'export -p'` using a unique delimiter around the output and a hard timeout, then spawn every job under a plain non-interactive shell with the captured env. Fixture must confirm captured PATH is enough for `npm run dev`. Known costs to probe and document: rc files that prompt will hang (hence timeout), Powerlevel10k instant-prompt injects junk before the delimiter, and `nvm use` inside a job command still won't work (acceptable — the use case is `npm run dev`).

7. **New fixtures/coverage still owed:**
   - Raw-binary ctty / SIGINT / SIGWINCH (extend `winch-fg.c` or siblings), now expected to PASS via the helper.
   - EOF-while-sibling-running: spawn job A and job B; A exits while B runs; assert A's master reaches EOF (`drainEnded`) promptly. Tests no cross-job fd inheritance (the CLOEXEC fix).
   - `kill(0)` zero-pgid refusal (item 4).
   - Reclassify the `winch-fg` divergent-group skip as an **expected-failure tracked against finding 1**, not a plain SKIP ("not applicable" reads wrong for "known broken"). After the helper it should convert to a real PASS.

8. **Plan writes (confirmed by the user — write into `docs/runstuff-plan.md`):**
   - The six process-layer deferred assertions that will be verified against phase-1 code, not the spike: ANSI-stripped-copy match (colours §1), metrics sum across group (spawns-children §1), restart backoff + maxRestarts (crash-loop §5), ring eviction (firehose §1), port detection via `proc_pidfdinfo` (binds-port §2). The other four deferred are presentation (shell-mode hint copy ×2, SwiftTerm rendering ×2).
   - Staged phase-1 items: ship resolved-execPath-plus-version display unconditionally in the detail view; hold per-project shell mode; narrow project-pin detection to `.envrc` (direnv) and `.nvmrc`, warned at job creation; persist session IDs at spawn for orphan adoption and reconcile on launch; phase-1 entry gate = this fixture suite green against `JobRuntime` unchanged before feature work.
   - Note `proc_pidfdinfo` is undocumented libproc surface, blocked under App Store sandboxing (fine now, relevant only if MAS ever comes up).
   - The helper-deleted-on-wrong-evidence pattern (see above).

## Verified C-interop facts already established (don't re-derive)

- File actions run inside the `posix_spawn` syscall before it returns; the child holds the slave when it returns, so the parent closes its slave immediately. On any posix_spawn error no child exists.
- `read()` on the master after the last slave holder closes returns **0** (EOF), not EIO (that's Linux). Master EOF ≠ child exit (a grandchild can hold the slave; a child can close stdio and live). Cancel the read source on EOF or the level-triggered source spins. Kernel drops undrained output ~600 ms after last slave close, so drain from spawn.
- `NOTE_EXIT` fires before the child is a reapable zombie, so `waitpid(WNOHANG)` can return 0 at the exit event; use blocking `waitpid(pid,&status,0)` on a queue SEPARATE from the drain. libdispatch synthesises the exit event if the pid is already a zombie at attach.
- `TIOCSWINSZ` makes the kernel signal SIGWINCH to the tty's foreground process group, only when the size changed. So an explicit `kill(-pgid, SIGWINCH)` is redundant and, aimed at the job pgid, wrong under job control. `resize()` targets `tcgetpgrp(master)` and no-ops on unchanged size.
- macOS `openpty` is not safe against a concurrent `posix_spawn` fork; it fails with a garbage errno and the child's slave-open then fails (exit 127). Fixed by serializing the openpty…posix_spawn critical section AND (item 1) CLOEXEC on the pty fds.
- `posix_spawnattr_setflags` takes `Int16`; `POSIX_SPAWN_*` import as `Int32`, wrap with `Int16(...)`. `WIFEXITED` & co. are not imported; decode the status word by hand (low 7 bits = signal or 0; bits 8-15 = exit code; bit 7 = core flag). `addchdir_np` is deprecated at macOS 26 but silent at deployment target 14.

## Architecture of the spike (what's there)

`SpikeCore` (imports Darwin/Dispatch only): `PTYSpawner` (the one C-interop boundary), `JobRuntime` (actor: drain via read source, exit/reap on a separate shared serial queue, session-aware `stop()`, `resize()`), `ProcessTable` (sysctl/libproc queries), `OutputSpool` (file-backed retention so late subscribers replay and drain is proven with no subscriber), `ExitStatus`, `ShellMode` (login/interactiveLogin/direct; shell modes prefix `unset COLUMNS LINES;`), `SpawnEnvironment` (scrubbed launchd-like base; no COLUMNS/LINES — the ioctl is the size source). `runstuff-spike` = harness + scenarios (`Scenarios+Basic/Process/Drain/Shell.swift`, `Check.swift` reporter with phase tags + deferred inventory, `Harness.swift`, `Recorder.swift`, `Manual.swift`). Non-negotiable: `SpikeCore` never imports SwiftUI/AppKit.

## Memory

Project memory at `/Users/andy.harris/.claude/projects/-Users-andy-harris-Repos-runstuff/memory/`. Relevant files: `ctty-shell-vs-raw.md`, `probe-the-cause-not-the-consequence.md`, `tag-assertions-not-fixtures.md`, `fixtures-base-system-only.md`, `toolchain-clt-only.md`, `show-doc-diffs-before-applying.md`. Keep them current.

## Commit attribution

The session's attribution trailer has changed twice. Confirm the current one from the latest system reminder before committing. Nothing has been committed yet; the repo was `git init`'d this session but has no commits.
