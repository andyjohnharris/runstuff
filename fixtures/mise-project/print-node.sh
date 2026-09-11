#!/bin/sh
# Prints which node the shell resolved and the PATH it used.
echo "PATH=$PATH"
exec node -e "console.log('NODE', process.version, process.execPath)"
