#!/usr/bin/env bash
set -e

# activate conda
source /cluster/software/Miniforge3/24.1.2-0/etc/profile.d/conda.sh
conda activate /nird/datalake/NS16000B/cmip7validate-env

# get version from yml file
cmorout=$(yq -r '.cmorout' params.yml)
source_id=$(yq -r '.source_id' params.yml)
experiment_id=$(yq -r '.experiment_id' params.yml)
variant_label=$(yq -r '.variant_label' params.yml)
version=$(yq -r '.version' params.yml)

# set default value
data_root=$cmorout/$source_id/$experiment_id/$version
www_root=/nird/datalake/NS9560K/www/diagnostics/cmip7validate
exp_root=${www_root}

# check group id
if id |grep -q 'ipcc' ; then
  gid='ipcc'
elif id |grep 'ns9560k' ; then
  gid='ns9560k'
else
  gid='null'
fi
# set permission
umask 002

# inject parameters
#for pynb in $(ls notebooks/*ipynb); do
#  papermill --prepare-only -f params.yml $pynb $(basename $pynb)
#done

# build the book
jupyter-book clean .
jupyter-book build -n .

# publish
chmod -R g+w _build/html
if [ $gid == 'null' ]; then
  echo "Generated diagnostics is under:"
  echo "$pwd/_build/html"
  echo "It is not copied to ${www_root} since you do not blong to the 'ipcc' group or 'ns9560k' group."
else
  mkdir -p ${www_root}/${source_id}/${experiment_id}/${version}
  rsync -au --chown=$USER:$gid --delete --remove-source-files _build/html/ ${www_root}/${source_id}/${experiment_id}/${version}/
  echo 'Gedneratd diagnostics is at:'
  echo "https://ns9560k.web.sigma2.no/datalake/diagnostics/cmip7validate/${source_id}/${experiment_id}/${version}"
fi

