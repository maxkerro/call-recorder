#!/bin/bash
# Double-click in Finder: pulls the latest code, rebuilds, reinstalls and reopens CallRecorder.
cd "$(dirname "$0")" || exit 1
./update.sh
status=$?
echo
if [ $status -eq 0 ]; then echo "Done: CallRecorder was rebuilt and reopened."; else echo "FAILED (exit $status). Copy the messages above and send them to Claude."; fi
echo "Press any key to close."
read -r -n 1
