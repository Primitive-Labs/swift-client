#!/usr/bin/env bash
#
# Regression gate for the Swift 6 language mode on the `JsBaoClient` target.
#
# The whole package ships in `.v6` (see the comment in `Package.swift`; #1946,
# Phase F, flipped the `JsBaoClient` target and #2310 flipped the rest and moved
# the mode to the package-level `swiftLanguageModes: [.v6]` pin). The compiler
# is therefore the real enforcement now — a `Sendable` violation in
# `Sources/JsBaoClient` is a build error, not a counted diagnostic. What this
# script adds on top of `swift build` is:
#
#   * it proves the mode is still committed before it believes a clean build
#     (a revert to `.v5` would otherwise report zero sites and read as PASS).
#     That manifest check covers the package pin AND every target's override,
#     including the targets this script's own `swift build --target
#     JsBaoClient` never compiles;
#   * it attributes the errors per file, which is what makes a regression
#     readable at a glance;
#   * it counts the strict-concurrency diagnostics the compiler grades as
#     WARNINGS, which a green build says nothing about (#2318);
#   * it fails with a gate-shaped message from `run-tests.sh`, before the
#     suite runs, instead of somewhere inside the test build output.
#
# On that third point: "builds clean" is narrower than "no `Sendable`
# violations". Phase F left 11 warning-level `#SendableClosureCaptures`
# diagnostics in `SQLiteStorageProvider.onQueue` behind a green build and a
# green gate, because both statements were about errors only. `--max-warnings`
# is the counter that closes that gap — it counts warning-level
# strict-concurrency sites in the target's OWN sources (a dependency's
# warnings are not ours to fix, and are not a regression in this package).
#
# Before #1946 this script installed the `.v6` mode itself by rewriting
# `Package.swift` into a scratch copy, because the committed mode was `.v5`
# and the epic's per-phase "this file is at zero sites" claims had no other
# way to be checked. That rewrite is gone: the mode it used to simulate is
# now the one the package actually builds in.
#
# Usage:
#   scripts/v6-sendable-gate.sh                     # print the per-file table
#   scripts/v6-sendable-gate.sh --raw <path>        # also keep the raw build log
#   scripts/v6-sendable-gate.sh --max <N>           # fail if the total exceeds N
#   scripts/v6-sendable-gate.sh --max-warnings <N>  # fail if the warning total exceeds N
#   scripts/v6-sendable-gate.sh --require-zero <f>… # fail if any listed file has a site
#
# Exit status:
#   With none of `--max`, `--max-warnings` or `--require-zero`, the script only
#   measures and exits 0 whenever the measurement completed — the counts are
#   the result, not the exit code.
#
#   With any of them, the script is an ASSERTION and exits non-zero on a
#   regression. `run-tests.sh` invokes it that way (`--max 0 --max-warnings 0`)
#   before the suite. In assertion mode ANY build failure fails the gate:
#   under the real language mode a green build is the invariant, so there is
#   no longer an "expected" failure to tolerate. That also covers the failure
#   shapes that emit no per-file diagnostic at all (missing toolchain,
#   manifest parse, dependency resolution, link), which would otherwise be
#   indistinguishable from "zero sites".
#
# The build uses the ordinary `.build` scratch path, so the compile it does is
# the same one `swift test` needs straight afterwards rather than a second
# copy of it.

set -uo pipefail

cd "$(dirname "$0")/.."

RAW_LOG=""
MAX_SITES=""
MAX_WARNING_SITES=""
REQUIRE_ZERO=()
ASSERT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --raw)
      RAW_LOG="${2:?--raw needs a path}"; shift 2 ;;
    --max)
      MAX_SITES="${2:?--max needs a number}"; ASSERT=1; shift 2 ;;
    --max-warnings)
      MAX_WARNING_SITES="${2:?--max-warnings needs a number}"; ASSERT=1; shift 2 ;;
    --require-zero)
      shift
      while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do
        REQUIRE_ZERO+=("$1"); shift
      done
      [ ${#REQUIRE_ZERO[@]} -gt 0 ] || { echo "--require-zero needs at least one path" >&2; exit 2; }
      ASSERT=1 ;;
    *)
      echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Confirm the committed language mode BEFORE spending a build on it. Read it
# out of the resolved manifest rather than grepping for the source text: the
# mode the JsBaoClient target actually builds in is the package-level pin plus
# any per-target override, and a grep sees neither relationship. Get it wrong
# and the JsBaoClient build runs in `.v5`, finds nothing, and reports PASS.
MANIFEST_JSON="$(mktemp -t v6-gate-manifest)"
trap 'rm -f "$MANIFEST_JSON"' EXIT
swift package dump-package > "$MANIFEST_JSON" 2>/dev/null \
  || { echo "GATE FAIL: could not dump the package manifest." >&2; exit 2; }
python3 - "$MANIFEST_JSON" <<'PY'
import json, sys

manifest = json.load(open(sys.argv[1]))
target = next((t for t in manifest["targets"] if t["name"] == "JsBaoClient"), None)
if target is None:
    sys.exit("GATE FAIL: no JsBaoClient target in the manifest.")

# Since #2310 the mode is the package-level pin, not a per-target setting, so
# that is what has to read `.v6`.
package_modes = manifest.get("swiftLanguageVersions")
if package_modes != ["6"]:
    sys.exit(
        "GATE FAIL: the package-level swiftLanguageModes pin must be [.v6] — the "
        "whole package builds in the Swift 6 language mode since #2310 (found: "
        f"{package_modes}). The gate would report zero sites for the wrong reason."
    )

# A per-target override wins over the package pin, so a stray one would put
# that target back in `.v5` behind a green package pin. Checked across EVERY
# target, not just `JsBaoClient`: the gate's own build is
# `swift build --target JsBaoClient`, so an override added to a test target
# would never be compiled here and would otherwise ship green.
def language_modes(settings):
    return [
        setting["kind"]["swiftLanguageMode"]["_0"]
        for setting in settings
        if "swiftLanguageMode" in setting["kind"]
    ]


offenders = {
    t["name"]: modes
    for t in manifest["targets"]
    for modes in [language_modes(t.get("settings", []))]
    if modes not in ([], ["6"])
}
if offenders:
    sys.exit(
        "GATE FAIL: a target overrides the package's Swift 6 language mode "
        f"(target: swiftLanguageMode settings): {offenders}."
    )

# `-swift-version 5` passed as an unsafe flag sets the same mode by another
# spelling, which the `swiftLanguageMode` settings above do not see.
unsafe_offenders = {}
for t in manifest["targets"]:
    for setting in t.get("settings", []):
        flags = setting["kind"].get("unsafeFlags", {}).get("_0", [])
        for index, flag in enumerate(flags):
            if flag == "-swift-version" and flags[index + 1:index + 2] != ["6"]:
                unsafe_offenders[t["name"]] = flags
if unsafe_offenders:
    sys.exit(
        "GATE FAIL: these targets set the language mode through "
        f"`-swift-version` unsafe flags: {unsafe_offenders}."
    )
PY
[ $? = 0 ] || exit 2

LOG="$(mktemp -t v6-build-log)"

# Force the target's own sources to recompile. An incremental `swift build`
# over an up-to-date module emits NOTHING — errors always resurface (a module
# with errors has no valid output to be up to date), but warnings do not, so a
# warm `.build` would hand the warning counter an empty log and read as PASS.
# Bumping the mtimes is enough, costs a couple of seconds, and keeps the
# artifacts the ones `swift test` needs straight afterwards — which a separate
# scratch path or an extra `-Xswiftc` flag would not.
find Sources/JsBaoClient -name '*.swift' -exec touch {} +

swift build --target JsBaoClient > "$LOG" 2>&1
BUILD_RC=$?
if [ -n "$RAW_LOG" ]; then cp "$LOG" "$RAW_LOG"; fi

# Only the diagnostic HEADER lines carry a `path:line:col:` prefix; the
# swiftc caret/underline continuation lines repeat the message without one,
# so anchoring on `^/` is what makes the count "unique site", not "unique
# mention".
#
# One pipeline, parameterized by severity, serves both counters:
#   $1 — severity, `error` or `warning`
#   $2 — extended regex the diagnostic message must match
#   $3 — optional extended regex the absolute path must match (default: any)
sites_matching() {
  local severity="$1" message_re="$2" path_re="${3:-.*}"
  grep -E "^/${path_re}\.swift:[0-9]+:[0-9]+: ${severity}: ${message_re}" "$LOG" \
    | sed -E "s/^(.*\.swift:[0-9]+:[0-9]+): ${severity}:.*$/\1/" \
    | sort -u
}

sites() {
  sites_matching "error" ".*Sendable"
}

# Strict-concurrency diagnostics as this compiler spells them: a bracketed
# diagnostic group (`[#SendableClosureCaptures]`, `[#SendableMetatypes]`,
# `[#IsolatedConformances]`, …) or, for the ones swiftc does not tag with a
# group, the concurrency vocabulary in the message itself. Deliberately wider
# than the one group that produced #2318 — a sibling group appearing after a
# toolchain bump is exactly the event this counter exists to surface.
CONCURRENCY_WARNING_RE='.*(\[#[A-Za-z]*(Sendable|Concurrency|Isolat|Actor)[A-Za-z]*\]|Sendable|concurrenc|actor-isolated|main actor|nonisolated|data race)'

# Scoped to the target's own sources: a warning in a dependency (TOMLKit) or in
# a test target is not a regression in `Sources/JsBaoClient` and must not fail
# our build.
warning_sites() {
  sites_matching "warning" "$CONCURRENCY_WARNING_RE" ".*/Sources/JsBaoClient/.*"
}

relative_sites() {
  sites | sed -E 's#^.*/Sources/JsBaoClient/##'
}

relative_warning_sites() {
  warning_sites | sed -E 's#^.*/Sources/JsBaoClient/##'
}

# `grep "^${path}:"` would read the `.` in each filename as a wildcard, so match
# the prefix literally instead.
sites_for_file() {
  relative_sites | awk -v prefix="$1:" 'index($0, prefix) == 1'
}

echo "=== unique Sendable error sites (file:line:col), by file ==="
relative_sites \
  | sed -E 's/:[0-9]+:[0-9]+$//' \
  | sort | uniq -c | sort -rn

TOTAL="$(sites | wc -l | tr -d ' ')"
echo "=== total unique Sendable error sites ==="
echo "$TOTAL"

echo "=== unique warning-level strict-concurrency sites in Sources/JsBaoClient, by file ==="
relative_warning_sites \
  | sed -E 's/:[0-9]+:[0-9]+$//' \
  | sort | uniq -c | sort -rn

WARNING_TOTAL="$(warning_sites | wc -l | tr -d ' ')"
echo "=== total unique warning-level strict-concurrency sites ==="
echo "$WARNING_TOTAL"

echo "=== non-Sendable compile errors (should stay empty) ==="
OTHER_ERRORS="$(grep -E "^/.*\.swift:[0-9]+:[0-9]+: error: " "$LOG" | grep -v "Sendable")"
echo "$OTHER_ERRORS" | head -20

FAILED=0

if [ "$ASSERT" = "1" ]; then
  # Under the committed `.v6` mode a green build IS the invariant, so any
  # non-zero status fails the gate — including a failure that emitted none of
  # the per-file diagnostics this script can read (missing toolchain, manifest
  # parse, dependency resolution, link), which would otherwise be
  # indistinguishable from "zero sites".
  if [ "$BUILD_RC" != "0" ]; then
    echo "GATE FAIL: the JsBaoClient target does not build under the Swift 6 language mode (exit $BUILD_RC)." >&2
    if [ "$TOTAL" = "0" ] && [ -z "$OTHER_ERRORS" ]; then
      echo "=== the build emitted no per-file diagnostics; last 20 log lines ===" >&2
      tail -20 "$LOG" >&2
    fi
    FAILED=1
  fi

  if [ -n "$OTHER_ERRORS" ]; then
    echo "GATE FAIL: the .v6 build has non-Sendable compile errors, so the counts above are not trustworthy." >&2
    FAILED=1
  fi

  if [ -n "$MAX_SITES" ] && [ "$TOTAL" -gt "$MAX_SITES" ]; then
    echo "GATE FAIL: $TOTAL unique .v6 Sendable sites, budget is $MAX_SITES." >&2
    FAILED=1
  fi

  if [ -n "$MAX_WARNING_SITES" ] && [ "$WARNING_TOTAL" -gt "$MAX_WARNING_SITES" ]; then
    echo "GATE FAIL: $WARNING_TOTAL unique warning-level strict-concurrency sites in Sources/JsBaoClient, budget is $MAX_WARNING_SITES." >&2
    relative_warning_sites >&2
    FAILED=1
  fi

  for path in ${REQUIRE_ZERO[@]+"${REQUIRE_ZERO[@]}"}; do
    count="$(sites_for_file "$path" | wc -l | tr -d ' ')"
    if [ "$count" -gt 0 ]; then
      echo "GATE FAIL: $path must be at zero .v6 Sendable sites, found $count." >&2
      sites_for_file "$path" >&2
      FAILED=1
    fi
  done

  if [ "$FAILED" = "0" ]; then
    echo "=== gate: PASS ==="
  fi
fi

rm -f "$LOG"
exit "$FAILED"
