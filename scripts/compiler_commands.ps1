function Get-CompilerCommand([string]$Root, [string]$Source, [string]$Toolchain) {
    $build = Get-BuildDirectory $Root 'Ninja' $Toolchain
    $receipt = Get-Content "$build\benchmark-setup.json" -Raw | ConvertFrom-Json
    Assert-WindowsSDK $receipt $Toolchain
    Assert-NativeExecutable $receipt.compiler $receipt.architecture
    if ((Get-FileHash $receipt.compiler).Hash -ne $receipt.compiler_sha256) {
        throw ' ERROR - Compiler changed since setup.'
    }
    $entry = Select-String "$build\CMakeCache.txt" -Pattern '^CMAKE_MAKE_PROGRAM:[^=]+=(.+)$'
    if (-not $entry) { throw ' ERROR - Configured Ninja executable not found.' }
    $ninja = $entry.Matches[0].Groups[1].Value
    $target = "modules/world/CMakeFiles/opencv_world.dir/__/$Source.obj"
    $commands = @(& $ninja -C $build -t commands $target)
    if ($LASTEXITCODE -ne 0) { throw " ERROR - Cannot retrieve compile command: $Source" }
    $sourcePath = "$Root\modules\$Source".Replace('\', '/')
    $commands = @($commands | Where-Object {
        $_ -match '(?: -c | /c )' -and $_.Replace('\', '/').Contains($sourcePath)
    })
    if ($commands.Count -ne 1) { throw " ERROR - Expected one compile command for $Source." }
    $command = $commands[0]
    if ($command -notmatch '^(?:"([^"]+)"|(\S+))\s+(.+)$') { throw ' ERROR - Cannot parse compiler command.' }
    $executable = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
    $arguments = $Matches[3]
    if ((Get-FileHash $executable).Hash -ne $receipt.compiler_sha256) {
        throw ' ERROR - Ninja command selects another compiler.'
    }
    return @{
        Build = $build; Receipt = $receipt; Command = $command
        Executable = $executable; Arguments = $arguments
    }
}

function Set-CompilerOutputs([string]$Arguments, [string]$Toolchain, [string]$Output) {
    if ($Output -match '["\r\n%!]' -or -not [IO.Path]::IsPathFullyQualified($Output)) {
        throw ' ERROR - Compiler output directory must be an absolute path without shell expansion characters.'
    }
    if ($Toolchain -eq 'MSVC') {
        if ($Arguments -notmatch '/Fo\S+' -or $Arguments -notmatch '/Fd\S+') {
            throw ' ERROR - Missing MSVC output flags.'
        }
        $Arguments = $Arguments -replace '/Fo(?:"[^"]+"|\S+)', "/Fo`"$Output\unit.obj`""
        $Arguments = $Arguments -replace '/Fd(?:"[^"]+"|\S+)', "/Fd`"$Output\unit.pdb`""
    } elseif ($Toolchain -eq 'Clang') {
        if ($Arguments -notmatch ' -o \S+' -or $Arguments -notmatch ' -MF \S+') {
            throw ' ERROR - Missing Clang output flags.'
        }
        $Arguments = $Arguments -replace ' -o (?:"[^"]+"|\S+)', " -o `"$Output\unit.obj`""
        $Arguments = $Arguments -replace ' -MF (?:"[^"]+"|\S+)', " -MF `"$Output\unit.d`""
    } else { throw " ERROR - Unsupported compiler: $Toolchain" }
    return $Arguments
}

function Assert-Arm64Object([string]$Path) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        $machine = $reader.ReadUInt16()
        if ($machine -eq 0) {
            if ($reader.ReadUInt16() -ne 0xFFFF -or $reader.ReadUInt16() -lt 2) {
                throw ' ERROR - Invalid bigobj header.'
            }
            $machine = $reader.ReadUInt16()
        }
        if ($machine -ne 0xAA64) { throw " ERROR - Object is not ARM64: $Path (machine $machine)" }
    } finally { $reader.Dispose() }
}
