#!/bin/bash
#
# Aggregating test runner for the statusline repo.
#   - Bash tests:  bats tests/bash        (requires bats-core)
#   - JS tests:    node --test tests/js/*.test.js   (Node.js built-in test runner)
# Exits non-zero if either suite fails. No package.json, no npm dependencies.
#
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Checking prerequisites"
if ! command -v node >/dev/null 2>&1; then
  echo "Error: 'node' not found. Install Node.js to run the JS tests." >&2
  exit 1
fi

if ! command -v bats >/dev/null 2>&1; then
  cat >&2 <<'MSG'
Error: 'bats' (bats-core) not found — required for the bash tests.
Install it with one of:
  sudo apt install -y bats       # Debian/Ubuntu/WSL
  brew install bats-core         # macOS
  npm install -g bats            # any platform with Node.js
MSG
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: 'jq' not found — the renderer under test parses its input with it." >&2
  exit 1
fi

bash_status=0
js_status=0

echo ""
echo "==> Bash tests (bats)"
if bats "$TESTS_DIR/bash"; then
  echo "Bash tests: PASS"
else
  bash_status=$?
  echo "Bash tests: FAIL (exit $bash_status)"
fi

# The glob is deliberate: `node --test tests/js` fails on older Node, which does
# not walk a bare directory. Passing the files directly works on every version.
echo ""
echo "==> JS tests (node --test)"
if node --test "$TESTS_DIR"/js/*.test.js; then
  echo "JS tests: PASS"
else
  js_status=$?
  echo "JS tests: FAIL (exit $js_status)"
fi

echo ""
echo "==> Summary"
echo "  bash: $([ "$bash_status" -eq 0 ] && echo PASS || echo FAIL)"
echo "  js:   $([ "$js_status" -eq 0 ] && echo PASS || echo FAIL)"

if [ "$bash_status" -ne 0 ] || [ "$js_status" -ne 0 ]; then
  exit 1
fi
echo "All tests passed."
