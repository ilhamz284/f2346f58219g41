"""Run the actual harvest/movement functions with a deterministic game stub.

Usage: python tests/test_harvest.py <path-to-luau.exe>
No Roblox client or account is touched.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

source = (Path(__file__).resolve().parents[1] / "hub.luau").read_text(encoding="utf-8-sig")


def extract(start, end):
    return source[source.index(start):source.index(end, source.index(start))]


prelude = r'''
local clock = 0
local os = {clock = function() return clock end}
local state = {x=10.5, y=5, grounded=true}
local active, direction, idleCount = true, 0, 0
local KeyRight, KeyLeft = 1, -1
local Move = {gen=0, cfg={reactMin=0.1,reactMax=0.2}}
function Move.ensureBackend() return true end
function Move.release() direction=0; Move.held=nil end
function Move.hold(key) direction=key; Move.held=key end
function Move.idle() idleCount+=1; clock+=0.1 end
local task = {wait=function(dt)
    dt = dt or 0.016
    clock+=dt
    state.x+=direction*7*dt
end}
local Bind = {name="TEST"}
function Bind.state() return state end
local function log() end
'''

movement_tests = r'''
assert(Move.walkTo(12.5,{quick=true, floorY=5, timeout=2, alive=function() return active end}))
assert(math.abs(state.x-12.5)<=0.14 and idleCount==0 and direction==0, "quick movement")
state.x=10.5
assert(Move.walkTo(10.5,{}))
assert(idleCount==2, "normal movement retains its pauses")
active=false; Move.hold(KeyRight)
assert(not Move.walkTo(20.5,{quick=true,alive=function() return active end}))
assert(direction==0, "Stop releases input")
active=true; state.y=6
assert(not Move.walkTo(20.5,{quick=true,floorY=5}))
assert(direction==0, "floor change aborts horizontal movement")
print("PASS quick movement, normal movement, Stop, floor guard")
local pathCalls, walks, solidHole, ripe, punches = 0,0,nil,true,0
local W = {name="TEST", w=100, h=60}
local tiles = {}
local Factory = {seedId=955,harvest=true,cycle=false,harvested=0}
local inv = {room=function() return 200 end, add=function() end}
local function standingFloor(s) return math.floor(s.y-0.0001)+1 end
local function factoryAlive() return active end
local function tileId(x,y) return tiles[y*100+x] or 0 end
local function bgId() return 0 end
function Bind.solid(x,y) return y==5 and x~=solidHole end
local Path = {}
function Path.standable(x,y) return y==4 and x>=0 and x<99 and x~=solidHole end
function Path.moveTo(x,y,alive)
    pathCalls+=1
    if not alive() then return false,"alive" end
    state.x=x+0.5; state.y=y+1; state.grounded=true
    return true
end
function Move.walkTo(x,opts)
    walks+=1
    if opts.alive and not opts.alive() then return false end
    state.x=x
    return true
end
local function edgeBlocked() return false end
local function factoryTreeRipe() return ripe end
local function factoryTarget() return nil end
local function setFactoryStatus() end
local Dig = {}
function Dig.punch(x,y) punches+=1; tiles[y*100+x]=0; return true end
function W.dropList() return {} end
function W.takeDrop() return 0 end
'''

harvest_tests = r'''
local function harvest(fromX, y, x)
    state={x=fromX,y=y+1,grounded=true}; tiles[411]=nil; tiles[412]=nil
    tiles[4*100+x]=955
    return factoryWork(W,inv,{kind="harvest",x=x,y=4,standX=x-1,standY=4},955,1)
end
assert(harvest(10.5,4,11) and pathCalls==0 and punches==1, "adjacent tree skips pathfinder")
assert(harvest(2.5,4,11) and pathCalls==0 and punches==2, "clear corridor skips pathfinder")
solidHole=6
assert(harvest(2.5,4,11) and pathCalls==1, "gap falls back to pathfinder")
solidHole=nil
assert(harvest(2.5,7,11) and pathCalls==2, "other floor uses pathfinder")
ripe=false; local before=punches
assert(not harvest(10.5,4,11) and punches==before, "unripe tree is never punched")
ripe=true; active=false
assert(not harvest(10.5,4,11) and punches==before, "Stop prevents harvesting")
active=true
print("PASS adjacent tree, corridor, gap fallback, other floor, unripe tree, Stop")
local takenCalls, added, request, room, accepted = 0,0,0,200,5
local drop={uid=1,id=954,n=5,x=11.5,y=4.5}
state={x=11.5,y=5,grounded=true}
function W.dropList() return {drop} end -- stale visual persists after success
function W.takeDrop(uid,n) takenCalls+=1; request=n; return accepted end
function inv.room() return room end
function inv.add(_,_,n) added+=n; room-=n end
clock=0
local n,blocked=collectDropsAtTile(W,inv,11,4,function() return active end,true)
assert(n==5 and added==5 and takenCalls==1 and not blocked and clock<0.2, "successful stale drop is not retried")
takenCalls=0; added=0; room=2; accepted=2; clock=0
n,blocked=collectDropsAtTile(W,inv,11,4,function() return active end,true)
assert(request==5 and added==2 and blocked==954, "server handles partial stack, full inventory reported")
room=200; accepted=0; takenCalls=0; clock=0
collectDropsAtTile(W,inv,11,4,function() return active end,true)
assert(takenCalls==3 and clock<0.7, "rejected drop has bounded retries")
clock=0; room=200; accepted=5; takenCalls=0
function W.dropList() if clock<0.3 then return {} else return {drop} end end
n=collectDropsAtTile(W,inv,11,4,function() return active end,true)
assert(n==5 and takenCalls==1, "late spawn still collected")
clock=0; active=false; takenCalls=0
collectDropsAtTile(W,inv,11,4,function() return active end,true)
assert(takenCalls==0, "Stop prevents collection")
print("PASS stale drop, server partial stack, full inventory, retry limit, late spawn, Stop")
'''

program = "\n".join([
    prelude,
    extract("function Move.walkTo(", "--// ===== 4. PUKUL"),
    movement_tests,
    extract("local function collectDropsAtTile(", "local function collectNearby("),
    extract("local function factoryWork(", "local function factoryCount("),
    harvest_tests,
])
with tempfile.TemporaryDirectory(prefix="humanhub-harvest-") as directory:
    script = Path(directory) / "harvest.luau"
    script.write_text(program, encoding="utf-8")
    subprocess.run([sys.argv[1], str(script)], check=True)
