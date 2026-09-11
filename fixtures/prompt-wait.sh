#!/bin/sh
# Prints a prompt and waits for a line of input.
# Phase 0 asserts: prompt bytes observed; input written to the master reaches
# the child; echo and response captured; exited(0).
printf 'Continue? [y/N] '
read ans
echo "GOT:$ans"
exit 0
