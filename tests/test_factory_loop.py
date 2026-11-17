"""Run actual factory phase transitions with a simulated native collector.

Farm actions and server replies are mocked; phase/drain code is extracted
from hub.luau. Other tests exercise the actual plant/PNB/collect actions.
Usage: python tests/test_factory_loop.py <luau.exe>
"""
from pathlib import Path
import subprocess
import sys
import tempfile

source = (Path(__file__).resolve().parents[1] / "hub.luau").read_text(encoding="utf-8-sig")
def extract(a,b):
    i=source.index(a)
    return source[i:source.index(b,i)]

prelude=r'''
local clock=0
local os={clock=function() return clock end}
local W={name="FARM",fg={},drops={}}
local state={x=10.5,y=5,grounded=true}
local inv={blocks=200,seeds=0}
function inv.count(_,id) return id==955 and inv.seeds or inv.blocks end
function inv.room(_,id) return 200-inv:count(id) end
local Factory={running=true,cycle=true,phase="harvest",baseId=954,seedId=955,
    planted=0,harvested=0,pnb=0,pnbDrainCount=0}
local Bind={name=W.name,state=function() return state end}
local Move={release=function() end}
local wireCalls,broken,late,returned=0,0,0,0
local firstTakePhase=nil
function W.dropList() return W.drops end
function W.takeDrop(uid,n)
    wireCalls+=1; firstTakePhase=firstTakePhase or Factory.phase
    return n
end
local nativeTake=W.takeDrop
local function factoryCount(_,id) return inv:count(id) end
local function factoryRoom(_,id) return inv:room(id) end
local function factoryBaseDrops() return W.drops end
local function selectedItemDefinition() return {grow=1} end
local function setFactoryStatus(s) Factory.status=s end
local function factoryAlive() return Factory.running end
local function factoryHasTrees() return true end
local function factoryHasRipeTree() return false end
local function factoryGrowDesc() return "growing" end
local function collectDropsNearby() return 0 end
local function factoryTarget(_,_,_,_,kind) if kind=="plant" then return {kind="plant"} end end
local function factoryWorkSpot() return 10,10,4 end
local function factoryWork()
    assert(Factory.phase=="plant" and inv.seeds>0)
    inv.seeds-=1; Factory.planted+=1; return true
end
local function factoryPNBOne(_,_,_,_,skip)
    assert(skip,"every Factory PNB entry must drain before collecting")
    inv.blocks-=1; broken+=1; Factory.pnb+=1
    if late>0 then inv.blocks+=late; late=0 end -- already-sent pickup ACK
    -- Some breaks return a real block, which must be collected and broken
    -- again. A finite return budget models eventual consumption.
    if returned<7 and broken%10==0 then
        returned+=1
        table.insert(W.drops,{uid=broken+10,id=954,n=1,x=10.5,y=4.5})
    end
    for i=#W.drops,1,-1 do
        local drop=W.drops[i]
        local got=W.takeDrop(drop.uid,drop.n)
        inv.blocks+=got
        if got>0 then table.remove(W.drops,i) end
    end
    if broken%10==0 then inv.seeds+=1 end
    return true
end
local function factoryCollectDrop()
    assert(inv.seeds==0,"collect cannot run before every available seed is planted")
    local d=W.drops[1]
    if not d then return "done",0 end
    local got=W.takeDrop(d.uid,d.n)
    inv.blocks+=got; table.remove(W.drops,1)
    return "collected",got
end
'''
checks=r'''
local function step()
    factoryCycleStep(W,inv,state,955,{},1); clock+=0.1
    assert(W.takeDrop==nativeTake,"Factory phases must not replace or gate native takeDrop")
end
local function run(initial,extra)
    Factory.phase="harvest"; Factory.planted=0; Factory.pnb=0; Factory.resumePNB=false
    Factory.resumeCollect=false; Factory.pnbDraining=false; Factory.pnbDrainCount=0
    W.drops={{uid=1,id=954,n=1,x=10.5,y=4.5}}
    inv.blocks=initial; inv.seeds=0; broken=0; wireCalls=0; late=extra; firstTakePhase=nil; returned=0
    if initial<200 then beginPNB(W,initial) end
    for i=1,1000 do
        step()
        if Factory.phase=="plant" then break end
    end
    assert(inv.blocks==0 and broken==initial+extra+returned+1 and wireCalls==returned+1,
        "PNB collects/rebreaks both old and fresh blocks and reaches actual zero without changing phase early")
    local seeds=inv.seeds
    for i=1,1000 do
        step()
        if Factory.phase=="collect" then break end
    end
    assert(inv.seeds==0 and Factory.planted==seeds and wireCalls==returned+1,
        "plant consumes all seeds after PNB has exhausted actual stock")
    step()
    assert(wireCalls==returned+1 and firstTakePhase=="pnb" and inv.blocks==0,
        "collect finds no leftover old stack because it was already picked during PNB")
end
run(200,0)
run(169,31)
run(40,0)
print("PASS full factory: old/fresh blocks collected and rebroken during PNB, then all seeds planted")
print("PASS late ACK cannot finish at stale 169-block target; default partial-stock PNB also drains")
'''
program="\n".join([prelude,
    extract("local function factoryHarvestCapacity(","local function factoryWork("),
    extract("local PNB_DRAIN_BATCH =","local function startFactory("),
    checks])
with tempfile.TemporaryDirectory(prefix="humanhub-factory-loop-") as directory:
    path=Path(directory)/"loop.luau"
    path.write_text(program,encoding="utf-8")
    result=subprocess.run([sys.argv[1],str(path)],capture_output=True,text=True,encoding="utf-8")
    print(result.stdout,end="")
    if result.returncode:
        print(result.stderr,file=sys.stderr)
        raise SystemExit(result.returncode)
