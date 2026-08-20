#!/bin/sh
set -eu

# BMS code coverage report generator.
# Builds the CUnit test suite with GCOV instrumentation, runs it, then
# aggregates per-file gcov results into a single summary report.
#
# Does not modify any production .c/.h files (test-side only, per
# COVERAGE_BOOST_README.md).

COVERAGE_DIR="analysis/coverage"
REPORT="coverage_summary.txt"
EXECUTABLE="cunit_coverage"
BAR="======================================================================"
RULE="----------------------------------------------------------------------"

command -v gcc >/dev/null 2>&1 || {
    echo "ERROR: gcc is not installed or not in PATH." >&2
    exit 1
}
command -v gcov >/dev/null 2>&1 || {
    echo "ERROR: gcov is not installed or not in PATH." >&2
    exit 1
}

PROJECT_DIR=$(pwd -P)
GCOV_VERSION=$(gcov --version | head -n 1)

# ---------------------------------------------------------------------
# Clean up artifacts from any previous run
# ---------------------------------------------------------------------
rm -rf "$COVERAGE_DIR"
mkdir -p "$COVERAGE_DIR"
rm -f ./*.gcda ./*.gcno ./*.gcov ./*.o "$EXECUTABLE" "$REPORT"

# ---------------------------------------------------------------------
# Discover sources dynamically instead of hardcoding a list, so newly
# added modules/tests (e.g. graph_management.c, test_graph.c) are
# always picked up automatically.
# ---------------------------------------------------------------------
UTILITY_SOURCE="utility.c"
[ -f "utility_updated.c" ] && UTILITY_SOURCE="utility_updated.c"

APP_SOURCES=$(find . -maxdepth 1 -name '*.c' \
    ! -name 'test_*.c' \
    ! -name 'main.c' \
    ! -name 'logging_smoke.c' \
    ! -name 'utility.c' \
    ! -name 'utility_updated.c' \
    | sed 's|^\./||' | sort)
APP_SOURCES=$(printf '%s\n%s\n' "$APP_SOURCES" "$UTILITY_SOURCE")

TEST_SOURCES=$(find . -maxdepth 1 -name 'test_*.c' | sed 's|^\./||' | sort)

if [ -z "$TEST_SOURCES" ]; then
    echo "ERROR: no test_*.c files found in $PROJECT_DIR; nothing to build." >&2
    exit 1
fi

echo "$BAR"
echo "                         BMS CODE COVERAGE"
echo "$BAR"
echo ""
echo "Building CUnit tests with GCOV instrumentation..."

# Compile every source to its OWN object file with a separate -c step.
# IMPORTANT: compiling+linking many sources in a single "gcc ... -o exe"
# invocation makes gcc name the .gcno notes files "<exe>-<source>.gcno"
# instead of "<source>.gcno". A later plain "gcov <source>.c" then can't
# find its notes file (silently reports 0/0 for every file). Compiling
# each source separately keeps the notes files plainly named so gcov can
# find them by default.
OBJS=""
for SRC in $APP_SOURCES $TEST_SOURCES; do
    if [ ! -f "$SRC" ]; then
        echo "ERROR: expected source '$SRC' not found in $PROJECT_DIR." >&2
        exit 1
    fi
    OBJ="${SRC%.c}.o"
    gcc -std=c11 -O0 -g --coverage -Wall -Wextra -Wpedantic -pthread \
        -c "$SRC" -o "$OBJ"
    OBJS="$OBJS $OBJ"
done

# shellcheck disable=SC2086
gcc --coverage -pthread $OBJS -lcunit -o "$EXECUTABLE"
echo "Build successful."
echo ""
echo "Running CUnit tests..."
echo ""

TEST_RC=0
"./$EXECUTABLE" | tee "$COVERAGE_DIR/cunit_test_output.txt" || TEST_RC=$?
[ "${PIPESTATUS_UNUSED:-0}" = "0" ] || true

echo ""
echo "Generating GCOV reports..."
echo ""

# ---------------------------------------------------------------------
# Run gcov per application source and aggregate the results.
# ---------------------------------------------------------------------
TOTAL_LINE_COV=0;  TOTAL_LINE_TOT=0
TOTAL_FUNC_COV=0;  TOTAL_FUNC_TOT=0
TOTAL_BRANCH_COV=0; TOTAL_BRANCH_TOT=0
USABLE_COUNT=0
ERROR_COUNT=0
ERROR_LIST=""
RAW_LOG="$COVERAGE_DIR/gcov_raw_output.txt"
: > "$RAW_LOG"

for SRC in $APP_SOURCES; do
    [ -f "$SRC" ] || continue
    BASE=${SRC%.c}
    GCNO="${BASE}.gcno"

    {
        echo "### $SRC"
    } >> "$RAW_LOG"

    if [ ! -f "$GCNO" ]; then
        ERROR_COUNT=$((ERROR_COUNT + 1))
        ERROR_LIST="$ERROR_LIST
  $SRC : no $GCNO produced (source was not compiled with --coverage)"
        echo "(no .gcno file found)" >> "$RAW_LOG"
        continue
    fi

    GCOV_STDOUT=$(gcov -b -f -o . "$SRC" 2>>"$RAW_LOG") || true
    echo "$GCOV_STDOUT" >> "$RAW_LOG"

    # Parse this file's gcov summary. Reads Function/File blocks and
    # extracts line, branch and per-function counts. A function counts
    # as "covered" if its executed-lines percentage is > 0. Branch
    # totals stay 0/0 if gcov reports "No branches" for the file.
    RESULT=$(printf '%s\n' "$GCOV_STDOUT" | awk '
        BEGIN { ctx="none"; seen=0; taken=0; flc=0; flt=0; fnc=0; fnt=0; brc=0; brt=0 }
        /^Function / { ctx="func"; next }
        /^File /     { ctx="file"; seen=1; next }
        /^Lines executed:/ {
            line=$0; sub(/^Lines executed:/, "", line)
            split(line, p, "%"); pct=p[1]+0
            rest=p[2]; sub(/^ of /, "", rest); tot=rest+0
            if (ctx=="func") {
                fnt++
                if (pct>0) fnc++
            } else if (ctx=="file" && taken==0) {
                flt=tot; flc=int(pct*tot/100+0.5); taken=1
            }
            next
        }
        /^Branches executed:/ {
            if (ctx=="file") {
                line=$0; sub(/^Branches executed:/, "", line)
                split(line, p, "%"); pct=p[1]+0
                rest=p[2]; sub(/^ of /, "", rest); tot=rest+0
                brt=tot; brc=int(pct*tot/100+0.5)
            }
            next
        }
        END { printf "%d %d %d %d %d %d %d\n", flc, flt, fnc, fnt, brc, brt, seen }
    ')

    set -- $RESULT
    F_LINE_COV=$1; F_LINE_TOT=$2; F_FUNC_COV=$3; F_FUNC_TOT=$4
    F_BR_COV=$5;   F_BR_TOT=$6;   F_SEEN=$7

    if [ "$F_SEEN" = "1" ]; then
        USABLE_COUNT=$((USABLE_COUNT + 1))
        TOTAL_LINE_COV=$((TOTAL_LINE_COV + F_LINE_COV))
        TOTAL_LINE_TOT=$((TOTAL_LINE_TOT + F_LINE_TOT))
        TOTAL_FUNC_COV=$((TOTAL_FUNC_COV + F_FUNC_COV))
        TOTAL_FUNC_TOT=$((TOTAL_FUNC_TOT + F_FUNC_TOT))
        TOTAL_BRANCH_COV=$((TOTAL_BRANCH_COV + F_BR_COV))
        TOTAL_BRANCH_TOT=$((TOTAL_BRANCH_TOT + F_BR_TOT))
    else
        ERROR_COUNT=$((ERROR_COUNT + 1))
        REASON=$(grep -m1 "cannot open\|version" "$RAW_LOG" | tail -n1)
        ERROR_LIST="$ERROR_LIST
  $SRC : ${REASON:-gcov produced no usable data for this file}"
    fi

    for G in ./*.gcov; do
        [ -f "$G" ] || continue
        mv -f "$G" "$COVERAGE_DIR/"
    done
done

# ---------------------------------------------------------------------
# Compute percentages and render the final report.
# ---------------------------------------------------------------------
REPORT_BODY=$(awk -v lc="$TOTAL_LINE_COV" -v lt="$TOTAL_LINE_TOT" \
    -v fc="$TOTAL_FUNC_COV" -v ft="$TOTAL_FUNC_TOT" \
    -v bc="$TOTAL_BRANCH_COV" -v bt="$TOTAL_BRANCH_TOT" \
    -v usable="$USABLE_COUNT" -v errors="$ERROR_COUNT" \
    -v proj="$PROJECT_DIR" -v gcovver="$GCOV_VERSION" \
    -v bar="$BAR" -v rule="$RULE" '
    function pct(cov, tot) { return (tot > 0) ? (cov * 100.0 / tot) : 0.0 }
    BEGIN {
        lp = pct(lc, lt); fp = pct(fc, ft); bp = pct(bc, bt)
        overall = (lp + fp + bp) / 3.0

        print bar
        print "                         BMS CODE COVERAGE"
        print bar
        print ""
        printf "%-8s: %s\n", "Project", proj
        printf "%-8s: %s\n", "gcov", gcovver
        print ""
        printf "Files with usable coverage data  : %d\n", usable
        printf "Files with gcov processing errors: %d\n", errors
        print ""
        printf "%-20s%12s%12s%14s\n", "Metric", "Covered", "Total", "Percentage"
        print rule
        printf "%-20s%12d%12d%13.2f%%\n", "Line coverage", lc, lt, lp
        printf "%-20s%12d%12d%13.2f%%\n", "Function coverage", fc, ft, fp
        printf "%-20s%12d%12d%13.2f%%\n", "Branch coverage", bc, bt, bp
        print ""
        print rule
        printf "Overall BMS coverage: %.2f%%\n", overall
        print rule
        print ""
        print "Calculation:"
        print "  Line     = executed lines / total lines"
        print "  Function = executed functions / total functions"
        print "  Branch   = executed branches / total branches"
        print "  Overall  = (Line + Function + Branch) / 3"
        print ""
        print bar
    }
')

printf '%s\n' "$REPORT_BODY" | tee "$REPORT"
{
    echo ""
    echo "Detailed summary saved to:"
    echo "$PROJECT_DIR/$REPORT"
} | tee -a "$REPORT"

if [ "$TOTAL_FUNC_TOT" -eq 0 ] && [ "$ERROR_COUNT" -gt 0 ]; then
    {
        echo ""
        echo "WARNING: gcov produced no function records."
    } | tee -a "$REPORT"
fi

if [ "$ERROR_COUNT" -gt 0 ]; then
    {
        echo ""
        echo "Files with gcov processing errors:"
        printf '%s\n' "$ERROR_LIST"
        echo ""
        echo "Run this diagnostic for one coverage unit:"
        echo "  gcov -f -b -c -o \"$PROJECT_DIR\" \"<name>.gcno\""
        echo ""
        echo "If it says 'no functions found' or reports a gcno/gcda version"
        echo "mismatch, the gcc that compiled the sources and the gcov being"
        echo "run here are different versions, or the .gcno/.gcda are stale."
        echo "Re-run this script from a clean tree (rm -f ./*.gcno ./*.gcda)"
        echo "with a gcov that matches \`gcc --version\`."
    } | tee -a "$REPORT"
fi

echo ""
echo "Raw per-file gcov output: $COVERAGE_DIR/gcov_raw_output.txt"
echo "Annotated .gcov files   : $COVERAGE_DIR/"
echo "CUnit test output       : $COVERAGE_DIR/cunit_test_output.txt"

if [ "$TEST_RC" -ne 0 ]; then
    echo ""
    echo "WARNING: One or more CUnit tests failed (exit code $TEST_RC)."
    exit "$TEST_RC"
fi
