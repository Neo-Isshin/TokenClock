"""TokenClock product worker; Python core and aggregate references, no private responses."""
import sys
import os
from pathlib import Path
if sys.version_info < (3,10):
    raise SystemExit("TokenClock L1 requires Python 3.10 or later")
worker_root=Path(__file__).resolve().parent
if (worker_root/"runtime/runtime-manifest.json").is_file():
    os.environ["TOKENCLOCK_MODEL_INTEGRITY_RUNTIME"]=str(worker_root/"runtime")
sys.path.insert(0,str(worker_root/"runtime.zip"))
from scripts.model_integrity.l1.cli import main
raise SystemExit(main())
