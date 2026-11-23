local clock, jobs, calls, queue, hooks, ups, rendered = 0, {}, {}, {}, {}, {}, 0
local os = {clock = function() return clock end}
local task = {}
function task.spawn(fn)
	jobs[#jobs + 1] = {co = coroutine.create(fn), at = clock}
end
function task.wait(delay) return coroutine.yield(delay or 0.01) end
local Hub = {dead = false, unload = {}, recovery = {read = function() return {} end}}
function Hub.onUnload(fn) Hub.unload[#Hub.unload + 1] = fn end
local Farm, PNB, Factory = {running = false}, {running = false}, {running = false}
local Move = {release = function() end}
local state = {x = 0.5, y = 1, active = true}
local inv = {stock = {}}
function inv:count(id) return self.stock[id] or 0 end
function inv:remove(id, amount) self.stock[id] = self:count(id) - amount end
function inv:add(id, amount) self.stock[id] = self:count(id) + amount end
local nativeOpen = function() end
local nativeRender = function() rendered += 1 end
local render
render = function(value) return (hooks[render] or nativeRender)(value) end
local W = {name = "SURGERY", w = 100, fg = {}, surgOn = {}, surgery = {open = nativeOpen}}
local context = {Items = {[4296] = {surgE = true}, [8558] = {surgE = true}}}
function context.inReach(x) return x <= 4 end
local Bind = {W = W, inv = inv, name = W.name, context = context,
	state = function() return state end, resolve = function() return true end}
local picker = false
local function worldPickerVisible() return picker end
local function call(remote, action, arg, y)
	assert(remote == "Surgery")
	calls[#calls + 1] = {action, arg, y, time = clock}
	local reply = table.remove(queue, 1)
	assert(reply, "unexpected request: " .. action)
	assert(reply.action == action, "expected " .. reply.action .. ", got " .. action)
	if reply.arg then assert(reply.arg == arg, "wrong tool") end
	if reply.delay then task.wait(reply.delay) end
	if reply.effect then reply.effect() end
	if reply.error then error(reply.error) end
	if reply.reject then return false, reply.reject end
	return reply.payload
end
ups[nativeOpen] = {false, call, 4296, render}
local debug = {}
function debug.getinfo(fn)
	if fn == nativeOpen then return {nups = 4} end
	return {name = fn == call and "call" or (fn == render and "render" or "other")}
end
function debug.getupvalue(fn, i) return ups[fn][i] end
function debug.setupvalue(fn, i, value) ups[fn][i] = value end
local function hookfunction(target, replacement)
	local original = hooks[target] or nativeRender
	hooks[target] = replacement
	return original
end

-- INSERT SURGERY HERE

local toolIds = {1258,1262,1270,1260,4316,1264,4318,1266,4310,1268,4308,4314,4312}
local function patient(overrides)
	local p = {status = "Unconscious", pulse = "Strong", temp = 98.6, dirt = 0, bleed = 0,
		pool = 0, incisions = 0, fever = 0, need = 1, usable = {}, diagnosis = "Injury"}
	for k, v in pairs(overrides or {}) do p[k] = v end
	return p
end
local function reset()
	assert(not Surgery.pending)
	Surgery.stop(); Surgery.detach()
	Surgery.won, Surgery.lost, Surgery.steps = 0, 0, 0
	Surgery.onStatus = nil
	calls, queue, rendered = {}, {}, 0
	state.active, state.dead, picker = true, false, false
	W.name, W.fg, W.surgOn = "SURGERY", {}, {}
	Bind.W, Bind.inv, Bind.name, Bind.context = W, inv, W.name, context
	Farm.running, PNB.running, Factory.running, Hub.dead = false, false, false, false
	Hub.recovery.read = function() return {} end
	inv.stock = {}
	for _, id in ipairs(toolIds) do inv.stock[id] = 10 end
	ups[nativeOpen][1], ups[nativeOpen][3] = false, 4296
	local binding = assert(Surgery.attach())
	Surgery.running = true; Surgery.gen += 1
	return binding, Surgery.gen
end
local function chosen(changes, expected)
	local action, id, reason = Surgery.choose(patient(changes), inv)
	assert(action == "use" and id == expected, tostring(expected) .. ": " .. tostring(reason))
end

task.spawn(function()
	reset()
	chosen({status = "Heart stopped", usable = {defib = true, sponge = true}, pool = 5}, 4312)
	chosen({pool = 4, usable = {sponge = true, transfusion = true}, pulse = "Weak"}, 1258)
	chosen({woozy = true, pool = 2, usable = {sponge = true}}, 1258)
	chosen({pulse = "Weak", usable = {transfusion = true, scalpel = true}}, 4310)
	chosen({bleed = 1, usable = {clamp = true}}, 4314)
	chosen({fever = 1, usable = {antibiotics = true}}, 1266)
	chosen({dirt = 2, usable = {antiseptic = true}}, 1264)
	chosen({status = "Coming to", usable = {anesthetic = true}}, 1262)
	chosen({diagnosis = false, usable = {ultrasound = true}}, 4316)
	chosen({diagnosis = false, usable = {labkit = true}}, 4318)
	chosen({bones = {1,0}, usable = {splint = true}}, 1268)
	chosen({bones = {0,1}, usable = {pins = true}}, 4308)
	chosen({need = 2, incisions = 1, usable = {scalpel = true}}, 1260)
	chosen({fixed = true, incisions = 1, usable = {stitches = true}}, 1270)
	chosen({fixed = true, incisions = 1, usable = {stitches = true, labkit = true, ultrasound = true}}, 1270)
	local action = Surgery.choose(patient({canFix = true}), inv)
	assert(action == "fix")
	action = Surgery.choose(patient({canFix = true, usable = {sponge = true}}), inv)
	assert(action ~= "fix", "respect native Fix It visibility condition")
	inv.stock[4312] = 0
	local _, _, reason = Surgery.choose(patient({status = "Heart stopped", usable = {defib = true, scalpel = true}}), inv)
	assert(reason:find("alat habis"), "do not skip a missing emergency tool")
	action = Surgery.choose(patient({status = "Heart stopped", usable = {scalpel = true}}), inv)
	assert(not action, "do not cut while the heart has stopped")
	action = Surgery.choose(patient({fixed = false, incisions = 1, usable = {stitches = true}}), inv)
	assert(not action, "do not close before repair")
	print("PASS condition priorities, diagnoses, bones, Fix It prerequisites and missing tools")

	local binding, gen = reset()
	W.fg[0] = {[1] = 4296, [3] = 8558, [9] = 4296}
	W.surgOn[1] = true
	assert(Surgery.nearest(binding).x == 3, "skip occupied and out-of-range robots")
	W.surgOn[1] = nil
	assert(Surgery.nearest(binding).x == 1)
	Surgery.running = false
	for _, x in ipairs({1,3}) do
		local train = x == 3
		queue[#queue+1] = {action = "peek", payload = {train = train, skill = 1}}
		queue[#queue+1] = {action = "start", payload = {state = patient({diagnosis = false, usable = {ultrasound = true}})}}
		queue[#queue+1] = {action = "use", arg = 4316, payload = {removed = not train and 4316 or nil,
			state = patient({usable = {scalpel = true}})}}
		queue[#queue+1] = {action = "use", arg = 1260, payload = {removed = not train and 1260 or nil,
			state = patient({incisions = 1, canFix = true})}}
		queue[#queue+1] = {action = "fix", payload = {state = patient({incisions = 1, fixed = true, usable = {stitches = true}})}}
		queue[#queue+1] = {action = "use", arg = 1270, payload = {removed = not train and 1270 or nil,
			add = not train and {{99,2}} or nil, state = patient({done = "won"})}, effect = function() W.fg[0][x] = nil end}
	end
	assert(Surgery.start())
	for _=1,250 do if Surgery.won == 2 then break end; task.wait(0.1) end
	assert(Surgery.won == 2 and Surgery.lost == 0 and #calls == 12 and #queue == 0)
	assert(inv:count(4316) == 9 and inv:count(1260) == 9 and inv:count(1270) == 9 and inv:count(99) == 2)
	assert(ups[nativeOpen][3] == 8558, "native dialog follows Train-E icon")
	assert(calls[2][2] == 1 and calls[8][2] == 3)
	assert(calls[4].time - calls[3].time >= 0.6, "pace actions")
	Surgery.stop()
	print("PASS two robots through actual worker, native requests, training inventory and rewards")

	binding, gen = reset()
	Surgery.stop()
	binding.render(patient({status = "Heart stopped", usable = {defib = true}}))
	assert(Surgery.state.status == "Heart stopped", "observer captures native manual operation")
	queue = {{action = "use", arg = 4312, payload = {removed = 4312, state = patient({done = "won"})}}}
	assert(Surgery.start())
	for _=1,50 do if Surgery.won == 1 then break end; task.wait(0.1) end
	assert(Surgery.won == 1 and #calls == 1 and inv:count(4312) == 9)
	Surgery.stop()
	print("PASS observed manual operation resumes without starting a second session")

	binding, gen = reset()
	Surgery.state = patient({status = "Heart stopped", usable = {defib = true}})
	queue = {{action = "use", arg = 4312, delay = 1, payload = {removed = 4312, state = patient({done = "won"})}}}
	task.spawn(function() task.wait(0.2); Surgery.stop("pause") end)
	Surgery.step(binding, gen)
	assert(not Surgery.running and Surgery.pending and ups[nativeOpen][1])
	assert(not Surgery.start(), "keep late request serialized after toggling off")
	task.wait(1)
	assert(not Surgery.pending and not ups[nativeOpen][1] and inv:count(4312) == 9 and #calls == 1)
	print("PASS Stop cancels future actions while applying its pending server result once")

	binding, gen = reset()
	queue = {{action = "use", delay = 13, payload = {removed = 1258, state = patient({pool = 0})}}}
	Surgery.state = patient({pool = 4, usable = {sponge = true}})
	Surgery.step(binding, gen)
	assert(not Surgery.running and Surgery.pending and #calls == 1)
	assert(not Surgery.start())
	task.wait(1.5)
	assert(not Surgery.pending and inv:count(1258) == 9 and #calls == 1)
	print("PASS timeout stops without replaying a possibly accepted tool request")

	binding, gen = reset()
	queue = {{action = "use", delay = 0.5, payload = {removed = 1258, state = patient({})}}}
	task.spawn(function() task.wait(0.1); W.fg = {} end)
	local before = rendered
	assert(not Surgery.request(binding, gen, "use", 1258))
	task.wait(0.6)
	assert(rendered == before and inv:count(1258) == 10, "old grid ACK must not alter a refreshed inventory or UI")
	assert(not Surgery.alive(gen, binding))
	local replacement = assert(Surgery.attach())
	assert(replacement ~= binding and Surgery.state == nil)
	print("PASS same-name world reload invalidates state and observer before resuming")

	binding, gen = reset()
	queue = {{action = "use", reject = "Tool unavailable"}}
	Surgery.state = patient({pool = 4, usable = {sponge = true}})
	Surgery.step(binding, gen)
	assert(not Surgery.running and Surgery.status == "Tool unavailable" and inv:count(1258) == 10)
	assert(not ups[nativeOpen][1] and not Surgery.pending)
	binding, gen = reset()
	Surgery.state = patient({done = "lost", why = "Too much blood loss", malpractice = false})
	Surgery.step(binding, gen)
	assert(not Surgery.running and Surgery.lost == 1 and #calls == 0)
	print("PASS server rejection and failed operations stop without repeated consumables")

	binding, gen = reset()
	Surgery.running = false; Factory.running = true
	assert(not Surgery.start() and #calls == 0)
	Factory.running = false
	Hub.recovery.read = function() return {world = "WAITING", guardCheck = true} end
	assert(not Surgery.start())
	Hub.recovery.read = function() return {} end
	picker = true; assert(not Surgery.start()); picker = false
	print("PASS active farming, guarded recovery and lobby block Auto Surgery startup")

	local control, paragraph
	local section = {}
	function section:Paragraph(config)
		paragraph = {text = config.Desc, SetDesc = function(self, value) self.text = value end}
		return paragraph
	end
	function section:Toggle(config)
		control = {Value = config.Value, Callback = config.Callback}
		function control:Set(value, fire)
			self.Value = value
			if fire ~= false then self.Callback(value) end
		end
		return control
	end
	local surgeryTab = {Section = function() return section end}
	-- INSERT SURGERY UI HERE
	Factory.running = true; control:Set(true)
	assert(not control.Value and paragraph.text:find("matikan auto farming"))
	Factory.running = false
	control:Set(true); assert(control.Value and Surgery.running)
	control:Set(false); assert(not control.Value and not Surgery.running)
	assert(#calls == 0)
	local captured = Surgery.state
	Surgery.detach(); render(patient({}))
	assert(Surgery.state == nil and captured == nil)
	for _, unload in ipairs(Hub.unload) do unload() end
	assert(not Surgery.running and not Surgery.binding and not ups[nativeOpen][1])
	print("PASS actual UI toggle, failed-start reset, silent sync and unload cleanup")
end)

local iterations = 0
while #jobs > 0 do
	iterations += 1; assert(iterations < 10000, "scheduler did not finish")
	table.sort(jobs, function(a,b) return a.at < b.at end)
	local job = table.remove(jobs, 1)
	clock = math.max(clock, job.at)
	local ok, delay = coroutine.resume(job.co)
	assert(ok, debug and tostring(delay))
	if coroutine.status(job.co) ~= "dead" then
		job.at = clock + (delay or 0.01)
		jobs[#jobs + 1] = job
	end
end
