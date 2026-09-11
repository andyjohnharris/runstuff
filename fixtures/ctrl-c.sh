#!/bin/sh
# Second-order check behind ctty-probe.sh: only meaningful once the child has
# the PTY as its controlling terminal. Waits for input forever; the harness
# writes 0x03 to the master and expects death by SIGINT.
echo "READY"
while :; do
  read line
done
