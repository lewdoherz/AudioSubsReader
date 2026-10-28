"""Independent EPUB + timed speech -> portable .abook preparation worker."""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import uuid
import zipfile

from alignment import align
from epub import read_epub
from cuda_runtime import configure_windows_cuda


class PreparationError(ValueError):
    pass


def emit(kind: str, **values):
    print(json.dumps({"type": kind, **values}, ensure_ascii=False), flush=True)


def progress(message: str, value: float | None = None):
    fields = {"message": message}
    if value is not None:
        fields["progress"] = min(1.0, max(0.0, value))
    emit("progress", **fields)


def required_path(value, label: str) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise PreparationError(f"{label} must be a nonempty path")
    return Path(value).expanduser().resolve()


def audio_duration(path: Path) -> int:
    # PyAV is also faster-whisper's decoder; no system ffmpeg installation is required.
    import av
    with av.open(str(path)) as container:
        streams = list(container.streams.audio)
        if not streams:
            raise PreparationError(f"No audio stream in {path.name}")
        stream = streams[0]
        seconds = None
        if stream.duration is not None and stream.time_base is not None:
            seconds = float(stream.duration * stream.time_base)
        elif container.duration is not None:
            seconds = container.duration / av.time_base
        if seconds is None or not math.isfinite(seconds) or seconds <= 0:
            # Some WAV/streaming containers have no useful duration metadata.
            seconds = 0.0
            for frame in container.decode(stream):
                duration = frame.samples / frame.sample_rate
                if frame.time is not None:
                    seconds = max(seconds, float(frame.time) + duration)
                else:
                    seconds += duration
        milliseconds = round(seconds * 1000)
        if milliseconds <= 0:
            raise PreparationError(f"Audio track is empty or has invalid duration: {path.name}")
        return milliseconds


def normalize_words(words, duration_ms: int, label: str) -> list[dict]:
    if not isinstance(words, list):
        raise PreparationError(f"{label} must be a list of word objects")
    result = []
    previous_start = -1
    for index, word in enumerate(words):
        if not isinstance(word, dict) or not isinstance(word.get("word"), str):
            raise PreparationError(f"Invalid word object in {label}, word {index + 1}")
        start, end = word.get("start"), word.get("end")
        if (isinstance(start, bool) or isinstance(end, bool)
                or not isinstance(start, (int, float)) or not isinstance(end, (int, float))
                or not math.isfinite(start) or not math.isfinite(end)
                or start < 0 or end <= start):
            raise PreparationError(f"Invalid word timestamps in {label}, word {index + 1}")
        start_ms, end_ms = round(start * 1000), round(end * 1000)
        if start_ms < previous_start or end_ms > duration_ms:
            raise PreparationError(f"Unordered or out-of-track word timestamps in {label}, word {index + 1}")
        previous_start = start_ms
        if end_ms > start_ms:
            result.append({"word": word["word"], "startMs": start_ms, "endMs": end_ms})
    return result


def audio_chunks(path: Path, seconds: int = 90):
    """Yield bounded mono 16 kHz float32 chunks and sample-exact absolute offsets.

    The yielded buffer is reused on the next iteration; consume it synchronously.
    Flush the resampler so a partial final frame is never lost.
    """
    import av
    import numpy as np
    rate = 16000
    capacity = rate * seconds
    if capacity <= 0:
        raise PreparationError("Audio chunk duration must be positive")
    buffer = np.empty(capacity, dtype=np.float32)
    filled = 0
    emitted = 0
    with av.open(str(path)) as container:
        if not container.streams.audio:
            raise PreparationError(f"No audio stream in {path.name}")
        stream = container.streams.audio[0]
        resampler = av.AudioResampler(format="s16", layout="mono", rate=rate)

        def frames():
            for frame in container.decode(stream):
                yield from resampler.resample(frame)
            yield from resampler.resample(None)

        for frame in frames():
            samples = frame.to_ndarray().reshape(-1)
            position = 0
            while position < len(samples):
                count = min(capacity - filled, len(samples) - position)
                np.multiply(samples[position:position + count], 1.0 / 32768.0,
                            out=buffer[filled:filled + count], casting="unsafe")
                position += count
                filled += count
                if filled == capacity:
                    yield emitted / rate, buffer
                    emitted += filled
                    filled = 0
        if filled:
            yield emitted / rate, buffer[:filled]


def transcribe(paths: list[Path], durations: list[int], request: dict) -> list[list[dict]]:
    transcript = request.get("transcript")
    if transcript:
        path = required_path(transcript, "transcript")
        data = json.loads(path.read_text(encoding="utf-8-sig"))
        if not isinstance(data, list) or len(data) != len(paths):
            raise PreparationError("transcript must contain one word list per audio track, in track order")
        progress("Reading supplied word timestamps", 0.2)
        return [normalize_words(words, duration, f"transcript track {index + 1}")
                for index, (words, duration) in enumerate(zip(data, durations))]
    model = request.get("model")
    if not isinstance(model, str) or not model.strip():
        raise PreparationError("model must be a downloaded model directory or a cached faster-whisper model ID")
    device = request.get("device", "cpu")
    compute_type = request.get("computeType", "int8")
    language = request.get("language", "auto")
    if device not in ("cpu", "cuda"):
        raise PreparationError("device must be cpu or cuda")
    if compute_type not in ("int8", "float16", "float32"):
        raise PreparationError("computeType must be int8, float16, or float32")
    if not isinstance(language, str) or not language:
        raise PreparationError("language must be auto or an ISO language code")
    if device == "cuda":
        progress("Loading CUDA 12 / cuDNN 9 runtime", 0.14)
        configure_windows_cuda()
    # Never allow inference to download a model implicitly.
    progress("Loading local transcription model", 0.15)
    from faster_whisper import WhisperModel
    engine = WhisperModel(model, device=device, compute_type=compute_type, local_files_only=True)
    transcripts = []
    for track, path in enumerate(paths):
        progress(f"Transcribing track {track + 1}/{len(paths)}: {path.name}", 0.2 + 0.6 * track / len(paths))
        words = []
        for offset, samples in audio_chunks(path):
            segments, _ = engine.transcribe(samples, language=None if language == "auto" else language,
                                           task="transcribe", word_timestamps=True, vad_filter=True, beam_size=5)
            chunk_duration = len(samples) / 16000
            for segment in segments:
                for word in segment.words or []:
                    # Ignore zero-duration/padded hallucinations, never assign their
                    # timestamps to real text or interpolate across chunk boundaries.
                    start, end = offset + word.start, offset + word.end
                    if (0 <= word.start < word.end <= chunk_duration
                            and round(end * 1000) <= durations[track]):
                        words.append({"word": word.word, "start": start, "end": end})
                fraction = min(1.0, max(0.0, (offset + segment.end) * 1000 / durations[track]))
                progress(f"Transcribing track {track + 1}/{len(paths)}", 0.2 + 0.6 * (track + fraction) / len(paths))
        transcripts.append(normalize_words(words, durations[track], f"transcription track {track + 1}"))
    return transcripts


def publish_archive(output: Path, book: dict, audio: list[Path], images: dict[str, bytes]):
    manifest = json.dumps(book, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(manifest) > 64 * 1024 * 1024:
        raise PreparationError("Book manifest exceeds the reader's 64 MiB safety limit")
    if sum(path.stat().st_size for path in audio) + sum(map(len, images.values())) + len(manifest) > 64 * 1024 ** 3 - 1024 ** 2:
        raise PreparationError("Book package exceeds the reader's 64 GiB safety limit")
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".abook-", suffix=".tmp", dir=output.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(temporary, "w", allowZip64=True) as archive:
            archive.writestr("book.json", manifest, compress_type=zipfile.ZIP_DEFLATED)
            for track, source in zip(book["tracks"], audio):
                archive.write(source, track["path"], compress_type=zipfile.ZIP_STORED)
            for name, data in images.items():
                archive.writestr(name, data, compress_type=zipfile.ZIP_STORED)
        # Flush before publishing. A concurrent creator must never be overwritten.
        with temporary.open("rb+") as stream:
            os.fsync(stream.fileno())
        if os.name == "nt":
            os.rename(temporary, output)  # Windows rename fails when destination exists.
        else:
            os.link(temporary, output)  # Atomic create-if-absent on POSIX.
            temporary.unlink()
    finally:
        temporary.unlink(missing_ok=True)


def prepare(request_path: Path):
    request = json.loads(request_path.read_text(encoding="utf-8-sig"))
    if not isinstance(request, dict):
        raise PreparationError("request must be a JSON object")
    ebook_path = required_path(request.get("ebook"), "ebook")
    output = required_path(request.get("output"), "output")
    if output.suffix.lower() != ".abook":
        raise PreparationError("output must have the .abook extension")
    if output.exists():
        raise PreparationError("Output already exists; choose a new .abook filename")
    raw_audio = request.get("audio")
    if not isinstance(raw_audio, list) or not raw_audio:
        raise PreparationError("audio must be a nonempty ordered list of paths")
    audio = [required_path(path, "audio entry") for path in raw_audio]
    for path in [ebook_path, *audio]:
        if not path.is_file():
            raise PreparationError(f"Input file does not exist: {path}")
    progress("Reading EPUB spine and semantic formatting", 0.02)
    ebook = read_epub(ebook_path)
    durations = []
    for index, path in enumerate(audio):
        progress(f"Reading audio duration {index + 1}/{len(audio)}", 0.05 + 0.08 * index / len(audio))
        durations.append(audio_duration(path))
    transcripts = transcribe(audio, durations, request)
    progress("Aligning unique ebook anchors and timed words", 0.82)
    cues, alignment = align(ebook.blocks, transcripts)
    alignment["warnings"] = ebook.warnings + alignment["warnings"]
    if not request.get("transcript"):
        alignment["warnings"].append("Speech was decoded in bounded 90-second chunks; boundary words or padded out-of-range recognizer words may be omitted.")
    tracks = []
    for index, (path, duration) in enumerate(zip(audio, durations)):
        extension = path.suffix.lower()
        if not extension or not extension[1:].isascii() or not extension[1:].isalnum() or len(extension) > 12:
            raise PreparationError(f"Audio filename needs a simple extension: {path.name}")
        tracks.append({"path": f"audio/{index:03d}{extension}", "title": path.stem, "durationMs": duration})
    book = {"schemaVersion": 1, "id": str(uuid.uuid4()), "title": ebook.title, "author": ebook.author,
            "blocks": ebook.blocks, "tracks": tracks, "cues": cues, "alignment": alignment}
    progress("Packaging portable book and original audio", 0.92)
    publish_archive(output, book, audio, ebook.images)
    emit("done", output=str(output), matchedWords=alignment["matchedWords"], recognizedWords=alignment["recognizedWords"])


def download_model(model: str, root: Path):
    if not model or "\\" in model or any(part in ("", ".", "..") for part in model.split("/")):
        raise PreparationError("MODEL must be a faster-whisper model alias or repository ID")
    name = model.split("/")[-1]
    if any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for character in name):
        raise PreparationError("MODEL contains unsafe directory characters")
    target = root.resolve() / name
    progress(f"Downloading transcription model {model}; this explicitly requires network access", 0.0)
    from faster_whisper.utils import download_model as fetch_model
    result = fetch_model(model, output_dir=str(target), local_files_only=False)
    emit("done", output=str(Path(result).resolve()), model=model)


def main() -> int:
    # Flutter reads stdout as UTF-8 JSONL even on legacy Windows code pages.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="strict")
    parser = argparse.ArgumentParser(description=__doc__)
    def argument_error(message):
        raise PreparationError(message)
    parser.error = argument_error
    command = parser.add_mutually_exclusive_group(required=True)
    command.add_argument("--request", type=Path, help="Preparation request JSON file")
    command.add_argument("--download-model", metavar="MODEL", help="Explicitly download a faster-whisper model")
    parser.add_argument("--model-directory", type=Path, help="Model cache root; MODEL subdirectory is created")
    try:
        args = parser.parse_args()
        if args.download_model:
            if args.model_directory is None:
                raise PreparationError("--download-model requires --model-directory")
            download_model(args.download_model, args.model_directory)
        else:
            if args.model_directory is not None:
                raise PreparationError("--model-directory is only valid with --download-model")
            prepare(args.request)
        return 0
    except KeyboardInterrupt:
        emit("error", message="Preparation cancelled")
        return 130
    except Exception as error:
        emit("error", message=f"{type(error).__name__}: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
