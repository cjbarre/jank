# Jank AOT Library Linking Fix

## Problem

When using `jank compile` for AOT compilation, user-specified libraries via `-l` flags were not being passed to the linker. This caused "undefined symbols" errors for any external libraries (e.g., GLFW, ozz-animation, etc.).

## Root Cause

Two issues were identified:

### 1. User libraries not passed to linker (`aot/processor.cpp`)

The AOT processor iterated through `util::cli::opts.library_dirs` to add `-L` flags, but never iterated through `util::cli::opts.libs` to add `-l` flags. Only hardcoded jank dependencies were being linked.

**File:** `src/cpp/jank/aot/processor.cpp`

**Fix:** Added a loop to pass user-specified libraries to the linker (after line 238):

```cpp
/* User-specified libraries from -l flags. */
for(auto const &lib : util::cli::opts.libs)
{
  compiler_args.push_back(strdup(util::format("-l{}", lib).c_str()));
}
```

### 2. macOS JIT library name mismatch (`jit/processor.cpp`)

On macOS, the JIT's `default_shared_lib_name()` function was generating `{lib}.dylib` (e.g., `glfw.3.dylib`), but actual library files follow the convention `lib{lib}.dylib` (e.g., `libglfw.3.dylib`). This caused JIT to fail finding libraries even when they existed in the search paths.

The linker's `-l` flag expects the base name (e.g., `-lglfw.3`) and automatically prepends `lib` and appends `.dylib`, so users naturally specify library names without the `lib` prefix.

**File:** `src/cpp/jank/jit/processor.cpp`

**Fix:** Changed the macOS library name format to include the `lib` prefix:

```cpp
static jtl::immutable_string default_shared_lib_name(jtl::immutable_string const &lib)
#if defined(__APPLE__)
{
  return util::format("lib{}.dylib", lib);  // Was: "{}.dylib"
}
```

### 3. Missing macOS framework linking (`aot/processor.cpp`)

On macOS, OpenGL/GUI applications require linking against system frameworks (OpenGL, Cocoa, IOKit, CoreFoundation). These weren't being included in the AOT link step.

**File:** `src/cpp/jank/aot/processor.cpp`

**Fix:** Added macOS framework linking after user libraries:

```cpp
/* macOS requires framework linking for OpenGL/GUI applications. */
if constexpr(jtl::current_platform == jtl::platform::macos_like)
{
  for(auto const &framework : { "OpenGL", "Cocoa", "IOKit", "CoreFoundation" })
  {
    compiler_args.push_back(strdup("-framework"));
    compiler_args.push_back(strdup(framework));
  }
}
```

## Usage After Fix

Users can now specify libraries in the standard format:

```bash
jank -Llibs/mylib/lib -lmylib compile my.module -o output
```

Both JIT (for analysis during compilation) and the final linker will correctly find `libs/mylib/lib/libmylib.dylib`.

On macOS, OpenGL applications will automatically link against required system frameworks.

### 4. std::filesystem::exists() throws on permission denied (`util/clang.cpp`)

When distributing AOT-compiled jank programs, the `find_clang()` function checks hardcoded paths like `JANK_CLANG_PATH` that point to the build machine's filesystem. On end-user machines, these paths may exist but be inaccessible (permission denied), causing `std::filesystem::exists()` to throw an exception instead of returning false.

**File:** `src/cpp/jank/util/clang.cpp`

**Symptoms:**
```
libc++abi: terminating due to uncaught exception of type std::filesystem::__1::filesystem_error:
filesystem error: cannot get file status: Permission denied [/Users/cam/.../clang++]
```

**Fix:** Changed all `std::filesystem::exists()` calls to use the non-throwing overload that takes an `std::error_code` parameter:

```cpp
// Before (throws on permission denied):
if(std::filesystem::exists(configured_path))

// After (returns false on any error):
std::error_code ec;
if(std::filesystem::exists(configured_path, ec) && !ec)
```

**Locations fixed:**
- `find_clang()`: Lines checking `JANK_CLANG_PATH`, installed clang path, and `CXX` environment variable
- `find_pch()`: Lines checking dev_path and installed_path for PCH files
- `build_pch()`: Lines checking include_path and install_path for prelude.hpp

This allows the fallback logic to work correctly on end-user machines where the build machine's paths are inaccessible.

### 5. Reorder clang search to check bundled clang first (`util/clang.cpp`)

The `find_clang()` function originally checked `JANK_CLANG_PATH` (hardcoded at build time) before checking the bundled clang in the resource directory. On macOS, this triggers a permission prompt asking for Documents access when the hardcoded path points to the developer's machine.

**Fix:** Reordered the checks to look for bundled clang first:

```cpp
/* Check bundled clang first - this avoids triggering macOS permission prompts
 * for the hardcoded JANK_CLANG_PATH when running as a distributed app. */
std::filesystem::path const resource_dir{ util::resource_dir().c_str() };
std::filesystem::path const installed_path{ resource_dir / "bin/clang++" };
if(std::filesystem::exists(installed_path, ec) && !ec)
{
  return result = installed_path.c_str();
}

// Then check JANK_CLANG_PATH as fallback...
```

This ensures distributed apps find their bundled clang without triggering permission prompts for paths on the build machine.

### 6. Filter non-existent include paths from JIT flags (`jit/processor.cpp`)

`JANK_JIT_FLAGS` is baked into the binary at build time and contains `-I` flags pointing to include directories on the build machine (e.g., `-I/Users/cam/Documents/code/jank/...`). When these paths are passed to clang during JIT compilation, macOS prompts for Documents access even though the paths don't exist on the end-user's machine.

**Fix:** Filter out `-I` flags for non-existent directories before passing to clang:

```cpp
while(std::getline(flags, flag, ' '))
{
  /* Skip include paths that don't exist - these are baked in from the build machine
   * and will trigger macOS permission prompts when running distributed apps. */
  if(flag.starts_with("-I"))
  {
    std::error_code ec;
    auto const path{ flag.substr(2) };
    if(!std::filesystem::exists(path, ec) || ec)
    {
      continue;
    }
  }
  args.emplace_back(strdup(flag.c_str()));
}
```

This prevents the JIT compiler from attempting to access build-machine paths that don't exist on end-user systems.

**Important:** For `/Users/` paths, we check if they belong to the current user (by comparing with `$HOME`). Paths belonging to other users are skipped without any filesystem check, because even `std::filesystem::exists()` can trigger the macOS permission dialog.

```cpp
auto const home{ getenv("HOME") };
if(path.starts_with("/Users/") && (!home || !path.starts_with(home)))
{
  continue;  // Skip other users' paths without checking
}
```

The same fix was applied to `find_clang()` in `util/clang.cpp` for checking `JANK_CLANG_PATH` and `CXX` environment variable paths.

Also fixed `resource_dir()` in `util/environment.cpp` to use the non-throwing `std::filesystem::exists()` overload.

### 7. Detect app bundles and skip ALL build-machine paths (`jit/processor.cpp`, `util/clang.cpp`)

The previous fix (checking if paths belong to the current user via `$HOME`) doesn't work when the **developer** tests the distributed app on their own machine. The hardcoded paths like `/Users/cam/Documents/code/jank/...` start with the developer's `$HOME`, so they pass the check and trigger TCC prompts for Documents access.

**Fix:** Detect if we're running from inside a `.app` bundle by checking if the process path contains `.app/`. If so, skip ALL `/Users/` paths unconditionally - they're stale build-machine paths.

```cpp
/* Detect if we're running from inside a .app bundle */
auto const is_app_bundle{ util::process_path().find(".app/") != std::string::npos };

/* In the is_accessible_path lambda: */
if(path.starts_with("/Users/"))
{
  /* In app bundles, ALL /Users/ paths are stale build paths */
  if(is_app_bundle)
  {
    return false;
  }
  /* In development, only allow paths from current user */
  return home && path.starts_with(home);
}
```

This way:
- **In app bundles**: Skip all `/Users/` paths (even on the build machine)
- **In development**: Only skip other users' paths

Applied to both `jit/processor.cpp` (JANK_JIT_FLAGS filtering) and `util/clang.cpp` (`find_clang()` function).

### 8. Disable PCH validation when loading (`jit/processor.cpp`)

The precompiled header (PCH) is built with paths to headers on the build machine. When Clang loads the PCH, it may try to validate that those paths still exist, triggering macOS permission dialogs.

**Fix:** Add `-Xclang -fno-validate-pch` when loading the PCH:

```cpp
args.emplace_back("-include-pch");
args.emplace_back(strdup(pch_path_str.c_str()));
/* Disable PCH validation to prevent Clang from checking if the original
 * header paths still exist (they won't on end-user machines). */
args.emplace_back("-Xclang");
args.emplace_back("-fno-validate-pch");
```
