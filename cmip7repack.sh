#!/usr/bin/env bash
#set -e

# activate conda
source /cluster/software/Miniforge3/24.1.2-0/etc/profile.d/conda.sh
conda activate /nird/datalake/NS16000B/cmip7validate-env

# parse yml file
cmorout=$(yq -r '.datasets.cmorout' params.yml)
source_id=$(yq -r '.datasets.source_id' params.yml)
experiment_id=$(yq -r '.datasets.experiment_id' params.yml)
variant_label=$(yq -r '.datasets.variant_label' params.yml)
version=$(yq -r '.datasets.version' params.yml)

# set default value
data_root=$cmorout/$source_id/$experiment_id/$variant_label/$version

# number of files to process in parallel
num_threads=8

# repack netcdf file to have solidated metada and large enough chunk size
if [ -d $data_root ] && [ -w $data_root ] ; then
  running=0
  for ncfile in $(ls $data_root/{*_r*i*p*f*.nc,*_r*i*p*f*_*-*.nc})
  do
    # throttle: only start a new job when fewer than $num_threads are running
    if [ "$running" -ge "$num_threads" ]; then
      wait -n          # returns as soon as ONE job finishes
      running=$((running - 1))
    fi

    if [ -w $ncfile ]; then
      (
        check_cmip7_packing "$ncfile" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
          echo "Packing $(basename $ncfile)"
          cmip7repack -o "$ncfile"
        else
          echo "$(basename $ncfile) already packed"
        fi
      ) &
      running=$((running + 1))
    else
      echo "$ncfile is not writable. Check the permission"
    fi
  done
  # wait for the remaining jobs before exiting
  wait
else
  echo "$data_root is not writable. Check the permission"
  echo "EXIT..."
  exit 1
fi

echo "cmip7repack, DONE!"
echo "repacked: $data_root"

