#!/bin/sh
# Exits 1 after 200 ms. The harness spawns it 20 times in a row.
# Phase 0 asserts: each exit detected and reaped; no zombies; fd census unchanged.
# Phase 1 asserts: backoff and maxRestarts.
echo "crashing"
sleep 0.2
exit 1
