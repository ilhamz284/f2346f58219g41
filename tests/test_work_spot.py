"""Exercise actual station selection, including leftover blocks and map edges."""
from pathlib import Path
import subprocess, sys, tempfile
src=(Path(__file__).resolve().parents[1]/"hub.luau").read_text(encoding="utf-8-sig")
start=src.index("local function factoryWorkSpot(")
fn=src[start:src.index("local function factoryPNBOne(",start)]
pre=r'''
local W={w=100,h=6}
local Factory={baseId=954,baseLayer="fg",baseAtSelf=true}
local function keyOf(x,y) return y*1000+x end
local cells={}
local function tileId(x,y) return cells[keyOf(x,y)] or 955 end
local function bgId() return 0 end
local Bind={solid=function(_,y) return y==5 end}
local Path={explore=function()
 local d={};for x=0,99 do d[keyOf(x,4)]=math.abs(x-45) end;return d
end}
local state={x=45.5,y=4.999}
'''
checks=r'''
cells[keyOf(99,4)]=0
assert(factoryWorkSpot(W,state,{})==nil,"outermost platform is not a reachable PNB center")
cells[keyOf(64,4)]=0
assert(factoryWorkSpot(W,state,{})==64,"an interior empty tile can be reserved")
cells[keyOf(45,4)]=954
assert(factoryWorkSpot(W,state,{})==45,"leftover selected farm block is a usable station")
assert(factoryWorkSpot(W,state,{["pnb:4:45"]=1})==64,"blocked station yields to another tile")
print("PASS actual station selector: edge rejection, interior tile, existing farm block, retry exclusion")
'''
# Station cooldowns use a deterministic clock.
pre+='\nlocal os={clock=function() return 0 end}\n'
with tempfile.TemporaryDirectory() as td:
 p=Path(td)/"spot.luau";p.write_text(pre+fn+checks,encoding="utf-8")
 subprocess.run([sys.argv[1],str(p)],check=True)
