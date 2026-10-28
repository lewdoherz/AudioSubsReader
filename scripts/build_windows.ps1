param([switch]$SkipWorker, [switch]$Cuda)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
  if (-not $SkipWorker) {
    & "$PSScriptRoot/setup_worker.ps1" -Package -Cuda:$Cuda
    if ($LASTEXITCODE -ne 0) { throw 'Worker packaging failed.' }
  }
  if (-not (Test-Path 'worker/runtime/prepare/prepare.exe')) {
    throw 'Packaged preparation runtime missing. Run scripts/setup_worker.ps1 -Package first.'
  }
  flutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed.' }
  $Version = ([regex]::Match((Get-Content pubspec.yaml -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)')).Groups[1].Value
  & worker/.venv/Scripts/python.exe scripts/collect_dependency_notices.py --release-source-url "https://github.com/lewdoherz/AudioSubsReader/releases/download/v$Version/AudioSubsReader-$Version-ffmpeg-lgpl-source.zip"
  if ($LASTEXITCODE -ne 0) { throw 'Runtime notice/source collection failed.' }
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
  Write-Host 'Run build/windows/x64/runner/Release/audiosubs_reader.exe. Distribute the entire Release folder, not only the executable. Models are downloaded separately.'
} finally { Pop-Location }
