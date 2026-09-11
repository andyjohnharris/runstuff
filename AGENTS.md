# RunStuff

RunStuff is a macOS menu bar app for supervising local development servers and other long-running processes. It uses Swift 6 and SwiftUI, targets macOS 14 or later, and is distributed outside the Mac App Store with the hardened runtime enabled and App Sandbox disabled.

## Repository map

- `RunStuff/`: menu bar app, panel, editor, terminal windows, settings, notifications, and update UI.
- `RunStuffCore/`: process supervision, PTY management, persistence, metrics, output buffering, and the attach protocol. This module must not import SwiftUI or AppKit.
- `RunStuffCLI/`: `runstuff` command-line client for list, start, stop, and attach.
- `RunStuffTTYHelper/`: C helper that acquires the controlling terminal before executing a job.
- `RunStuffCoreTests/`: SwiftPM and Xcode unit and integration tests.
- `spike/Sources/runstuff-spike/` and `fixtures/`: process-layer acceptance harness and fixtures. Despite the historical name, these remain active regression coverage.

The UI calls a configured process “Stuff”. The code calls it a `Job`.

## Build and test

Use Xcode’s **RunStuff** scheme for local development. Keep Debug builds restricted to the active architecture; otherwise Xcode can build SwiftTerm for arm64 and then try to load it from an x86_64 app compile.

```sh
# Format Swift sources
xcrun swift-format format --in-place --recursive \
  RunStuff RunStuffCLI RunStuffCore RunStuffCoreTests spike/Sources/runstuff-spike

# Unit and integration tests
swift test
xcodebuild -project RunStuff.xcodeproj -scheme RunStuff \
  -configuration Debug -destination 'platform=macOS,name=My Mac' test

# Process acceptance suite
swift run runstuff-spike --all "$PWD/fixtures"
```

Builds treat warnings as errors. Run the narrowest relevant test while iterating, then run both test suites before committing changes to process management or shared core code. Run the acceptance suite for PTY, spawn, signal, resize, drain, reaping, shell, or process-tree changes.

For UI changes, run the app and inspect the affected state. RunStuff is an `LSUIElement` app: launch must show only the menu bar item. Add/edit, terminal, and settings windows open on demand, and closing them must not quit the app.

## Process invariants

These rules prevent subtle hangs, leaked servers, and corrupted terminal output:

1. Drain each PTY continuously from spawn through EOF, even with no subscriber. An undrained PTY eventually blocks the child on write.
2. Stop the complete job, not only its leader PID. Signal the process group first, then verify and sweep the session because interactive shell job control can create additional process groups. Escalate remaining verified members from SIGTERM to SIGKILL.
3. Validate process start time and session identity before acting on persisted orphan records. A reused PID, PGID, or SID must never target an unrelated process.
4. Spawn through the bundled TTY helper. `posix_spawn` with `POSIX_SPAWN_SETSID` does not acquire a controlling terminal by itself.
5. Keep PTY descriptors close-on-exec and keep the `openpty` through `posix_spawn` allocation path serialized.
6. Store raw terminal bytes. Use only an ANSI-stripped projection for matching and display the raw bytes through SwiftTerm.
7. Keep `RunState` and `Health` separate. A running job can still have warning or error health.
8. Detect failures from spawn errors, exit status, signals, and user-authored `SignalRule`s. Do not add broad built-in text heuristics such as matching the word “error”.
9. A GUI app inherits launchd’s environment. Keep login shell as the default; interactive login supports tools such as nvm that initialize in `.zshrc`; direct mode executes without shell syntax.

## Darwin and concurrency

Treat `posix_spawn`, `openpty`, `ioctl`, `waitpid`, signals, sysctl, and libproc calls as high-risk code. Verify signatures and semantics against the installed macOS SDK headers or Apple documentation before changing them, then prove behavior with a fixture. Shell-based probes are not sufficient for claims about raw executable or controlling-terminal behavior.

Swift strict concurrency is enabled. Keep mutable descriptor ownership inside `JobRuntime` or the reviewed socket state boundary. Do not add `@unchecked Sendable` merely to silence a compiler error. Every descriptor, process source, read source, task, and continuation needs an explicit lifetime and cleanup path.

## Persistence and security

- Job configuration: `~/Library/Application Support/RunStuff/config.json`.
- Live process recovery records: `runtime.json` in the same directory.
- Machine-specific UI preferences: `UserDefaults`.
- `${keychain:name}` values: generic passwords under service `dev.runstuff.environment`.
- Local attach socket: owner-only Unix socket under Application Support.
- Sparkle’s private signing key belongs in the login Keychain and must never be committed. Only the public key belongs in `RunStuff/Info.plist`.

Do not add dependencies without user approval. Preserve the unsandboxed hardened-runtime model unless the user explicitly chooses a different distribution approach.

## Code style

- Prefer the smallest change that follows existing ownership boundaries.
- Avoid force unwraps outside tests.
- Surface operation and persistence failures in the existing UI banner rather than using `try?` for user actions.
- Keep user-facing text concrete and use “Stuff” consistently.
- Add tests that distinguish the intended behavior from plausible incorrect implementations.
