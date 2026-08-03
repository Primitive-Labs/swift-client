#!/usr/bin/env bash
#
# Regression gate for the Swift 6 language mode on the `JsBaoClient` target.
#
# The target ships in `.v6` (see the comment in `Package.swift`; the flip
# landed in #1946, Phase F of the concurrency-modernization epic). The
# compiler is therefore the real enforcement now — a `Sendable` violation in
# `Sources/JsBaoClient` is a build error, not a counted diagnostic. What this
# script adds on top of `swift build` is:
#
#   * it proves the mode is still committed before it believes a clean build
#     (a revert to `.v5` would otherwise report zero sites and read as PASS);
#   * it attributes the errors per file, which is what makes a regression
#     readable at a glance;
#   * it fails with a gate-shaped message from `run-tests.sh`, before the
#     suite runs, instead of somewhere inside the test build output.
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
#   scripts/v6-sendable-gate.sh --require-zero <f>… # fail if any listed file has a site
#
# Exit status:
#   With neither `--max` nor `--require-zero`, the script only measures and
#   exits 0 whenever the measurement completed — the counts are the result,
#   not the exit code.
#
#   With `--max` and/or `--require-zero`, the script is an ASSERTION and exits
#   non-zero on a regression. `run-tests.sh` invokes it that way (`--max 0`)
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
REQUIRE_ZERO=()
ASSERT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --raw)
      RAW_LOG="${2:?--raw needs a path}"; shift 2 ;;
    --max)
      MAX_SITES="${2:?--max needs a number}"; ASSERT=1; shift 2 ;;
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
# out of the resolved manifest rather than grepping for the source text: a
# `.swiftLanguageMode(.v6)` line that drifted onto some other target would
# still match a grep, and the JsBaoClient build would then run in `.v5`, find
# nothing, and report PASS.
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

modes = [
    setting["kind"]["swiftLanguageMode"]["_0"]
    for setting in target.get("settings", [])
    if "swiftLanguageMode" in setting["kind"]
]
if modes != ["6"]:
    sys.exit(
        "GATE FAIL: the JsBaoClient target is not in the Swift 6 language mode "
        f"(swiftLanguageMode settings: {modes or 'none'}). The gate would report "
        "zero sites for the wrong reason."
    )

# The flip is target-scoped by design; a package-wide default of .v6 would
# silently pull the test targets in with it.
package_modes = manifest.get("swiftLanguageVersions")
if package_modes != ["5"]:
    sys.exit(
        "GATE FAIL: the package-level swiftLanguageModes pin must stay [.v5] so "
        f"the flip stays scoped to JsBaoClient (found: {package_modes})."
    )
PY
[ $? = 0 ] || exit 2

LOG="$(mktemp -t v6-build-log)"
swift build --target JsBaoClient > "$LOG" 2>&1
BUILD_RC=$?
if [ -n "$RAW_LOG" ]; then cp "$LOG" "$RAW_LOG"; fi

# Only the diagnostic HEADER lines carry a `path:line:col:` prefix; the
# swiftc caret/underline continuation lines repeat the message without one,
# so anchoring on `^/` is what makes the count "unique site", not "unique
# mention".
sites() {
  grep -E "^/.*\.swift:[0-9]+:[0-9]+: error: .*Sendable" "$LOG" \
    | sed -E 's/^(.*\.swift:[0-9]+:[0-9]+): error:.*$/\1/' \
    | sort -u
}

relative_sites() {
  sites | sed -E 's#^.*/Sources/JsBaoClient/##'
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
