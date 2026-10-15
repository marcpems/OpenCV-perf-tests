#Requires -Version 7.0
param(
    [string]$Root = '',
    [Parameter(Mandatory)][string]$CachedSource,
    [Parameter(Mandatory)][string]$ResultsDir
)
. "$PSScriptRoot\common.ps1"
$Root = Get-SourceRoot $Root
$CachedSource = (Resolve-Path -LiteralPath $CachedSource).ProviderPath
$ResultsDir = [IO.Path]::GetFullPath($ResultsDir, (Get-Location).ProviderPath)
if (Test-Path $ResultsDir) { throw ' ERROR - Choose a fresh DLS comparison directory.' }
New-Item -ItemType Directory $ResultsDir | Out-Null
$manifest = [ordered]@{
    status = 'running'; started_at = [datetimeoffset]::Now.ToString('o')
    order = @('original', 'cached', 'cached', 'original')
    cached_source_sha256 = (Get-FileHash $CachedSource).Hash
    runner_sha256 = (Get-FileHash $PSCommandPath).Hash
    completed_blocks = @()
}
$shell = (Get-Process -Id $PID).Path
try {
    for ($i = 0; $i -lt $manifest.order.Count; $i++) {
        if ((Get-FileHash $CachedSource).Hash -ne $manifest.cached_source_sha256) {
            throw ' ERROR - Cached-pointer source changed during comparison.'
        }
        $kind = $manifest.order[$i]
        $label = "block$($i + 1)_$kind"
        $options = if ($kind -eq 'cached') { @('-SourceOverride', $CachedSource) } else { @() }
        & $shell -NoProfile -File "$PSScriptRoot\run_compiler_microbench.ps1" -Root $Root `
            -ResultsDir "$ResultsDir\$label" -Sources 'calib3d/src/dls.cpp' `
            -Repetitions 2 -PhaseTiming @options
        if ($LASTEXITCODE -ne 0) { throw " ERROR - DLS comparison failed: $label" }
        $manifest.completed_blocks += $label
        $manifest | ConvertTo-Json -Depth 4 | Set-Content "$ResultsDir\study.json"
    }
    $manifest.status = 'succeeded'
    $manifest['finished_at'] = [datetimeoffset]::Now.ToString('o')
} catch {
    $manifest.status = 'failed'
    $manifest['error'] = $_.Exception.Message
    throw
} finally {
    $manifest | ConvertTo-Json -Depth 4 | Set-Content "$ResultsDir\study.json"
}
