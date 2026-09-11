#!/bin/sh
# Prints 200 numbered lines and a sentinel, then exits 0.
# Phase 0 asserts: exited(0); every byte captured in order; EOF observed once.
i=1
while [ "$i" -le 200 ]; do
  echo "line $i"
  i=$((i + 1))
done
echo "DONE"
exit 0
