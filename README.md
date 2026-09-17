# RunStuff

RunStuff is a macOS menu bar app for starting, supervising, and attaching to local development processes.

The [design system](DESIGN.md) defines the app's colours, typography, reusable components and motion rules.

## Run a development build

1. Open `RunStuff.xcodeproj` and run the `RunStuff` scheme.
2. Select the menu bar icon.
3. Add Stuff with its command and project folder.

RunStuff uses a login shell by default so Homebrew, mise, and asdf paths work from a GUI app. Select **Interactive login** for tools such as nvm that are loaded from `.zshrc`. Select **Direct** only when the executable is already available in the Stuff's configured `PATH`.

## Tests

Run unit and integration tests with `swift test` or the Xcode **RunStuff** scheme.
The process acceptance harness lives in `RunStuffAcceptance/`, with scenarios backed by `fixtures/`:

```sh
swift run runstuff-acceptance --all "$PWD/fixtures"
swift run runstuff-acceptance fixtures/exit-clean.sh
swift run runstuff-acceptance --manual fixtures/colours.sh
```

Xcode builds the same harness with the **RunStuffAcceptance** scheme.

## Command-line tool

Select **Install Command-Line Tool…** in Settings to create `/usr/local/bin/runstuff`. RunStuff prompts for administrator access when `/usr/local/bin` is not writable.

```sh
runstuff list
runstuff start "Web server"
runstuff attach "Web server"
runstuff stop "Web server"
```

`attach` forwards input, output, terminal resize events, and Ctrl-C to the Stuff's PTY.

## Run history

Select **History** in the main footer to see completed runs for all Stuff. History in a Stuff's details opens the same window filtered to that Stuff. Finished details return to configuration and **Start**; the run's outcome, evidence, measurements and read-only output are in History.

Each run retains its original name, command, folder and timing. History survives renaming, deletion and app restarts. Deleted Stuff is labelled in the list. Manual and automatic restarts produce separate entries.

Run records live in `~/Library/Application Support/RunStuff/history/`. Each keeps at most the newest **256 KiB of raw terminal output**, with a notice when earlier output was omitted. Measurements retain the supervisor's most recent 10,000 samples. Records have no automatic expiry. Environment values are not saved, but commands and process output can contain secrets; history files are owner-only.

History starts collecting with this version; earlier runs cannot be reconstructed. Recovered processes have no earlier output or known exit status, and are labelled accordingly. An unsaved record remains available for the current session if a disk write fails; the app reports the error in its banner.

RunStuff stays in the Dock and Cmd-Tab while a terminal or History window is open, including when minimised. Closing the last of these windows returns it to menu-bar-only mode.

## Keychain environment values

Store a secret as a generic password under the `dev.runstuff.environment` service:

```sh
security add-generic-password -U -s dev.runstuff.environment -a github-token -w
```

Set the environment value in RunStuff to `${keychain:github-token}`. RunStuff reads the value only when it starts the Stuff.

## Updates

RunStuff uses Sparkle 2.9.6 and embeds its EdDSA public key. Enter the HTTPS appcast URL in Settings after an update feed is published.

## If Stuff does not start

Open **History** from its details and check the latest run's outcome and output. An exit code of 127 usually means the selected shell mode did not load the tool. Try **Interactive login** for nvm or other setup from `.zshrc`. Try **Login** for mise, asdf, and Homebrew. Use **Direct** only with an executable available in the configured `PATH`.

If a `${keychain:name}` value fails, confirm that the generic-password item's service is `dev.runstuff.environment` and its account is `name`.

## Failure notifications and port conflicts

Settings shows notification permission and links to macOS notification settings. RunStuff presents alerts while active and shows permission or delivery errors in its banner. Focus and macOS settings can still silence alerts. User-requested stops do not send exit alerts.

Unexpected failures retain a reason on the Stuff card until the next start and in the completed run's History entry. For recognised TCP bind conflicts, **Check Port Owner** runs a read-only `lsof` lookup. It shows current listeners, which may differ from the owner at failure time. Stop the conflicting service from its app or terminal, then start the Stuff again. RunStuff does not kill other services automatically.

The owner-check terminal also shows **Copy Stop Command**. Enter a listed PID to copy `kill -TERM <PID>`, or press Return to finish without copying. RunStuff never executes that command. Check the owner again if you run it later: PIDs can be reused.

Some wrapper scripts return exit code 0 even when a child fails. When the output contains a recognised TCP bind conflict, the completion notification reports the port conflict alongside the command's exit code and offers **Check Port Owner** and **View Output**. This is evidence from the output, not proof that the port is still occupied; it does not change health or trigger automatic restarts.

The popover retains a **Check output** indicator and the reported conflict until the next start. History retains the matching evidence, actual exit status and **Check Port Owner** action. User-requested stops do not create this reported-conflict indicator or send exit notifications.

To also mark these runs as failures, open **Edit → Signal Rules → Suggested Rules** and add **bind: address already in use** (Go/Smokescreen) or **EADDRINUSE** (Node or Ruby/Puma). Keep **Notify** enabled. These explicit rules detect the failure even if the wrapper exits with code 0.

Failure evidence in History persists across app launches. See [the notification plan](NOTIFICATIONS-PLAN.md) for the original notification work and verification.
