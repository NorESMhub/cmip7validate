#!/usr/bin/env bash
set -e

# get version from yml file
source_id=$(cat params.yml |grep 'source_id' |cut -d: -f2 |sed 's/ //g')
experiment_id=$(cat params.yml |grep 'experiment_id' |cut -d: -f2 |sed 's/ //g')
variant_label=$(cat params.yml |grep 'variant_label' |cut -d: -f2 |sed 's/ //g')
version=$(cat params.yml |grep 'version' |cut -d: -f2 |sed 's/ //g')

# set default value
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
if [ ! -d ${www_root}/${source_id}/${experiment_id} ]; then
  mkdir -p ${www_root}/${source_id}/${experiment_id}
fi

# activate conda
source /cluster/software/Miniforge3/24.1.2-0/etc/profile.d/conda.sh
conda activate /nird/datalake/NS16000B/cmip7validate-env

# inject parameters
for pynb in $(ls notebooks/*ipynb); do
  papermill --prepare-only -f params.yml $pynb $(basename $pynb)
done

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
  rm -rf ${www_root}/${source_id}/${experiment_id}.${version}
  rsync -au _build/html/ ${www_root}/${source_id}/${experiment_id}.${version}/
  echo 'Gedneratd diagnostics is at:'
  echo "https://ns9560k.web.sigma2.no/datalake/diagnostics/cmip7validate/${source_id}/${experiment_id}.${version}"
fi

# move generated pynb to tmp
[ ! -d tmp ] && mkdir tmp
[ -f intro.ipynb ] && mv *.ipynb tmp/
