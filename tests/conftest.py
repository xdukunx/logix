import sys
from pathlib import Path

# Make the co-located core modules (paths, logbook_report, gsheet_sync) importable
# the same way they are when installed side-by-side in the data dir.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "logix"))
