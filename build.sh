#!/usr/bin/env bash
set -e

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
www_root=/nird/datalake/NS9560K/www/diagnostics/cmip7validate
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

# build the book
rm -f build.log execute.log
export PYTHONNOUSERSITE=1
jupyter-book clean .
jupyter-book build -v -n . | tee build.log

#jupyter-book build -v -n --all --builder html . |tee build.log  # rebuild html only
#jupyter-book build --path-output . ocean_fx.ipynb    # build single page (output _build/_page)
#jupyter-book build --builder html ocean_fx.ipynb

[ ! -d logs ] && mkdir logs
[ -f build.log ] && mv build.log logs/${source_id}.${experiment_id}.${variant_label}.${version}.build.log
[ -f execute.log ] && mv execute.log logs/${source_id}.${experiment_id}.${variant_label}.${version}.execute.log

# backup (for rerun from cache)
#cp params.yml _build/jupyter_execute

# publish
if [ $gid == 'null' ]; then
  echo "Generated diagnostics is under:"
  echo "$pwd/_build/html"
  echo "It is not copied to ${www_root} since you do not blong to the 'ipcc' group or 'ns9560k' group."
else
  mkdir -p ${www_root}/${www_subdir}
  rsync -au --chown=$USER:$gid --delete _build/html/ ${www_root}/${www_subdir}/
  echo 'Gedneratd diagnostics is at:'
  echo "https://ns9560k.web.sigma2.no/datalake/diagnostics/cmip7validate/${www_subdir}"
fi
# writable until variant_label folder for all group members
chmod g+w ${www_root}/${www_subdir}/../


