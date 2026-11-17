"""Exercise actual collection ACK, local sprite cleanup and in-flight handling.

Usage: python tests/test_collect_protocol.py <luau.exe>
"""
from pathlib import Path
import subprocess
import sys
import tempfile

source = (Path(__file__).resolve().parents[1] / "hub.luau").read_text(encoding="utf-8-sig")
start = source.index("local DropMemory =")
functions = source[start:source.index("local function collectDropsAtTile(", start)]
prelude = r'''
local clock=0
local Hub={onUnload=function() end}
local os={clock=function() return clock end}
local scheduled={}
local task={}
local function resume(co)
    local ok,delay=coroutine.resume(co)
    assert(ok,delay)
    if coroutine.status(co)~="dead" then table.insert(scheduled,{co=co,at=clock+(delay or 0)}) end
end
function task.spawn(fn) resume(coroutine.create(fn)) end
function task.wait(dt)
    clock+=dt or 0.016
    for i=#scheduled,1,-1 do
        if scheduled[i].at<=clock then
            local job=table.remove(scheduled,i)
            resume(job.co)
        end
    end
end
local Factory={baseId=954,ignoredDrops={},dropTakeFailures={}}
local W={name="TEST",fg={},drops={}}
function W.dropList() return W.drops end
local state={x=10.5,y=5,grounded=true}
local Bind={state=function() return state end}
local Move={gen=0}
local inv={n=0}
function inv.room() return 200-inv.n end
function inv.add(_,_,n) inv.n+=n end
local function standingFloor(s) return math.floor(s.y-0.0001)+1 end
local rpcCount,serverDelay,serverGot,raiseError=0,0,0,false
function W.takeDrop(uid,n)
    rpcCount+=1
    local answer=serverGot
    if serverDelay>0 then coroutine.yield(serverDelay) end
    if raiseError then error("connection error") end
    return answer
end
local setterCalls,gcCalls=0,0
local function setter(drop,n)
    setterCalls+=1; drop.n=n
    if n<=0 then
        local i=table.find(W.drops,drop)
        if i then table.remove(W.drops,i) end
        drop.frame:Destroy()
    else drop.count:set(n>1 and tostring(n) or "") end
end
local debug={getupvalues=function() return {W.drops} end}
local function filtergc() gcCalls+=1; return {setter} end
local function drop(uid,n)
    local frame={destroyed=false}
    function frame:Destroy() self.destroyed=true end
    local count={value=n}
    function count:set(value) self.value=value end
    return {uid=uid,id=954,n=n,x=10.5,y=4.5,frame=frame,count=count}
end
'''
checks = r'''
local first=drop(1,5)
W.drops={first}; serverGot=2
state.x=9.8 -- dx=.7, dy=.5: inside the old radius but outside native overlap.
local rangeRequests=rpcCount
for i=1,4 do collectDropsNearby(W,inv,state,0.9); clock+=0.2 end
assert(rpcCount==rangeRequests and not dropIgnored(W,first),
    "outside native overlap sends no packet and cannot classify a real drop as visual")
assert(not dropInReach({x=0.6,y=4.5},{x=0,y=5}),
    "native horizontal boundary is excluded")
state.x=10.5
assert(collectDropsNearby(W,inv,state,0.9)==2 and inv.n==2)
assert(first.n==3 and not first.frame.destroyed and first.count.value=="3",
    "partial server ACK updates the drop count without destroying the remainder")
serverGot=3
assert(collectDropsNearby(W,inv,state,0.9)==3 and inv.n==5)
assert(#W.drops==0 and first.frame.destroyed and first.n==0,
    "full server ACK removes the live record and sprite, just like manual collect")
assert(setterCalls==2 and gcCalls==1,"game setter is cached by exact live-list identity")
print("PASS server-confirmed partial/full local cleanup, cached game setter")

local shifted=drop(100,2)
W.drops={shifted}; syncDropMemory(W,W.drops)
local stale={x=10.5,y=5,grounded=true}
state.x=12; rangeRequests=rpcCount
local _,_,rangeStatus=requestDropTake(W,inv,shifted,stale,200)
assert(rangeStatus=="position" and rpcCount==rangeRequests,
    "request rechecks the live position instead of trusting a stale batch position")
state.x=10.5
print("PASS native pickup geometry, no false ghost, live-position guard")

local second=drop(2,4)
W.drops={second}; second.readyAt=clock+1
local before=rpcCount
assert(collectDropsNearby(W,inv,state,0.9)==0 and rpcCount==before,
    "pickup delay cannot send premature requests")
clock+=1.01; second.taking=true
assert(collectDropsNearby(W,inv,state,0.9)==0 and rpcCount==before,
    "native collector already owns this UID")
second.taking=false; serverGot=4
assert(collectDropsNearby(W,inv,state,0.9)==4 and second.frame.destroyed)
print("PASS pickup readiness and native collector ownership")

local delayed=drop(3,7)
W.drops={delayed}; serverDelay=4; serverGot=7
local began=clock
local n,_,status=collectDropsNearby(W,inv,state,0.9)
assert(n==0 and status=="pending" and clock-began<0.4,
    "slow RPC cannot hold the factory for the game's five-second ask timeout")
before=rpcCount
local other=drop(4,2)
table.insert(W.drops,other)
for i=1,5 do collectDropsNearby(W,inv,state,0.9) end
assert(rpcCount==before and delayed.taking,
    "one in-flight request blocks duplicate UID and parallel requests for other drops")
task.wait(4)
assert(not delayed.taking and delayed.frame.destroyed and inv.n==16,
    "late positive ACK still updates inventory and cleans the sprite exactly once")
serverDelay=0; serverGot=2
assert(collectDropsNearby(W,inv,state,0.9)==2 and inv.n==18)
print("PASS bounded wait, one in-flight request and late-ACK reconciliation")

local rejected=drop(5,1)
W.drops={rejected}; serverGot=0
collectDropsNearby(W,inv,state,0.9)
assert(not rejected.frame.destroyed and rejected.n==1,"zero ACK must not erase a potentially real item")
local noReply=drop(6,1)
W.drops={noReply}; serverGot=nil
collectDropsNearby(W,inv,state,0.9)
assert(not noReply.frame.destroyed and not dropIgnored(W,noReply),
    "timeout cannot delete a drop or count as proof of a visual ghost")
before=rpcCount
collectDropsNearby(W,inv,state,0.9)
assert(rpcCount==before,"timeout backs off instead of repeating immediately")
print("PASS zero/timeout safety and retry backoff")

local old=drop(7,3)
W.drops={old}; serverGot=3; serverDelay=4
collectDropsNearby(W,inv,state,0.9)
local oldCount=inv.n
W.name="OTHER"; W.fg={}; W.drops={drop(8,1)}
syncDropMemory(W,W.drops)
task.wait(4)
assert(inv.n==oldCount and not old.frame.destroyed and not old.taking,
    "old-world ACK cannot mutate inventory or visuals for the next world")
print("PASS world-change cancellation of local reconciliation")

serverDelay=0; before=rpcCount
local gem=drop(9,1); gem.id=112
local display=drop(10,1); display.display=true
local pending=drop(11,1); pending.pending=true
W.drops={gem,display,pending}
collectDropsNearby(W,inv,state,0.9)
assert(rpcCount==before,"gems use native collector; display/pending drops are not pickup requests")
print("PASS native gems and non-collectible records")

Factory.running=true; Factory.cycle=true; Factory.phase="pnb"
W.drops={}; inv.n=200; serverGot=1; serverDelay=0
local original=W.takeDrop
Factory.setPickupGate(W,true)
before=rpcCount
for i=1,200 do
    inv.n-=1
    local block=drop(30000+i,1); table.insert(W.drops,block)
    local taken=W.takeDrop(block.uid,block.n) -- native auto pickup
    inv.n+=taken
    assert(inv.n==200-i,"native collector must not refill the PNB inventory")
end
assert(inv.n==0 and rpcCount==before,"200 to zero cannot send collect packets during PNB")
local held=W.drops[1]
syncDropMemory(W,W.drops)
assert(collectDropsNearby(W,inv,state,0.9)==0 and not dropIgnored(W,held),
    "a held real block is not classified as a visual failure")
local seed=drop(31001,1); seed.id=955; table.insert(W.drops,seed)
local gem2=drop(31002,1); gem2.id=112; table.insert(W.drops,gem2)
assert(W.takeDrop(seed.uid,1)==1 and W.takeDrop(gem2.uid,1)==1,
    "PNB gate allows native seed and gem pickup")
Factory.phase="collect"; Factory.setPickupGate(W,false)
assert(W.takeDrop==original and W.takeDrop(held.uid,1)==1,
    "leaving PNB restores normal collect and its original function")
Factory.phase="pnb"; Factory.setPickupGate(W,true)
Factory.running=false; Factory.setPickupGate(nil,false)
assert(W.takeDrop==original,"Stop restores the original native collector")
print("PASS native PNB 200-to-zero, script hold, seeds/gems, collect resume and Stop cleanup")
'''

with tempfile.TemporaryDirectory(prefix="humanhub-collect-protocol-") as directory:
    path = Path(directory) / "collect.luau"
    path.write_text("\n".join([prelude,functions,checks]), encoding="utf-8")
    result = subprocess.run([sys.argv[1],str(path)], capture_output=True,text=True,encoding="utf-8")
    print(result.stdout,end="")
    if result.returncode:
        print(result.stderr,file=sys.stderr)
        raise SystemExit(result.returncode)
