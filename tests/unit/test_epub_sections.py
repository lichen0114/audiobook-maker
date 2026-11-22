"""Reading order and content-selection regressions without loading a voice model."""

import argparse
import json

import pytest
from ebooklib import epub

from audiobook_backend.epub_parser import parse_loaded_epub
from audiobook_backend.job import JobPreparationDeps, build_checkpoint_config, prepare_job
from audiobook_backend import job as job_module
from audiobook_backend.models import BookMetadata, ParsedEpub, ParsedSection
from checkpoint import CheckpointInspection

pytestmark = pytest.mark.unit


def document(uid, content, name=None, properties=None):
    item = epub.EpubHtml(uid=uid, file_name=name or f"{uid}.xhtml", title=uid)
    item.content = f"<html><body>{content}</body></html>".encode()
    item.properties = properties or []
    return item


def book_with(items, spine=None, toc=()):
    book = epub.EpubBook()
    book.set_title("Example")
    book.add_author("Reader")
    for item in items:
        book.add_item(item)
    book.spine = spine or []
    book.toc = toc
    return book


def test_spine_order_wins_over_manifest_order_and_deduplicates_entries():
    one = document("one", "<p>First.</p>")
    two = document("two", "<p>Second.</p>")
    book = book_with([two, one], [("one", "yes"), ("one", "yes"), ("two", "yes")])
    parsed = parse_loaded_epub(book)
    assert [section.text for section in parsed.chapters] == ["First.", "Second."]
    assert len({section.section_id for section in parsed.sections}) == 2
    book.items.reverse()
    assert [section.section_id for section in parse_loaded_epub(book).sections] == [
        section.section_id for section in parsed.sections
    ]


def test_navigation_and_nonlinear_documents_are_available_but_excluded():
    nav = document("nav", '<nav><ol><li>Contents</li></ol></nav>', properties=["nav"])
    appendix = document("appendix", "<p>Appendix text.</p>")
    story = document("story", "<p>The story.</p>")
    unspined = document("extra", "<p>Extra text.</p>")
    parsed = parse_loaded_epub(book_with(
        [nav, appendix, story, unspined],
        [("nav", "yes"), ("story", "yes"), ("appendix", "no")],
    ))
    assert [section.item_id for section in parsed.chapters] == ["story"]
    assert [section.item_id for section in parsed.sections] == ["nav", "story", "appendix", "extra"]
    assert parsed.sections[0].text == "Contents"
    assert parsed.sections[0].exclusion_reason == "navigation"
    assert parsed.sections[2].exclusion_reason == "nonlinear"


@pytest.mark.parametrize("spine", [[], [("missing", "yes")], [None, 123]])
def test_missing_or_malformed_spine_falls_back_to_document_order(spine):
    book = book_with([document("two", "<p>Second.</p>"), document("one", "<p>First.</p>")], spine)
    assert [section.item_id for section in parse_loaded_epub(book).chapters] == ["two", "one"]


def test_toc_fragments_partition_nested_content_without_duplicate_narration():
    content = (
        '<p>Preface.</p><section id="first"><h1>First</h1><p>Alpha <b>bold</b>.</p>'
        '<section><h2 id="second">Second</h2><p>Beta.</p></section><p>Tail.</p></section>'
    )
    toc = [
        epub.Link("story.xhtml#first", "Part one", "a"),
        epub.Link("story.xhtml#first", "Duplicate TOC target", "again"),
        epub.Link("story.xhtml#second", "Part two", "b"),
    ]
    parsed = parse_loaded_epub(book_with([document("story", content)], [("story", "yes")], toc))
    assert len(parsed.sections) == 3
    assert [section.title for section in parsed.sections[1:]] == ["Part one", "Part two"]
    text = " ".join(section.text for section in parsed.sections)
    for word in ["Preface.", "Alpha", "bold", "Beta.", "Tail."]:
        assert text.count(word) == 1
    assert "Beta." not in parsed.sections[1].text
    assert "Tail." in parsed.sections[2].text


def test_missing_fragment_retains_document_and_does_not_create_empty_chapter():
    toc = [epub.Link("story.xhtml#missing", "Missing", "a")]
    parsed = parse_loaded_epub(book_with([document("story", "<p>All text.</p>")], toc=toc))
    assert len(parsed.chapters) == 1
    assert parsed.chapters[0].text == "All text."


def test_section_inspection_contains_bounded_excerpt_and_word_count():
    section = ParsedSection("Chapter", "word\n\n" * 100, section_id="stable")
    summary = section.to_dict()
    assert summary["id"] == "stable"
    assert summary["word_count"] == 100
    assert summary["included"] is True
    assert len(summary["excerpt"]) == 240
    assert "\n" not in summary["excerpt"]


def job_args(tmp_path, **overrides):
    values = dict(
        input="book.epub", output=str(tmp_path / "book.m4b"), checkpoint=True,
        resume=False, backend="mock", device="cpu", chunk_chars=100, pipeline_mode=None,
        format="mp3", voice="af_heart", speed=1.0, lang_code="a", split_pattern=r"\n+",
        bitrate="192k", normalize=False, sections_file=None,
    )
    values.update(overrides)
    return argparse.Namespace(**values)


def selection_deps(parsed, seen_configs):
    def inspect(_checkpoint, _input, config, **_kwargs):
        seen_configs.append(config)
        return CheckpointInspection(False, False)
    return JobPreparationDeps(
        resolve_backend=lambda value: value,
        resolve_device_for_args=lambda *_: ("cpu", []),
        resolve_pipeline_mode_for_args=lambda *_: ("sequential", []),
        is_low_memory_apple_host=lambda: False,
        parse_epub=lambda *_args, **_kwargs: parsed,
        inspect_checkpoint=inspect,
    )


def test_selection_applies_in_reading_order_and_can_include_auxiliary_content(tmp_path):
    one = ParsedSection("One", "First.", section_id="one")
    extra = ParsedSection("Extra", "Extra.", section_id="extra", included=False)
    two = ParsedSection("Two", "Second.", section_id="two")
    parsed = ParsedEpub(BookMetadata("Book", "Author"), [one, two], [one, extra, two])
    selected = tmp_path / "sections.json"
    selected.write_text(json.dumps(["two", "extra"]))
    configs = []
    prepared = prepare_job(
        job_args(tmp_path, sections_file=str(selected)), inspect_checkpoint_state=True,
        deps=selection_deps(parsed, configs),
    )
    assert [section.section_id for section in prepared.chapters] == ["extra", "two"]
    assert configs[0]["selected_section_ids"] == ["extra", "two"]
    assert configs[0]["parser_version"] == "spine-sections-v1"
    assert configs[0]["model_identity"] == "mock:mock:v1:builtin"


@pytest.mark.parametrize("selection", [[], ["unknown"], ["one", "one"], [1], {"one": True}])
def test_invalid_selection_is_rejected_instead_of_silently_reading_whole_book(tmp_path, selection):
    one = ParsedSection("One", "First.", section_id="one")
    parsed = ParsedEpub(BookMetadata("Book", "Author"), [one], [one])
    selected = tmp_path / "sections.json"
    selected.write_text(json.dumps(selection))
    with pytest.raises(ValueError, match="[Ss]ection selection"):
        prepare_job(
            job_args(tmp_path, sections_file=str(selected)), inspect_checkpoint_state=False,
            deps=selection_deps(parsed, []),
        )


def test_checkpoint_fingerprint_changes_with_selection_and_backend(tmp_path):
    args = job_args(tmp_path)
    original = build_checkpoint_config(args, "mock", 100, "cpu", ["one"])
    assert original != build_checkpoint_config(args, "mock", 100, "cpu", ["two"])
    assert original["model_identity"] != build_checkpoint_config(args, "pytorch", 100, "cpu", ["one"])["model_identity"]


def test_inspection_can_review_a_book_with_only_excluded_content(tmp_path):
    extra = ParsedSection("Extra", "Extra.", section_id="extra", included=False)
    parsed = ParsedEpub(BookMetadata("Book", "Author"), [], [extra])
    prepared = prepare_job(
        job_args(tmp_path, inspect_job=True), inspect_checkpoint_state=True,
        deps=selection_deps(parsed, []),
    )
    assert prepared.chunks == []
    assert prepared.parsed_epub.sections[0].section_id == "extra"
    with pytest.raises(ValueError, match="No text chunks"):
        prepare_job(job_args(tmp_path), inspect_checkpoint_state=False, deps=selection_deps(parsed, []))


def test_checkpoint_identity_changes_when_cached_model_snapshot_changes(tmp_path, monkeypatch):
    monkeypatch.setattr(job_module, "_cached_model_revision", lambda _repo: "commit-one")
    first = build_checkpoint_config(job_args(tmp_path), "mlx", 100, "mlx", ["one"])
    monkeypatch.setattr(job_module, "_cached_model_revision", lambda _repo: "commit-two")
    second = build_checkpoint_config(job_args(tmp_path), "mlx", 100, "mlx", ["one"])
    assert first["model_identity"].endswith(":commit-one")
    assert second["model_identity"].endswith(":commit-two")
    assert first != second


def test_cached_revision_uses_snapshot_path_without_network(monkeypatch):
    import huggingface_hub

    calls = []
    def cached(repo, filename):
        calls.append((repo, filename))
        return "/cache/models--repo/snapshots/abcdef/config.json"
    monkeypatch.setattr(huggingface_hub, "try_to_load_from_cache", cached)
    assert job_module._cached_model_revision("repo") == "abcdef"
    assert calls == [("repo", "config.json")]
    monkeypatch.setattr(huggingface_hub, "try_to_load_from_cache", lambda *_: None)
    assert job_module._cached_model_revision("repo") == "unknown"
