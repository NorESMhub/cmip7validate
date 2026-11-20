## Technically validate the CMIP7 data by NorESM3
### Checkout 'cmip7validate'
```bash
cd ~
git clone git@github.com:NorESMhub/cmip7validate.git
```
### Update the configuration of the experiment
update the value correspondingly to the cmorized experiment, in `params.yml`

### Pre-compute the climo / time-series cache
The ocean and ocnBgchem pages read per-file climatologies and global time
series from the cache root configured in `params.yml`. They are produced by a
separate script, so the heavy work is done once instead of during the notebook
build:
```bash
python preprocess_cache.py
```
The script takes no arguments; it reads everything from `params.yml`
(`datasets`, `cache.root`, `cache.overwrite`, `cache.jobs`) and
`assets/methods.txt`. Each variable is treated as 3D when it
has a `lev` dimension (vertical aggregation) and as 2D otherwise.

Use `cache.overwrite: false` in `params.yml` so the notebooks reuse the cache.

### Build and execute the validation
find the generated book/webpage by default at:
```
https://ns9560k.web.sigma2.no/datalake/diagnostics/cmip7validate
```
