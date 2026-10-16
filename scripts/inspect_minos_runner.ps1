$ErrorActionPreference = 'Stop'
$tools = @{}
foreach ($name in @('pwsh','cmake','ninja','7z','python','git')) {
    $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $tools[$name] = if ($command) { $command.Source } else { $null }
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = if (Test-Path $vswhere) {
    $raw = & $vswhere -products '*' -format json
    if ($LASTEXITCODE) { throw 'Visual Studio inventory failed' }
    @($raw | ConvertFrom-Json | Select-Object installationPath,installationVersion,isComplete,isRebootRequired)
} else { @() }
$inventory = [ordered]@{
    runner = $env:RUNNER_NAME
    architecture = $env:PROCESSOR_ARCHITECTURE
    os = Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture
    device = Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model,TotalPhysicalMemory
    cpu = Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors
    volumes = @(Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter,FileSystem,Size,SizeRemaining)
    power_scheme = (& powercfg /getactivescheme | Out-String).Trim()
    tools = $tools
    visual_studio = $vs
    sdk_versions = @(Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Include" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
}
$json = $inventory | ConvertTo-Json -Depth 6
$json = $json -replace '(?i)[A-Z]:[\\\/]+Users[\\\/]+[^\\\/"]+', '<USERPROFILE>'
Write-Output $json
