"""Run actual target selection and planting on a deterministic multi-floor world.

Usage: python tests/test_plant.py <path-to-luau.exe> [baseline-git-revision]
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "hub.luau").read_text(encoding="utf-8-sig")


def extract(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


prelude = r'''
local clock, active, onWait = 0, true, nil
local os={clock=function() return clock end}
local task={wait=function(dt) clock+=dt or 0.016; if onWait then onWait() end end}
local W={w=60,h=20,name="TEST",fg={}}
local state={x=10.5,y=5,grounded=true,facing=1}
local inv={seeds=200}
function inv.count() return inv.seeds end
function inv.select() end
function inv.remove(_,_,n) inv.seeds-=n end
local Factory={seedId=955,plant=true,cycle=true,workX=10,workY=4,planted=0}
local Bind={W=W,name="TEST",inv=inv}
function Bind.state() return state end
local function tileId(x,y) return W.fg[y] and W.fg[y][x] or 0 end
function Bind.solid(x,y) return tileId(x,y)==2 end
local function standingFloor(s) return math.floor(s.y-0.0001)+1 end
local function factoryAlive() return active end
local function keyOf(x,y) return y*1000+x end
local rejected,placedAt,paths,plans,walks,lastPlace=0,{},0,0,0,-100
local hole=nil
local Path={}
function Path.standable(x,y)
    return x>=0 and x<W.w-1 and tileId(x,y)~=2 and Bind.solid(x,y+1)
end
function Path.explore(sx,sy)
    plans+=1; clock+=0.04
    local dist={}
    for y=0,W.h-2 do for x=0,W.w-2 do
        if Path.standable(x,y) then dist[keyOf(x,y)]=math.abs(sx-x)+math.abs(sy-y)*3 end
    end end
    return dist,{}
end
function Path.moveTo(x,y,alive)
    paths+=1
    if not alive() then return false,"alive" end
    clock+=0.2+math.abs(state.x-x-0.5)/7+math.abs(standingFloor(state)-y-1)*0.5
    state.x=x+0.5; state.y=y+1; return true
end
local Move={}
function Move.release() end
function Move.walkTo(x,opts)
    walks+=1
    if opts.alive and not opts.alive() then return false end
    if opts.floorY and standingFloor(state)~=opts.floorY then return false end
    clock+=math.abs(state.x-x)/7+(opts.quick and 0 or 0.22)
    state.x=x
    return true
end
function Bind.setTile(_,x,y,id)
    if not active or not state.grounded or standingFloor(state)~=y+1
        or math.abs(math.floor(state.x)-x)>2 or clock-lastPlace<0.14-1e-6 then
        rejected+=1; return
    end
    assert(not (x==Factory.workX and y==Factory.workY), "PNB tile is reserved")
    assert(Bind.solid(x,y+1) and tileId(x,y)==0, "plant requires empty supported tile")
    W.fg[y][x]=id; lastPlace=clock; table.insert(placedAt,{x=x,y=y,t=clock})
end
local function edgeBlocked() return false end
local function factoryTreeRipe() return false end
local function setFactoryStatus() end
local function reset(seeds)
    clock=0; active=true; onWait=nil; inv.seeds=seeds; lastPlace=-100
    Factory.planted=0; Factory.seedId=955; Factory.workX=10; Factory.workY=4
    state={x=10.5,y=5,grounded=true,facing=1}
    rejected=0; placedAt={}; paths=0; plans=0; walks=0
    W.fg={}
    for _,y in ipairs({4,7,10,13}) do
        W.fg[y]={}; W.fg[y+1]={}
        for x=0,W.w-1 do W.fg[y][x]=0; W.fg[y+1][x]=2 end
    end
end
'''

batch_tests = r'''
reset(200)
local target=factoryTarget(W,state,955,{},"plant")
assert(target and factoryWork(W,inv,target,955,1))
assert(Factory.planted>5 and Factory.planted<=24 and paths==0 and plans==0,
    "bounded row sweep avoids pathfinder on a clear row")
assert(rejected==0 and inv.seeds==200-Factory.planted, "range, pacing and seed accounting")
reset(200)
onWait=function() active=false end
target=factoryTarget(W,state,955,{},"plant")
factoryWork(W,inv,target,955,1)
assert(Factory.planted==1 and inv.seeds==199, "Stop interrupts the batch")
reset(200)
onWait=function() Factory.seedId=3 end
target=factoryTarget(W,state,955,{},"plant")
factoryWork(W,inv,target,955,1)
assert(Factory.planted==1, "changing seed interrupts the batch")
reset(200)
W.fg[5][6]=0
target={kind="plant",x=9,y=4,standX=9,standY=4}
factoryWork(W,inv,target,955,1)
assert(state.x>=7.5, "sweep never walks across a floor gap")
for _,p in ipairs(placedAt) do assert(p.x~=6, "unsupported tile is never planted") end
reset(200)
onWait=function() state.y=8 end
target=factoryTarget(W,state,955,{},"plant")
factoryWork(W,inv,target,955,1)
assert(Factory.planted==1 and rejected==0, "floor change interrupts the batch")
reset(1)
target=factoryTarget(W,state,955,{},"plant")
assert(factoryWork(W,inv,target,955,1) and inv.seeds==0 and Factory.planted==1, "last seed planted once")
print("PASS row sweep, batch limit, range, pacing, PNB reservation, Stop, seed change, gap, floor change, last seed")
'''

world_tests = r'''
reset(200)
for step=1,500 do
    if inv.seeds<=0 then break end
    local target=factoryTarget(W,state,955,{},"plant")
    assert(target,"world still has a reachable empty tile")
    local before=Factory.planted
    local ok=factoryWork(W,inv,target,955,1)
    assert(ok and Factory.planted>before,"plant must make progress")
    task.wait(0.06)
end
assert(inv.seeds==0 and Factory.planted==200,"all 200 seeds planted across floors")
assert(W.fg[4][10]==0,"reserved PNB station remains empty")
local floors={}
for _,p in ipairs(placedAt) do floors[p.y]=true end
assert(floors[4] and floors[7] and floors[10] and floors[13],"all floors searched")
print(string.format("WORLD_RESULT %.3f %d %d %d",clock,paths,plans,rejected))
'''


def run(text, regression):
    program = "\n".join([prelude,
        extract(text, "local function factoryTarget(", "local function factoryWork("),
        extract(text, "local function factoryWork(", "local function factoryCount("),
        batch_tests if regression else "", world_tests])
    with tempfile.TemporaryDirectory(prefix="humanhub-plant-") as directory:
        path = Path(directory) / "plant.luau"
        path.write_text(program, encoding="utf-8")
        result = subprocess.run([sys.argv[1], str(path)], capture_output=True, text=True, encoding="utf-8")
        print(result.stdout, end="")
        if result.returncode:
            print(result.stderr, file=sys.stderr)
            raise SystemExit(result.returncode)
        return result.stdout.split("WORLD_RESULT ")[1].splitlines()[0]


current = run(source, True)
if len(sys.argv) > 2:
    baseline = subprocess.run(["git", "show", f"{sys.argv[2]}:hub.luau"], cwd=root,
                              capture_output=True, text=True, encoding="utf-8", check=True).stdout
    old = run(baseline, False)
    assert float(current.split()[0]) < float(old.split()[0])
    print(f"SIMULATED seconds/path calls/plans/rejections: {old} -> {current}; real game not measured")
