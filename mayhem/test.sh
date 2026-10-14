#!/usr/bin/env bash
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# Functional oracle: known-answer transpilations driven through the frozen sqlglot-cli ELF.
# Each case asserts the EXACT transpiled output — parsing + generation must actually run. Because the
# oracle exercises a *project* executable (not the spared system interpreter), the anti-reward-hacking
# neuter (LD_PRELOAD exit(0) into non-system binaries) makes sqlglot-cli emit nothing, so every case
# mismatches and this suite FAILS — i.e. a program stubbed to exit(0) does NOT pass.

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

CLI=/mayhem/sqlglot-cli
if [ ! -x "$CLI" ]; then
  echo "missing $CLI — build.sh should have frozen the transpile CLI" >&2
  emit_ctrf "sqlglot-transpile-kat" 0 1 0
  exit 1
fi

passed=0
failed=0

run_case() {
  local sql="$1" read="$2" write="$3" want="$4"
  local got
  got="$(printf '%s' "$sql" | "$CLI" "$read" "$write" 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: transpile($read->$write) [$sql] => [$got], want [$want]" >&2
  fi
}

run_case "select 1"                     ""      ""         "SELECT 1"
run_case "select a as b from t"         ""      ""         "SELECT a AS b FROM t"
run_case "select CAST(a as int) from t" ""      ""         "SELECT CAST(a AS INT) FROM t"
run_case "SELECT * FROM t WHERE x > 1"  "mysql" "postgres" "SELECT * FROM t WHERE x > 1"

emit_ctrf "sqlglot-transpile-kat" "$passed" "$failed" 0
