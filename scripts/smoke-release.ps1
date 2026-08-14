$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$smokeRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'output\release-smoke'))
$expectedPrefix = [IO.Path]::GetFullPath((Join-Path $projectRoot 'output')) + [IO.Path]::DirectorySeparatorChar
if (-not $smokeRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Refusing to use smoke-test path outside the project output directory: $smokeRoot"
}

$releaseRoot = Join-Path $projectRoot 'release'
$installer = Join-Path $releaseRoot 'VizioControl Setup 1.0.0.exe'
$portable = Join-Path $releaseRoot 'VizioControl 1.0.0 Portable.exe'
$installRoot = Join-Path $smokeRoot 'installed'
$installedExe = Join-Path $installRoot 'VizioControl.exe'
$uninstaller = Join-Path $installRoot 'Uninstall VizioControl.exe'
$started = New-Object System.Collections.Generic.List[System.Diagnostics.Process]

function New-IsolatedAppData([string] $name) {
  $appData = Join-Path $smokeRoot $name
  $settings = @{
    version = 2
    settings = @{
      launchAtStartup = $false
      aiVisionEnabled = $true
      showPreview = $true
      alwaysStreamScreen = $false
      preferredProfile = ''
      manualAddress = ''
    }
    device = $null
    buttons = @()
  } | ConvertTo-Json -Depth 5
  foreach ($productName in @('VizioControl', 'viziocontrol')) {
    $userData = Join-Path $appData $productName
    New-Item -ItemType Directory -Path $userData -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $userData 'viziocontrol.json') -Value $settings -Encoding UTF8
  }
  return $appData
}

function Start-IsolatedProcess([string] $filePath, [string] $arguments, [string] $appData) {
  $info = [System.Diagnostics.ProcessStartInfo]::new()
  $info.FileName = $filePath
  $info.Arguments = $arguments
  $info.WorkingDirectory = Split-Path -Parent $filePath
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $localAppData = Join-Path $appData 'Local'
  New-Item -ItemType Directory -Path $localAppData -Force | Out-Null
  $previousAppData = $env:APPDATA
  $previousLocalAppData = $env:LOCALAPPDATA
  try {
    # Inherit an isolated environment without reading ProcessStartInfo's
    # case-insensitive dictionary, which rejects duplicate Path/PATH entries.
    $env:APPDATA = $appData
    $env:LOCALAPPDATA = $localAppData
    $process = [System.Diagnostics.Process]::Start($info)
  } finally {
    $env:APPDATA = $previousAppData
    $env:LOCALAPPDATA = $previousLocalAppData
  }
  if (-not $process) { throw "Could not start $filePath" }
  $started.Add($process)
  return $process
}

function Get-ProcessTreeIds([int] $rootId) {
  $snapshot = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId)
  $ids = New-Object System.Collections.Generic.List[int]
  $ids.Add($rootId)
  for ($index = 0; $index -lt $ids.Count; $index += 1) {
    $parent = $ids[$index]
    foreach ($child in $snapshot | Where-Object { $_.ParentProcessId -eq $parent }) {
      if (-not $ids.Contains([int] $child.ProcessId)) { $ids.Add([int] $child.ProcessId) }
    }
  }
  return @($ids)
}

function Stop-ProcessTree([System.Diagnostics.Process] $rootProcess) {
  $ids = @(Get-ProcessTreeIds $rootProcess.Id)
  [Array]::Reverse($ids)
  foreach ($id in $ids) {
    Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Milliseconds 600
}

function Assert-AppStaysRunning([System.Diagnostics.Process] $process, [string] $label) {
  Start-Sleep -Seconds 8
  $tree = @(Get-ProcessTreeIds $process.Id | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
  if ($tree.Count -eq 0) { throw "$label exited during startup." }
  return $tree.Count
}

if (-not (Test-Path -LiteralPath $installer) -or -not (Test-Path -LiteralPath $portable)) {
  throw 'Release artifacts are missing. Run npm run package first.'
}

if (Test-Path -LiteralPath $smokeRoot) {
  Remove-Item -LiteralPath $smokeRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $smokeRoot -Force | Out-Null

$installedTreeCount = 0
$portableTreeCount = 0
$uninstalled = $false
try {
  $installerData = New-IsolatedAppData 'installer-appdata'
  $installProcess = Start-IsolatedProcess $installer "/S /D=$installRoot" $installerData
  if (-not $installProcess.WaitForExit(180000)) { throw 'Installer smoke test timed out.' }
  if ($installProcess.ExitCode -ne 0) { throw "Installer exited with code $($installProcess.ExitCode)." }
  if (-not (Test-Path -LiteralPath $installedExe)) { throw 'Installer completed without creating VizioControl.exe.' }

  $installedProcess = Start-IsolatedProcess $installedExe '--hidden' $installerData
  $installedTreeCount = Assert-AppStaysRunning $installedProcess 'Installed VizioControl'
  Stop-ProcessTree $installedProcess

  if (-not (Test-Path -LiteralPath $uninstaller)) { throw 'The installed build did not include its uninstaller.' }
  $uninstallProcess = Start-IsolatedProcess $uninstaller '/S' $installerData
  if (-not $uninstallProcess.WaitForExit(180000)) { throw 'Uninstaller smoke test timed out.' }
  if ($uninstallProcess.ExitCode -ne 0) { throw "Uninstaller exited with code $($uninstallProcess.ExitCode)." }
  $uninstallDeadline = [DateTime]::UtcNow.AddSeconds(30)
  while ((Test-Path -LiteralPath $installedExe) -and [DateTime]::UtcNow -lt $uninstallDeadline) {
    Start-Sleep -Milliseconds 500
  }
  $uninstalled = -not (Test-Path -LiteralPath $installedExe)
  if (-not $uninstalled) { throw 'Uninstall completed but the installed executable remains.' }

  $portableData = New-IsolatedAppData 'portable-appdata'
  $portableProcess = Start-IsolatedProcess $portable '--hidden' $portableData
  $portableTreeCount = Assert-AppStaysRunning $portableProcess 'Portable VizioControl'
  Stop-ProcessTree $portableProcess

  [PSCustomObject]@{
    ok = $true
    installerExitCode = $installProcess.ExitCode
    installedProcessTree = $installedTreeCount
    uninstallVerified = $uninstalled
    portableProcessTree = $portableTreeCount
  } | ConvertTo-Json -Compress
} finally {
  foreach ($process in $started) {
    if ($process -and -not $process.HasExited) { Stop-ProcessTree $process }
  }
  if (Test-Path -LiteralPath $smokeRoot) {
    for ($attempt = 0; $attempt -lt 10 -and (Test-Path -LiteralPath $smokeRoot); $attempt += 1) {
      Remove-Item -LiteralPath $smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $smokeRoot) { Start-Sleep -Milliseconds 500 }
    }
  }
}
