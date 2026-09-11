#!/bin/sh
# Ignores SIGTERM and loops. The sleep children inherit SIG_IGN across exec.
# Phase 0 asserts: alive through the grace period; SIGKILL escalation fires;
# the session is swept clean.
trap '' TERM
echo "READY"
while :; do
  sleep 1
done
