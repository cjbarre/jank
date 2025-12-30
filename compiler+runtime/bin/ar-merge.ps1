# CMake will copy this script into the build directory when configuring
# and it will replace these variables with the correct values.
$ar = "@CMAKE_AR@"
$cmake_binary_dir = "@CMAKE_CURRENT_BINARY_DIR@"
$cache_dir = "@CMAKE_CURRENT_BINARY_DIR@/ar-cache"

$ErrorActionPreference = "Stop"

# Ensure we're in the build directory so relative paths (like response files) work
Write-Host "ar-merge.ps1: Setting location to $cmake_binary_dir"
Set-Location $cmake_binary_dir
Write-Host "ar-merge.ps1: Current directory is $(Get-Location)"

$command = $args[0]
$remaining_args = $args[1..($args.Length - 1)]

# Ensure cache directory exists
if (-not (Test-Path $cache_dir)) {
    New-Item -ItemType Directory -Path $cache_dir -Force | Out-Null
}

switch ($command) {
    # We only use this from ./bin/clean. Generally, this should not be needed.
    "clean" {
        if (Test-Path $cache_dir) {
            Remove-Item -Recurse -Force $cache_dir
        }
        New-Item -ItemType Directory -Path $cache_dir -Force | Out-Null
    }

    # We use this prior to building the jank executable, but after building all libraries.
    "merge" {
        $object_files = Get-ChildItem -Path $cache_dir -File | ForEach-Object { Get-Content $_.FullName } | Where-Object { $_ }
        $merge_output = "$cmake_binary_dir/libjank-standalone-phase-1.a"
        if (Test-Path $merge_output) {
            Remove-Item -Force $merge_output
        }
        # On Windows with LLVM, we still use llvm-ar which uses the same syntax
        & $ar qc $merge_output @object_files
    }

    # This follows merge, but also bundles in the Clojure core library object files, following
    # jank's phase 2 building.
    "merge-phase-2" {
        $object_files = @(Get-ChildItem -Path $cache_dir -File | ForEach-Object { Get-Content $_.FullName } | Where-Object { $_ })
        $object_files += "$cmake_binary_dir/core-libs/clojure/core.o"
        $merge_output = "$cmake_binary_dir/libjank-standalone.a"
        if (Test-Path $merge_output) {
            Remove-Item -Force $merge_output
        }
        & $ar qc $merge_output @object_files
    }

    # No custom command, so just pass this onto the original AR but keep track of all of
    # the object files referenced.
    default {
        $output = $remaining_args[0]
        $object_args = $remaining_args[1..($remaining_args.Length - 1)]
        $base = $output -replace '[/\\]', '_'
        $list_file = "$cache_dir/$base.list"

        Write-Host "ar-merge.ps1 default: command=$command output=$output"
        Write-Host "ar-merge.ps1 default: object_args=$object_args"

        # Expand response files to get actual object file paths
        # This is needed because response files are temporary and won't exist at merge time
        $expanded_args = @()
        foreach ($arg in $object_args) {
            if ($arg -match '^@(.+)$') {
                $rspFile = $Matches[1]
                Write-Host "ar-merge.ps1 default: Expanding response file: $rspFile"
                if (Test-Path $rspFile) {
                    # Read response file and add each line as an object file
                    $rspContents = Get-Content $rspFile
                    foreach ($line in $rspContents) {
                        $trimmed = $line.Trim()
                        if ($trimmed -ne "") {
                            $expanded_args += $trimmed
                        }
                    }
                    Write-Host "ar-merge.ps1 default: Expanded to $($expanded_args.Count) object files"
                } else {
                    Write-Host "ar-merge.ps1 default: Response file NOT FOUND: $rspFile"
                    $expanded_args += $arg
                }
            } else {
                $expanded_args += $arg
            }
        }

        if (Test-Path $list_file) {
            Remove-Item -Force $list_file
        }
        # Store expanded object files, not response file references
        $expanded_args -join "`n" | Out-File -FilePath $list_file -Encoding utf8

        Write-Host "ar-merge.ps1 default: Running $ar $command $output with args"
        & $ar $command $output @object_args
    }
}
