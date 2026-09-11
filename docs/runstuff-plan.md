# RunStuff — end-to-end build plan

A macOS menu bar app for starting, supervising and inspecting long-running local dev processes without keeping a terminal window around for each one.

**Stack:** Swift 6 / SwiftUI, deployment target macOS 14.
**Distribution:** Developer ID signed + notarized, hardened runtime, **not** sandboxed. Shared as a DMG, not App Store.
**Output architecture:** one app-owned PTY per process, fanned out to a ring buffer and N live subscribers (your spec, adopted as-is).

Vocabulary note: the UI says "stuff", the code says `Job`. Keep the playfulness in headings, empty states and the add button; keep it out of error and confirmation copy, where people need to know exactly what's about to happen.

---

## 1. Architecture

```
┌─────────────────────────────────────────────────────────┐
│ UI (SwiftUI)                                            │
│  StatusItemController → NSPanel → RootView              │
│    ├── SummaryHeader (Swift Charts)                     │
│    ├── JobList → JobDetail                              │
│    └── ActionBar                                        │
│  TerminalWindowController (SwiftTerm) × N               │
│  JobEditorWindowController (add/edit sheet as a window) │
├─────────────────────────────────────────────────────────┤
│ Supervisor (actor)                                      │
│  ├── JobRuntime × N                                     │
│  │    ├── PTY (master fd, pid, pgid)                    │
│  │    ├── OutputBuffer (ring, raw bytes)                │
│  │    ├── OutputFanout (subscribers)                    │
│  │    ├── SignalScanner (patterns, on stripped copy)    │
│  │    └── MetricsSampler                                │
│  ├── LifecycleWatcher (process exit sources)            │
│  └── OrphanRegistry (runtime.json)                      │
├─────────────────────────────────────────────────────────┤
│ Services                                                │
│  ConfigStore (config.json, atomic + file-watched)       │
│  NotificationService (UNUserNotificationCenter)         │
│  LogArchive (~/Library/Logs/RunStuff)                   │
│  AttachServer (phase 3, unix socket)                    │
└─────────────────────────────────────────────────────────┘
```

Three rules that keep this clean:

1. **The Supervisor never imports SwiftUI.** It publishes an `AsyncStream<SupervisorEvent>`; the UI and the notification service are both just consumers. This is what makes the notification matrix in §6 a lookup table rather than calls scattered through the codebase.
2. **The PTY is always drained, whether or not anyone is watching.** If you only read when a terminal window is open, the kernel PTY buffer fills and the child process blocks on `write()`. Your dev server appears to hang. Reading starts at spawn and stops at exit.
3. **Raw bytes in, stripped copy for matching.** The ring buffer stores raw bytes so SwiftTerm renders colour correctly; the scanner works on an ANSI-stripped projection so `\e[31merror\e[0m` still matches `error`.

### Process spawn

`posix_spawn` rather than `Foundation.Process`, because you need `POSIX_SPAWN_SETSID` and `Process` won't give you it.

```swift
var master: Int32 = 0, slave: Int32 = 0
guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw PTYError.open(errno) }
fcntl(master, F_SETFD, FD_CLOEXEC)
fcntl(slave, F_SETFD, FD_CLOEXEC)
let slavePath = String(cString: ttyname(slave))

var attr: posix_spawnattr_t?
posix_spawnattr_init(&attr)
// SETSID: child becomes a session leader, and its pgid == its pid — see
// "killing" below.
// CLOEXEC_DEFAULT (Apple-specific): closes every fd we don't explicitly wire up.
posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

var actions: posix_spawn_file_actions_t?
posix_spawn_file_actions_init(&actions)
posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
posix_spawn_file_actions_adddup2(&actions, 0, 1)
posix_spawn_file_actions_adddup2(&actions, 0, 2)
posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
```

`posix_spawn` has no hook between `SETSID` and `exec`, and macOS has no `POSIX_SPAWN_SETCTTY`. Spawn the bundled `runstuff-tty-helper` through those file actions; it calls `ioctl(0, TIOCSCTTY, 0)` and then `execv`s the pre-resolved real command. `exec` preserves the pid, pgid and sid, so lifecycle control and reaping still track the final command. The helper is mandatory in production; helper-less spawn exists only for negative fixtures.

The spike originally deleted this helper after shell-based probes passed. That evidence was wrong: the shell acquired the ctty itself, hiding that a raw binary had none. Any process-layer claim must therefore be proved with the raw executable at the layer under test, not only through a shell wrapper. Raw fixtures now prove ctty acquisition, `0x03` → `SIGINT`, and `SIGWINCH` delivery.

Serialize the complete `openpty`…`posix_spawn` allocation section. Also apply `FD_CLOEXEC` to both parent fds immediately after `openpty`; serialization prevents this spawner's race, while close-on-exec prevents inheritance by children spawned elsewhere in the app. The helper receives fresh fds 0/1/2 from `addopen`/`adddup2`, so those parent flags do not close its stdio.

Then `close(slave)` in the parent and set the window size:

```swift
var ws = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
ioctl(master, TIOCSWINSZ, &ws)
```

Re-issue `TIOCSWINSZ` whenever a terminal window for that job resizes. The kernel signals the tty's current foreground process group when the size changes. An explicit belt-and-braces `SIGWINCH`, if retained, must target `tcgetpgrp(master)`, not the static job pgid: job control may foreground a different group. Never negate a non-positive pgid — `kill(-0, sig)` is `kill(0, sig)` and signals RunStuff's own process group. Without the resize, TUI-ish output (progress bars, Vite's box) wraps at whatever the default was.

**Killing:** because of `SETSID`, the job's pgid equals its pid and its sid equals its pid. `kill(-pid, SIGTERM)` reaches `npm` and the `node` it spawned in one call. Killing only the pid is the classic bug where stopping a job leaves the server holding port 3000. One caveat the spike proved: once the child has a controlling terminal, an interactive login shell runs job control and moves a compound command (`cmd && other`) into a new process group, so `kill(-pid)` alone misses it. Sweep and escalate by session (`getsid(pid) == job.sid`), not only by group.

**Reaping:** `DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)` on a queue separate from the drain, then a blocking `waitpid(pid, &status, 0)`. The kernel fires `NOTE_EXIT` before it marks the child a zombie, so `WNOHANG` at that instant can return 0; the blocking call returns as soon as the child is reapable, and keeping it off the drain queue means it never stalls the read source. libdispatch synthesises the exit event if the pid is already a zombie when the source attaches. Swift does not import `WIFEXITED` and friends; decode by hand: low 7 bits zero → exited with code `(status >> 8) & 0xff`; otherwise the low 7 bits are the terminating signal and bit 7 is the core-dump flag. A job killed by a signal is a different event from a job that exited 1.

**EOF:** on macOS, reading the master after the last slave holder closes returns `0`, confirmed by the spike (not `-1`/`EIO`, which is Linux). Treat `EIO` as EOF too; it costs nothing. EOF does not mean the child exited (a grandchild holding the slave keeps the master open) and its absence does not mean the child is alive (a child can close its stdio and keep running). Exit comes only from the process source. Cancel the read source on EOF: the master stays readable forever and an uncancelled level-triggered source spins. The kernel discards output the master has not read within 600 ms of the last slave close, one more reason draining starts at spawn.

### The PATH problem

A GUI-launched app inherits launchd's environment, not your shell's. `npm run dev` will fail with "command not found" for anyone using nvm, mise, asdf, Homebrew on Apple Silicon, or pyenv.

Per-job shell mode, defaulting to **login shell**:

| Mode              | Argv                      | When                                                                                        |
| ----------------- | ------------------------- | ------------------------------------------------------------------------------------------- |
| Login (default)   | `$SHELL -l -c "<cmd>"`    | Sources `.zprofile`/`.zshenv`. Covers Homebrew, mise, asdf.                                 |
| Interactive login | `$SHELL -l -i -c "<cmd>"` | Needed for **nvm**, which lives in `.zshrc`. Slower, and noisy `.zshrc` can pollute output. |
| Direct            | exec the argv directly    | Fast, predictable, for absolute paths and binaries.                                         |

Keep shell mode on each job; do not replace it with one global captured shell environment. The helper fixed the interactive-login tty problem, while one-time capture would add prompt timeouts and delimiter parsing and would not support commands such as `nvm use`.

Surface the resolved `PATH`, executable path and executable version in the job detail view unconditionally. At job creation, warn when the project contains `.nvmrc` or `.envrc` and the selected shell mode may bypass that setup. Do not infer managers from every possible pin file: the spike reproduced false confidence when multiple managers supplied the same executable name. When a job exits immediately with 127, the error state should say so directly: "Command not found. Try switching this job to an interactive login shell." Diagnosing this by hand is miserable and it'll happen to every friend you give the app to.

Env layering, lowest to highest: launchd env → shell startup files → RunStuff defaults (`TERM=xterm-256color`, `RUNSTUFF_JOB=<id>`) → per-job overrides. Do not set `COLUMNS` or `LINES`; `TIOCSWINSZ` is the terminal-size source of truth.

### Output buffer

Fixed-capacity ring of line records, default 10,000 lines, plus a byte ceiling (say 8 MB) so one job emitting a 400 MB minified bundle can't eat your RAM.

```swift
struct OutputLine {
    let seq: UInt64          // monotonic, survives eviction — subscribers resume from a cursor
    let timestamp: Date
    let raw: ArraySlice<UInt8>
    let stripped: String     // lazily computed, cached, used for matching and search
}
```

Strip ANSI with a small hand-rolled state machine rather than a regex — you're doing this on every line of every job. Handle CSI (`ESC [ … final`), OSC (`ESC ] … BEL` or `ST`), and bare two-byte escapes. Watch for sequences split across `read()` boundaries: keep a partial-escape carry between reads or you'll emit garbage mid-sequence.

"Spill to disk" writes the raw bytes to `~/Library/Logs/RunStuff/<slug>-<ISO8601>.log`. Optional per-job always-on logging with size-based rotation, off by default.

**Known limitation, worth being explicit about:** a single PTY merges stdout and stderr. That's exactly what a terminal shows you, and it's what makes colour and interactivity work — but it means you cannot classify a line as "an error" on the grounds that it came from stderr. If you later want that, it's a separate `stderr` pipe as an opt-in per job, at the cost of that stream losing its tty (many tools then drop colour and switch to non-interactive output). Don't build it until something demands it.

### Metrics

`proc_pid_rusage(pid, RUSAGE_INFO_V4, &info)` gives `ri_user_time` + `ri_system_time` (nanoseconds, cumulative) and `ri_resident_size`. CPU% is the delta of CPU time over the delta of wall time.

To capture `npm`'s children, enumerate processes via `sysctl(KERN_PROC_ALL)` and **filter by pgid** — the `SETSID` spawn means the job's whole tree shares one pgid, so no parent-pointer tree walk is needed. Sum rusage across the set.

Sampling cadence: 2s while the panel or a terminal window is open, 15s otherwise. Don't take an activity assertion to defeat App Nap — a menu bar utility that stops the machine idling will get uninstalled. Accept coarser background sampling and interpolate the sparkline.

**Port detection** (a strong addition to the list rows): `proc_pidinfo(pid, PROC_PIDLISTFDS, …)`, then `proc_pidfdinfo(…, PROC_PIDFDSOCKETINFO, …)` for each socket fd, keeping those in `TCPS_LISTEN`. Do it across the pgid set, refresh every few seconds for the first 30s after start then back off. Gives you a real `:3000` badge, and a "Open in browser" action that isn't guessing. `proc_pidfdinfo` is undocumented libproc surface and is blocked by App Sandbox; that is acceptable for the unsandboxed Developer ID distribution, but must be revisited if Mac App Store distribution is ever considered.

---

## 2. Data model

```swift
struct Job: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var command: String
    var workingDirectory: URL
    var shellMode: ShellMode = .login
    var env: [String: String] = [:]
    var openTerminalOnStart: Bool = false   // the inverse of your "run in background", default true
    var autostartOnLaunch: Bool = false
    var restartOnCrash: Bool = false
    var maxRestarts: Int = 3                // within 60s, then give up and escalate
    var signals: [SignalRule] = []          // user-editable patterns
    var readyRule: ReadyRule? = nil         // e.g. port opens, or a pattern like "ready in"
    var notifyWhenReady: Bool = false
    var notifyWhenWaitingForInput: Bool = false
    var notifyOnHighCPU: Bool = false
    var notes: String = ""
    var tags: [String] = []
    var colorSeed: Int                      // stable band colour in the aggregate chart
}

struct SignalRule: Codable, Hashable {
    var pattern: String
    var isRegex: Bool = false               // default substring — friendlier, and faster
    var severity: Severity                  // .info | .warning | .error
    var notify: Bool
    var caseSensitive: Bool = false
}

enum RunState { case idle, starting, running, stopping
                case exited(code: Int32), signalled(Int32), failedToStart(String) }

enum Health { case ok, warning(reason: String, since: Date), error(reason: String, since: Date) }
```

`RunState` and `Health` are deliberately separate. A dev server that printed a compile error is `running` + `warning`; a server that exited 1 is `exited(1)` + `error`. Collapsing them into one enum is the thing you'd regret in week three, because the menu bar icon needs the health axis while the row actions need the lifecycle axis.

`Health` is reset on every start, cleared when the user opens the detail view of a warned job (acknowledgement), and auto-expires for `.warning` after 10 minutes of clean output.

### Detection, per your steer

Ranked by how much you should trust it:

1. **Exit code ≠ 0**, where the stop wasn't user-initiated. Unambiguous. This is the backbone.
2. **Death by signal** (excluding the SIGTERM/SIGKILL you sent). `SIGSEGV`, `SIGABRT` → error. Only visible when the shell execs the command: zsh, bash and sh do so for a single simple command under `-c`; a compound command reports `128+n` as an exit code instead.
3. **Failure to start**: spawn errno, or exit 127 within 2s.
4. **User-authored `SignalRule`s.** Ships with an empty list and a "suggest rules" affordance that offers a handful of well-known ones (`EADDRINUSE`, `ELIFECYCLE`, `Cannot find module`) as _checkboxes the user opts into_, not defaults.

No built-in heuristic scanning for the word "error". Rate-limit rule matches to one notification per rule per 60s, or a watch-mode compiler failing in a loop will bury you.

---

## 3. Persistence

```
~/Library/Application Support/RunStuff/
    config.json        # jobs + settings, atomic write, hand-editable, file-watched
    runtime.json       # live pids/pgids/sids/start times, for orphan recovery
~/Library/Logs/RunStuff/
    <slug>-<timestamp>.log
```

Atomic write via write-to-temp + `FileManager.replaceItemAt`. Watch `config.json` with a `DispatchSource` vnode source so hand-edits reload live — debounce 300ms, validate before applying, and show an in-panel banner if the file is malformed rather than silently reverting.

UI preferences (window frames, terminal font/theme, panel width) go in `UserDefaults`, not `config.json`. Keep the shareable/portable thing free of machine-specific junk.

---

## 4. UI

### Menu bar item

**Recommendation: `NSStatusItem` + a borderless `NSPanel` hosting SwiftUI, not `MenuBarExtra`.**

`MenuBarExtra(.menuBarExtraStyle: .window)` gets you started in twenty minutes, but it has no supported way to programmatically open or close the window. You need that: after "Add stuff" completes, after "Stop all", and when a notification action should reveal a job. You'll also want right-click behaviour and full control over the panel's material and shadow. Build behind a thin `MenuBarPresenting` protocol so a `MenuBarExtra` prototype and the `NSStatusItem` implementation are interchangeable, and expect to land on the latter.

Icon states, rendered with `ImageRenderer` from a SwiftUI view and cached per state:

| State                  | Glyph         | Badge             | Template                  |
| ---------------------- | ------------- | ----------------- | ------------------------- |
| Nothing running        | Outline glyph | —                 | Yes (tints with menu bar) |
| n running, all healthy | Filled glyph  | `n`, label colour | Yes                       |
| Any warning            | Filled glyph  | `n` + amber dot   | No                        |
| Any error              | Filled glyph  | `n` + red dot     | No                        |

Two things here. Non-template images don't adapt to light/dark menu bars or to the "reduce transparency" wallpaper cases, so the coloured variants need both light and dark renderings chosen off `NSApp.effectiveAppearance`. And colour alone can't carry the warning/error distinction — the dot's _position and shape_ should differ too (amber triangle vs red circle), or use a distinct glyph overlay.

No animation. A pulsing or spinning menu bar icon in your peripheral vision all day is the fastest route to the app being quit permanently. The count changing is enough.

### Design direction

This is a native macOS utility, so the honest "distinctive" move is not an unusual typeface — deviating from SF in a menu bar panel reads as broken, not designed. Spend the boldness in one place instead:

> **The aggregate chart is the key.** The summary header shows one stacked area chart of total CPU over the last 60 seconds, with each job as its own coloured band. Each job's band colour is then reused as its status dot in the list below. The chart _is_ the legend. Glancing at the header tells you not just "something is busy" but _which thing_, and your eye lands on the right row without reading a single label.

Everything else stays quiet: system materials, system accent for interactive affordances, generous whitespace, no card-in-a-card.

**Tokens**

| Token   | Value                                     | Use                                         |
| ------- | ----------------------------------------- | ------------------------------------------- |
| Surface | `NSVisualEffectView`, `.popover` material | Panel background                            |
| Running | `#3FB950`                                 | Healthy state, chart bands tint from here   |
| Warning | `#D29922`                                 | Warning dot, warning banner                 |
| Error   | `#F85149`                                 | Error dot, failed rows, destructive confirm |
| Idle    | `.secondaryLabelColor`                    | Stopped rows, empty state                   |
| Accent  | `NSColor.controlAccentColor`              | Buttons, selection, focus rings             |

Band colours derive from `colorSeed` via an evenly-spaced hue rotation seeded off the running-set, kept at consistent saturation/lightness so no band shouts.

**Type:** SF Pro throughout the chrome — 13pt row titles (`.medium`), 11pt metadata (`.secondary`), 22pt for the single big number in the header. **SF Mono only where the content is literally terminal content**: commands, paths, ports, PIDs, log tails. That's the content justifying the face, not a decorative choice.

### Panel layout

Width 380pt, max height ~520pt with the job list scrolling and the action bar pinned.

```
┌──────────────────────────────────────────────┐
│  4 running                      ⏻ Stop all   │  ← hidden entirely when 0 running
│  ▁▂▅▇▆▃▂▁▂▄▇█▆▄▂▁▁▂▃▅▆▄▂▁  ← stacked, per job │
│  CPU 34%          RAM 1.2 GB       ↑ 2h 14m  │
├──────────────────────────────────────────────┤
│ ● web            :3000    running   2h 14m ▸ │
│   ▁▂▅▇▆▃▂▁                          ⏹ ↻      │  ← quick actions on hover
│ ● api            :8080    running     41m  ▸ │
│ ▲ worker                  running     41m  ▸ │  ← amber, warning
│ ○ docs                    stopped      —   ▸ │
├──────────────────────────────────────────────┤
│  ＋              ⚙︎                        ⏻  │
└──────────────────────────────────────────────┘
```

Row anatomy: status indicator, name, port badge (when detected), state, duration, chevron. Sparkline appears on the row only for the hovered or selected job — eight sparklines at once is noise. Quick stop/restart on hover. Full row is the tap target for detail.

Duration ticks via a `TimelineView(.periodic(from:by:1))` that only exists while the panel is open. Compute from a monotonic clock (`ContinuousClock` / `mach_absolute_time`), not `Date`, so a clock change or sleep doesn't produce a negative uptime.

**Detail view** pushes within the panel via `NavigationStack` — a second popover or a separate window for this would be heavy for something you open twenty times a day.

Contents: name, state, health reason (if any), duration, PID, port, working directory (click to reveal in Finder), command (monospace, click to copy), resolved shell mode, resolved executable path and version, and resolved `PATH`. CPU and RAM charts over the session. A 6-line output tail, monospace, ANSI-rendered, that live-updates. Then:

- **Primary:** View output · Stop / Start · Restart
- **Secondary:** Edit · Reveal in Finder · Copy command · Open `http://localhost:<port>`
- **Toggles:** Open terminal on start · Start when RunStuff launches · Restart if it crashes
- **Destructive:** Delete, behind a confirmation, disabled while running

**Empty state:** a quiet illustration, "Nothing running yet.", one line explaining what the app does, and an "Add stuff" button. Per the interface's voice — an empty screen is an invitation, not an apology.

### Add / edit

**This must be a real window, not a sheet on the panel.** `NSOpenPanel` for the folder picker will dismiss a menu bar panel out from under you, and you lose the half-filled form. So: opening the editor closes the panel and shows a standard window (`NSApp.activate` first, since the app is an accessory with no Dock icon).

Fields: Name · Folder (picker, drag-and-drop target, with recents) · Command (monospace, multiline) · Shell mode · Env vars (key/value table) · Open terminal on start · Start on launch · Restart on crash · Signal rules.

When the chosen folder contains `.nvmrc` or `.envrc`, show a warning at creation time if the selected shell mode is unlikely to load it. This is guidance, not an automatic mode change.

Two things that make this feel finished: a **Test run** button that spawns the job into a scratch terminal window without saving, so people can debug PATH issues in the editor; and folder-drop auto-filling the name from the directory name and suggesting the command from `package.json` scripts / `Makefile` targets / `docker-compose.yml` if one is present.

### Terminal window

SwiftTerm's `TerminalView`, **not** `LocalProcessTerminalView` — the latter spawns and owns its own process, which is precisely what you don't want. Wire it up manually:

- Feed it with `terminal.feed(byteArray:)` from the ring buffer (replay on open) and then from the live subscription.
- Implement `TerminalViewDelegate.send(source:data:)` to write back to the master fd, giving you real interactivity: Ctrl-C, `y/n` prompts, watch-mode keypresses.
- `TerminalViewDelegate.sizeChanged` → `TIOCSWINSZ` + `SIGWINCH`.
- Per-window: font family/size, theme, frame autosave keyed by job id. Global defaults in settings.
- On job exit, keep the window open showing the final output and a footer bar: "Exited with code 1 · Restart".

---

## 5. Lifecycle and edge cases

**Quit with jobs running.** A modal alert listing the running jobs by name, with "Stop all and quit" / "Cancel". Then SIGTERM to each pgid, wait up to a configurable grace period (default 5s), SIGKILL anything left, show a brief progress state if it takes more than ~500ms.

**Crash or force-quit.** Jobs are orphaned and keep running — that's a real hazard, since port 3000 stays occupied by an invisible process. `runtime.json` records pid, pgid, sid, start time and command hash at spawn and clears on clean exit. Persist this record as part of spawn, before presenting the job as running. On launch, reconcile every record: verify the pid still exists _and_ matches the recorded start time (guards against pid reuse), clear dead records, and retain live sessions for the recovery sheet: "3 processes from a previous session are still running" with Adopt / Stop / Ignore per job.

Adoption caveat to state plainly in that UI: the PTY is gone, so adopted jobs get lifecycle control and metrics but **no output history and no terminal view**. Don't pretend otherwise.

**Restart-on-crash.** Exponential backoff (1s, 2s, 4s), `maxRestarts` within a 60s window, then stop and raise an error with "restart loop" as the reason. Silent infinite restarts are worse than a dead server.

**Sleep/wake.** Register for `NSWorkspace.willSleepNotification` / `didWakeNotification`. Jobs survive; pause the metrics sampler; on wake, insert a gap marker in the chart rather than drawing a misleading flat line, and re-probe ports.

**Launch at login.** `SMAppService.mainApp.register()`, exposed as a settings toggle, off by default.

**TCC.** Unsandboxed doesn't mean unrestricted: if a working directory sits under `~/Documents`, `~/Desktop` or `~/Downloads`, the first access triggers a consent prompt attributed to RunStuff. Ship `NSDocumentsFolderUsageDescription`, `NSDesktopFolderUsageDescription` and `NSDownloadsFolderUsageDescription` strings that explain it in terms of running the user's project, and handle denial with a clear job error rather than a mystery failure.

---

## 6. Event and notification matrix

Auth is requested lazily — on the first event that actually wants a notification, not at launch. Use `UNNotificationCategory` actions so notifications are useful without opening the app. Notifications only deliver reliably from a signed, notarized bundle with a stable bundle ID; unsigned debug builds will silently swallow them, which is a confusing half-hour if you don't expect it.

| Event                                            | Menu bar           | In-app                    | Notification                                                      | Sound                 |
| ------------------------------------------------ | ------------------ | ------------------------- | ----------------------------------------------------------------- | --------------------- |
| Job added / edited                               | —                  | List updates              | —                                                                 | —                     |
| Starting                                         | Count +1           | Row spinner               | —                                                                 | —                     |
| Started                                          | Count, active icon | Row → green               | —                                                                 | —                     |
| Ready detected (port open, or `readyRule` match) | —                  | Port badge appears        | `.passive`, opt-in per job. Actions: Open in browser, View output | —                     |
| Exited 0                                         | Count −1           | Row → stopped             | `.active` "web finished". Action: Restart                         | —                     |
| Exited non-zero                                  | Error state        | Row → red, reason shown   | `.active` "api exited with code 1". Actions: View output, Restart | Subtle, on by default |
| Killed by signal (not ours)                      | Error state        | Row → red                 | `.active` "worker crashed (SIGSEGV)"                              | Subtle                |
| Failed to start                                  | Error state        | Row → red, with hint      | `.active`, includes the PATH hint for 127                         | Subtle                |
| Crash + auto-restart                             | Warning            | Restart count on row      | `.passive`, rate-limited                                          | —                     |
| Restart loop exhausted                           | Error state        | Row → red                 | `.active` "gave up after 3 restarts"                              | Subtle                |
| `SignalRule` matched, `.error`                   | Error state        | Row → red, reason         | `.active` if `notify`, max 1/60s per rule                         | Subtle                |
| `SignalRule` matched, `.warning`                 | Warning            | Row → amber, reason       | Only if `notify`, rate-limited                                    | —                     |
| Waiting for input (see below)                    | Warning            | Row → amber "waiting"     | `.active`. Actions: View output                                   | Subtle                |
| Sustained high CPU (>80% for 2 min)              | Warning            | Row badge                 | Opt-in, once per session                                          | —                     |
| Output buffer wrapped                            | —                  | Subtle marker in terminal | —                                                                 | —                     |
| Orphans found at launch                          | Error state        | Recovery sheet            | —                                                                 | —                     |
| Quit with jobs running                           | —                  | Modal confirmation        | —                                                                 | —                     |

**Interruption levels.** `.timeSensitive` is tempting for errors but needs a provisioning entitlement and breaks through Focus modes — inappropriate for "your dev server restarted". Ship `.active` for errors and `.passive` for informational. Let Focus suppress them; that's the user's call, and respecting it is what keeps the app installed.

**Sound.** One custom sound in the bundle, short and low, error events only, with a settings toggle and a "None" option. Never for warnings. Never more than one per 10 seconds regardless of how many jobs fail at once — a `docker compose` stack collapsing shouldn't sound like a slot machine.

**"Waiting for input" detection.** Genuinely hard, and prone to false positives. Heuristic: the buffer's last chunk ended _without_ a trailing newline, the trailing text matches a prompt-ish shape (ends in `? `, `: `, `[y/N] `, `> `), and no further output has arrived for 4 seconds. Ship it off by default, per-job opt-in, and make the setting's help text honest about it being a guess. If it proves flaky, cut it — a wrong "waiting for input" notification is worse than none.

---

## 7. Delivery phases

**Phase 0 — spike (half a day to a day).** A command-line Swift package, no UI. `posix_spawn` + PTY + `SETSID`, drain to stdout, `TIOCSWINSZ`, kill the group, reap and decode exit status. Validate against: an nvm-managed `npm run dev`, a mise-managed project, a colour-heavy build, Ctrl-C passthrough, and a process that spawns children. **Do not start the app until this works.** Everything downstream assumes it.

**Phase 1 — core (the bulk of the work).** First port `JobRuntime` unchanged and run the phase 0 fixture suite against it; no feature work begins until that entry gate is green. Then build the Supervisor actor, data model, `ConfigStore`, runtime registry with session IDs and launch reconciliation, ring buffer with ANSI stripping, exit-code-based state and health, metrics sampler, status item with the four icon states, panel with job list and detail, add/edit window with folder picker, SwiftTerm window, basic notifications (exit 0, exit non-zero, failed to start), stop-all and quit confirmation. Keep shell mode per job. Ship resolved executable path plus version in detail unconditionally, and warn about `.nvmrc`/`.envrc` at job creation. Move to phase 2 when the build, tests, phase-0 and phase-1 fixture assertions, and a short end-to-end app check are green. Continue using the app during later development and fix problems as they surface; prolonged dogfooding does not block implementation.

**Phase 2 — the rich experience.** Summary header with the stacked aggregate chart and band-coloured status dots, per-row sparklines, port detection and the `:3000` badge, `SignalRule` editor with suggested rules, ready-detection, notification actions, empty state, orphan recovery, restart-on-crash with backoff, keyboard navigation and VoiceOver labels, settings window.

**Phase 3 — external attach and distribution polish.** `AttachServer` on a unix socket, the `runstuff` CLI with `attach`/`list`/`start`/`stop`, a user-editable terminal launch template (Ghostty via `ghostty -e`, falling back to `open -na`; presets for iTerm2, WezTerm, Terminal), CLI installation into `/usr/local/bin` via a symlink with an explanatory prompt. Sparkle for updates. Keychain-backed env values referenced as `${keychain:name}`.

Deliberately gated behind phase 2 per your instinct: once the in-app terminal window is good, external attach may turn out to be a nice-to-have rather than the point. Find out before building it.

**Phase 4 — if you still want more.** Job groups ("start my whole stack") with dependency ordering and readiness gating. HTTP health-check probes. URL scheme `runstuff://start/<name>`. Shortcuts/App Intents actions. Import from `docker-compose.yml` or `Procfile`.

---

## 8. Risk register

| Risk                                                   | Mitigation                                                                                                                    |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| PTY not drained → child blocks, looks like a hang      | Drain from spawn to exit, unconditionally. Integration test with a high-throughput fixture.                                   |
| Raw child has no controlling terminal                  | Spawn through the `TIOCSCTTY` helper; prove tty behaviour with raw binaries, not shell wrappers.                              |
| Killing pid not pgid → orphaned server holds the port  | `SETSID` + `kill(-pid, …)`. Test with `npm` wrapping `node`.                                                                  |
| GUI PATH breaks nvm/mise users                         | Login shell default, interactive-login mode, resolved PATH visible in detail, specific error copy for exit 127.               |
| `NSOpenPanel` dismisses the panel                      | Editor is a real window, never a sheet on the panel.                                                                          |
| `MenuBarExtra` can't be closed programmatically        | `NSStatusItem` + `NSPanel` behind a protocol.                                                                                 |
| Notifications silent in dev builds                     | Sign even local builds; verify on a notarized build before concluding anything's broken.                                      |
| ANSI escapes split across reads                        | Carry partial-escape state between reads in the stripper.                                                                     |
| Swift 6 strict concurrency vs. raw fds and C callbacks | Confine all fd state to the `JobRuntime` actor; wrap C interop in `@unchecked Sendable` boxes at a single, reviewed boundary. |
| App Nap throttles background sampling                  | Accept it. Coarser cadence when hidden, interpolate. Don't take activity assertions.                                          |
| Pid reuse when adopting orphans                        | Match recorded start time, not just pid existence.                                                                            |
| SwiftTerm dependency risk                              | Pin the version; the surface you use (`TerminalView`, `feed`, delegate) is small enough to replace if it stalls.              |
| Charts redrawing at 2s × 8 jobs in a popover           | Downsample to fixed buckets before handing data to Swift Charts; only render sparklines for visible rows.                     |

---

## 9. Testing

**Unit:** ring buffer eviction and cursor semantics; ANSI stripping against a corpus of real dev-server output including split-escape cases; `SignalRule` matching and rate limiting; state machine transitions; duration formatting across sleep/wake; exit status decoding.

**Fixture scripts** (`fixtures/`, POSIX sh, base system + Command Line Tools only) are the acceptance suite for the process layer and are written in phase 0. Each assertion inside a fixture carries the phase that owns it; the harness reports later-phase assertions as SKIPPED with their phase until implemented, so the skip list is the inventory of owed work. Fixtures needing a version manager detect it at run time and SKIP with the reason when absent. The table in `CLAUDE.md` is the authoritative list: clean exit; exit 1; command not found in each shell mode; crash after 5s; crash loop; 300 MB unpaced output with and without a consumer; heavy ANSI colour including an escape split across writes; a progress bar that reports its size after `TIOCSWINSZ`; a `[y/N]` prompt; shell and raw-binary controlling-terminal and Ctrl-C checks; raw-binary SIGWINCH under a divergent foreground group; sibling-job EOF isolation; a port listener; three descendants including a grandchild; a compound command under an interactive login shell (session-kill); a SIGTERM-ignoring process; an nvm project; a mise project. An `EADDRINUSE` fixture for `SignalRule` matching joins in phase 1.

Ten assertions remain deliberately deferred. Six verify process-layer behaviour against phase 1 code: ANSI-stripped matching, metrics summed across a job group, restart backoff, `maxRestarts`, ring eviction, and listening-port detection. Four verify presentation: shell-mode hint copy in two paths, SwiftTerm colour rendering, and SwiftTerm carriage-return redraw. Deferred does not mean optional; each converts to a required assertion when its owning phase starts.

**Manual matrix:** light/dark mode, menu bar over a light and dark wallpaper, reduce transparency, reduce motion, increased contrast, VoiceOver traversal of the panel, external display with different scaling, 20 concurrent jobs, laptop sleep for an hour with jobs running.

---

## 10. Signing and distribution

- Bundle id `com.<you>.RunStuff`. `LSUIElement = true` (no Dock icon).
- Hardened runtime, no App Sandbox. No unusual entitlements needed — spawning child processes is fine under hardened runtime. Add the three folder usage description strings from §5.
- Developer ID Application certificate → `codesign --deep --options runtime` → `notarytool submit --wait` → `stapler staple`.
- Package as a DMG (`create-dmg`) with an Applications symlink. Publish to GitHub Releases.
- Automate in CI so releasing isn't a twenty-step ritual you dread.
- Include first-run instructions for friends, plus a short "what to do when a job won't start" section covering the shell-mode toggle. It'll be the only support question you get.

---

## 11. Open questions

1. **Do you want job groups in v1?** If your actual daily workflow is "start web + api + worker together", that's phase 4 in this plan but arguably your real primary use case, and it would change the list's information hierarchy. Worth deciding now rather than retrofitting.
2. **Should `config.json` be a file you'd commit to a dotfiles repo?** If yes, working directories need to be portable (`~`-relative or project-relative) and secrets must go to Keychain from the start rather than in phase 3.
3. **Global hotkey to toggle the panel?** Cheap to add, and for something you open this often it may beat reaching for the menu bar. Needs a shortcut recorder and a `CGEvent` tap or `NSEvent` global monitor.
4. **How much output history do you actually want?** 10k lines is a guess. If you regularly scroll back through a whole day of a watch-mode compiler, always-on disk logging should be the default rather than opt-in.
