#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Python = 'py',
    [switch]$Package,
    [switch]$Cuda,
    [string]$DownloadModel,
    [string]$ModelDirectory
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Worker = Join-Path $Root 'worker'
$Venv = Join-Path $Worker '.venv'
$WorkerPython = Join-Path $Venv 'Scripts\python.exe'

function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $Executable $($Arguments -join ' ')"
    }
}

if (-not (Test-Path -LiteralPath $WorkerPython)) {
    $CreateArguments = @('-m', 'venv', $Venv)
    if ([IO.Path]::GetFileNameWithoutExtension($Python) -eq 'py') {
        $CreateArguments = @('-3.12') + $CreateArguments
    }
    Invoke-Checked $Python $CreateArguments
}
Invoke-Checked $WorkerPython @('-c', 'import sys; assert sys.version_info[:2] == (3, 12), "Python 3.12 is required; recreate worker/.venv with Python 3.12"')
Invoke-Checked $WorkerPython @('-m', 'pip', 'install', '--upgrade', 'pip')
& (Join-Path $PSScriptRoot 'build_lgpl_pyav.ps1')
if ($LASTEXITCODE -ne 0) { throw 'LGPL PyAV build/provenance verification failed.' }
Invoke-Checked $WorkerPython @('-m', 'pip', 'install', '--requirement', (Join-Path $Worker 'requirements.txt'))
if ($Cuda) {
    Invoke-Checked $WorkerPython @('-m', 'pip', 'install', '--requirement', (Join-Path $Worker 'requirements-cuda.txt'))
}

if ($DownloadModel) {
    if (-not $ModelDirectory) {
        $ModelDirectory = Join-Path $Worker 'models'
    }
    Invoke-Checked $WorkerPython @((Join-Path $Worker 'prepare.py'), '--download-model', $DownloadModel, '--model-directory', $ModelDirectory)
}

if ($Package) {
    # Keep native decoder/inference DLLs and VAD model assets alongside the executable.
    # No installed Python is needed by the resulting runtime/prepare directory.
    $Arguments = @(
        '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir', '--console',
        '--name', 'prepare',
        '--distpath', (Join-Path $Worker 'runtime'),
        '--workpath', (Join-Path $Worker '.package-build'),
        '--specpath', (Join-Path $Worker '.package-build'),
        '--collect-all', 'faster_whisper',
        '--collect-all', 'ctranslate2',
        '--collect-all', 'av',
        '--collect-all', 'tokenizers',
        '--collect-all', 'onnxruntime',
        '--collect-all', 'huggingface_hub',
        '--collect-all', 'resvg_py'
    )
    # Include private NVIDIA wheels when installed, without requiring Python
    # namespace packages at runtime. CPU-only environments keep a lean bundle.
    foreach ($Component in @('cublas', 'cudnn', 'cuda_nvrtc')) {
        $BinaryDirectory = Join-Path $Venv "Lib\site-packages\nvidia\$Component\bin"
        if (Test-Path -LiteralPath $BinaryDirectory) {
            $Arguments += @('--add-binary', "$BinaryDirectory\*.dll;nvidia/$Component/bin")
            $DistributionName = 'nvidia-' + $Component.Replace('_', '-') + '-cu12'
            $Arguments += @('--copy-metadata', $DistributionName)
        }
    }
    $Arguments += (Join-Path $Worker 'prepare.py')
    Invoke-Checked $WorkerPython $Arguments
    # Our loader uses the explicit optional NVIDIA runtime or system cuDNN.
    # Do not redistribute CT2's redundant vendor DLL without its own licence.
    $RedundantCudnn = Join-Path $Worker 'runtime\prepare\_internal\ctranslate2\cudnn64_9.dll'
    if (Test-Path -LiteralPath $RedundantCudnn) { Remove-Item -LiteralPath $RedundantCudnn }
    Invoke-Checked $WorkerPython @((Join-Path $PSScriptRoot 'lgpl_pyav.py'), 'verify', '--bundle', (Join-Path $Worker 'runtime\prepare'))
    Write-Host ('Packaged preparation runtime: ' + (Join-Path $Worker 'runtime\prepare\prepare.exe'))
}
Write-Host ('Preparation Python: ' + $WorkerPython)
