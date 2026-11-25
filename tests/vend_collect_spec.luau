local passed=0
local weights={[242]=1,[1796]=100,[7188]=10000,[20049]=100000,[20050]=1000000}
local function setup(o)
    o=o or {};local clock,queue,calls=100,{},{}
    local inv={counts={[242]=o.money or 0,[13]=25}}
    function inv:count(id)return self.counts[id] or 0 end
    local function balance()local n=0;for id,v in pairs(weights)do n+=inv:count(id)*v end return n end
    local vend={id=13,stock=123,cost=1,per=80,earned=o.earned or 46}
    local w={name='OWN',entering=1,fg={[49]={[85]=2978}}}
    local state={active=true,dead=false}
    local c={world=w,inv=inv,px=85.5,py=50,Items={[2978]={vend=true},[9268]={vend=true},[999]={vend=true,gemMachine=true},[13]={name='Door Seed',kind='seed'}}}
    w.atTile=function(x,y)return math.abs(c.px-x-.5)<=.85 and math.abs(c.py-y-1)<=.6 end
    w.vendOwner=function()return not o.foreign end
    w.vends={get=function(x,y)return x==85 and y==49 and vend or nil end}
    w.vendCall=function(action,x,y,...)
        assert(action=='withdraw' and x==85 and y==49 and select('#',...)==0)
        calls[#calls+1]=action
        if o.reject then return false,'backpack full' end
        if o.moreSales then vend.earned+=o.moreSales end
        local amount=o.partial and math.min(vend.earned,o.partial) or vend.earned
        local newMoney=balance()+amount
        local result={add={},remove={}}
        for id in pairs(weights)do if inv:count(id)>0 then result.remove[#result.remove+1]={id,inv:count(id)}end end
        for _,id in ipairs({20050,20049,7188,1796,242})do
            local n=math.floor(newMoney/weights[id]);newMoney%=weights[id]
            if n>0 then result.add[#result.add+1]={id,n}end
        end
        if not o.noWalletUpdate then
            for id in pairs(weights)do inv.counts[id]=nil end
            for _,row in ipairs(result.add)do inv.counts[row[1]]=row[2]end
        end
        if not o.noEarnUpdate then vend.earned-=amount end
        o.ack=true
        return true,result
    end
    local Hub={dead=false,ssp={},recovery={read=function()return o.saved end},onUnload=function(fn)o.unload=fn end}
    local b={W=w,context=c,inv=inv,resolve=function()end,state=function()return state end}
    local env={Hub=Hub,Bind=b,Farm={},PNB={},Factory={},Surgery={},worldPickerVisible=function()return o.lobby end,
        os={clock=function()return clock end},task={spawn=function(fn)queue[#queue+1]=fn end,wait=function(n)
            clock+=n or .05;if o.onWait then o.onWait(clock)end
            if not o.defer then local fn=table.remove(queue,1);if fn then fn()end end
        end}}
    local collect=make(env);collect.running=true
    return {collect=collect,o=o,env=env,Hub=Hub,world=w,vend=vend,state=state,context=c,inv=inv,calls=calls,balance=balance,
        advance=function(n)clock+=n end,flush=function()while #queue>0 do table.remove(queue,1)()end end}
end
local function test(name,fn)fn();passed+=1;print('PASS '..name)end

test('passing an owned vend withdraws earnings once and preserves seed stock and price',function()
    local t=setup();t.collect.step();assert(#t.calls==1 and t.balance()==46 and t.vend.earned==0)
    assert(t.vend.stock==123 and t.vend.cost==1 and t.vend.per==80 and t.inv:count(13)==25)
    assert(t.collect.collected==46 and t.collect.machines==1)
    t.collect.step();t.advance(6);t.collect.step();assert(#t.calls==1)
end)
test('empty configured or unconfigured vend and DigiVend earnings are collected',function()
    for _,edit in ipairs({function(t)t.vend.stock=0;t.vend.id=nil end,function(t)t.world.fg[49][85]=9268 end})do
        local t=setup();edit(t);t.collect.step();assert(t.balance()==46)
    end
end)
test('currency conversion across WL DL BGL Emerald and Ruby is counted as net earnings',function()
    local t=setup({money=199,earned=1000246});t.inv.counts[1796]=2
    local before=t.balance();t.collect.step();assert(t.balance()==before+1000246 and t.collect.collected==1000246)
end)
test('earnings received during scheduling and partial server withdrawals use actual credited amount',function()
    local t=setup({moreSales=4});t.collect.step();assert(t.collect.collected==50 and t.balance()==50)
    t=setup({partial=20});t.collect.step();assert(t.collect.collected==20 and t.vend.earned==26)
end)
test('foreign vend, distant machines, gem machines and shop machines are skipped',function()
    for _,edit in ipairs({function(t)t.o.foreign=true end,function(t)t.context.px=88 end,function(t)t.world.fg[49][85]=999 end,function(t)t.vend.shop=true end})do
        local t=setup();edit(t);t.collect.step();assert(#t.calls==0)
    end
end)
test('zero missing negative decimal and malformed earnings never cause withdrawal',function()
    for _,edit in ipairs({function(t)t.vend.earned=0 end,function(t)t.vend.earned=nil end,function(t)t.vend.earned=-1 end,function(t)t.vend.earned=.5 end,function(t)t.vend.earned=0/0 end,function(t)t.vend.earned=math.huge end,function(t)t.vend.earned='46'end})do
        local t=setup();edit(t);t.collect.step();assert(#t.calls==0)
    end
end)
test('ownership position machine replacement world and stop recheck before sending',function()
    for _,edit in ipairs({function(t)t.o.foreign=true end,function(t)t.context.px=90 end,function(t)t.world.fg[49][85]=0 end,function(t)t.world.entering=2 end,function(t)t.world.name='OTHER'end,function(t)t.collect.stop()end,function(t)t.vend.earned=0 end})do
        local t=setup();local first=true;t.o.onWait=function()if first then first=false;edit(t)end end
        t.collect.step();assert(#t.calls==0 and not t.world.__HumanHubVendPending)
    end
end)
test('native server rejection backs off and does not change wallet or earnings',function()
    local t=setup({reject=true});t.collect.step();t.collect.step();assert(#t.calls==1 and t.balance()==0 and t.vend.earned==46)
    t.advance(5);t.collect.step();assert(#t.calls==2)
end)
test('timeout preserves pending lock and prevents restart or replay',function()
    local t=setup({defer=true});t.collect.step();assert(not t.collect.running and t.collect.pending and not t.collect.start())
    assert(t.world.__HumanHubVendPending);t.flush();assert(#t.calls==0 and not t.world.__HumanHubVendPending)
end)
test('shared vend lock serializes collect with stock price and buy',function()
    local t=setup();t.world.__HumanHubVendPending={};t.collect.step();assert(#t.calls==0)
    t.world.__HumanHubVendPending=nil;t.collect.step();assert(#t.calls==1)
end)
test('ACK without matching backpack credit stops; stale vend earnings also stop',function()
    local t=setup({noWalletUpdate=true});t.collect.step();assert(not t.collect.running and t.collect.collected==0 and #t.calls==1)
    t=setup({noEarnUpdate=true});t.collect.step();assert(not t.collect.running and t.collect.collected==46 and #t.calls==1)
end)
test('delayed VendChanged is awaited and freshly earned proceeds can later be collected',function()
    local t=setup({noEarnUpdate=true});t.o.onWait=function(clock)if t.o.ack and clock>=100.3 then t.vend.earned=0 end end
    t.collect.step();assert(t.collect.running and t.collect.collected==46)
    t.o.noEarnUpdate=false;t.o.onWait=nil;t.vend.earned=5;t.advance(6);t.collect.step();assert(t.collect.collected==51)
end)
test('farm SSP recovery lobby and dead character pause collections',function()
    for _,edit in ipairs({function(t)t.env.Farm.running=true end,function(t)t.Hub.ssp.running=true end,function(t)t.o.saved={world='OWN'}end,function(t)t.o.lobby=true end,function(t)t.state.dead=true end})do
        local t=setup();edit(t);t.collect.step();assert(#t.calls==0)
    end
end)
test('actual UI starts worker silently resets and unload stops collect',function()
    local t=setup();t.collect.running=false;local callback
    local toggle={Value=false};function toggle:Set(on,fire)self.Value=on;if fire~=false then callback(on)end end
    local section={Paragraph=function()return {SetDesc=function()end}end,Toggle=function(_,v)callback=v.Callback;return toggle end}
    makeUI(t.Hub,section);callback(true);assert(t.collect.running)
    t.collect.stop('done');assert(not toggle.Value);t.o.unload();assert(not t.collect.running)
end)
print(passed..' cases passed')
