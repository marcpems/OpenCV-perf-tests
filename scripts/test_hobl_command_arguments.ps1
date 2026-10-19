#Requires -Version 7.0
param([Parameter(Mandatory)][string]$HoblRoot)
$ErrorActionPreference = 'Stop'
$path = Join-Path $HoblRoot 'scenarios\windows\opencv_build\opencv_build_resources\opencv_build_run.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ' ERROR - Candidate PowerShell did not parse.' }
$commands = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'cmake'
}, $true))
$arguments = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$msbuildArgs'
}, $true))
if ($commands.Count -ne 3 -or $arguments.Count -ne 1) {
    throw ' ERROR - Unexpected command layout.'
}
$cleanLog = $buildLog = $installLog = $null
function cmake { $script:captured = @($args) }
foreach ($buildJobs in @(1,12,20)) {
    Invoke-Expression $arguments[0].Extent.Text
    $expected = @{
        0 = @('--build','.','--target','clean','--config','Release','--') + $msbuildArgs
        1 = @('--build','.','--config','Release','--parallel',"$buildJobs",'--') + $msbuildArgs
        2 = @('--build','.','--target','INSTALL','--config','Release','--') + $msbuildArgs
    }
    for ($i = 0; $i -lt 3; $i++) {
        Invoke-Expression $commands[$i].Extent.Text
        $boundExpected = @($expected[$i] | Where-Object { $_ -ne '--' })
        if (($script:captured -join '|') -ne ($boundExpected -join '|') -or
            $commands[$i].Extent.Text -notmatch ' -- @msbuildArgs') {
            throw " ERROR - Unexpected CMake argument forwarding for phase $i, budget $buildJobs."
        }
        if ($script:captured -notcontains "/p:MultiProcMaxCount=$buildJobs") {
            throw ' ERROR - Compiler budget is not bound to the chosen processor count.'
        }
    }
}
Write-Output 'Verified exact clean/build/install arguments for budgets 1, 12 and 20.'
