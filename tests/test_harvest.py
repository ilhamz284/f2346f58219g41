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
function task.spawn(fn) fn() end
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
function inv.count() return 0 end
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
takenCalls=0; added=0; room=2; accepted=2; clock=0; drop.uid=2
n,blocked=collectDropsAtTile(W,inv,11,4,function() return active end,true)
assert(request==5 and added==2 and blocked==954, "server handles partial stack, full inventory reported")
room=200; accepted=0; takenCalls=0; clock=0; drop.uid=3
collectDropsAtTile(W,inv,11,4,function() return active end,true)
assert(takenCalls==3 and clock<0.7, "rejected drop has bounded retries")
clock=0; room=200; accepted=5; takenCalls=0; drop.uid=4
function W.dropList() if clock<0.3 then return {} else return {drop} end end
n=collectDropsAtTile(W,inv,11,4,function() return active end,true)
assert(n==5 and takenCalls==1, "late spawn still collected")
clock=0; active=false; takenCalls=0; drop.uid=5
collectDropsAtTile(W,inv,11,4,function() return active end,true)
assert(takenCalls==0, "Stop prevents collection")
print("PASS stale drop, server partial stack, full inventory, retry limit, late spawn, Stop")

-- A seed/gem is replicated first; the harvested block arrives later.
-- Exercise factoryWork itself so its expected block ID must reach collect.
Factory.pairId=954
local seedDrop={uid=101,id=955,n=1,x=11.5,y=4.5}
local blockDrop={uid=102,id=954,n=5,x=11.5,y=4.5}
local blockCount,seedCount,seedFull=0,0,false
local requestTimes={}
function inv.count(_,id) return id==955 and seedCount or blockCount end
function inv.room(_,id) return id==955 and (seedFull and 0 or 200-seedCount) or 200-blockCount end
function inv.add(_,id,n)
    if id==955 then seedCount+=n else blockCount+=n end
end
function W.dropList()
    return clock>=0.42 and {seedDrop,blockDrop} or {seedDrop}
end
function W.takeDrop(uid,n)
    table.insert(requestTimes,{uid=uid,t=clock})
    return n
end
clock=0; active=true
assert(harvest(11.5,4,11) and blockCount==5 and seedCount==1,
    "harvest must wait for delayed blocks after collecting the first seed")
assert(#requestTimes==2 and requestTimes[2].t-requestTimes[1].t>=0.08-1e-6,
    "harvest collect requests are spaced without repeating successful drops")
seedDrop.uid=103; blockDrop.uid=104
clock=0; blockCount=0; seedFull=true; requestTimes={}
collectDropsAtTile(W,inv,11,4,function() return active end,true,954)
assert(blockCount==5 and #requestTimes==1,
    "a full seed stack cannot hide an already-fallen block drop")
print("PASS seed-first late-block harvest, request pacing, full seed stack")

-- Several drops are in the search circle, but movement into range fails.
-- No pickup request may be sent for the unreachable neighbor.
clock=0; seedDrop.uid=105; blockDrop.uid=106; seedFull=false
requestTimes={}; blockCount=0; seedCount=0
state={x=10.5,y=5,grounded=true}
function W.dropList() return {blockDrop} end
local walkTo=Move.walkTo
function Move.walkTo() return false end
collectDropsAtTile(W,inv,11,4,function() return active end,true,954)
assert(#requestTimes==0 and not dropIgnored(W,blockDrop),
    "failed movement cannot send out-of-range requests or mark real drops as visual")
Move.walkTo=walkTo
print("PASS failed positioning sends no collect packets")

-- A live drop can be visible but still carry the game's pickup delay.
clock=0; active=true; state={x=11.5,y=5,grounded=true}
blockDrop.uid=107; blockDrop.readyAt=1
blockCount=0; requestTimes={}
assert(harvest(11.5,4,11) and blockCount==5 and #requestTimes==1,
    "harvest waits for the visible block's actual readyAt before leaving")
assert(requestTimes[1].t>=1,"no premature take packets while the game pickup delay is active")
print("PASS harvest honors actual pickup readiness")

-- Native collection can complete before factoryWork enters its collector.
-- Inventory growth must use the baseline from before the tree was punched.
local originalPunch=Dig.punch
function Dig.punch(x,y)
    originalPunch(x,y)
    blockCount+=2 -- native collector got the block during the punch
    return true
end
function W.dropList() return {} end
clock=0; blockCount=0; seedFull=false; requestTimes={}
for i=1,20 do assert(harvest(11.5,4,11)) end
assert(blockCount==40 and #requestTimes==0 and clock<1,
    "twenty native pickups cannot pay twenty redundant half-second waits")
print(string.format("PASS native pickup before collect: 20 trees in %.3f simulated seconds",clock))

-- An unrelated outstanding script pickup is not evidence for the new tree.
blockCount=0; clock=0; DropMemory.inFlight={}
assert(harvest(11.5,4,11) and clock>=0.5,
    "pending previous RPC cannot falsely satisfy the current tree's pickup baseline")
DropMemory.inFlight=nil

-- If native pickup finishes while the collector is waiting, exit promptly.
clock=0; blockCount=0
local nativeDone=false
function W.dropList()
    if clock>=0.12 and not nativeDone then blockCount+=2; nativeDone=true end
    return {}
end
collectDropsAtTile(W,inv,11,4,function() return active end,true,954,0)
assert(nativeDone and clock<0.2,"native ACK observed during collect ends the wait promptly")
Dig.punch=originalPunch
print("PASS native pickup while waiting and pending-RPC baseline guard")

function W.dropList() return {} end
blockCount=200; seedFull=false
local punchBefore=punches
assert(not harvest(11.5,4,11) and punches==punchBefore,"full blocks prevent another tree hit")
blockCount=0; seedFull=true
assert(not harvest(11.5,4,11) and punches==punchBefore,"full seed room prevents another tree hit")
seedFull=false
local normalWalk=Move.walkTo
function Move.walkTo(x,opts)
    local ok=normalWalk(x,opts); blockCount=200; return ok
end
assert(not harvest(2.5,4,11) and punches==punchBefore,
    "inventory filling while approaching the tree prevents its first hit")
Move.walkTo=normalWalk
blockCount=0
function Dig.punch(x,y,tree,skip,lava,bg,canAct)
    blockCount=200 -- pickup completes while the hit cooldown is waiting
    if canAct and not canAct() then return false end
    return originalPunch(x,y)
end
assert(not harvest(11.5,4,11) and punches==punchBefore,
    "post-cooldown callback checks capacity before sending the hit")
Dig.punch=originalPunch
print("PASS full block/seed stacks, mid-route pickup and post-cooldown capacity guard")
'''

program = "\n".join([
    prelude,
    "math.randomseed(1701)",
    extract("local function rnd(", "local function log("),
    extract("function Move.walkTo(", "--// ===== 4. PUKUL"),
    movement_tests,
    extract("local DropMemory =", "local function collectDropsNearby("),
    extract("local function collectDropsAtTile(", "local function collectNearby("),
    extract("local function factoryHarvestCapacity(", "local function factoryCount("),
    harvest_tests,
])
with tempfile.TemporaryDirectory(prefix="humanhub-harvest-") as directory:
    script = Path(directory) / "harvest.luau"
    script.write_text(program, encoding="utf-8")
    subprocess.run([sys.argv[1], str(script)], check=True)
