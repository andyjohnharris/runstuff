#!/bin/sh
# Emits SGR colour sequences, including one CSI split across two writes.
# Phase 0 asserts: raw bytes arrive byte-exact; TERM reaches the child.
# Phase 1 asserts: SwiftTerm renders colour; stripped copy matches plain text.
printf '\033[31mred\033[0m \033[1;32mbold green\033[0m\n'
printf '\033[38;5;208m256-colour orange\033[0m\n'
printf '\033[38;2;255;105;180mtruecolor pink\033[0m\n'
printf '\033['
sleep 0.1
printf '31msplit red\033[0m\n'
printf 'TERM=%s\n' "$TERM"
echo "COLOURS-DONE"
