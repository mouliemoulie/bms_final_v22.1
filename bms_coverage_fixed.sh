#!/bin/sh
# bms_coverage_fixed.sh
# Calculates line, function, branch and a simple overall BMS coverage
# using the existing .gcno/.gcda files and gcov.
#
# Usage:
#   sh bms_coverage_fixed.sh [PROJECT_ROOT]
#
# Example:
#   sh bms_coverage_fixed.sh .
#
# No gcovr installation is required.

set -u

ROOT=${1:-.}
ROOT=$(cd "$ROOT" 2>/dev/null && pwd) || {
    echo "ERROR: Cannot access project directory: $1"
    exit 1
}

command -v gcov >/dev/null 2>&1 || {
    echo "ERROR: gcov is not installed or is not in PATH."
    exit 1
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/bms_coverage.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' 0 1 2 3 15

REPORT="$ROOT/coverage_percentage.txt"
GCOV_LOG="$TMP/gcov.log"
RESULTS="$TMP/results.txt"
: > "$RESULTS"

echo "============================================================"
echo " BMS CODE COVERAGE"
echo "============================================================"
echo "Project : $ROOT"
echo "gcov    : $(gcov --version | head -1)"
echo

GCNO_COUNT=$(find "$ROOT" -type f -name '*.gcno' 2>/dev/null | wc -l | tr -d ' ')
if [ "$GCNO_COUNT" -eq 0 ]; then
    echo "ERROR: No .gcno files found under:"
    echo "  $ROOT"
    echo
    echo "Run:"
    echo "  find \"$ROOT\" -type f \\( -name '*.gcno' -o -name '*.gcda' \\) | sort"
    exit 2
fi

total_line_hit=0
total_line_all=0
total_func_hit=0
total_func_all=0
total_branch_hit=0
total_branch_all=0
processed=0

# gcov prints percentages, not covered/total counts in its summary.
# We therefore derive the counts from the percentage and total count.
# Totals are rounded by gcov, so the aggregate counts are approximate.
for gcno in $(find "$ROOT" -type f -name '*.gcno' -print 2>/dev/null | sort); do
    dir=$(dirname "$gcno")
    file=$(basename "$gcno")

    # Coverage is useful only when runtime data exists.
    gcda="$dir/${file%.gcno}.gcda"
    if [ ! -f "$gcda" ]; then
        continue
    fi

    : > "$GCOV_LOG"

    # -b = branch information
    # -c = branch/arc execution counts
    # -f = function coverage
    #
    # -o "$dir" explicitly tells gcov where the .gcno/.gcda data lives.
    # This avoids the "cannot open notes file" problem caused by running
    # gcov from a different directory.
    (
        cd "$dir" || exit 10
        gcov -b -c -f -o "$dir" "$file"
    ) >"$GCOV_LOG" 2>&1

    # Keep a copy of failed gcov output for troubleshooting.
    if ! grep -q 'Lines executed:' "$GCOV_LOG"; then
        echo "WARNING: gcov could not process $gcno"
        sed -n '1,8p' "$GCOV_LOG"
        echo
        continue
    fi

    # A single .gcno normally maps to one source/object compilation unit.
    # Use the final summary emitted by gcov for that invocation.
    line_line=$(grep 'Lines executed:' "$GCOV_LOG" | tail -1)
    func_line=$(grep 'Functions executed:' "$GCOV_LOG" | tail -1)
    branch_line=$(grep 'Branches executed:' "$GCOV_LOG" | tail -1)

    line_pct=$(printf '%s\n' "$line_line" |
        sed -n 's/.*Lines executed:\([0-9.][0-9.]*\)%.*/\1/p')
    line_all=$(printf '%s\n' "$line_line" |
        sed -n 's/.*% of \([0-9][0-9]*\).*/\1/p')

    func_pct=$(printf '%s\n' "$func_line" |
        sed -n 's/.*Functions executed:\([0-9.][0-9.]*\)%.*/\1/p')
    func_all=$(printf '%s\n' "$func_line" |
        sed -n 's/.*% of \([0-9][0-9]*\).*/\1/p')

    branch_pct=$(printf '%s\n' "$branch_line" |
        sed -n 's/.*Branches executed:\([0-9.][0-9.]*\)%.*/\1/p')
    branch_all=$(printf '%s\n' "$branch_line" |
        sed -n 's/.*% of \([0-9][0-9]*\).*/\1/p')

    [ -n "$line_pct" ] || continue
    [ -n "$line_all" ] || continue

    [ -n "$func_pct" ] || func_pct=0
    [ -n "$func_all" ] || func_all=0
    [ -n "$branch_pct" ] || branch_pct=0
    [ -n "$branch_all" ] || branch_all=0

    line_hit=$(awk -v p="$line_pct" -v n="$line_all" \
        'BEGIN { printf "%.0f", p*n/100 }')
    func_hit=$(awk -v p="$func_pct" -v n="$func_all" \
        'BEGIN { printf "%.0f", p*n/100 }')
    branch_hit=$(awk -v p="$branch_pct" -v n="$branch_all" \
        'BEGIN { printf "%.0f", p*n/100 }')

    total_line_hit=$((total_line_hit + line_hit))
    total_line_all=$((total_line_all + line_all))
    total_func_hit=$((total_func_hit + func_hit))
    total_func_all=$((total_func_all + func_all))
    total_branch_hit=$((total_branch_hit + branch_hit))
    total_branch_all=$((total_branch_all + branch_all))
    processed=$((processed + 1))

    rel=${gcno#"$ROOT"/}
    printf '%s|%s|%s|%s\n' "$rel" "$line_pct" "$func_pct" "$branch_pct" >> "$RESULTS"
done

if [ "$processed" -eq 0 ]; then
    echo "ERROR: .gcno files were found, but no usable .gcda/.gcno pairs were processed."
    echo
    echo "Check:"
    echo "  find \"$ROOT\" -type f \\( -name '*.gcno' -o -name '*.gcda' \\) | sort"
    echo
    echo "Important: .gcda files must be generated after the tests/program have run."
    exit 3
fi

line_total_pct=$(awk -v h="$total_line_hit" -v n="$total_line_all" \
    'BEGIN { if (n > 0) printf "%.2f", 100*h/n; else printf "0.00" }')
func_total_pct=$(awk -v h="$total_func_hit" -v n="$total_func_all" \
    'BEGIN { if (n > 0) printf "%.2f", 100*h/n; else printf "0.00" }')
branch_total_pct=$(awk -v h="$total_branch_hit" -v n="$total_branch_all" \
    'BEGIN { if (n > 0) printf "%.2f", 100*h/n; else printf "0.00" }')

# There is no official single "overall gcov coverage" percentage.
# This project-level number is the arithmetic mean of the three metrics.
overall_pct=$(awk -v l="$line_total_pct" -v f="$func_total_pct" -v b="$branch_total_pct" \
    'BEGIN { printf "%.2f", (l+f+b)/3 }')

echo
echo "Files with usable coverage data : $processed"
echo
printf '%-24s %12s %12s %12s\n' "Metric" "Covered" "Total" "Percentage"
printf '%-24s %12d %12d %11s%%\n' "Line coverage" "$total_line_hit" "$total_line_all" "$line_total_pct"
printf '%-24s %12d %12d %11s%%\n' "Function coverage" "$total_func_hit" "$total_func_all" "$func_total_pct"
printf '%-24s %12d %12d %11s%%\n' "Branch coverage" "$total_branch_hit" "$total_branch_all" "$branch_total_pct"
echo "------------------------------------------------------------"
printf '%-24s %11s%%\n' "Overall BMS coverage" "$overall_pct"
echo

{
    echo "BMS CODE COVERAGE SUMMARY"
    echo "========================="
    echo "Project: $ROOT"
    echo
    printf 'Line coverage       : %s%% (%d/%d)\n' "$line_total_pct" "$total_line_hit" "$total_line_all"
    printf 'Function coverage   : %s%% (%d/%d)\n' "$func_total_pct" "$total_func_hit" "$total_func_all"
    printf 'Branch coverage     : %s%% (%d/%d)\n' "$branch_total_pct" "$total_branch_hit" "$total_branch_all"
    printf 'Overall BMS coverage: %s%%\n' "$overall_pct"
    echo
    echo "Per coverage-data file:"
    printf '%-55s %10s %10s %10s\n' "File" "Lines" "Functions" "Branches"
    while IFS='|' read -r f l fn b; do
        printf '%-55s %9s%% %9s%% %9s%%\n' "$f" "$l" "$fn" "$b"
    done < "$RESULTS"
} > "$REPORT"

echo "Detailed summary saved to:"
echo "  $REPORT"
echo
echo "If gcov still reports 'cannot open notes file', run:"
echo "  find \"$ROOT\" -type f \\( -name '*.gcno' -o -name '*.gcda' \\) | sort"
echo "and check that each .gcda has a matching .gcno in the expected directory."
