#!/bin/bash
# Shows every network connection of CallRecorder and the tools it starts. Run it while recording.
# Expected: nothing except 127.0.0.1 / localhost. Anything else is printed and the script exits with 1.
bad=0
for name in CallRecorder whisper-server whisper-cli ollama; do
  out=$(lsof -nP -i -a -c "$name" 2>/dev/null | tail -n +2)
  [ -z "$out" ] && continue
  echo "== $name"
  echo "$out"
  if echo "$out" | grep -vE '127\.0\.0\.1|\[::1\]|localhost|\*:\*' | grep -q .; then bad=1; fi
done
echo
if [ $bad -eq 0 ]; then echo "OK: no connection leaves this Mac."; else echo "ATTENTION: a connection to another machine exists (see above)."; fi
exit $bad
