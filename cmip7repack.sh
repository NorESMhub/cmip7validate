#!/usr/bin/env bash
#set -e

# activate conda
source /cluster/software/Miniforge3/24.1.2-0/etc/profile.d/conda.sh
conda activate /nird/datalake/NS16000B/cmip7validate-env

# parse yml file
cmorout=$(yq -r '.cmorout' params.yml)
source_id=$(yq -r '.source_id' params.yml)
experiment_id=$(yq -r '.experiment_id' params.yml)
variant_label=$(yq -r '.variant_label' params.yml)
version=$(yq -r '.version' params.yml)

# set default value
data_root=$cmorout/$source_id/$experiment_id/$version

# repack netcdf file to have solidated metada and large enough chunk size
if [ -d $data_root ] && [ -w $data_root ] ; then
  for ncfile in $(ls $data_root/{*_r*i*p*f*.nc,*_r*i*p*f*_*-*.nc})
  do
    if [ -w $ncfile ]; then
      check_cmip7_packing $ncfile >/dev/null 2>&1
      if [ $? -ne 0 ]; then
        echo "Packing $ncfile"
        cmip7repack -o $ncfile
      fi
    else
      echo "$ncfile is not writable. Check the permission"
      continue
    fi
  done
else
  echo "$data_root is not writable. Check the permission"
  echo "EXIT..."
  exit 1
fi

echo "cmip7repack, DONE!"
echo "repacked: $data_root"

