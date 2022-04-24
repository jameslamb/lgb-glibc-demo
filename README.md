# lgb-glibc-demo

Code and documentation for investigating the error described in https://github.com/microsoft/LightGBM/issues/5106.

When LightGBM's Python package is build from source on Linux, under certain conditions compilation can succeed by importing the library can fail with an error similar to the following.

> OSError: /root/miniforge/bin/../lib/libstdc++.so.6: version 'GLIBCXX_3.4.30' not found (required by /usr/local/src/LightGBM/python-package/compile/lib_lightgbm.so)

## Reproducible Examples

This describes the steps to reproduce the error.

First, build an Ubuntu 22.04 container with the necessary system libraries set up and `conda` installed.

```shell
make build
```

Next, try building `lightgbm` from source and installing it in the `base` conda environment.

Installation and importing the library should succeed.

```shell
docker run \
    --rm \
    --workdir /usr/local/src/LightGBM/python-package \
    -it lgb-glibc-demo:local \
    /bin/bash -c "pip install . && python -c 'import lightgbm'"
```

But installing `libcxx-ng` (or anything that results in that being installed, like `dask`) will cause importing `lightgbm` to fail.

```shell
# fails
docker run \
    --rm \
    --workdir /usr/local/src/LightGBM/python-package \
    -it lgb-glibc-demo:local \
    /bin/bash -c "conda install -y -n base libstdcxx-ng && pip install . && python -c 'import lightgbm'"
```

> OSError: /root/miniforge/bin/../lib/libstdc++.so.6: version 'GLIBCXX_3.4.30' not found (required by /usr/local/src/LightGBM/python-package/compile/lib_lightgbm.so)

```shell
# fails
docker run \
    --rm \
    --workdir /usr/local/src/LightGBM/python-package \
    -it lgb-glibc-demo:local \
    /bin/bash -c "conda install -y -n base dask && pip install . && python -c 'import lightgbm'"
```

> OSError: /root/miniforge/bin/../lib/libstdc++.so.6: version 'GLIBCXX_3.4.30' not found (required by /usr/local/src/LightGBM/python-package/compile/lib_lightgbm.so)
