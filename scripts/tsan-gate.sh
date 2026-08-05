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
#   FIXED AND REMOVED FROM THE BASELINE (2026-07-29, #1994 Phase E2):
#     - EventEmitter.swift  EventSubscription.cancel() — `cancellation` is now
#       claimed under an `NSLock` and the closure runs outside it, so `cancel()`
#       racing `deinit` (or itself) cancels exactly once.
#       `EventStreamTests.testEventSubscriptionCancelsExactlyOnceUnderConcurrency`
#       is the regression.
#     - JsBaoClient.swift  openDocument's `sub?.cancel()` in the .sync handler
#       racing the `sub =` assignment — the captured `var` is now a lock-guarded
#       `SubscriptionHolder`, which also cancels a subscription stored after an
#       early cancel instead of leaking the registry entry.
#   Their signatures are gone from BASELINE_RACE_SIGNATURES below, so either race
#   reappearing now FAILS the gate.
#
#   FIXED AND REMOVED FROM THE BASELINE (2026-07-30, #1993 Phase D3):
#     - AnalyticsQueue.swift  scheduleFlush()/flushTimer — `AnalyticsQueue` is an
#       `actor`, so `flushTimer` is isolated state and the check-and-schedule
#       region contains no suspension point. The `AnalyticsQueue` and
#       `flushTimer` signatures are gone from BASELINE_RACE_SIGNATURES, and
#       `AnalyticsQueueFlushTimerRaceTests` joined the default filter so the
#       race they covered is actually exercised on every run.
#
#   This script ENFORCES that baseline-diff policy (issue #1910, codex cycle 1):
#   it does not just run `swift test` and inherit its exit code. It captures the
#   TSan output, splits it into per-race report blocks, and classifies each block
#   as KNOWN (matches one of the documented baseline races via the stable
#   type/field-name signatures in BASELINE_RACE_SIGNATURES below — line numbers
#   shift as code moves, so we match on names, not `file:line`) or NEW. A run
#   with only KNOWN races does not fail the RACE verdict; a single NEW race does.
#
# THREE INDEPENDENT VERDICTS (issue #2274)
#
#   The gate reports a RACE verdict, a SANITIZER verdict and a SUITE verdict
#   separately, and fails if any of them is bad:
#     - Race verdict      — from the classification above, over `data race`
#       reports only: NEW / BASELINE-ONLY / CLEAN.
#     - Sanitizer verdict — every OTHER kind of ThreadSanitizer report
#       (heap-use-after-free, thread leak, double lock / destroy of a locked
#       mutex / unlock of an unlocked mutex, signal-unsafe call, ...). None of
#       these is in the baseline, so any of them fails the gate.
#     - Suite verdict     — from `swift test`'s exit code: did the sanitized run
#       build and pass?
#   Race and suite used to be entangled: the `KNOWN_RACES > 0` branch returned
#   PASS and exit 0 BEFORE the exit-code check ran, so any run in which a
#   baseline race fired (which is nearly every run, thanks to the
#   WebSocketManager.disconnect entry) reported PASS even when the suite was red.
#
#   Keeping them separate needs `exitcode=0` in TSAN_OPTIONS (set below).
#   ThreadSanitizer's default is `exitcode=66`: with it, merely DETECTING a race
#   makes the test process exit nonzero, so a suite check would fail every
#   baseline run. With `exitcode=0`, reports are surfaced in the log (where this
#   script classifies them) and the process exit status means only "the suite
#   built and passed".
#
#   `exitcode=0` is also why the SANITIZER verdict exists: non-data-race reports
#   used to fail the run only through TSan's own exit code, so neutralizing it
#   without classifying them from the log would let a heap-use-after-free pass
#   the gate silently.
#
# PREREQUISITE: A RUNNING LOCAL DEV SERVER
#
#   Because the suite verdict is load-bearing, the gate now requires the same
#   environment the rest of the repo's live-API tests do. Three suites in the
#   default filter are server-backed (they build a `TestContext`):
#   ConcurrentWritesTests, DocumentManagerRaceTests, AuthRefreshCoalescingTests.
#   Start `node debug-server.js` before running the gate. Those suites are kept
#   in the filter deliberately — they drive the real multi-client WebSocket and
#   document traffic through the lock-bearing classes this gate exists to
#   validate, so narrowing the filter to server-free suites would drop the
#   highest-value race coverage. The suite-failure message names this
#   prerequisite so a down server is diagnosable from the gate output.
#
# If a future run reports a race originating in yswift-fork/sqlite3 rather than
# JsBaoClient code, narrow the `--filter` to the JsBaoClient concurrency suites
# and document the FFI race instead of treating it as a JsBaoClient regression.
#
# Usage:
#   node debug-server.js &                       # required: see PREREQUISITE above
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
# #1994: the AsyncStream registry and the EventSubscription lock fix. The
# subscription cancel/deinit race this suite hammers is the one whose baseline
# entry was removed above, so the gate has to actually run it.
DEFAULT_FILTER="${DEFAULT_FILTER}|EventStreamTests"
# #1993 Phase D3: `AnalyticsQueue` is an actor now and its `flushTimer` baseline
# entry was removed, so — same reasoning as `EventStreamTests` — the gate has to
# actually run the suite that hammers the race the entry used to cover.
DEFAULT_FILTER="${DEFAULT_FILTER}|AnalyticsQueueFlushTimerRaceTests"
# The removed entries were TYPE-level, so they covered the whole queue, not just
# `scheduleFlush`. `flush` / `takeBatch` / `deliver` / `persistBuffer` /
# `destroy` and the `pendingFlushTask` the conversion added need exercising too,
# or the broadest signature in the list was traded for one suite's worth of
# coverage (review of PR #2266).
DEFAULT_FILTER="${DEFAULT_FILTER}|ActorizedAnalyticsQueueTests"
# #2172: `BlobManager` is an actor now. `BlobManagerTests` was already in the
# filter, but it exercises the queue-management verbs, not the timer —
# `BlobBackoffTests` is the suite that hammers `scheduleQueueProcessing`, the
# generation counter and the retry rotation, which is exactly the state the
# conversion moved into actor isolation. `ActorizedBlobManagerTests` adds the
# emit-off-the-actor and upload-concurrency exercises. Neither suite has ever
# run under TSan before, and no baseline entry involves `BlobManager` — nothing
# is removed here, and nothing may be added.
DEFAULT_FILTER="${DEFAULT_FILTER}|BlobBackoffTests|ActorizedBlobManagerTests"
# #2171: `WebSocketManager` is an actor now and BOTH remaining baseline entries
# were removed below. Same rule as `EventStreamTests` and
# `AnalyticsQueueFlushTimerRaceTests`: a baseline entry may only be removed if
# the gate actually runs the suites that hammer the race it covered.
# `WebSocketManagerDisconnectTests` was already in the filter (it drives the
# `disconnect()` side); `ActorizedWebSocketManagerTests` is the new ordering and
# reconnect suite, which is what exercises `receiveLoopTask` and the task swap.
# The `send(_:)` throughput measurement lives in its own suite
# (`WebSocketSendThroughputTests`) precisely so it is NOT swept in here: a
# 20,000-send loop under a 5-15x sanitizer is gate runtime with no coverage
# return, because the ratio between its two arms survives instrumentation.
# Don't add it (review of PR #2425).
DEFAULT_FILTER="${DEFAULT_FILTER}|ActorizedWebSocketManagerTests|WebSocketManagerErrorTests"

FILTER="${1:-${DEFAULT_FILTER}}"

# Documented baseline races (see the Phase 0 result above). Each entry is an
# extended-regex signature matched against a whole TSan race report block. They
# key on the stable type / function / file names TSan prints in the race stacks
# rather than a `file:line`, because the conversion shifts line numbers (the
# WebSocketManager race moved from :584 to :661 with no behavior change). A race
# block that matches ANY of these is a KNOWN pre-existing race and does not fail
# the gate; a block matching NONE is a NEW race and fails it.
#
# THE BASELINE IS EMPTY. Every race the gate sees is a NEW race and fails it.
# Keep it that way: an entry added here is a race someone decided to tolerate,
# and it needs the same justification the removed ones carried.
#
# The `EventSubscription` / `EventEmitter.swift` signatures were REMOVED once
# #1994 Phase E2 fixed those two races (see the note above) — a race there now
# fails the gate.
#
# The `AnalyticsQueue` / `flushTimer` signatures were REMOVED by #1993 Phase D3:
# the type is an `actor` now, so `flushTimer` is isolated state and the
# scheduleFlush() race the entries covered cannot occur. They were type-level
# entries — the broadest in the list — so keeping them would have hidden a new
# race anywhere in the file. Removed only after a clean TSan run over
# `AnalyticsQueueFlushTimerRaceTests` (added to the default filter above)
# confirmed the signature no longer appears.
#
# The last two — `WebSocketManager\.disconnect` and `receiveLoopTask`, the two
# angles on the same `disconnect()`-versus-receive-loop race — were REMOVED by
# #2171: `WebSocketManager` is an `actor` now, `receiveLoopTask` is isolated
# state, and every URLSession callback enters through one ordered channel, so
# the race the entries covered cannot occur. Removed only after a clean TSan run
# over the default filter (with `ActorizedWebSocketManagerTests` and
# `WebSocketManagerErrorTests` added to it above) reported 0 known / 0 new.
#
# That leaves the baseline EMPTY, which the two guards below exist to make safe:
# an empty array is not an accident here, and it must not be able to turn the
# race verdict into a permanent pass.
BASELINE_RACE_SIGNATURES=()

# Build a single alternation so a block is "known" if it matches any signature.
#
# TWO empty-baseline hazards are handled here, both of which would otherwise
# turn an emptied baseline into a silently broken gate (#2171 behavior 19):
#
#  1. macOS ships bash 3.2, where `"${arr[@]}"` on an EMPTY array aborts under
#     `set -u` with `unbound variable`. Hence the `${arr[@]+...}` idiom, the
#     same one `scripts/v6-sendable-gate.sh` already uses for `REQUIRE_ZERO`.
#  2. An empty `KNOWN_RE` is an empty awk regex, and an empty regex matches
#     EVERY string. Left unguarded, the classifier below would file every race —
#     including a brand-new one — as KNOWN, and the race verdict would report OK
#     forever. `HAVE_BASELINE` makes the classifier skip the known-match branch
#     entirely when there is no baseline, so every race classifies as NEW.
if [ "${#BASELINE_RACE_SIGNATURES[@]}" -gt 0 ]; then
  HAVE_BASELINE=1
  KNOWN_RE="$(printf '%s|' ${BASELINE_RACE_SIGNATURES[@]+"${BASELINE_RACE_SIGNATURES[@]}"})"
  KNOWN_RE="${KNOWN_RE%|}"
else
  HAVE_BASELINE=0
  KNOWN_RE=""
fi

# Collect every race in one run (don't abort on the first) so the diff sees the
# full set. TSan defaults to halt_on_error=0, but set it explicitly.
#
# This export doubles as the "running under TSan" marker the test process reads:
# `ActorizedAnalyticsQueueTests.threadSanitizerActive` keys off `TSAN_OPTIONS`
# being set, and skips the one wall-clock assertion in the suite
# (`testUntypedLoggingHotPathDoesNotRegress`) because TSan's ~4× overhead spends
# most of that test's margin. Keep the export unconditional (review of PR #2266).
#
# `exitcode=0` overrides TSan's default of 66 so that detecting a race does NOT
# by itself make the process exit nonzero. Races are classified from the log
# below; the process exit status is reserved for the SUITE verdict — "did the
# sanitized run build and pass?" (issue #2274). Without this the two verdicts
# stay entangled and every baseline race would fail the suite check.
#
# A caller-supplied TSAN_OPTIONS is appended last, so an explicit caller value
# still wins (sanitizer flag parsing takes the last occurrence).
export TSAN_OPTIONS="halt_on_error=0 exitcode=0 ${TSAN_OPTIONS:-}"

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

# Split the log into ThreadSanitizer report blocks and classify each. A block
# runs from a `WARNING: ThreadSanitizer: <type>` line to the following
# `SUMMARY: ThreadSanitizer:` line.
#
# The block opener matches ANY report type, not just `data race`. TSan also
# reports heap-use-after-free, thread leak, mutex misuse (double lock / destroy
# of a locked mutex / unlock of an unlocked mutex) and signal-unsafe call; with
# `exitcode=0` those no longer fail the process on their own, so the gate has to
# see them here or they pass silently.
#
#   - `data race` blocks (including `data race on vptr`) are classified against
#     the baseline: KNOWN if they match a signature, otherwise NEW.
#   - Every other report type is counted as OTHER. None of them is in the
#     documented baseline, so any occurrence fails the gate.
CLASSIFY="$(
  awk -v known_re="${KNOWN_RE}" -v have_baseline="${HAVE_BASELINE}" '
    /WARNING: ThreadSanitizer:/ {
      in_block=1; block="";
      is_race = ($0 ~ /WARNING: ThreadSanitizer: data race/);
    }
    in_block { block = block $0 "\n"; }
    in_block && /SUMMARY: ThreadSanitizer:/ {
      in_block=0;
      if (!is_race) { other++; }
      # The known-match branch is skipped entirely when the baseline is empty:
      # `block ~ ""` is true for every block, so testing it would classify
      # every race as KNOWN and report a permanent pass.
      else if (have_baseline == 1 && block ~ known_re) { known++; }
      else { new++; }
    }
    END { printf "%d %d %d\n", (known+0), (new+0), (other+0); }
  ' "${TSAN_LOG}"
)"
read -r KNOWN_RACES NEW_RACES OTHER_REPORTS <<< "${CLASSIFY}"

# The distinct non-data-race report types, for the failure message.
OTHER_TYPES="$(
  awk '
    /WARNING: ThreadSanitizer:/ {
      line=$0;
      sub(/.*WARNING: ThreadSanitizer: /, "", line);
      sub(/ *\(pid=.*/, "", line);
      sub(/[[:space:]]+$/, "", line);
      if (line !~ /^data race/) { print line; }
    }
  ' "${TSAN_LOG}" | sort -u | paste -sd, - | sed 's/,/, /g'
)"

echo
echo "== TSan gate result: ${KNOWN_RACES} known (baseline) race(s), ${NEW_RACES} new race(s), ${OTHER_REPORTS} other sanitizer report(s); swift test exit ${SWIFT_EXIT} =="
echo

# Three independent verdicts (issue #2274). Report all of them, THEN decide the
# exit code — no check may short-circuit another, or a red suite hides behind a
# tolerated baseline race (or vice versa).

# --- Race verdict: from the classification above, never from the exit code. ---
if [ "${NEW_RACES}" -gt 0 ]; then
  echo "Race verdict:  FAIL — ${NEW_RACES} NEW data race(s) not in the documented #1910 baseline."
  echo "               Inspect the TSan output above; the lock conversion likely introduced one."
elif [ "${KNOWN_RACES}" -gt 0 ]; then
  echo "Race verdict:  OK — only the ${KNOWN_RACES} documented pre-existing (baseline) race(s) fired; no new race."
  echo "               These are the #1910 sponsor-flagged pre-existing races, tolerated by the baseline-diff policy."
elif [ "${HAVE_BASELINE}" -eq 0 ]; then
  echo "Race verdict:  CLEAN — no data races at all, and the baseline is empty:"
  echo "               every race is now a NEW race. Nothing is tolerated here any more."
else
  echo "Race verdict:  CLEAN — no data races at all."
fi

# --- Sanitizer verdict: every non-data-race ThreadSanitizer report. ---
if [ "${OTHER_REPORTS}" -gt 0 ]; then
  echo "Sanitizer verdict: FAIL — ${OTHER_REPORTS} non-data-race ThreadSanitizer report(s): ${OTHER_TYPES}."
  echo "               None of these is in the documented #1910 baseline, which covers data races only."
else
  echo "Sanitizer verdict: CLEAN — no non-data-race ThreadSanitizer reports."
fi

# --- Suite verdict: from the swift test exit code, never from the races. ---
if [ "${SWIFT_EXIT}" -ne 0 ]; then
  echo "Suite verdict: FAIL — swift test exited ${SWIFT_EXIT}: the sanitized suite did not build and pass."
  echo "               This is a build or test failure, NOT a race verdict. Check the test output above."
  echo "               The default filter includes server-backed suites (ConcurrentWritesTests,"
  echo "               DocumentManagerRaceTests, AuthRefreshCoalescingTests), so a local dev server"
  echo "               must be running (\`node debug-server.js\`) — a down server fails the suite here."
else
  echo "Suite verdict: PASS — swift test succeeded under ThreadSanitizer."
fi

echo

# A new race or any non-data-race sanitizer report is the gate's own failure and
# takes the exit code; otherwise a red suite propagates its underlying status.
if [ "${NEW_RACES}" -gt 0 ]; then
  echo "GATE: FAIL (new data race)"
  exit 1
fi

if [ "${OTHER_REPORTS}" -gt 0 ]; then
  echo "GATE: FAIL (non-data-race sanitizer report)"
  exit 1
fi

if [ "${SWIFT_EXIT}" -ne 0 ]; then
  echo "GATE: FAIL (sanitized suite failed)"
  exit "${SWIFT_EXIT}"
fi

echo "GATE: PASS"
exit 0
