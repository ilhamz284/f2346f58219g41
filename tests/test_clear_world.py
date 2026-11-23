"""Exercise Clear World with actual route discovery and a simulated tile world.

Usage: python tests/test_clear_world.py <path-to-luau.exe>
No Roblox session or world is modified.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

source = (Path(__file__).resolve().parents[1] / "hub.luau").read_text(encoding="utf-8-sig")


def extract(start, end):
    offset = source.index(start)
    return source[offset:source.index(end, offset)]


prelude = r'''
local clock, hits, worker, settings = 0, 0, nil, {}
local hitCounts = {}
local os = {clock=function() return clock end}
local Hub = {dead=false}
local state = {x=0.5,y=2.999,grounded=true,active=true}
local Farm = {running=false,gen=0,breakBg=false,digDelay=0.14}
local PNB, Factory = {running=false}, {running=false}
local W = {name="TEST",w=6,h=7,fg={},bg={}}
local Bind = {W=W, CT={}, hit=function() end}
function Bind.resolve() return true end
function Bind.getW() return Bind.W end
function Bind.state() return state end
function Bind.solid(x,y)
    if x<0 or x>=W.w or y<0 or y>=W.h then return true end
    local id=W.fg[y] and W.fg[y][x] or 0
    return id==2 or id==8
end
local function keyOf(x,y) return y*1000+x end
local function edgeBlocked() return false end
local Path = {canJump=false,clearEdges=function() end}
local Move = {release=function() end}
local function setStatus(text) Farm.status=text end
function Farm.stop(text) Farm.running=false; Farm.gen+=1; setStatus(text) end
local function worldPickerVisible() return false end
local function log() end
local function selectedItemDefinition(id) return {kind=id==955 and "seed" or "block"} end
local function gravity()
    local x=math.floor(state.x)
    local floor=math.floor(state.y-0.0001)+1
    while floor<W.h-1 and not Bind.solid(x,floor) do floor+=1 end
    state.y=floor-0.001
end
local task = {}
function task.wait(dt)
    clock+=dt or 0.02
    assert(clock<1000,"worker did not finish")
    gravity()
end
function task.spawn(fn) assert(not worker); worker=fn end
function Path.moveTo(x,y,canAct)
    if settings.stopMove then Farm.stop("manual stop"); return false,"alive" end
    assert(canAct() and Path.standable(x,y))
    state.x,state.y=x+0.5,y+1-0.001
    return true
end
local function reset(options)
    settings=options or {}; clock=0;hits=0;worker=nil;hitCounts={}
    Hub.dead=false;Bind.W=W;Farm.running=false;Farm.gen+=1;Farm.clearWorld=false
    W.fg={};W.bg={};W.lock={x=3,y=2}
    state={x=0.5,y=2.999,grounded=true,active=true}
    for y=0,W.h-1 do
        W.fg[y]={};W.bg[y]={}
        for x=0,W.w-1 do
            W.fg[y][x]= y==6 and 8 or (y>=3 and 2 or 0)
            W.bg[y][x]=y>=1 and y<6 and 2 or 0
        end
    end
    W.fg[2][2]=6
    W.fg[2][1]=955
end
'''
dig_mock = r'''
local treeHits=0
function Dig.punch(x,y,isTree,_,lava,background,canAct)
    assert(canAct() and lava and background)
    local fg=W.fg[y][x]
    assert(not Dig.isProtected(fg~=0 and fg or W.bg[y][x],x,y))
    if fg==955 then assert(isTree);treeHits+=1 end
    hits+=1
    local key=keyOf(x,y);hitCounts[key]=(hitCounts[key] or 0)+1
    if not settings.noDamage then
        if fg~=0 then W.fg[y][x]=0 else W.bg[y][x]=0 end
    end
    if settings.stopHit then Farm.stop("manual stop") end
    if settings.changeWorld then Bind.W={name="OTHER"} end
    return true
end
'''
checks = r'''
reset()
local target=Clear.target(W,state,{},function() return true end)
assert(target.y==1,"clear the highest reachable background first")
W.bg[0][0]=2
target=Clear.target(W,state,{},function() return true end)
assert(target.x==0 and target.y==0,"include top row and outermost column at normal punch reach")
W.bg[0][0]=0
assert(startClearWorld());worker()
assert(not Farm.running and Farm.status:find("selesai",1,true),Farm.status)
assert(treeHits>0 and Clear.cleared>0)
for y=0,W.h-1 do for x=0,W.w-1 do
    assert(Clear.layer(W,x,y)==nil,"a removable tile remains at "..x..","..y)
end end
assert(W.fg[2][2]==6 and W.bg[2][2]==2,"preserve the Main Door and its background")
assert(W.bg[2][3]==2,"preserve world-lock position")
for x=0,W.w-1 do assert(W.fg[6][x]==8,"preserve bedrock") end
assert(W.fg[3][0]==0 and W.fg[5][5]==0,"clear both horizontal map boundaries")
assert(not Farm.breakBg,"Clear background does not alter Dirt Farm settings")
print("PASS complete foreground/background clear, real route graph, gravity, trees, edges, protections")

reset({stopHit=true});assert(startClearWorld());worker()
assert(hits==1 and Farm.status=="manual stop","Stop prevents later punches")
reset({stopMove=true});assert(startClearWorld());worker()
assert(hits==0 and Farm.status=="manual stop","Stop during movement prevents digging")
reset({changeWorld=true});assert(startClearWorld());worker()
assert(hits==1 and Farm.status:find("world berubah",1,true))
print("PASS cancellation during movement/punch and world replacement")

reset({noDamage=true});assert(startClearWorld());worker()
assert(Farm.status:find("tidak bisa dihancurkan",1,true),Farm.status)
for _, count in pairs(hitCounts) do assert(count<=48,"retry limit per tile") end
assert(not Farm.status:find("selesai",1,true))
reset();W.bg[0][0]=2;state.y=5.999
for y=1,5 do for x=0,5 do W.fg[y][x]=0;W.bg[y][x]=0 end end
assert(startClearWorld());worker()
assert(W.bg[0][0]==2 and Farm.status:find("tidak terjangkau",1,true))
print("PASS bounded rejection retries and honest unreachable-world status")

reset();PNB.running=true;assert(not startClearWorld());assert(not worker);PNB.running=false
Factory.running=true;assert(not startClearWorld());assert(not worker);Factory.running=false
Farm.running=true;Farm.clearWorld=false;assert(not startClearWorld());assert(not worker)
print("PASS mutual exclusion with Dirt Farm, PNB and Factory")
'''
ui_prelude = r'''
do
local Farm={running=false,clearWorld=false,status="idle"}
local PNB,Factory={running=false,stop=function() end},{running=false,stop=function() end}
local surgeryStops=0
local Surgery={stop=function() surgeryStops+=1 end}
local clearStarts,dirtStarts,stops=0,0,0
local suppressed=0
local controls={}
local WindUI={Notify=function() end}
local farmTab={}
function farmTab:Section()
    local section={}
    function section:Paragraph(value) return {SetDesc=function() end} end
    function section:Toggle(value)
        local control={value=value.Value,Value=value.Value,Callback=value.Callback}
        function control:Set(on,fire)
            self.value=on;self.Value=on
            if fire~=false then self.Callback(on) else suppressed+=1 end
        end
        controls[value.Title]=control
        return control
    end
    function section:Slider() end
    function section:Button(value) controls[value.Title]=value end
    return section
end
function Farm.stop(text)
    stops+=1;Farm.running=false;Farm.status=text
    if Farm.onStatus then Farm.onStatus(text) end
end
local function startFarm()
    dirtStarts+=1;Farm.running=true;Farm.clearWorld=false
    if Farm.onStatus then Farm.onStatus("dirt") end
end
local function startClearWorld()
    if Farm.running then return Farm.clearWorld,"busy" end
    clearStarts+=1;Farm.running=true;Farm.clearWorld=true
    if Farm.onStatus then Farm.onStatus("clear") end
    return true
end
'''
ui_checks = r'''
local clear,dirt=controls["Auto Clear World"],controls["Auto Dirt Farm"]
clear:Set(true);assert(clear.value and not dirt.value and clearStarts==1)
dirt:Set(true);assert(clear.value and not dirt.value and stops==0)
clear:Set(false);assert(not clear.value and not dirt.value and stops==1)
dirt:Set(true);assert(dirt.value and not clear.value and dirtStarts==1)
clear:Set(true);assert(dirt.value and not clear.value and stops==1)
dirt:Set(false);assert(not clear.value and not dirt.value and stops==2)
clear:Set(true);controls["Stop & lepas semua tombol"].Callback()
assert(not Farm.running and not clear.value and not dirt.value and stops==3)
assert(surgeryStops==1,"shared Stop also pauses Auto Surgery")
assert(suppressed>0,"programmatic status updates suppress deferred WindUI callbacks")
print("PASS actual UI callbacks, mutual toggle synchronization and shared Stop button")
end
'''
program = "\n".join([
    prelude,
    extract("local Dig = { protectedIds =", "-- Pukul satu tile satu kali."),
    dig_mock,
    extract("function Path.standable(", "function Path.reconstruct("),
    extract("local Clear =", "-- Jemput drop hasil PNB."),
    checks,
    ui_prelude,
    extract("local clearSec =", "-- ---- Tab Gerak ----"),
    ui_checks,
])
with tempfile.TemporaryDirectory(prefix="humanhub-clear-") as directory:
    path = Path(directory) / "clear.luau"
    path.write_text(program, encoding="utf-8")
    result = subprocess.run([sys.argv[1], str(path)], capture_output=True, text=True)
    print(result.stdout, end="")
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        raise SystemExit(result.returncode)
