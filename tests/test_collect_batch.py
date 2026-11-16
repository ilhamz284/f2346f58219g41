"""Exercise actual factory collection of many small stacks with delayed ACKs.

Usage: python tests/test_collect_batch.py <luau.exe> [baseline-git-revision]
The comparison models network and movement time; it is not a live benchmark.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "hub.luau").read_text(encoding="utf-8-sig")

prelude = r'''
local clock,active,onWait=0,true,nil
local os={clock=function() return clock end}
local scheduled={}
local task={}
local function resume(co)
    local ok,delay=coroutine.resume(co); assert(ok,delay)
    if coroutine.status(co)~="dead" then table.insert(scheduled,{co=co,at=clock+(delay or 0)}) end
end
function task.spawn(fn) resume(coroutine.create(fn)) end
function task.wait(dt)
    clock+=dt or 0.016
    for i=#scheduled,1,-1 do
        if scheduled[i].at<=clock then local job=table.remove(scheduled,i); resume(job.co) end
    end
    if onWait then onWait() end
end
local W={name="TEST",w=100,fg={},drops={}}
local state={x=10.5,y=5,grounded=true}
local Factory={baseId=954,seedId=955,ignoredDrops={},dropTakeFailures={}}
local Bind={name="TEST",state=function() return state end}
local inv={blocks=0,seeds=0}
function inv.room(_,id) return 200-(id==955 and inv.seeds or inv.blocks) end
function inv.count(_,id) return id==955 and inv.seeds or inv.blocks end
function inv.add(_,id,n) if id==955 then inv.seeds+=n else inv.blocks+=n end end
local function standingFloor(s) return math.floor(s.y-0.0001)+1 end
local function keyOf(x,y) return y*1000+x end
local function edgeBlocked() return false end
local function factoryAlive() return active end
local Move={gen=0}
local paths,plans,walks,requests=0,0,0,{}
local Path={}
function Move.release() end
function Move.walkTo(x)
    walks+=1; clock+=0.02; state.x=x; return true
end
local gap=nil
function Path.standable(x,y) return x>=0 and x<100 and (y==4 or y==7) and x~=gap end
function Path.explore()
    plans+=1; clock+=0.04
    local d={}
    for x=0,99 do for y=1,10 do d[keyOf(x,y)]=math.abs(x-state.x+0.5)+math.abs(y-4)*3 end end
    return d
end
function Path.moveTo(x,y)
    paths+=1; clock+=0.08; state.x=x+0.5; state.y=y+1; return true
end
function W.dropList() return W.drops end
local rpcDelay=0.12
function W.takeDrop(uid,n)
    table.insert(requests,{uid=uid,n=n,t=clock})
    if rpcDelay>0 then coroutine.yield(rpcDelay) end
    return math.min(n,inv:room(954))
end
local function setter(drop,n)
    drop.n=n
    if n<=0 then
        local index=table.find(W.drops,drop)
        if index then table.remove(W.drops,index) end
        drop.frame:Destroy()
    end
end
local debug={getupvalues=function() return {W.drops} end}
local function filtergc() return {setter} end
local function makeDrop(uid,n,x,y)
    local frame={destroyed=false}
    function frame:Destroy() self.destroyed=true end
    return {uid=uid,id=954,n=n,x=x or 10.5,y=y or 4.5,frame=frame}
end
local function reset(n)
	-- An already-sent RPC finishes even if the caller presses Stop.
	onWait=nil
	if #scheduled>0 then task.wait(5) end
    W.drops={}; W.fg={}; inv.blocks=0; inv.seeds=0
    clock=0; active=true; onWait=nil; paths=0; plans=0; walks=0; requests={}; scheduled={}
    state={x=10.5,y=5,grounded=true}; gap=nil; Factory.dropFilter=nil
    for i=1,n do W.drops[i]=makeDrop(i,2) end
end
'''

checks = r'''
reset(20)
local result,n=factoryCollectDrop(W,inv,state,{},1)
assert(result=="collected" and n>2 and n<=24 and #requests<=12,
    "one visit must collect several two-block stacks within the bounded batch")
assert(paths==0 and plans==0 and walks==0,"underfoot collection needs no movement or world path search")
for i=2,#requests do assert(requests[i].t-requests[i-1].t>=0.08-1e-6,"requests stay serial and spaced") end
assert(clock<1.7,"batch yields control after its time budget")
print("PASS bounded multi-stack batch, no redundant movement, request pacing")

reset(20)
onWait=function() if #requests>=1 then active=false; Move.gen+=1 end end
factoryCollectDrop(W,inv,state,{},1)
assert(#requests==1,"Stop cannot issue the next request in the batch")
reset(20)
onWait=function() if inv.blocks>0 then inv.seeds=200 end end
factoryCollectDrop(W,inv,state,{},1)
assert(#requests==1,"seed capacity interrupts collection for planting")
reset(5); inv.blocks=198
factoryCollectDrop(W,inv,state,{},1)
assert(inv.blocks==200 and #requests==1,"full block stack stops the batch immediately")
print("PASS Stop and inventory boundaries")

reset(5); rpcDelay=0.8
result=factoryCollectDrop(W,inv,state,{},1)
assert(result=="pending" and #requests==1 and clock<0.4)
factoryCollectDrop(W,inv,state,{},1)
assert(#requests==1,"slow ACK cannot start another batch request")
task.wait(1); rpcDelay=0.12
assert(inv.blocks==2,"late ACK is still reconciled")
print("PASS slow ACK keeps one outstanding request")

reset(3)
Factory.dropFilter={[1]=true,[3]=true}
factoryCollectDrop(W,inv,state,{},1)
assert(inv.blocks==4 and #requests==2 and requests[1].uid==1 and requests[2].uid==3,
    "batch respects the old-drop filter from PNB")
reset(1); W.drops[1].x=15.5
assert(factoryCollectDrop(W,inv,state,{},1)=="collected" and plans==0 and paths==0 and walks==1,
    "same-floor drop uses a checked walk corridor")
reset(1); W.drops[1].y=7.5
assert(factoryCollectDrop(W,inv,state,{},1)=="collected" and plans==1 and paths==1,
    "cross-floor drop retains world pathfinding")
print("PASS old-drop filter, corridor and cross-floor fallback")
'''

benchmark = r'''
reset(100)
local calls=0
for i=1,400 do
    if inv.blocks>=200 then break end
    local result=factoryCollectDrop(W,inv,state,{},1)
    calls+=1
    task.wait(result=="collected" and 0.15 or 0.2)
end
assert(inv.blocks==200 and #requests==100 and #W.drops==0,"all 100 two-block stacks must be collected")
print(string.format("BATCH_RESULT %.3f %d %d %d %d",clock,calls,plans,paths,walks))
'''


def run(text, regression):
    def extract(a, b):
        start = text.index(a)
        return text[start:text.index(b, start)]
    program = "\n".join([
        prelude,
        extract("local DropMemory =", "local function collectDropsAtTile("),
        extract("local function factoryCount(", "local function factoryWorkSpot("),
        extract("local function factoryRoom(", "local function factoryHasPlantTile("),
        checks if regression else "",
        benchmark,
    ])
    with tempfile.TemporaryDirectory(prefix="humanhub-collect-batch-") as directory:
        path = Path(directory) / "batch.luau"
        path.write_text(program, encoding="utf-8")
        result = subprocess.run([sys.argv[1],str(path)], capture_output=True,text=True,encoding="utf-8")
        print(result.stdout,end="")
        if result.returncode:
            print(result.stderr,file=sys.stderr)
            raise SystemExit(result.returncode)
        return result.stdout.split("BATCH_RESULT ")[1].splitlines()[0]


current = run(source, True)
if len(sys.argv)>2:
    old_source = subprocess.run(["git","show",f"{sys.argv[2]}:hub.luau"],cwd=root,
                                capture_output=True,text=True,encoding="utf-8",check=True).stdout
    old = run(old_source,False)
    assert float(current.split()[0])<float(old.split()[0])
    print(f"SIMULATED seconds/calls/plans/paths/walks: {old} -> {current}; not a live benchmark")
