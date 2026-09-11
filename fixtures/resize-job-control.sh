#!/bin/sh
# Reports the terminal size, then on each SIGWINCH reports the new size. The
# harness runs this as part of a compound command under an interactive login
# shell, so job control may place it in a foreground process group other than
# the job leader's. The kernel delivers SIGWINCH to the tty's foreground
# group, so this program must see the resize regardless of which group that
# is, and without the supervisor sending an explicit (wrong-group) signal.
# Phase 0 asserts: a mid-flight resize reaches the foreground command.
report() {
  echo "SIZE $(stty size)"
}
trap 'report' WINCH

echo "PGID $(ps -o pgid= -p $$ | tr -d ' ')"
report
echo "READY"
i=0
while [ "$i" -lt 200 ]; do
  sleep 0.1
  i=$((i + 1))
done
echo "RJC-DONE"
