"""Verify actual harvest-to-PNB decisions, including temporary route misses.

Usage: python tests/test_cycle.py <luau.exe> [git-revision]
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "hub.luau").read_text(encoding="utf-8-sig")
if len(sys.argv) > 2:
    source = subprocess.run(["git", "show", f"{sys.argv[2]}:hub.luau"], cwd=root,
                            capture_output=True, text=True, encoding="utf-8", check=True).stdout

start = source.index("local function factoryCycleStep(")
cycle = source[start:source.index("local function startFactory(", start)]
prelude = r'''
local now=0
local os={clock=function() return now end}
local W={name="TEST"}
local state={x=4.5,y=4,grounded=true}
local Bind={state=function() return state end}
local inv={blocks=30,seeds=0}
local Factory={}
local targetAvailable,ripeTrees,room,workReason=true,true,170,nil
local pnbCalls,workCalls,lastDrain=0,0,nil
local function selectedItemDefinition() return {grow=1,name="Seed"} end
local function factoryCount(_,id) return id==955 and inv.seeds or inv.blocks end
local function factoryRoom() return room end
local function factoryTarget(_,_,_,blocked,kind)
    if kind=="harvest" and targetAvailable and not blocked["955:harvest:3:3"] then
        return {kind="harvest",x=3,y=3,standX=4,standY=3}
    end
end
local function factoryWork()
    workCalls+=1
    if workReason then return false,workReason end
    inv.blocks+=1; Factory.harvested+=1
    return true
end
local function factoryHasRipeTree() return ripeTrees end
local function factoryHasTrees() return true end
local function factoryGrowDesc() return "growing" end
local function factoryAlive() return true end
local function collectDropsNearby() return 0,false end
local function setFactoryStatus(s) Factory.status=s end
local function beginPNB(_,_,drain) pnbCalls+=1; lastDrain=drain; Factory.phase="pnb" end
local Move={release=function() end}
local function reset(phase,blocks)
    Factory={phase=phase,baseId=954,seedId=955,seedGrow=1,cycle=true,
        harvested=0,pnb=0,planted=0,harvestFailCount={},harvestPathRetryAt={}}
    inv.blocks=blocks or 30; inv.seeds=0
    now=0; targetAvailable=true; ripeTrees=true; room=200-inv.blocks; workReason=nil
    pnbCalls=0; workCalls=0; lastDrain=nil
end
'''

cases = r'''
reset("harvest",30)
targetAvailable=false
local blocked={["955:harvest:3:3"]=60}
for i=1,60 do
    factoryCycleStep(W,inv,state,955,blocked,1); now+=1
    assert(Factory.phase=="harvest" and pnbCalls==0,
        "30 blocks plus ripe trees must stay in harvest throughout route cooldown")
end
targetAvailable=true; blocked={}
factoryCycleStep(W,inv,state,955,blocked,1)
assert(workCalls==1 and inv.blocks==31, "harvest resumes after temporary target loss")
print("PASS harvest keeps 30 blocks through target/route cooldown, then resumes")

for _,reportedRoom in ipairs({170,0}) do
    reset("harvest",30)
    Factory.collectNeedsRoom=true; Factory.blockedDropId=955; room=reportedRoom
    factoryCycleStep(W,inv,state,955,{},1)
    assert(Factory.phase=="harvest" and workCalls==1 and pnbCalls==0,
        "pickup failure and room reading must not substitute for block count 200")
end
reset("harvest",199)
factoryCycleStep(W,inv,state,955,{},1)
assert(inv.blocks==200 and pnbCalls==0, "last harvest fills stack before PNB")
factoryCycleStep(W,inv,state,955,{},1)
assert(Factory.phase=="pnb" and pnbCalls==1 and lastDrain==true, "200 blocks start full drain")
print("PASS pickup flags, room readings and exact 200-block threshold")

reset("harvest",30)
targetAvailable=false; ripeTrees=false
factoryCycleStep(W,inv,state,955,{},1)
assert(Factory.phase=="pnb" and pnbCalls==1, "no ripe trees allows early PNB as specified")
reset("grow",30)
targetAvailable=false
factoryCycleStep(W,inv,state,955,{},1)
assert(Factory.phase=="harvest" and pnbCalls==0, "grow cannot start early PNB while ripe trees remain")
reset("grow",30)
targetAvailable=false; ripeTrees=false
factoryCycleStep(W,inv,state,955,{},1)
assert(Factory.phase=="pnb" and pnbCalls==1, "grow can PNB when no ripe trees remain")
reset("grow",30)
Factory.resumePNB=true
factoryCycleStep(W,inv,state,955,{},1)
assert(Factory.phase=="pnb" and pnbCalls==1, "explicit interrupted PNB resumes after planting")
print("PASS no-ripe-tree exception, grow transition and pending PNB preservation")

reset("harvest",30)
local failed={}
workReason="path"
factoryCycleStep(W,inv,state,955,failed,1)
assert(failed["955:harvest:3:3"]>now and Factory.harvestPathRetryAt["955:harvest:3:3"]==now+3,
    "movement failures schedule a short same-floor retry")
failed={}; workReason="break"
factoryCycleStep(W,inv,state,955,failed,1)
assert(failed["955:harvest:3:3"]==now+60 and Factory.harvestPathRetryAt["955:harvest:3:3"]==nil,
    "failed punches cannot use movement retry")
failed={}; workReason=nil
Factory.harvestPathRetryAt["955:harvest:3:3"]=now+3
factoryCycleStep(W,inv,state,955,failed,1)
assert(Factory.harvestPathRetryAt["955:harvest:3:3"]==nil, "successful harvest clears movement retry")
print("PASS movement retry recording and cleanup")
'''

with tempfile.TemporaryDirectory(prefix="humanhub-cycle-") as directory:
    path = Path(directory) / "cycle.luau"
    path.write_text("\n".join([prelude,cycle,cases]), encoding="utf-8")
    result = subprocess.run([sys.argv[1],str(path)], capture_output=True,
                            text=True, encoding="utf-8")
    print(result.stdout,end="")
    if result.returncode:
        print(result.stderr,file=sys.stderr)
        raise SystemExit(result.returncode)
