"""Check old/direct and v1945 context bindings without executing game actions.

Usage: python tests/test_bindings.py <luau.exe>
"""
from pathlib import Path
import subprocess
import sys
import tempfile

source=(Path(__file__).resolve().parents[1]/"hub.luau").read_text(encoding="utf-8-sig")
def extract(a,b):
    start=source.index(a)
    return source[start:source.index(b,start)]

prelude=r'''
local clock=0
local os={clock=function() return clock end}
local Factory={}
local function log(_) end
local world={name="FARM",w=100,h=60,fg={},bg={},goTo=function() end}
local foreign={name="OTHER"}
local controller={state=function() end,solidAt=function() end,onHurt=function() end,onDie=function() end}
local function inventory()
    return {slots={},count=function() return 20 end,room=function() return 180 end,
        select=function() end,remove=function() end}
end
local correctInv,decoyInv=inventory(),inventory()
local function itemDB(grow)
    return {[2]={name="Dirt"},[3]={name="Dirt Seed",kind="seed"},[14]={background=true},
        [4585]={name="Pepper Tree Seed",kind="seed",grow=grow}}
end
local catalog,liveDB=itemDB(105233),itemDB(63140)
local trees={[3]={p=1}}
local ctx={world=world,inv=correctInv,Items=liveDB,trees=trees}
local hit,place,splice=function() end,function() end,function() end
local wrongHit=function() end
local ups={[hit]={ctx},[place]={ctx},[splice]={ctx},[wrongHit]={{world=foreign}}}
local functions={hit={wrongHit,hit},setTile={place},spliceAt={splice}}
local debug={}
function debug.getinfo(fn) return {nups=#ups[fn]} end
function debug.getupvalue(fn,i) return ups[fn][i] end
function debug.getupvalues(fn) return ups[fn] end
local function filtergc(kind,query)
    if kind=="function" then return functions[query.Name] or {} end
    local key=query.Keys[1]
    if key=="fg" then return {world} end
    if key=="state" then return {controller} end
    if key=="slots" then return {{slots=5},decoyInv,correctInv} end
    if type(key)=="number" then return {{[key]=false},catalog} end
    return {}
end
'''
checks=r'''
assert(Bind.resolve(true),"context binding must resolve hit and place")
assert(Bind.hit==hit and Bind.setTile==place and Bind.context==ctx,
    "context functions match their exact world rather than an unrelated hit function")
assert(Bind.inv==correctInv,"inventory must come from the same game context")
assert(findItemDB()==liveDB and selectedItemDefinition(4585).grow==63140,
    "world growth data cannot fall back to slower catalog values")
assert(factoryEnsureTreeMap(world)==trees,"harvest tree map comes from the same live context")
local replacement=itemDB(60000)
ctx.Items=replacement; ctx.trees={}
assert(findItemDB()==replacement and factoryEnsureTreeMap(world)==ctx.trees,
    "new world data replaces cached context tables even when function identity is unchanged")
print("PASS v1945 context actions, matching inventory, live ItemDB and tree-map replacement")
ctx.inv=nil
assert(not Bind.resolve(true) and Bind.inv==nil,
    "a loading game inventory cannot bind a decoy inventory from GC")
ctx.inv=correctInv
assert(Bind.resolve(true) and Bind.inv==correctInv,"context inventory can recover once ready")

-- Historical builds captured world/Items/trees directly in each closure.
hit,place,splice=function() end,function() end,function() end
functions.hit={wrongHit,hit}; functions.setTile={place}; functions.spliceAt={splice}
ups[hit]={world,liveDB}; ups[place]={world}; ups[splice]={world,trees}
Bind.invalidate(); clock+=2; Factory.treeMap=nil; Factory.treeMapWorld=nil
assert(Bind.resolve(true) and Bind.context==nil,"direct-world binding remains supported")
assert(Bind.hit==hit and Bind.setTile==place and Bind.inv==decoyInv,
    "legacy inventory discovery remains available without context")
assert(findItemDB()==liveDB and factoryEnsureTreeMap(world)==trees,"legacy data discovery remains supported")
print("PASS historical direct-world bindings and data discovery")

functions.hit={wrongHit}; functions.setTile={}
Bind.invalidate(); clock+=2
assert(not Bind.resolve(true) and Bind.hit==nil and Bind.setTile==nil,
    "foreign-world functions cannot make an incomplete binding look ready")
print("PASS foreign-world rejection and incomplete-binding result")
'''
program="\n".join([prelude,
    extract("local Bind =","function Bind.getW("),
    extract("local itemDBCache","local function centerOnTile("),
    extract("local function factoryEnsureTreeMap(","local function factoryTreeRipe("),checks])
with tempfile.TemporaryDirectory(prefix="humanhub-bindings-") as directory:
    path=Path(directory)/"bindings.luau"
    path.write_text(program,encoding="utf-8")
    result=subprocess.run([sys.argv[1],str(path)],capture_output=True,text=True,encoding="utf-8")
    print(result.stdout,end="")
    if result.returncode:
        print(result.stderr,file=sys.stderr)
        raise SystemExit(result.returncode)
