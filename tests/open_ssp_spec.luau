local passed = 0
local function setup(options)
    options = options or {}
    local clock, queue, calls, drops = 100, {}, {}, {}
    local server = table.clone(options.counts or {[5706]=2})
    local items = {
        [5706]={name='Small Seed Pack',kind='consumable'},
        [13]={name='Door Seed',kind='seed'}, [17]={name='Glass Pane Seed',kind='seed'},
        [19]={name='Grass Seed',kind='seed'}, [21]={name='Wood Block Seed',kind='seed'},
        [23]={name='Lava Rock Seed',kind='seed'}, [99]={name='Pepper Tree Seed',kind='seed'},
        [999]={name='World Lock',kind='currency'}, [888]={name='Tool',kind='tool'},
    }
    local inv = {slots={},capacity=options.capacity or 54}
    local function rebuild()
        inv.slots={}
        for id,n in pairs(inv.counts) do if n>0 then table.insert(inv.slots,{id=id,n=n}) end end
    end
    inv.counts=table.clone(server)
    function inv:count(id) return self.counts[id] or 0 end
    function inv:used()
        local count=0
        for id,n in pairs(self.counts) do if n>0 and (not items[id] or items[id].kind~='tool') then count+=1 end end
        return count
    end
    function inv:remove(id,n)
        assert(self:count(id)>=n)
        self.counts[id]=self:count(id)-n
        if self.counts[id]==0 then self.counts[id]=nil end
        rebuild()
        return true
    end
    function inv:add(id,n)
        if not self.counts[id] and self:used()>=self.capacity then return 0 end
        assert(self:count(id)+n<=200)
        self.counts[id]=self:count(id)+n
        rebuild()
        return n
    end
    rebuild()
    local state={x=3,y=10,active=true,dead=false}
    local world={name='TEST',entering=1,DROP_COOLDOWN=1,lastDropAt=0}
    local context={world=world,inv=inv,Items=items,px=3,py=10,facing=1}
    local ground=options.ground or {}
    world.dropList=function()return ground end
    world.takeDrop=function(uid,wanted)
        calls[#calls+1]='TakeDrop'
        if options.rejectTake then return 0 end
        for _,drop in ipairs(ground) do
            if drop.uid==uid then
                assert(drop.id==5706,'refill must never collect seeds')
                local taken=math.min(wanted,200-(server[5706] or 0))
                server[5706]=(server[5706] or 0)+taken
                return taken
            end
        end
        return 0
    end
    context.setDropCount=function(drop,left)
        drop.n=left
        if left==0 then table.remove(ground,table.find(ground,drop)) end
    end
    local ctrl={canDrop=function() return not options.blocked end}
    world.displayHere=function() return options.display and 5 or nil end
    world.call=function(remote,id)
        calls[#calls+1]=remote
        if options.onCall then options.onCall(remote) end
        if remote=='GetInventory' then
            local slots={}
            for key,n in pairs(server) do if n>0 then slots[#slots+1]={key,n} end end
            return {capacity=inv.capacity,slots=slots}
        end
        assert(remote=='OpenPack' and id==5706)
        if options.rejectOpen then return false,'Backpack full' end
        assert((server[5706] or 0)>0)
        server[5706]-=1
        if server[5706]==0 then server[5706]=nil end
        if options.nativeRefill then server[5706]=200 end
        local rewards=options.rewards or {{13,4},{17,1}}
        for _,r in ipairs(rewards) do server[r[1]]=(server[r[1]] or 0)+r[2] end
        return true,rewards
    end
    ctrl.onDrop=function(id,n)
        drops[#drops+1]={id,n,time=clock}
        inv:remove(id,n)
        if not options.rejectDrop then
            server[id]-=n
            if server[id]==0 then server[id]=nil end
        end
    end
    context.invUI=ctrl
    local Hub={dead=false,sspSeedNames={['door seed']='Door Seed',['glass pane seed']='Glass Pane Seed',['grass seed']='Grass Seed',['wood block seed']='Wood Block Seed',['lava rock seed']='Lava Rock Seed'},recovery={read=function()return nil end},onUnload=function()end}
    local Bind={W=world,inv=inv,context=context,state=function()return state end,resolve=function()end}
    local ssp
    local env={Hub=Hub,Bind=Bind,Farm={},PNB={},Factory={},Surgery={},Move={release=function()end},
        task={spawn=function(fn) queue[#queue+1]=fn end,wait=function(delay)
            clock+=delay or 0.05
            if options.onWait then options.onWait(clock) end
            if options.stopWhenEmpty and ssp and ssp.opened>=2 and not server[5706] then ssp.stop('uji selesai') end
            if options.deferRequests then return end
            local fn=table.remove(queue,1)
            if fn then fn() end
        end},os={clock=function()return clock end},
        dropInReach=function(drop,s)
            return math.abs(drop.x-s.x)<0.6 and s.y-.95<drop.y+.3 and drop.y-.3<s.y
        end,worldPickerVisible=function()return options.lobby end}
    ssp=make(env)
    ssp.running=true
    local job={context=context,inv=inv,world=world,name='TEST',entering=1,gen=ssp.gen,ctrl=ctrl,x=3,y=10}
    return {ssp=ssp,job=job,server=server,inv=inv,state=state,world=world,drops=drops,calls=calls,options=options,Hub=Hub,env=env,ground=ground,
        drain=function()while #queue>0 do table.remove(queue,1)() end end}
end
local function test(name,fn)
    fn()
    passed+=1
    print('PASS '..name)
end
local function step(t) return t.ssp.step(t.job) end

test('stack 200 only drops that seed, retains partial seed and locks',function()
    local t=setup({counts={[5706]=2,[13]=200,[17]=30,[999]=200}})
    assert(step(t))
    assert(#t.drops==1 and t.drops[1][1]==13 and t.drops[1][2]==200)
    assert(t.server[17]==30 and t.server[999]==200 and t.server[5706]==2)
end)
test('too many types drops minimal small stacks until five slots are free',function()
    local t=setup({capacity=8,counts={[5706]=2,[13]=10,[17]=3,[19]=2,[21]=6,[23]=9,[999]=200,[99]=80}})
    for _=1,5 do assert(step(t)) end
    assert(#t.drops==5 and t.drops[1][1]==19 and t.drops[2][1]==17)
    assert(t.server[999]==200 and t.server[99]==80 and t.server[5706]==2)
    assert(step(t) and t.server[5706]==1)
end)
test('room available opens SSP without dropping partial seeds',function()
    local t=setup({counts={[5706]=2,[13]=12}})
    assert(step(t) and #t.drops==0 and t.ssp.opened==1)
    assert(t.server[5706]==1 and t.inv:count(5706)==1 and t.inv:count(13)==16 and t.inv:count(17)==1)
end)
test('last SSP still drops stack reaching 200 then preserves partials',function()
    local t=setup({counts={[5706]=1,[13]=196}})
    assert(step(t) and t.server[13]==200)
    assert(step(t) and t.server[13]==nil and #t.drops==1)
    assert(step(t) and t.ssp.running and t.ssp.status:find('menunggu refill',1,true) and t.server[17]==1)
end)
test('duplicate reward rows aggregate correctly',function()
    local t=setup({rewards={{13,2},{13,2},{17,1}}})
    assert(step(t) and t.inv:count(13)==4)
end)
test('tool does not consume backpack type capacity',function()
    local t=setup({capacity=6,counts={[5706]=2,[888]=1}})
    assert(step(t) and #t.drops==0)
end)
test('full of non SSP items stops without dropping locks or rare seeds',function()
    local t=setup({capacity=3,counts={[5706]=1,[999]=200,[99]=200}})
    local ok,msg=pcall(step,t)
    assert(not ok and msg:find('tidak ada seed SSP',1,true) and #t.drops==0)
end)
test('rejected ground drop restores server counts and prevents opening',function()
    local t=setup({counts={[5706]=2,[13]=200},rejectDrop=true})
    local ok,msg=pcall(step,t)
    assert(not ok and msg:find('belum terkonfirmasi',1,true) and #t.drops==1 and t.inv:count(13)==200)
    assert(t.server[5706]==2)
end)
test('cooldown preserved between different seed types',function()
    local t=setup({counts={[5706]=2,[13]=200,[17]=200}})
    assert(step(t) and step(t) and #t.drops==2)
    assert(t.drops[2].time-t.drops[1].time>=1.1-1e-7)
end)
test('display and blocked drop stop before consuming SSP',function()
    for _,options in ipairs({{display=true},{blocked=true}}) do
        local t=setup(options)
        assert(not pcall(step,t) and t.server[5706]==2 and #t.drops==0)
    end
end)
test('world or position changes prevent inventory actions',function()
    local t=setup();t.world.name='OTHER';assert(not pcall(step,t) and #t.calls==0)
    t=setup();t.state.x=7;assert(not pcall(step,t) and #t.calls==0)
end)
test('timeout keeps pending lock until late reply; start cannot duplicate',function()
    local t=setup({deferRequests=true})
    local ok,msg=pcall(step,t)
    assert(not ok and msg:find('server belum membalas',1,true) and t.ssp.pending)
    t.ssp.stop();assert(not t.ssp.start())
    t.drain();assert(t.ssp.pending==nil and t.server[5706]==2)
end)
test('stopping during request prevents subsequent open or drop',function()
    local t=setup()
    t.options.onCall=function()t.ssp.stop()end
    assert(not pcall(step,t) and #t.calls==1 and t.server[5706]==2 and #t.drops==0)
end)
test('worker entry point keeps opening until explicitly stopped',function()
    local t=setup({stopWhenEmpty=true});t.ssp.running=false
    assert(t.ssp.start());t.drain()
    assert(not t.ssp.running and t.ssp.opened==2 and t.ssp.status:find('uji selesai',1,true))
    assert(t.inv:count(13)==8 and t.inv:count(5706)==0)
end)
test('server rejection ends worker once',function()
    local t=setup({rejectOpen=true});t.ssp.running=false
    assert(t.ssp.start());t.drain()
    assert(not t.ssp.running and t.ssp.status:find('OpenPack ditolak',1,true) and t.server[5706]==2)
    local opens=0;for _,r in ipairs(t.calls)do if r=='OpenPack'then opens+=1 end end
    assert(opens==1)
end)
test('reload cannot overlap an unfinished server request',function()
    local t=setup({deferRequests=true})
    assert(not pcall(step,t))
    local replacement=make(t.env)
    assert(not replacement.start())
    t.drain()
    assert(t.world.__HumanHubSSPPending==nil)
end)
test('actual toggle starts worker and silent status sync does not replay it',function()
    local t=setup({stopWhenEmpty=true});t.ssp.running=false
    local config, paragraph, toggle
    local section={
        Paragraph=function(_,p)
            local out={SetDesc=function(_,text)paragraph=text end}
            return out
        end,
        Toggle=function(_,p)
            config=p
            toggle={Value=false,Set=function(self,value)
                self.Value=value
                p.Callback(value)
            end}
            return toggle
        end,
    }
    makeUI(t.Hub,{Section=function()return section end})
    toggle:Set(true)
    t.drain()
    assert(not toggle.Value and not t.ssp.running and t.ssp.opened==2)
    assert(paragraph:find('uji selesai',1,true))
    assert(t.ssp.gen==2,'silent toggle sync must not call stop again')
end)
test('native ground refill during OpenPack may keep backpack at 200',function()
    local t=setup({counts={[5706]=200},nativeRefill=true})
    assert(step(t) and t.ssp.opened==1 and t.server[5706]==200)
    assert(step(t) and t.ssp.opened==2 and t.server[5706]==200)
end)
test('empty backpack waits then collects nearby SSP and continues opening',function()
    local t=setup({counts={}})
    assert(step(t) and t.ssp.running and #t.drops==0)
    assert(t.ssp.status:find('menunggu refill',1,true))
    t.ground[1]={id=5706,uid=1,n=25,x=3,y=9.55}
    assert(step(t) and t.inv:count(5706)==25 and #t.ground==0)
    assert(step(t) and t.inv:count(5706)==24 and t.ssp.opened==1)
end)
test('partial pickup leaves remaining stack and empty can refill repeatedly',function()
    local t=setup({counts={},ground={{id=5706,uid=1,n=250,x=3,y=9.55}}})
    assert(step(t) and t.inv:count(5706)==200 and t.ground[1].n==50)
    t.server[5706]=nil
    t.env.task.wait(1)
    assert(step(t) and t.inv:count(5706)==50 and #t.ground==0)
end)
test('refill never picks unrelated seeds, displays or distant SSP',function()
    local t=setup({counts={},ground={
        {id=13,uid=1,n=200,x=3,y=9.55},
        {id=5706,uid=2,n=200,x=5,y=9.55},
        {id=5706,uid=3,n=200,x=3,y=9.55,display=true},
    }})
    assert(step(t) and t.inv:count(5706)==0 and #t.drops==0)
    for _,call in ipairs(t.calls) do assert(call~='TakeDrop') end
end)
test('empty full backpack drops one small seed stack for refill slot',function()
    local t=setup({capacity=6,counts={[13]=2,[17]=6,[19]=8,[21]=5,[23]=4,[999]=200},
        ground={{id=5706,uid=1,n=20,x=3,y=9.55}}})
    assert(step(t) and #t.drops==1 and t.drops[1][1]==13)
    assert(step(t) and t.inv:count(5706)==20)
    assert(t.server[999]==200 and t.server[17]==6)
end)
test('rejected refill remains active and backs off before next request',function()
    local t=setup({counts={},rejectTake=true,ground={{id=5706,uid=1,n=20,x=3,y=9.55}}})
    assert(step(t) and step(t) and t.ssp.running)
    local takes=0;for _,call in ipairs(t.calls)do if call=='TakeDrop'then takes+=1 end end
    assert(takes==1 and t.inv:count(5706)==0)
end)
print(passed..' cases passed')
