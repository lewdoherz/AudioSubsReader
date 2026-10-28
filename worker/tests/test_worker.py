from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import stat
import struct
import sys
import tempfile
import unittest
import wave
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from alignment import align, match_tokens, tokenize
from epub import EpubError, SafeArchive, member_path, read_epub, resolve_reference
import prepare


def block(text: str, identifier="b0", kind="p"):
    return {"id": identifier, "chapter": "Chapter", "kind": kind,
            "runs": [{"text": text, "bold": False, "italic": False, "underline": False}]}


def timed(text: str, track_start=0):
    return [{"word": word, "startMs": track_start + i * 400, "endMs": track_start + i * 400 + 250}
            for i, word in enumerate(text.split())]


def make_epub(path: Path, body: str, extra=None):
    contents = {
        "mimetype": "application/epub+zip",
        "META-INF/container.xml": '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
        "OPS/book.opf": '<package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Unicode &amp; Style</dc:title><dc:creator>A Writer</dc:creator></metadata><manifest><item id="second" href="text/second.xhtml" media-type="application/xhtml+xml"/><item id="first" href="text/first.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="first"/><itemref idref="second"/></spine></package>',
        "OPS/text/first.xhtml": '<html><body>' + body + '</body></html>',
        "OPS/text/second.xhtml": '<html><body><h2>Second chapter</h2><p>Final words.</p></body></html>',
    }
    contents.update(extra or {})
    with zipfile.ZipFile(path, "w") as archive:
        for name, data in contents.items():
            archive.writestr(name, data)


def make_wav(path: Path, seconds=1.0, rate=16000):
    with wave.open(str(path), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(rate)
        # A nonzero tail detects loss of residual resampler frames.
        audio.writeframes(struct.pack("<h", 8192) * round(rate * seconds))


class AlignmentTests(unittest.TestCase):
    def test_utf16_original_spelling_and_combining_marks(self):
        text = "😀 naïve cafe\u0301 Straße l’amour 𐐀"
        tokens = list(tokenize(text))
        self.assertEqual([token[0] for token in tokens], ["naïve", "café", "strasse", "l'amour", "𐐨"])
        self.assertEqual(tokens[0][1:], (3, 8))
        self.assertEqual(tokens[-1][2] - tokens[-1][1], 2)
        encoded = text.encode("utf-16-le")
        self.assertEqual(encoded[tokens[1][1] * 2:tokens[1][2] * 2].decode("utf-16-le"), "cafe\u0301")
        cues, summary = align([block(text)], [timed("naïve café strasse l'amour 𐐨")])
        self.assertEqual(summary["matchedWords"], 5)
        self.assertEqual(cues[0]["start"], 3)
        self.assertEqual(cues[-1]["end"] - cues[-1]["start"], 2)

    def test_unspaced_cjk_words_keep_original_ranges(self):
        cues, summary = align([block("你好，世界。")], [[
            {"word": "你好", "startMs": 0, "endMs": 300},
            {"word": "世界", "startMs": 500, "endMs": 800},
        ]])
        self.assertEqual(summary["matchedWords"], 2)
        self.assertEqual([(cue["start"], cue["end"]) for cue in cues], [(0, 2), (3, 5)])

    def test_recovers_after_large_ebook_omission(self):
        opening = "the quiet river winds beside ancient stones"
        ending = "later brilliant stars appeared above the sleeping village"
        omitted = " ".join(f"omission{i}" for i in range(4000))
        text = f"{opening} {omitted} {ending}"
        spoken = f"{opening} {ending}"
        cues, summary = align([block(text)], [timed(spoken)])
        self.assertEqual(summary["matchedWords"], len(spoken.split()))
        self.assertGreater(cues[len(opening.split())]["start"], len(omitted))
        self.assertTrue(all(cue["endMs"] - cue["startMs"] == 250 for cue in cues))

    def test_ambiguous_repeated_passage_stays_unaligned(self):
        cues, summary = align([block("red green blue red green blue")], [timed("red green blue")])
        self.assertEqual(cues, [])
        self.assertEqual(summary["matchedWords"], 0)
        self.assertTrue(any("ambiguous" in warning for warning in summary["warnings"]))

    def test_fuzzy_spelling_only_inside_strong_short_gap(self):
        book = "one brave little extraordinary fox ran through green woods"
        spoken = "one brave little extraordinery fox ran through green woods"
        mapping = match_tokens(spoken.split(), book.split())
        self.assertEqual(mapping[3], 3)
        self.assertEqual(len(mapping), len(book.split()))
        self.assertEqual(match_tokens(["extraordinery"], ["extraordinary"]), {})

    def test_does_not_fuzz_semantically_different_word(self):
        book = "one brave little planet fox ran through green woods"
        spoken = "one brave little plants fox ran through green woods"
        mapping = match_tokens(spoken.split(), book.split())
        self.assertNotIn(3, mapping)
        self.assertIn(4, mapping)

    def test_multiple_tracks_keep_global_book_order_and_local_timing(self):
        blocks = [block("alpha beta gamma delta", "first"), block("epsilon zeta eta theta", "second")]
        cues, summary = align(blocks, [timed("alpha beta gamma delta"), timed("epsilon zeta eta theta")])
        self.assertEqual(summary["matchedWords"], 8)
        self.assertEqual(cues[4]["track"], 1)
        self.assertEqual(cues[4]["startMs"], 0)
        self.assertEqual(cues[4]["blockId"], "second")
        self.assertEqual(cues[0]["endMs"], 250)  # The 150ms silence is not filled.

    def test_recognizer_multi_token_word_is_not_double_counted(self):
        words = [{"word": "hello-world", "startMs": 0, "endMs": 500}]
        cues, summary = align([block("hello-world")], [words])
        self.assertEqual(summary["recognizedWords"], 1)
        self.assertEqual(summary["matchedWords"], 1)
        self.assertEqual(len(cues), 1)
        self.assertEqual(cues[0]["end"], 11)

    def test_image_alt_text_is_never_timed_as_narrative(self):
        blocks = [block("alpha beta gamma", "image", "image"), block("alpha beta gamma", "paragraph")]
        cues, _ = align(blocks, [timed("alpha beta gamma")])
        self.assertEqual({cue["blockId"] for cue in cues}, {"paragraph"})

    def test_inserted_narration_does_not_get_fabricated_cues(self):
        book = "alpha beta gamma delta epsilon zeta eta theta"
        speech = "alpha beta gamma unexpected introduction delta epsilon zeta eta theta"
        cues, summary = align([block(book)], [timed(speech)])
        self.assertEqual(summary["matchedWords"], 8)
        self.assertNotIn(1200, [cue["startMs"] for cue in cues])
        self.assertNotIn(1600, [cue["startMs"] for cue in cues])

    def test_monotonic_under_reordered_passages(self):
        book = "aqua birch coral dune elm fir gold hazel iris jade kelp lime"
        speech = "gold hazel iris aqua birch coral jade kelp lime"
        positions = list(match_tokens(speech.split(), book.split()).values())
        self.assertEqual(positions, sorted(set(positions)))


class EpubTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_semantic_inline_formatting_spine_and_images(self):
        path = self.root / "book.epub"
        make_epub(path, '<h1>First chapter</h1><p>Hello <strong>bold <em>and italic</em></strong> <u>underlined</u> &amp; café.</p><blockquote><p>A quotation.</p></blockquote><ul><li>List <i>item</i>.</li></ul><p>Before<img src="../images/picture.png" alt="A picture"/>After</p>',
                  {"OPS/images/picture.png": b"\x89PNG\r\n\x1a\nfixture"})
        ebook = read_epub(path)
        self.assertEqual(ebook.title, "Unicode & Style")
        self.assertEqual(ebook.author, "A Writer")
        self.assertEqual(ebook.blocks[0]["kind"], "h1")
        paragraph = ebook.blocks[1]
        self.assertEqual("".join(run["text"] for run in paragraph["runs"]), "Hello bold and italic underlined & café.")
        self.assertTrue(any(run["bold"] and run["italic"] and run["text"] == "and italic" for run in paragraph["runs"]))
        self.assertTrue(any(run["underline"] for run in paragraph["runs"]))
        self.assertIn("blockquote", [b["kind"] for b in ebook.blocks])
        self.assertIn("li", [b["kind"] for b in ebook.blocks])
        self.assertEqual(ebook.blocks[-1]["chapter"], "Second chapter")
        image = next(b for b in ebook.blocks if b["kind"] == "image")
        self.assertIn(image["image"], ebook.images)
        self.assertTrue(all(".." not in name for name in ebook.images))
        self.assertEqual(len({b["id"] for b in ebook.blocks}), len(ebook.blocks))

    def test_hidden_executable_and_comment_text_not_included(self):
        path = self.root / "book.epub"
        make_epub(path, '<p>Visible<!-- secret --><script>evil()</script><span hidden>hidden</span><span style="display: none">invisible</span> words.</p>')
        text = " ".join("".join(run["text"] for run in b["runs"]) for b in read_epub(path).blocks)
        self.assertIn("Visible words.", text)
        for hidden in ("secret", "evil", "hidden", "invisible"):
            self.assertNotIn(hidden, text)

    def test_unsupported_image_reports_warning_and_retains_alt(self):
        path = self.root / "book.epub"
        make_epub(path, '<img src="../images/a.tiff" alt="Diagram"/>', {"OPS/images/a.tiff": b"unsupported"})
        ebook = read_epub(path)
        self.assertTrue(any("Unsupported image" in warning for warning in ebook.warnings))
        self.assertEqual(ebook.blocks[0]["runs"][0]["text"], "Diagram")

    def test_svg_is_rasterized_and_external_resources_are_rejected(self):
        path = self.root / "vector.epub"
        make_epub(path, '<img src="../images/a.svg" alt="Vector"/>', {
            "OPS/images/a.svg": '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="blue"/></svg>'})
        ebook = read_epub(path)
        image = next(b for b in ebook.blocks if b["kind"] == "image")
        self.assertTrue(image["image"].endswith(".png"))
        self.assertTrue(ebook.images[image["image"]].startswith(b"\x89PNG\r\n\x1a\n"))
        make_epub(path, '<img src="../images/a.svg"/>', {
            "OPS/images/a.svg": '<svg xmlns="http://www.w3.org/2000/svg"><rect fill="url(file:///private)" width="10" height="10"/></svg>'})
        with self.assertRaises(EpubError):
            read_epub(path)

    def test_traversal_and_windows_path_entries_rejected(self):
        for name in ("../escape", "/absolute", "a/../../escape", "C:/evil", "a\\evil", "a//b", "a/./b"):
            with self.subTest(name=name), self.assertRaises(EpubError):
                member_path(name)
        for reference in ("../../../evil", "%2e%2e/%2e%2e/%2e%2e/evil", "https://evil/a", "//evil/a", "C:/evil", "..%5cevil"):
            with self.subTest(reference=reference), self.assertRaises(EpubError):
                resolve_reference("OPS/text/chapter.xhtml", reference)
        self.assertEqual(resolve_reference("OPS/text/chapter.xhtml", "../images/a%20b.png#page"), "OPS/images/a b.png")

    def test_duplicate_and_symlink_members_rejected(self):
        for symlink in (False, True):
            path = self.root / f"bad-{symlink}.zip"
            with zipfile.ZipFile(path, "w") as archive:
                if symlink:
                    info = zipfile.ZipInfo("link")
                    info.create_system = 3
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(info, "../../outside")
                else:
                    archive.writestr("same", "first")
                    with self.assertWarns(UserWarning):
                        archive.writestr("same", "second")
            with self.assertRaises(EpubError):
                SafeArchive(path)

    def test_zip_bomb_and_xml_entities_rejected(self):
        path = self.root / "bomb.zip"
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("zeros", b"0" * (2 * 1024 * 1024))
        with self.assertRaises(EpubError):
            SafeArchive(path)
        path = self.root / "entities.epub"
        make_epub(path, '<p>Text</p>', {"META-INF/container.xml": '<!DOCTYPE x [<!ENTITY bomb "expanded">]><container>&bomb;</container>'})
        with self.assertRaises(EpubError):
            read_epub(path)


class PreparationTests(unittest.TestCase):
    def test_strict_timestamp_boundaries(self):
        for words in ([{"word": "x", "start": float("nan"), "end": 1}],
                      [{"word": "x", "start": 0, "end": 2}],
                      [{"word": "x", "start": True, "end": 1}],
                      [{"word": "x", "start": 0.5, "end": 0.6}, {"word": "y", "start": 0.4, "end": 0.8}]):
            with self.subTest(words=words), self.assertRaises(prepare.PreparationError):
                prepare.normalize_words(words, 1000, "fixture")

    def test_real_decoder_chunk_resampler_tail_and_offsets(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "track.wav"
            make_wav(path, seconds=2.125, rate=44100)
            chunks = [(offset, samples.copy()) for offset, samples in prepare.audio_chunks(path, seconds=1)]
            self.assertEqual([offset for offset, _ in chunks], [0.0, 1.0, 2.0])
            total = sum(len(samples) for _, samples in chunks)
            self.assertLessEqual(abs(total - round(2.125 * 16000)), 1)
            self.assertGreater(float(chunks[-1][1][-1]), 0.2)
            self.assertLessEqual(abs(prepare.audio_duration(path) - 2125), 1)

    def test_portable_archive_real_audio_and_atomic_no_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            epub = root / "book.epub"
            audio = root / "voice.wav"
            transcript = root / "timed.json"
            output = root / "portable.abook"
            request = root / "request.json"
            make_epub(epub, '<p>Alpha <b>beta</b> gamma.</p>')
            make_wav(audio, seconds=2)
            transcript.write_text(json.dumps([[{"word": word, "start": i * 0.4, "end": i * 0.4 + 0.2} for i, word in enumerate(("Alpha", "beta", "gamma"))]]), encoding="utf-8")
            request.write_text(json.dumps({"ebook": str(epub), "audio": [str(audio)], "output": str(output), "transcript": str(transcript)}), encoding="utf-8")
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                prepare.prepare(request)
            events = [json.loads(line) for line in captured.getvalue().splitlines()]
            self.assertEqual(events[-1]["type"], "done")
            self.assertEqual(events[-1]["matchedWords"], 3)
            with zipfile.ZipFile(output) as archive:
                book = json.loads(archive.read("book.json"))
                self.assertEqual(book["schemaVersion"], 1)
                self.assertEqual(book["tracks"][0]["durationMs"], 2000)
                self.assertEqual(archive.read("audio/000.wav"), audio.read_bytes())
                self.assertEqual(len(book["cues"]), 3)
                self.assertTrue(any(run["bold"] for run in book["blocks"][0]["runs"]))
            original = output.read_bytes()
            with self.assertRaises(prepare.PreparationError):
                prepare.prepare(request)
            self.assertEqual(output.read_bytes(), original)
            with self.assertRaises(FileExistsError):
                prepare.publish_archive(output, {"tracks": []}, [], {})
            self.assertEqual(output.read_bytes(), original)
            self.assertEqual(list(root.glob(".abook-*.tmp")), [])



if __name__ == "__main__":
    unittest.main()
