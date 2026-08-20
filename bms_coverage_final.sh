#!/bin/sh

# ============================================================
# BMS CODE COVERAGE REPORT - CORRECTED
# GCC/gcov 14.x
#
# IMPORTANT:
# gcov -i writes the intermediate records to *.gcov files.
# It does NOT put the function/lcount/branch records on stdout.
#
# This version reads those generated *.gcov files, so function
# coverage will not incorrectly become 0/0.
# ============================================================

PROJECT_DIR="$(pwd)"
OUTPUT_FILE="$PROJECT_DIR/coverage_percentage.txt"
GCOV_CMD="gcov"

echo "============================================================"
echo "                    BMS CODE COVERAGE"
echo "============================================================"
echo
echo "Project : $PROJECT_DIR"

if ! command -v "$GCOV_CMD" >/dev/null 2>&1
then
    echo
    echo "ERROR: gcov is not installed or not in PATH."
    exit 1
fi

GCOV_VERSION=$("$GCOV_CMD" --version 2>/dev/null | head -1)
echo "gcov    : $GCOV_VERSION"
echo

TMP_DIR="${TMPDIR:-/tmp}/bms_coverage_$$"
mkdir -p "$TMP_DIR" || exit 1

trap 'rm -rf "$TMP_DIR"' 0 1 2 3 15

TOTAL_LINE_FOUND=0
TOTAL_LINE_EXECUTED=0

TOTAL_FUNC_FOUND=0
TOTAL_FUNC_EXECUTED=0

TOTAL_BRANCH_FOUND=0
TOTAL_BRANCH_EXECUTED=0

DATA_FILES=0
FAILED_FILES=0

GCNO_LIST="$TMP_DIR/gcno_list"

find "$PROJECT_DIR" -type f -name "*.gcno" \
    ! -path "$TMP_DIR/*" \
    ! -path "*/.git/*" \
    | sort > "$GCNO_LIST"

if [ ! -s "$GCNO_LIST" ]
then
    echo
    echo "ERROR: No .gcno files found."
    echo
    echo "Run:"
    echo "  find . -type f -name '*.gcno'"
    exit 1
fi

# ------------------------------------------------------------
# Process each .gcno + matching .gcda
# ------------------------------------------------------------

while IFS= read -r GCNO_FILE
do
    GCNO_DIR=$(dirname "$GCNO_FILE")
    GCNO_NAME=$(basename "$GCNO_FILE")
    GCNO_BASE=${GCNO_NAME%.gcno}
    GCDA_FILE="$GCNO_DIR/$GCNO_BASE.gcda"

    # Only use coverage units having both files.
    if [ ! -f "$GCDA_FILE" ]
    then
        continue
    fi

    DATA_FILES=$((DATA_FILES + 1))

    RUN_DIR="$TMP_DIR/gcov_$DATA_FILES"
    mkdir -p "$RUN_DIR"

    GCOV_STDOUT="$RUN_DIR/gcov_stdout.txt"
    GCOV_STDERR="$RUN_DIR/gcov_stderr.txt"

    # --------------------------------------------------------
    # gcov -i creates an intermediate *.gcov file.
    #
    # -i = intermediate format
    # -b = branch records
    # -c = branch counts
    # -o = directory containing .gcno/.gcda
    #
    # We run from RUN_DIR so generated *.gcov files do not
    # interfere with the project directory.
    # --------------------------------------------------------

    (
        cd "$RUN_DIR" || exit 1
        "$GCOV_CMD" -i -b -c \
            -o "$GCNO_DIR" \
            "$GCNO_BASE.gcno"
    ) >"$GCOV_STDOUT" 2>"$GCOV_STDERR"

    GCOV_FILES="$RUN_DIR/gcov_files"

    find "$RUN_DIR" -maxdepth 1 -type f -name "*.gcov" \
        | sort > "$GCOV_FILES"

    if [ ! -s "$GCOV_FILES" ]
    then
        FAILED_FILES=$((FAILED_FILES + 1))
        continue
    fi

    # --------------------------------------------------------
    # Read ALL intermediate *.gcov files produced for this
    # coverage data unit.
    # --------------------------------------------------------

    while IFS= read -r GCOV_FILE
    do

        # ----------------------------------------------------
        # LINE COVERAGE
        #
        # lcount:<line>,<execution_count>
        # ----------------------------------------------------

        LINE_TOTAL=$(awk '
            /^lcount:/ {
                x=$0
                sub(/^lcount:[^,]*,/, "", x)

                if (x ~ /^[0-9]+$/) {
                    total++
                    if (x > 0)
                        executed++
                }
            }
            END {
                printf "%d %d\n", total, executed
            }
        ' "$GCOV_FILE")

        LINE_FOUND=$(echo "$LINE_TOTAL" | awk '{print $1}')
        LINE_EXECUTED=$(echo "$LINE_TOTAL" | awk '{print $2}')

        TOTAL_LINE_FOUND=$((TOTAL_LINE_FOUND + LINE_FOUND))
        TOTAL_LINE_EXECUTED=$((TOTAL_LINE_EXECUTED + LINE_EXECUTED))

        # ----------------------------------------------------
        # FUNCTION COVERAGE
        #
        # function:<line>,<execution_count>,<function_name>
        #
        # Every function: record = one function.
        # execution_count > 0 = executed function.
        # ----------------------------------------------------

        FUNC_TOTAL=$(awk '
            /^function:/ {
                x=$0

                # Remove "function:<line>,"
                sub(/^function:[^,]*,/, "", x)

                # Get execution count before next comma.
                count=x
                sub(/,.*/, "", count)

                if (count ~ /^[0-9]+$/) {
                    total++

                    if (count > 0)
                        executed++
                }
            }
            END {
                printf "%d %d\n", total, executed
            }
        ' "$GCOV_FILE")

        FUNC_FOUND=$(echo "$FUNC_TOTAL" | awk '{print $1}')
        FUNC_EXECUTED=$(echo "$FUNC_TOTAL" | awk '{print $2}')

        TOTAL_FUNC_FOUND=$((TOTAL_FUNC_FOUND + FUNC_FOUND))
        TOTAL_FUNC_EXECUTED=$((TOTAL_FUNC_EXECUTED + FUNC_EXECUTED))

        # ----------------------------------------------------
        # BRANCH COVERAGE
        #
        # branch:<line>,taken
        # branch:<line>,nottaken
        # branch:<line>,notexec
        #
        # taken/nottaken = executed branches
        # notexec          = unexecuted branches
        # ----------------------------------------------------

        BRANCH_TOTAL=$(awk '
            /^branch:/ {
                x=$0
                sub(/^branch:[^,]*,/, "", x)

                total++

                if (x == "taken" || x == "nottaken")
                    executed++
            }
            END {
                printf "%d %d\n", total, executed
            }
        ' "$GCOV_FILE")

        BRANCH_FOUND=$(echo "$BRANCH_TOTAL" | awk '{print $1}')
        BRANCH_EXECUTED=$(echo "$BRANCH_TOTAL" | awk '{print $2}')

        TOTAL_BRANCH_FOUND=$((TOTAL_BRANCH_FOUND + BRANCH_FOUND))
        TOTAL_BRANCH_EXECUTED=$((TOTAL_BRANCH_EXECUTED + BRANCH_EXECUTED))

    done < "$GCOV_FILES"

done < "$GCNO_LIST"

# ------------------------------------------------------------
# Calculate percentages
# ------------------------------------------------------------

if [ "$TOTAL_LINE_FOUND" -gt 0 ]
then
    LINE_COVERAGE=$(awk \
        -v e="$TOTAL_LINE_EXECUTED" \
        -v t="$TOTAL_LINE_FOUND" \
        'BEGIN { printf "%.2f", (e/t)*100 }')
else
    LINE_COVERAGE="0.00"
fi

if [ "$TOTAL_FUNC_FOUND" -gt 0 ]
then
    FUNCTION_COVERAGE=$(awk \
        -v e="$TOTAL_FUNC_EXECUTED" \
        -v t="$TOTAL_FUNC_FOUND" \
        'BEGIN { printf "%.2f", (e/t)*100 }')
else
    FUNCTION_COVERAGE="0.00"
fi

if [ "$TOTAL_BRANCH_FOUND" -gt 0 ]
then
    BRANCH_COVERAGE=$(awk \
        -v e="$TOTAL_BRANCH_EXECUTED" \
        -v t="$TOTAL_BRANCH_FOUND" \
        'BEGIN { printf "%.2f", (e/t)*100 }')
else
    BRANCH_COVERAGE="0.00"
fi

# Keep the same definition used in your previous report.
OVERALL_COVERAGE=$(awk \
    -v l="$LINE_COVERAGE" \
    -v f="$FUNCTION_COVERAGE" \
    -v b="$BRANCH_COVERAGE" \
    'BEGIN { printf "%.2f", (l+f+b)/3 }')

# ------------------------------------------------------------
# Display final report
# ------------------------------------------------------------

{
echo "============================================================"
echo "                    BMS CODE COVERAGE"
echo "============================================================"
echo
echo "Project : $PROJECT_DIR"
echo "gcov    : $GCOV_VERSION"
echo
echo "Files with usable coverage data : $DATA_FILES"
if [ "$FAILED_FILES" -gt 0 ]
then
    echo "Files with gcov processing errors: $FAILED_FILES"
fi
echo
echo "Metric              Covered       Total       Percentage"
echo "------------------------------------------------------------"
printf "%-20s %8s %11s %13s\n" \
    "Line coverage" \
    "$TOTAL_LINE_EXECUTED" \
    "$TOTAL_LINE_FOUND" \
    "$LINE_COVERAGE%"
printf "%-20s %8s %11s %13s\n" \
    "Function coverage" \
    "$TOTAL_FUNC_EXECUTED" \
    "$TOTAL_FUNC_FOUND" \
    "$FUNCTION_COVERAGE%"
printf "%-20s %8s %11s %13s\n" \
    "Branch coverage" \
    "$TOTAL_BRANCH_EXECUTED" \
    "$TOTAL_BRANCH_FOUND" \
    "$BRANCH_COVERAGE%"
echo
echo "------------------------------------------------------------"
echo "Overall BMS coverage: $OVERALL_COVERAGE%"
echo "------------------------------------------------------------"
echo
echo "Calculation:"
echo "  Line     = executed lines / total lines"
echo "  Function = executed functions / total functions"
echo "  Branch   = executed branches / total branches"
echo "  Overall  = (Line + Function + Branch) / 3"
echo
echo "============================================================"
} | tee "$OUTPUT_FILE"

echo
echo "Detailed summary saved to:"
echo "$OUTPUT_FILE"

# ------------------------------------------------------------
# Diagnostic hint if function data is still unavailable.
# ------------------------------------------------------------

if [ "$TOTAL_FUNC_FOUND" -eq 0 ]
then
    echo
    echo "WARNING: gcov produced no function records."
    echo
    echo "Run this diagnostic for one coverage unit:"
    echo "  gcov -f -b -c -o \"<directory-containing-gcno-gcda>\" \"<name>.gcno\""
    echo
    echo "If it says 'no functions found' or reports a gcno/gcda"
    echo "version mismatch, the coverage files were generated"
    echo "with a different/incompatible GCC version."
fi
