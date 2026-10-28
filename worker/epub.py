"""Read EPUB spine content without extracting untrusted ZIP members."""
from __future__ import annotations

from dataclasses import dataclass
import base64
import hashlib
import posixpath
import re
import stat
from pathlib import Path
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET
import zipfile

from bs4 import BeautifulSoup, NavigableString, Tag


class EpubError(ValueError):
    pass


@dataclass
class Ebook:
    title: str
    author: str
    blocks: list[dict]
    images: dict[str, bytes]
    warnings: list[str]


def member_path(name: str) -> str:
    """ZIP entry names are not filesystem paths, even on Windows."""
    if not name or "\\" in name or "\x00" in name or ":" in name or name.startswith("/"):
        raise EpubError(f"Unsafe EPUB member: {name!r}")
    parts = name.rstrip("/").split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise EpubError(f"Unsafe EPUB member: {name!r}")
    return "/".join(parts)


def resolve_reference(base: str, reference: str) -> str:
    parsed = urlsplit(reference)
    if parsed.scheme or parsed.netloc:
        raise EpubError(f"External EPUB resource is not allowed: {reference!r}")
    decoded = unquote(parsed.path)
    if "\\" in decoded or "\x00" in decoded or ":" in decoded or decoded.startswith("/"):
        raise EpubError(f"Unsafe EPUB reference: {reference!r}")
    parts = base.split("/")[:-1]
    for part in decoded.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                raise EpubError(f"EPUB reference escapes archive: {reference!r}")
            parts.pop()
        else:
            parts.append(part)
    return member_path("/".join(parts))


class SafeArchive:
    def __init__(self, path: Path):
        self.archive = zipfile.ZipFile(path)
        try:
            entries = self.archive.infolist()
            if len(entries) > 20000:
                raise EpubError("EPUB has too many ZIP entries")
            self.entries = {}
            expanded = 0
            for info in entries:
                name = member_path(info.filename)
                mode = info.external_attr >> 16
                if stat.S_ISLNK(mode) or info.flag_bits & 1:
                    raise EpubError("Encrypted or symbolic-link EPUB members are not supported")
                if info.is_dir():
                    continue
                if name in self.entries:
                    raise EpubError(f"Duplicate EPUB member: {name}")
                expanded += info.file_size
                if info.file_size > 128 * 1024 * 1024 or expanded > 512 * 1024 * 1024:
                    raise EpubError("EPUB uncompressed size exceeds safety limit")
                if info.file_size > 1024 * 1024 and info.file_size > max(info.compress_size, 1) * 1000:
                    raise EpubError("EPUB ZIP compression ratio exceeds safety limit")
                self.entries[name] = info
        except Exception:
            self.archive.close()
            raise

    def read(self, name: str) -> bytes:
        if name not in self.entries:
            raise EpubError(f"Missing EPUB resource: {name}")
        return self.archive.read(self.entries[name])

    def close(self):
        self.archive.close()


def xml(data: bytes) -> ET.Element:
    if re.search(br"<!\s*(DOCTYPE|ENTITY)", data, re.I):
        raise EpubError("XML entities and document type declarations are not allowed in EPUB metadata")
    return ET.fromstring(data)


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def rasterize_svg(data: bytes, document: str, archive: SafeArchive) -> bytes:
    """Rasterize vectors without filesystem/network resource resolution."""
    import resvg_py
    root = xml(data)
    for element in root.iter():
        if local_name(element.tag) in ("script", "foreignObject"):
            raise EpubError(f"Executable SVG content is not supported: {document}")
        for attribute, value in list(element.attrib.items()):
            if local_name(attribute).lower().startswith("on") or local_name(attribute) == "base":
                del element.attrib[attribute]
            elif local_name(attribute) == "href" and value and not value.startswith("#"):
                if value.startswith("data:"):
                    if not re.match(r"data:image/(?:png|jpeg|gif|webp);base64,", value, re.I):
                        raise EpubError(f"Unsupported SVG data reference: {document}")
                else:
                    resource = resolve_reference(document, value)
                    extension = posixpath.splitext(resource)[1].lower()
                    mime = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                            ".gif": "image/gif", ".webp": "image/webp"}.get(extension)
                    if mime is None:
                        raise EpubError(f"SVG references a non-raster resource: {resource}")
                    element.attrib[attribute] = "data:" + mime + ";base64," + base64.b64encode(archive.read(resource)).decode("ascii")
        css = " ".join(element.attrib.values()) + ((element.text or "") if local_name(element.tag) == "style" else "")
        css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
        if "\\" in css:
            raise EpubError(f"Escaped SVG resource declarations are not supported: {document}")
        if re.search(r"@import", css, re.I):
            raise EpubError(f"External SVG stylesheets are not supported: {document}")
        for reference in re.findall(r"url\s*\(([^)]*)\)", css, re.I):
            if not reference.strip(" \t\r\n'\"").startswith("#"):
                raise EpubError(f"External SVG CSS resource is not supported: {document}")
    # Fixed bounds prevent malicious SVG dimensions from allocating giant bitmaps.
    return resvg_py.svg_to_bytes(svg_string=ET.tostring(root, encoding="unicode"),
                                 width=1600, height=1600, log_information=False)


def read_epub(path: Path) -> Ebook:
    archive = SafeArchive(path)
    try:
        container = xml(archive.read("META-INF/container.xml"))
        rootfiles = [node for node in container.iter() if local_name(node.tag) == "rootfile"]
        if not rootfiles:
            raise EpubError("EPUB container has no package document")
        package_path = member_path(rootfiles[0].attrib.get("full-path", ""))
        package = xml(archive.read(package_path))
        metadata = next((node for node in package if local_name(node.tag) == "metadata"), None)
        def metadata_text(name: str) -> str:
            return "; ".join("".join(node.itertext()).strip() for node in (metadata if metadata is not None else [])
                             if local_name(node.tag) == name and "".join(node.itertext()).strip())
        title = metadata_text("title") or path.stem
        author = metadata_text("creator")
        manifest = {node.attrib["id"]: node for node in package.iter()
                    if local_name(node.tag) == "item" and "id" in node.attrib}
        spine = [node for node in package.iter() if local_name(node.tag) == "itemref"
                 and node.attrib.get("linear", "yes") != "no"]
        if not spine:
            raise EpubError("EPUB has no readable spine")
        if any(node.attrib.get("media-type") == "application/vnd.adobe.adept+xml" for node in manifest.values()):
            raise EpubError("DRM-protected EPUB is not supported")
        blocks: list[dict] = []
        images: dict[str, bytes] = {}
        warnings: list[str] = []
        image_paths: dict[str, str | None] = {}
        chapter = title

        def image(source: str, document: str, alt: str):
            resource = resolve_reference(document, source)
            if resource not in image_paths:
                data = archive.read(resource)
                extension = posixpath.splitext(resource)[1].lower()
                if extension == ".svg":
                    data = rasterize_svg(data, resource, archive)
                    extension = ".png"
                # Store native-decoder-compatible raster assets on both platforms.
                if extension not in (".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"):
                    warnings.append(f"Unsupported image format omitted: {resource}")
                    image_paths[resource] = None
                else:
                    target = "images/" + hashlib.sha256(data).hexdigest() + extension
                    images[target] = data
                    image_paths[resource] = target
            target = image_paths[resource]
            if target:
                blocks.append({"id": f"b{len(blocks):06d}", "chapter": chapter, "kind": "image",
                               "runs": [{"text": alt, "bold": False, "italic": False, "underline": False}] if alt else [],
                               "image": target})
            elif alt:
                blocks.append({"id": f"b{len(blocks):06d}", "chapter": chapter, "kind": "p",
                               "runs": [{"text": alt, "bold": False, "italic": True, "underline": False}]})

        for itemref in spine:
            item = manifest.get(itemref.attrib.get("idref", ""))
            if item is None:
                raise EpubError("EPUB spine refers to an unknown manifest item")
            document = resolve_reference(package_path, item.attrib.get("href", ""))
            if item.attrib.get("media-type") not in ("application/xhtml+xml", "text/html"):
                warnings.append(f"Non-HTML spine item omitted: {document}")
                continue
            soup = BeautifulSoup(archive.read(document), "html.parser")
            body = soup.find("body") or soup
            first_heading = body.find(["h1", "h2", "h3", "h4", "h5", "h6"])
            chapter = first_heading.get_text(" ", strip=True) if first_heading else posixpath.basename(document)
            pending: list[dict] = []
            current_kind = "p"
            block_tags = {"p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "li", "div", "section", "article", "ul", "ol", "table", "tr", "td", "figure", "figcaption", "pre", "hr"}

            def append_text(text: str, style: tuple[bool, bool, bool]):
                text = re.sub(r"\s+", " ", text)
                if pending and pending[-1]["text"].endswith((" ", "\n")):
                    text = text.lstrip()
                if not text:
                    return
                run = {"text": text, "bold": style[0], "italic": style[1], "underline": style[2]}
                if pending and all(pending[-1][key] == run[key] for key in ("bold", "italic", "underline")):
                    pending[-1]["text"] += text
                else:
                    pending.append(run)

            def flush():
                nonlocal pending
                while pending and not pending[0]["text"].lstrip():
                    pending.pop(0)
                while pending and not pending[-1]["text"].rstrip():
                    pending.pop()
                if pending:
                    pending[0]["text"] = pending[0]["text"].lstrip()
                    pending[-1]["text"] = pending[-1]["text"].rstrip()
                    blocks.append({"id": f"b{len(blocks):06d}", "chapter": chapter,
                                   "kind": current_kind, "runs": pending})
                pending = []

            def walk(node, style=(False, False, False), inherited_kind="p"):
                nonlocal current_kind
                if isinstance(node, NavigableString):
                    # Comments and processing instructions are not visible book text.
                    if type(node) is NavigableString:
                        append_text(str(node), style)
                    return
                if not isinstance(node, Tag):
                    return
                name = node.name.lower().split(":")[-1]
                if name in ("script", "style", "head", "noscript") or node.has_attr("hidden") or node.get("aria-hidden") == "true":
                    return
                css = node.get("style", "").lower()
                if re.search(r"(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden)", css):
                    return
                styled = (style[0] or name in ("b", "strong") or bool(re.search(r"font-weight\s*:\s*(?:bold|[6-9]00)", css)),
                          style[1] or name in ("i", "em", "cite") or "font-style:italic" in css.replace(" ", ""),
                          style[2] or name == "u" or bool(re.search(r"text-decoration(?:-line)?\s*:[^;]*underline", css)))
                if name in ("img", "image"):
                    flush()
                    source = node.get("src") or node.get("href") or node.get("xlink:href")
                    if source:
                        image(source, document, node.get("alt", ""))
                    return
                if name == "br":
                    if pending:
                        pending[-1]["text"] = pending[-1]["text"].rstrip() + "\n"
                    return
                boundary = name in block_tags
                kind = name if name in ("p", "h1", "h2", "h3", "blockquote", "li") else ("h3" if name in ("h4", "h5", "h6") else inherited_kind)
                # A paragraph nested in a list/quote retains the enclosing semantic type.
                if name == "p" and inherited_kind in ("li", "blockquote"):
                    kind = inherited_kind
                if boundary:
                    flush()
                    current_kind = kind
                for child in node.children:
                    walk(child, styled, kind if boundary else inherited_kind)
                if boundary:
                    flush()
                    current_kind = inherited_kind

            walk(body)
            flush()
        if not blocks:
            raise EpubError("EPUB contains no supported readable content")
        return Ebook(title, author, blocks, images, warnings)
    finally:
        archive.close()
