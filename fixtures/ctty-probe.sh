#!/bin/sh
# Reports whether this process has a controlling terminal, which device it
# is, and the tty's foreground process group. /dev/tty opens O_RDWR only for
# a process with a controlling terminal. The device number must be read
# through an fd opened on /dev/tty: stat on the /dev/tty node itself returns
# the alias device (major 2), not the terminal it redirects to.
# Phase 0 asserts: CTTY=yes; TTY_RDEV == FD0_RDEV; TPGID == PGID; and the
# harness confirms e_tdev / e_tpgid via sysctl while the script sleeps.
if ( exec 3<>/dev/tty ) 2>/dev/null; then
  echo "CTTY=yes"
  echo "TTY_RDEV=$( (exec 3<>/dev/tty; stat -f %r /dev/fd/3) 2>/dev/null )"
else
  echo "CTTY=no"
  echo "TTY_RDEV=-"
fi
echo "FD0_RDEV=$(stat -f %r /dev/fd/0)"
echo "TPGID=$(ps -o tpgid= -p $$ | tr -d ' ')"
echo "PGID=$(ps -o pgid= -p $$ | tr -d ' ')"
echo "PID=$$"
echo "PROBE-DONE"
sleep 3
