# research

This document contains my notes put together while investigating https://github.com/microsoft/LightGBM/issues/5106.

See [README.md](./README.md) for a more concise summary and list of recommendations.

## What happens when `lightgbm` (the Python package) loads `lib_lightgbm.so`

Whenever `lightgbm` is loaded with `import lightgbm`, it uses `ctypes.dll.LoadLibrary()` to load its compiled library, `lib_lightgbm.so`.

https://github.com/microsoft/LightGBM/blob/416ecd5a8de1b2b9225ded3c919cb0d40ec0d9bd/python-package/lightgbm/basic.py#L117

Simplified version of that code:

```python
def _load_lib():
    lib_path = find_lib_path()
    return ctypes.cdll.LoadLibrary(lib_path[0])


_LIB = _load_lib()
```

The `ctypes` documentation desccribes this process in detail.

From "Finding shared libraries" ([link](https://github.com/python/cpython/blob/b4e048411f4c62ad7343bca32c307f0bf5ef74b4/Doc/library/ctypes.rst#finding-shared-libraries))

> When programming in a compiled language, shared libraries are accessed when compiling/linking a program, and when the program is run.

> ...the `ctypes` library loaders act like when a program is run, and call the runtime loader directly.

And from "loading shared libraries" ([doc](https://github.com/python/cpython/blob/b4e048411f4c62ad7343bca32c307f0bf5ef74b4/Doc/library/ctypes.rst#loading-shared-libraries))

> If you have an existing handle to an already loaded shared library, it can be passed as the handle named parameter, otherwise the underlying platform's `dlopen` or `LoadLibrary` function is used to load the library into the process, and to get a handle to it.

To be clear, "underlying platform's `dlopen`" here refers to a standard C interface available on all operating systems.

For example, see https://man7.org/linux/man-pages/man3/dlopen.3.html for Linux.

From those docs, when searching for a library, the following are checked in order:

> (ELF only) If the calling object (i.e., the shared library or executable from which dlopen() is called) contains a DT_RPATH tag, and does not contain a DT_RUNPATH tag, then the directories listed in the DT_RPATH tag are searched.

> If, at the time that the program was started, the environment variable LD_LIBRARY_PATH was defined to contain a colon-separated list of directories, then these are searched.

> (ELF only) If the calling object contains a DT_RUNPATH tag, then the directories listed in that tag are searched.

> The cache file /etc/ld.so.cache (maintained by ldconfig(8)) is checked to see whether it contains an entry for filename.

> The directories /lib and /usr/lib are searched (in that order).

LightGBM uses `ctypes.cdll.LoadLibrary`.

`ctypes.cdll` is an instance of `ctypes.LibraryLoader`

https://github.com/python/cpython/blob/39a54ba63850e081a4a5551a773df5b4d5b1d3cd/Lib/ctypes/__init__.py#L458

Which uses the system's `dlopen()` to load libraries.

https://github.com/python/cpython/blob/39a54ba63850e081a4a5551a773df5b4d5b1d3cd/Lib/ctypes/__init__.py#L376

https://github.com/python/cpython/blob/39a54ba63850e081a4a5551a773df5b4d5b1d3cd/Lib/ctypes/__init__.py#L138

I found that, after compiling `lib_lightgbm.so`, `conda`-based Python failed to load it and non-`conda`-based Python loaded it successfully.

```shell
LIB_LIGHTGBM='/root/miniforge/lib/python3.9/site-packages/lightgbm/lib_lightgbm.so'

# fails with conda Python
/root/miniforge/bin/python -c \
    "import ctypes; ctypes.cdll.LoadLibrary('${LIB_LIGHTGBM}')"

# succeeds with non-conda Python
/usr/bin/python3 -c \
    "import ctypes; ctypes.cdll.LoadLibrary('${LIB_LIGHTGBM}')"
```

This made me think "ok, `conda` must have modified how Python looks for libraries when loading `.so` files".

First, I searched through all the `conda` patch files for mentions of `dlopen`...didn't find any.

```shell
CONDA_HOME=$(
    conda info --json \
    | jq -r .'"root_prefix"'
)
cd "${CONDA_HOME}"

cat $(find . -name '*.patch') \
| grep -i dlopen
```

So next I searched for `LoadLibrary`.

```shell
cat $(find . -name '*.patch') \
| grep -i LoadLibrary
```

That revealed one result!

```text
+    HMODULE hDLL = LoadLibraryExW(&test_dll[0], NULL, 0);
         hDLL = LoadLibraryExW(wpathname, NULL,
```

So then I searched for files with that.

```shell
grep -R LoadLibraryExW '**/*.patch'
```

And found the following file.

```text
pkgs/python-3.9.10-h85951f9_2_cpython/info/recipe/parent/patches/0014-Add-CondaEcosystemModifyDllSearchPath.patch
```

Look at what's in there!

```shell
cat pkgs/python-3.9.10-h85951f9_2_cpython/info/recipe/parent/patches/0014-Add-CondaEcosystemModifyDllSearchPath.patch
```

```text
From 05ed093c4a434e09ce52c28b578f35ea9c8af3fe Mon Sep 17 00:00:00 2001
From: Ray Donnelly <mingw.android@gmail.com>
Date: Tue, 24 Dec 2019 18:37:17 +0100
Subject: [PATCH 14/27] Add CondaEcosystemModifyDllSearchPath()

There are 2 modes depending on CONDA_DLL_SEARCH_MODIFICATION env variable

- unset CONDA_DLL_SEARCH_MODIFICATION (Default)

  In this mode, the python interpreter works as if the python interpreter
  was called with the following conda directories.

    os.add_dll_directory(join(sys.prefix, 'bin'))
    os.add_dll_directory(join(sys.prefix, 'Scripts'))
    os.add_dll_directory(join(sys.prefix, 'Library', 'bin'))
    os.add_dll_directory(join(sys.prefix, 'Library', 'usr', 'bin'))
    os.add_dll_directory(join(sys.prefix, 'Library', 'mingw-w64', 'bin'))

  Search order
    - The directory that contains the DLL (if looking for a dependency)
    - Application (python.exe) directory
    - Directories added with os.add_dll_directory
    - The 5 conda directories
    - C:\Windows\System32

  Note that the default behaviour changed in conda python 3.10 to
  make os.add_dll_directory work in user code.

- CONDA_DLL_SEARCH_MODIFICATION=1

  Search order is roughly,

    - The directory that contains the DLL (if looking for a dependency)
    - Application (python.exe) directory
    - C:\Windows
    - Current working directory
    - The 5 conda directories
    - PATH
    - Directories added with os.add_dll_directory
    - Old PATH entries (Deficiency in current patch)
    - Old working directories (Deficiency in current patch)
    - C:\Windows\System32

This changes the DLL search order so that C:\Windows\System32 does not
get searched in before entries in PATH.

Reviewed by Kai Tietz 7.2.2019

Updated a bit to include other directories.

Made fwprintfs breakpointable

From Shaun Walbridge:
Fix CondaEcosystemModifyDllSearchPath for users of the Python DLL

Co-authored-by: Isuru Fernando <isuruf@gmail.com>
---
 Modules/main.c       | 370 +++++++++++++++++++++++++++++++++++++++++++
 Python/dynload_win.c |   4 +
 Python/pylifecycle.c |   5 +-
 3 files changed, 378 insertions(+), 1 deletion(-)

diff --git a/Modules/main.c b/Modules/main.c
index 2cc891f61a..966d8c6595 100644
--- a/Modules/main.c
+++ b/Modules/main.c
@@ -17,6 +17,10 @@
 #endif
 #ifdef MS_WINDOWS
 #  include <windows.h>            // STATUS_CONTROL_C_EXIT
+#  include <shlwapi.h>
+#  include <string.h>
+#  include <malloc.h>
+#  include <libloaderapi.h>
 #endif
 /* End of includes for exit_sigint() */

@@ -691,10 +695,376 @@ Py_RunMain(void)
     return exitcode;
 }

+#ifdef MS_WINDOWS
+/* Please do not remove this function. It is needed for testing
+   CondaEcosystemModifyDllSearchPath(). */
+
+/*
+void LoadAndUnloadTestDLL(wchar_t* test_dll)
+{
+    wchar_t test_path[MAX_PATH + 1];
+    HMODULE hDLL = LoadLibraryExW(&test_dll[0], NULL, 0);
+    if (hDLL == NULL)
+    {
+        wchar_t err_msg[256];
+        DWORD err_code = GetLastError();
+        FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
+            NULL, err_code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
+            err_msg, (sizeof(err_msg) / sizeof(wchar_t)), NULL);
+        fwprintf(stderr, L"LoadAndUnloadTestDLL() :: ERROR :: Failed to load %ls, error is: %ls\n", &test_dll[0], &err_msg[0]);
+    }
+    GetModuleFileNameW(hDLL, &test_path[0], MAX_PATH);
+    fwprintf(stderr, L"LoadAndUnloadTestDLL() :: %ls loaded from %ls\n", &test_dll[0], &test_path[0]);
+    if (FreeLibrary(hDLL) == 0)
+    {
+        wchar_t err_msg[256];
+        DWORD err_code = GetLastError();
+        FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
+            NULL, err_code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
+            err_msg, (sizeof(err_msg) / sizeof(wchar_t)), NULL);
+        fwprintf(stderr, L"LoadAndUnloadTestDLL() :: ERROR :: Failed to free %ls, error is: %ls\n", &test_dll[0], &err_msg[0]);
+    }
+}
+*/
+
+/*
+    Provided CONDA_DLL_SEARCH_MODIFICATION_ENABLE is set (to anything at all!)
+    this function will modify the DLL search path so that C:\Windows\System32
+    does not appear before entries in PATH. If it does appear in PATH then it
+    gets added at the position it was in in PATH.
+
+    This is achieved via a call to SetDefaultDllDirectories() then calls to
+    AddDllDirectory() for each entry in PATH. We also take the opportunity to
+    clean-up these PATH entries such that any '/' are replaced with '\', no
+    double quotes occour and no PATH entry ends with '\'.
+
+    Caution: Microsoft's documentation says that the search order of entries
+    passed to AddDllDirectory is not respected and arbitrary. I do not think
+    this will be the case but it is worth bearing in mind.
+*/
+
+#if !defined(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS)
+#define LOAD_LIBRARY_SEARCH_DEFAULT_DIRS 0x00001000
+#endif
+
+/* Caching of prior processed PATH environment */
+static wchar_t *sv_path_env = NULL;
+typedef void (WINAPI *SDDD)(DWORD DirectoryFlags);
+typedef void (WINAPI *SDD)(PCWSTR SetDir);
+typedef void (WINAPI *ADD)(PCWSTR NewDirectory);
+static SDDD pSetDefaultDllDirectories = NULL;
+static SDD pSetDllDirectory = NULL;
+static ADD pAddDllDirectory = NULL;
+static int sv_failed_to_find_dll_fns = 0;
+/* Have hidden this behind a define because it is clearly not code that
+   could be considered for upstreaming so clearly delimiting it makes it
+   easier to remove. */
+#define HARDCODE_CONDA_PATHS
+#if defined(HARDCODE_CONDA_PATHS)
+typedef struct
+{
+    wchar_t *p_relative;
+    wchar_t *p_name;
+} CONDA_PATH;
+
+#define NUM_CONDA_PATHS 5
+
+static CONDA_PATH condaPaths[NUM_CONDA_PATHS] =
+{
+    {L"Library\\mingw-w64\\bin", NULL},
+    {L"Library\\usr\\bin", NULL},
+    {L"Library\\bin", NULL},
+    {L"Scripts", NULL},
+    {L"bin", NULL}
+};
+#endif /* HARDCODE_CONDA_PATHS */
+static wchar_t sv_dll_dirname[1024];
+static wchar_t sv_windows_directory[1024];
+static wchar_t *sv_added_windows_directory = NULL;
+static wchar_t *sv_added_cwd = NULL;
+
+int CondaEcosystemModifyDllSearchPath_Init()
+{
+    int debug_it = _wgetenv(L"CONDA_DLL_SEARCH_MODIFICATION_DEBUG") ? 1 : 0;
+    wchar_t* enable = _wgetenv(L"CONDA_DLL_SEARCH_MODIFICATION_ENABLE");
+    int res = 0;
+#if defined(HARDCODE_CONDA_PATHS)
+    long long j;
+    CONDA_PATH *p_conda_path;
+#endif /* defined(HARDCODE_CONDA_PATHS) */
+    HMODULE dll_handle = NULL;
+
+    if (pSetDefaultDllDirectories == NULL)
+    {
+        wchar_t *conda_prefix = _wgetenv(L"CONDA_PREFIX");
+        wchar_t *build_prefix = _wgetenv(L"BUILD_PREFIX");
+        wchar_t *prefix = _wgetenv(L"PREFIX");
+        pSetDefaultDllDirectories = (SDDD)GetProcAddress(GetModuleHandle(TEXT("kernel32.dll")), "SetDefaultDllDirectories");
+        pSetDllDirectory = (SDD)GetProcAddress(GetModuleHandle(TEXT("kernel32.dll")), "SetDllDirectoryW");
+        pAddDllDirectory = (ADD)GetProcAddress(GetModuleHandle(TEXT("kernel32.dll")), "AddDllDirectory");
+
+        /* Determine sv_dll_dirname */
+        if (GetModuleHandleEx(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
+            (LPCSTR) &CondaEcosystemModifyDllSearchPath_Init, &dll_handle) == 0)
+        {
+            // Getting the pythonxx.dll path failed. Fall back to relative path of python.exe
+            // assuming that the executable that is running this code is python.exe
+            dll_handle = NULL;
+        }
+        GetModuleFileNameW(dll_handle, &sv_dll_dirname[0], sizeof(sv_dll_dirname)/sizeof(sv_dll_dirname[0])-1);
+        sv_dll_dirname[sizeof(sv_dll_dirname)/sizeof(sv_dll_dirname[0])-1] = L'\0';
+        if (wcsrchr(sv_dll_dirname, L'\\'))
+            *wcsrchr(sv_dll_dirname, L'\\') = L'\0';
+
+#if defined(HARDCODE_CONDA_PATHS)
+        for (p_conda_path = &condaPaths[0]; p_conda_path < &condaPaths[NUM_CONDA_PATHS]; ++p_conda_path)
+        {
+            size_t n_chars_dll_dirname = wcslen(sv_dll_dirname);
+            size_t n_chars_p_relative = wcslen(p_conda_path->p_relative);
+            p_conda_path->p_name = malloc(sizeof(wchar_t) * (n_chars_dll_dirname + n_chars_p_relative + 2));
+            wcsncpy(p_conda_path->p_name, sv_dll_dirname, n_chars_dll_dirname+1);
+            wcsncat(p_conda_path->p_name, L"\\", 2);
+            wcsncat(p_conda_path->p_name, p_conda_path->p_relative, n_chars_p_relative+1);
+        }
+#endif /* defined(HARDCODE_CONDA_PATHS) */
+
+        /* Determine sv_windows_directory */
+        {
+            char tmp_ascii[1024];
+            size_t convertedChars = 0;
+            GetWindowsDirectory(&tmp_ascii[0], sizeof(tmp_ascii) / sizeof(tmp_ascii[0]) - 1);
+            tmp_ascii[sizeof(tmp_ascii) / sizeof(tmp_ascii[0]) - 1] = L'\0';
+            mbstowcs_s(&convertedChars, sv_windows_directory, strlen(tmp_ascii)+1, tmp_ascii, _TRUNCATE);
+            sv_windows_directory[sizeof(sv_windows_directory) / sizeof(sv_windows_directory[0]) - 1] = L'\0';
+        }
+    }
+
+    if (pSetDefaultDllDirectories == NULL || pSetDllDirectory == NULL || pAddDllDirectory == NULL)
+    {
+        if (debug_it)
+            fwprintf(stderr, L"CondaEcosystemModifyDllSearchPath() :: WARNING :: Please install KB2533623 from http://go.microsoft.com/fwlink/p/?linkid=217865\n"\
+                             L"CondaEcosystemModifyDllSearchPath() :: WARNING :: to improve conda ecosystem DLL isolation");
+        sv_failed_to_find_dll_fns = 1;
+        res = 2;
+    }
+#if defined(HARDCODE_CONDA_PATHS)
+    else if (enable == NULL || !wcscmp(enable, L"0")) {
+        for (j = NUM_CONDA_PATHS-1, p_conda_path = &condaPaths[NUM_CONDA_PATHS-1]; j > -1; --j, --p_conda_path)
+        {
+            if (debug_it)
+                fwprintf(stderr, L"CondaEcosystemModifyDllSearchPath() :: AddDllDirectory(%ls - ExePrefix)\n", p_conda_path->p_name);
+            pAddDllDirectory(p_conda_path->p_name);
+        }
+    }
+#endif /* defined(HARDCODE_CONDA_PATHS) */
+    return res;
+}
+
+int CondaEcosystemModifyDllSearchPath(int add_windows_directory, int add_cwd) {
+    int debug_it = _wgetenv(L"CONDA_DLL_SEARCH_MODIFICATION_DEBUG") ? 1 : 0;
+    const wchar_t *path_env = _wgetenv(L"PATH");
+    wchar_t current_working_directory[1024];
+    const wchar_t *p_cwd = NULL;
+    long long entry_num = 0;
+    long long i;
+    wchar_t **path_entries;
+    wchar_t *path_end;
+    long long num_entries = 1;
+#if defined(HARDCODE_CONDA_PATHS)
+    long long j;
+    CONDA_PATH *p_conda_path;
+    int foundCondaPath[NUM_CONDA_PATHS] = {0, 0, 0, 0, 0};
+#endif /* defined(HARDCODE_CONDA_PATHS) */
+    wchar_t *enable;
+
+    int SetDllDirectoryValue = LOAD_LIBRARY_SEARCH_DEFAULT_DIRS;
+    if (sv_failed_to_find_dll_fns)
+        return 1;
+
+    /* Fix for embedding the Python DLL. Courtesy of Shaun Walbridge
+     * if the CondaEcosystemModifyDllSearchPath_Init(argc, argv) code hasn't been run
+     * or failed to bind to the required functions in kernel32.dll, fail early to avoid
+     * an access violation. */
+    if (pSetDefaultDllDirectories == NULL || pSetDllDirectory == NULL || pAddDllDirectory == NULL)
+        return 1;
+
+    enable = _wgetenv(L"CONDA_DLL_SEARCH_MODIFICATION_ENABLE");
+    if (enable == NULL || !wcscmp(enable, L"0"))
+        return 0;
+    if (_wgetenv(L"CONDA_DLL_SEARCH_MODIFICATION_NEVER_ADD_WINDOWS_DIRECTORY"))
+        add_windows_directory = 0;
+    if (_wgetenv(L"CONDA_DLL_SEARCH_MODIFICATION_NEVER_ADD_CWD"))
+        add_cwd = 0;
+
+    if (add_cwd)
+    {
+        _wgetcwd(&current_working_directory[0], (sizeof(current_working_directory)/sizeof(current_working_directory[0])) - 1);
+        current_working_directory[sizeof(current_working_directory)/sizeof(current_working_directory[0]) - 1] = L'\0';
+        p_cwd = &current_working_directory[0];
+    }
+
+    /* cache path to avoid multiple adds */
+    if (sv_path_env != NULL && path_env != NULL && !wcscmp(path_env, sv_path_env))
+    {
+        if ((add_windows_directory && sv_added_windows_directory != NULL) ||
+            (!add_windows_directory && sv_added_windows_directory == NULL) )
+        {
+            if ((p_cwd == NULL && sv_added_cwd == NULL) ||
+                p_cwd != NULL && sv_added_cwd != NULL && !wcscmp(p_cwd, sv_added_cwd))
+            {
+                if (_wgetenv(L"CONDA_DLL_SEARCH_MODIFICATION_NEVER_CACHE") == NULL)
+                {
+                    if (debug_it)
+                        fwprintf(stderr, L"CondaEcosystemModifyDllSearchPath() :: INFO :: Values unchanged\n");
+                    return 0;
+                }
+            }
+        }
+    }
+    /* Something has changed.
+       Reset to default search order */
+    pSetDllDirectory(NULL);
+
+    if (sv_path_env != NULL)
+    {
+        free(sv_path_env);
+    }
+    sv_path_env = (path_env == NULL) ? NULL : _wcsdup(path_env);
+
+    if (path_env != NULL)
+    {
+        size_t len = wcslen(path_env);
+        wchar_t *path = (wchar_t *)alloca((len + 1) * sizeof(wchar_t));
+        if (debug_it)
+            fwprintf(stderr, L"CondaEcosystemModifyDllSearchPath() :: PATH=%ls\n\b", path_env);
+        memcpy(path, path_env, (len + 1) * sizeof(wchar_t));
+        /* Convert any / to \ */
+        /* Replace slash with backslash */
+        while ((path_end = wcschr(path, L'/')))
+            *path_end = L'\\';
+        /* Remove all double quotes */
+        while ((path_end = wcschr(path, L'"')))
+            memmove(path_end, path_end + 1, sizeof(wchar_t) * (len-- - (path_end - path)));
+        /* Remove all leading and double ';' */
+        while (*path == L';')
+            memmove(path, path + 1, sizeof(wchar_t) * len--);
+        while ((path_end = wcsstr(path, L";;")))
+            memmove(path_end, path_end + 1, sizeof(wchar_t) * (len-- - (path_end - path)));
+        /* Remove trailing ;'s */
+        while(path[len-1] == L';')
+            path[len-- - 1] = L'\0';
+
+        if (len == 0)
+            return 2;
+
+        /* Count the number of path entries */
+        path_end = path;
+        while ((path_end = wcschr(path_end, L';')))
+        {
+            ++num_entries;
+            ++path_end;
+        }
+
+        path_entries = (wchar_t **)alloca((num_entries) * sizeof(wchar_t *));
+        path_end = wcschr(path, L';');
+
+        if (getenv("CONDA_DLL_SET_DLL_DIRECTORY_VALUE") != NULL)
+            SetDllDirectoryValue = atoi(getenv("CONDA_DLL_SET_DLL_DIRECTORY_VALUE"));
+        pSetDefaultDllDirectories(SetDllDirectoryValue);
+        while (path != NULL)
+        {
+            if (path_end != NULL)
+            {
+                *path_end = L'\0';
+                /* Hygiene, no \ at the end */
+                while (path_end > path && path_end[-1] == L'\\')
+                {
+                    --path_end;
+                    *path_end = L'\0';
+                }
+            }
+            if (wcslen(path) != 0)
+                path_entries[entry_num++] = path;
+            path = path_end;
+            if (path != NULL)
+            {
+                while (*path == L'\0')
+                    ++path;
+                path_end = wcschr(path, L';');
+            }
+        }
+        for (i = num_entries - 1; i > -1; --i)
+        {
+#if defined(HARDCODE_CONDA_PATHS)
+            for (j = 0, p_conda_path = &condaPaths[0]; p_conda_path < &condaPaths[NUM_CONDA_PATHS]; ++j, ++p_conda_path)
+            {
+                if (!foundCondaPath[j] && !wcscmp(path_entries[i], p_conda_path->p_name))
+                {
+                    foundCondaPath[j] = 1;
+                    break;
+                }
+            }
+#endif /* defined(HARDCODE_CONDA_PATHS) */
+            if (debug_it)
+                fwprintf(stderr, L"CondaEcosystemModifyDllSearchPath() :: AddDllDirectory(%ls)\n", path_entries[i]);
+            pAddDllDirectory(path_entries[i]);
+        }
+    }
+
+#if defined(HARDCODE_CONDA_PATHS)
+    if (_wgetenv(L"CONDA_DLL_SEARCH_MODIFICATION_DO_NOT_ADD_EXEPREFIX") == NULL)
+    {
+        for (j = NUM_CONDA_PATHS-1, p_conda_path = &condaPaths[NUM_CONDA_PATHS-1]; j > -1; --j, --p_conda_path)
+        {
+            if (debug_it)
+                fwprintf(stderr, L"CondaEcosystemModifyDllSearchPath() :: p_conda_path->p_name = %ls, foundCondaPath[%zd] = %d\n", p_conda_path->p_name, j, foundCondaPath[j]);
+            if (!foundCondaPath[j])
+            {
+                if (debug_it)
+                    fwprintf(stderr, L"CondaEcosystemModifyDllSearchPath() :: AddDllDirectory(%ls - ExePrefix)\n", p_conda_path->p_name);
+                pAddDllDirectory(p_conda_path->p_name);
+            }
+        }
+    }
+#endif /* defined(HARDCODE_CONDA_PATHS) */
+
+    if (p_cwd)
+    {
+        if (sv_added_cwd != NULL && wcscmp(p_cwd, sv_added_cwd))
+        {
+            free(sv_added_cwd);
+        }
+        sv_added_cwd = _wcsdup(p_cwd);
+        if (debug_it)
+            fwprintf(stderr, L"CondaEcosystemModifyDllSearchPath() :: AddDllDirectory(%ls - CWD)\n", sv_added_cwd);
+        pAddDllDirectory(sv_added_cwd);
+    }
+
+    if (add_windows_directory)
+    {
+        sv_added_windows_directory = &sv_windows_directory[0];
+        if (debug_it)
+            fwprintf(stderr, L"CondaEcosystemModifyDllSearchPath() :: AddDllDirectory(%ls - WinDir)\n", sv_windows_directory);
+        pAddDllDirectory(sv_windows_directory);
+    }
+    else
+    {
+        sv_added_windows_directory = NULL;
+    }
+
+    return 0;
+}
+#endif
+

 static int
 pymain_main(_PyArgv *args)
 {
+#ifdef MS_WINDOWS
+    /* LoadAndUnloadTestDLL(L"libiomp5md.dll"); */
+    CondaEcosystemModifyDllSearchPath_Init(args->argc, args->wchar_argv);
+    /* LoadAndUnloadTestDLL(L"libiomp5md.dll"); */
+#endif
     PyStatus status = pymain_init(args);
     if (_PyStatus_IS_EXIT(status)) {
         pymain_free();
diff --git a/Python/dynload_win.c b/Python/dynload_win.c
index 81787e5f22..b4a34a9b6c 100644
--- a/Python/dynload_win.c
+++ b/Python/dynload_win.c
@@ -190,6 +190,10 @@ _Py_COMP_DIAG_POP
            to avoid DLL preloading attacks and enable use of the
            AddDllDirectory function. We add SEARCH_DLL_LOAD_DIR to
            ensure DLLs adjacent to the PYD are preferred. */
+        /* This resyncs values in PATH to AddDllDirectory() */
+        extern int CondaEcosystemModifyDllSearchPath(int, int);
+        CondaEcosystemModifyDllSearchPath(1, 1);
+
         Py_BEGIN_ALLOW_THREADS
         hDLL = LoadLibraryExW(wpathname, NULL,
                               LOAD_LIBRARY_SEARCH_DEFAULT_DIRS |
diff --git a/Python/pylifecycle.c b/Python/pylifecycle.c
index 60f091cbbe..b21f7b58f3 100644
--- a/Python/pylifecycle.c
+++ b/Python/pylifecycle.c
@@ -78,7 +78,10 @@ _PyRuntime_Initialize(void)
         return _PyStatus_OK();
     }
     runtime_initialized = 1;
-
+#ifdef MS_WINDOWS
+    extern int CondaEcosystemModifyDllSearchPath_Init();
+    CondaEcosystemModifyDllSearchPath_Init();
+#endif
     return _PyRuntimeState_Init(&_PyRuntime);
 }

--
2.35.0
```

```shell
cat pkgs/python-3.9.10-h85951f9_2_cpython/info/recipe/parent/patches/0019-Make-dyld-search-work-with-SYSTEM_VERSION_COMPAT-1.patch
```

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
ldd -v ${LIB_LIGHTGBM_IN_CONDA}
```

### What versions of `GLIBCXX` does `lib_lightgbm.so` require?

```shell
ldd -v ${LIB_LIGHTGBM_IN_CONDA} \
| grep -E 'GLIBCXX_[0-9]+'
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

Found that I could get more insight into what `ld` was doing by setting `LD_DEBUG=libs`.
This revealed that there is an `RPATH` set on `conda`'s Python distribution.

```text
search path=/root/miniforge/lib/python3.9/lib-dynload/../../glibc-hwcaps/x86-64-v3:/root/miniforge/lib/python3.9/lib-dynload/../../glibc-hwcaps/x86-64-v2:/root/miniforge/lib/python3.9/lib-dynload/../../tls/haswell/x86_64:/root/miniforge/lib/python3.9/lib-dynload/../../tls/haswell:/root/miniforge/lib/python3.9/lib-dynload/../../tls/x86_64:/root/miniforge/lib/python3.9/lib-dynload/../../tls:/root/miniforge/lib/python3.9/lib-dynload/../../haswell/x86_64:/root/miniforge/lib/python3.9/lib-dynload/../../haswell:/root/miniforge/lib/python3.9/lib-dynload/../../x86_64:/root/miniforge/lib/python3.9/lib-dynload/../..       (RPATH from file /root/miniforge/lib/python3.9/lib-dynload/_ctypes.cpython-39-x86_64-linux-gnu.so)
```





### Which `libstdc++.so.6` is `ctypes.util.find_library()` going to load?

```shell
python -c \
    "from ctypes.util import find_library; print(find_library('libstdc++.so.6'))"
```

If this is `None`, the path found by `ld` will be used.

### What RPATH entries (if any) exist in a shared object?

```shell
chrpath -l ${LIB_LIGHTGBM_IN_CONDA}

objdump -x "${LIB_LIGHTGBM_IN_CONDA}" \
| grep -i 'PATH'

readelf -d "${LIB_LIGHTGBM_IN_CONDA}" \
| grep -i 'PATH'
```

### How do I see the source of an imported Python function?

The example below shows how to see the source of `_ctypes.dlopen`.

```python
import inspect
import _ctypes
lines = inspect.getsource(_ctypes.dlopen)
print(lines)
```

### How do I get logs describing the decisions `ld` is making when loading a library?

```shell
LD_DEBUG=libs \
python -c \
    "import ctypes; ctypes.cdll.LoadLibrary('/root/miniforge/lib/python3.9/site-packages/lightgbm/lib_lightgbm.so')" 2>&1
```

h/t https://github.com/ContinuumIO/anaconda-issues/issues/7052#issuecomment-354995205
