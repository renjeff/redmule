#!/bin/bash
# Verification sweep for fill_stall_q fix.
# Uses exact command sequence from build_environment.md.
# Run from repo root: bash scripts/run_sweep.sh 2>&1 | tee sweep_results.txt

set -e
cd "$(dirname "$0")/.."
source scripts/run_sim_env.sh

VSIM_DIR="target/sim/vsim"
RESULTS_DIR="$VSIM_DIR/sweep_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

PASS=0
FAIL=0
TIMEOUT_COUNT=0

run_test() {
    local tag="$1"
    local M="$2"
    local N="$3"
    local K="$4"
    local MX_ENABLE="${5:-0}"
    local MX_FORMAT="${6:-e5m2}"
    local transcript="$RESULTS_DIR/transcript_${tag}.txt"

    echo ""
    echo "========================================="
    echo "TEST: $tag  M=$M N=$N K=$K  MX=$MX_ENABLE fmt=$MX_FORMAT"
    echo "========================================="

    # 1. Golden (FP16 reference)
    make golden OP=gemm M=$M N=$N K=$K 2>&1 | tail -3

    if [ "$MX_ENABLE" = "1" ]; then
        # 2. MX headers + SW build
        make mx-headers M=$M N=$N K=$K MX_FORMAT=$MX_FORMAT MX_ENABLE=1 MX_SKIP_FP16=1 2>&1 | tail -3
        make sw-build M=$M N=$N K=$K MX_ENABLE=1 MX_FORMAT=$MX_FORMAT target=vsim 2>&1 | tail -3
    else
        # 2. FP16 SW build
        make sw-build M=$M N=$N K=$K target=vsim 2>&1 | tail -3
    fi

    # 3. Run sim
    local ret=0
    timeout 360 make hw-run target=vsim VsimFlags="-c -suppress 3009 +PERF_ENABLE=1" \
        > "$transcript" 2>&1 || ret=$?

    if [ $ret -eq 124 ]; then
        echo "  RESULT: TIMEOUT"
        TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
        return
    fi

    # Parse
    local errors; errors=$(grep -c "\[TB\] - Error" "$transcript" 2>/dev/null); errors=${errors:-0}
    local success; success=$(grep -c "\[TB\] - Success" "$transcript" 2>/dev/null); success=${success:-0}
    local perf_total=$(grep "\[PERF\] total cycles"  "$transcript" | grep -oP '\d+$' 2>/dev/null || echo "?")
    local perf_ratio=$(grep "\[PERF\] busy ratio"    "$transcript" | grep -oP '[\d.]+(?= %)' 2>/dev/null || echo "?")
    local eng_util=$(grep  "\[PERF\] engine util"    "$transcript" | grep -oP '[\d.]+(?= %)' 2>/dev/null || echo "?")
    local stalls=$(grep -c "\[TB\]\[STALL\]"         "$transcript" 2>/dev/null || echo 0)

    if [ "$success" -gt 0 ] && [ "$errors" -eq 0 ]; then
        echo "  RESULT: PASS"
        echo "  PERF  : total_cycles=$perf_total  busy=${perf_ratio}%  engine=${eng_util}%  stall_events=$stalls"
        PASS=$((PASS + 1))
    else
        echo "  RESULT: FAIL  (errors=$errors  success=$success)"
        tail -20 "$transcript"
        FAIL=$((FAIL + 1))
    fi
}

echo "Sweep start: $(date)"
echo "Results: $RESULTS_DIR"

# ---- FP8 E5M2 ----
run_test "fp8_64x64x96_random"  64 64  96 1 e5m2
run_test "fp8_32x64x64"         32 64  64 1 e5m2
run_test "fp8_64x64x64"         64 64  64 1 e5m2
run_test "fp8_64x64x128"        64 64 128 1 e5m2
run_test "fp8_64x64x192"        64 64 192 1 e5m2
run_test "fp8_32x64x96"         32 64  96 1 e5m2
run_test "fp8_96x64x96"         96 64  96 1 e5m2
run_test "fp8_64x96x64"         64 96  64 1 e5m2

# ---- FP16 baseline ----
run_test "fp16_64x64x64"        64 64  64 0
run_test "fp16_64x64x96"        64 64  96 0
run_test "fp16_32x64x64"        32 64  64 0
run_test "fp16_96x64x96"        96 64  96 0

# ---- FP4 E2M1 ----
run_test "fp4_32x64x64"         32 64  64 1 e2m1
run_test "fp4_64x64x64"         64 64  64 1 e2m1
run_test "fp4_64x64x96"         64 64  96 1 e2m1

# ---- FP6 E3M2 ----
run_test "fp6e3m2_32x64x64"     32 64  64 1 e3m2
run_test "fp6e3m2_64x64x64"     64 64  64 1 e3m2
run_test "fp6e3m2_64x64x96"     64 64  96 1 e3m2

# ---- FP6 E2M3 ----
run_test "fp6e2m3_32x64x64"     32 64  64 1 e2m3
run_test "fp6e2m3_64x64x64"     64 64  64 1 e2m3
run_test "fp6e2m3_64x64x96"     64 64  96 1 e2m3

echo ""
echo "============================================="
echo "SWEEP DONE: $(date)"
echo "PASS=$PASS  FAIL=$FAIL  TIMEOUT=$TIMEOUT_COUNT  TOTAL=$((PASS+FAIL+TIMEOUT_COUNT))"
echo "============================================="
