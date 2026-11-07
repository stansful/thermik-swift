#!/usr/bin/env bash
# Focused parser regression: generic Swift declarations are inventoried and the original generic call's 21-line body
# is a violation. The fixture is text so the production Swift scan does not include it.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd -P)"
TREE="$(cd "$HERE/../.." && pwd -P)"
python3 - "$TREE/scripts/lib/swift-function-inventory.py" "$HERE/fixtures/generic-call.swift.txt" <<'PY'
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("swift_function_inventory", sys.argv[1])
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)
items = inventory.functions(Path(sys.argv[2]))
actual = [(item["name"], item["bodyLines"]) for item in items]
violations = [item for item in items if item["bodyLines"] > 10]
if actual != [("call", 21)] or len(violations) != 1:
    print(f"not ok generic function inventory: functions={actual}, violations={len(violations)}", file=sys.stderr)
    sys.exit(1)
print("ok generic function counted; 21-line violation detected")
PY

WORK="$(mktemp -d "${TMPDIR:-/tmp}/swift-function-inventory-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
for root in App Helper Packages scripts; do
  ln -s "$TREE/$root" "$WORK/$root"
done
if ! (cd "$WORK" && python3 "$TREE/scripts/lib/swift-function-inventory.py"); then
  echo "not ok clean-tree inventory: main() failed without an existing build directory" >&2
  exit 1
fi
if [ ! -f "$WORK/build/swift-function-inventory.json" ]; then
  echo "not ok clean-tree inventory: main() did not create build/swift-function-inventory.json" >&2
  exit 1
fi
echo "ok clean-tree inventory: main() creates the output parent and JSON"
