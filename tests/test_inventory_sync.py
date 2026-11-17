"""Exercise the actual on-demand server inventory reconciliation with RPC stubs."""
from pathlib import Path
import subprocess
import sys
import tempfile

source = (Path(__file__).resolve().parents[1] / "hub.luau").read_text(encoding="utf-8-sig")
start = source.index("function Factory.syncInventory(")
sync = source[start:source.index("-- Dipanggil worker UI", start)]
prelude = r'''
local clock,calls=0,0
local os={clock=function() return clock end}
local W={name="FARM",fg={}}
local inv={counts={[954]=199,[955]=12}}
function inv.count(_,id) return inv.counts[id] or 0 end
function inv.add(_,id,n) inv.counts[id]=(inv.counts[id] or 0)+n end
function inv.remove(_,id,n) inv.counts[id]=(inv.counts[id] or 0)-n end
local Factory={collectNeedsRoom=true,blockedDropId=954}
local Hub={dead=false}
local DropMemory={}
local Bind={W=W,inv=inv,context={world=W,Shared={Net={}}}}
local Move={release=function() end}
local response,onCall={slots={{954,200},{955,12}}},nil
local require=function()
 return {call=function(action)
  assert(action=="GetInventory");calls+=1
  if onCall then onCall() end
  return response
 end}
end
local function reset()
 clock+=11;Factory.inventorySyncAt=0;Factory.inventorySync=nil
 inv.counts={[954]=199,[955]=12};Bind.W=W;Bind.inv=inv
 Hub.dead=false;DropMemory.inFlight=nil;onCall=nil
 response={slots={{954,200},{955,12}}}
end
'''
checks = r'''
assert(Factory.syncInventory(W,inv,954,955) and inv:count(954)==200,
 "199 local / 200 server must correct the actual inventory, not fake the capacity threshold")
assert(not Factory.collectNeedsRoom and Factory.inventorySync.server[954]==200)
local before=calls
for i=1,100 do assert(not Factory.syncInventory(W,inv,954,955)) end
assert(calls==before,"repeated factory ticks do not poll the server during cooldown")
reset();response.slots={{954,199},{955,12}}
assert(Factory.syncInventory(W,inv,954,955) and inv:count(954)==199,
 "genuine 199 stock stays 199; do not round inventory up to 200")
reset();inv.counts[954]=150;response.slots={{954,75},{954,74}}
assert(Factory.syncInventory(W,inv,954,955) and inv:count(954)==149 and inv:count(955)==0,
 "aggregate server slots and apply both positive and negative corrections")
print("PASS server-only counts, genuine 199, slot aggregation, missing item and bounded requests")

reset();onCall=function() inv.counts[954]=198 end
assert(Factory.syncInventory(W,inv,954,955) and inv:count(954)==198,
 "an inventory change during the RPC must not be overwritten by an older response")
reset();DropMemory.inFlight={};before=calls
local ok,why=Factory.syncInventory(W,inv,954,955)
assert(not ok and why=="pending" and calls==before and inv:count(954)==199,
 "wait for outstanding script pickup before requesting a snapshot")
DropMemory.inFlight=nil
assert(Factory.syncInventory(W,inv,954,955),"pending pickup cannot consume the sync cooldown")
reset();onCall=function() Bind.W={} end
assert(not Factory.syncInventory(W,inv,954,955) and inv:count(954)==199,
 "a world change during the query cancels reconciliation")
reset();onCall=function() W.fg={} end
assert(not Factory.syncInventory(W,inv,954,955) and inv:count(954)==199,
 "a reload into a new world grid cancels reconciliation")
reset();response={slots={{954,200},{955,"bad"}}}
assert(not Factory.syncInventory(W,inv,954,955) and inv:count(954)==199,
 "validate all data before applying any inventory mutation")
reset();response={slots={{955,19}}}
assert(Factory.syncInventory(W,inv,nil,955) and inv:count(955)==19,
 "seed-only mode must reconcile even without a block pair")
print("PASS concurrent pickup, in-flight wait, world/grid guards, malformed data and seed-only mode")
'''
with tempfile.TemporaryDirectory(prefix="humanhub-inventory-sync-") as directory:
    path=Path(directory)/"sync.luau"
    path.write_text("\n".join([prelude,sync,checks]),encoding="utf-8")
    result=subprocess.run([sys.argv[1],str(path)],capture_output=True,text=True,encoding="utf-8")
    print(result.stdout,end="")
    if result.returncode:
        print(result.stderr,file=sys.stderr)
        raise SystemExit(result.returncode)
