from dataclasses import dataclass, field
import re
from typing import Any, Dict, List, Optional


@dataclass
class TextChunk:
    chapter_title: str
    text: str


@dataclass
class BookMetadata:
    title: str
    author: str
    cover_image: Optional[bytes] = None
    cover_mime_type: Optional[str] = None


@dataclass
class ParsedSection:
    title: str
    text: str
    href: str = ""
    item_id: str = ""
    section_id: str = ""
    included: bool = True
    exclusion_reason: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.section_id,
            "title": self.title,
            "word_count": len(self.text.split()),
            "excerpt": re.sub(r"\s+", " ", self.text).strip()[:240],
            "included": self.included,
            "href": self.href,
            "exclusion_reason": self.exclusion_reason,
        }


@dataclass
class ParsedEpub:
    metadata: BookMetadata
    chapters: List[ParsedSection]
    sections: List[ParsedSection] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)


@dataclass
class ChapterInfo:
    title: str
    start_sample: int
    end_sample: int


@dataclass
class JobInspectionResult:
    input_path: str
    output_path: str
    resolved_backend: str
    resolved_device: str
    resolved_chunk_chars: int
    resolved_pipeline_mode: str
    output_format: str
    total_chars: int
    total_chunks: int
    chapter_count: int
    epub_metadata: Dict[str, Any]
    checkpoint: Dict[str, Any]
    warnings: List[str]
    errors: List[str]
    sections: List[Dict[str, Any]] = field(default_factory=list)
    cover_path: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "input_path": self.input_path,
            "output_path": self.output_path,
            "resolved_backend": self.resolved_backend,
            "resolved_device": self.resolved_device,
            "resolved_chunk_chars": self.resolved_chunk_chars,
            "resolved_pipeline_mode": self.resolved_pipeline_mode,
            "output_format": self.output_format,
            "total_chars": self.total_chars,
            "total_chunks": self.total_chunks,
            "chapter_count": self.chapter_count,
            "epub_metadata": self.epub_metadata,
            "checkpoint": self.checkpoint,
            "warnings": self.warnings,
            "errors": self.errors,
            "sections": self.sections,
            "cover_path": self.cover_path,
        }

