"""Run actual Surgery binding, decision, worker, request and UI code with a deterministic server."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "hub.luau").read_text(encoding="utf-8-sig")
module = source[source.index("local Surgery = {"):source.index("--// ===== 8. UI (WindUI) =====")]
ui = source[source.index("-- ---- Tab Surgery ----"):source.index("-- ---- Tab Auto Farming ----")]
fixture = (root / "tests" / "surgery_spec.luau").read_text(encoding="utf-8")
prelude, checks = fixture.split("-- INSERT SURGERY HERE", 1)
checks = checks.replace("-- INSERT SURGERY UI HERE", ui)
with tempfile.TemporaryDirectory(prefix="humanhub-surgery-") as directory:
    path = Path(directory) / "surgery.luau"
    path.write_text(prelude + module + checks, encoding="utf-8")
    result = subprocess.run([sys.argv[1], str(path)], capture_output=True, text=True)
    print(result.stdout, end="")
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        raise SystemExit(result.returncode)
