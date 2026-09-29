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
# pre-v3 palette, so a freshly installed workstation rendered a maroon
# sign-in card that no design document called for. Tokens are only the source of
# truth if the thing that serves them agrees.
#
# Checked against DEFAULT_CONFIG in server/main.py, not the runtime
# server_config.json on disk. That file is deliberately gitignored -- an
# admin can repaint it from the dashboard, and a real deployment's copy is
# meant to diverge from the repo -- so it does not exist on a fresh
# checkout at all. It is only ever created by startup_event() writing
# DEFAULT_CONFIG the first time the server runs, which makes DEFAULT_CONFIG
# the actual thing "a freshly installed workstation" gets, and the real
# regression-guard target this test's own docstring describes. Reading the
# gitignored file directly meant this test could only ever pass on a
# machine that happened to have started the server locally before -- it
# failed on every CI runner, every time, since the day it was written.

# docs/design/LogiX_BUILD_BRIEF.md: "#741B47 maroon is retired as the accent,
# kept only as legacy comparison."
RETIRED_MAROON = "#741B47"

V4_CLIENT_COLORS = {
    "accent": "#C5F23A",
    "text": "#EEF0F3",
    "muted": "#8D939C",
    "surface": "#0B0C0E",
    "surfaceWidget": "#111214",
    "surfaceElevated": "#1A1C20",
}


def _served_colors(monkeypatch) -> dict:
    main = _load_main(monkeypatch)
    return main.DEFAULT_CONFIG["branding"]["colors"]


def test_served_branding_matches_the_v4_client_palette(monkeypatch):
    colors = _served_colors(monkeypatch)
    for key, expected in V4_CLIENT_COLORS.items():
        assert colors.get(key) == expected, (
            f"branding.colors.{key} is {colors.get(key)!r}, expected {expected!r}. "
            "DEFAULT_CONFIG paints the WPF client on first run; it has to track src/tokens.css."
        )


def test_retired_maroon_accent_is_not_served_to_clients(monkeypatch):
    assert RETIRED_MAROON.lower() not in json.dumps(_served_colors(monkeypatch)).lower(), (
        f"{RETIRED_MAROON} was retired as the accent in v3. If a lab genuinely "
        "wants it back, that is a per-deployment override, not the shipped default."
    )


# --- Upgrading a lab that is already running --------------------------------
# startup_event() wrote a full DEFAULT_CONFIG snapshot on first run, so an
# existing server_config.json holds the v3 colours explicitly.

def _start_with_saved_config(monkeypatch, tmp_path, saved):
    main = _load_main(monkeypatch)
    main.DB_PATH = tmp_path / "test.db"
    main.CONFIG_PATH = tmp_path / "server_config.json"
    main.REPORTS_DIR = tmp_path / "reports"
    main.CONFIG_PATH.write_text(saved if isinstance(saved, str) else json.dumps(saved), encoding="utf-8")
    main.startup_event()
    return main, main.CONFIG_PATH.read_text(encoding="utf-8")


def _v3_snapshot(main):
    cfg = json.loads(json.dumps(main.DEFAULT_CONFIG))
    cfg["branding"]["colors"] = dict(main.V3_DEFAULT_COLORS)
    cfg["branding"]["signals"] = dict(main.V3_DEFAULT_SIGNALS)
    return cfg


def test_an_untouched_v3_palette_is_upgraded_at_startup(monkeypatch, tmp_path):
    main = _load_main(monkeypatch)
    saved = _v3_snapshot(main)
    saved["branding"]["colors"]["accent"] = "#2563eb"  # case must not matter
    saved["branding"]["title"] = "Lab Kimia"            # everything else is kept
    main, text = _start_with_saved_config(monkeypatch, tmp_path, saved)
    cfg = json.loads(text)
    assert cfg["branding"]["colors"] == main.DEFAULT_CONFIG["branding"]["colors"]
    assert cfg["branding"]["signals"] == main.DEFAULT_CONFIG["branding"]["signals"]
    assert cfg["branding"]["title"] == "Lab Kimia"


def test_a_lab_that_picked_its_own_colours_is_left_alone(monkeypatch, tmp_path):
    main = _load_main(monkeypatch)
    saved = _v3_snapshot(main)
    saved["branding"]["colors"]["accent"] = "#1A7F4B"
    main, text = _start_with_saved_config(monkeypatch, tmp_path, saved)
    cfg = json.loads(text)
    assert cfg["branding"]["colors"]["accent"] == "#1A7F4B"
    assert cfg["branding"]["colors"]["surface"] == "#070C15", "a customised palette is not partially migrated"


def test_an_unreadable_config_does_not_stop_the_server(monkeypatch, tmp_path):
    _, text = _start_with_saved_config(monkeypatch, tmp_path, "{ not json")
    assert text == "{ not json"
