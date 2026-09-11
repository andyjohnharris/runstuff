#!/bin/sh
# Writes 1 MB and exits, with no prompt and no wait. The harness attaches NO
# subscriber: this proves the runtime drains the master from spawn, not only
# when a view is watching. If the drain were subscriber-gated, the kernel PTY
# buffer would fill and the child would block on write() and never exit.
# Phase 0 asserts: exits 0 with nothing attached; the full 1 MB was drained.
dd if=/dev/zero bs=1m count=1 2>/dev/null | tr '\0' 'x'
echo
echo "WRITES-DONE"
