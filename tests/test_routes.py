"""Exercise actual route graph and target selection on open multi-floor farms.

Usage: python tests/test_routes.py <luau.exe> [git-revision]
An optional revision runs the same regressions against the old source.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "hub.luau").read_text(encoding="utf-8-sig")
if len(sys.argv) > 2:
    source = subprocess.run(
        ["git", "show", f"{sys.argv[2]}:hub.luau"], cwd=root,
        capture_output=True, text=True, encoding="utf-8", check=True,
    ).stdout


def extract(start, end):
    return source[source.index(start):source.index(end, source.index(start))]


prelude = r'''
local now, yields = 0, 0
local os = {clock=function() return now end}
local task = {wait=function() yields+=1 end}
local Hub = {dead=false}
local W = {w=100,h=60,fg={}}
local inv = {count=function() return 200 end}
local Bind = {W=W,inv=inv}
function Bind.getW() return W end
function Bind.solid(x,y)
    return W.fg[y] and W.fg[y][x]==2 or false
end
local Factory = {cycle=true,workX=10,workY=3}
local function factoryTreeRipe() return true end
local function reset(w,h)
    W.w=w; W.h=h; W.fg={}
    for y=0,h-1 do
        W.fg[y]={}
        for x=0,w-1 do W.fg[y][x]=0 end
    end
end
local function floor(y,from,to)
    for x=from,to do W.fg[y][x]=2 end
end
'''

cases = r'''
-- A clear shaft beside each floor, with four-tile floor spacing.
-- Descending is valid even when the return staircase is elsewhere.
reset(100,60)
for y=4,56,4 do floor(y,2,97) end
W.fg[55][60]=955
local distances,parents=Path.explore(50,3,6000)
assert(distances[keyOf(60,55)], "open shaft must reach ripe tree on bottom floor")
local target=factoryTarget(W,{x=50.5,y=4,grounded=true},955,{},"harvest")
assert(target and target.y==55, "harvest selects the reachable lower floor")
W.fg[55][60]=0
target=factoryTarget(W,{x=50.5,y=4,grounded=true},955,{["plant:row:3"]=100},"plant")
assert(target and target.y>3, "plant searches lower floors when current row is postponed")
print("PASS whole-world harvest/plant across clear descent shafts")

-- Long drop landing directly in the adjacent shaft, rather than returning
-- to the takeoff column; both are physical descents supported by pathStep.
reset(12,20)
floor(4,2,8); floor(16,0,1)
distances,parents=Path.explore(2,3,6000)
assert(distances[keyOf(1,15)] and parents[keyOf(1,15)].kind=="fall",
    "clear long descent may land in the shaft")
print("PASS long shaft landing")

-- A closed ceiling/floor is still impassable; no edge may teleport
-- through a solid tile, beyond the first landing, or through the world.
reset(12,20)
floor(4,0,11); floor(8,0,11)
distances=Path.explore(5,3,6000)
assert(not distances[keyOf(5,7)], "solid full-width floor cannot be crossed downward")
reset(12,40)
floor(4,2,8); floor(32,2,8)
distances=Path.explore(2,3,6000)
assert(not distances[keyOf(2,31)], "descent stays within the 24-tile movement bound")
print("PASS solid-floor and excessive-depth rejection")

-- The only walk edge failed once. Target discovery must reset stale route
-- exclusions before moveTo; otherwise no target ever reaches its recovery.
reset(8,8)
floor(4,0,7); floor(2,0,7) -- low roof excludes jump detours
W.fg[3][6]=955
Path.clearEdges(); Path.targetRetryAt=nil
Path.blockEdge(1,3,2,3,60)
local state={x=1.5,y=4,grounded=true}
target=factoryTarget(W,state,955,{},"harvest")
assert(target and target.x==6 and next(Path.blockedEdges)==nil,
    "target discovery recovers a stale route exclusion")
Path.blockEdge(1,3,2,3,60)
target=factoryTarget(W,state,955,{},"harvest")
assert(not target and next(Path.blockedEdges)~=nil,
    "route reset is throttled instead of retried every tick")
now=8
local blocked={["955:harvest:3:6"]=100}
target=factoryTarget(W,state,955,blocked,"harvest")
assert(not target, "route reset preserves cooldown for a tree that failed to harvest")
now=16
Path.blockEdge(1,3,2,3,60)
target=factoryTarget(W,state,955,{},"harvest")
assert(target and target.x==6, "target can retry after bounded cooldown")
print("PASS stale-edge recovery, throttling and target cooldown")

-- Existing upward platform links remain usable across several floors.
reset(12,20)
for y=4,16,3 do floor(y,2,9); W.fg[y][1]=102 end
Path.clearEdges()
distances=Path.explore(5,15,6000)
assert(distances[keyOf(5,3)], "one-way platform staircase remains traversable upward")
print("PASS upward platform staircase")

-- A route failure while approaching another floor must not hide the same
-- tree for a minute once the player is beside it on an open row.
reset(12,10)
floor(4,0,11); floor(2,0,11)
W.fg[3][3]=955
local key="955:harvest:3:3"
local cooldown={[key]=now+60}
Factory.harvestPathRetryAt={[key]=now+3}
state={x=8.5,y=4,grounded=true}
assert(not factoryTarget(W,state,955,cooldown,"harvest"), "movement retry respects three-second cooldown")
now+=3
target=factoryTarget(W,state,955,cooldown,"harvest")
assert(target and target.x==3 and target.y==3, "same-floor tree retries a failed route promptly")
Factory.harvestPathRetryAt={}
assert(not factoryTarget(W,state,955,cooldown,"harvest"), "failed punches retain their cooldown")
print("PASS same-floor movement retry without bypassing failed-punch cooldown")

-- Actual grounded position can already reach the adjacent tree, even if
-- a collision query rejects the occupied tile. No route search is needed.
local standable,explore=Path.standable,Path.explore
Path.standable=function() return false end
Path.explore=function() error("adjacent tree must use the actual grounded position") end
state={x=4.5,y=4,grounded=true}
target=factoryTarget(W,state,955,{},"harvest")
assert(target and target.x==3 and target.standX==4, "grounded player can harvest adjacent tree directly")
Path.explore=function() return {} end
state.grounded=false
assert(not factoryTarget(W,state,955,{},"harvest"), "airborne position cannot bypass route discovery")
Path.standable=standable; Path.explore=explore
print("PASS adjacent tree without pathfinder dependence")
'''

program = "\n".join([
    prelude,
    extract("local Path =", "-- Riwayat singkat langkah gerak"),
    extract("local function edgeBlocked(", "function Path.probeJump("),
    extract("function Path.standable(", "function Path.reconstruct("),
    extract("local function factoryTarget(", "local function factoryWork("),
    cases,
])
with tempfile.TemporaryDirectory(prefix="humanhub-routes-") as directory:
    path = Path(directory) / "routes.luau"
    path.write_text(program, encoding="utf-8")
    result = subprocess.run([sys.argv[1], str(path)], capture_output=True,
                            text=True, encoding="utf-8")
    print(result.stdout, end="")
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        raise SystemExit(result.returncode)
