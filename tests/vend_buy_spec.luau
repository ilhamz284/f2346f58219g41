local passed=0
local function setup(o)
    o=o or {};o.raw=o.raw or 'v1'
    o.data=o.data or {format='ssp-vend-prices-v1',prices={{name='Cliffside Seed',cost=1,per=80}}}
    local clock,queue,calls=100,{},{}
    local inv={counts={[242]=o.money or 10,[13]=o.count or 0}}
    function inv:count(id)return self.counts[id] or 0 end
    function inv:room(id)if o.full then return 0 end return 200-self:count(id)end
    local vend={id=13,cost=o.cost or 1,per=o.per or 100,stock=o.stock or 1000}
    local w={name='OTHER',entering=1,fg={[42]={[28]=2978}}}
    local state={active=true,dead=false}
    local c={world=w,inv=inv,px=28.5,py=43,Items={[2978]={vend=true},[13]={name='Cliffside Seed',kind='seed'},[17]={name='Door Seed',kind='seed'},[999]={kind='currency',name='World Lock'}}}
    w.atTile=function(x,y)return math.abs(c.px-x-.5)<=.85 and math.abs(c.py-y-1)<=.6 end
    w.vendOwner=function()return o.owner==true end
    w.vends={get=function(x,y)return x==28 and y==42 and vend or nil end}
    local weights={[242]=1,[1796]=100,[7188]=10000,[20049]=100000,[20050]=1000000}
    local function balance()local n=0;for id,v in pairs(weights)do n+=inv:count(id)*v end return n end
    w.vendCall=function(action,x,y,amount,quote)
        assert(action=='buy' and x==28 and y==42 and type(quote)=='table')
        calls[#calls+1]={amount=amount,cost=quote.cost,per=quote.per}
        if o.beforeServer then o.beforeServer(vend)end
        if o.reject or vend.cost~=quote.cost or vend.per~=quote.per then return false end
        assert(amount>0 and amount%vend.per==0 and amount<=vend.stock and amount<=inv:room(vend.id))
        local payment=amount/vend.per*vend.cost;assert(payment<=balance())
        if not o.noUpdate then
            inv.counts[vend.id]=inv:count(vend.id)+amount
            local remaining=balance()-payment
            for id in pairs(weights)do inv.counts[id]=nil end
            for _,id in ipairs({20050,20049,7188,1796,242})do
                inv.counts[id]=math.floor(remaining/weights[id]);remaining%=weights[id]
            end
            vend.stock-=amount
        end
        return true,{add={{vend.id,amount}}}
    end
    local Hub={dead=false,ssp={},recovery={read=function()return o.saved end},onUnload=function(fn)o.unload=fn end}
    local b={W=w,context=c,inv=inv,resolve=function()end,state=function()return state end}
    local env={Hub=Hub,Bind=b,Farm={},PNB={},Factory={},Surgery={},worldPickerVisible=function()return o.lobby end,
        os={clock=function()return clock end},readfile=function()if o.missing then error('missing')end return o.raw end,
        http={JSONDecode=function()if o.badJSON then error('bad')end return o.data end},
        task={spawn=function(fn)queue[#queue+1]=fn end,wait=function(n)
            clock+=n or .05;if o.onWait then o.onWait()end
            if not o.defer then local fn=table.remove(queue,1);if fn then fn()end end
        end}}
    local buy=make(env);assert(buy.load());buy.running=true
    return {buy=buy,o=o,env=env,Hub=Hub,world=w,vend=vend,state=state,context=c,inv=inv,calls=calls,balance=balance,
        advance=function(n)clock+=n end,flush=function()while #queue>0 do table.remove(queue,1)()end end}
end
local function test(name,fn)fn();passed+=1;print('PASS '..name)end

test('100/WL versus reference80 buys maximum200 for2WL, then skips full stack',function()
    local t=setup();t.buy.step();assert(#t.calls==1 and t.calls[1].amount==200 and t.balance()==8 and t.inv:count(13)==200)
    assert(t.buy.bought==200 and t.buy.spent==2 and t.vend.stock==800)
    t.advance(6);t.buy.step();assert(#t.calls==1)
end)
test('same and more expensive unit prices are skipped',function()
    for _,per in ipairs({80,70,1})do local t=setup({per=per});t.buy.step();assert(#t.calls==0)end
end)
test('seed per WL: exactly15percent, below15percent and only above15percent boundary',function()
    for _,per in ipairs({99,100,101})do
        local t=setup({per=per,data={format='ssp-vend-prices-v1',prices={{name='Cliffside Seed',cost=1,per=85}}}})
        t.buy.step();assert(#t.calls==(per==101 and 1 or 0))
    end
end)
test('WL per seed: exactly15percent is skipped and greater discount is bought',function()
    for _,cost in ipairs({84,85,86})do
        local t=setup({cost=cost,per=1,money=200,data={format='ssp-vend-prices-v1',prices={{name='Cliffside Seed',cost=100,per=1}}}})
        t.buy.step();assert(#t.calls==(cost==84 and 1 or 0))
    end
end)
test('a queued discount that falls to15percent is rejected before sending',function()
    local t=setup({per=101,data={format='ssp-vend-prices-v1',prices={{name='Cliffside Seed',cost=1,per=85}}}})
    local first=true;t.o.onWait=function()if first then first=false;t.vend.per=100 end end
    t.buy.step();assert(#t.calls==0)
end)
test('buys only complete lots that fit backpack, stock and funds',function()
    for _,case in ipairs({{per=150,count=0,stock=1000,money=10,expected=150},{per=100,count=60,stock=1000,money=10,expected=100},{per=100,count=0,stock=150,money=10,expected=100},{per=100,count=0,stock=1000,money=1,expected=100}})do
        local t=setup(case);t.buy.step();assert(t.calls[1].amount==case.expected)
    end
end)
test('not enough money, room, stack or one full lot does not buy',function()
    for _,o in ipairs({{money=0},{full=true},{count=200},{count=150},{stock=99}})do
        local t=setup(o);t.buy.step();assert(#t.calls==0)
    end
end)
test('WL per seed and mixed units compare correctly',function()
    local t=setup({cost=2,per=1,money=10,data={format='ssp-vend-prices-v1',prices={{name='Cliffside Seed',cost=3,per=1}}}})
    t.buy.step();assert(t.calls[1].amount==5 and t.buy.spent==10)
    t=setup({cost=2,per=1});t.buy.step();assert(#t.calls==0)
end)
test('native currency denominations including DL, BGL and larger locks count once',function()
    local t=setup({money=0});t.inv.counts[1796]=2;t.inv.counts[7188]=3;t.inv.counts[20049]=4;t.inv.counts[20050]=1
    assert(t.buy.balance(t.inv)==1430200);t.buy.step();assert(t.buy.bought==200 and t.buy.spent==2)
end)
test('own vend, shops, nonseed, unknown reference and gem machine are skipped',function()
    for _,edit in ipairs({function(t)t.o.owner=true end,function(t)t.vend.shop=true end,function(t)t.vend.id=17 end,function(t)t.vend.id=999 end,function(t)t.context.Items[2978].gemMachine=true end})do
        local t=setup();edit(t);t.buy.step();assert(#t.calls==0)
    end
end)
test('malformed, zero, decimal, infinite and negative quotes never cause a request',function()
    for _,edit in ipairs({function(t)t.vend.cost=nil end,function(t)t.vend.cost=0 end,function(t)t.vend.per=0 end,function(t)t.vend.stock=-1 end,function(t)t.vend.cost=0/0 end,function(t)t.vend.per=100.5 end,function(t)t.vend.stock=math.huge end,function(t)t.vend.per=201 end})do
        local t=setup();edit(t);t.buy.step();assert(#t.calls==0)
    end
end)
test('moved player, replaced seed, raised price, ownership and stop are rechecked before send',function()
    for _,edit in ipairs({function(t)t.context.px=31 end,function(t)t.vend.id=17 end,function(t)t.vend.cost=2 end,function(t)t.o.owner=true end,function(t)t.world.entering=2 end,function(t)t.buy.stop()end,function(t)t.buy.prices={}end})do
        local t=setup();local first=true;t.o.onWait=function()if first then first=false;edit(t)end end
        t.buy.step();assert(#t.calls==0 and not t.world.__HumanHubVendPending)
    end
end)
test('latest count, money and stock lower the original order without increasing it',function()
    local t=setup();local first=true;t.o.onWait=function()if first then first=false;t.inv.counts[242]=1 end end
    t.buy.step();assert(t.calls[1].amount==100 and t.buy.spent==1)
    t=setup({stock=100});first=true;t.o.onWait=function()if first then first=false;t.vend.stock=1000 end end
    t.buy.step();assert(t.calls[1].amount==100)
end)
test('quoted native request rejects server price changes and backs off',function()
    local t=setup({beforeServer=function(v)v.cost=2 end});t.buy.step();assert(#t.calls==1 and t.inv:count(13)==0 and t.balance()==10)
    t.buy.step();assert(#t.calls==1)
end)
test('stock and price use the same in-flight lock as buying',function()
    local t=setup();t.world.__HumanHubVendPending={};t.buy.step();assert(#t.calls==0)
    t.world.__HumanHubVendPending=nil;t.buy.step();assert(#t.calls==1)
end)
test('timeout cannot restart or replay a possibly accepted order',function()
    local t=setup({defer=true});t.buy.step();assert(not t.buy.running and t.buy.pending and not t.buy.start())
    assert(t.world.__HumanHubVendPending);t.flush();assert(#t.calls==0 and not t.world.__HumanHubVendPending)
end)
test('accepted response with inconsistent inventory stops before another purchase',function()
    local t=setup({noUpdate=true});t.buy.step();assert(not t.buy.running and #t.calls==1)
end)
test('updated file controls comparisons and missing or broken file stops stale references',function()
    local t=setup();t.o.raw='v2';t.o.data.prices[1].per=120;t.advance(6);t.buy.step();assert(#t.calls==0)
    t.o.raw='v3';t.o.data.prices[1].per=80;t.advance(6);t.buy.step();assert(#t.calls==1)
    t.o.missing=true;t.advance(6);t.buy.step();assert(not t.buy.running and not t.buy.prices)
end)
test('changing shared source while queued prevents purchase with old references',function()
    local t=setup();local first=true;t.o.onWait=function()if first then first=false;t.Hub.vendPrice.filename='ssp-harga-vend (1).json'end end
    t.buy.step();assert(#t.calls==0)
end)
test('farming, SSP, recovery, dead or lobby states pause buying',function()
    for _,edit in ipairs({function(t)t.env.Farm.running=true end,function(t)t.Hub.ssp.running=true end,function(t)t.o.saved={world='OTHER'}end,function(t)t.state.dead=true end,function(t)t.o.lobby=true end})do
        local t=setup();edit(t);t.buy.step();assert(#t.calls==0)
    end
end)
test('actual toggle starts, silently resets and stops on unload',function()
    local t=setup();t.buy.running=false;local callback
    local toggle={Value=false};function toggle:Set(on,fire)self.Value=on;if fire~=false then callback(on)end end
    local section={Paragraph=function()return {SetDesc=function()end}end,Toggle=function(_,v)callback=v.Callback;return toggle end}
    makeUI(t.Hub,section);callback(true);assert(t.buy.running)
    t.buy.stop('done');assert(not toggle.Value);t.o.unload();assert(not t.buy.running)
end)
print(passed..' cases passed')
