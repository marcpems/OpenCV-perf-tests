#Requires -Version 7.0
. "$PSScriptRoot\..\scripts\compiler_commands.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory $temp | Out-Null
try {
    $output = "$temp\with space"
    $msvc = Set-CompilerOutputs '/O2 /EHa /Fo"old path\unit.obj" /Fdold.pdb -c source.cpp' 'MSVC' $output
    if ($msvc -ne "/O2 /EHa /Fo`"$output\unit.obj`" /Fd`"$output\unit.pdb`" -c source.cpp") {
        throw ' ERROR - MSVC output isolation changed other arguments.'
    }
    $clang = Set-CompilerOutputs '-O3 -MF "old path\unit.d" -o old.obj -c source.cpp' 'Clang' $output
    if ($clang -ne "-O3 -MF `"$output\unit.d`" -o `"$output\unit.obj`" -c source.cpp") {
        throw ' ERROR - Clang output isolation changed other arguments.'
    }
    foreach ($case in @(
        @{ args = '/O2 -c x.cpp'; toolchain = 'MSVC'; output = $output },
        @{ args = '-O3 -o x.obj -c x.cpp'; toolchain = 'Clang'; output = $output },
        @{ args = '/Fox.obj /Fdx.pdb'; toolchain = 'MSVC'; output = 'relative' }
    )) {
        $failed = $false
        try { Set-CompilerOutputs $case.args $case.toolchain $case.output | Out-Null }
        catch { $failed = $true }
        if (-not $failed) { throw ' ERROR - Unsafe compiler output rewrite accepted.' }
    }
    [IO.File]::WriteAllBytes("$temp\normal.obj", [byte[]]@(0x64, 0xAA, 0, 0))
    [IO.File]::WriteAllBytes("$temp\big.obj", [byte[]]@(0, 0, 255, 255, 2, 0, 0x64, 0xAA))
    Assert-Arm64Object "$temp\normal.obj"
    Assert-Arm64Object "$temp\big.obj"
    [IO.File]::WriteAllBytes("$temp\x64.obj", [byte[]]@(0x64, 0x86, 0, 0))
    $failed = $false
    try { Assert-Arm64Object "$temp\x64.obj" } catch { $failed = $true }
    if (-not $failed) { throw ' ERROR - Non-ARM64 object accepted.' }
    Write-Host 'PASS: compiler output redirection, command preservation and ARM64 COFF guards.'
} finally {
    Get-ChildItem -LiteralPath $temp -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Remove-Item -LiteralPath $temp
}
