#!/bin/zsh
set -eu
ROOT="${0:A:h}"
if ! /usr/bin/curl -fsS http://127.0.0.1:8765/api/comments >/dev/null 2>&1; then
  /usr/bin/python3 "$ROOT/IdleIcon/Tools/ReviewServer.py" >> "/tmp/xianzhe-review-server.log" 2>&1 &
  sleep 1
fi
open "http://127.0.0.1:8765/逐项批注.html"
