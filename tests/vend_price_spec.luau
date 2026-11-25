local passed=0
local function setup(o)
    o=o or {};o.raw=o.raw or 'file-v1'
    o.data=o.data or {format='ssp-vend-prices-v1',prices={{name='Sidewalk Seed',cost=1,per=45}}}
    local clock,queue,calls=20,{},{}
    local inv={count=function()return 9 end}
    local vend={id=995,stock=34,cost=o.cost or 1,per=o.per or 40,earned=123}
    local world={name='OWN',entering=1,fg={[49]={[74]=2978}}}
    local state={active=true,dead=false}
    local context={world=world,inv=inv,px=74.5,py=50,Items={[2978]={vend=true},[995]={name='Sidewalk Seed',kind='seed'},[13]={name='Door Seed',kind='seed'},[999]={name='World Lock',kind='currency'}}}
    world.atTile=function(x,y)return math.abs(context.px-x-.5)<=.85 and math.abs(context.py-y-1)<=.6 end
    world.vendOwner=function()return not o.foreign end
    world.vends={get=function(x,y)return x==74 and y==49 and vend or nil end}
    world.vendCall=function(action,x,y,cost,per)
        assert(action=='price' and x==74 and y==49)
        calls[#calls+1]={action,x,y,cost,per}
        if o.reject then return false end
        if not o.noUpdate then vend.cost,vend.per=cost,per end
        return true
    end
    local Hub={dead=false,ssp={},recovery={read=function()return o.saved end},onUnload=function(fn)o.unload=fn end}
    local Bind={W=world,context=context,inv=inv,state=function()return state end,resolve=function()end}
    local env={Hub=Hub,Bind=Bind,Farm={},PNB={},Factory={},Surgery={},worldPickerVisible=function()return o.lobby end,
        readfile=function(path)assert(path:match('^ssp%-harga%-vend'));if o.missing then error('missing')end return o.raw end,
        http={JSONDecode=function()if o.badJSON then error('invalid JSON')end return o.data end},
        os={clock=function()return clock end},task={spawn=function(fn)queue[#queue+1]=fn end,wait=function(n)
            clock+=n or .05
            if o.onWait then o.onWait()end
            if not o.defer then local fn=table.remove(queue,1);if fn then fn()end end
        end}}
    local price=make(env);local loaded=price.load();assert(loaded or o.allowInvalid);price.running=loaded
    return {price=price,stock=Hub.vendStock,Hub=Hub,env=env,world=world,vend=vend,context=context,state=state,inv=inv,calls=calls,o=o,
        advance=function(n)clock+=n end,flush=function()while #queue>0 do table.remove(queue,1)()end end}
end
local function test(name,fn)fn();passed+=1;print('PASS '..name)end

test('changes only the mismatched price with native cost/per and no inventory operation',function()
    local t=setup();t.price.step();assert(#t.calls==1 and t.calls[1][4]==1 and t.calls[1][5]==45 and t.price.changed==1)
    assert(t.vend.stock==34 and t.vend.earned==123 and t.inv:count(995)==9)
    t.price.step();t.advance(6);t.price.step();assert(#t.calls==1)
end)
test('WL per seed and zero-stock configured vend work without backpack seed',function()
    local t=setup({data={format='ssp-vend-prices-v1',prices={{name='Sidewalk Seed',cost=3,per=1}}}})
    t.vend.stock=0;t.inv.count=function()return 0 end;t.price.step();assert(t.vend.cost==3 and t.vend.per==1)
end)
test('missing reference, unknown item, gem machine and unconfigured machine are skipped',function()
    for _,edit in ipairs({function(t)t.vend.id=13 end,function(t)t.vend.id=nil end,function(t)t.vend.id=999 end,function(t)t.context.Items[2978].gemMachine=true end})do
        local t=setup();edit(t);t.price.step();assert(#t.calls==0)
    end
end)
test('foreign and distant vend and lobby are skipped',function()
    for _,edit in ipairs({function(t)t.o.foreign=true end,function(t)t.context.px=76 end,function(t)t.o.lobby=true end})do
        local t=setup();edit(t);t.price.step();assert(#t.calls==0)
    end
end)
test('price and stock share the in-flight world lock',function()
    local t=setup();t.world.__HumanHubVendPending={};t.price.step();assert(#t.calls==0)
    t.world.__HumanHubVendPending=nil;t.price.step();assert(#t.calls==1)
    t.stock.running=true;t.world.__HumanHubVendPending={};t.stock.step();assert(#t.calls==1)
end)
test('rechecks ownership, movement, machine ID, current price, revision and stop before sending',function()
    for _,edit in ipairs({function(t)t.o.foreign=true end,function(t)t.context.px=78 end,function(t)t.vend.id=13 end,function(t)t.vend.per=45 end,function(t)t.world.entering=2 end,function(t)t.price.prices={}end,function(t)t.price.stop()end})do
        local t=setup();local first=true;t.o.onWait=function()if first then first=false;edit(t)end end
        t.price.step();assert(#t.calls==0 and not t.world.__HumanHubVendPending)
    end
end)
test('rejects malformed, empty, unknown, duplicate, decimal, free and out-of-game prices atomically',function()
    local bad={{format='other',prices={{name='Sidewalk Seed',cost=1,per=45}}},{format='ssp-vend-prices-v1',prices={}}}
    for _,rows in ipairs({{{name='Fake Seed',cost=1,per=2}},{{name='Sidewalk Seed',cost=1,per=0}},{{name='Sidewalk Seed',cost=1,per=2.5}},{{name='Sidewalk Seed',cost=2,per=3}},{{name='Sidewalk Seed',cost=1,per=201}},{{name='Sidewalk Seed',cost=100001,per=1}},{{name='Sidewalk Seed',cost=1,per=45},{name='sidewalk seed',cost=1,per=44}},{{name='Tangram Block Seed',cost=1,per=20}}})do bad[#bad+1]={format='ssp-vend-prices-v1',prices=rows} end
    for _,data in ipairs(bad)do
        local t=setup({data=data,allowInvalid=true});assert(not t.price.load() and not t.price.prices and not t.price.running)
        assert(not t.price.start() and #t.calls==0)
    end
end)
test('missing files, broken JSON, large files and path traversal are rejected',function()
    for _,o in ipairs({{missing=true},{badJSON=true},{raw=string.rep('x',262145)}})do
        o.allowInvalid=true;local t=setup(o);assert(not t.price.start() and not t.price.prices)
    end
    local t=setup();for _,name in ipairs({'../ssp-harga-vend.json','C:/ssp-harga-vend.json','arbitrary.json'})do
        t.price.setFilename(name);assert(not t.price.load())
    end
end)
test('file replacement updates references; invalid replacement stops rather than reuse old prices',function()
    local t=setup();t.price.step();assert(t.vend.per==45)
    t.o.raw='file-v2';t.o.data.prices[1].per=50;t.advance(6);t.price.step();assert(t.vend.per==50 and #t.calls==2)
    t.o.raw='broken';t.o.badJSON=true;t.advance(6);t.price.step();assert(not t.price.running and not t.price.prices and #t.calls==2)
end)
test('changing selected filename stops and clears the old reference',function()
    local t=setup();t.price.setFilename('ssp-harga-vend (1).json');assert(not t.price.running and not t.price.prices)
end)
test('server rejection backs off; acknowledged but unreplicated price stops',function()
    local t=setup({reject=true});t.price.step();t.price.step();assert(#t.calls==1 and t.vend.per==40)
    t.advance(6);t.price.step();assert(#t.calls==2)
    t=setup({noUpdate=true});t.price.step();assert(not t.price.running and #t.calls==1)
end)
test('timeout blocks duplicate starts and preserves the shared lock until the old request ends',function()
    local t=setup({defer=true});t.price.step();assert(not t.price.running and t.price.pending and not t.price.start())
    assert(t.world.__HumanHubVendPending);t.flush();assert(not t.world.__HumanHubVendPending and #t.calls==0)
end)
test('farm, SSP and recovery pause the price worker',function()
    for _,edit in ipairs({function(t)t.env.Farm.running=true end,function(t)t.Hub.ssp.running=true end,function(t)t.o.saved={world='OWN'}end})do
        local t=setup();edit(t);t.price.step();assert(#t.calls==0)
    end
end)
test('legacy omitted seeds do not break valid exports and seed names normalize',function()
    local t=setup({data={format='ssp-vend-prices-v1',prices={{name='Tangram Block Seed',cost=1,per=1},{name='  SIDEWALK   SEED  ',cost=1,per=45}}}})
    t.price.step();assert(t.vend.per==45)
end)
test('actual UI supports load, filename change, start, silent reset and unload',function()
    local t=setup();t.price.running=false
    local callbacks={};local toggle={Value=false}
    local section={Paragraph=function()return {SetDesc=function()end}end,Input=function(_,v)callbacks.input=v.Callback end,Button=function(_,v)callbacks.load=v.Callback end,Toggle=function(_,v)callbacks.toggle=v.Callback;return toggle end}
    function toggle:Set(on,fire)self.Value=on;if fire~=false then callbacks.toggle(on)end end
    makeUI(t.Hub,section);callbacks.load();callbacks.toggle(true);assert(t.price.running)
    callbacks.input('ssp-harga-vend (1).json');assert(not t.price.running and not toggle.Value)
    t.o.unload();assert(not t.price.running)
end)
print(passed..' cases passed')
