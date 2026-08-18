#!/usr/bin/env bash
# Regression guard for the 2026-08-18 security advisory.
#
# `#[spec_only]` is a CUSTOM attribute (sui-prover / asymptotic.tech), not a
# Move primitive. The regular compiler tolerates it as an unknown-attribute
# warning and ships the annotated functions in production bytecode VERBATIM —
# the former `spec_call_*` wrappers were Critical unauthenticated
# `&mut PositionManager` entry points. Only `#[test_only]` (a Move primitive)
# is stripped from non-test builds.
#
# This script fails the build if the PRODUCTION module bytecode contains ANY
# `spec_` or `test_only_` symbol:
#   - `spec_*`        — every `#[spec_only]` item is forbidden in the chain
#                       package; private-field reads for specs must use
#                       `#[test_only]` getters instead (sui-prover SKILL.md
#                       "Private struct field access" pattern)
#   - `test_only_*`   — must be stripped by the compiler; presence means a
#                       test-only helper leaked into a production module

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
    if strings "$mv" | grep -qE 'spec_|test_only_'; then
        echo "FAIL: $mv contains a forbidden spec/test symbol:" >&2
        strings "$mv" | grep -E 'spec_|test_only_' | sed 's/^/    /' >&2
        echo "Chain package must contain NO #[spec_only] items." >&2
        echo "Use #[test_only] getters for private-field reads (compiler-stripped)." >&2
        exit 1
    fi
done

echo "OK: production bytecode is clean of spec_/test_only_ symbols"
