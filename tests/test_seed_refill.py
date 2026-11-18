"""Test refill scheduling and prevention of pickup/storage loops using real helper."""
from pathlib import Path
import subprocess, sys, tempfile
src=(Path(__file__).resolve().parents[1]/"hub.luau").read_text(encoding="utf-8-sig")
start=src.index("local function factoryRefillSeeds(")
helper=src[start:src.index("-- Kosongkan seluruh blok",start)]
pre=r'''
local clock,count,calls=0,0,0
local os={clock=function() return clock end}
local Factory={seedId=955}
local room=true
local result="done"
local function factoryCount() return count end
local function factoryHasPlantTile() return room end
local function setFactoryStatus(s) Factory.status=s end
local function factoryCollectDrop(_,_,_,_,_,id)
 assert(id==955,"only selected seed is a refill target")
 calls+=1
 if result=="collected" then count=4 end
 return result,4
end
local function reset()
 clock+=4;Factory.seedRefillAt=0;Factory.seedRefilling=false;count=0;room=true;calls=0
end
'''
cases=r'''
reset();count=3
assert(not factoryRefillSeeds({}, {}, {}, {}, 1) and calls==0,"keep planting existing inventory first")
reset();room=false
assert(not factoryRefillSeeds({}, {}, {}, {}, 1) and calls==0,
 "full farm must not recollect seeds just stored in a Display Box")
reset();result="done"
for i=1,10 do assert(not factoryRefillSeeds({}, {}, {}, {}, 1)) end
assert(calls==1,"missing seeds cause one search per cooldown, not per frame")
reset();result="pending"
assert(factoryRefillSeeds({}, {}, {}, {}, 1))
assert(factoryRefillSeeds({}, {}, {}, {}, 1) and calls==1,
 "plant stays in refill while waiting for an ACK, without duplicate pickup")
clock+=.21;result="collected"
assert(factoryRefillSeeds({}, {}, {}, {}, 1) and count==4)
assert(not factoryRefillSeeds({}, {}, {}, {}, 1) and not Factory.seedRefilling,
 "once pickup is acknowledged, normal planting resumes")
reset();result="path"
assert(factoryRefillSeeds({}, {}, {}, {}, 1))
clock+=1;assert(factoryRefillSeeds({}, {}, {}, {}, 1) and calls==1)
clock+=1.1;result="done"
assert(not factoryRefillSeeds({}, {}, {}, {}, 1),"unreachable or ignored drops do not lock the phase forever")
print("PASS seed refill: existing inventory, full-farm guard, throttling, pending ACK, resume and exhausted targets")
'''
with tempfile.TemporaryDirectory() as td:
 p=Path(td)/"refill.luau";p.write_text(pre+helper+cases,encoding="utf-8")
 subprocess.run([sys.argv[1],str(p)],check=True)
