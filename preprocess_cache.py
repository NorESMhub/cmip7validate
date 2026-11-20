#!/usr/bin/env python3
"""Pre-compute the climo / time-series caches used by the notebooks.

All settings are read from `params.yml` (`datasets` and `cache`) and
`assets/methods.txt`; the grid labels are fixed in this script. It takes no
arguments:

    python preprocess_cache.py

For every compound name in `assets/variables.nml` for which cmorized data
files exist, the dimensionality of the variable decides how it is handled:

* 3D (`lev` dimension): the time mean is vertically aggregated (method
  `vertical` in `assets/methods.txt`) and the global time series is weighted
  by area x layer thickness (method `timeseries`),
* 2D (no `lev`): the time mean is used as is and the global time series is
  weighted by area (method `timeseries`).

Variables without a `time` dimension (fixed fields) and variables without the
horizontal `j`/`i` dimensions (e.g. basin or section diagnostics) are skipped.

Two cache files are written per data file:

    <cache.root>/<source_id>/<experiment_id>/<variant_label>/<version>/climo/<data file name>
    <cache.root>/<source_id>/<experiment_id>/<variant_label>/<version>/ts/<data file name>

The climo files keep the original `time` coordinate (the data variable itself
has no time dimension) so that the number of averaged time steps can be
recovered when the cache is read back.
"""

from __future__ import annotations

import logging
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

import xarray as xr
import yaml
from pyprojroot import here

# Get project root
root_path = Path(here())

from cmip7validate.utils import read_compound_names, read_variables

log = logging.getLogger("preprocess")

# grid labels of the cmorized files
GRID_LABEL = "g202"        # grid label for the fx files areacello and sftof (not valid for other fx files)
FILE_GRID_LABEL = "g???"   # grid label used to search the data files

@dataclass(frozen=True)
class Settings:
    """Paths and flags used by all tasks (picklable, passed to workers)."""

    data_path: Path
    climo_path: Path
    ts_path: Path
    source_id: str
    experiment_id: str
    variant_label: str
    grid_label: str
    file_grid_label: str
    overwrite: bool
    jobs: int


@dataclass(frozen=True)
class Task:
    """One compound name to process."""

    cname: str
    var: str
    ndim: int
    mth_vert: str
    mth_ts: str


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def resolve_methods(cname: str, methods: dict) -> tuple[str, str]:
    """Return the (vertical, timeseries) aggregation methods of a compound name."""
    mth_vert = "mean"
    mth_ts = "mean"
    spec = methods.get(cname)
    if spec:
        mth_vert = spec.get("vertical", mth_vert)
        mth_ts = spec.get("timeseries", mth_ts)
    return mth_vert, mth_ts


def data_file_pattern(cname: str, settings: Settings) -> str:
    """Glob pattern of the cmorized data files of one compound name."""
    _, var, coord, freq, region = cname.split(".")
    return (
        f"{var}_{coord}_{freq}_{region}_{settings.file_grid_label}_"
        f"{settings.source_id}_{settings.experiment_id}_{settings.variant_label}_*.nc"
    )


def load_grid(settings: Settings) -> tuple[xr.DataArray, xr.DataArray]:
    """Load area weights and ocean mask, as done in the notebooks."""
    grid_file = settings.data_path.joinpath(
        f"areacello_ti-u-hxy-u_fx_glb_{settings.grid_label}_"
        f"{settings.source_id}_{settings.experiment_id}_{settings.variant_label}.nc"
    )
    if grid_file.exists():
        with xr.open_dataset(grid_file) as ds:
            parea = ds["areacello"].load()
    else:
        with xr.open_dataset(root_path.joinpath("assets/grid.nc")) as ds:
            parea = ds["parea"].rename({"y": "j", "x": "i"}).load()

    grid_file = settings.data_path.joinpath(
        f"sftof_ti-u-hxy-u_fx_glb_{settings.grid_label}_"
        f"{settings.source_id}_{settings.experiment_id}_{settings.variant_label}.nc"
    )
    if grid_file.exists():
        with xr.open_dataset(grid_file) as ds:
            pmask = ds["sftof"].load()
    else:
        with xr.open_dataset(root_path.joinpath("assets/grid.nc")) as ds:
            pmask = ds["pmask"].rename({"y": "j", "x": "i"}).load()

    return parea, pmask


def write_climo(
    ds: xr.Dataset,
    da: xr.DataArray,
    var: str,
    out_file: Path,
    ndim: int,
    mth_vert: str,
    thk: xr.DataArray | None,
    pmask: xr.DataArray,
) -> None:
    """Write the (for 3D vertically aggregated) time mean of one data file."""
    daclimo = da.mean(dim="time", keep_attrs=True)

    if ndim == 3:
        if mth_vert == "mean":
            daclimo = daclimo.weighted(thk).mean(dim="lev", keep_attrs=True).where(pmask == 1)
        elif mth_vert == "sum":
            daclimo = daclimo.weighted(thk).sum(dim="lev", keep_attrs=True).where(pmask == 1)
        else:
            raise ValueError(f"Unsupported vertical aggregation method: {mth_vert}")

    ds_climo = daclimo.to_dataset(name=var)
    # keep the original time coordinate so that the number of averaged
    # time steps can be recovered from the cache file
    ds_climo["time"] = ds["time"]
    ds_climo.to_netcdf(out_file, unlimited_dims=["time"])


def write_ts(
    ds: xr.Dataset,
    da: xr.DataArray,
    var: str,
    out_file: Path,
    ndim: int,
    mth_ts: str,
    thk: xr.DataArray | None,
    parea: xr.DataArray,
) -> None:
    """Write the global time series of one data file."""
    if ndim == 3:
        weights = parea * thk
        dims = ["lev", "j", "i"]
    else:
        weights = parea
        dims = ["j", "i"]

    if mth_ts == "mean":
        dats = da.weighted(weights).mean(dim=dims, keep_attrs=True)
    elif mth_ts == "sum":
        dats = da.weighted(weights).sum(dim=dims, keep_attrs=True)
    else:
        raise ValueError(f"Unsupported timeseries method: {mth_ts}")

    dats.attrs = da.attrs.copy()

    ds_ts = dats.to_dataset(name=var)
    ds_ts["time"] = ds["time"]
    ds_ts.to_netcdf(out_file, unlimited_dims=["time"])


# --------------------------------------------------------------------------- #
# task construction
# --------------------------------------------------------------------------- #
def build_tasks(cnames: list[str], methods: dict, settings: Settings) -> list[Task]:
    """Select the compound names with usable data files and detect 2D / 3D."""
    tasks: list[Task] = []

    for cname in cnames:
        if len(cname.split(".")) != 5:
            log.warning("%s: unexpected compound name, skipped", cname)
            continue

        data_files = sorted(settings.data_path.glob(data_file_pattern(cname, settings)))
        if not data_files:
            log.debug("%s: no data files, skipped", cname)
            continue

        var = cname.split(".")[1]
        with xr.open_dataset(data_files[0]) as ds:
            if var not in ds:
                log.warning("%s: '%s' not in %s, skipped", cname, var, data_files[0].name)
                continue
            dims = ds[var].dims
            has_lev_bnds = "lev_bnds" in ds

        if "time" not in dims:
            log.info("%s: no time dimension, skipped", cname)
            continue
        if not {"j", "i"}.issubset(dims):
            log.info("%s: dims %s are not horizontal, skipped", cname, dims)
            continue
        if "lev" in dims and not has_lev_bnds:
            log.info("%s: no lev_bnds, skipped", cname)
            continue

        ndim = 3 if "lev" in dims else 2
        mth_vert, mth_ts = resolve_methods(cname, methods)
        tasks.append(Task(cname, var, ndim, mth_vert, mth_ts))

    return tasks


# --------------------------------------------------------------------------- #
# worker
# --------------------------------------------------------------------------- #
def process_task(
    task: Task,
    settings: Settings,
    parea: xr.DataArray,
    pmask: xr.DataArray,
) -> dict:
    """Build the climo and ts cache files of one compound name."""
    t0 = time.time()
    result = {
        "cname": task.cname,
        "ndim": task.ndim,
        "written": 0,
        "cached": 0,
        "status": "ok",
        "message": "",
        "seconds": 0.0,
    }

    data_files = sorted(settings.data_path.glob(data_file_pattern(task.cname, settings)))
    if not data_files:
        result["status"] = "skipped"
        result["message"] = "no data files"
        return result

    # vertical weights from the first file
    thk = None
    j_size = None
    with xr.open_dataset(data_files[0]) as ds:
        if task.ndim == 3:
            lev_bnds = ds.isel(time=0, drop=True)["lev_bnds"]
            thk = lev_bnds.diff(dim="bnds").squeeze()
            thk = thk / thk.sum(dim="lev")
        j_size = ds.sizes.get("j")

    # the data may have one row less than the (384 row) grid file
    parea_t = parea
    pmask_t = pmask
    if j_size is not None and j_size == 384:
        if "j" in parea_t.dims and parea_t.sizes["j"] > j_size:
            parea_t = parea_t.isel(j=slice(0, j_size))
        if "j" in pmask_t.dims and pmask_t.sizes["j"] > j_size:
            pmask_t = pmask_t.isel(j=slice(0, j_size))

    for data_file in data_files:
        climo_file = settings.climo_path.joinpath(data_file.name)
        ts_file = settings.ts_path.joinpath(data_file.name)

        need_climo = settings.overwrite or not climo_file.is_file()
        need_ts = settings.overwrite or not ts_file.is_file()

        if not need_climo and not need_ts:
            result["cached"] += 2
            continue

        with xr.open_dataset(data_file) as ds:
            da = ds[task.var]
            if need_climo:
                write_climo(
                    ds, da, task.var, climo_file, task.ndim,
                    task.mth_vert, thk, pmask_t,
                )
                result["written"] += 1
                log.debug("%s: saved climo %s", task.cname, climo_file.name)
            if need_ts:
                write_ts(
                    ds, da, task.var, ts_file, task.ndim,
                    task.mth_ts, thk, parea_t,
                )
                result["written"] += 1
                log.debug("%s: saved ts %s", task.cname, ts_file.name)

    result["seconds"] = time.time() - t0
    return result


def report_result(res: dict) -> None:
    """Log the outcome of one task."""
    if res["status"] == "skipped":
        log.info("%s: skipped (%s)", res["cname"], res["message"])
    else:
        log.info(
            "%s (%dD): written %d, cached %d (%.1fs)",
            res["cname"], res["ndim"], res["written"], res["cached"], res["seconds"],
        )


def init_worker() -> None:
    """Make sure workers log the same way when the 'spawn' start method is used."""
    if not logging.getLogger().handlers:
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s\t%(processName)s\t%(message)s",
            datefmt="%Y-%m-%d %H:%M",
        )


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s\t%(message)s",
        datefmt="%Y-%m-%d %H:%M",
        force=True,
    )

    params_file = root_path.joinpath("params.yml")
    with open(params_file) as f:
        param = yaml.safe_load(f)

    ds_param = param["datasets"]
    cache_param = param["cache"]

    source_id = ds_param["source_id"]
    experiment_id = ds_param["experiment_id"]
    variant_label = ds_param["variant_label"]
    version = ds_param["version"]

    data_path = Path(ds_param["cmorout"]).joinpath(
        source_id, experiment_id, variant_label, version
    )
    cache_base = Path(cache_param["root"]).joinpath(
        source_id, experiment_id, variant_label, version
    )
    settings = Settings(
        data_path=data_path,
        climo_path=cache_base.joinpath("climo"),
        ts_path=cache_base.joinpath("ts"),
        source_id=source_id,
        experiment_id=experiment_id,
        variant_label=variant_label,
        grid_label=GRID_LABEL,
        file_grid_label=FILE_GRID_LABEL,
        overwrite=cache_param.get("overwrite", False),
        jobs=cache_param.get("jobs", 1),
    )

    log.info("config:    %s", params_file)
    log.info("dataset:   %s/%s/%s/%s", source_id, experiment_id, variant_label, version)
    log.info("data:      %s", settings.data_path)
    log.info("climo:     %s", settings.climo_path)
    log.info("ts:        %s", settings.ts_path)
    log.info("overwrite: %s  (jobs=%d)", settings.overwrite, settings.jobs)

    if not settings.data_path.is_dir():
        log.error("data path does not exist: %s", settings.data_path)
        return 1
    settings.climo_path.mkdir(parents=True, exist_ok=True)
    settings.ts_path.mkdir(parents=True, exist_ok=True)

    methods = read_variables(root_path.joinpath("assets/methods.txt"))
    cnames = read_compound_names(root_path.joinpath("assets/variables.nml"))

    tasks = build_tasks(cnames, methods, settings)
    if not tasks:
        log.warning("nothing to do - no usable compound names")
        return 0

    n2d = sum(1 for t in tasks if t.ndim == 2)
    log.info("%d compound name(s) selected (%d x 2D, %d x 3D)",
             len(tasks), n2d, len(tasks) - n2d)

    parea, pmask = load_grid(settings)

    # ------------------------------------------------------------------ run
    t0 = time.time()
    results: list[dict] = []
    failed: list[str] = []

    if settings.jobs > 1:
        with ProcessPoolExecutor(max_workers=settings.jobs, initializer=init_worker) as pool:
            futures = {
                pool.submit(process_task, task, settings, parea, pmask): task
                for task in tasks
            }
            for future in as_completed(futures):
                task = futures[future]
                try:
                    res = future.result()
                except Exception as exc:  # keep going with the other variables
                    failed.append(task.cname)
                    log.error("%s failed: %s", task.cname, exc)
                    continue
                results.append(res)
                report_result(res)
    else:
        for i, task in enumerate(tasks, start=1):
            log.info("[%d/%d] %s", i, len(tasks), task.cname)
            try:
                res = process_task(task, settings, parea, pmask)
            except Exception as exc:  # keep going with the other variables
                failed.append(task.cname)
                log.error("%s failed: %s", task.cname, exc)
                continue
            results.append(res)
            report_result(res)

    # -------------------------------------------------------------- summary
    written = sum(r["written"] for r in results)
    cached = sum(r["cached"] for r in results)
    skipped = sum(1 for r in results if r["status"] == "skipped")

    log.info("--- --- ---")
    log.info("compound names: %d", len(tasks))
    log.info("cache files written: %d", written)
    log.info("cache files reused: %d", cached)
    log.info("skipped: %d, failed: %d", skipped, len(failed))
    log.info("total time: %.1f minutes", (time.time() - t0) / 60)

    for cname in failed:
        log.error("failed: %s", cname)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
