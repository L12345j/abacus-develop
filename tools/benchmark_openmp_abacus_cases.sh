#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

BUILD_DIR=${BUILD_DIR:-"$REPO_ROOT/build"}
ABACUS_BIN=${ABACUS_BIN:-"$BUILD_DIR/abacus_basic_para"}
LOG_ROOT=${LOG_ROOT:-"$REPO_ROOT/openmp_case_logs"}
THREADS_LIST=${THREADS_LIST:-"1 2 4 8"}
CASES=${CASES:-"P007_H2O_pw P000_si16_pw BUG_PW_BPCG"}
MPI_NPROCS=${MPI_NPROCS:-1}

if [[ ! -x "$ABACUS_BIN" ]]; then
  echo "ERROR: ABACUS binary not found or not executable: $ABACUS_BIN"
  exit 1
fi

if ! command -v mpirun >/dev/null 2>&1; then
  echo "ERROR: mpirun is required but was not found in PATH."
  exit 1
fi

mkdir -p "$LOG_ROOT"
ln -sfn "$REPO_ROOT/tests/PP_ORB" "$LOG_ROOT/PP_ORB"

case_source_dir() {
  case "$1" in
    P007_H2O_pw)
      printf '%s\n' "$REPO_ROOT/tests/performance/P007_H2O_pw"
      ;;
    P000_si16_pw)
      printf '%s\n' "$REPO_ROOT/tests/performance/P000_si16_pw"
      ;;
    BUG_PW_BPCG)
      printf '%s\n' "$REPO_ROOT/tests/01_PW/BUG_PW_BPCG"
      ;;
    *)
      echo "ERROR: unsupported case key: $1" >&2
      return 1
      ;;
  esac
}

prepare_case_dir() {
  local case_name=$1
  local threads=$2
  local source_dir
  source_dir=$(case_source_dir "$case_name")

  local case_dir="$LOG_ROOT/$case_name"
  local run_dir="$case_dir/run_omp_${threads}"

  mkdir -p "$case_dir"
  rm -rf "$run_dir"
  mkdir -p "$run_dir"
  cp -f "$source_dir/INPUT" "$source_dir/STRU" "$source_dir/KPT" "$run_dir/"
}

parse_runtime_log() {
  python3 - "$1" <<'PY'
import re
import sys

log_path = sys.argv[1]
energy = None
eigen_time = 0.0
scf_steps = 0
converged = 0

with open(log_path, encoding='utf-8', errors='ignore') as handle:
    for raw_line in handle:
        line = raw_line.strip()
        if 'TOTAL  Time  :' in line:
            converged = 1
        parts = line.split()
        if len(parts) >= 5 and re.match(r'^(CG|DA|GE|GV)\d+$', parts[0]):
            try:
                energy = float(parts[1].replace('D', 'E'))
                step_time = float(parts[4].replace('D', 'E'))
            except ValueError:
                continue
            scf_steps += 1
            eigen_time += step_time

if energy is None:
    energy_text = 'NA'
else:
    energy_text = f'{energy:.12f}'

if scf_steps == 0:
    eigen_time_text = 'NA'
else:
    eigen_time_text = f'{eigen_time:.6f}'

print('|'.join([energy_text, str(scf_steps), eigen_time_text, str(converged)]))
PY
}

read_wall_time() {
  local time_file=$1
  if [[ -f "$time_file" ]]; then
    awk '/^real / {print $2}' "$time_file" | tail -n1
  else
    printf 'NA\n'
  fi
}

run_case_thread() {
  local case_name=$1
  local threads=$2
  local case_dir="$LOG_ROOT/$case_name"
  local run_dir="$case_dir/run_omp_${threads}"
  local log_file="$case_dir/log_omp_${threads}.out"
  local time_file="$run_dir/time_omp_${threads}.txt"

  prepare_case_dir "$case_name" "$threads"

  : > "$log_file"
  : > "$time_file"

  set +e
  (
    cd "$run_dir"
    env \
      OMP_NUM_THREADS="$threads" \
      MKL_NUM_THREADS=1 \
      OPENBLAS_NUM_THREADS=1 \
      BLIS_NUM_THREADS=1 \
      OMP_PROC_BIND=false \
      /usr/bin/time -p -o "$time_file" \
      mpirun -np "$MPI_NPROCS" "$ABACUS_BIN" >"$log_file" 2>&1
  )
  local exit_code=$?
  set -e

  printf '%s\n' "$exit_code"
}

for case_name in $CASES; do
  case_dir="$LOG_ROOT/$case_name"
  csv_file="$case_dir/benchmark_openmp_case.csv"
  baseline_energy="NA"
  baseline_steps="NA"
  baseline_wall="NA"

  mkdir -p "$case_dir"
  printf 'case,threads,wall_time,eigen_time,total_energy,scf_steps,converged,status,speedup,efficiency\n' > "$csv_file"

  for threads in $THREADS_LIST; do
    exit_code=$(run_case_thread "$case_name" "$threads")

    log_file="$case_dir/log_omp_${threads}.out"
    time_file="$LOG_ROOT/$case_name/run_omp_${threads}/time_omp_${threads}.txt"
    parsed=$(parse_runtime_log "$log_file")
    IFS='|' read -r total_energy scf_steps eigen_time converged <<<"$parsed"
    wall_time=$(read_wall_time "$time_file")

    status="FAIL"
    if [[ "$exit_code" -eq 0 && "$converged" -eq 1 ]]; then
      status="PASS"
      if [[ "$threads" == "1" ]]; then
        baseline_energy="$total_energy"
        baseline_steps="$scf_steps"
        baseline_wall="$wall_time"
      else
        energy_diff="NA"
        if [[ "$baseline_energy" != "NA" && "$total_energy" != "NA" ]]; then
          energy_diff=$(awk -v a="$baseline_energy" -v b="$total_energy" 'BEGIN { d=a-b; if (d<0) d=-d; printf "%.12f", d }')
        fi
        if [[ "$baseline_steps" != "NA" && "$baseline_steps" == "$scf_steps" && "$energy_diff" != "NA" ]]; then
          if awk -v d="$energy_diff" 'BEGIN { exit !(d <= 1e-6) }'; then
            status="PASS+MATCH"
          else
            status="PASS+DIFF"
          fi
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
    elif [[ "$baseline_wall" != "NA" && "$wall_time" != "NA" && "$status" != "FAIL" ]]; then
      speedup=$(awk -v t1="$baseline_wall" -v tp="$wall_time" 'BEGIN { if (tp > 0) printf "%.6f", t1 / tp; else print "NA" }')
      efficiency=$(awk -v s="$speedup" -v p="$threads" 'BEGIN { if (s == "NA") print "NA"; else printf "%.6f", s / p }')
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$case_name" "$threads" "$wall_time" "$eigen_time" "$total_energy" "$scf_steps" "$converged" "$status" "$speedup" "$efficiency" \
      >> "$csv_file"

    printf '[%s] threads=%s wall=%s eigen=%s energy=%s steps=%s converged=%s status=%s\n' \
      "$case_name" "$threads" "$wall_time" "$eigen_time" "$total_energy" "$scf_steps" "$converged" "$status"
  done
done