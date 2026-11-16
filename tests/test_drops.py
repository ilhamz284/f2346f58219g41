"""Exercise real drop collectors with stale visuals and changing inventory.

Usage: python tests/test_drops.py <path-to-luau.exe>
"""
from pathlib import Path
import subprocess
import sys
import tempfile

source = (Path(__file__).resolve().parents[1] / "hub.luau").read_text(encoding="utf-8-sig")


def extract(start, end):
    return source[source.index(start):source.index(end, source.index(start))]


prelude = r'''
local clock=0
local os={clock=function() return clock end}
local task={wait=function(dt) clock+=dt or 0.016 end}
local Factory={baseId=954,seedId=955,ignoredDrops={},dropTakeFailures={}}
local W={name="TEST",fg={}}
local state={x=10.5,y=5,grounded=true}
local Bind={name="TEST",state=function() return state end}
local inv={blocks=0,seeds=0}
function inv.count(_,id) return id==955 and inv.seeds or inv.blocks end
function inv.room(_,id) return 200-inv:count(id) end
function inv.add(_,id,n) if id==955 then inv.seeds+=n else inv.blocks+=n end end
local function standingFloor(s) return math.floor(s.y-0.0001)+1 end
local function keyOf(x,y) return y*1000+x end
local function factoryAlive() return true end
local function setFactoryStatus() end
local drops,requests,listCalls={}, {},0
local rejected={}
local throwError=false
local jitter=false
function W.dropList()
    listCalls+=1
    if jitter then
        for _,d in ipairs(drops) do
            if d.uid==1 then
                d.x=10.5+(listCalls%3-1)*0.02
                d.y=4.5+(listCalls%2)*0.01
            end
        end
    end
    return drops
end
function W.takeDrop(uid,n)
    requests[uid]=(requests[uid] or 0)+1
    if throwError then error("network failure") end
    if rejected[uid] or n>inv:room(954) then return 0 end
    return n
end
local forceMoveFail=false
local Move={walkTo=function(x) if forceMoveFail then return false end; state.x=x; return true end}
local Path={}
local plans,moves=0,0
function Path.standable() return true end
function Path.explore()
    plans+=1
    local dist={}
    for x=0,99 do dist[keyOf(x,4)]=math.abs(state.x-x-0.5) end
    return dist
end
function Path.moveTo(x,y) moves+=1; state.x=x+0.5; state.y=y+1; return true end
'''

checks = r'''
local ghost={uid=1,id=954,n=5,x=10.5,y=4.5}
local good={uid=2,id=954,n=3,x=10.5,y=4.5}
drops={ghost,good}; rejected[1]=true; jitter=true
local blocked={}
assert(factoryCollectDrop(W,inv,state,blocked,1)=="ignored")
assert(requests[1]==3 and not requests[2] and inv.blocks==0,
    "target failure cannot be masked by another nearby drop")
assert(plans==1 and moves==1 and clock<=0.35,
    "visual drop is tested in one short visit, without repeated pathfinding")
clock+=0.1
assert(factoryCollectDrop(W,inv,state,blocked,1)=="collected" and inv.blocks==3)
assert(requests[1]==3,
    "three in-range failures with enough room ignore the UID")
local nextDrop={uid=3,id=954,n=7,x=11.5,y=4.5}
drops={ghost,good,nextDrop}
inv.blocks=200
beginPNB(W,200,true)
assert(not Factory.pnbOldDrops[1] and not Factory.pnbOldDrops[2] and Factory.pnbOldDrops[3],
    "next PNB batch snapshots only eligible drops")
clock+=1000; inv.blocks=0 -- simulate a long PNB batch
assert(factoryCollectDrop(W,inv,state,blocked,1)=="collected" and inv.blocks==7)
assert(requests[1]==3 and requests[3]==1,"long PNB does not expire the ghost exclusion")
assert(factoryCollectDrop(W,inv,state,blocked,1)=="done","stale visuals cannot start another collect/PNB loop")
assert(factoryCollectDrop(W,inv,state,blocked,1)=="done" and requests[1]==3)
local sameTile={uid=4,id=954,n=5,x=10.5,y=4.5}
drops={ghost,sameTile}; state.x=10.5
assert(collectDropsNearby(W,inv,state,0.9)==5 and requests[4]==1,
    "new UID at the ghost's position is still collected")
print("PASS one-visit verification, visual bobbing, per-UID failures, other-drop progress, long PNB memory, new UID")

local partial={uid=5,id=954,n=5,x=10.5,y=4.5}
drops={partial}; inv.blocks=198
for i=1,4 do
    clock+=0.2
    local _,needsRoom=collectDropsNearby(W,inv,state,0.9)
    assert(needsRoom and not dropIgnored(W,partial),"insufficient room is not a visual drop")
end
inv.blocks=190
assert(collectDropsNearby(W,inv,state,0.9)==5 and requests[5]==5)
local full={uid=6,id=954,n=1,x=10.5,y=4.5}
drops={full}; inv.blocks=200
collectDropsNearby(W,inv,state,0.9)
assert(not requests[6] and not dropIgnored(W,full),"full inventory never counts as take failure")
inv.blocks=0; throwError=true
for i=1,4 do clock+=0.2; collectDropsNearby(W,inv,state,0.9) end
assert(not dropIgnored(W,full),"executor/network errors are not visual evidence")
throwError=false
assert(collectDropsNearby(W,inv,state,0.9)==1)
local far={uid=7,id=954,n=1,x=11.5,y=4.5}
drops={far}; rejected[7]=true
for i=1,4 do clock+=0.2; collectDropsNearby(W,inv,state,1.35) end
assert(not dropIgnored(W,far),"out-of-reach rejection never blacklists the UID")
rejected[7]=nil; state.x=11.5
assert(collectDropsNearby(W,inv,state,0.9)==1)
print("PASS partial capacity, full inventory, network errors, out-of-reach drops")

local unreachable={uid=8,id=954,n=1,x=10.5,y=4.5}
drops={unreachable}; inv.blocks=0; forceMoveFail=true
assert(factoryCollectDrop(W,inv,state,{},1)=="path" and not requests[8]
    and not dropIgnored(W,unreachable),"failed centering must not mark a real drop as visual")
forceMoveFail=false
local transient={uid=9,id=954,n=1,x=10.5,y=4.5}
drops={transient}
local originalTake=W.takeDrop
function W.takeDrop(uid,n)
    if uid==9 and (requests[uid] or 0)<2 then requests[uid]=(requests[uid] or 0)+1; return 0 end
    return originalTake(uid,n)
end
assert(factoryCollectDrop(W,inv,state,{},1)=="collected" and requests[9]==3 and inv.blocks==1,
    "a transient failure can recover during the verification visit")
W.takeDrop=originalTake
print("PASS failed positioning, transient rejection recovery")

state.x=10.5; inv.blocks=0; drops={ghost}; rejected[1]=nil
ghost.n=6
assert(collectDropsNearby(W,inv,state,0.9)==6,"changed stack with reused UID is reconsidered")
W.name="OTHER"; Bind.name="OTHER"
assert(collectDropsNearby(W,inv,state,0.9)==6,"world change resets UID memory")
W.fg={} -- rejoin into freshly loaded world data
assert(collectDropsNearby(W,inv,state,0.9)==6,"reloaded world data resets UID memory")
drops={}; clock+=6
factoryBaseDrops(W,954)
assert(next(DropMemory.records)==nil,"vanished records are pruned")
for i=1,10000 do drops[i]={uid=i+100,id=954,n=1,x=90.5,y=4.5} end
local before=listCalls
collectDropsNearby(W,inv,state,0.9)
assert(listCalls==before+1 and next(DropMemory.records)==nil,
    "distant drop scan creates no records and requests no additional snapshot")
print("PASS changed stack, world scope, world reload, cleanup, lightweight distant-drop scan")

local requestTimes={}
function W.takeDrop(uid,n)
    table.insert(requestTimes,clock)
    return originalTake(uid,n)
end
drops={}; inv.blocks=0; Move.gen=0
for i=1,3 do drops[i]={uid=20000+i,id=954,n=1,x=10.5,y=4.5} end
assert(collectDropsNearby(W,inv,state,0.9)==3 and #requestTimes==3)
for i=2,#requestTimes do
    assert(requestTimes[i]-requestTimes[i-1]>=0.02-1e-6,
        "nearby drop requests cannot burst in the same frame")
end
local originalWait=task.wait
task.wait=function(dt) originalWait(dt); Move.gen+=1 end
drops={}; requestTimes={}
for i=1,3 do drops[i]={uid=21000+i,id=954,n=1,x=10.5,y=4.5} end
assert(collectDropsNearby(W,inv,state,0.9)==1 and #requestTimes==1,
    "Stop during request pacing prevents the rest of the collection batch")
task.wait=originalWait
W.takeDrop=originalTake
print("PASS collection request spacing and Stop during pacing")
'''

program = "\n".join([
    prelude,
    extract("local DropMemory =", "local function collectDropsAtTile("),
    extract("local function factoryCount(", "local function factoryWorkSpot("),
    extract("local function factoryRoom(", "local function factoryHasPlantTile("),
    extract("local PNB_DRAIN_BATCH =", "local function factoryCycleStep("),
    checks,
])
with tempfile.TemporaryDirectory(prefix="humanhub-drops-") as directory:
    path = Path(directory) / "drops.luau"
    path.write_text(program, encoding="utf-8")
    subprocess.run([sys.argv[1], str(path)], check=True)
