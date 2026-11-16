"""Test UI search budgets, retries, cached labels, and layout coalescing.

Usage: python tests/test_status_ui.py <path-to-luau.exe>
"""
from pathlib import Path
import subprocess
import sys
import tempfile

source = (Path(__file__).resolve().parents[1] / "hub.luau").read_text(encoding="utf-8-sig")


def extract(start, end):
    return source[source.index(start):source.index(end, source.index(start))]


prelude = r'''
local clock,cost,calls,yields,lastYield,worst=0,0,0,0,0,0
local Hub={dead=false}
local Factory={status="idle"}
local _G={__HumanHub=Hub}
local os={clock=function() return clock end}
local workers={}
local mainThread=coroutine.running()
local onYield
local task={}
function task.spawn(fn) table.insert(workers,coroutine.create(fn)) end
function task.wait(dt)
    if coroutine.running()~=mainThread then
        clock+=dt or 0.016
        coroutine.yield()
    else
        yields+=1; worst=math.max(worst,clock-lastYield)
        clock+=dt or 0.016; lastYield=clock
        if onYield then onYield() end
    end
end
local function node(name,children,kind,text)
    local n={Name=name,children=children or {},kind=kind or "Frame",Text=text}
    function n:GetChildren() calls+=1; clock+=cost; return self.children end
    function n:IsA(k) return self.kind==k end
    for _,child in ipairs(n.children) do child.Parent=n end
    return n
end
local root=node("Root")
local function gethui() return root end
local layouts=0
local factoryStatusPara={SetDesc=function() layouts+=1 end}
'''

search_tests = r'''
cost=0.00005
local nested=node("Leaf")
for i=1,10000 do nested=node("Container",{nested}) end
assert(Hub.findParagraphLabel(nested,"Missing")==nil)
assert(yields>0 and worst<0.005,"large UI search yields within a small frame budget")
calls=0; onYield=function() Hub.dead=true end
assert(Hub.findParagraphLabel(nested,"Missing")==nil and calls<10000,"unload cancels UI scan")
Hub.dead=false; onYield=nil; cost=0; clock=0; calls=0
local title=node("Title",{},"TextLabel","Status Harvest/Plant")
local body=node("Description",{},"TextLabel","idle")
local panel=node("TitleFrame",{title,body})
assert(Hub.findParagraphLabel(panel,"Status Harvest/Plant")==body,"correct status body selected")
root=node("Root")
calls=0
print("PASS large UI yields, unload cancellation, paragraph matching")
'''

worker_tests = r'''
assert(#workers==1)
local initial=calls
for i=1,12 do assert(coroutine.resume(workers[1])) end
assert(calls==initial,"missing label does not trigger a UI scan every tick")
root.children={panel}; panel.Parent=root
for i=1,10 do assert(coroutine.resume(workers[1])) end
assert(Factory.statusLabel==body,"label discovered after retry interval")
local cachedCalls=calls
Factory.status="Factory: PNB 123"
for i=1,5 do assert(coroutine.resume(workers[1])) end
assert(body.Text==Factory.status and calls==cachedCalls,"cached label updates without rescanning")
for i=1,100 do Factory.onStatus("Factory: PNB "..i) end
assert(layouts==0,"known label avoids repeated library layout calls")
Factory.statusLabel=nil; clock=100
for i=1,100 do Factory.onStatus("Factory: PNB "..i) end
assert(layouts==1,"fallback layout calls coalesced to one per second")
clock+=1.01; Factory.onStatus("new status")
assert(layouts==2,"fallback remains responsive after its cooldown")
_G.__HumanHub=nil
assert(coroutine.resume(workers[1]))
assert(coroutine.status(workers[1])=="dead","worker ends after unload")
print("PASS missing-label backoff, cached status, no layout storm, fallback, worker cleanup")
'''

finder = source.index("\tlocal function findStatusLabel(inst)")
start = source.rfind("\ndo\n", 0, finder)
end = source.index("\nFactory.onMode = function()", finder)
program = "\n".join([
    prelude,
    extract("function Hub.findParagraphLabel(", "local factoryStatusPara ="),
    extract("local nextFactoryLayoutAt =", "-- Status juga ditulis"),
    search_tests,
    source[start:end],
    worker_tests,
])
with tempfile.TemporaryDirectory(prefix="humanhub-status-ui-") as directory:
    path = Path(directory) / "status.luau"
    path.write_text(program, encoding="utf-8")
    subprocess.run([sys.argv[1], str(path)], check=True)
