#!/usr/bin/env bash
set -e

# get version from yml file
source_id=$(cat params.yml |grep 'source_id' |cut -d: -f2 |sed 's/ //g')
experiment_id=$(cat params.yml |grep 'experiment_id' |cut -d: -f2 |sed 's/ //g')
variant_label=$(cat params.yml |grep 'variant_label' |cut -d: -f2 |sed 's/ //g')
version=$(cat params.yml |grep 'version' |cut -d: -f2 |sed 's/ //g')

# set default value
www_root=/nird/datalake/NS9560K/www/diagnostics/cmip7validate/
exp_root=${www_root}

# check group id
gid=$(id -g -n)
if [ "$gid" != "ipcc" ] && [ "$gid" != "ns9560k" ]; then
  newgrp -c ipcc
fi
if [ $? != 0 ]; then
  newgrp -c ns9560k
  if [ $? != 0 ]; then
    echo "group error; exit..." && exit 1
  fi
fi

# set permission
umask 002
if [ ! -d ${www_root}/${source_id}/${experiment_id} ]; then
  mkdir -p ${www_root}/${source_id}/${experiment_id}
fi

# inject parameters
for pynb in $(ls notebooks/*ipynb); do
  papermill --prepare-only -f params.yml $pynb $(basename $pynb)
done

# build the book
source /cluster/software/Miniforge3/24.1.2-0/etc/profile.d/conda.sh
conda activate /nird/datalake/NS16000B/cmip7validate-env
jupyter-book build -n .

# publish
chmod -R g+w _build/html
rm -rf ${www_root}/${source_id}/${experiment_id}/${version}
mv _build/html ${www_root}/${source_id}/${experiment_id}/${version}

