#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_DIR=${BUILD_DIR:-"$REPO_ROOT/build"}
SOURCE_TEST_DIR="$REPO_ROOT/source/source_hsolver/test"
TEST_DIR="$BUILD_DIR/source/source_hsolver/test"
THREADS_LIST=${THREADS_LIST:-"1 2 4 8"}
TARGETS=${TARGETS:-"MODULE_HSOLVER_cg"}
LOG_ROOT=${LOG_ROOT:-"$REPO_ROOT/openmp_benchmark_logs"}

if [[ -z "${CONDA_PREFIX:-}" ]]; then
  echo "ERROR: please activate the abacus conda environment before running this script."
  echo "Example: conda activate abacus && bash tools/benchmark_openmp_diago.sh"
  exit 1
fi

mkdir -p "$LOG_ROOT"

copy_test_assets() {
  mkdir -p "$TEST_DIR"
  cp -f "$SOURCE_TEST_DIR"/*.dat "$TEST_DIR"/ 2>/dev/null || true
  cp -f "$SOURCE_TEST_DIR"/*.sh "$TEST_DIR"/ 2>/dev/null || true
  chmod +x "$TEST_DIR"/*.sh 2>/dev/null || true
}

ensure_target_built() {
  local target=$1
  if [[ ! -x "$TEST_DIR/$target" ]]; then
    cmake --build "$BUILD_DIR" --target "$target" -j"$(nproc)"
  fi
}

sanitize_log() {
  local log_file=$1
  grep -vE 'Lapack Run time:|diag Run time:|solver time:|Average Scalapack Time:|Speedup:|Total Test time|^\[----------\]|^\[ RUN\s+\]|^\[\s+OK\s+\]|^\[\s+PASSED\s+\]|^\[==========\]' "$log_file" \
    | sed '/^[[:space:]]*$/d'
}

extract_time_seconds() {
  local log_file=$1
  local wall_file=$2
  local value

  value=$(grep -Eo 'solver time: *[0-9.]+s|diag Run time: *[0-9.]+ *S|diag Run time: *[0-9.]+|Average Scalapack Time: *[0-9.]+ *ms' "$log_file" | tail -n1 || true)
  if [[ -n "$value" ]]; then
    case "$value" in
      *"solver time:"*)
        awk '{gsub(/s/,"",$3); print $3}' <<<"$value"
        return
        ;;
      *"diag Run time:"*)
        awk '{print $4}' <<<"$value"
        return
        ;;
      *"Average Scalapack Time:"*)
        awk '{printf "%.6f\n", $4 / 1000.0}' <<<"$value"
        return
        ;;
    esac
  fi

  cat "$wall_file"
}

run_target_threads() {
  local target=$1
  local threads=$2
  local target_dir="$LOG_ROOT/$target"
  local log_file="$target_dir/log_omp_${threads}.out"
  local wall_file="$target_dir/wall_omp_${threads}.txt"
  local status_file="$target_dir/status_omp_${threads}.txt"
  local exe="$TEST_DIR/$target"

  mkdir -p "$target_dir"
  copy_test_assets
  ensure_target_built "$target"

  set +e
  (
    cd "$TEST_DIR"
    env \
      OMP_NUM_THREADS="$threads" \
      OMP_DYNAMIC=false \
      OMP_PROC_BIND=spread \
      OMP_PLACES=cores \
      MKL_NUM_THREADS=1 \
      OPENBLAS_NUM_THREADS=1 \
      BLIS_NUM_THREADS=1 \
      VECLIB_MAXIMUM_THREADS=1 \
      NUMEXPR_NUM_THREADS=1 \
      /usr/bin/time -f '%e' -o "$wall_file" \
      "$exe" >"$log_file" 2>&1
  )
  local exit_code=$?
  set -e

  echo "$exit_code" >"$status_file"
}

for target in $TARGETS; do
  target_dir="$LOG_ROOT/$target"
  csv_file="$target_dir/benchmark_openmp_${target}.csv"
  baseline_sanitized="$target_dir/baseline_sanitized.log"

  mkdir -p "$target_dir"
  printf 'threads,time,speedup,efficiency,status\n' >"$csv_file"

  baseline_time=""

  for threads in $THREADS_LIST; do
    run_target_threads "$target" "$threads"

    log_file="$target_dir/log_omp_${threads}.out"
    wall_file="$target_dir/wall_omp_${threads}.txt"
    status_file="$target_dir/status_omp_${threads}.txt"

    exit_code=$(cat "$status_file")
    elapsed=$(extract_time_seconds "$log_file" "$wall_file")
    status="FAIL"

    if [[ "$exit_code" -eq 0 ]]; then
      if [[ "$threads" == "1" ]]; then
        sanitize_log "$log_file" >"$baseline_sanitized"
        baseline_time="$elapsed"
        status="PASS"
      else
        sanitized_now="$target_dir/sanitized_omp_${threads}.log"
        sanitize_log "$log_file" >"$sanitized_now"
        if diff -q "$baseline_sanitized" "$sanitized_now" >/dev/null 2>&1; then
          status="PASS+MATCH"
        else
          status="PASS+DIFF"
        fi
      fi
    fi

    speedup="NA"
    efficiency="NA"
    if [[ "$threads" == "1" ]]; then
      speedup="1.000000"
      efficiency="1.000000"
    elif [[ -n "$baseline_time" && "$exit_code" -eq 0 ]]; then
      speedup=$(awk -v t1="$baseline_time" -v tp="$elapsed" 'BEGIN { if (tp > 0) printf "%.6f", t1 / tp; else print "NA" }')
      efficiency=$(awk -v s="$speedup" -v p="$threads" 'BEGIN { if (s == "NA") print "NA"; else printf "%.6f", s / p }')
    fi

    printf '%s,%s,%s,%s,%s\n' "$threads" "$elapsed" "$speedup" "$efficiency" "$status" >>"$csv_file"
    printf '[%s] threads=%s time=%s speedup=%s efficiency=%s status=%s\n' "$target" "$threads" "$elapsed" "$speedup" "$efficiency" "$status"
  done

  cat >"$target_dir/README.txt" <<EOF
Target: $target
CSV: $csv_file
Logs: $target_dir/log_omp_*.out
Baseline log: $baseline_sanitized
EOF
done
