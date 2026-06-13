import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
# Make the co-located core modules (paths, logbook_report, gsheet_sync) importable
# the same way they are when installed side-by-side in the data dir.
sys.path.insert(0, str(_ROOT / "logix"))
# Installer-side tools (setup_sync) live here.
sys.path.insert(0, str(_ROOT / "install"))
