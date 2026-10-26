#!/usr/bin/env bash
set -eo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export JUPYTER_CONFIG_DIR="${PROJECT_DIR}/.jupyter"
export JUPYTER_RUNTIME_DIR="${PROJECT_DIR}/.jupyter_runtime"
mkdir -p "${JUPYTER_RUNTIME_DIR}"

# Try to activate the project environment if Conda is available.
for conda_sh in \
  "/conda/miniconda3/etc/profile.d/conda.sh" \
  "/cluster/software/Miniforge3/24.1.2-0/etc/profile.d/conda.sh"
do
  if [ -f "${conda_sh}" ]; then
    . "${conda_sh}"
    break
  fi
done

if command -v conda >/dev/null 2>&1; then
  #conda activate blomster-env >/dev/null 2>&1 || true
  conda activate cmip7validate-env
fi

# Launch
export PYTHONNOUSERSITE=1
unset PYTHONPATH
cd "${PROJECT_DIR}"
exec python -m jupyter lab \
  --notebook-dir "${PROJECT_DIR}" \
  --ip=127.0.0.1 \
  --no-browser \
  --port=8080 \
  --KernelManager.transport=ipc
