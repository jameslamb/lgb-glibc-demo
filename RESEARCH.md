# research

This document contains my notes put together while investigating https://github.com/microsoft/LightGBM/issues/5106.

See [README.md](./README.md) for a more concise summary and list of recommendations.

## Investigative Tools

Run the following from the root of this repo to get into a container, and install `lightgbm` in the `base` conda environment.

```shell
make build

docker run \
    --rm \
    --workdir /usr/local/src/LightGBM/python-package \
    -it lgb-glibc-demo:local \
    /bin/bash

pip install .
```

All other commands below are intended to be run in the container, after that setup.
Some of them reference variables populated by other steps, so it's recommended that you run them in order.

### Where is `conda`?

```shell
CONDA_HOME=$(
    conda info --json \
    | jq -r .'"root_prefix"'
)
echo "conda is installed at '${CONDA_HOME}'"
```

### Where is Python and what version is it?

```shell
which python
python --version

which pip
pip --version
```

If Python is in `${CONDA_HOME}`, then you know that it's coming from `conda` and therefore using `conda`'s patches.

### Where did `pip install` put `lib_lightgbm.so`?

```shell
LIB_LIGHTGBM_IN_CONDA=$(
    find "${CONDA_HOME}" -name 'lib_lightgbm.so' \
    | head -1
)
echo "lib_lightgbm.so is at '${LIB_LIGHTGBM_IN_CONDA}'"
```

### What other libraries are linked to `lib_lightgbm.so`, and where did the linker find them?

```shell
ldd ${LIB_LIGHTGBM_IN_CONDA}
```

### What copies of `libstdc++.so.6` exist?

```shell
LIBSTDCXX_FILES=$(
    find / -name 'libstdc++.so.6'
)
echo "found the following copies of 'libstdc++.so.6':"
for libfile in ${LIBSTDCXX_FILES}; do
    echo "  ${libfile}"
done
```

### What is the maximum version of `GLIBCXX` in every `libstdc++.so.6`?

```shell
min_glibc_version() {
    libfile="${1}"
    strings "${libfile}" \
    | grep -E '^GLIBCXX_[0-9]+' \
    | tr -d 'GLIBCXX_' \
    | sort -V \
    | head -1
}

max_glibc_version() {
    libfile="${1}"
    strings "${libfile}" \
    | grep -E '^GLIBCXX_[0-9]+' \
    | tr -d 'GLIBCXX_' \
    | sort -r -V \
    | head -1
}

echo "finding GLIBCXX ranges for libstdc++.so.6 files"
for libfile in ${LIBSTDCXX_FILES}; do
    echo "  ${libfile}"
    echo "    - min: $(min_glibc_version ${libfile})"
    echo "    - max: $(max_glibc_version ${libfile})"
done
```

### Which `libstdc++.so.6` is `ctypes.util.find_library()` going to load?

```shell
python -c \
    "from ctypes.util import find_library; print(find_library('libstdc++.so.6'))"
```

If this is `None`, the path found by `ld` will be used.
