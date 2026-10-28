"""Sparse unique anchors plus bounded local alignment; never interpolate timestamps."""
from __future__ import annotations

from bisect import bisect_left, bisect_right
from collections import Counter
from dataclasses import dataclass
from difflib import SequenceMatcher
import heapq
import unicodedata


@dataclass(frozen=True)
class Token:
    text: str
    block: int
    start: int
    end: int


@dataclass(frozen=True)
class Spoken:
    text: str
    word: int
    track: int
    start_ms: int
    end_ms: int


APOSTROPHES = "'’‘ʼ＇"


def normalized(text: str) -> str:
    return unicodedata.normalize("NFKC", text).casefold().translate(str.maketrans({c: "'" for c in APOSTROPHES}))


def unspaced_character(character: str) -> bool:
    code = ord(character)
    return (0x3400 <= code <= 0x9FFF or 0xF900 <= code <= 0xFAFF
            or 0x20000 <= code <= 0x323AF or 0x3040 <= code <= 0x30FF
            or 0x31F0 <= code <= 0x31FF or 0xFF66 <= code <= 0xFF9F)


def tokenize(text: str):
    """Yield normalized words with original UTF-16 offsets (including combining marks)."""
    start = None
    start_unspaced = False
    offset = 0
    for index, character in enumerate(text):
        category = unicodedata.category(character)
        word_character = category[0] in ("L", "N") or (category[0] == "M" and start is not None)
        unspaced = unspaced_character(character)
        if start is not None and category[0] in ("L", "N") and (unspaced or start_unspaced):
            yield normalized(text[start[0]:index]), start[1], offset
            start = None
        internal_apostrophe = (character in APOSTROPHES and start is not None and index + 1 < len(text)
                               and unicodedata.category(text[index + 1])[0] in ("L", "N"))
        if word_character or internal_apostrophe:
            if start is None:
                start = (index, offset)
                start_unspaced = unspaced
        elif start is not None:
            yield normalized(text[start[0]:index]), start[1], offset
            start = None
        offset += 2 if ord(character) > 0xFFFF else 1
    if start is not None:
        yield normalized(text[start[0]:]), start[1], offset


def unique_grams(words: list[str], size: int) -> dict[tuple[str, ...], int]:
    seen: dict[tuple[str, ...], int] = {}
    for i in range(len(words) - size + 1):
        key = tuple(words[i:i + size])
        seen[key] = -1 if key in seen else i
    return {key: index for key, index in seen.items() if index >= 0}


def anchors(speech: list[str], book: list[str]) -> list[tuple[int, int, int]]:
    """Maximum-weight nonoverlapping monotone chain in O(N log N), not all-pairs."""
    candidates: dict[tuple[int, int], int] = {}
    for length in (5, 4, 3):
        left, right = unique_grams(speech, length), unique_grams(book, length)
        for gram, i in left.items():
            if gram in right:
                key = (i, right[gram])
                candidates[key] = max(candidates.get(key, 0), length)
    seeds = sorted((i, j, length) for (i, j), length in candidates.items())
    if not seeds:
        return []
    coordinates = sorted({j + length for _, j, length in seeds})
    tree = [(0, -1)] * (len(coordinates) + 1)
    scores = [0] * len(seeds)
    previous = [-1] * len(seeds)
    pending = []

    def query(position):
        result = (0, -1)
        while position:
            if tree[position][0] > result[0]:
                result = tree[position]
            position -= position & -position
        return result

    def insert(position, value):
        while position < len(tree):
            if value[0] > tree[position][0]:
                tree[position] = value
            position += position & -position

    for index, (i, j, length) in enumerate(seeds):
        while pending and pending[0][0] <= i:
            _, completed = heapq.heappop(pending)
            _, end_j, n = seeds[completed]
            insert(bisect_left(coordinates, end_j + n) + 1, (scores[completed], completed))
        score, predecessor = query(bisect_right(coordinates, j))
        scores[index] = score + length
        previous[index] = predecessor
        heapq.heappush(pending, (i + length, index))
    best = max(range(len(seeds)), key=scores.__getitem__)
    chain = []
    while best >= 0:
        chain.append(seeds[best])
        best = previous[best]
    return list(reversed(chain))


def match_tokens(speech: list[str], book: list[str]) -> dict[int, int]:
    if not speech or not book:
        return {}
    if speech == book:
        return dict(enumerate(range(len(book))))
    chain = anchors(speech, book)
    if not chain:
        return {}
    result = {}
    for i, j, length in chain:
        result.update((i + k, j + k) for k in range(length))
    # Only extend the outer boundaries. Interior omissions/repetitions must be
    # resolved by bounded gaps, not greedy assignment of repeated words.
    i, j, _ = chain[0]
    a, b = i - 1, j - 1
    while a >= 0 and b >= 0 and speech[a] == book[b]:
        result[a] = b
        a, b = a - 1, b - 1
    i, j, length = chain[-1]
    a, b = i + length, j + length
    while a < len(speech) and b < len(book) and speech[a] == book[b]:
        result[a] = b
        a, b = a + 1, b + 1
    ordered = sorted(result.items())
    for (left_i, left_j), (right_i, right_j) in zip(ordered, ordered[1:]):
        a, b = speech[left_i + 1:right_i], book[left_j + 1:right_j]
        if not a or not b or max(len(a), len(b)) > 256 or max(len(a), len(b)) > 3 * min(len(a), len(b)):
            continue
        if a == b:
            result.update((left_i + 1 + k, left_j + 1 + k) for k in range(len(a)))
            continue
        matcher = SequenceMatcher(None, a, b, autojunk=False)
        counts_a, counts_b = Counter(a), Counter(b)
        for tag, a0, a1, b0, b1 in matcher.get_opcodes():
            if tag == "equal":
                # Repeated tokens in an unequal gap cannot establish which
                # occurrence was omitted, even inside a two-word exact run.
                for k in range(a1 - a0):
                    word = a[a0 + k]
                    if counts_a[word] == counts_b[word] == 1:
                        result[left_i + 1 + a0 + k] = left_j + 1 + b0 + k
            elif tag == "replace" and len(a) == len(b) <= 3 and a1 - a0 == b1 - b0:
                # Fuzzy spelling is allowed only in tiny gaps tightly bounded by exact words.
                for x, y in zip(range(a0, a1), range(b0, b1)):
                    if (min(len(a[x]), len(b[y])) >= 5 and counts_a[a[x]] == counts_b[b[y]] == 1
                            and SequenceMatcher(None, a[x], b[y], autojunk=False).ratio() >= 0.86):
                        result[left_i + 1 + x] = left_j + 1 + y
    return dict(sorted(result.items()))


def align(blocks: list[dict], transcripts: list[list[dict]]) -> tuple[list[dict], dict]:
    book = [Token(word, index, start, end) for index, block in enumerate(blocks)
            if block["kind"] != "image"
            for word, start, end in tokenize("".join(run["text"] for run in block["runs"]))]
    speech = []
    original_words: dict[int, list[int]] = {}
    word_id = 0
    for track, words in enumerate(transcripts):
        for word in words:
            tokens = list(tokenize(word["word"]))
            if not tokens:
                continue
            original_words[word_id] = []
            for text, _, _ in tokens:
                original_words[word_id].append(len(speech))
                speech.append(Spoken(text, word_id, track, word["startMs"], word["endMs"]))
            word_id += 1
    mapping = match_tokens([word.text for word in speech], [word.text for word in book])
    cues = []
    matched = 0
    for indexes in original_words.values():
        # A recognizer word can contain several lexical tokens. Highlight it only if all
        # tokens map consecutively inside one ebook block, with a real positive duration.
        if not all(index in mapping for index in indexes):
            continue
        positions = [mapping[index] for index in indexes]
        targets = [book[position] for position in positions]
        spoken = speech[indexes[0]]
        if (positions != list(range(positions[0], positions[0] + len(positions)))
                or targets[0].block != targets[-1].block or spoken.end_ms <= spoken.start_ms):
            continue
        matched += 1
        cues.append({"track": spoken.track, "startMs": spoken.start_ms, "endMs": spoken.end_ms,
                     "blockId": blocks[targets[0].block]["id"], "start": targets[0].start, "end": targets[-1].end})
    cues.sort(key=lambda cue: (cue["track"], cue["startMs"], cue["endMs"]))
    recognized = len(original_words)
    warnings = []
    if recognized and matched < recognized:
        warnings.append(f"{recognized - matched} recognized words were unmatched or ambiguous; no timing was invented.")
    if not recognized:
        warnings.append("No spoken words were recognized; the book remains readable without highlights.")
    coverage = matched / recognized if recognized else 0.0
    if coverage < 0.5:
        warnings.append("Low alignment coverage: check ebook edition, audio ordering, and transcription language.")
    return cues, {"recognizedWords": recognized, "matchedWords": matched, "coverage": coverage, "warnings": warnings}
