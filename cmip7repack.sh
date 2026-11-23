#!/usr/bin/env bash
#
# Repack CMIP7 CMORised NetCDF files (consolidated metadata, larger chunks)
# for the dataset described in params.yml.
# Each parallel job checks one file and repacks it if needed.
#
# Usage:   ./cmip7repack.sh                # default 8 parallel jobs
#          num_threads=4 ./cmip7repack.sh  # override

set -uo pipefail

# `wait -n -p <var>` (bash >= 5.1) is used to track which job finished
if (( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1) )); then
  echo "ERROR: bash >= 5.1 required, found $BASH_VERSION" >&2
  exit 1
fi

# activate conda
source /cluster/software/Miniforge3/24.1.2-0/etc/profile.d/conda.sh
conda activate /nird/datalake/NS16000B/cmip7validate-env

# ---------------------------------------------------------------------------
# sanity checks
# ---------------------------------------------------------------------------
for cmd in yq cmip7repack check_cmip7_packing; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' not found in PATH (conda env not activated?)" >&2
    exit 1
  fi
done

if [[ ! -f params.yml ]]; then
  echo "ERROR: params.yml not found in $PWD" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# parse params.yml
# ---------------------------------------------------------------------------
cmorout=$(yq -r '.datasets.cmorout' params.yml)
source_id=$(yq -r '.datasets.source_id' params.yml)
experiment_id=$(yq -r '.datasets.experiment_id' params.yml)
variant_label=$(yq -r '.datasets.variant_label' params.yml)
version=$(yq -r '.datasets.version' params.yml)

for var in cmorout source_id experiment_id variant_label version; do
  if [[ -z ${!var} || ${!var} == "null" ]]; then
    echo "ERROR: '$var' is empty or null in params.yml" >&2
    exit 1
  fi
done

# set default value
data_root="${cmorout}/${source_id}/${experiment_id}/${variant_label}/${version}"

if [[ ! -d $data_root || ! -w $data_root ]]; then
  echo "$data_root is not writable. Check the permission"
  echo "EXIT..."
  exit 1
fi

# ---------------------------------------------------------------------------
# number of files to process in parallel
# ---------------------------------------------------------------------------
num_threads=${num_threads:-${SLURM_CPUS_PER_TASK:-32}}
if ! [[ $num_threads =~ ^[0-9]+$ ]] || (( num_threads < 1 )); then
  echo "ERROR: invalid num_threads='$num_threads'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# collect files
# ---------------------------------------------------------------------------
shopt -s nullglob extglob
declare -A seen=()
files=()
for f in "$data_root"/*_r+([0-9])i+([0-9])p+([0-9])f+([0-9])@(.nc|_+([0-9])-+([0-9]).nc); do
  [[ -n ${seen[$f]:-} ]] && continue
  seen[$f]=1
  files+=("$f")
done
shopt -u nullglob extglob

if (( ${#files[@]} == 0 )); then
  echo "No '*_r*i*p*f*.nc' files found under $data_root"
  exit 0
fi
echo "Found ${#files[@]} file(s) in $data_root (parallel jobs: $num_threads)"

# ---------------------------------------------------------------------------
# failure bookkeeping and interrupt handling
# ---------------------------------------------------------------------------
log_prefix="${source_id}.${experiment_id}.${variant_label}.${version}"
fail_log=$(mktemp "${TMPDIR:-/tmp}/${log_prefix}.fail.XXXXXX") || exit 1
attempt_log=$(mktemp "${TMPDIR:-/tmp}/${log_prefix}.attempt.XXXXXX") || {
  rm -f "$fail_log"
  exit 1
}
skip_log=$(mktemp "${TMPDIR:-/tmp}/${log_prefix}.skip.XXXXXX") || {
  rm -f "$fail_log" "$attempt_log"
  exit 1
}
pids=()
running=0

cleanup() {
  trap - INT TERM
  echo "" >&2
  echo "Interrupted: stopping ${#pids[@]} running job(s)..." >&2
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  #rm -f "$fail_log" "$attempt_log" "$skip_log"
  mv "$fail_log" "$attempt_log" "$skip_log" logs/cmip7repack/
  exit 130
}
trap cleanup INT TERM

prune_pid() {
  local target=$1 p
  local -a keep=()
  for p in "${pids[@]}"; do
    [[ $p == "$target" ]] || keep+=("$p")
  done
  pids=("${keep[@]}")
}

# check and, if needed, repack one file in the same background job
process_one() {
  local file=$1
  if check_cmip7_packing "$file" >/dev/null 2>&1; then
    echo "$(basename "$file") already packed"
    printf '%s\n' "$file" >> "$skip_log"
    return 0
  fi

  echo "Packing $(basename "$file")"
  printf '%s\n' "$file" >> "$attempt_log"
  if cmip7repack -o "$file"; then
    return 0
  fi
  printf '%s\n' "$file" >> "$fail_log"
  return 1
}

# reap one finished job and update the slot counter
reap_one() {
  local finished=''
  wait -n -p finished
  (( running = running - 1 ))
  [[ -n $finished ]] && prune_pid "$finished"
  return 0
}

# ---------------------------------------------------------------------------
# main loop: keep at most $num_threads jobs in flight
# ---------------------------------------------------------------------------
notwritable=0

for ncfile in "${files[@]}"; do
  # throttle: only start a new job when fewer than $num_threads are running
  if (( running >= num_threads )); then
    reap_one
  fi

  if [[ ! -w $ncfile ]]; then
    echo "NOT WRITABLE: $ncfile"
    (( notwritable = notwritable + 1 ))
    continue
  fi

  process_one "$ncfile" &
  pids+=("$!")
  (( running = running + 1 ))
done

# wait for the remaining jobs before exiting
while (( running > 0 )); do
  reap_one
done

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
packed=$(awk 'END { print NR }' "$attempt_log")
skipped=$(awk 'END { print NR }' "$skip_log")
nfailed=$(awk 'END { print NR }' "$fail_log")
echo ""
echo "repacked      : $packed"
echo "already packed: $skipped"
echo "not writable  : $notwritable"
echo "failed        : $nfailed"

if (( nfailed > 0 )); then
  echo "Failed files:" >&2
  sed 's/^/  - /' "$fail_log" >&2
fi
mkdir -p logs/cmip7repack
for logfile in  "$fail_log" "$attempt_log" "$skip_log"
do
  # append .log extension
  mv "${logfile}" "logs/cmip7repack/${logfile}.log"
  # or replace random suffix with .log
  #mv "${logfile}" "logs/cmip7repack/${logfile%.*}.log"
done

if (( nfailed > 0 )); then
  echo "cmip7repack finished WITH ERRORS: $data_root" >&2
  exit 1
fi

echo "cmip7repack, DONE!"
echo "repacked: $data_root"

