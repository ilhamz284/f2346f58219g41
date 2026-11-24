"""Run the actual Auto Open SSP module against a deterministic inventory server."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'hub.luau').read_text(encoding='utf-8-sig')
module = source.split('--// ===== 7d. AUTO OPEN SSP =====', 1)[1].split('--// ===== 8. UI', 1)[0]
suite = (root / 'tests/open_ssp_spec.luau').read_text(encoding='utf-8')
ui = source.split('-- ---- Tab SSP ----', 1)[1].split('-- ---- Tab Auto Farming ----', 1)[0]
program = 'local function make(env)\nlocal Hub,Bind,Farm,PNB,Factory,Surgery,Move,task,os,worldPickerVisible,dropInReach = env.Hub,env.Bind,env.Farm,env.PNB,env.Factory,env.Surgery,env.Move,env.task,env.os,env.worldPickerVisible,env.dropInReach\n'+module+'\nreturn Hub.ssp\nend\n'
program += 'local function makeUI(Hub,sspTab)\nlocal Window={Tab=function(_,config)assert(config.Title=="SSP");return sspTab end}\nlocal task={spawn=function()end}\nlocal function uiContainer() return nil end\n'+ui+'\nend\n'+suite
with tempfile.TemporaryDirectory(prefix='humanhub-open-ssp-') as directory:
    path = Path(directory) / 'test.luau'
    path.write_text(program, encoding='utf-8')
    result = subprocess.run([sys.argv[1], str(path)], capture_output=True, text=True)
    print(result.stdout, end='')
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        raise SystemExit(result.returncode)
