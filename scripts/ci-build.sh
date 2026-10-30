#!/usr/bin/env bash
# Keep compiler output visible in check annotations when a build fails.
set -euo pipefail
build_log="$(mktemp)"
trap 'rm -f "$build_log"' EXIT

if "$@" 2>&1 | tee "$build_log"; then
  exit 0
fi

python3 - "$build_log" <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
message = "\n".join(lines[-100:])[-12000:]
message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
print(f"::error title=Build failure details::{message}")
PY
exit 1
