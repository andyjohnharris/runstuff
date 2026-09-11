#!/bin/sh
# Runs for 5 seconds, then dies by SIGSEGV.
# Phase 0 asserts: signalled(SIGSEGV) after >= 5 s, distinct from exited(139).
echo "running for 5s then SIGSEGV"
sleep 5
kill -SEGV $$
