#!/bin/sh
# Execs a command that does not exist. Under a shell the exit code is 127.
# The harness also runs the bare command name in direct mode, where spawn
# itself fails with ENOENT (or the tty helper exits 127).
exec definitely-not-a-command-4f2a
