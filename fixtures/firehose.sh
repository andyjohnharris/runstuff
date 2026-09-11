#!/bin/sh
# 30 bursts of 10 MB of 'x' in 1000-byte lines, one burst per second, each
# preceded by a TICK line carrying the burst number and the child's clock.
# Total payload: 30 * 10 * 1048576 = 314572800 'x' bytes.
# Phase 0 asserts: every byte present although nothing is attached for the
# first 5 s; TICK lines arrive on the child's cadence (child never blocked).
# Phase 1 asserts: ring eviction.
i=1
while [ "$i" -le 30 ]; do
  echo "TICK $i $(date +%s)"
  dd if=/dev/zero bs=1m count=10 2>/dev/null | tr '\0' 'x' | fold -w 1000
  echo
  i=$((i + 1))
  sleep 1
done
echo "FIREHOSE-DONE"
