import sys
from pathlib import Path

import pytest

_ROOT = Path(__file__).resolve().parent.parent
# Make the co-located core modules (paths, logbook_report, gsheet_sync) importable
# the same way they are when installed side-by-side in the data dir.
sys.path.insert(0, str(_ROOT / "logix"))
# Installer-side tools (setup_sync) live here.
sys.path.insert(0, str(_ROOT / "install"))
# Preview server component (main.py) is not a package; import it flat too.
sys.path.insert(0, str(_ROOT / "server"))


# Modules that resolve environment-dependent state AT IMPORT TIME, and are
# therefore unsafe to leave in sys.modules across tests.
#
# log_physical.py computes `DEFAULT_DB = paths.default_db()` at module level
# and hands it to argparse as the default for --db. A test that sets
# LOGIX_DB to a tmp_path and then reloads the module (the established idiom
# here for picking up new env) freezes that tmp_path into DEFAULT_DB. When
# monkeypatch restores the environment afterwards, the module object keeps
# the stale value -- so the NEXT test to rely on the argparse default writes
# its rows into a temp directory that no longer exists.
#
# That landmine predates this fixture; nothing stepped on it because the only
# file using the reload idiom sorted alphabetically after the tests it could
# have broken. Adding a test file earlier in the alphabet was enough to
# surface it, as a failure in a completely unrelated gsheet test.
#
# Dropping these from sys.modules after each test means the next importer
# re-executes them against the environment IT set up. Re-import is a few
# milliseconds for modules this size, and it removes a whole class of
# order-dependent failure rather than the one instance that was found.
_ENV_SENSITIVE_MODULES = ("log_physical", "logbook_report", "gsheet_sync")


@pytest.fixture(autouse=True)
def _no_env_sensitive_module_leakage():
    yield
    for name in _ENV_SENSITIVE_MODULES:
        sys.modules.pop(name, None)
