"""Run actual Factory phases, seed collection and Display Box storage with mocked game actions."""
from pathlib import Path
import subprocess
import sys
import tempfile

source = (Path(__file__).resolve().parents[1] / "hub.luau").read_text(encoding="utf-8-sig")


def extract(start, end):
    offset = source.index(start)
    return source[offset:source.index(end, offset)]


prelude = r'''
local clock, trees, ripe, requests, picked, options, onWait = 0, 0, true, 0, 0, {}, nil
local os={clock=function() return clock end,time=function() return 1000+clock end}
local task={wait=function(seconds) clock+=seconds or 0.02; if onWait then onWait() end end}
local W={name="TEST",box=0,drops={}}
function W.dropList() return W.drops end
W.displays={get=function() return {{955,W.box}} end}
local state={x=4.5,y=5,grounded=true}
local inv={blocks=0,seeds=0}
function inv:count(id) return id==955 and self.seeds or self.blocks end
function inv:room(id) return 200-self:count(id) end
local Factory={}
local Bind={name=W.name,state=function() return state end}
local Move={release=function() end}
local Path={moveTo=function() return true end}
local function factoryAlive() return Factory.running end
local function factoryCount(_,id) return id and inv:count(id) or 0 end
local function factoryRoom(_,id) return inv:room(id) end
local function dropIgnored() return false end
local function syncDropMemory() end
local function setFactoryStatus(text) Factory.status=text end
local function selectedItemDefinition() return {grow=1,name="Selected Seed"} end
local function factoryGrowDesc() return "growing" end
local function factoryHasTrees() return trees>0 end
local function factoryHasRipeTree() return trees>0 and ripe end
local function factoryHasPlantTile() return not options.noPlantSpace end
local function collectDropsNearby() return 0 end
local function factoryWorkSpot() return 4,4,4 end
local function factoryHarvestCapacity()
    if inv.seeds>=200 then return "seed" end
    if inv.blocks>=200 then return "block" end
end
local function factoryTarget(_,_,_,_,kind)
    if kind=="harvest" and trees>0 and ripe then return {kind=kind,x=5,y=4} end
    if kind=="plant" then return {kind=kind,x=5,y=4} end
end
local function factoryWork(_,_,target)
    if target.kind=="plant" then
        assert(not Factory.clearTree,"Clear Tree called a plant action")
        inv.seeds-=1;Factory.planted+=1
    else
        trees-=1;inv.blocks+=1;inv.seeds+=1;Factory.harvested+=1
    end
    return true
end
local function factoryPNBOne()
    assert(inv.blocks>0 and inv.seeds<200)
    inv.blocks-=1;inv.seeds+=1;Factory.pnb+=1
    return true
end
local function factoryDisplaySpots()
    return options.missingBox and {} or {{x=9,y=4,sx=8,sy=4}}
end
local function displayDropPoint() return 8.75 end
function W.displayPut(_,_,id,n)
    assert(id==955);requests+=1
    if options.reject then return false end
    if options.delayed then return end
    local stored=math.min(n,options.partial or n)
    W.box+=stored;inv.seeds-=stored
end
local function reset(phase,blocks,seeds,count,settings)
    clock=0;trees=count or 0;ripe=true;requests=0;picked=0;options=settings or {};onWait=nil
    inv.blocks=blocks or 0;inv.seeds=seeds or 0;W.box=0;W.drops={}
    table.clear(Factory)
    Factory.stop=function(message) Factory.running=false;Factory.status=message end
    Factory.running=true;Factory.cycle=true;Factory.clearTree=true;Factory.phase=phase
    Factory.baseId=954;Factory.seedId=955;Factory.seedGrow=1;Factory.seedName="Seed"
    Factory.planted=0;Factory.harvested=0;Factory.pnb=0;Factory.pnbDrainCount=0
    Factory.pnbPathFailures=0;Factory.harvestPathRetryAt={}
end
'''
collector = r'''
local function factoryCollectDrop(_,_,_,_,_,itemId)
    local id=itemId or Factory.baseId
    local drops=factoryBaseDrops(W,id,true)
    local drop=drops[1]
    if not drop then return "done",0 end
    assert(not drop.display,"Display Box contents must stay stored")
    local taken=math.min(drop.n,inv:room(id))
    if taken<=0 then return "room",drop.n end
    if id==955 then inv.seeds+=taken;picked+=taken else inv.blocks+=taken end
    drop.n-=taken
    return "collected",taken
end
'''
checks = r'''
local blocked={}
local function step() local delay=factoryCycleStep(W,inv,state,955,blocked,1);clock+=delay or 0.1 end
local function finish()
    for i=1,2000 do if not Factory.running then return end;step() end
    error("factory did not finish: "..tostring(Factory.status))
end
reset("harvest",0,0,8)
W.drops={{uid=1,id=955,n=42,x=1,y=4},{uid=2,id=955,n=99,x=9,y=4,display=true}}
finish()
assert(Factory.harvested==8 and Factory.pnb==8 and Factory.planted==0)
assert(W.box==58 and inv.seeds==0 and picked==42 and W.drops[2].n==99)
print("PASS harvest -> PNB -> Display Box, loose seeds, selected-item filtering and completion")

reset("pnb",10,200)
step();assert(Factory.phase=="store" and inv.blocks==10)
step();assert(W.box==200 and inv.seeds==0)
finish();assert(W.box==210 and Factory.pnb==10 and Factory.planted==0)
print("PASS full seed stack deposits before continuing remaining PNB")

reset("plant",0,13,0,{missingBox=true})
step();assert(Factory.phase=="store" and inv.seeds==13 and Factory.planted==0)
local retry=Factory.storeRetryAt
step();assert(Factory.storeRetryAt==retry and Factory.running and requests==0)
clock=retry;options.missingBox=false;step();finish()
assert(W.box==13 and inv.seeds==0)
reset("store",0,17,0,{reject=true})
step();assert(inv.seeds==17 and W.box==0 and requests==1 and Factory.running)
step();assert(requests==1 and Factory.planted==0)
print("PASS unavailable/rejected Display Box retains seeds and retries without planting")

reset("store",0,40,0,{partial=10});step()
assert(W.box==40 and inv.seeds==0 and requests==4)
reset("store",0,20,0,{partial=5})
onWait=function() if requests>0 then Factory.clearTree=false end end
step();onWait=nil
assert(requests==1 and W.box==5 and inv.seeds==15)
step();assert(Factory.phase=="plant" and Factory.planted==1)
print("PASS partial deposits and live toggle-off cancellation restore normal planting")

reset("store",0,20,0,{delayed=true})
onWait=function()
    Factory.clearTree=false
    if clock>=0.6 and W.box==0 then W.box=7;inv.seeds-=7 end
end
step();onWait=nil
assert(clock>=0.6 and requests==1 and W.box==7 and inv.seeds==13)
print("PASS disabling storage waits for its in-flight acknowledgement before planting can resume")

reset("pnb",3,20);Factory.pnbSkipUntil=100;trees=0
step();assert(Factory.planted==0 and inv.seeds==20 and requests==0)
reset("grow",0,0);ripe=false;trees=1
step();assert(Factory.running and Factory.phase=="grow" and Factory.planted==0)
print("PASS PNB cooldown has no plant fallback and immature trees keep the factory waiting")

reset("grow",0,0)
Factory.seedRefillAt=clock+3
W.drops={{uid=3,id=955,n=7,x=1,y=4}}
finish();assert(W.box==7 and picked==7 and Factory.planted==0)
reset("store",0,18,0,{partial=5})
onWait=function() Factory.running=false end
step();assert(requests==1 and inv.seeds==13)
print("PASS late seed drops survive refill cooldown and Stop prevents later deposits")
'''
ui_prelude = r'''
do
local Factory={running=true,cycle=true,harvest=false,plant=false,clearTree=false,phase="plant",storeFail="old error",storeRetryAt=99}
local saved={mode="factory",world="TEST",phase="plant",guardCheck=true}
local modeCalls=0
local Hub={recovery={read=function() return table.clone(saved) end,
    write=function(value) saved=table.clone(value) end}}
local factorySec={}
function factorySec:Toggle(config)
    local control={Value=config.Value,Callback=config.Callback}
    function control:Set(value,fire)
        self.Value=value
        if fire~=false then self.Callback(value) end
    end
    return control
end
function Factory.setMode() modeCalls+=1 end
'''
ui_checks = r'''
clearTreeToggle:Set(true)
assert(Factory.clearTree and Factory.phase=="store" and saved.clearTree and saved.phase=="store")
assert(Factory.storeRetryAt==nil and Factory.storeFail==nil and modeCalls==0)
clearTreeToggle:Set(false)
assert(not Factory.clearTree and Factory.phase=="plant" and not saved.clearTree and saved.phase=="plant")
Factory.running=false;Factory.cycle=false;saved.phase="pnb"
clearTreeToggle:Set(true)
assert(not Factory.running and saved.clearTree and saved.phase=="pnb","configure a pending resume without starting a worker")
Factory.clearTree=false;Factory.onMode()
assert(clearTreeToggle.Value==false and saved.clearTree and modeCalls==0,"silent UI sync must not overwrite persisted settings")
print("PASS actual toggle callbacks, plant/store switching, pending recovery configuration and silent UI sync")
end
'''
checkpoint_prelude = r'''
do
local Factory={cycle=true,phase="harvest",resumePNB=false,resumeCollect=false,clearTree=false}
local saved,writes=nil,0
local Hub={recovery={write=function(value) saved=value;writes+=1;return true end,arm=function() end}}
local worldName,seedId="TEST",955
'''
checkpoint_checks = r'''
checkpoint();assert(writes==1 and saved.clearTree==false)
Factory.clearTree=true;checkpoint();assert(writes==2 and saved.clearTree==true)
checkpoint();assert(writes==2,"unchanged mode does not write each tick")
Factory.phase="store";checkpoint();assert(writes==3 and saved.phase=="store")
print("PASS checkpoint tracks Clear Tree changes immediately and saves the storage phase")
end
'''
program = "\n".join([
    prelude,
    extract("local function factoryBaseDrops(", "-- Sesudah target utama"),
    collector,
    extract("local factoryStoreSeeds\n", "-- Kosongkan seluruh blok"),
    extract("local PNB_DRAIN_BATCH =", "local function startFactory("),
    extract("local function seedCountInDisplay(", "-- Cari id item Display Box"),
    extract("factoryStoreSeeds = function(", "Factory.storeSeeds = factoryStoreSeeds"),
    checks,
    ui_prelude,
    extract("local harvestToggle, plantToggle, cycleToggle", "-- Pecah scan UI panjang"),
    extract("Factory.onMode = function()", "-- ---- Quest harian:"),
    ui_checks,
    checkpoint_prelude,
    extract("local nextCheckpoint, lastPhase,", "\n\tcheckpoint()\n\tsetFactoryStatus("),
    checkpoint_checks,
])
with tempfile.TemporaryDirectory(prefix="humanhub-clear-tree-") as directory:
    path = Path(directory) / "clear_tree.luau"
    path.write_text(program, encoding="utf-8")
    result = subprocess.run([sys.argv[1], str(path)], capture_output=True, text=True)
    print(result.stdout, end="")
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        raise SystemExit(result.returncode)
