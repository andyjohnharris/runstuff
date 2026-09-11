#!/bin/sh
# The smallest short-lived job: print the pid and exit 0 at once. The harness
# spawns hundreds of these concurrently to stress exit detection and reaping
# (finding: NOTE_EXIT fires before the child is reapable).
echo "PID $$"
exit 0
