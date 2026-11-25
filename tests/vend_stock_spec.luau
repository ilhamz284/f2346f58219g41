local passed=0
local function setup(o)
    o=o or {}
    local clock,queue,calls=10,{},{}
    local inv={counts={[13]=o.count or 9}}
    function inv:count(id)return self.counts[id] or 0 end
    local items={[13]={kind='seed',name='Door Seed'},[17]={kind='seed',name='Glass Pane Seed'},[999]={kind='currency',name='World Lock'},[2978]={vend=true},[9268]={vend=true},[123]={gemMachine=true,vend=true}}
    local state={active=true,dead=false}
    local vend={id=13,stock=o.stock or 40,cost=1,per=40}
    local world={name='OWN',entering=1,fg={[5]={[4]=o.tile or 2978}}}
    local context={world=world,inv=inv,Items=items,px=4.5,py=6}
    world.vends={get=function(x,y)return x==4 and y==5 and vend or nil end}
    world.atTile=function(x,y)return math.abs(context.px-x-.5)<=.85 and math.abs(context.py-y-1)<=.6 end
    world.vendOwner=function()return not o.foreign end
    world.vendCall=function(action,x,y,id,n)
        assert(action=='stock' and x==4 and y==5 and id==vend.id)
        assert(n>0 and n<=inv:count(id))
        calls[#calls+1]={action,x,y,id,n}
        if o.reject then return false end
        inv.counts[id]=inv:count(id)-n;vend.stock+=n
        return true,{remove={{id,n}}}
    end
    local Hub={dead=false,recovery={read=function()return o.saved end},ssp={},onUnload=function(fn)o.unload=fn end}
    local Bind={W=world,inv=inv,context=context,resolve=function()end,state=function()return state end}
    local stock
    local env={Hub=Hub,Bind=Bind,Farm={},PNB={},Factory={},Surgery={},worldPickerVisible=function()return o.lobby end,
        os={clock=function()return clock end},task={spawn=function(fn)queue[#queue+1]=fn end,wait=function(n)
            clock+=n or .05
            if o.onWait then o.onWait() end
            if not o.defer then local fn=table.remove(queue,1);if fn then fn()end end
        end}}
    stock=make(env);stock.running=true
    return {stock=stock,env=env,inv=inv,vend=vend,world=world,state=state,context=context,Hub=Hub,calls=calls,o=o,
        flush=function()while #queue>0 do table.remove(queue,1)()end end,advance=function(n)clock+=n end}
end
local function test(name,fn)fn();passed+=1;print('PASS '..name)end

test('walking past native reach adds all matching backpack seeds without dialogs',function()
    local t=setup();t.stock.step();assert(#t.calls==1 and t.calls[1][5]==9 and t.vend.stock==49 and t.inv:count(13)==0 and t.stock.stocked==9)
    assert(t.vend.cost==1 and t.vend.per==40)
end)
test('standard vend capacity limits transfer and preserves remainder',function()
    local t=setup({count=200,stock=5190});t.stock.step();assert(t.calls[1][5]==9 and t.vend.stock==5199 and t.inv:count(13)==191)
end)
test('DigiVend uses 10398 capacity',function()
    local t=setup({count=200,stock=10390,tile=9268});t.stock.step();assert(t.calls[1][5]==8 and t.vend.stock==10398)
end)
test('zero-stock vend with known item can be refilled',function()
    local t=setup({stock=0});t.stock.step();assert(#t.calls==1 and t.vend.stock==9)
end)
test('unconfigured, full, wrong-item and currency machines are skipped',function()
    for _,edit in ipairs({function(t)t.vend.id=nil end,function(t)t.vend.stock=5199 end,function(t)t.vend.id=17 end,function(t)t.vend.id=999;t.inv.counts[999]=20 end,function(t)t.vend.stock=-1 end})do
        local t=setup();edit(t);t.stock.step();assert(#t.calls==0)
    end
end)
test('foreign worlds, far machines, gem machines and non-vend tiles are skipped',function()
    for _,edit in ipairs({function(t)t.o.foreign=true end,function(t)t.context.px=5.4 end,function(t)t.world.fg[5][4]=123 end,function(t)t.world.fg[5][4]=0 end})do
        local t=setup();edit(t);t.stock.step();assert(#t.calls==0)
    end
end)
test('lobby, inactive, dead, replaced inventory and context pause the worker',function()
    for _,edit in ipairs({function(t)t.o.lobby=true end,function(t)t.state.active=false end,function(t)t.state.dead=true end,function(t)t.env.Bind.inv={}end,function(t)t.context.world={}end})do
        local t=setup();edit(t);t.stock.step();assert(#t.calls==0)
    end
end)
test('farming, surgery, SSP and recovery pause stock actions',function()
    for _,edit in ipairs({function(t)t.env.Farm.running=true end,function(t)t.env.PNB.running=true end,function(t)t.env.Factory.running=true end,function(t)t.env.Surgery.running=true end,function(t)t.Hub.ssp.running=true end,function(t)t.o.saved={world='OWN'}end})do
        local t=setup();edit(t);t.stock.step();assert(#t.calls==0)
    end
end)
test('scheduled request rechecks movement, ownership, item and world identity',function()
    for _,edit in ipairs({function(t)t.context.px=10 end,function(t)t.o.foreign=true end,function(t)t.vend.id=17 end,function(t)t.world.name='OTHER'end,function(t)t.world.entering=2 end,function(t)t.stock.stop()end})do
        local t=setup();local first=true;t.o.onWait=function()if first then first=false;edit(t)end end
        t.stock.step();assert(#t.calls==0 and not t.stock.pending and not t.world.__HumanHubVendPending)
    end
end)
test('count is rechecked immediately before sending',function()
    local t=setup();local first=true;t.o.onWait=function()if first then first=false;t.inv.counts[13]=3 end end
    t.stock.step();assert(t.calls[1][5]==3 and t.inv:count(13)==0 and t.stock.stocked==3)
end)
test('rejected stock backs off without modifying inventory',function()
    local t=setup({reject=true});t.stock.step();t.stock.step();assert(#t.calls==1 and t.inv:count(13)==9)
    t.advance(5);t.stock.step();assert(#t.calls==2)
end)
test('timeout and reload cannot overlap an unfinished native request',function()
    local t=setup({defer=true});t.stock.step();assert(not t.stock.running and t.stock.pending and not t.stock.start())
    local replacement=make(t.env);replacement.running=true;replacement.step();assert(#t.calls==0)
    t.flush();assert(#t.calls==0 and not t.world.__HumanHubVendPending)
    t.o.defer=false;replacement.step();assert(#t.calls==1)
end)
test('native inventory reply is applied once and inconsistent result stops',function()
    local t=setup();t.world.vendCall=function()return true end;t.stock.step();assert(not t.stock.running and t.inv:count(13)==9)
end)
test('world transfer resumes against fresh matching context only',function()
    local t=setup();t.o.lobby=true;t.stock.step();assert(t.stock.running and #t.calls==0)
    t.o.lobby=false;t.world.entering=2;t.stock.step();assert(#t.calls==1)
end)
test('actual toggle starts once, silent status does not restart, unload stops',function()
    local t=setup();t.stock.running=false;local toggleConfig
    local toggle={Value=false};function toggle:Set(on,fire)self.Value=on;if fire~=false then toggleConfig.Callback(on)end end
    local section={Paragraph=function()return {SetDesc=function()end}end,Toggle=function(_,c)toggleConfig=c;return toggle end}
    makeUI(t.Hub,section);toggleConfig.Callback(true);assert(t.stock.running)
    t.stock.stop('done');assert(toggle.Value==false and not t.stock.running)
    t.o.unload();assert(not t.stock.running)
end)
print(passed..' cases passed')
