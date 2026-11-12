"""With the env ABSENT, mail, Safari and browser extract ALL history (18250 days).

Before: hidden fallbacks of 1825 (mail) and 365 (Safari, browser) capped a
customer who ran the extractor outside the installer, which passes 18250.
Runs extract_all.run_all with the three extractors stubbed to record the
since_days they were handed. Synthetic data only.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor"))
from ostler_fda import extract_all  # noqa: E402


def _record(monkeypatch, tmp_path):
    for k in ("OSTLER_MAIL_BACKFILL_DAYS", "OSTLER_SAFARI_BACKFILL_DAYS", "OSTLER_BROWSER_BACKFILL_DAYS"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / ".ostler"))
    seen = {}

    from ostler_fda import apple_mail, chrome_history, safari_history

    def mail(*a, **k):
        seen.setdefault("mail", k.get("since_days", a[1] if len(a) > 1 else None))
        return []

    def safari(*a, **k):
        seen.setdefault("safari", k.get("since_days", a[0] if a else None))
        return []

    def chrome(*a, **k):
        seen.setdefault("browser", k.get("since_days", a[0] if a else None))
        return []

    monkeypatch.setattr(apple_mail, "extract_messages", mail)
    monkeypatch.setattr(safari_history, "extract_history", safari)
    monkeypatch.setattr(chrome_history, "extract_history", chrome)
    return seen


def test_defaults_with_env_absent_are_all_history(monkeypatch, tmp_path):
    seen = _record(monkeypatch, tmp_path)
    try:
        extract_all.run_all(output_dir=tmp_path / "out",
                            enabled_sources=["apple_mail", "safari_history", "chrome_history"])
    except Exception:
        pass  # downstream writers may object to empty stubs; the capture is what we assert
    assert seen.get("mail") == 18250, seen
    assert seen.get("safari") == 18250, seen
    assert seen.get("browser") == 18250, seen


def test_an_explicit_env_value_still_wins(monkeypatch, tmp_path):
    """Control: the fallback must not override what the installer passes."""
    seen = _record(monkeypatch, tmp_path)
    monkeypatch.setenv("OSTLER_SAFARI_BACKFILL_DAYS", "90")
    monkeypatch.setenv("OSTLER_BROWSER_BACKFILL_DAYS", "120")
    try:
        extract_all.run_all(output_dir=tmp_path / "out",
                            enabled_sources=["safari_history", "chrome_history"])
    except Exception:
        pass
    assert seen.get("safari") == 90 and seen.get("browser") == 120, seen
