--// ============================================================
--// Human Hub
--// Script hub dengan pergerakan seperti manusia (tanpa teleport/goTo).
--// Fitur #1 : Auto Dirt Farm - menggali lorong 1 block di atas lantai
--//            (foreground + cave background), menyisir map bolak-balik
--//            lalu turun satu lantai lewat poros di tepi, sampai jadi
--//            lantai bertingkat.
--//
--// Prinsip gerak:
--//   - semua gerak lewat keypress A/D + Space (VirtualInputManager)
--//   - tidak pernah memanggil world.goTo / teleport
--//   - ada waktu reaksi, jeda acak, dan micropause seperti orang main
--//   - berhenti dulu sebelum memukul tile, lalu lanjut jalan
--//
--// Catatan game (terverifikasi 2026):
--//   - fungsi hit/setTile dibuat obfuscate, jadi dicari lewat upvalue
--//     world (bukan lewat nama source).
--//   - Dirt (id 2) hancur dalam 2 pukulan.
--//   - kecepatan jalan game ~7 tile/detik; jangan dipaksa lebih.
--// ============================================================

--// ===== 0. STATE HUB & BERSIH-BERSIH =====
local Hub = {
	version = "0.1.0",
	conns = {},
	unload = {},
	ui = {},
}
local prev = _G.__HumanHub
if type(prev) == "table" and type(prev.shutdown) == "function" then
	pcall(prev.shutdown)
end
_G.__HumanHub = Hub

function Hub.keep(conn)
	table.insert(Hub.conns, conn)
	return conn
end

function Hub.onUnload(fn)
	table.insert(Hub.unload, fn)
end

function Hub.shutdown()
	for _, fn in ipairs(Hub.unload) do
		pcall(fn)
	end
	table.clear(Hub.unload)
	for _, c in ipairs(Hub.conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(Hub.conns)
end
_G.__HumanHubShutdown = Hub.shutdown

-- WindUI menaruh ScreenGui-nya di gethui() dan sisa run lama tidak terhapus.
local uiRoot = (gethui and gethui()) or game:GetService("CoreGui")
for _, c in ipairs(uiRoot:GetChildren()) do
	if c.Name == "WindUI" or c.Name:sub(1, 7) == "WindUI/" then
		pcall(function()
			c:Destroy()
		end)
	end
end
local localGui = game:GetService("Players").LocalPlayer and game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
for _, folder in ipairs({ game:GetService("CoreGui"), localGui }) do
	if folder and folder.GetChildren then
		for _, c in ipairs(folder:GetChildren()) do
			if c.Name == "WindUI" or c.Name == "Rayfield" or c.Name == "FluentUI" then
				pcall(function()
					c:Destroy()
				end)
			end
		end
	end
end

--// ===== 1. SERVICES & UTIL =====
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local VIM = game:GetService("VirtualInputManager")

local function rnd(a, b)
	return a + math.random() * (b - a)
end

local function log(msg)
	print("[HumanHub] " .. tostring(msg))
end

--// ===== 2. BINDING KE DALAM GAME =====
-- W = tabel world (fg/bg/name/w/h + goTo), CT = controller (state/solidAt),
-- hit = fungsi pukul tile milik game, setTile = fungsi pasang tile.
local Bind = { W = nil, CT = nil, hit = nil, setTile = nil, inv = nil, name = nil }

local function pickTable(matches, need)
	if type(matches) ~= "table" then
		return nil
	end
	if type(matches[1]) ~= "table" then
		matches = { matches }
	end
	for _, t in ipairs(matches) do
		if type(t) == "table" then
			local ok = true
			for _, k in ipairs(need) do
				if type(t[k]) ~= "function" then
					ok = false
					break
				end
			end
			if ok then
				return t
			end
		end
	end
	return nil
end

local function findFnByWorld(fname, world)
	local ok, list = pcall(filtergc, "function", { Name = fname }, false)
	if not ok or type(list) ~= "table" then
		return nil
	end
	for _, f in ipairs(list) do
		local okInfo, info = pcall(debug.getinfo, f)
		if okInfo and info then
			for i = 1, (info.nups or 0) do
				local okUp, v = pcall(debug.getupvalue, f, i)
				if okUp and v == world then
					return f
				end
			end
		end
	end
	return nil
end

function Bind.invalidate()
	Bind.W, Bind.CT, Bind.hit, Bind.setTile, Bind.inv, Bind.name = nil, nil, nil, nil, nil, nil
end

local function findInventory()
	local ok, list = pcall(filtergc, "table", { Keys = { "slots", "capacity", "changed" } }, false)
	if not ok or type(list) ~= "table" then
		return nil
	end
	if type(list[1]) ~= "table" then
		list = { list }
	end
	for _, t in ipairs(list) do
		if type(t) == "table" and type(t.slots) == "table" then
			return t
		end
	end
	return nil
end

function Bind.resolve(force)
	if not force and Bind.W and Bind.CT and Bind.hit and Bind.setTile then
		return true
	end

	local okW, worldList = pcall(filtergc, "table", { Keys = { "fg", "bg", "name", "w", "h" } }, false)
	if not okW then
		return false
	end
	local W = pickTable(worldList, { "goTo" })
	if not W then
		return false
	end

	local okC, ctList = pcall(filtergc, "table", { Keys = { "state", "onHurt", "onDie" } }, false)
	local CT = okC and pickTable(ctList, { "state", "solidAt" }) or nil

	local hit = findFnByWorld("hit", W)
	local setTile = findFnByWorld("setTile", W)
	local inv = findInventory()

	Bind.W, Bind.CT, Bind.hit, Bind.setTile, Bind.inv, Bind.name = W, CT, hit, setTile, inv, W.name
	log(string.format("bind world=%s %sx%s hit=%s setTile=%s inv=%s", tostring(W.name), tostring(W.w), tostring(W.h),
		hit and "ok" or "NIL", setTile and "ok" or "NIL", inv and "ok" or "NIL"))
	return W ~= nil and CT ~= nil and hit ~= nil
end

function Bind.getW()
	if not Bind.W then
		Bind.resolve()
	end
	return Bind.W
end

function Bind.state()
	if not Bind.CT then
		Bind.resolve()
	end
	if not Bind.CT or type(Bind.CT.state) ~= "function" then
		return nil
	end
	local ok, s = pcall(Bind.CT.state)
	if ok and type(s) == "table" then
		return s
	end
	return nil
end

function Bind.solid(x, y)
	local W = Bind.getW()
	if not W then
		return false
	end
	if Bind.CT and type(Bind.CT.solidAt) == "function" then
		local ok, v = pcall(Bind.CT.solidAt, x, y)
		if ok then
			return v == true
		end
	end
	local row = W.fg and W.fg[y]
	local id = row and row[x] or 0
	if id == 0 then
		return false
	end
	-- id solid yang umum di game ini
	return id == 2 or id == 6 or id == 8 or id == 4 or id == 10
end

--// ===== 3. GERAK MANUSIA =====
local Move = {
	held = nil,
	gen = 0,
	cfg = {
		reactMin = 0.07,
		reactMax = 0.18,
		pauseChance = 0.14,
		pauseMin = 0.08,
		pauseMax = 0.28,
	},
}

local KeyLeft = Enum.KeyCode.A
local KeyRight = Enum.KeyCode.D

local function vkey(down, kc)
	if not VIM or not kc then
		return
	end
	pcall(function()
		VIM:SendKeyEvent(down, kc, false, game)
	end)
end

function Move.release()
	if Move.held then
		vkey(false, Move.held)
		Move.held = nil
	end
end

function Move.hold(kc)
	if Move.held == kc then
		return
	end
	Move.release()
	Move.held = kc
	vkey(true, kc)
end

function Move.jump()
	vkey(true, Enum.KeyCode.Space)
	task.delay(rnd(0.05, 0.11), function()
		vkey(false, Enum.KeyCode.Space)
	end)
end

function Move.idle(a, b)
	task.wait(rnd(a, b))
end

-- Jeda kecil acak: tombol dilepas sebentar lalu ditekan lagi. Ini yang
-- membuat jalannya tidak terlihat seperti mesin (konstan, presisi frame).
function Move.microPause()
	if Move.held and math.random() < Move.cfg.pauseChance then
		local was = Move.held
		Move.release()
		Move.idle(Move.cfg.pauseMin, Move.cfg.pauseMax)
		Move.hold(was)
		return true
	end
	return false
end

function Move.stop()
	Move.gen += 1
	Move.release()
end

-- Jalan ke target X. Return true kalau berhenti di dekat target.
function Move.walkTo(targetX, opts)
	opts = opts or {}
	local tol = opts.tol or 0.14
	local deadline = os.clock() + (opts.timeout or 25)
	local myGen = Move.gen
	local lastX, lastT = nil, os.clock()

	Move.idle(Move.cfg.reactMin, Move.cfg.reactMax)

	while Move.gen == myGen and os.clock() < deadline do
		local s = Bind.state()
		if not s then
			break
		end
		local dx = targetX - s.x
		if math.abs(dx) <= tol then
			Move.release()
			Move.idle(0.06, 0.16)
			return true
		end

		local key = dx > 0 and KeyRight or KeyLeft
		Move.hold(key)

		-- poll pendek: berhenti sebelum overshoot (game tidak punya inertia,
		-- tapi event key punya latency ~1-2 frame)
		local tEnd = os.clock() + 0.07
		while os.clock() < tEnd and Move.gen == myGen do
			local s2 = Bind.state()
			if not s2 then
				break
			end
			if (dx > 0 and s2.x >= targetX - tol) or (dx < 0 and s2.x <= targetX + tol) then
				break
			end
			task.wait(0.02)
		end

		-- tidak maju sama sekali -> jangan diam sampai timeout
		local s3 = Bind.state()
		if s3 then
			if not lastX or math.abs(s3.x - lastX) >= 0.05 then
				lastX = s3.x
				lastT = os.clock()
			elseif os.clock() - lastT > 1.6 then
				Move.release()
				return false
			end
		end

		Move.microPause()
	end

	Move.release()
	return false
end

--// ===== 4. PUKUL / GALI TILE =====
-- Tabel Farm dideklarasikan lebih dulu karena Dig memakai Farm.breakBg.
local Farm = {
	running = false,
	gen = 0,
	spacing = 2, -- 1 baris lantai + 1 baris lorong (1 block)
	digDelay = 0.14,
	breakBg = true, -- ikut menghancurkan cave background
	patchLava = true, -- lava di lantai dihancurkan lalu diganti dirt
	status = "idle",
	onStatus = nil,
}
local Dig = { protectedIds = { [6] = true, [8] = true, [202] = true, [204] = true, [206] = true, [240] = true, [242] = true, [1796] = true, [7188] = true, [9640] = true } }

function Dig.isProtected(id, x, y)
	if not id or id == 0 then
		return true
	end
	if Dig.protectedIds[id] then
		return true
	end
	local W = Bind.getW()
	if W and type(W.lock) == "table" and W.lock.x == x and W.lock.y == y then
		return true
	end
	return false
end

-- Pukul satu tile satu kali. Return true kalau panggilan game berhasil.
function Dig.punch(x, y, isTree, skipAim, allowLava)
	local W = Bind.getW()
	if not W or not Bind.hit then
		return false
	end
	local maxX = (tonumber(W.w) or 100) - 1
	local maxY = (tonumber(W.h) or 60) - 1
	if x < 0 or y < 0 or x > maxX or y > maxY then
		return false
	end
	local row = W.fg and W.fg[y]
	local fg = row and row[x] or 0
	if fg ~= 0 then
		if Dig.isProtected(fg, x, y) then
			return false
		end
		-- lava: hanya boleh kalau memang diminta (poros / lorong)
		if fg == 4 and not allowLava then
			return false
		end
	else
		-- foreground sudah kosong: yang tersisa cave background
		local bg = W.bg and W.bg[y] and W.bg[y][x] or 0
		if bg == 0 or not Farm.breakBg then
			return true
		end
		if Dig.isProtected(bg, x, y) then
			return false
		end
	end

	-- arah hadap, biar animasi & hit valid
	local s = Bind.state()
	if s and s.x then
		pcall(function()
			s.facing = (x >= s.x) and 1 or -1
		end)
	end

	-- pegang Fist (18) saat memukul blok; Place.dirt memilih dirt (2)
	if not isTree and Bind.inv and Bind.inv.selected ~= 18 and Bind.inv.select then
		pcall(Bind.inv.select, Bind.inv, 18)
	end

	-- hormati cooldown pukul milik game
	local now = os.clock()
	if type(W.punchReady) == "number" and now < W.punchReady then
		task.wait(math.min(0.28, W.punchReady - now))
	end

	-- "membidik" sebentar sebelum pukulan pertama
	if not skipAim then
		Move.idle(0.03, 0.08)
	end

	local ok = pcall(Bind.hit, x, y, isTree == true)
	W.punchReady = os.clock() + rnd(0.21, 0.24)
	return ok
end

-- Gali tile sampai hancur (foreground + cave background).
-- opts.allowLava = true -> lava boleh dihancurkan (dipakai untuk poros & lorong).
function Dig.tile(x, y, maxHits, delay, opts)
	opts = opts or {}
	local W = Bind.getW()
	if not W then
		return false
	end
	maxHits = maxHits or 8
	delay = delay or 0.18
	for i = 1, maxHits do
		local fg = W.fg and W.fg[y] and W.fg[y][x] or 0
		local bg = W.bg and W.bg[y] and W.bg[y][x] or 0
		if fg ~= 0 then
			if Dig.isProtected(fg, x, y) then
				return false
			end
			if fg == 4 and not opts.allowLava then
				return false
			end
		elseif bg ~= 0 then
			if not Farm.breakBg or Dig.isProtected(bg, x, y) then
				return true
			end
		else
			return true
		end
		Dig.punch(x, y, false, i > 1, opts.allowLava)
		-- cooldown utama sudah ditangani punchReady di Dig.punch; ini
		-- cuma napas kecil supaya tidak 100% presisi mesin
		task.wait(delay * 0.35 + rnd(0, 0.02))
	end
	local fgEnd = W.fg and W.fg[y] and W.fg[y][x] or 0
	local bgEnd = W.bg and W.bg[y] and W.bg[y][x] or 0
	return fgEnd == 0 and (not Farm.breakBg or bgEnd == 0 or Dig.isProtected(bgEnd, x, y))
end

-- Pasang dirt (id 2) dari inventory. Dipakai untuk mengganti lava / menambal lantai.
local Place = {}

function Place.dirtCount()
	local inv = Bind.inv or findInventory()
	Bind.inv = inv
	if not (inv and inv.count) then
		return 0
	end
	local ok, n = pcall(inv.count, inv, 2)
	return ok and (tonumber(n) or 0) or 0
end

function Place.dirt(x, y)
	local W = Bind.getW()
	if not W or not Bind.setTile then
		return false
	end
	local cur = (W.fg[y] and W.fg[y][x]) or 0
	if cur == 2 then
		return true
	end
	if cur ~= 0 then
		return false
	end
	local maxX = (tonumber(W.w) or 100) - 1
	local maxY = (tonumber(W.h) or 60) - 1
	if x < 0 or y < 0 or x > maxX or y > maxY then
		return false
	end
	if not Bind.inv then
		Bind.inv = findInventory()
	end
	if Place.dirtCount() <= 0 then
		return false
	end
	if Bind.inv.select then
		pcall(Bind.inv.select, Bind.inv, 2)
	end
	local ok = pcall(Bind.setTile, "fg", x, y, 2, false, false)
	if not ok then
		return false
	end
	if Bind.inv.remove then
		pcall(Bind.inv.remove, Bind.inv, 2, 1)
	end
	W.punchReady = os.clock() + 0.15
	task.wait(rnd(0.1, 0.18))
	return ((W.fg[y] and W.fg[y][x]) or 0) == 2
end

--// ===== 5. AUTO DIRT FARM (LANTAI BERTINGKAT) =====
-- Tabel Farm ada di atas (sebelum Dig) karena Dig memakai Farm.breakBg.

local function setStatus(text)
	Farm.status = text
	if Farm.onStatus then
		pcall(Farm.onStatus, text)
	end
end

local function standingFloor(state)
	-- y pemain saat berdiri ~ tile+1 (mis. 36.999 = body 36, lantai 37)
	if not state then
		return nil
	end
	return math.floor(state.y - 0.0001) + 1
end

local function corridorRows(floorY, spacing)
	local rows = {}
	for dy = -(spacing - 1), -1 do
		table.insert(rows, floorY + dy)
	end
	return rows
end

local function tileId(x, y)
	local W = Bind.getW()
	return (W and W.fg and W.fg[y] and W.fg[y][x]) or 0
end

local function bgId(x, y)
	local W = Bind.getW()
	return (W and W.bg and W.bg[y] and W.bg[y][x]) or 0
end

local function needsDig(x, y)
	local id = tileId(x, y)
	if id ~= 0 then
		if Dig.isProtected(id, x, y) then
			return false
		end
		-- termasuk lava: lava di lorong juga harus dibersihkan
		return true
	end
	-- foreground kosong: cave background juga harus dibersihkan
	local bg = bgId(x, y)
	if bg ~= 0 and Farm.breakBg and not Dig.isProtected(bg, x, y) then
		return true
	end
	return false
end

local function rowNeedsDig(floorY, spacing)
	for x = 1, 98 do
		for _, y in ipairs(corridorRows(floorY, spacing)) do
			if needsDig(x, y) then
				return true
			end
		end
	end
	return false
end

local function alive(gen)
	return Farm.running and Farm.gen == gen
end

-- Menyisir satu lantai dari tepi ke tepi sambil menggali.
local function sweepFloor(floorY, dir, gen)
	local W = Bind.getW()
	if not W then
		return false
	end
	local rows = corridorRows(floorY, Farm.spacing)
	local endX = dir > 0 and 97.2 or 1.8
	local lastX, stuck = nil, 0
	local lastProgressAt = os.clock()
	local lastPatchT = 0

	Move.idle(0.18, 0.45) -- "menghela napas" sebelum mulai

	while alive(gen) do
		local s = Bind.state()
		if not s then
			break
		end
		if (dir > 0 and s.x >= endX) or (dir < 0 and s.x <= endX) then
			break
		end

		local bx = math.floor(s.x)
		local worked = false

		-- Lantai 1 langkah di depan: lava dihancurkan lalu diganti dirt,
		-- lubang ditambal supaya bot tidak jatuh.
		local aheadX = bx + dir
		if aheadX >= 1 and aheadX <= 98 then
			local floorId = tileId(aheadX, floorY)
			if floorId == 4 then
				Move.release()
				Move.idle(0.04, 0.10)
				Dig.tile(aheadX, floorY, 8, Farm.digDelay, { allowLava = true })
				if Farm.patchLava then
					if not Place.dirt(aheadX, floorY) then
						setStatus("berhenti: lava tidak bisa diganti dirt (stok habis / jangkauan)")
						Farm.running = false
						return false
					end
				end
				Move.idle(0.04, 0.10)
			elseif floorId == 0 and Farm.patchLava then
				if os.clock() - lastPatchT > 0.6 then
					lastPatchT = os.clock()
					Move.release()
					if not Place.dirt(aheadX, floorY) then
						setStatus("berhenti: lubang lantai tidak bisa ditambal (stok dirt habis)")
						Farm.running = false
						return false
					end
				end
			end
		end

		-- lihat 2 tile ke depan; kalau ada tanah, berhenti & gali dulu
		for step = 1, 2 do
			local tx = bx + step * dir
			if tx < 1 or tx > 98 then
				break
			end
			local need = false
			for _, ty in ipairs(rows) do
				if needsDig(tx, ty) then
					need = true
					break
				end
			end
			if need then
				worked = true
				Move.release()
				Move.idle(0.03, 0.07)
				for _, ty in ipairs(rows) do
					if not alive(gen) then
						break
					end
					if needsDig(tx, ty) then
						Dig.tile(tx, ty, 8, Farm.digDelay, { allowLava = true })
					end
				end
				Move.idle(0.02, 0.06)
				break
			end
		end

		if not worked then
			Move.hold(dir > 0 and KeyRight or KeyLeft)
			Move.microPause()
		end

		-- deteksi macet: posisi tidak berubah cukup lama (bisa karena blok
		-- terkunci di depan, bukan karena sedang menggali)
		if not lastX then
			lastX = s.x
			lastProgressAt = os.clock()
		elseif math.abs(s.x - lastX) >= 0.05 then
			lastX = s.x
			lastProgressAt = os.clock()
			stuck = 0
		else
			stuck += 1
		end
		if stuck > 16 or os.clock() - lastProgressAt > 4.5 then
			setStatus("berhenti: jalan terhalang blok yang tidak bisa digali")
			break
		end

		task.wait(0.03)
	end

	Move.release()

	-- rapikan kolom tepi (poros) supaya jalur turun bersih
	local corner = dir > 0 and 99 or 0
	for _, ty in ipairs(rows) do
		if not alive(gen) then
			break
		end
		if needsDig(corner, ty) then
			Dig.tile(corner, ty, 8, Farm.digDelay, { allowLava = true })
		end
	end

	return alive(gen)
end

-- Turun satu lantai lewat poros di tepi.
local function descendTo(fromFloorY, toFloorY, corner, gen)
	local W = Bind.getW()
	if not W then
		return false
	end

	-- 0. pilih kolom poros. Prioritas: tepi yang diminta -> tepi seberang ->
	--    geser masuk (pilihan terakhir). Jadi bot tetap turun di ujung world
	--    kalau ujung itu masih memungkinkan.
	local inward = corner > 50 and -1 or 1
	local worldW = tonumber(W.w) or 100
	local function columnOk(cx)
		if cx < 0 or cx > worldW - 1 then
			return false
		end
		local landId = tileId(cx, toFloorY)
		if landId == 0 or landId == 4 then
			return false
		end
		for y = fromFloorY, toFloorY - 1 do
			local id = tileId(cx, y)
			if id ~= 0 and Dig.isProtected(id, cx, y) then
				return false
			end
		end
		return true
	end

	local candidates = { corner, (corner == 0) and (worldW - 1) or 0 }
	for d = 1, 6 do
		table.insert(candidates, corner + inward * d)
	end

	local col
	for _, cx in ipairs(candidates) do
		if columnOk(cx) then
			col = cx
			break
		end
	end
	if not col then
		return false, nil
	end

	-- 1. JALAN dulu ke kolom poros. Menggali dari jauh tidak akan kena
	--    (tile di luar jangkauan / tertutup tile lain).
	local targetX = col + 0.5
	Move.gen += 1
	Move.walkTo(targetX, { timeout = 22, tol = 0.5 })
	if not alive(gen) then
		return false
	end

	-- 2. gali poros dari atas ke bawah, satu tile demi satu. Tile di bawah
	--    baru bisa dipukul setelah tile di atasnya hancur.
	for y = fromFloorY, toFloorY - 1 do
		if not alive(gen) then
			return false
		end
		local id = tileId(col, y)
		if id ~= 0 then
			Dig.tile(col, y, 8, Farm.digDelay, { allowLava = true })
		end
		task.wait(rnd(0.08, 0.16))
	end

	-- 3. kalau belum jatuh (poros di sisi, bukan di bawah kaki),
	--    melangkah masuk ke lubang
	local sNow = Bind.state()
	local fyNow = sNow and standingFloor(sNow)
	if fyNow and fyNow < toFloorY then
		local key = col > 50 and KeyRight or KeyLeft
		Move.hold(key)
		local deadline = os.clock() + 12
		local lastX, lastT = nil, os.clock()
		while alive(gen) and os.clock() < deadline do
			local s = Bind.state()
			if not s then
				break
			end
			local fy = standingFloor(s)
			if fy and fy >= toFloorY and s.grounded then
				break
			end
			if not lastX or math.abs(s.x - lastX) >= 0.05 then
				lastX = s.x
				lastT = os.clock()
			elseif os.clock() - lastT > 2.5 then
				Move.release()
				return false
			end
			task.wait(0.04)
		end
		Move.release()
	end

	Move.idle(0.18, 0.40)
	local sEnd = Bind.state()
	local fyEnd = sEnd and standingFloor(sEnd)
	return fyEnd ~= nil and fyEnd >= toFloorY, col
end

local function startFarm()
	if Farm.running then
		return
	end
	Bind.resolve(true)
	if not Bind.W or not Bind.CT or not Bind.hit then
		setStatus("gagal: binding game tidak lengkap (coba rejoin lalu jalankan ulang)")
		return
	end

	local s = Bind.state()
	if not s then
		setStatus("gagal: state pemain tidak terbaca")
		return
	end

	local baseFloor = standingFloor(s)
	if not baseFloor or not Bind.solid(math.floor(s.x), baseFloor) then
		setStatus("gagal: karakter tidak berdiri di atas lantai")
		return
	end

	local spacing = math.clamp(math.floor(Farm.spacing), 2, 6)
	Farm.spacing = spacing

	local floors = {}
	local maxFloor = (tonumber(Bind.W.h) or 60) - 1
	for fy = baseFloor + spacing, maxFloor, spacing do
		table.insert(floors, fy)
		if #floors >= 40 then
			break
		end
	end

	if #floors == 0 then
		setStatus("tidak ada lantai yang bisa dibuat (sudah terlalu dalam)")
		return
	end

	Farm.running = true
	Farm.gen += 1
	local gen = Farm.gen

	-- pilih tepi terdekat supaya jalur turun pertama pendek (dan tidak
	-- menyeberangi lubang yang jauh)
	local worldW = tonumber(Bind.W.w) or 100
	local startDir = (s.x < worldW / 2) and -1 or 1
	setStatus(string.format("mulai: seluruh world (%d lantai, jarak %d)", #floors, spacing))
	log(string.format("farm start floor=%d dir=%d floors=%s", baseFloor, startDir, table.concat(floors, ",")))

	task.spawn(function()
		local curFloor = baseFloor
		local corner = startDir > 0 and 99 or 0
		local dir = startDir

		local okDown, firstCol = descendTo(curFloor, floors[1], corner, gen)
		if not okDown or not alive(gen) then
			Farm.running = false
			setStatus("berhenti: tidak bisa turun ke lantai pertama (dasar/bedrock)")
			return
		end
		curFloor = floors[1]
		local midW = (tonumber(Bind.W.w) or 100) / 2
		dir = (firstCol and firstCol > midW) and -1 or 1

		for idx, floorY in ipairs(floors) do
			if not alive(gen) then
				return
			end

			local passes = 0
			repeat
				setStatus(string.format("lantai %d/%d (Y=%d) - menyisir %s", idx, #floors, floorY,
					dir > 0 and "ke kanan" or "ke kiri"))
				sweepFloor(floorY, dir, gen)
				if not alive(gen) then
					return
				end
				passes += 1
				if rowNeedsDig(floorY, Farm.spacing) then
					if passes >= 4 then
						setStatus(string.format("lantai Y=%d terhalang, lanjut lantai berikutnya", floorY))
						break
					end
					dir = -dir
				else
					break
				end
			until false

			if idx < #floors then
				-- setelah menyisir, posisi ada di ujung; poros di ujung itu
				local sNow = Bind.state()
				if sNow then
					corner = (sNow.x > 50) and 99 or 0
				end

				setStatus(string.format("turun ke lantai %d/%d (Y=%d)", idx + 1, #floors, floors[idx + 1]))
				local ok, newCol = descendTo(floorY, floors[idx + 1], corner, gen)
				if not ok or not alive(gen) then
					Farm.running = false
					setStatus("berhenti: tidak bisa turun lagi (dasar/bedrock)")
					return
				end
				curFloor = floors[idx + 1]
				local midW2 = (tonumber(Bind.W.w) or 100) / 2
				dir = (newCol and newCol > midW2) and -1 or 1
			end
		end

		Farm.running = false
		Move.release()
		setStatus("selesai - semua lantai selesai digali")
	end)
end

function Farm.stop(reason)
	if not Farm.running then
		Move.release()
		return
	end
	Farm.running = false
	Farm.gen += 1
	Move.gen += 1
	Move.release()
	setStatus(reason or "dihentikan")
end

--// ===== 6. UI (WindUI) =====
local okLoad, WindUI = pcall(function()
	return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
end)
if not okLoad or not WindUI then
	warn("[HumanHub] gagal memuat WindUI: " .. tostring(WindUI))
	return
end

local Window = WindUI:CreateWindow({
	Title = "Human Hub",
	Author = "gerak seperti manusia - fitur #1: dirt farm",
	Icon = "person-standing",
	Size = UDim2.fromOffset(560, 460),
	Theme = "Dark",
	ToggleKey = Enum.KeyCode.RightShift,
})
Hub.Window = Window

local farmTab = Window:Tab({ Title = "Dirt Farm", Icon = "pickaxe" })
local moveTab = Window:Tab({ Title = "Gerak", Icon = "footprints" })
local infoTab = Window:Tab({ Title = "Info", Icon = "info" })

-- ---- Tab Dirt Farm ----
local farmSec = farmTab:Section({ Title = "Auto Dirt Farm", Opened = true })
local statusPara
local farmToggle

farmToggle = farmSec:Toggle({
	Title = "Auto Dirt Farm",
	Desc = "Menggali lorong 1 block di atas lantai (termasuk cave background), menyisir bolak-balik, lalu turun lewat poros tepi.",
	Value = false,
	Callback = function(on)
		if on then
			startFarm()
			if not Farm.running then
				if farmToggle and farmToggle.Set then
					pcall(farmToggle.Set, farmToggle, false)
				end
			end
		else
			Farm.stop("dimatikan dari toggle")
		end
	end,
})

farmSec:Toggle({
	Title = "Break cave background",
	Desc = "Bersihkan lapisan cave di belakang tanah. Matikan kalau mau lebih cepat (lorong tetap 1 block).",
	Value = true,
	Callback = function(on)
		Farm.breakBg = on
	end,
})

farmSec:Toggle({
	Title = "Ganti lava dengan dirt",
	Desc = "Lava di lantai yang dilewati dihancurkan lalu dipasangi dirt (butuh stok dirt).",
	Value = true,
	Callback = function(on)
		Farm.patchLava = on
	end,
})

farmSec:Slider({
	Title = "Jarak antar lantai (tile)",
	Desc = "2 = lorong 1 block + 1 baris lantai (paling rapat, sesuai permintaan).",
	Value = { Min = 2, Max = 6, Default = 2 },
	Step = 1,
	Callback = function(v)
		Farm.spacing = v
	end,
})

farmSec:Paragraph({
	Title = "Mode",
	Desc = "Otomatis menyisir SELURUH world sampai tidak bisa dibuat lantai lagi (dasar / bedrock). Tidak perlu mengatur jumlah lantai.",
})

farmSec:Slider({
	Title = "Jeda pukulan (detik)",
	Desc = "Jeda napas kecil setelah tiap pukulan. Cooldown utama tetap dari game.",
	Value = { Min = 0.08, Max = 0.35, Default = 0.14 },
	Step = 0.01,
	Callback = function(v)
		Farm.digDelay = v
	end,
})

statusPara = farmSec:Paragraph({
	Title = "Status",
	Desc = "idle",
})

farmSec:Button({
	Title = "Stop & lepas semua tombol",
	Desc = "Menghentikan bot dan memastikan A/D/Space tidak tertahan.",
	Callback = function()
		Farm.stop("dihentikan manual")
		if farmToggle and farmToggle.Set then
			pcall(farmToggle.Set, farmToggle, false)
		end
		WindUI:Notify({ Title = "Human Hub", Content = "Bot dihentikan, tombol dilepas.", Duration = 3 })
	end,
})

Farm.onStatus = function(text)
	if statusPara then
		if statusPara.SetDesc then
			pcall(statusPara.SetDesc, statusPara, text)
		elseif statusPara.SetTitle then
			pcall(statusPara.SetTitle, statusPara, "Status: " .. text)
		end
	end
end

-- ---- Tab Gerak ----
local moveSec = moveTab:Section({ Title = "Pengaturan Gerak Manusia", Opened = true })

moveSec:Slider({
	Title = "Waktu reaksi (detik)",
	Desc = "Jeda sebelum mulai bergerak, meniru waktu reaksi tangan.",
	Value = { Min = 0.03, Max = 0.35, Default = 0.12 },
	Step = 0.01,
	Callback = function(v)
		Move.cfg.reactMin = math.max(0.02, v - 0.03)
		Move.cfg.reactMax = v + 0.04
	end,
})

moveSec:Slider({
	Title = "Peluang jeda saat jalan (%)",
	Desc = "Semakin besar, semakin sering tombol dilepas sebentar (jalan jadi tidak kaku).",
	Value = { Min = 0, Max = 40, Default = 14 },
	Step = 1,
	Callback = function(v)
		Move.cfg.pauseChance = v / 100
	end,
})

moveSec:Slider({
	Title = "Lama jeda (detik)",
	Desc = "Durasi micropause saat jalan.",
	Value = { Min = 0.04, Max = 0.45, Default = 0.14 },
	Step = 0.01,
	Callback = function(v)
		Move.cfg.pauseMin = math.max(0.03, v * 0.7)
		Move.cfg.pauseMax = v + 0.06
	end,
})

local function testWalk(dir)
	if Farm.running then
		WindUI:Notify({ Title = "Gerak", Content = "Matikan Auto Dirt Farm dulu.", Duration = 3 })
		return
	end
	local s = Bind.state()
	if not s then
		WindUI:Notify({ Title = "Gerak", Content = "State pemain tidak terbaca.", Duration = 3 })
		return
	end
	local target = math.clamp(math.floor(s.x) + dir * 5, 1, 98)
	task.spawn(function()
		Move.gen += 1
		local ok = Move.walkTo(target, { timeout = 6 })
		WindUI:Notify({
			Title = "Gerak",
			Content = ok and string.format("Sampai di x=%d", target) or "Berhenti (terhalang / timeout)",
			Duration = 3,
		})
	end)
end

moveSec:Button({
	Title = "Tes jalan ke kanan 5 tile",
	Callback = function()
		testWalk(1)
	end,
})

moveSec:Button({
	Title = "Tes jalan ke kiri 5 tile",
	Callback = function()
		testWalk(-1)
	end,
})

moveSec:Paragraph({
	Title = "Cara kerja",
	Desc = "Semua gerak memakai keypress A/D dan Space. Tidak ada goTo/teleport. Bot berhenti dulu sebelum memukul, lalu jalan lagi. Jeda dan waktu reaksi diacak supaya tidak polanya tetap.",
})

-- ---- Tab Info ----
infoTab:Section({ Title = "Fitur", Opened = true }):Paragraph({
	Title = "Sudah ada",
	Desc = "1) Auto Dirt Farm: menyisir seluruh world, menggali lorong 1 block (foreground + cave background), turun lewat poros tepi sampai tidak bisa digali lagi, dan mengganti lava di lantai dengan dirt.",
})

infoTab:Section({ Title = "Keamanan", Opened = true }):Paragraph({
	Title = "Tanpa teleport",
	Desc = "Kecepatan gerak mengikuti jalan normal game (~7 tile/detik). Kalau tombol tertahan, tekan tombol Stop atau RightShift untuk menutup menu lalu jalankan ulang.",
})

infoTab:Section({ Title = "Catatan", Opened = true }):Paragraph({
	Title = "Lava & blok terkunci",
	Desc = "Tile lava (id 4), Bedrock, pintu, dan lock dilewati - tidak digali.",
})

log("loaded v" .. Hub.version)
-- WindUI tidak auto-pilih tab: tanpa ini panel isi kelihatan kosong.
if farmTab.Select then
	pcall(farmTab.Select, farmTab)
end
WindUI:Notify({ Title = "Human Hub", Content = "Siap. Buka tab Dirt Farm.", Duration = 4 })

Hub.debug = {
	Bind = Bind,
	Move = Move,
	Farm = Farm,
	Dig = Dig,
	Place = Place,
	startFarm = startFarm,
	sweepFloor = sweepFloor,
	descendTo = descendTo,
	rowNeedsDig = rowNeedsDig,
}

--// ===== 7. HEARTBEAT / PENJAGA =====
-- kalau karakter hilang (respawn / keluar world), hentikan bot supaya
-- tidak menekan tombol terus tanpa tujuan.
Hub.keep(RunService.Heartbeat:Connect(function()
	if not Farm.running then
		return
	end
	local s = Bind.state()
	if not s then
		Farm.stop("state hilang (respawn / pindah world)")
	end
end))

Hub.onUnload(function()
	Farm.running = false
	Farm.gen += 1
	Move.release()
end)
