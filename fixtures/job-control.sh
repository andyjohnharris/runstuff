#!/bin/sh
# Run by the harness under an interactive login shell as part of a compound
# command ("fixtures/job-control.sh && true"), so the shell's job control
# places this script and its children in a process group other than the
# job's. Phase 0 asserts: one stop() still removes every descendant, found
# by session id rather than process group.
sleep 1000 &
echo "CHILD $!"
( sleep 1000 & echo "CHILD $!"; wait ) &
echo "CHILD $!"
echo "SELF $$"
echo "PGID $(ps -o pgid= -p $$ | tr -d ' ')"
sleep 0.3
echo "CHILDREN-READY"
wait
