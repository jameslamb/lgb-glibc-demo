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

## Investigation

### Root Cause

TThe root cause of this issue is as follows:

> When `lib_lightgbm.so` is compiled with `gcc` not managed by `conda`, the compiler links against a C++ implementation in a location like `/usr/lib/x86_64-linux-gnu/libstdc++.so.6`.
>
> That linking is *dynamic*...it's expected that when the library is loaded in a Python session, `libstdc++.so.6` will be loaded at runtime.
>
> `conda`'s distribution of Python
>
> Using a `conda` distribution of CPython-based Python, when `lib_lightgbm.so` is loaded using `ctypes.cdll.LoadLibrary()`, if there are any `libstdc++.so.6` in `conda`'s lib paths, one of those will be loaded instead of the one in `/usr/lib`.
>
> This is because `conda` alters `ctypes`'s behavior to prefer directories managed by `conda`.

As described in https://gcc.gnu.org/onlinedocs/libstdc++/manual/abi.html, GNU C++ is architected for forward compatibility.

> It is not possible to take program binaries linked with the latest version of a library binary in a release series (with additional symbols added), substitute in the initial release of the library binary, and remain link compatible.

So if the C++ compiler links against a given `libstdc++.so` at build time, then at runtime it's necessary to link against a version of `libstdc++.so` that is *at least that new*.

So the issue here comes in when the `libstdc++.so` version available from the operating system (the one linked to by like `/usr/bin/g++`, for example) is newer than whatever ones are found in a given conda environment when loading the library.

There are two mechanisms by which errors like this can result from trying to load a `.so`/ `.dll` in `conda`'s Python:

1. via `conda`'s patches to `ctypes` and Python itself
2. beccause of the `RPATH` values se on `conda`'s 

`conda` makes this situation much more likely via its patch(es?) to `ctypes`.

```shell
LIB_LIGHTGBM='/root/miniforge/lib/python3.9/site-packages/lightgbm/lib_lightgbm.so'

# fails with conda Python
/root/miniforge/bin/python -c \
    "import ctypes; ctypes.cdll.LoadLibrary('${LIB_LIGHTGBM}')"

# succeeds with non-conda Python
/usr/bin/python3 -c \
    "import ctypes; ctypes.cdll.LoadLibrary('${LIB_LIGHTGBM}')"
```

### Research

## Workarounds that do not require modifying LightGBM

Code below should be run inside a container using the base image created above.

```shell
docker run \
    --rm \
    --workdir /usr/local/src/LightGBM/python-package \
    -it lgb-glibc-demo:local \
    /bin/bash
```

1. Use `conda`'s CMake and compilers to build LightGBM from source.

From https://conda.io/projects/conda-build/en/latest/resources/compiler-tools.html#using-the-compiler-packages

> Instead of `gcc`, the executable name of the compiler you use will be something like `x86_64-conda_cos6-linux-gnu-gcc`.

> Many build tools such as make and CMake search by default for a compiler named simply `gcc`, so we set environment variables to point these tools to the correct compiler.

> We set these variables in conda activate.d scripts, so any environment in which you will use the compilers must first be activated so the scripts will run. Conda-build does this activation for you using activation hooks installed with the compiler packages in `CONDA_PREFIX/etc/conda/activate.d`.

```shell
# install the problematic library
conda install -y -n base \
    libstdcxx-ng

# confirm that it resulting in a `libstdc++.so.6` being added in conda env
find / -name 'libstdc++.so.6'
# /root/miniforge/lib/libstdc++.so.6
# /root/miniforge/pkgs/libstdcxx-ng-11.2.0-he4da1e4_16/lib/libstdc++.so.6
# /usr/lib/x86_64-linux-gnu/libstdc++.so.6

# get conda compilers
conda install -y -n base \
    cmake \
    gcc_linux-64 \
    gxx_linux-64

# it's important to activate the target conda env, to set
# the relevant environment variables pointing to conda's compilers
source activate base

# you can see the effect of this by checking env variables
echo $CC
# /root/miniforge/bin/x86_64-conda-linux-gnu-cc

echo $CXX
# /root/miniforge/bin/x86_64-conda-linux-gnu-c++

cd /usr/local/src/LightGBM
pip uninstall -y lightgbm
rm -rf ./build
rm -f ./lib_lightgbm.so

cd ./python-package
pip install .

# confirm that importing works
python -c "import lightgbm; print(lightgbm.__version__)"
# 3.3.2.99

# confirm that the maximum GLIBCXX version is less than
# the one from the error message, and that the libstdc++.so.6 linked
# is the one from /root/miniforge
LIB_LIGHTGBM_IN_CONDA=$(
    find /root/miniforge -name 'lib_lightgbm.so' \
    | head -1
)
ldd -v \
    "${LIB_LIGHTGBM_IN_CONDA}"
```

2. Set `LD_PRELOAD` prior to loading `libstdc++.so.6`.

```shell
# install the problematic library
conda install -y -n base \
    libstdcxx-ng

# confirm that it resulted in a `libstdc++.so.6` being added in conda env
find / -name 'libstdc++.so.6'
# /root/miniforge/lib/libstdc++.so.6
# /root/miniforge/pkgs/libstdcxx-ng-11.2.0-he4da1e4_16/lib/libstdc++.so.6
# /usr/lib/x86_64-linux-gnu/libstdc++.so.6

# build LightGBM from source
cd /usr/local/src/LightGBM
pip uninstall -y lightgbm
rm -rf ./build
rm -f ./lib_lightgbm.so
cd ./python-package
pip install .

# try loading lightgbm (this will fail)
python -c "import lightgbm; print(lightgbm.__version__)"

# try loading lightgbm with LD_LIBRARY_PATH set to the same paths
# referenced in lib_lightgbm.so
LD_PRELOAD="${LD_PRELOAD}:/usr/lib/x86_64-linux-gnu/libstdc++.so.6" \
python -c "import lightgbm; print(lightgbm.__version__)"
```

NOTE: this cannot be done from inside Python. The following code will fail.

```python
import os
os.environ["LD_PRELOAD"] = "/usr/lib/x86_64-linux-gnu/libstdc++.so.6"
import lightgbm
```

3. Modify `lib_lightgbm.so`'s DT_RPATH tag so that it points at the place where it found `libstdc++.so.6`.

See https://man7.org/linux/man-pages/man3/dlopen.3.html and https://stackoverflow.com/a/20333550/3986677.
rpath is a way to embed a hint about where to find include dirs in a shared object.

```shell
cd /root/miniforge/lib/python3.9/site-packages/lightgbm/
cp lib_lightgbm.so lib_lightgbm2.so

# shows no rpath
chrpath -l lib_lightgbm2.so

# fails
python -c \
    "import ctypes; ctypes.cdll.LoadLibrary('/root/miniforge/lib/python3.9/site-packages/lightgbm/lib_lightgbm.so')"

# patch the rpath
patchelf --set-rpath '/usr/lib/x86_64-linux-gnu' lib_lightgbm2.so

# shows rpath
chrpath -l lib_lightgbm2.so

# succeeds!
python -c \
    "import ctypes; ctypes.cdll.LoadLibrary('/root/miniforge/lib/python3.9/site-packages/lightgbm/lib_lightgbm2.so')"
```

4. Inspect `lib_lightgbm.so` to figure out where the compiler found certain libraries, and copy any found from outside `conda` libraries into `conda`'s `lib/` directory.

```shell
# install the problematic library
conda install -y -n base \
    libstdcxx-ng

# confirm that it resulted in a `libstdc++.so.6` being added in conda env
find / -name 'libstdc++.so.6'
# /root/miniforge/lib/libstdc++.so.6
# /root/miniforge/pkgs/libstdcxx-ng-11.2.0-he4da1e4_16/lib/libstdc++.so.6
# /usr/lib/x86_64-linux-gnu/libstdc++.so.6

cd /usr/local/src/LightGBM
pip uninstall -y lightgbm
rm -rf ./build
rm -f ./lib_lightgbm.so

cd ./python-package
pip install .

# try loading lightgbm (this will fail)
python -c "import lightgbm; print(lightgbm.__version__)"

# find libraries linked against lib_lightgbm.so but not in conda's lib path
LIB_LIGHTGBM_IN_CONDA=$(
    find "${CONDA}" -name 'lib_lightgbm.so' \
    | head -1
)
LINKED_LIBRARIES_NOT_IN_CONDA_LIB_PATH=$(
    ldd ${LIB_LIGHTGBM_IN_CONDA} \
    | grep -oP '(?=\> ).*(?= )' \
    | tr -d '\> ' \
    | grep -v -E "^${CONDA}"
)

for libfile in ${LINKED_LIBRARIES_NOT_IN_CONDA_LIB_PATH}; do
    echo "copying '${libfile}' into ${CONDA}/lib"
    cp "${libfile}" "${CONDA}/lib/"
done

# now this should work
python -c "import lightgbm; print(lightgbm.__version__)"
# 3.3.2.99
```

## Ways LightGBM could mitigate this issue

1. Try setting RPATH at build time to create a "relocatable executable"
    - either by setting `LDFLAGS` or by using `patchelf` after compilation
    - see https://nehckl0.medium.com/creating-relocatable-linux-executables-by-setting-rpath-with-origin-45de573a2e98
2. In `setup.py`, after compilation (incl. when using `--precompile`), detect that we're using `conda`, then run `ldd` to check what is linked into `lib_lightgbm.so`, and try to copy into the current conda environment's `lib/` dir any shared objects that are not already found there.
    - conda patches `sys.prefix` to be the path to the current conda env, so that can be relied on
3. try-catch library loading, and if an `OSError` about missing libraries is raised, at least raise an informative error describing the workarounds listed above

## Attempted workarounds that do not work

## References
