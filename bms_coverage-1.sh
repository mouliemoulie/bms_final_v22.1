#!/bin/bash
# bms_coverage.sh
# Calculate Line / Function / Branch / Overall coverage using existing gcov data.
# Requires: gcc/gcov. No gcovr installation is needed.

set -u

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || {
    echo "ERROR: Cannot access directory: $1"
    exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REPORT="$ROOT/coverage_percentage.txt"

echo "============================================================"
echo " BMS CODE COVERAGE"
echo "============================================================"
echo "Project : $ROOT"
echo "gcov    : $(gcov --version | head -1)"
echo

# Find .gcno files which also have a matching .gcda.
# This deliberately does not require gcovr.
mapfile -t GCNO_FILES < <(
    find "$ROOT" -type f -name '*.gcno' -print | sort
)

if [ "${#GCNO_FILES[@]}" -eq 0 ]; then
    echo "ERROR: No .gcno files found."
    echo
    echo "Check with:"
    echo "  find \"$ROOT\" -type f \\( -name '*.gcno' -o -name '*.gcda' \\)"
    exit 2
fi

total_line_hit=0
total_line_all=0
total_func_hit=0
total_func_all=0
total_branch_hit=0
total_branch_all=0
processed=0

# Store per-file results for the final table.
RESULTS="$TMP/results.txt"
: > "$RESULTS"

for gcno in "${GCNO_FILES[@]}"; do
    dir="$(dirname "$gcno")"
    base="$(basename "$gcno" .gcno)"
    gcda="$dir/$base.gcda"

    # A gcno without gcda has no runtime execution data.
    if [ ! -f "$gcda" ]; then
        continue
    fi

    # gcov expects the gcno/gcda pair and the referenced source files.
    # Run it from the directory containing the coverage data.
    log="$TMP/gcov_${processed}.log"

    (
        cd "$dir" || exit 10
        gcov -b -c -f "$(basename "$gcno")"
    ) >"$log" 2>&1

    # Ignore files for which gcov could not produce executable coverage.
    if ! grep -qE 'Lines executed:[0-9.]+% of [0-9]+' "$log"; then
        continue
    fi

    line_line="$(grep -E 'Lines executed:[0-9.]+% of [0-9]+' "$log" | tail -1)"
    func_line="$(grep -E 'Functions executed:[0-9.]+% of [0-9]+' "$log" | tail -1)"
    branch_line="$(grep -E 'Branches executed:[0-9.]+% of [0-9]+' "$log" | tail -1)"

    # Extract covered percentage and total count.
    line_pct="$(echo "$line_line" | sed -E 's/.*Lines executed:([0-9.]+)%.*/\1/')"
    line_all="$(echo "$line_line" | sed -E 's/.*% of ([0-9]+).*/\1/')"

    if [ -n "$func_line" ]; then
        func_pct="$(echo "$func_line" | sed -E 's/.*Functions executed:([0-9.]+)%.*/\1/')"
        func_all="$(echo "$func_line" | sed -E 's/.*% of ([0-9]+).*/\1/')"
    else
        func_pct="0"
        func_all="0"
    fi

    if [ -n "$branch_line" ]; then
        branch_pct="$(echo "$branch_line" | sed -E 's/.*Branches executed:([0-9.]+)%.*/\1/')"
        branch_all="$(echo "$branch_line" | sed -E 's/.*% of ([0-9]+).*/\1/')"
    else
        branch_pct="0"
        branch_all="0"
    fi

    # Convert percentage + total into an integer covered count.
    # gcov percentages are rounded, so this is an approximation only.
    line_hit="$(awk -v p="$line_pct" -v n="$line_all" 'BEGIN {printf "%.0f", p*n/100}')"
    func_hit="$(awk -v p="$func_pct" -v n="$func_all" 'BEGIN {printf "%.0f", p*n/100}')"
    branch_hit="$(awk -v p="$branch_pct" -v n="$branch_all" 'BEGIN {printf "%.0f", p*n/100}')"

    total_line_hit=$((total_line_hit + line_hit))
    total_line_all=$((total_line_all + line_all))
    total_func_hit=$((total_func_hit + func_hit))
    total_func_all=$((total_func_all + func_all))
    total_branch_hit=$((total_branch_hit + branch_hit))
    total_branch_all=$((total_branch_all + branch_all))
    processed=$((processed + 1))

    rel="${gcno#$ROOT/}"
    printf '%s|%s|%s|%s\n' "$rel" "$line_pct" "$func_pct" "$branch_pct" >> "$RESULTS"
done

if [ "$processed" -eq 0 ]; then
    echo "ERROR: Found .gcno files, but no usable .gcda/.gcno pairs."
    echo
    echo "Found .gcno files: ${#GCNO_FILES[@]}"
    echo "Check the pairs with:"
    echo "  find \"$ROOT\" -type f \\( -name '*.gcno' -o -name '*.gcda' \\) | sort"
    exit 3
fi

line_total_pct="$(awk -v h="$total_line_hit" -v n="$total_line_all" 'BEGIN {if(n) printf "%.2f",100*h/n; else print "0.00"}')"
func_total_pct="$(awk -v h="$total_func_hit" -v n="$total_func_all" 'BEGIN {if(n) printf "%.2f",100*h/n; else print "0.00"}')"
branch_total_pct="$(awk -v h="$total_branch_hit" -v n="$total_branch_all" 'BEGIN {if(n) printf "%.2f",100*h/n; else print "0.00"}')"

# "Overall BMS coverage" = average of line/function/branch percentages.
# This is a simple reporting metric, not a standard gcov metric.
overall_pct="$(awk -v l="$line_total_pct" -v f="$func_total_pct" -v b="$branch_total_pct" \
    'BEGIN {count=0; sum=0; if(l>=0){sum+=l;count++} if(f>=0){sum+=f;count++} if(b>=0){sum+=b;count++} if(count) printf "%.2f",sum/count; else print "0.00"}')"

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
    printf 'Line coverage      : %s%% (%d/%d)\n' "$line_total_pct" "$total_line_hit" "$total_line_all"
    printf 'Function coverage  : %s%% (%d/%d)\n' "$func_total_pct" "$total_func_hit" "$total_func_all"
    printf 'Branch coverage    : %s%% (%d/%d)\n' "$branch_total_pct" "$total_branch_hit" "$total_branch_all"
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
echo "Note: Overall BMS coverage is the arithmetic mean of line,"
echo "function, and branch coverage. gcov itself reports these metrics"
echo "separately; there is no official single 'overall' gcov percentage."
