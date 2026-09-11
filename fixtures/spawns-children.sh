#!/bin/sh
# Starts two children and one grandchild, prints their pids, then waits.
# Phase 0 asserts: all share the job pgid; one group kill removes them all.
# Phase 1 asserts: metrics sum across the group.
sleep 1000 &
echo "CHILD $!"
sleep 1000 &
echo "CHILD $!"
( sleep 1000 & echo "CHILD $!"; wait ) &
echo "CHILD $!"
echo "PGID $(ps -o pgid= -p $$ | tr -d ' ')"
sleep 0.3
echo "CHILDREN-READY"
wait
