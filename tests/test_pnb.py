"""Exercise the actual PNB functions against a cooldown-enforcing game stub.

Usage: python tests/test_pnb.py <path-to-luau.exe> [baseline-git-revision]
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
local clock, active, stopAt = 0, true, math.huge
local os = {clock=function() return clock end}
local task = {wait=function(dt)
    clock+=dt or 0.016
    if clock>=stopAt then active=false end
end}
local function log() end
local state={x=10.5,y=5,grounded=true}
local W={name="TEST",w=100,h=60,fg={[4]={}},bg={[4]={}}}
local inv={selected=954,blocks=200,seeds=0}
function inv.count(_,id) return id==955 and inv.seeds or inv.blocks end
function inv.select(_,id) inv.selected=id end
function inv.remove(_,id,n) inv.blocks-=n end
local Bind={name="TEST",inv=inv}
function Bind.getW() return W end
function Bind.state() return state end
function Bind.solid(_,y) return y==5 end
local function tileId(x,y) return W.fg[y] and W.fg[y][x] or 0 end
local function pnbTileId(_,layer,x,y) return W[layer][y] and W[layer][y][x] or 0 end
local function standingFloor(s) return math.floor(s.y-0.0001)+1 end
local Factory={baseId=954,seedId=955,baseLayer="fg",baseAtSelf=true,
    workX=10,workStandX=10,workY=4,pnb=0,cycle=true}
function Factory.setPickupGate() end
local function factoryAlive() return active end
local function factoryCount(_,id) return inv:count(id) end
local function factoryWorkSpot() return 10,10,4 end
local Path={}
local paths,walks,collections,sweeps,rejected,hits=0,0,0,0,0,0
local quickCollections=0
local function collectDropsNearby() quickCollections+=1; return 0 end
local obstacle=false
function Path.standable(x,y) return y==4 and not (obstacle and x==11) end
function Path.moveTo(x,y,alive)
    paths+=1
    if not alive() then return false end
    state.x=x+0.5; state.y=y+1
    return true
end
local function edgeBlocked() return false end
local Move={}
function Move.release() end
function Move.walkTo(x,opts)
    walks+=1
    if opts.alive and not opts.alive() then return false end
    state.x=x; return true
end
function Move.idle(a,b) task.wait((a+b)/2) end
local Farm={breakBg=false}
local Dig={isProtected=function() return false end}
local placedAt,lastHit,hitsOnTile=0,-100,0
function Bind.setTile(layer,x,y,id)
    W[layer][y][x]=id; placedAt=clock; hitsOnTile=0
end
function Bind.hit(x,y)
    if clock-lastHit<0.21-1e-6 or clock-placedAt<0.14-1e-6 then
        rejected+=1; return
    end
    lastHit=clock; hits+=1; hitsOnTile+=1
    if hitsOnTile>=2 then W[Factory.baseLayer][y][x]=0 end
end
local sweepCollections=0
local function dropSweepTile() sweeps+=1; sweepCollections=collections; return false end
local function collectDropsAtTile() collections+=1; task.wait(0.06); return 0,nil end
'''

drain_test = r'''
for i=1,200 do
    assert(factoryPNBOne(W,inv,1,{},true), "drain must break each block")
    task.wait(OUTER_WAIT)
end
assert(inv.blocks==0 and Factory.pnb==200 and hits==400, "drain all 200 blocks")
assert(collections==0 and sweeps==0 and quickCollections==200,
    "self-tile PNB services fresh pickup without a wait, sweep or path search")
assert(rejected==0, "cooldown must not be bypassed")
print(string.format("DRAIN_SECONDS %.3f",clock))
'''

regressions = r'''
assert(paths==0, "stationary PNB must not call the pathfinder")
inv.blocks=5; Factory.baseAtSelf=false; Factory.workStandX=9; state.x=10.5
assert(factoryPNBOne(W,inv,1,{},false))
assert(paths==0 and walks>0 and collections==1, "nearby solid station uses quick corridor and collects")
Factory.workStandX=8; state.x=10.5; obstacle=true
-- Block an intermediate tile, so the shortcut must fall back.
Path.standable=function(x,y) return y==4 and x~=9 end
assert(factoryPNBOne(W,inv,1,{},true) and paths==1, "blocked corridor falls back")
local before=hits
Factory.baseAtSelf=true; Factory.workX=10; Factory.workY=4; Factory.workStandX=10
state.x=10.5; stopAt=clock+0.05
local worked=factoryPNBOne(W,inv,1,{},true)
assert(not worked and hits==before, "Stop during cooldown prevents another hit")
W.fg[4][10]=0; active=true; stopAt=math.huge
inv.blocks=0
local ok,why=factoryPNBOne(W,inv,1,{},true)
assert(not ok and why=="blocks", "empty inventory stops placement")
inv.blocks=2; W.fg[4][10]=6
ok,why=factoryPNBOne(W,inv,1,{},true)
assert(not ok and why=="occupied" and inv.blocks==2, "occupied station never consumes a block")
W.fg[4][10]=0; Factory.workX=10; Factory.workY=4; Factory.workStandX=10
Factory.baseLayer="bg"
assert(factoryPNBOne(W,inv,1,{},true) and W.bg[4][10]==0, "background block is broken on correct layer")
local beforeCollect=collections
assert(factoryPNBOne(W,inv,1,{},false) and sweeps==1 and sweepCollections==beforeCollect+1,
    "check lower-floor drops after collector waits for delayed spawns")
print("PASS stationary PNB, solid station, gap fallback, Stop, empty inventory, occupied station, background, cooldown, full drain")
'''

phase_helpers = r'''
local function selectedItemDefinition() return {grow=1} end
local function factoryRoom() return 200 end
local baseDrops={}
local function factoryBaseDrops() return baseDrops end
local function setFactoryStatus() end
local phasePlantCalls=0
local function factoryTarget(_,_,_,_,kind)
    assert(kind=="plant", "post-PNB planting must not search for harvest targets")
    return {kind="plant"}
end
local function factoryWork(_,_,target)
    assert(target.kind=="plant" and inv.seeds>0)
    phasePlantCalls+=1; inv.seeds-=1; Factory.planted=(Factory.planted or 0)+1
    return true
end
'''

phase_tests = r'''
Factory.phase="pnb"; inv.seeds=200; inv.blocks=10
local before=hits
factoryCycleStep(W,inv,state,955,{},1)
assert(Factory.phase=="plant" and Factory.resumePNB and inv.blocks==10 and hits==before,
    "full seeds pause PNB for planting without consuming blocks")
Factory.phase="pnb"; inv.seeds=0; inv.blocks=0
factoryCycleStep(W,inv,state,955,{},1)
assert(Factory.phase=="plant", "empty blocks advance to planting")
Factory.phase="pnb"; inv.seeds=23; inv.blocks=0
Factory.pnbDraining=true; Factory.pnbDrainCount=200; Factory.pnbDrainTarget=200; Factory.pnbOldDrops={}
factoryCycleStep(W,inv,state,955,{},1)
assert(Factory.phase=="plant" and inv.seeds==23 and not Factory.resumeCollect,
    "full-inventory drain plants existing seeds below 200 before harvesting")
for i=1,23 do
    factoryCycleStep(W,inv,state,955,{},1)
    assert(Factory.phase=="plant" and inv.seeds==23-i, "stay in plant until every seed is used")
end
assert(phasePlantCalls==23, "all seeds below 200 are planted")
factoryCycleStep(W,inv,state,955,{},1)
assert(Factory.phase=="grow", "only leave plant once seeds are empty")
inv.seeds=23
Factory.phase="pnb"; Factory.pnbDraining=true; Factory.pnbDrainCount=200; Factory.pnbDrainTarget=200
Factory.pnbOldDrops={[17]=true}
factoryCycleStep(W,inv,state,955,{},1)
assert(Factory.phase=="plant" and Factory.resumeCollect and Factory.dropFilter==nil,
    "old drops wait until seeds are planted; leftover fresh drops are also eligible afterwards")
Factory.phase="pnb"; Factory.pnbDraining=false; inv.seeds=9
baseDrops={{uid=17,id=954,n=2}}
factoryCycleStep(W,inv,state,955,{},1)
assert(Factory.phase=="plant" and Factory.resumeCollect,
    "normal PNB also plants available seeds before leftover block drops")
Factory.phase="pnb"; Factory.pnbDraining=true; Factory.pnbDrainCount=8; Factory.pnbDrainTarget=8
Factory.pnbOldDrops={}; inv.blocks=4; inv.seeds=5
factoryCycleStep(W,inv,state,955,{},1)
assert(Factory.phase=="pnb" and inv.blocks==3,
    "reaching the original batch counter cannot finish while blocks remain")
finishPNBDrain(inv)
assert(Factory.phase=="plant" and Factory.resumePNB,"an explicit interruption preserves remaining PNB")
baseDrops={}; inv.blocks=0; inv.seeds=0; Factory.resumePNB=false
Factory.phase="pnb"; Factory.pnbDraining=true; Factory.pnbDrainCount=200; Factory.pnbDrainTarget=200
Factory.pnbOldDrops={[17]=true}
factoryCycleStep(W,inv,state,955,{},1)
assert(Factory.phase=="plant" and Factory.resumeCollect, "drain always enters plant even without seeds")
factoryCycleStep(W,inv,state,955,{},1)
assert(Factory.phase=="collect", "empty seeds continue deferred old-drop collection")
print("PASS full seeds switch to plant, empty blocks switch to plant")
print("PASS post-drain seeds below 200, deferred old drops, normal PNB seeds, remaining blocks, empty seeds")
'''


def run(text, outer_wait, regression=False):
    parts = [prelude, "math.randomseed(1701)",
             extract(text, "local function rnd(", "local function log("),
             extract(text, "function Dig.punch(", "-- Gali tile sampai hancur"),
             extract(text, "local function centerOnTile(", "local function findPNBTarget("),
             extract(text, "local function factoryPNBOne(", "local function factoryHasTrees("),
             f"local OUTER_WAIT={outer_wait}", drain_test]
    if regression:
        parts.append(regressions)
        parts.extend([phase_helpers,
                      extract(text, "local PNB_DRAIN_BATCH =", "local function factoryCycleStep("),
                      extract(text, "local function factoryCycleStep(", "local function startFactory("),
                      phase_tests])
    with tempfile.TemporaryDirectory(prefix="humanhub-pnb-") as directory:
        script = Path(directory) / "pnb.luau"
        script.write_text("\n".join(parts), encoding="utf-8")
        result = subprocess.run([sys.argv[1], str(script)], capture_output=True, text=True, encoding="utf-8")
        print(result.stdout, end="")
        if result.returncode:
            print(result.stderr, file=sys.stderr)
            raise SystemExit(result.returncode)
        return float(result.stdout.split("DRAIN_SECONDS ")[1].splitlines()[0])


current = run(source, 0.06, regression=True)
if len(sys.argv) > 2:
    baseline = subprocess.run(["git", "show", f"{sys.argv[2]}:hub.luau"], cwd=root,
                              capture_output=True, text=True, encoding="utf-8", check=True).stdout
    old = run(baseline, 0.3)
    assert current < old
    print(f"SIMULATED 200-block drain: {old:.3f}s -> {current:.3f}s; real game not measured")
