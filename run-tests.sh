#!/usr/bin/env bash
# Run Swift client tests with env vars from .env.tests
# Usage:
#   ./run-tests.sh                    # all tests
#   ./run-tests.sh smoke              # quick smoke tests (~1-2 min)
#   ./run-tests.sh AvailabilityTests  # filter by test class

set -euo pipefail
cd "$(dirname "$0")"

# Load env vars
set -a
source .env.tests
set +a

# Smoke test: core client ops, sync, offline, persistence, lifecycle
SMOKE_FILTER="JsBaoClientTests.JsBaoClientTests|AvailabilityTests|LifecycleTests|StorageProviderTests|PersistenceTests"

# Swift 6 Sendable regression gate (#1992, repointed by #1946). The
# `JsBaoClient` target now compiles in the `.v6` language mode, so a `Sendable`
# violation in the library is a hard build error rather than a counted
# diagnostic. The gate still runs first because it turns that build failure
# into a readable, per-file report before the whole test build starts — and
# because it checks the mode is still committed, which the build cannot: a
# revert to `.v5` would compile clean and mean nothing.
#
# Runs on the full-suite invocation only (filtered runs are for iteration).
# Set SKIP_V6_SENDABLE_GATE=1 to skip it.
#
# `V6_ZERO_FILES` names the files whose zero-site claim each phase of the
# concurrency epic made; the gate reports any site in them by name. It is the
# same set that `SendableModelLayerTests.testV6SendableGateIsWiredAsAnAssertion`
# and `SendableAsyncManagerTypingTests.testV6GateHoldsThePhaseD1FilesAtZero`
# check for, so a half-update fails the suite. `V6_MAX_SITES` stays at 0 — under
# the committed mode nothing above zero builds at all.
V6_MAX_SITES=0
V6_ZERO_FILES=(
  "JsBaoClient.swift"                  # Phase C (#1992)
  "Schema/DynamicModel.swift"          # Phase C
  "Schema/MultiDocModel.swift"         # Phase C
  "Schema/RelationshipResolution.swift" # Phase C
  "Query/BaoModelQueryEngine.swift"    # Phase C
  "Internal/KvCache.swift"             # Phase D1 (#1993)
  "Internal/DocumentManager.swift"     # Phase D1
  "Internal/OfflineStore.swift"        # Phase D2 — new actor boundary
  "Internal/AnalyticsQueue.swift"      # Phase D3 — the actor itself
  "Internal/BlobManager.swift"         # #2172 — new actor boundary
)

run_v6_gate() {
  if [ "${SKIP_V6_SENDABLE_GATE:-0}" = "1" ]; then
    echo "Skipping the Swift 6 Sendable gate (SKIP_V6_SENDABLE_GATE=1)."
    return 0
  fi
  echo "Running the Swift 6 Sendable gate (max $V6_MAX_SITES sites)..."
  scripts/v6-sendable-gate.sh --max "$V6_MAX_SITES" --require-zero "${V6_ZERO_FILES[@]}"
}

if [ "${1:-}" = "smoke" ]; then
  echo "Running smoke tests..."
  swift test --filter "$SMOKE_FILTER"
elif [ $# -gt 0 ]; then
  swift test --filter "$@"
else
  run_v6_gate
  swift test
fi
