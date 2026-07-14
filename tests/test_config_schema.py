"""Drift guard for docs/config.schema.json vs. server/main.py's
DEFAULT_CONFIG (roadmap item I). The schema had drifted silently once
already this session -- devices/reports/privacy sections were added to
DEFAULT_CONFIG for the dashboard redesign without ever touching the
schema, leaving it describing speculative fields (product/organization/
device/privacyMode) that were never implemented, while omitting the real
ones. This test makes that kind of drift loud instead of silent.
"""
import importlib
import json
import sys
from pathlib import Path

SCHEMA_PATH = Path(__file__).resolve().parent.parent / "docs" / "config.schema.json"


def _load_main(monkeypatch):
    monkeypatch.setenv("LOGIX_DEV_MODE", "1")
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", "")
    monkeypatch.setenv("LOGIX_ALLOWED_ORIGINS", "")
    monkeypatch.setenv("ADMIN_EMAILS", "admin@example.org")
    if "main" in sys.modules:
        return importlib.reload(sys.modules["main"])
    return importlib.import_module("main")


def test_schema_is_valid_json():
    json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def test_default_config_top_level_keys_are_all_in_schema(monkeypatch):
    module = _load_main(monkeypatch)
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    schema_keys = set(schema["properties"].keys())
    default_config_keys = set(module.DEFAULT_CONFIG.keys())

    missing = default_config_keys - schema_keys
    assert not missing, (
        f"DEFAULT_CONFIG has top-level key(s) {sorted(missing)} not declared in "
        f"docs/config.schema.json -- update the schema (see server/main.py's "
        f"DEFAULT_CONFIG for the real shape)."
    )


def test_schema_devices_section_matches_default_config_shape(monkeypatch):
    module = _load_main(monkeypatch)
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    schema_device_keys = set(schema["properties"]["devices"]["properties"].keys())
    actual_device_keys = set(module.DEFAULT_CONFIG["devices"].keys())
    assert actual_device_keys <= schema_device_keys


def test_schema_reports_section_matches_default_config_shape(monkeypatch):
    module = _load_main(monkeypatch)
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    schema_reports_keys = set(schema["properties"]["reports"]["properties"].keys())
    actual_reports_keys = set(module.DEFAULT_CONFIG["reports"].keys())
    assert actual_reports_keys <= schema_reports_keys


def test_schema_privacy_section_matches_default_config_shape(monkeypatch):
    module = _load_main(monkeypatch)
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    schema_privacy_keys = set(schema["properties"]["privacy"]["properties"].keys())
    actual_privacy_keys = set(module.DEFAULT_CONFIG["privacy"].keys())
    assert actual_privacy_keys <= schema_privacy_keys


def test_schema_no_longer_lists_speculative_unimplemented_fields():
    """product/organization/device/privacyMode described nothing real and
    risked someone thinking privacyMode in server_config.json controls
    sync behavior -- it doesn't; only the agent-local LOGIX_PRIVACY_MODE
    env var does (a deliberately separate mechanism, see item F)."""
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    for stale_key in ("product", "organization", "device", "privacyMode"):
        assert stale_key not in schema["properties"], (
            f"{stale_key!r} was removed as speculative/unimplemented -- "
            "if it's back, confirm it's actually built before re-adding it."
        )
