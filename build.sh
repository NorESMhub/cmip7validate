#!/usr/bin/env bash
set -e

# reset log file; use append mode for tee
log_subdir=logs/cmip7validate
mkdir -p ${log_subdir}
rm -f build.log execute.log
tee() {
    command tee -a "$@"
}

echo "-------------------------------" |tee build.log execute.log
echo "cmip7validate starts:" |tee build.log execute.log
date | tee build.log execute.log
echo "-------------------------------" |tee build.log execute.log

# activate conda
source /cluster/software/Miniforge3/24.1.2-0/etc/profile.d/conda.sh
conda activate /nird/datalake/NS16000B/cmip7validate-env

# parse yml file
cmorout=$(yq -r '.datasets.cmorout' params.yml)
source_id=$(yq -r '.datasets.source_id' params.yml)
experiment_id=$(yq -r '.datasets.experiment_id' params.yml)
variant_label=$(yq -r '.datasets.variant_label' params.yml)
version=$(yq -r '.datasets.version' params.yml)
www_root=$(yq -r '.webpage.www_root' params.yml)

# set default value
data_root=$cmorout/$source_id/$experiment_id/$variant_label/$version
www_subdir=${source_id}/${experiment_id}/${variant_label}/${version}

# check group id
if id |grep -q 'ipcc' ; then
  gid='ipcc'
elif id |grep 'ns9560k' ; then
  gid='ns9560k'
else
  gid='null'
fi
# set permission
umask 022

# inject parameters
#for pynb in $(ls notebooks/*ipynb); do
#  papermill --prepare-only -f params.yml $pynb $(basename $pynb)
#done

# run preprocess_cache.py
python preprocess_cache.py

# build the book
export PYTHONNOUSERSITE=1
jupyter-book clean --all . |tee build.log
jupyter-book build --config ./_config.yml -v -n notebooks | tee build.log

#jupyter-book build -v -n --all --builder html . |tee build.log  # rebuild html only
#jupyter-book build --path-output . ocean_fx.ipynb    # build single page (output _build/_page)
#jupyter-book build --builder html ocean_fx.ipynb

# backup (for rerun from cache)
#cp params.yml _build/jupyter_execute

# publish
if [ $gid == 'null' ]; then
  echo "Generated diagnostics is under:" |tee build.log
  echo "$pwd/_build/html" |tee build.log
  echo "It is not copied to ${www_root} since you do not blong to the 'ipcc' group or 'ns9560k' group." |tee build.log
else
  mkdir -p ${www_root}/${www_subdir}
  rsync -au --chown=$USER:$gid --delete _build/html/ ${www_root}/${www_subdir}/
  echo 'Generated diagnostics are at:' |tee build.log
  echo "${www_root}/${www_subdir}" |tee build.log
  if [ ${www_root} == '/nird/datalake/NS9560K/www/diagnostics/cmip7validate' ]; then
    echo "https://ns9560k.web.sigma2.no/datalake/diagnostics/cmip7validate/${www_subdir}" |tee build.log
  fi
fi
# writable until variant_label folder for all group members
chmod g+w ${www_root}/${www_subdir}/../


echo "-------------------------------" |tee build.log execute.log
echo "cmip7validate ends:" |tee build.log execute.log
date | tee -a build.log execute.log
echo "-------------------------------" |tee build.log execute.log

[ ! -d logs ] && mkdir logs
[ -f build.log ] && mv build.log ${log_subdir}/${source_id}.${experiment_id}.${variant_label}.${version}.build.log
[ -f execute.log ] && mv execute.log ${log_subdir}/${source_id}.${experiment_id}.${variant_label}.${version}.execute.log

