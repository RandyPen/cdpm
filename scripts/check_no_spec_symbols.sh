#!/usr/bin/env bash
# Regression guard for the 2026-08-18 security advisory.
#
# The former `#[spec_only] public fun spec_call_*` forwarders compiled into
# production bytecode as unauthenticated `&mut PositionManager` entry points
# (Critical). `#[spec_only]` is a CUSTOM attribute — the regular compiler
# tolerates it and ships the annotated items verbatim. Only `#[test_only]`
# (a Move primitive) is stripped from non-test builds.
#
# This script fails the build if the PRODUCTION module bytecode contains any
# of:
#   - `spec_call_`   — mutating prover wrappers (removed 2026-08-18)
#   - `test_only_`   — must be stripped by the compiler
#   - `test_call_`   — former wrapper naming (removed 2026-08-18)
#
# Read-only `#[spec_only]` state probes (`spec_pm_*`, `spec_fee_house_*`,
# `spec_max_fee_rate`) are intentionally ALLOWED — they take `&` references
# and cannot move assets. If the spec package is ever restructured to drop
# them, tighten this check to forbid every `spec_` symbol.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> building production package"
sui move build

echo "==> scanning production bytecode for spec/test symbols"
for mv in build/*/bytecode_modules/*.mv; do
    [ -e "$mv" ] || continue
    # Skip test-only modules (their test_only_* symbols are expected).
    case "$(basename "$mv")" in
        *_tests.mv) continue ;;
    esac
    if strings "$mv" | grep -qE 'spec_call_|test_only_|test_call_'; then
        echo "FAIL: $mv contains a forbidden spec/test symbol:" >&2
        strings "$mv" | grep -E 'spec_call_|test_only_|test_call_' | sed 's/^/    /' >&2
        echo "If you added a test-only helper, use #[test_only] (compiler-stripped)." >&2
        echo "If you need a prover hook, keep it read-only (#[spec_only] with & refs)." >&2
        exit 1
    fi
done

echo "OK: production bytecode is clean of spec_call_/test_only_/test_call_ symbols"
