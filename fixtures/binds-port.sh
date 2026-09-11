#!/bin/sh
# Listens on the loopback port given as $1 and stays up. -k keeps nc
# listening after each accepted connection.
# Phase 0 asserts: connect() succeeds while running; refused after stop().
# Phase 2 asserts: port detected via proc_pidfdinfo.
PORT="${1:?usage: binds-port.sh <port>}"
echo "PORT $PORT"
exec /usr/bin/nc -k -l 127.0.0.1 "$PORT"
