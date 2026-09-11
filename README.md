# RunStuff

RunStuff is a macOS menu bar app for starting, supervising, and attaching to local development processes.

## Run a development build

1. Open `RunStuff.xcodeproj` and run the `RunStuff` scheme.
2. Select the menu bar icon.
3. Add Stuff with its command and project folder.

RunStuff uses a login shell by default so Homebrew, mise, and asdf paths work from a GUI app. Select **Interactive login** for tools such as nvm that are loaded from `.zshrc`. Select **Direct** only when the executable is already available in the Stuff's configured `PATH`.

## Command-line tool

Select **Install Command-Line Tool…** in Settings to create `/usr/local/bin/runstuff`. RunStuff prompts for administrator access when `/usr/local/bin` is not writable.

```sh
runstuff list
runstuff start "Web server"
runstuff attach "Web server"
runstuff stop "Web server"
```

`attach` forwards input, output, terminal resize events, and Ctrl-C to the Stuff's PTY.

## Keychain environment values

Store a secret as a generic password under the `dev.runstuff.environment` service:

```sh
security add-generic-password -U -s dev.runstuff.environment -a github-token -w
```

Set the environment value in RunStuff to `${keychain:github-token}`. RunStuff reads the value only when it starts the Stuff.

## Updates

RunStuff uses Sparkle 2.9.6 and embeds its EdDSA public key. Enter the HTTPS appcast URL in Settings after an update feed is published.

## If Stuff does not start

Open its detail view and check **Executable** and **PATH**. An exit code of 127 usually means the selected shell mode did not load the tool. Try **Interactive login** for nvm or other setup from `.zshrc`. Try **Login** for mise, asdf, and Homebrew. Use **Direct** only with an executable available in the configured `PATH`.

If a `${keychain:name}` value fails, confirm that the generic-password item's service is `dev.runstuff.environment` and its account is `name`.
