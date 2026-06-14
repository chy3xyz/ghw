#!/usr/bin/env bash
# run_all_tests.sh — verify all Phase 1 tests pass end-to-end.
#
# Usage:  bash examples/crm_demo/run_all_tests.sh
# Exits 0 iff all 9 Python tests + all Zig tests pass.
#
# This is the "did Phase 1 work?" check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Python tests (CRM demo orchestrator) ==="
python3 "$SCRIPT_DIR/test_demo.py"

echo ""
echo "=== Zig tests (Phase 1 modules) ==="
for module in \
    src/harness/product_intent.zig \
    src/harness/llm_driver.zig \
    src/harness/crm_kpi.zig \
    src/harness/evolution_rationale.zig \
    src/harness/user_channel.zig \
    src/harness/mock_provider.zig \
    src/harness/consent.zig \
    src/world/existence_degree.zig \
; do
    if [ -f "$REPO_ROOT/$module" ]; then
        echo ""
        echo "--- $module ---"
        (cd "$REPO_ROOT" && zig test "$module" 2>&1 | tail -1)
    fi
done

echo ""
echo "=== End-to-end demo ==="
python3 "$SCRIPT_DIR/demo.py" 2>&1 | tail -10

echo ""
echo "✅ All Phase 1 tests passed."
