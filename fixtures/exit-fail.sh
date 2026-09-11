#!/bin/sh
# Prints one line and exits 1.
# Phase 0 asserts: exited(1), not signalled.
echo "about to fail"
exit 1
