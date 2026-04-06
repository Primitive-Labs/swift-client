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

if [ "${1:-}" = "smoke" ]; then
  echo "Running smoke tests..."
  swift test --filter "$SMOKE_FILTER"
elif [ $# -gt 0 ]; then
  swift test --filter "$@"
else
  swift test
fi
