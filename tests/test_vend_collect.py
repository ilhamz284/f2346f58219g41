"""Exercise actual vend modules and Auto Collect WL UI with native-style currency ACKs."""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'hub.luau').read_text(encoding='utf-8-sig')
modules=s.split('--// ===== 7e. AUTO STOCK VEND =====',1)[1].split('--// ===== 8. UI',1)[0]
ui=s.split('-- ---- Vend Collect UI ----',1)[1].split('-- ---- Tab Info ----',1)[0]
program='local function make(env)\nlocal Hub,Bind,Farm,PNB,Factory,Surgery,task,os,worldPickerVisible=env.Hub,env.Bind,env.Farm,env.PNB,env.Factory,env.Surgery,env.task,env.os,env.worldPickerVisible\n'+modules+'\nreturn Hub.vendCollect\nend\n'
program+='local function makeUI(Hub,section)\nHub.ui={vendTab={Section=function()return section end}}\n'+ui+'\nend\n'
program+=(root/'tests/vend_collect_spec.luau').read_text()
with tempfile.TemporaryDirectory(prefix='humanhub-collect-') as directory:
    path=Path(directory)/'test.luau';path.write_text(program,encoding='utf-8')
    r=subprocess.run([sys.argv[1],str(path)],capture_output=True,text=True)
    print(r.stdout,end='')
    if r.returncode:print(r.stderr,file=sys.stderr);raise SystemExit(r.returncode)
