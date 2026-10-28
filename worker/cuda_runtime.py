"""Make Windows CUDA libraries visible to Python and native lazy DLL loaders."""
from __future__ import annotations

import os
from pathlib import Path
import sys
import sysconfig


# Both AddDllDirectory cookies and loaded modules must outlive GPU inference.
_directory_handles = []
_library_handles = []
_configured = False


class CudaRuntimeError(RuntimeError):
    pass


def configure_windows_cuda():
    global _configured
    if sys.platform != "win32" or _configured:
        return

    import ctypes

    directories = []
    # PyInstaller preserves this same layout for the optional NVIDIA wheels.
    roots = [Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent)),
             Path(sysconfig.get_paths()["purelib"])]
    for root in roots:
        for component in ("cublas", "cudnn", "cuda_nvrtc"):
            directory = root / "nvidia" / component / "bin"
            if directory.is_dir() and directory not in directories:
                directories.append(directory)
    for variable in ("CUDA_PATH", "CUDNN_PATH"):
        value = os.environ.get(variable)
        if value:
            directory = Path(value) / "bin"
            if directory.is_dir() and directory not in directories:
                directories.append(directory)

    # Python's modern DLL search uses AddDllDirectory. CTranslate2/cuDNN also
    # load libraries by basename through native LoadLibrary, which needs PATH.
    for directory in directories:
        _directory_handles.append(os.add_dll_directory(str(directory)))
    if directories:
        os.environ["PATH"] = os.pathsep.join(
            [*(str(directory) for directory in directories), os.environ.get("PATH", "")])

    for name in ("cublasLt64_12.dll", "cublas64_12.dll", "cudnn64_9.dll"):
        location = next((directory / name for directory in directories
                         if (directory / name).is_file()), None)
        try:
            _library_handles.append(ctypes.WinDLL(str(location) if location else name))
        except OSError as error:
            raise CudaRuntimeError(
                f"Cannot load {name} for CUDA transcription: {error}. "
                "CUDA requires CUDA 12 cuBLAS and CUDA 12-compatible cuDNN 9, "
                "including their dependent DLLs, plus a compatible NVIDIA driver. "
                "Install/package this project's GPU runtime with "
                "scripts/setup_worker.ps1 -Cuda -Package, then rebuild with "
                "scripts/build_windows.ps1 -SkipWorker; alternatively install "
                "compatible system CUDA/cuDNN libraries on PATH. "
                "No CPU fallback was used."
            ) from error
    _configured = True
