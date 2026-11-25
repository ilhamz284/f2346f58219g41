"""Run the actual price reader, vend modules and Auto Buy UI with a quote-protected server."""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'hub.luau').read_text(encoding='utf-8-sig')
number=s.split('\tlocal function vendNumber',1)[1].split('\n\tlocal function scanVendRows',1)[0]
reader=s.split('\tfunction Hub.readVendPrices',1)[1].split('\n\tfunction Hub.compareVendPrices',1)[0]
modules=s.split('--// ===== 7e. AUTO STOCK VEND =====',1)[1].split('--// ===== 7h. AUTO COLLECT VEND WL =====',1)[0]
ui=s.split('-- ---- Vend Buy UI ----',1)[1].split('-- ---- Vend Collect UI ----',1)[0]
program='local function make(env)\nlocal Hub,Bind,Farm,PNB,Factory,Surgery,task,os,worldPickerVisible,http,readfile=env.Hub,env.Bind,env.Farm,env.PNB,env.Factory,env.Surgery,env.task,env.os,env.worldPickerVisible,env.http,env.readfile\nlocal sspSeedNames={["cliffside seed"]="Cliffside Seed",["door seed"]="Door Seed"}\nlocal function vendNumber'+number+'\nfunction Hub.readVendPrices'+reader+'\n'+modules+'\nreturn Hub.vendBuy\nend\n'
program+='local function makeUI(Hub,section)\nHub.ui={vendTab={Section=function()return section end}}\n'+ui+'\nend\n'
program+=(root/'tests/vend_buy_spec.luau').read_text()
with tempfile.TemporaryDirectory(prefix='humanhub-buy-') as directory:
    path=Path(directory)/'test.luau';path.write_text(program,encoding='utf-8')
    r=subprocess.run([sys.argv[1],str(path)],capture_output=True,text=True)
    print(r.stdout,end='')
    if r.returncode:print(r.stderr,file=sys.stderr);raise SystemExit(r.returncode)
