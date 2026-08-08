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


# --- v3 palette guard ---------------------------------------------------------
# server_config.json is what the Windows agent actually paints itself with: the
# client fetches /api/config and Get-LogbookTheme reads branding.colors straight
# out of it. The v3 pass restyled every surface but left this file shipping the
# pre-v3 MindLab palette, so a freshly installed workstation rendered a maroon
# sign-in card that no design document called for. Tokens are only the source of
# truth if the thing that serves them agrees.

SERVER_CONFIG_PATH = Path(__file__).resolve().parent.parent / "server" / "server_config.json"

# docs/design/LogiX_BUILD_BRIEF.md: "#741B47 maroon is retired as the accent,
# kept only as legacy comparison."
RETIRED_MAROON = "#741B47"

V3_CLIENT_COLORS = {
    "accent": "#2563EB",
    "text": "#EEF3FB",
    "muted": "#93A1B8",
    "surface": "#070C15",
    "surfaceWidget": "#0B1017",
    "surfaceElevated": "#0E1626",
}


def _served_colors() -> dict:
    return json.loads(SERVER_CONFIG_PATH.read_text(encoding="utf-8"))["branding"]["colors"]


def test_served_branding_matches_the_v3_client_palette():
    colors = _served_colors()
    for key, expected in V3_CLIENT_COLORS.items():
        assert colors.get(key) == expected, (
            f"branding.colors.{key} is {colors.get(key)!r}, expected {expected!r}. "
            "This file paints the WPF client; it has to track src/tokens.css."
        )


def test_retired_maroon_accent_is_not_served_to_clients():
    assert RETIRED_MAROON.lower() not in json.dumps(_served_colors()).lower(), (
        f"{RETIRED_MAROON} was retired as the accent in v3. If a lab genuinely "
        "wants it back, that is a per-deployment override, not the shipped default."
    )
