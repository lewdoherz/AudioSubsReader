$ErrorActionPreference = 'Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
  flutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed.' }
  flutter build apk --release --target-platform android-arm64,android-x64
  if ($LASTEXITCODE -ne 0) { throw 'Android build failed.' }
  Write-Host 'Player-only APK: build/app/outputs/flutter-apk/app-release.apk. This local build uses the development signing key, not a store-release key.'
} finally { Pop-Location }
