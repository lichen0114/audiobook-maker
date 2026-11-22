import hashlib
import posixpath
import re
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import unquote, urldefrag

from bs4 import BeautifulSoup, Comment, NavigableString, Tag

from .chunking import _clean_text, _clean_text_with_paragraphs
from .models import BookMetadata, ParsedEpub, ParsedSection

try:
    import ebooklib
    from ebooklib import epub
except ImportError:  # pragma: no cover - exercised via fallback tests
    class _EbooklibFallback:
        ITEM_COVER = "ITEM_COVER"
        ITEM_IMAGE = "ITEM_IMAGE"
        ITEM_DOCUMENT = "ITEM_DOCUMENT"

    ebooklib = _EbooklibFallback()
    epub = None


SECTION_BLOCK_TAGS = (
    "p",
    "li",
    "blockquote",
    "pre",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "dt",
    "dd",
)
NAV_DOCUMENT_HINT_RE = re.compile(
    r"(^|[\\/._-])(nav|toc|contents?|landmarks?)([\\/._-]|$)",
    re.IGNORECASE,
)
PARSER_VERSION = "spine-sections-v1"


def _require_epub_support() -> None:
    if epub is None:
        raise ImportError(
            "ebooklib is required for EPUB parsing. Install with: pip install ebooklib"
        )


def _load_epub_book(epub_path: str) -> Any:
    _require_epub_support()
    return epub.read_epub(epub_path)


def _extract_book_metadata(book: Any) -> BookMetadata:
    title_meta = book.get_metadata("DC", "title")
    title = title_meta[0][0] if title_meta else "Unknown Title"

    author_meta = book.get_metadata("DC", "creator")
    author = author_meta[0][0] if author_meta else "Unknown Author"

    cover_image = None
    cover_mime_type = None

    for item in book.get_items_of_type(ebooklib.ITEM_COVER):
        cover_image = item.get_content()
        cover_mime_type = item.media_type
        break

    if cover_image is None:
        cover_meta = book.get_metadata("OPF", "cover")
        if cover_meta:
            cover_id = cover_meta[0][1].get("content") if cover_meta[0][1] else None
            if cover_id:
                for item in book.get_items():
                    if item.get_id() == cover_id:
                        cover_image = item.get_content()
                        cover_mime_type = item.media_type
                        break

    if cover_image is None:
        for item in book.get_items_of_type(ebooklib.ITEM_IMAGE):
            item_name = item.get_name().lower()
            if "cover" in item_name:
                cover_image = item.get_content()
                cover_mime_type = item.media_type
                break

    return BookMetadata(
        title=title,
        author=author,
        cover_image=cover_image,
        cover_mime_type=cover_mime_type,
    )


def extract_epub_metadata(epub_path: str) -> BookMetadata:
    book = _load_epub_book(epub_path)
    return _extract_book_metadata(book)


def _normalize_href_reference(value: Optional[str]) -> str:
    if not value:
        return ""

    normalized = posixpath.normpath(unquote(str(value).split("#", 1)[0].strip()))
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def _iter_toc_entries(entries: Any) -> Any:
    if not entries:
        return

    if isinstance(entries, tuple):
        for entry in entries:
            yield from _iter_toc_entries(entry)
        return

    if isinstance(entries, list):
        for entry in entries:
            yield from _iter_toc_entries(entry)
        return

    yield entries

    subitems = getattr(entries, "subitems", None)
    if subitems:
        yield from _iter_toc_entries(subitems)


def _build_toc_label_map(book: Any) -> Dict[str, str]:
    toc_labels: Dict[str, str] = {}
    toc = getattr(book, "toc", None)
    if not isinstance(toc, (list, tuple)):
        return toc_labels

    for entry in _iter_toc_entries(toc):
        href = _normalize_href_reference(getattr(entry, "href", None))
        title = getattr(entry, "title", None) or getattr(entry, "text", None)
        if href and isinstance(title, str):
            cleaned_title = _clean_text(title)
            if cleaned_title:
                toc_labels.setdefault(href, cleaned_title)

    return toc_labels


def _get_item_reference_candidates(item: Any) -> List[str]:
    raw_candidates: List[str] = []

    for attr_name in ("file_name", "href"):
        value = getattr(item, attr_name, None)
        if isinstance(value, str):
            raw_candidates.append(value)

    for method_name in ("get_name", "get_id"):
        method = getattr(item, method_name, None)
        if callable(method):
            try:
                value = method()
            except TypeError:
                continue
            if isinstance(value, str):
                raw_candidates.append(value)

    normalized_candidates: List[str] = []
    for candidate in raw_candidates:
        normalized = _normalize_href_reference(candidate)
        if normalized and normalized not in normalized_candidates:
            normalized_candidates.append(normalized)

    return normalized_candidates


def _get_item_properties(item: Any) -> List[str]:
    properties = getattr(item, "properties", None)
    if properties is None:
        get_properties = getattr(item, "get_properties", None)
        if callable(get_properties):
            try:
                properties = get_properties()
            except TypeError:
                properties = None

    if not properties:
        return []

    if not isinstance(properties, (list, tuple, set)):
        return []

    return [str(property_value).lower() for property_value in properties]


def _is_navigation_document(item: Any) -> bool:
    properties = _get_item_properties(item)
    if "nav" in properties:
        return True

    return any(
        NAV_DOCUMENT_HINT_RE.search(candidate) is not None
        for candidate in _get_item_reference_candidates(item)
    )


def _prune_non_content_nodes(body: Any, *, keep_navigation: bool = False) -> None:
    for node in list(body.find_all(["script", "style"])):
        node.decompose()

    for node in list(body.find_all(True)):
        if node.name is None:  # A parent may already have been decomposed.
            continue
        if keep_navigation:
            continue
        if node.name == "nav":
            node.decompose()
            continue

        attr_values = [
            node.get("role"),
            node.get("epub:type"),
            node.get("id"),
            " ".join(node.get("class", [])),
        ]
        if any(
            isinstance(value, str)
            and re.search(r"\b(toc|landmarks?)\b", value, re.IGNORECASE)
            for value in attr_values
        ):
            node.decompose()


def _extract_body_text(soup: BeautifulSoup) -> str:
    body = soup.body or soup
    _prune_non_content_nodes(body)

    paragraphs: List[str] = []
    for node in body.find_all(SECTION_BLOCK_TAGS):
        if node.find(SECTION_BLOCK_TAGS):
            continue

        text = _clean_text(node.get_text(" ", strip=True))
        if text:
            paragraphs.append(text)

    if not paragraphs:
        fallback_text = _clean_text(body.get_text(" ", strip=True))
        if fallback_text:
            paragraphs.append(fallback_text)

    return _clean_text_with_paragraphs("\n\n".join(paragraphs))


def _item_id(item: Any) -> str:
    get_id = getattr(item, "get_id", None)
    value = get_id() if callable(get_id) else ""
    return value if isinstance(value, str) else ""


def _ordered_documents(book: Any) -> tuple[list[tuple[Any, bool]], list[str]]:
    """Use the spine for reading order; retain auxiliary documents for review."""
    documents = list(book.get_items_of_type(ebooklib.ITEM_DOCUMENT))
    spine = getattr(book, "spine", None)
    if not isinstance(spine, (list, tuple)) or not spine:
        return [(item, True) for item in documents], []
    by_id = {_item_id(item): item for item in documents if _item_id(item)}
    ordered: list[tuple[Any, bool]] = []
    seen: set[str] = set()
    invalid = False
    for entry in spine:
        if isinstance(entry, str):
            item_id, linear = entry, True
        elif isinstance(entry, (tuple, list)) and entry:
            item_id = entry[0]
            linear = len(entry) < 2 or str(entry[1]).lower() != "no"
        else:
            invalid = True
            continue
        if not isinstance(item_id, str) or item_id not in by_id:
            invalid = True
            continue
        if item_id in seen:
            continue
        seen.add(item_id)
        ordered.append((by_id[item_id], linear))
    if not ordered:
        return [(item, True) for item in documents], [
            "EPUB reading order is malformed; using document order."
        ]
    ordered.extend((item, False) for item in documents if _item_id(item) not in seen)
    return ordered, (["Some EPUB reading-order entries could not be resolved."] if invalid else [])


def _fragment_labels(book: Any, item: Any) -> Dict[str, str]:
    candidates = _get_item_reference_candidates(item)
    labels: Dict[str, str] = {}
    toc = getattr(book, "toc", None)
    if not isinstance(toc, (list, tuple)):
        return labels
    for entry in _iter_toc_entries(toc):
        href = getattr(entry, "href", None)
        title = getattr(entry, "title", None) or getattr(entry, "text", None)
        if not isinstance(href, str) or not isinstance(title, str):
            continue
        document, fragment = urldefrag(href)
        if _normalize_href_reference(document) in candidates and fragment:
            label = _clean_text(title)
            if label:
                labels.setdefault(unquote(fragment), label)
    return labels


def _section_texts(
    soup: BeautifulSoup, fragment_labels: Dict[str, str], *, navigation: bool
) -> list[tuple[str, str, Optional[str]]]:
    """Partition a document once in DOM order, including nested fragment anchors."""
    body = soup.body or soup
    _prune_non_content_nodes(body, keep_navigation=navigation)
    available = {
        str(node.get("id") or node.get("name"))
        for node in body.find_all(True)
        if node.get("id") or node.get("name")
    }
    if body.get("id") or body.get("name"):
        available.add(str(body.get("id") or body.get("name")))
    boundaries = {key: value for key, value in fragment_labels.items() if key in available}
    if not boundaries and not navigation:
        text = _extract_body_text(soup)
        return [("", text, None)] if text else []

    parts: list[tuple[str, list[str], Optional[str]]] = [("", [], None)]
    used: set[str] = set()

    def visit(node: Any) -> None:
        if isinstance(node, Comment):
            return
        if isinstance(node, NavigableString):
            parts[-1][1].append(str(node))
            return
        if not isinstance(node, Tag):
            return
        anchor = str(node.get("id") or node.get("name") or "")
        if anchor in boundaries and anchor not in used:
            used.add(anchor)
            parts.append((anchor, [], boundaries[anchor]))
        if node.name in SECTION_BLOCK_TAGS or node.name == "br":
            parts[-1][1].append("\n\n")
        for child in node.children:
            visit(child)
        if node.name in SECTION_BLOCK_TAGS:
            parts[-1][1].append("\n\n")

    visit(body)
    result = []
    for fragment, text_parts, title in parts:
        text = _clean_text_with_paragraphs("".join(text_parts))
        if text:
            result.append((fragment, text, title))
    return result


def _stable_section_id(item: Any, href: str, fragment: str, index: int) -> str:
    identity = href or _item_id(item) or f"document-{index}"
    identity = posixpath.normpath(unquote(identity)) + "#" + fragment
    return "section-" + hashlib.sha256(identity.encode("utf-8")).hexdigest()[:20]


def _resolve_section_title(
    item: Any,
    soup: BeautifulSoup,
    toc_labels: Dict[str, str],
    chapter_number: int,
) -> str:
    for candidate in _get_item_reference_candidates(item):
        toc_title = toc_labels.get(candidate)
        if toc_title:
            return toc_title

    body = soup.body or soup
    for heading_tag in ("h1", "h2"):
        heading = body.find(heading_tag)
        if heading is None:
            continue

        heading_text = _clean_text(heading.get_text(" ", strip=True))
        if heading_text:
            return heading_text

    if soup.title is not None:
        title_text = _clean_text(soup.title.get_text(" ", strip=True))
        if title_text:
            return title_text

    return f"Chapter {chapter_number}"


def parse_loaded_epub(
    book: Any,
    progress_callback: Optional[Callable[[int, int, int], None]] = None,
) -> ParsedEpub:
    metadata = _extract_book_metadata(book)
    sections: List[ParsedSection] = []
    document_items, warnings = _ordered_documents(book)
    total_items = len(document_items)
    toc_labels = _build_toc_label_map(book)

    for idx, (item, linear) in enumerate(document_items, start=1):
        navigation = _is_navigation_document(item)
        soup = BeautifulSoup(item.get_content(), "html.parser")
        title = _resolve_section_title(item, soup, toc_labels, len(sections) + 1)
        href = next(iter(_get_item_reference_candidates(item)), "")
        for fragment, text, fragment_title in _section_texts(
            soup, _fragment_labels(book, item), navigation=navigation
        ):
            sections.append(
                ParsedSection(
                    title=fragment_title or title,
                    text=text,
                    href=href + ("#" + fragment if fragment else ""),
                    item_id=_item_id(item),
                    section_id=_stable_section_id(item, href, fragment, idx),
                    included=linear and not navigation,
                    exclusion_reason="navigation" if navigation else (None if linear else "nonlinear"),
                )
            )
        if progress_callback is not None:
            progress_callback(idx, total_items, sum(section.included for section in sections))

    if not sections:
        raise ValueError("No readable text content found in EPUB.")

    return ParsedEpub(
        metadata=metadata,
        chapters=[section for section in sections if section.included],
        sections=sections,
        warnings=warnings,
    )


def parse_epub(
    epub_path: str,
    progress_callback: Optional[Callable[[int, int, int], None]] = None,
) -> ParsedEpub:
    book = _load_epub_book(epub_path)
    return parse_loaded_epub(book, progress_callback=progress_callback)


def extract_epub_text(epub_path: str) -> List[Tuple[str, str]]:
    return [(chapter.title, chapter.text) for chapter in parse_epub(epub_path).chapters]

