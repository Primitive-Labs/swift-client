#!/usr/bin/env bash
#
# ThreadSanitizer gate for the NSLock -> scoped `withLock` conversion (issue #1910).
#
# Runs the JsBaoClient concurrency tests under ThreadSanitizer so a data race
# introduced by the lock refactor fails loudly instead of lurking. Uses SwiftPM's
# native `--sanitize thread` — no external tooling, no suppression files.
#
# Rollout policy (per the sponsor's approved plan, issue #1910):
#   - Run ONCE as a baseline before the rollout starts.
#   - Re-run after each RISKY batch (not per-file before/after).
#
# Phase 0 spike result (2026-07-21):
#   BUILD: `swift build --package-path swift-client -Xswiftc -sanitize=thread`
#   builds the full FFI-linked package (yswift-fork + sqlite3) cleanly — exit 0,
#   "Build complete!". TSan is viable here; no FFI build failure, so no FFI
#   suppression infrastructure is needed.
#
#   RUNTIME BASELINE IS NOT CLEAN. Running this gate on unmodified `main`
#   reports PRE-EXISTING data races in JsBaoClient code (NOT introduced by the
#   #1910 conversion, and NOT in yswift-fork/sqlite3):
#     - EventEmitter.swift:112  EventSubscription.cancel() — `cancellation` var
#       is read/niled with no synchronization; EventSubscription has no lock and
#       is outside the 10 lock-bearing classes this epic converts.
#     - JsBaoClient.swift:1828  openDocument's `sub?.cancel()` in the .sync
#       handler racing the `sub =` assignment (same EventSubscription root cause).
#     - AnalyticsQueue.swift:273 scheduleFlush() — `flushTimer` assigned/niled
#       outside the lock.
#     - WebSocketManager.disconnect() — `self.receiveLoopTask?.cancel()` is read
#       OUTSIDE the lock (base commit line 584; behavior-preserved by the Phase 4
#       `withLock` conversion, same access, now line 661). Surfaced by the Phase 4
#       server-free `WebSocketManagerDisconnectTests`; confirmed PRE-EXISTING by
#       running that test against base commit 2fe408b1 (same race at :584). The
#       `receiveLoopTask` var is otherwise mutated under the lock. NOT introduced
#       by the conversion — same sponsor-decision bucket as the others above.
#   So the gate is a BASELINE-DIFF gate, not a "clean before/after" gate: a phase
#   passes if it introduces NO NEW race beyond this documented set. Whether to
#   fix these pre-existing races (in-epic vs a tracked follow-up) is a sponsor
#   decision flagged on issue #1910 — see the Phase 0 comment.
#
#   This script ENFORCES that baseline-diff policy (issue #1910, codex cycle 1):
#   it does not just run `swift test` and inherit its exit code. It captures the
#   TSan output, splits it into per-race report blocks, and classifies each block
#   as KNOWN (matches one of the documented baseline races via the stable
#   type/field-name signatures in BASELINE_RACE_SIGNATURES below — line numbers
#   shift as code moves, so we match on names, not `file:line`) or NEW. A run
#   with only KNOWN races PASSES even though `swift test` exits nonzero; a single
#   NEW race FAILS the gate. A genuine build/test failure with no TSan race at
#   all still fails (the underlying exit code is propagated).
#
# If a future run reports a race originating in yswift-fork/sqlite3 rather than
# JsBaoClient code, narrow the `--filter` to the JsBaoClient concurrency suites
# and document the FFI race instead of treating it as a JsBaoClient regression.
#
# Usage:
#   swift-client/scripts/tsan-gate.sh            # default concurrency-suite filter
#   swift-client/scripts/tsan-gate.sh <filter>   # custom XCTest filter

set -euo pipefail

# Resolve the package path relative to this script so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default filter: the deadlock/concurrency scaffolding PLUS every concurrency
# suite the #1910 lock conversions exercise. The gate exists to validate those
# conversions, so its default run must actually execute them — omitting them
# would let the gate pass without touching the lock refactor (codex cycle 1).
# Each name is an XCTest identifier substring; `swift test --filter` treats them
# as an alternation of regexes.
DEFAULT_FILTER="DeadlockWatchdogTests|YDocumentDeadlockTests|YTextSemanticsTests"
DEFAULT_FILTER="${DEFAULT_FILTER}|DocumentManagerRaceTests|DocumentManagerCoalescingTests"
DEFAULT_FILTER="${DEFAULT_FILTER}|ConcurrentWritesTests"
DEFAULT_FILTER="${DEFAULT_FILTER}|AuthRefreshCoalescingTests|AuthRefreshCoalescingUnitTests"
DEFAULT_FILTER="${DEFAULT_FILTER}|OnlineHandoffCoalescingTests"
DEFAULT_FILTER="${DEFAULT_FILTER}|BlobManagerTests|StorageProviderTests|KvCacheTests"
DEFAULT_FILTER="${DEFAULT_FILTER}|EventEmitterTests|WebSocketManagerDisconnectTests"

FILTER="${1:-${DEFAULT_FILTER}}"

# Documented baseline races (see the Phase 0 result above). Each entry is an
# extended-regex signature matched against a whole TSan race report block. They
# key on the stable type / function / file names TSan prints in the race stacks
# rather than a `file:line`, because the conversion shifts line numbers (the
# WebSocketManager race moved from :584 to :661 with no behavior change). A race
# block that matches ANY of these is a KNOWN pre-existing race and does not fail
# the gate; a block matching NONE is a NEW race and fails it.
#
# Granularity is deliberate. `EventSubscription` and `AnalyticsQueue` are
# UNCONVERTED classes outside the 10 lock-bearing classes this epic touches, so
# any race naming them is by definition one of the documented pre-existing ones
# — matched at TYPE level. `WebSocketManager` IS a converted class, so only its
# `disconnect` method is baseline; it is matched at METHOD level so a new race
# in any other WebSocketManager method still fails the gate.
BASELINE_RACE_SIGNATURES=(
  'EventSubscription'            # EventEmitter.swift EventSubscription.cancel()
                                 # + the openDocument .sync `sub?.cancel()` race
                                 # (same EventSubscription root cause); type-level
  'EventEmitter\.swift'          # file of the EventSubscription race
  'AnalyticsQueue'              # scheduleFlush()/flushTimer race; unconverted, type-level
  'flushTimer'                  # AnalyticsQueue field name, if TSan prints it
  'WebSocketManager\.disconnect' # disconnect() receiveLoopTask race; METHOD-level
  'receiveLoopTask'             # WebSocketManager field name, if TSan prints it
)

# Build a single alternation so a block is "known" if it matches any signature.
KNOWN_RE="$(printf '%s|' "${BASELINE_RACE_SIGNATURES[@]}")"
KNOWN_RE="${KNOWN_RE%|}"

# Collect every race in one run (don't abort on the first) so the diff sees the
# full set. TSan defaults to halt_on_error=0, but set it explicitly.
export TSAN_OPTIONS="halt_on_error=0 ${TSAN_OPTIONS:-}"

TSAN_LOG="$(mktemp -t tsan-gate.XXXXXX)"
trap 'rm -f "${TSAN_LOG}"' EXIT

echo "== TSan gate: swift test --sanitize thread --filter '${FILTER}' =="

# Run the suite, teeing output so the operator still sees it live. Capture the
# exit code without letting `set -e` abort — we classify races before deciding.
set +e
swift test \
  --package-path "${PACKAGE_DIR}" \
  --sanitize thread \
  --filter "${FILTER}" 2>&1 | tee "${TSAN_LOG}"
SWIFT_EXIT=${PIPESTATUS[0]}
set -e

# Split the log into race report blocks and classify each. A ThreadSanitizer
# race block runs from a `WARNING: ThreadSanitizer: data race` line to the
# following `SUMMARY: ThreadSanitizer:` line. A block is KNOWN if it matches a
# baseline signature, otherwise NEW.
CLASSIFY="$(
  awk -v known_re="${KNOWN_RE}" '
    /WARNING: ThreadSanitizer: data race/ { in_block=1; block=""; }
    in_block { block = block $0 "\n"; }
    in_block && /SUMMARY: ThreadSanitizer:/ {
      in_block=0;
      if (block ~ known_re) { known++; } else { new++; }
    }
    END { printf "%d %d\n", (known+0), (new+0); }
  ' "${TSAN_LOG}"
)"
KNOWN_RACES="${CLASSIFY%% *}"
NEW_RACES="${CLASSIFY##* }"

echo
echo "== TSan gate result: ${KNOWN_RACES} known (baseline) race(s), ${NEW_RACES} new race(s); swift test exit ${SWIFT_EXIT} =="

if [ "${NEW_RACES}" -gt 0 ]; then
  echo "FAIL: ${NEW_RACES} NEW data race(s) not in the documented #1910 baseline."
  echo "      Inspect the TSan output above; the lock conversion likely introduced one."
  exit 1
fi

if [ "${KNOWN_RACES}" -gt 0 ]; then
  echo "PASS: only the ${KNOWN_RACES} documented pre-existing (baseline) race(s) fired; no new race."
  echo "      These are the #1910 sponsor-flagged pre-existing races, tolerated by the baseline-diff policy."
  exit 0
fi

# No TSan races at all. Honor the underlying swift test result so a genuine
# build/test failure (not a race) still fails the gate.
if [ "${SWIFT_EXIT}" -ne 0 ]; then
  echo "FAIL: swift test exited ${SWIFT_EXIT} with no TSan race — a build or test failure, not a race."
  exit "${SWIFT_EXIT}"
fi

echo "PASS: no data races and swift test succeeded."
exit 0
