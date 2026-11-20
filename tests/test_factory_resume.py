"""Exercise actual resume and preload code without game or network actions.

Usage: python tests/test_factory_resume.py <path-to-luau.exe>
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "hub.luau").read_text(encoding="utf-8-sig")
resume = source[source.rindex("function Hub.recovery.resume()") :]
guard = source.split("local preloadGuardSource = [=[\n", 1)[1].split("\n]=]", 1)[0]
suite = (root / "tests/factory_resume_spec.luau").read_text(encoding="utf-8")


def factory(body, names):
    bindings = ",".join(names) + " = " + ",".join("env." + name for name in names)
    return "function(env)\nlocal " + bindings + "\n" + body + "\nend"


make_resume = factory(resume, [
    "Hub", "Factory", "Farm", "PNB", "Bind", "os", "task",
    "worldPickerVisible", "startFactory", "startFarm", "setFactoryStatus", "log", "_G", "getgenv",
])
make_guard = factory(guard, [
    "game", "workspace", "getgenv", "_G", "hookfunction", "restorefunction",
    "hookmetamethod", "getnamecallmethod", "newcclosure", "task",
])
program = "\n".join([
    "local suite = (function()\n" + suite + "\nend)()",
    "local result = suite(" + make_resume + "," + make_guard + ")",
    'for _, name in ipairs(result.cases) do print("PASS " .. name) end',
    'print(tostring(result.passed) .. " cases passed")',
])
with tempfile.TemporaryDirectory(prefix="humanhub-resume-") as directory:
    path = Path(directory) / "resume.luau"
    path.write_text(program, encoding="utf-8")
    result = subprocess.run([sys.argv[1], str(path)], capture_output=True, text=True)
    print(result.stdout, end="")
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        raise SystemExit(result.returncode)
