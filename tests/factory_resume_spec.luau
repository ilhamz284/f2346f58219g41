-- Run the actual checkpoint-resume block with a simulated clock and world.
return function(make, makeGuard)
	local cases = {}
	local function run(options)
		options = options or {}
		local now, starts, refreshes, clearStarts = 0, 0, 0, 0
		local checkpoint = {
			mode = options.mode, guardCheck = options.guardCheck,
			clearWorld = options.clearWorld,
			world = "TEST", seedId = 4585, phase = "plant", attempts = 1,
			resumePNB = true, resumeCollect = true, expires = 1600,
		}
		local Hub, Factory = { dead = false }, { running = false }
		local Farm, PNB = { running = false }, { running = false }
		local Bind = { W = { name = "" } }
		local worker, resumed
		Hub.recovery = {
			read = function()
				if checkpoint and checkpoint.expires and checkpoint.expires > 1000 + now then
					return table.clone(checkpoint)
				end
			end,
			write = function(value) checkpoint = table.clone(value); return true end,
		}
		function Bind.resolve(force)
			assert(force, "bootstrap bindings must refresh even if the cached world is empty")
			refreshes += 1
			if now >= (options.readyAfter or 0) then
				Bind.W = { name = options.world or "TEST" }
			end
			return true
		end
		function Bind.state()
			return { active = Bind.W.name ~= "", grounded = true, dead = false }
		end
		make({
			Hub = Hub, Factory = Factory, Farm = Farm, PNB = PNB, Bind = Bind, _G = {},
			os = { clock = function() return now end, time = function() return 1000 + now end },
			task = {
				spawn = function(fn) assert(not worker); worker = fn end,
				wait = function()
					now += options.frameSeconds or 2
					assert(now < 1800, "resume worker failed to finish")
					if options.cancelAt and now >= options.cancelAt then checkpoint = nil end
					if options.unloadAt and now >= options.unloadAt then Hub.dead = true end
					if options.manualAt and now >= options.manualAt then Farm.running = true end
					if options.safeAt and now >= options.safeAt then checkpoint.guardCheck = nil end
				end,
			},
			worldPickerVisible = function() return now < (options.pickerUntil or 0) end,
			startFactory = function(saved)
				starts += 1
				assert(Factory.seedId == 4585 and Factory.cycle)
				if options.startError and starts == 1 then error("world still loading") end
				if options.startFails and starts == 1 then return false end
				resumed = table.clone(saved)
				Factory.running, Factory.phase = true, saved.phase
				return true
			end,
			startFarm = function() starts += 1; Farm.running = true end,
			startClearWorld = function() starts += 1; clearStarts += 1; Farm.running = true end,
			setFactoryStatus = function(message) Factory.status = message end,
			log = function() end,
		})
		assert(worker)
		worker()
		return { starts = starts, clearStarts = clearStarts, resumed = resumed, now = now, refreshes = refreshes,
			checkpoint = checkpoint, Factory = Factory }
	end
	local function case(name, body) body(); table.insert(cases, name) end
	case("world becomes ready after the previous 30-second retry window", function()
		local r = run({ readyAfter = 120 })
		assert(r.starts == 1 and r.now >= 120 and r.refreshes > 15)
	end)
	case("slow minimized frames keep the checkpoint alive beyond ten minutes", function()
		local r = run({ readyAfter = 1200, frameSeconds = 4 })
		assert(r.starts == 1 and r.now >= 1200 and r.checkpoint.expires > 1000 + r.now)
	end)
	case("resume retains the saved seed, phase, and pending work", function()
		local r = run()
		assert(r.resumed.seedId == 4585 and r.resumed.phase == "plant")
		assert(r.resumed.resumePNB and r.resumed.resumeCollect and r.Factory.cycle)
	end)
	case("world picker delays resume until the world is usable", function()
		local r = run({ pickerUntil = 90 })
		assert(r.starts == 1 and r.now >= 90)
	end)
	case("cancelled checkpoint prevents delayed restart", function()
		assert(run({ readyAfter = 120, cancelAt = 10 }).starts == 0)
	end)
	case("unloading or starting another farm cancels pending resume", function()
		assert(run({ readyAfter = 120, unloadAt = 10 }).starts == 0)
		assert(run({ readyAfter = 120, manualAt = 10 }).starts == 0)
	end)
	case("a different active world clears the old checkpoint", function()
		local r = run({ world = "OTHER" })
		assert(r.starts == 0 and r.checkpoint.world == nil)
	end)
	case("transient startup rejection and error both retry", function()
		assert(run({ startFails = true }).starts == 2)
		assert(run({ startError = true }).starts == 2)
	end)
	case("guard checkpoint waits for a safe player list before resuming", function()
		local r = run({ guardCheck = true, safeAt = 180 })
		assert(r.starts == 1 and r.now >= 180)
	end)
	case("Dirt Farm checkpoint restores farm and clears the completed checkpoint", function()
		local r = run({ mode = "dirt", guardCheck = true, safeAt = 180 })
		assert(r.starts == 1 and r.now >= 180 and r.checkpoint.world == nil)
	end)
	case("Clear World resumes its own mode after the guard declares the world safe", function()
		local r = run({ mode = "dirt", clearWorld = true, guardCheck = true, safeAt = 180 })
		assert(r.starts == 1 and r.clearStarts == 1 and r.now >= 180 and r.checkpoint.world == nil)
	end)
	local function preloadSetup()
		local env, tasks, delayed = {}, {}, {}
		local loads, callbackSeen, method = 0, nil, "PreloadAsync"
		local provider = {}
		local original = function(self, assets, callback)
			assert(self == provider and assets[1] == "image")
			loads += 1
			callbackSeen = callback
			return 42
		end
		provider.PreloadAsync = original
		local baseNamecall = function() return "other method" end
		local currentDot, currentNamecall = original, baseNamecall
		local context = {
			game = { GetService = function() return provider end },
			workspace = { CurrentCamera = { ViewportSize = { X = 1, Y = 1 } } },
			getgenv = function() return env end, _G = env,
			hookfunction = function(target, replacement)
				assert(target == original)
				currentDot = replacement
				return original
			end,
			restorefunction = function() currentDot = original end,
			hookmetamethod = function(_, name, replacement)
				assert(name == "__namecall")
				local previous = currentNamecall
				currentNamecall = replacement
				return previous
			end,
			getnamecallmethod = function() return method end,
			newcclosure = function(fn) return fn end,
			task = {
				defer = function(fn) table.insert(tasks, fn) end,
				delay = function(_, fn) table.insert(delayed, fn) end,
			},
		}
		local guard = makeGuard(context)
		return {
			guard = guard, context = context, env = env,
			dot = function(callback) return currentDot(provider, { "image" }, callback) end,
			namecall = function(name, callback)
				method = name
				return currentNamecall(provider, { "image" }, callback)
			end,
			flush = function() for _, fn in ipairs(tasks) do fn() end; table.clear(tasks) end,
			loads = function() return loads end,
			callback = function() return callbackSeen end,
			timeout = function() delayed[1]() end,
		}
	end
	case("minimized preload defers both dot calls and native namecalls", function()
		local t = preloadSetup()
		local callback = function() end
		t.dot(callback)
		t.namecall("PreloadAsync", callback)
		assert(t.loads() == 0 and t.guard.deferred == 2)
		t.flush()
		assert(t.loads() == 2 and t.callback() == callback)
	end)
	case("foreground preload and unrelated engine methods retain their results", function()
		local t = preloadSetup()
		t.context.workspace.CurrentCamera.ViewportSize = { X = 1280, Y = 720 }
		assert(t.dot() == 42 and t.namecall("PreloadAsync") == 42 and t.loads() == 2)
		assert(t.namecall("GetChildren") == "other method")
	end)
	case("preload guard avoids duplicate hooks and restores both entry points", function()
		local t = preloadSetup()
		assert(makeGuard(t.context) == t.guard)
		t.guard.restore()
		t.guard.restore()
		assert(t.env.__HumanHubPreloadGuard == nil and not t.guard.active)
		assert(t.dot() == 42 and t.namecall("PreloadAsync") == "other method")
	end)
	case("preload guard also restores on timeout and handles unsupported executors", function()
		local t = preloadSetup()
		t.timeout()
		assert(t.env.__HumanHubPreloadGuard == nil and t.dot() == 42)
		assert(makeGuard({ _G = {}, getgenv = nil, hookfunction = nil }) == nil)
	end)
	return { passed = #cases, cases = cases }
end
