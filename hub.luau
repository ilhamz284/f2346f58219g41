--// ============================================================
--// Human Hub
--// Script hub dengan gerak tombol A/D dan Space untuk lintas lantai.
--// Fitur #1 : Auto Dirt Farm - menggali lorong 1 block di atas lantai
--//            (foreground + cave background), menyisir map bolak-balik
--//            lalu turun satu lantai lewat poros di tepi, sampai jadi
--//            lantai bertingkat.
--// Fitur #2 : PNB (Place and Break): blok solid di depan pemain,
--//            background dan blok non-solid pada tile pemain, dengan Auto Collect.
--// Fitur #3 : Auto Harvest / Auto Plant dengan seed pilihan dari inventory.
--// Fitur #4 : Auto Factory: panen sampai blok penuh / tree habis,
--//            PNB sampai blok habis, tanam sampai seed habis.
--//
--// Prinsip gerak:
--//   - PC: keypress A/D + Space (VirtualInputManager)
--//   - Android: tombol MobileGui bawaan game (Left/Right/Jump) karena
--//     SendKeyEvent tidak selalu diteruskan executor mobile
--//   - karakter yang terjepit di tepi/pojok world dilepas otomatis lalu
--//     path dihitung ulang, tidak langsung menyerah
--//   - factory berjalan ke poros, jatuh, atau melompat dengan input game
--//   - jalan lurus tetap mulus; jeda hanya saat berganti aksi
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
	version = "0.4.62",
	conns = {},
	unload = {},
	ui = {},
	remote = false,
	bus = nil,
	dead = false,
}
local HUB_TOKEN = tostring(math.floor(os.clock() * 1000)) .. "_" .. tostring(math.random(100000, 999999))

--// ===== 0a. HENTIKAN INSTANCE LAMA =====
-- Di Android (Delta) setiap Execute bisa punya _G sendiri, jadi run lama
-- tidak ketemu lewat _G dan tetap hidup: window jadi dobel dan dua thread
-- berebut menggerakkan karakter. Instance didaftarkan di semua kanal global
-- yang biasa dipakai executor, ditambah sinyal BindableEvent yang bertahan
-- antar-execute karena berupa Instance.
local function uiContainer()
	local ok, hui = pcall(function()
		return gethui and gethui() or nil
	end)
	if ok and hui then
		return hui
	end
	local lp = game:GetService("Players").LocalPlayer
	return lp and lp:FindFirstChild("PlayerGui") or nil
end

local function hubGlobals()
	local list = {}
	list[#list + 1] = _G
	local okEnv, env = pcall(function()
		return getgenv and getgenv() or nil
	end)
	if okEnv and type(env) == "table" and env ~= _G then
		list[#list + 1] = env
	end
	local okShared, sh = pcall(function()
		return shared
	end)
	if okShared and type(sh) == "table" and sh ~= _G and sh ~= env then
		list[#list + 1] = sh
	end
	return list
end

local function findHubBus()
	local root = uiContainer()
	if not root then
		return nil
	end
	local bus = root:FindFirstChild("HumanHubBus")
	if bus and bus:IsA("BindableEvent") then
		return bus
	end
	return nil
end

local function killPrevious()
	local killed = false
	for _, env in ipairs(hubGlobals()) do
		local prevHub = env.__HumanHub
		if type(prevHub) == "table" and type(prevHub.shutdown) == "function" and prevHub ~= Hub then
			pcall(prevHub.shutdown)
			killed = true
		end
		pcall(function()
			env.__HumanHub = nil
		end)
		pcall(function()
			env.__HumanHubShutdown = nil
		end)
	end
	local bus = findHubBus()
	if bus then
		-- Handler BindableEvent dijalankan tertunda di thread sinyal. Panggilan
		-- langsung di atas hanya membersihkan state Lua (Hub.dead + loop
		-- berhenti); kerja engine dari chunk lama (Destroy GUI, input) bisa
		-- diabaikan executor, jadi handler bus yang benar-benar menutupnya.
		pcall(function()
			bus:Fire("shutdown")
		end)
		killed = true
		-- Beri satu frame supaya handler sempat jalan. Window run lama juga
		-- dihapus sendiri di bawah sebelum window baru dibuat, jadi ini hanya
		-- pengaman, bukan syarat.
		task.wait(0.1)
	end
	if killed then
		task.wait(0.05)
	end
	return killed
end

killPrevious()

function Hub.publish()
	if Hub.dead then
		return
	end
	for _, env in ipairs(hubGlobals()) do
		pcall(function()
			env.__HumanHub = Hub
		end)
	end
	pcall(function()
		_G.__HumanHubShutdown = Hub.shutdown
	end)
end

function Hub.keep(conn)
	if Hub.dead then
		pcall(function()
			conn:Disconnect()
		end)
		return conn
	end
	table.insert(Hub.conns, conn)
	return conn
end

function Hub.onUnload(fn)
	if Hub.dead then
		return
	end
	table.insert(Hub.unload, fn)
end

-- Window WindUI ditaruh di gethui()/PlayerGui dan tidak ikut mati saat
-- script dijalankan ulang. Semua penghapusan dibungkus pcall supaya
-- container aneh (gethui nil / instance terkunci) tidak menggagalkan reload.
-- Tiap window diberi tanda HumanHubOwner berisi token instance-nya. Saat
-- shutdown (often telat, lewat thread sinyal) hanya window bertanda token
-- sendiri yang dihapus, jadi window run baru tidak ikut kena.
local GUI_OWNER = "HumanHubOwner"

local function guiOwner(c)
	local ok, owner = pcall(function()
		return c:GetAttribute(GUI_OWNER)
	end)
	return ok and owner or nil
end

local function destroyHubGui(onlyMine)
	local function shouldKill(c)
		if not onlyMine then
			return true
		end
		local owner = guiOwner(c)
		return owner == nil or owner == HUB_TOKEN
	end
	local root = uiContainer()
	if root and root.GetChildren then
		pcall(function()
			for _, c in ipairs(root:GetChildren()) do
				if (c.Name == "WindUI" or c.Name:sub(1, 7) == "WindUI/") and shouldKill(c) then
					pcall(function()
						c:Destroy()
					end)
				end
			end
		end)
	end
	local lp = game:GetService("Players").LocalPlayer
	local playerGui = lp and lp:FindFirstChild("PlayerGui")
	for _, folder in ipairs({ game:GetService("CoreGui"), playerGui }) do
		if folder and folder.GetChildren then
			pcall(function()
				for _, c in ipairs(folder:GetChildren()) do
					if (c.Name == "WindUI" or c.Name == "Rayfield" or c.Name == "FluentUI") and shouldKill(c) then
						pcall(function()
							c:Destroy()
						end)
					end
				end
			end)
		end
	end
end

-- Dipanggil tepat setelah window dibuat: tandai ScreenGui WindUI sebagai milik
-- instance ini. Saat startup semua window lama sudah dihapus, jadi ScreenGui
-- tanpa tanda pasti milik kita.
function Hub.claimGui()
	local root = uiContainer()
	if not root or not root.GetChildren then
		return
	end
	pcall(function()
		for _, c in ipairs(root:GetChildren()) do
			if (c.Name == "WindUI" or c.Name:sub(1, 7) == "WindUI/") and guiOwner(c) == nil then
				pcall(function()
					c:SetAttribute(GUI_OWNER, HUB_TOKEN)
				end)
			end
		end
	end)
end

function Hub.shutdown()
	Hub.dead = true
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
	for _, env in ipairs(hubGlobals()) do
		if env.__HumanHub == Hub then
			pcall(function()
				env.__HumanHub = nil
			end)
		end
		if env.__HumanHubShutdown == Hub.shutdown then
			pcall(function()
				env.__HumanHubShutdown = nil
			end)
		end
	end
	destroyHubGui(true)
end

-- Bus dipakai run berikutnya untuk mematikan instance ini walau _G-nya
-- terpisah. Bus sengaja tidak dihapus saat shutdown agar instance lain yang
-- masih hidup tetap bisa menerima sinyal yang sama.
do
	local bus = findHubBus()
	if not bus then
		bus = Instance.new("BindableEvent")
		bus.Name = "HumanHubBus"
		local okParent = pcall(function()
			bus.Parent = uiContainer()
		end)
		if not okParent or not bus.Parent then
			bus = nil
		end
	end
	if bus then
		Hub.bus = bus
		-- Atribut token lama (versi yang sempat memakainya) dibersihkan supaya
		-- bus tidak menumpuk sampah; liveness tidak lagi bergantung padanya.
		pcall(function()
			for k in pairs(bus:GetAttributes()) do
				bus:SetAttribute(k, nil)
			end
		end)
		Hub.keep(bus.Event:Connect(function(msg)
			if msg == "shutdown" then
				-- Handler ini jalan di thread sinyal. filtergc di thread itu
				-- menggantung, jadi tandai dulu supaya panicRelease dilewati.
				Hub.remote = true
				Hub.shutdown()
			end
		end))
	end
end
Hub.publish()

destroyHubGui()

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
	local ok, list = pcall(function() return filtergc("function", { Name = fname }) end)
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
	local function valid(t)
		return type(t) == "table" and type(t.slots) == "table"
			and type(t.count) == "function" and type(t.select) == "function"
			and type(t.remove) == "function" and type(t.room) == "function"
	end
	for _, keys in ipairs({ { "slots", "capacity", "changed" }, { "slots", "capacity" }, { "slots" } }) do
		local ok, list = pcall(function() return filtergc("table", { Keys = keys }) end)
		if ok and type(list) == "table" then
			if valid(list) then return list end
			if type(list[1]) ~= "table" then list = { list } end
			for _, t in ipairs(list) do
				if valid(t) then return t end
			end
		end
	end
	return nil
end

function Bind.resolve(force)
	if not force and Bind.W and Bind.CT and Bind.hit and Bind.setTile then
		if not Bind.inv then Bind.inv = findInventory() end
		return Bind.inv ~= nil
	end

	local okW, worldList = pcall(function() return filtergc("table", { Keys = { "fg", "bg", "name", "w", "h" } }) end)
	if not okW then
		return false
	end
	local W = pickTable(worldList, { "goTo" })
	if not W then
		return false
	end

	local okC, ctList = pcall(function() return filtergc("table", { Keys = { "state", "onHurt", "onDie" } }) end)
	local CT = okC and pickTable(ctList, { "state", "solidAt" }) or nil

	local hit = findFnByWorld("hit", W)
	local setTile = findFnByWorld("setTile", W)
	local inv = findInventory() or Bind.inv

	Bind.W, Bind.CT, Bind.hit, Bind.setTile, Bind.inv, Bind.name = W, CT, hit, setTile, inv, W.name
	log(string.format("bind world=%s %sx%s hit=%s setTile=%s inv=%s", tostring(W.name), tostring(W.w), tostring(W.h),
		hit and "ok" or "NIL", setTile and "ok" or "NIL", inv and "ok" or "NIL"))
	return W ~= nil and CT ~= nil and hit ~= nil and inv ~= nil
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

local function worldPickerVisible()
	local menu = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
	menu = menu and menu:FindFirstChild("MenuGui")
	local picker = menu and menu:FindFirstChild("WorldPicker")
	return picker ~= nil and picker.Visible == true, picker
end

local function closeWorldPicker(picker)
	if not picker then return end
	picker.Visible = false
	-- Menu game memanggil closeDialogs() setelah enter berhasil untuk
	-- menampilkan HUD lagi. Panel saja ditutup akan menyembunyikan HUD.
	local ok, matches = pcall(function() return filtergc("table", { Keys = { "layers", "closeDialogs" } }) end)
	if not ok or type(matches) ~= "table" then return end
	if type(matches[1]) ~= "table" then matches = { matches } end
	for _, menu in ipairs(matches) do
		if type(menu) == "table" and type(menu.layers) == "table"
			and menu.layers.WorldPicker == picker and type(menu.closeDialogs) == "function" then
			pcall(menu.closeDialogs)
			break
		end
	end
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
	vimHeld = nil,
	backend = "vim",
	forceTouch = type(getgenv) == "function" and getgenv().HumanHubForceTouch == true or false,
	noTouch = false,
	gen = 0,
	lastJumpAt = 0,
	recovering = false,
	cfg = {
		reactMin = 0.07,
		reactMax = 0.18,
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

--// ===== 3a. INPUT SENTUH MOBILE =====
-- Di sebagian executor Android SendKeyEvent tidak sampai ke game. Tombol
-- MobileGui bawaan game tetap bekerja: tekan koneksi InputBegan-nya, lalu
-- lepas lewat current.edit(nil) milik modul controller mobile.
local Touch = {
	ready = false,
	triedAt = 0,
	gui = nil,
	ctrl = nil,
	conns = nil,
	enabledByHub = false,
	origEnabled = nil,
}

-- Move.stop() mematikan MobileGui. Selama GUI itu mati, semua InputBegan
-- yang kita kirim ke tombolnya diabaikan game (terukur dx=0 selama 0,6 s),
-- jadi karakter terlihat "tidak bisa gerak" padahal backend masih touch.
-- Setiap kali input sentuh dipakai, pastikan GUI-nya hidup lagi.
local function touchEnsureGui()
	if Touch.gui and not Touch.gui.Enabled then
		Touch.gui.Enabled = true
		Touch.enabledByHub = true
	end
end

local function touchFindCtrl()
	local ok, list = pcall(function()
		return filtergc("table", { Keys = { "current", "mount" } })
	end)
	if not ok or type(list) ~= "table" then
		return nil
	end
	local entries = list
	if type(list[1]) ~= "table" then
		entries = { list }
	end
	for _, entry in ipairs(entries) do
		local current = type(entry) == "table" and entry.current
		if type(current) == "table"
			and type(current.dir) == "function"
			and type(current.edit) == "function" then
			return current
		end
	end
	return nil
end

local function touchSetup()
	if Touch.ready then
		touchEnsureGui()
		return true
	end
	if os.clock() - Touch.triedAt < 3 then
		return false
	end
	Touch.triedAt = os.clock()
	if type(getconnections) ~= "function" then
		return false
	end
	local okAll, gui, conns, ctrl = pcall(function()
		local player = Players.LocalPlayer
		local playerGui = player and player:FindFirstChild("PlayerGui")
		local mobileGui = playerGui and playerGui:FindFirstChild("MobileGui")
		if not mobileGui then
			return nil
		end
		local list = {}
		for _, name in ipairs({ "Left", "Right", "Jump" }) do
			local button = mobileGui:FindFirstChild(name)
			if not button then
				return nil
			end
			local fn = nil
			for _, conn in ipairs(getconnections(button.InputBegan)) do
				if conn.Function then
					fn = conn.Function
					break
				end
			end
			if not fn then
				return nil
			end
			list[name] = fn
		end
		local current = touchFindCtrl()
		if not current then
			return nil
		end
		return mobileGui, list, current
	end)
	if not okAll or not gui or not conns or not ctrl then
		return false
	end
	Touch.gui, Touch.conns, Touch.ctrl = gui, conns, ctrl
	if Touch.origEnabled == nil then
		Touch.origEnabled = gui.Enabled
	end
	if not gui.Enabled then
		gui.Enabled = true
		Touch.enabledByHub = true
	end
	Touch.ready = true
	log("input sentuh MobileGui siap")
	return true
end

local function touchPress(name)
	if not touchSetup() then
		return false
	end
	local fake = {
		UserInputType = Enum.UserInputType.Touch,
		Position = Vector3.new(0, 0, 0),
	}
	return pcall(Touch.conns[name], fake)
end

local function touchRelease()
	if not Touch.ready then
		return false
	end
	pcall(Touch.ctrl.edit, nil)
	return true
end

-- Pindah ke input sentuh kalau tersedia. Di PC VIM sudah terbukti, jadi
-- hanya dipakai bila TouchEnabled aktif dan keyboard tidak terdeteksi,
-- atau bila pengguna menyalakan "Paksa input sentuh".
function Move.preferTouch()
	if Move.backend == "touch" then
		return true
	end
	if Move.noTouch then
		return false
	end
	if not Touch.ready then
		if not Move.forceTouch then
			local uis = game:GetService("UserInputService")
			if not uis.TouchEnabled or uis.KeyboardEnabled then
				return false
			end
		end
		if not touchSetup() then
			return false
		end
	end
	if Move.vimHeld then
		vkey(false, Move.vimHeld)
		Move.vimHeld = nil
	end
	Move.held = nil
	Move.backend = "touch"
	log("mode gerak: sentuh (MobileGui)")
	return true
end

function Move.release()
	if Move.vimHeld then
		vkey(false, Move.vimHeld)
		Move.vimHeld = nil
	end
	if Touch.ready then
		pcall(Touch.ctrl.edit, nil)
	end
	Move.held = nil
end

-- Reload membunuh thread lama saat tombol arah masih ditekan. Kalau objek
-- controller mobile sudah diganti game (respawn/rejoin), release milik run
-- lama mengenai objek basi dan karakter terus berjalan ke satu arah. Cari
-- ulang semua controller lalu lepas arahnya.
function Move.panicRelease()
	if Move.vimHeld then
		vkey(false, Move.vimHeld)
		Move.vimHeld = nil
	end
	vkey(false, KeyLeft)
	vkey(false, KeyRight)
	vkey(false, Enum.KeyCode.Space)
	Move.held = nil
	local ok, list = pcall(function()
		return filtergc("table", { Keys = { "current", "mount" } })
	end)
	if ok and type(list) == "table" then
		local entries = list
		if type(list[1]) ~= "table" then
			entries = { list }
		end
		for _, entry in ipairs(entries) do
			local current = type(entry) == "table" and entry.current
			if type(current) == "table" and type(current.edit) == "function" then
				pcall(current.edit, nil)
			end
		end
	end
	if Touch.ready and Touch.ctrl then
		pcall(Touch.ctrl.edit, nil)
	end
end

function Move.hold(kc)
	if Move.held == kc then
		return
	end
	Move.preferTouch()
	Move.release()
	if Move.backend == "touch" then
		if touchPress(kc == KeyRight and "Right" or "Left") then
			Move.held = kc
			return
		end
		Move.backend = "vim"
		log("input sentuh gagal; kembali ke VIM")
	end
	Move.held = kc
	Move.vimHeld = kc
	vkey(true, kc)
end

-- Kirim satu tekanan lompat sesuai backend aktif.
local function sendJump()
	if Move.backend == "touch" or Move.preferTouch() then
		local held = Move.held
		if touchPress("Jump") then
			task.wait(rnd(0.12, 0.16))
			touchRelease()
			-- edit(nil) ikut melepas arah; pasang lagi supaya lompatan
			-- tetap punya dorongan horizontal seperti di PC.
			if held then
				touchPress(held == KeyRight and "Right" or "Left")
			end
			return true
		end
		Move.backend = "vim"
	end
	vkey(true, Enum.KeyCode.Space)
	task.wait(rnd(0.14, 0.20))
	vkey(false, Enum.KeyCode.Space)
	return true
end

-- Lompat hanya dianggap berhasil kalau karakter benar-benar naik/lepas
-- tanah. Di Android tekanan tombol kadang hilang (frames drop / MobileGui
-- baru hidup), dan lompatan yang tidak terjadi membuat pathfinder menandai
-- jalur naik sebagai mustahil. Karena itu input diulang sekali sebelum
-- menyerah.
function Move.jump()
	local state = Bind.state()
	if not state or not state.grounded or os.clock() - (Move.lastJumpAt or 0) < 0.7 then
		return false
	end
	local startY = state.y
	for _ = 1, 2 do
		Move.lastJumpAt = os.clock()
		sendJump()
		local deadline = os.clock() + 0.3
		while os.clock() < deadline do
			local s = Bind.state()
			if s and (not s.grounded or s.y < startY - 0.12) then
				return true
			end
			task.wait(0.02)
		end
		local now = Bind.state()
		if not now or not now.grounded then
			return true
		end
		-- Masih menempel tanah: tombol tidak sampai, ulangi setelah jeda
		-- singkat (jangan menunggu cooldown 0,7 s penuh).
		task.wait(0.1)
	end
	return false
end

function Move.idle(a, b)
	task.wait(rnd(a, b))
end

local function moveStandable(W, x, y)
	if not W then
		return false
	end
	local w = tonumber(W.w) or 100
	local h = tonumber(W.h) or 60
	if x < 0 or x >= w - 1 or y < 0 or y >= h - 1 then
		return false
	end
	local floor = W.fg and W.fg[y + 1] and W.fg[y + 1][x]
	return (not Bind.solid(x, y)) and (Bind.solid(x, y + 1) or floor == 102)
end

-- true kalau karakter menempel tepi world atau berdiri di tile yang tidak
-- dianggap bisa dipijak. Dari posisi begini pathfinder sering tidak punya
-- jalan keluar, jadi karakter harus digeser dulu.
function Move.edgeStuck()
	local W = Bind.getW()
	local s = Bind.state()
	if not W or not s then
		return false
	end
	local w = tonumber(W.w) or 100
	local cx, cy = math.floor(s.x), math.floor(s.y - 0.0001)
	if not moveStandable(W, cx, cy) then
		return true
	end
	return cx <= 1 or cx >= w - 3
end

-- Geser karakter menjauh dari tepi sambil melompat bila perlu, lalu biarkan
-- pemanggil menghitung ulang path dari posisi baru.
function Move.recover()
	if Move.recovering then
		return false
	end
	local W, s = Bind.getW(), Bind.state()
	if not W or not s then
		return false
	end
	Move.recovering = true
	local w = tonumber(W.w) or 100
	local dir = s.x < w / 2 and 1 or -1
	if s.x <= 2 then
		dir = 1
	elseif s.x >= w - 3 then
		dir = -1
	end
	local deadline = os.clock() + 2.2
	local nextJump = os.clock() + 0.3
	Move.hold(dir > 0 and KeyRight or KeyLeft)
	while os.clock() < deadline do
		local now = Bind.state()
		if not now then
			break
		end
		local cx, cy = math.floor(now.x), math.floor(now.y - 0.0001)
		if cx > 2 and cx < w - 3 and moveStandable(W, cx, cy) then
			break
		end
		if now.grounded and os.clock() >= nextJump then
			Move.jump()
			nextJump = os.clock() + 0.9
		end
		task.wait(0.04)
	end
	Move.release()
	task.wait(0.15)
	Move.recovering = false
	return true
end

function Move.stop()
	Move.gen += 1
	Move.release()
	if Touch.enabledByHub and Touch.gui then
		-- Kembalikan seperti semula, jangan selalu mati: di Android tombol
		-- sentuh itu kontrol bawaan pemain.
		pcall(function()
			Touch.gui.Enabled = Touch.origEnabled == true
		end)
		Touch.enabledByHub = false
	end
end

Hub.onUnload(function()
	Move.release()
	if not Hub.remote then
		-- filtergc hanya aman di thread executor. Saat shutdown lewat bus
		-- (thread sinyal) lewati; run baru sudah memanggil panicRelease
		-- sendiri saat startup.
		Move.panicRelease()
	end
	if Touch.enabledByHub and Touch.gui then
		pcall(function()
			Touch.gui.Enabled = Touch.origEnabled == true
		end)
		Touch.enabledByHub = false
	end
end)
Hub.move = Move
Hub.touch = Touch

-- Karakter yang masih jalan dari run lama harus berhenti sekarang, bukan
-- menunggu fitur gerak berikutnya dipakai.
Move.panicRelease()

-- Jalan ke target X. Return true kalau berhenti di dekat target.
function Move.walkTo(targetX, opts)
	opts = opts or {}
	Move.preferTouch()
	local tol = opts.tol or 0.14
	local deadline = os.clock() + (opts.timeout or 25)
	local myGen = Move.gen
	local lastX, lastT = nil, os.clock()
	local recovered = false

	if not Move.held then
		Move.idle(Move.cfg.reactMin, Move.cfg.reactMax)
	end

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
			elseif os.clock() - lastT > 1.2 then
				Move.release()
				if not recovered and opts.recover ~= false and Move.edgeStuck()
					and Move.recover() then
					recovered = true
					lastX, lastT = nil, os.clock()
					deadline = math.max(deadline, os.clock() + 2.0)
				else
					return false
				end
			end
		end

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
local PNB = {
	running = false,
	gen = 0,
	itemId = nil,
	layer = nil,
	atSelf = false,
	targetX = nil,
	targetY = nil,
	autoCollect = true,
	collectRadius = 0.9,
	searchRadius = 2.5,
	cycles = 0,
	status = "idle",
	onStatus = nil,
}
local Factory = {
	running = false,
	gen = 0,
	harvest = false,
	plant = false,
	cycle = false,
	seedId = nil,
	seedName = nil,
	seedGrow = nil,
	baseId = nil,
	baseName = nil,
	baseLayer = nil,
	baseAtSelf = nil,
	workX = nil,
	workY = nil,
	workStandX = nil,
	pnbPathFailures = 0,
	pnbSkipUntil = nil,
	pnbLowWater = nil,
	pnbDraining = false,
	pnbDrainCount = 0,
	pnbDrainTarget = nil,
	pnbOldDrops = nil,
	dropFilter = nil,
	harvestFailures = 0,
	harvestSkipUntil = nil,
	harvestFailCount = {},
	ignoredDrops = {},
	dropTakeFailures = {},
	resumePNB = false,
	resumeCollect = false,
	homeWorld = nil,
	lastRejoinAt = 0,
	pnb = 0,
	phase = "idle",
	treeMap = nil,
	treeMapWorld = nil,
	harvested = 0,
	planted = 0,
	status = "idle",
	onStatus = nil,
	onMode = nil,
	syncingUI = false,
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
function Dig.punch(x, y, isTree, skipAim, allowLava, forceBg)
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
		if bg == 0 or (not Farm.breakBg and not forceBg) then
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
	if PNB.running then
		setStatus("gagal: matikan PNB terlebih dahulu")
		return
	end
	if Factory.running then
		setStatus("gagal: matikan Auto Harvest / Plant terlebih dahulu")
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

--// ===== 6. PNB (PLACE AND BREAK) + AUTO COLLECT =====
local function setPNBStatus(message)
	PNB.status = message
	if PNB.onStatus then
		pcall(PNB.onStatus, message)
	end
end

function PNB.stop(reason)
	if not PNB.running then
		return
	end
	PNB.running = false
	PNB.gen += 1
	Move.stop()
	setPNBStatus(reason or "dihentikan")
end

-- `only` (opsional) = tabel uid drop yang boleh diambil. Dipakai saat blok
-- penuh: yang dijemput hanya drop lama, drop pecahan baru dibiarkan supaya
-- blok di inventory benar-benar berkurang dulu.
local function collectDropsNearby(W, inv, state, radius, only)
	if not state or type(W.dropList) ~= "function" or type(W.takeDrop) ~= "function" then
		return 0
	end
	if type(inv.room) ~= "function" or type(inv.add) ~= "function" then
		return 0
	end
	local ok, drops = pcall(W.dropList)
	if not ok or type(drops) ~= "table" then
		return 0
	end
	local collected, needsRoom = 0, false
	for _, drop in ipairs(drops) do
		if type(drop) == "table" and type(drop.uid) == "number" and type(drop.id) == "number"
			and type(drop.n) == "number" and type(drop.x) == "number" and type(drop.y) == "number"
			and not (Factory.ignoredDrops and (Factory.ignoredDrops[drop.uid] or 0) > os.clock())
			and (not only or only[drop.uid]) then
			local dx, dy = drop.x - state.x, drop.y - state.y
			if dx * dx + dy * dy <= radius * radius then
				local roomOK, room = pcall(inv.room, inv, drop.id)
				local available = roomOK and (tonumber(room) or 0) or 0
				if available > 0 then
					-- Minta satu tumpukan penuh. Game yang menentukan berapa
					-- bagian yang diterima ketika inventory hampir penuh.
					local takeOK, taken = pcall(W.takeDrop, drop.uid, drop.n)
					taken = takeOK and tonumber(taken) or 0
					if taken > 0 then
						pcall(inv.add, inv, drop.id, taken)
						collected += taken
					elseif drop.id == Factory.baseId and drop.n > available then
						needsRoom = true
					end
				end
			end
		end
	end
	return collected, needsRoom
end

-- Drop hasil pukulan duduk di tengah tile yang pecah (x+0.5, y+0.5). Pemain
-- yang berdiri di tile sebelah sudah berjarak ~1,12 tile, jadi radius 0,9
-- sering melewatkannya. Drop juga baru terlihat beberapa frame setelah tile
-- hancur, dan uid-nya masih ada di dropList walau sudah diambil server.
-- Karena itu patokannya bukan hasil takeDrop, tetapi apakah drop masih ada
-- di sekitar tile setelah ditunggu dan dijemput.
-- Return: jumlah yang diambil, id drop yang tertinggal karena inventory penuh.
local function collectDropsAtTile(W, inv, x, y, alive)
	if type(W.dropList) ~= "function" or type(W.takeDrop) ~= "function"
		or type(inv.room) ~= "function" or type(inv.add) ~= "function" then
		return 0, nil
	end
	local cx, cy = x + 0.5, y + 0.5
	local total = 0
	local attempts = {}
	local start = os.clock()

	local function nearby()
		local state = Bind.state()
		if not state then
			return nil
		end
		local ok, drops = pcall(W.dropList)
		if not ok or type(drops) ~= "table" then
			return nil
		end
		local list, nearest, nearestDist = {}, nil, nil
		for _, drop in ipairs(drops) do
			if type(drop) == "table" and type(drop.uid) == "number"
				and type(drop.id) == "number" and type(drop.n) == "number"
				and type(drop.x) == "number" and type(drop.y) == "number"
				and not (Factory.ignoredDrops and (Factory.ignoredDrops[drop.uid] or 0) > os.clock()) then
				local ox, oy = drop.x - cx, drop.y - cy
				if ox * ox + oy * oy <= 2.25 then
					local dx, dy = drop.x - state.x, drop.y - state.y
					local dist = dx * dx + dy * dy
					table.insert(list, { drop = drop, dist = dist })
					if not nearestDist or dist < nearestDist then
						nearest, nearestDist = drop, dist
					end
				end
			end
		end
		return list, nearest, nearestDist, state
	end

	local sawAny = false
	while os.clock() - start < 2.2 do
		if alive and not alive() then
			break
		end
		local list, nearest, nearestDist, state = nearby()
		if not list or #list == 0 then
			-- Drop bisa muncul beberapa frame setelah tile pecah.
			if sawAny or os.clock() - start >= 0.6 then
				break
			end
			task.wait(0.1)
		else
			sawAny = true
			-- Berdiri tepat di drop; jangan jalan kalau drop ada di lantai
			-- lain (bisa memicu jatuh).
			if nearest and nearestDist > 0.81 and math.abs(nearest.y - state.y) <= 1.05 then
				Move.walkTo(nearest.x, { timeout = 1.2, tol = 0.22 })
				state = Bind.state() or state
			end
			local anyRoom, took, retry = false, false, false
			for _, item in ipairs(list) do
				local drop = item.drop
				local roomOK, room = pcall(inv.room, inv, drop.id)
				local available = roomOK and (tonumber(room) or 0) or 0
				if available > 0 then
					anyRoom = true
					if (attempts[drop.uid] or 0) < 3 then
						attempts[drop.uid] = (attempts[drop.uid] or 0) + 1
						local okT, taken = pcall(W.takeDrop, drop.uid, math.min(drop.n, available))
						taken = okT and tonumber(taken) or 0
						if taken > 0 then
							pcall(inv.add, inv, drop.id, taken)
							total += taken
							took = true
						else
							retry = true
						end
					end
				end
			end
			-- Inventory penuh: tidak ada gunanya menunggu. Atau server
			-- menolak terus: jangan tahan panen berikutnya.
			if not anyRoom or (not took and not retry) then
				break
			end
			task.wait(0.18)
		end
	end

	-- Masih ada drop di tile ini setelah ditunggu? Kalau ruangnya nol, itu
	-- sebabnya; pemanggil bisa menahan panen berikutnya.
	local blockedId = nil
	local list = nearby()
	if list then
		for _, item in ipairs(list) do
			local roomOK, room = pcall(inv.room, inv, item.drop.id)
			if not roomOK or (tonumber(room) or 0) <= 0 then
				blockedId = item.drop.id
				break
			end
		end
	end
	return total, blockedId
end

local function collectNearby(W, inv, state)
	if not PNB.autoCollect then
		return 0
	end
	return collectDropsNearby(W, inv, state, PNB.collectRadius)
end

local function nearestCollectibleDrop(W, inv, state)
	if not PNB.autoCollect or type(W.dropList) ~= "function" or type(inv.room) ~= "function" then
		return nil
	end
	local ok, drops = pcall(W.dropList)
	if not ok or type(drops) ~= "table" then
		return nil
	end
	local floorY = standingFloor(state)
	local bestX, bestDistance
	for _, drop in ipairs(drops) do
		if type(drop) == "table" and type(drop.id) == "number" and type(drop.n) == "number"
			and type(drop.x) == "number" and type(drop.y) == "number" and drop.n > 0
			and math.abs(drop.y - state.y) <= 1.1 then
			local distance = math.abs(drop.x - state.x)
			if distance > PNB.collectRadius and distance <= PNB.searchRadius
				and (not bestDistance or distance < bestDistance) then
				local roomOK, room = pcall(inv.room, inv, drop.id)
				if roomOK and (tonumber(room) or 0) > 0 then
					local pathClear = true
					for tx = math.min(math.floor(state.x), math.floor(drop.x)), math.max(math.floor(state.x), math.floor(drop.x)) do
						if not Bind.solid(tx, floorY) or tileId(tx, floorY - 1) ~= 0 then
							pathClear = false
							break
						end
					end
					if pathClear then
						bestX, bestDistance = drop.x, distance
					end
				end
			end
		end
	end
	return bestX
end

local function pnbTileId(W, layer, x, y)
	local grid = W[layer]
	return (grid and grid[y] and grid[y][x]) or 0
end

local itemDBCache
local function itemDBCandidate(candidate)
	return type(candidate) == "table" and type(candidate[2]) == "table"
		and candidate[2].name == "Dirt" and type(candidate[3]) == "table"
		and candidate[3].kind == "seed" and type(candidate[14]) == "table"
		and candidate[14].background == true
end

local function findItemDB()
	if itemDBCandidate(itemDBCache) then
		return itemDBCache
	end
	if type(Bind.hit) == "function" then
		local ok, upvalues = pcall(debug.getupvalues, Bind.hit)
		if ok and type(upvalues) == "table" then
			for _, candidate in ipairs(upvalues) do
				if itemDBCandidate(candidate) then
					itemDBCache = candidate
					return candidate
				end
			end
		end
	end
	-- Filter gabungan key numerik bisa melewatkan ItemDB di beberapa executor.
	-- Cari dengan satu key lalu validasi isi tabel sebelum dipakai.
	for _, key in ipairs({ 955, 14 }) do
		local ok, candidates = pcall(function() return filtergc("table", { Keys = { key } }) end)
		if ok and type(candidates) == "table" then
			if itemDBCandidate(candidates) then
				itemDBCache = candidates
				return candidates
			end
			for _, candidate in ipairs(candidates) do
				if itemDBCandidate(candidate) then
					itemDBCache = candidate
					return candidate
				end
			end
		end
	end
	return nil
end

local function selectedItemDefinition(itemId)
	local items = findItemDB()
	return items and items[itemId] or nil
end

local function findPNBTarget(W, state, layer, atSelf)
	local floorY = standingFloor(state)
	if not floorY or not Bind.solid(math.floor(state.x), floorY) then
		return nil
	end
	local y = floorY - 1
	if atSelf then
		local x = math.floor(state.x)
		if x >= 0 and x < (tonumber(W.w) or 100) and y >= 0 and y < (tonumber(W.h) or 60)
			and pnbTileId(W, "fg", x, y) == 0 and pnbTileId(W, layer, x, y) == 0 then
			return x, y
		end
		return nil
	end
	local dir = state.facing == -1 and -1 or 1
	local baseX = math.floor(state.x)
	for step = 1, 2 do
		local x = baseX + dir * step
		local distance = math.abs(x + 0.5 - state.x)
		if x >= 0 and x < (tonumber(W.w) or 100) and y >= 0 and y < (tonumber(W.h) or 60)
			and distance >= 1.05 and distance <= 2.2
			and tileId(x, y) == 0 and Bind.solid(x, floorY) then
			return x, y
		end
	end
	return nil
end

local function startPNB()
	if PNB.running then
		return
	end
	if Farm.running then
		setPNBStatus("gagal: matikan Auto Dirt Farm terlebih dahulu")
		return
	end
	if Factory.running then
		setPNBStatus("gagal: matikan Auto Harvest / Plant terlebih dahulu")
		return
	end
	Bind.resolve(true)
	local W = Bind.W
	local inv = Bind.inv
	if not (W and Bind.CT and Bind.hit and Bind.setTile and inv) then
		setPNBStatus("gagal: binding game belum lengkap")
		return
	end
	if type(inv.count) ~= "function" or type(inv.select) ~= "function" or type(inv.remove) ~= "function" then
		setPNBStatus("gagal: fungsi inventory tidak lengkap")
		return
	end
	local state = Bind.state()
	if not state or type(state.x) ~= "number" or type(state.y) ~= "number" then
		setPNBStatus("gagal: posisi pemain tidak terbaca")
		return
	end
	local itemId = tonumber(inv.selected)
	if not itemId or itemId <= 0 or itemId == 18 or itemId == 32 or Dig.protectedIds[itemId] then
		setPNBStatus("gagal: pilih blok yang dapat dipasang di hotbar")
		return
	end
	local itemDef = selectedItemDefinition(itemId)
	if type(itemDef) == "table" and itemDef.kind == "seed" then
		setPNBStatus("gagal: yang dipilih adalah seed; pilih item bloknya (mis. Pepper Tree, bukan Pepper Tree Seed)")
		return
	end
	if type(itemDef) ~= "table" or itemDef.farmable ~= true then
		setPNBStatus("gagal: item yang dipilih bukan blok farmable")
		return
	end
	local layer = itemDef.background == true and "bg" or "fg"
	local atSelf = layer == "bg" or itemDef.solid == false
	local countOK, count = pcall(inv.count, inv, itemId)
	if not countOK or (tonumber(count) or 0) < 1 then
		setPNBStatus("gagal: stok blok yang dipilih habis")
		return
	end
	local x, y = findPNBTarget(W, state, layer, atSelf)
	if not x then
		setPNBStatus(atSelf
			and "gagal: tile pada posisi pemain tidak kosong"
			or "gagal: tidak ada tile kosong dengan lantai di depan pemain")
		return
	end
	if Dig.isProtected(itemId, x, y) then
		setPNBStatus("gagal: blok ini tidak cocok untuk PNB")
		return
	end

	PNB.running = true
	PNB.gen += 1
	PNB.itemId, PNB.layer, PNB.atSelf, PNB.targetX, PNB.targetY = itemId, layer, atSelf, x, y
	PNB.cycles = 0
	local gen = PNB.gen
	local startX = state.x
	local startY = state.y
	local worldName = W.name
	setPNBStatus(string.format("berjalan: %s (%s, %s) di (%d, %d)",
		tostring(itemDef.name or itemId), layer, atSelf and "posisi pemain" or "depan", x, y))

	task.spawn(function()
		local ok, err = pcall(function()
			while PNB.running and PNB.gen == gen do
				local s = Bind.state()
				if not s or W.name ~= worldName or math.abs(s.x - startX) > 0.8 or math.abs(s.y - startY) > 0.8 then
					PNB.stop("berhenti: posisi pemain atau world berubah")
					break
				end
				if pnbTileId(W, layer, x, y) ~= 0 then
					PNB.stop("berhenti: tile target sudah terisi")
					break
				end
				collectNearby(W, inv, s)
				local hasOK, has = pcall(inv.count, inv, itemId)
				if not hasOK or (tonumber(has) or 0) < 1 then
					PNB.stop("berhenti: stok blok habis")
					break
				end
				local selectedOK = pcall(inv.select, inv, itemId)
				if not selectedOK then
					PNB.stop("berhenti: tidak bisa memilih blok")
					break
				end
				local placeOK = pcall(Bind.setTile, layer, x, y, itemId, false, false)
				if not placeOK or pnbTileId(W, layer, x, y) ~= itemId then
					PNB.stop("berhenti: blok tidak bisa dipasang di tile target")
					break
				end
				pcall(inv.remove, inv, itemId, 1)
				W.punchReady = os.clock() + 0.15
				task.wait(rnd(0.13, 0.21))

				local hits = 0
				while PNB.running and PNB.gen == gen and pnbTileId(W, layer, x, y) == itemId and hits < 30 do
					if not Dig.punch(x, y, false, hits > 0, false, layer == "bg") then
						break
					end
					hits += 1
					task.wait(rnd(0.06, 0.11))
				end
				if not PNB.running or PNB.gen ~= gen then
					break
				end
				if pnbTileId(W, layer, x, y) ~= 0 then
					PNB.stop("berhenti: blok tidak berhasil dihancurkan")
					break
				end
				task.wait(rnd(0.32, 0.48))
				local afterBreak = Bind.state() or s
				collectNearby(W, inv, afterBreak)
				local dropX = not atSelf and nearestCollectibleDrop(W, inv, afterBreak) or nil
				if dropX and PNB.running and PNB.gen == gen then
					local reached = Move.walkTo(dropX, { timeout = 4, tol = 0.2 })
					if reached and PNB.running and PNB.gen == gen then
						collectNearby(W, inv, Bind.state() or afterBreak)
					end
					if PNB.running and PNB.gen == gen and not Move.walkTo(startX, { timeout = 4, tol = 0.2 }) then
						PNB.stop("berhenti: tidak bisa kembali setelah collect")
						break
					end
				end
				PNB.cycles += 1
				if PNB.cycles % 10 == 0 then
					setPNBStatus(string.format("berjalan: %d siklus, item %d", PNB.cycles, itemId))
				end
				task.wait(rnd(0.12, 0.25))
			end
		end)
		if not ok and PNB.running and PNB.gen == gen then
			log("PNB error: " .. tostring(err))
			PNB.stop("berhenti: terjadi error (lihat console)")
		end
	end)
end

--// ===== 7. AUTO HARVEST / AUTO PLANT =====
local function setFactoryStatus(message)
	Factory.status = message
	if Factory.onStatus then
		pcall(Factory.onStatus, message)
	end
end

function Factory.stop(reason)
	if not Factory.running then
		return
	end
	Factory.running = false
	Factory.gen += 1
	Factory.harvest = false
	Factory.plant = false
	Factory.cycle = false
	Factory.phase = "idle"
	Factory.pnbLowWater = nil
	Factory.pnbDraining = false
	Factory.pnbDrainCount = 0
	Factory.pnbDrainTarget = nil
	Factory.pnbOldDrops = nil
	Factory.dropFilter = nil
	Factory.homeWorld = nil
	Move.stop()
	setFactoryStatus(reason or "dihentikan")
	if Factory.onMode then
		pcall(Factory.onMode)
	end
end

function Factory.seedOptions()
	Bind.resolve(true)
	local inv = Bind.inv
	local items = findItemDB()
	local rows, seen = {}, {}
	if inv and items and type(inv.slots) == "table" then
		for _, slot in ipairs(inv.slots) do
			local def = type(slot) == "table" and items[slot.id] or nil
			if type(def) == "table" and def.kind == "seed" and (tonumber(slot.n) or 0) > 0 then
				table.insert(rows, { id = slot.id, name = def.name or ("Seed " .. slot.id), count = slot.n })
				seen[slot.id] = true
			end
		end
	end
	if Factory.seedId and not seen[Factory.seedId] and items then
		local def = items[Factory.seedId]
		if type(def) == "table" and def.kind == "seed" then
			table.insert(rows, { id = Factory.seedId, name = def.name or ("Seed " .. Factory.seedId), count = 0 })
		end
	end
	table.sort(rows, function(a, b)
		return a.name < b.name
	end)
	local values, byLabel = { "Pilih seed..." }, {}
	for _, row in ipairs(rows) do
		local label = string.format("%s [#%d] x%d", row.name, row.id, row.count)
		table.insert(values, label)
		byLabel[label] = row.id
	end
	if #values == 1 then
		table.insert(values, inv and items and "Tidak ada seed di inventory" or "Memuat daftar seed...")
	end
	return values, byLabel
end

local function factoryAlive(gen)
	-- Reload hub harus menghentikan loop run lama; tanpa cek ini dua instance
	-- bisa berebut menggerakkan karakter (run lama tetap jalan tanpa UI).
	return Factory.running and Factory.gen == gen and _G.__HumanHub == Hub
end

--// ===== 5. PATHFINDER TILE (JALAN / LOMPAT / JATUH) =====
-- Dipakai factory untuk menjangkau seluruh world, bukan cuma 1 baris.
local Path = { canJump = nil :: boolean? }

local function keyOf(x, y)
	return y * 1000 + x
end

-- Transisi tile yang sudah terbukti gagal (lompat/jatuh/walk tidak sampai)
-- disimpan sebentar supaya pathfinder tidak memilih jalur yang mustahil
-- berulang-ulang dan factory tidak terjebak di pohon yang sama.
Path.blockedEdges = {}

local function edgeKeyOf(fx, fy, tx, ty)
	return tostring(keyOf(fx, fy)) .. ">" .. tostring(keyOf(tx, ty))
end

function Path.blockEdge(fx, fy, tx, ty, seconds)
	Path.blockedEdges[edgeKeyOf(fx, fy, tx, ty)] = os.clock() + (seconds or 60)
end

local function edgeBlocked(fx, fy, tx, ty)
	local k = edgeKeyOf(fx, fy, tx, ty)
	local untilAt = Path.blockedEdges[k]
	if not untilAt then
		return false
	end
	if untilAt > os.clock() then
		return true
	end
	Path.blockedEdges[k] = nil
	return false
end

-- Cek sekali apakah karakter benar-benar bisa lompat. Di beberapa client
-- tombol Space tidak diteruskan ke game, sehingga semua transisi "lompat
-- naik" di pathfinder mustahil dan factory hanya membuang waktu.
function Path.probeJump()
	if Path.canJump ~= nil then
		return Path.canJump
	end
	local s = Bind.state()
	if not s or not s.grounded then
		return nil
	end
	local y0, minY, leftGround = s.y, s.y, false
	if not Move.jump() then
		return nil
	end
	local deadline = os.clock() + 0.9
	while os.clock() < deadline do
		local now = Bind.state()
		if now then
			minY = math.min(minY, now.y)
			if not now.grounded then
				leftGround = true
			end
		end
		task.wait(0.02)
	end
	local rise = y0 - minY
	if rise < 0.6 then
		-- Langit-langit rendah membuat lompatan tidak naik walau client
		-- sebenarnya bisa lompat. Jangan simpulkan apa-apa di posisi itu.
		local cx, cy = math.floor(s.x), math.floor(s.y - 0.0001)
		local headroom = 0
		for dy = 1, 3 do
			if Bind.solid(cx, cy - dy) then break end
			headroom += 1
		end
		if headroom < 3 then
			return nil
		end
		-- Kalau karakter sama sekali tidak lepas dari tanah, inputnya yang
		-- belum sampai (mis. MobileGui baru dinyalakan), bukan berarti client
		-- tidak bisa lompat. Jangan simpan kesimpulan palsu.
		if not leftGround then
			return nil
		end
		-- Jangan cache "tidak bisa lompat": satu probe di posisi sempit bisa
		-- mematikan semua jalur naik untuk seluruh sesi. Cukup laporkan
		-- untuk sekarang, probe berikutnya mengukur ulang.
		return false
	end
	Path.canJump = rise >= 0.6
	return Path.canJump
end

function Path.standable(x, y)
	local W = Bind.getW()
	if not W then
		return false
	end
	local w = tonumber(W.w) or 100
	local h = tonumber(W.h) or 60
	if x < 0 or x >= w or y < 0 or y >= h - 1 then
		return false
	end
	local floor = W.fg and W.fg[y + 1] and W.fg[y + 1][x]
	return (not Bind.solid(x, y)) and (Bind.solid(x, y + 1) or floor == 102)
end

-- Dijkstra kecil dari tile pemain. Hasil: dist[key], parent[key].
-- Biaya: jalan 1, jatuh = jarak jatuh, lompat = 2 + |dx| + tinggi.
function Path.explore(sx, sy, maxNodes)
	local W = Bind.getW()
	if not W then
		return nil, nil
	end
	local w = tonumber(W.w) or 100
	local h = tonumber(W.h) or 60
	maxNodes = maxNodes or 2500

	local solidCache = {}
	local function isSolid(x, y)
		if x < 0 or x >= w or y < 0 or y >= h then
			return true
		end
		local k = keyOf(x, y)
		local v = solidCache[k]
		if v == nil then
			v = Bind.solid(x, y)
			solidCache[k] = v
		end
		return v
	end
	local function canStand(x, y)
		-- Kolom terakhir (x = w-1) tetap dipakai: di world ini tangga antar
		-- lantai ada di tepi world, di atas Wooden Platform (id 102).
		if x < 0 or x >= w or y < 0 or y >= h - 1 then
			return false
		end
		local floor = W.fg and W.fg[y + 1] and W.fg[y + 1][x]
		return (not isSolid(x, y)) and (isSolid(x, y + 1) or floor == 102)
	end
	-- Wooden Platform (id 102) adalah platform satu arah: bisa ditembus dari
	-- bawah, tapi tetap bisa dipijak. Jangan pernah menganggapnya langit-langit.
	local function isPlatform(x, y)
		if x < 0 or x >= w or y < 0 or y >= h then
			return false
		end
		local row = W.fg and W.fg[y]
		return (row and row[x] or 0) == 102
	end
	-- Dipakai untuk memutuskan jatuh panjang aman: dari titik mendarat masih
	-- ada pijakan lain dalam jangkauan lompat (3 tile ke atas)?
	local function canClimbFrom(lx, ly)
		for up = 1, 3 do
			for dx = -2, 2 do
				if canStand(lx + dx, ly - up) then
					return true
				end
			end
		end
		return false
	end

	local dist, parent = {}, {}
	local startKey = keyOf(sx, sy)
	dist[startKey] = 0
	local open = {}
	local visited = {}
	local count = 0
	local function enqueue(node)
		local i = #open + 1
		while i > 1 do
			local parentIndex = math.floor(i / 2)
			if open[parentIndex].c <= node.c then break end
			open[i] = open[parentIndex]
			i = parentIndex
		end
		open[i] = node
	end
	local function dequeue()
		local first = open[1]
		local last = table.remove(open)
		if #open > 0 then
			local i = 1
			while i * 2 <= #open do
				local child = i * 2
				if child < #open and open[child + 1].c < open[child].c then child += 1 end
				if last.c <= open[child].c then break end
				open[i] = open[child]
				i = child
			end
			open[i] = last
		end
		return first
	end
	enqueue({ x = sx, y = sy, c = 0, key = startKey })

	local function push(cx, cy, cc, nx, ny, cost, kind, shaftX)
		if nx < 0 or nx >= w or ny < 0 or ny >= h - 1 then
			return
		end
		if not canStand(nx, ny) then
			return
		end
		if edgeBlocked(cx, cy, nx, ny) then
			return
		end
		local k = keyOf(nx, ny)
		local nc = cc + cost
		if dist[k] == nil or nc < dist[k] then
			dist[k] = nc
			parent[k] = { from = keyOf(cx, cy), kind = kind, shaftX = shaftX }
			enqueue({ x = nx, y = ny, c = nc, key = k })
		end
	end

	while #open > 0 and count < maxNodes do
		local cur = dequeue()
		if not visited[cur.key] then
			visited[cur.key] = true
			count += 1
			local cx, cy, cc = cur.x, cur.y, cur.c

			-- jalan kiri/kanan
			push(cx, cy, cc, cx - 1, cy, 1, "walk")
			push(cx, cy, cc, cx + 1, cy, 1, "walk")

			-- Melangkah ke poros samping, lalu mendarat di lantai berikutnya.
			-- Jatuh pendek (<= 3 tile) selalu aman. Jatuh panjang hanya dipakai
			-- kalau kolom porosnya benar-benar kosong sampai dasar dan dari
			-- titik mendarat masih ada pijakan untuk naik lagi; poros 1 tile
			-- selebar bisa menjadi perangkap satu arah.
			for _, dir in ipairs({ -1, 1 }) do
				local shaftX = cx + dir
				-- Poros boleh sampai kolom terakhir (x = w-1): di world ini
				-- tangga antar lantai justru ada di tepi world.
				if shaftX >= 0 and shaftX < w
					and not isSolid(shaftX, cy) and not canStand(shaftX, cy) then
					for ny = cy + 1, h - 2 do
						local depth = ny - cy
						if depth > 24 then break end
						if isSolid(shaftX, ny) then break end
						local sameCol = canStand(cx, ny)
						local shaftCol = canStand(shaftX, ny)
						if sameCol or shaftCol then
							local long = depth > 3
							if sameCol then
								-- Turun lewat poros kosong di samping lalu balik
								-- ke kolom semula (seperti video: platform di
								-- tepi, sebelahnya kosong). Jauh pun boleh asal
								-- dari titik mendarat masih bisa naik.
								if not long or (depth <= 8 and canClimbFrom(cx, ny)) then
									push(cx, cy, cc, cx, ny, 2 + depth, "drop", shaftX)
								end
							elseif shaftCol then
								if not long then
									push(cx, cy, cc, shaftX, ny, 2 + depth, "dropShaft", shaftX)
								elseif canClimbFrom(shaftX, ny) then
									push(cx, cy, cc, shaftX, ny, 2 + depth, "fall", shaftX)
								end
							end
							break
						end
					end
				end
			end

			-- lompat naik 1..3 tile, geser 0..2 tile. Platform (id 102) boleh
			-- ditembus dari bawah, jadi jangan dihitung sebagai langit-langit.
			if Path.canJump ~= false and (not isSolid(cx, cy - 1) or isPlatform(cx, cy - 1)) then
				for up = 1, 3 do
					for dx = -2, 2 do
						local nx, ny = cx + dx, cy - up
						-- Jangan pilih lompatan diagonal yang harus menembus lantai
						-- solid di samping poros. Masuk dulu ke tepi lantai, lalu
						-- gunakan edgeJump untuk naik lagi.
						if dx == 0 or up == 1 or not isSolid(nx, cy - 1)
							or isPlatform(nx, cy - 1) then
							push(cx, cy, cc, nx, ny, 2 + math.abs(dx) + up, "jump")
						end
					end
				end
			end

			-- Lantai penuh punya langit-langit tepat di atas pemain. Naik lewat
			-- celah tepi: keluar sedikit, lompat di poros, lalu masuk lagi.
			if Path.canJump ~= false and cy >= 2 then
				for _, dir in ipairs({ -1, 1 }) do
					local shaftX = cx + dir
					-- Poros kanan ada di data tile, tetapi batas fisik world
					-- menahan tubuh pemain sebelum titik lompatnya.
					if shaftX >= 0 and shaftX < w
						and (not isSolid(shaftX, cy - 1) or isPlatform(shaftX, cy - 1))
						and (not isSolid(shaftX, cy - 2) or isPlatform(shaftX, cy - 2))
						and canStand(cx, cy - 2) then
						push(cx, cy, cc, cx, cy - 2, 7, "edgeJump", shaftX)
					end
				end
			end
		end
	end
	return dist, parent
end

function Path.reconstruct(parent, startKey, goalKey)
	local path = {}
	local k = goalKey
	local guard = 0
	while k and k ~= startKey and guard < 500 do
		guard += 1
		local x = k % 1000
		local y = math.floor(k / 1000)
		local edge = parent[k]
		table.insert(path, 1, { x = x, y = y, kind = edge and edge.kind, shaftX = edge and edge.shaftX })
		k = edge and edge.from
	end
	return path
end

-- Gerak menyusuri satu langkah jalur.
local function pathStep(cx, cy, step, aliveFn)
	local function landed()
		local s = Bind.state()
		return s and s.grounded and math.floor(s.x) == step.x
			and math.floor(s.y - 0.0001) == step.y
	end
	if step.kind == "walk" then
		return Move.walkTo(step.x + 0.5, { timeout = 5, tol = 0.35 }) and landed()
	end
	if step.kind == "fall" then
		-- Jatuh panjang di kolom kosong: cukup melangkah keluar tepi, lalu
		-- tunggu sampai mendarat. Tidak ada gerakan balik ke tengah karena
		-- jaraknya jauh dan kolom tujuannya memang kosong.
		local outward = step.shaftX < cx and KeyLeft or KeyRight
		if math.floor(step.shaftX) == cx then
			outward = nil
		end
		if outward then Move.hold(outward) end
		local deadline = os.clock() + 1.4
		while aliveFn() and os.clock() < deadline do
			local s = Bind.state()
			if not s then break end
			if s.y >= cy + 0.9 or not s.grounded then break end
			task.wait(0.03)
		end
		Move.release()
		deadline = os.clock() + 5
		while aliveFn() and os.clock() < deadline do
			local s = Bind.state()
			if not s then return false end
			if s.grounded then
				if landed() then return true end
				return Move.walkTo(step.x + 0.5, { timeout = 2, tol = 0.35 }) and landed()
			end
			task.wait(0.04)
		end
		return false
	end
	if step.kind == "drop" then
		-- Turun satu lantai lewat tepi platform. Melangkah keluar sampai
		-- tidak grounded lalu LANGSUNG balik arah: karakter jatuh menempel
		-- sisi platform dan mendarat di lantai berikutnya. Jatuh di sini
		-- sangat cepat, jadi jangan menunggu sampai turun jauh dulu (bisa
		-- melewati beberapa lantai sekaligus).
		local outward = step.shaftX < cx and KeyLeft or KeyRight
		local inward = step.shaftX < cx and KeyRight or KeyLeft
		for _ = 1, 2 do
			if not aliveFn() then
				Move.release()
				return false
			end
			Move.hold(outward)
			local deadline = os.clock() + 1.2
			local airborne = false
			while aliveFn() and os.clock() < deadline do
				local s = Bind.state()
				if not s then
					break
				end
				if not s.grounded then
					airborne = true
					break
				end
				task.wait(0.005)
			end
			if airborne then
				Move.hold(inward)
				deadline = os.clock() + 1.1
				while aliveFn() and os.clock() < deadline do
					local s = Bind.state()
					if not s then
						break
					end
					if s.grounded then
						Move.release()
						local ay = math.floor(s.y - 0.0001)
						if ay ~= cy then
							-- Mendarat di lantai lain = berhasil. Kadang
							-- mendarat tepat di tepi (x di kolom kiri), jadi
							-- rapikan posisi ke tengah tile tujuan.
							if ay == step.y then
								Move.walkTo(step.x + 0.5, { timeout = 2, tol = 0.35, recover = false })
							end
							return true
						end
						break
					end
					task.wait(0.01)
				end
			end
			Move.release()
			task.wait(0.12)
		end
		return false
	end
	if step.kind == "dropShaft" then
		local outward = step.shaftX < cx and KeyLeft or KeyRight
		Move.hold(outward)
		local deadline = os.clock() + 2.5
		while aliveFn() and os.clock() < deadline do
			local s = Bind.state()
			if not s then break end
			if landed() then
				Move.release()
				return true
			end
			task.wait(0.02)
		end
		Move.release()
		return landed()
	end
	if step.kind == "edgeJump" then
		local outward = step.shaftX < cx and KeyLeft or KeyRight
		local inward = step.shaftX < cx and KeyRight or KeyLeft
		-- Lompat sebelum pusat pemain melewati tepi pijakan. Pada poros
		-- bertingkat, menunggu sampai x=0.76 sering membuat grounded hilang
		-- sebelum Space terkirim (terutama pada lompatan kedua).
		local takeoffX = step.shaftX < cx and step.shaftX + 0.92 or step.shaftX + 0.08
		local brakeX = step.shaftX < cx and step.shaftX + 0.85 or step.shaftX + 0.15
		local readyAt = (Move.lastJumpAt or 0) + 0.7
		if os.clock() < readyAt then
			task.wait(readyAt - os.clock() + 0.05)
		end
		if not aliveFn() then return false end
		Move.hold(outward)
		local deadline = os.clock() + 1.5
		local ready = false
		while aliveFn() and os.clock() < deadline do
			local s = Bind.state()
			if not s or not s.grounded then
				Move.release()
				return false
			end
			if (step.shaftX < cx and s.x <= takeoffX)
					or (step.shaftX > cx and s.x >= takeoffX) then
				ready = true
				break
			end
			task.wait(0.01)
		end
		if not ready or not aliveFn() then
			Move.release()
			return false
		end
		if not Move.jump() then
			Move.release()
			return false
		end
		Move.hold(inward)
		deadline = os.clock() + 1.2
		local braking = false
		while aliveFn() and os.clock() < deadline do
			local s = Bind.state()
			if not s then break end
			if not braking and ((step.shaftX < cx and s.x >= brakeX)
				or (step.shaftX > cx and s.x <= brakeX)) then
				Move.release()
				braking = true
			end
			if s.grounded then
				Move.release()
				if math.floor(s.y - 0.0001) == step.y then
					return Move.walkTo(step.x + 0.5, { timeout = 2, tol = 0.35 }) and landed()
				end
				return false
			end
			task.wait(0.02)
		end
		Move.release()
		return false
	end
	if step.kind == "jump" then
		local W = Bind.getW()
		-- Platform satu arah (id 102) tepat di atas kepala = tangga antar
		-- lantai. Cukup berdiri di kolomnya lalu lompat lurus menembus
		-- platform; tidak perlu geser kiri/kanan dulu seperti lompat tepi.
		local platformAbove = false
		if W and W.fg and step.x == cx then
			for dy = 1, 3 do
				local row = W.fg[cy - dy]
				if not row then
					break
				end
				if row[cx] == 102 then
					platformAbove = true
					break
				end
				if Bind.solid(cx, cy - dy) then
					break
				end
			end
		end
		-- Platform tepi harus dilompati dekat sisi poros, karena dinding
		-- lantai atas tepat di sampingnya menahan tubuh bila terlalu tengah.
		local center = cx + 0.5
		if not platformAbove and W and W.fg and W.fg[cy + 1] and W.fg[cy + 1][cx] == 102 then
			if Bind.solid(cx + 1, cy - 1) then
				center = cx + 0.12
			elseif Bind.solid(cx - 1, cy - 1) then
				center = cx + 0.88
			end
		end
		-- Lompat tegak lewat platform hanya berhasil kalau SELURUH badan ada
		-- di kolom platform. Kalau badan masih menyentuh kolom sebelah, kepala
		-- membentur lantai/dirt di atas kolom itu dan lompatan tidak jadi.
		local tol = platformAbove and 0.10 or 0.12

		local function inColumn(s)
			if not s then
				return false
			end
			if platformAbove and math.floor(s.x) ~= step.x then
				return false
			end
			return math.abs(s.x - center) <= tol
		end

		-- Koreksi halus: pulsa arah sangat pendek sampai pusat badan tepat di
		-- tengah tile platform. Dipakai setelah walkTo maupun saat walkTo
		-- berhenti terlalu jauh dari tengah.
		local function fineAlign()
			local s = Bind.state()
			if not s or not s.grounded then
				return nil
			end
			for _ = 1, 16 do
				if inColumn(s) then
					Move.release()
					return s
				end
				local dx = center - s.x
				local key = dx > 0 and KeyRight or KeyLeft
				Move.hold(key)
				local untilT = os.clock() + math.clamp(math.abs(dx) / 6, 0.02, 0.10)
				while os.clock() < untilT do
					local n = Bind.state()
					if not n then
						break
					end
					if inColumn(n) then
						break
					end
					s = n
					task.wait(0.008)
				end
				Move.release()
				s = Bind.state()
				if not s or not s.grounded then
					return nil
				end
				task.wait(0.02)
			end
			return inColumn(s) and s or nil
		end

		local function align()
			local s = Bind.state()
			if not s or not s.grounded then
				return nil
			end
			if not inColumn(s) then
				-- walkTo menangani overshoot key-up jauh lebih baik daripada
				-- menekan kiri/kanan bergantian di sini.
				Move.walkTo(center, {
					timeout = platformAbove and 1.8 or 1.0,
					tol = tol * 0.5,
					recover = false,
				})
				s = Bind.state()
				if not inColumn(s) then
					s = fineAlign()
				end
			end
			Move.release()
			if not inColumn(s) then
				return nil
			end
			return s
		end

		for attempt = 1, 2 do
			if not aliveFn() then
				return false
			end
			local ready = align()
			if not ready then
				Move.release()
				return false
			end
			-- Cooldown lompat dipatuhi sebelum menekan tombol.
			local waitFor = (Move.lastJumpAt or 0) + 0.72 - os.clock()
			if waitFor > 0 then
				task.wait(waitFor)
			end
			if not aliveFn() then
				return false
			end
			if not platformAbove and step.x ~= cx then
				Move.hold(step.x > cx and KeyRight or KeyLeft)
				task.wait(rnd(0.03, 0.08))
			end
			local tookOff = Move.jump()
			Move.release()
			if not tookOff then
				local now = Bind.state()
				if not now or not now.grounded then
					-- Sudah di udara walau tombol terasa gagal.
					tookOff = true
				elseif attempt == 2 then
					return false
				else
					task.wait(0.12)
				end
			end
			if tookOff then
				local deadline = os.clock() + 1.6
				local settled = false
				while aliveFn() and os.clock() < deadline do
					local s = Bind.state()
					if not s then
						break
					end
					if not platformAbove and math.abs(s.x - (step.x + 0.5)) <= 0.30 then
						Move.release()
					end
					if landed() then
						Move.release()
						return true
					end
					if s.grounded and os.clock() - (Move.lastJumpAt or 0) > 0.4 then
						settled = true
						break
					end
					task.wait(0.03)
				end
				Move.release()
				if not settled then
					break
				end
				local after = Bind.state()
				if after and after.grounded then
					local ax = math.floor(after.x)
					local ay = math.floor(after.y - 0.0001)
					if ax ~= cx or ay ~= cy then
						-- Mendarat di tile lain tetap kemajuan (kadang berhenti
						-- satu lantai di bawah sasaran); moveTo menghitung
						-- ulang dari posisi nyata.
						if Path.standable(ax, ay) then
							return true
						end
					end
				end
				-- Mendarat kembali di titik awal: ulangi sekali dari posisi
				-- yang sudah disejajarkan lagi.
			end
		end
		Move.release()
		return false
	end
	return false
end

-- Jalan ke tile (tx, ty). Return true kalau sampai.
function Path.moveTo(tx, ty, aliveFn)
	aliveFn = aliveFn or function()
		return true
	end
	local goalKey = keyOf(tx, ty)
	local path, idx, expect = nil, 1, nil
	local failedTransitions = 0
	local recovered = false
	local startGen = Move.gen
	local deadline = os.clock() + 120
	for _ = 1, 400 do
		-- Tombol Stop atau reload hub harus langsung menghentikan pencarian,
		-- bukan menyisakan loop pathfinding yang membuat client berat.
		if not aliveFn() or Move.gen ~= startGen or os.clock() > deadline then
			Move.release()
			return false
		end
		local s = Bind.state()
		if not s then
			Move.release()
			return false
		end
		local cx, cy = math.floor(s.x), math.floor(s.y - 0.0001)
		if cx == tx and cy == ty and s.grounded then
			Move.release()
			return true
		end
		if path and expect and (cx ~= expect.x or cy ~= expect.y) then
			path = nil
		end
		if not path then
			local dist, parent = Path.explore(cx, cy, 6000)
			if not dist or dist[goalKey] == nil then
				Move.release()
				-- Dari pojok/tepi world pathfinder sering tidak menemukan
				-- jalan sama sekali. Geser dulu, lalu hitung ulang sekali.
				if not recovered and Move.edgeStuck() and Move.recover() then
					recovered = true
					task.wait(0.2)
					continue
				end
				return false
			end
			path = Path.reconstruct(parent, keyOf(cx, cy), goalKey)
			idx = 1
		end
		local step = path[idx]
		if not step then
			Move.release()
			return true
		end
		local firstStep = step
		local stepCount = 1
		if step.kind == "walk" then
			local direction = step.x > cx and 1 or -1
			local endX = step.x
			while path[idx + stepCount] do
				local nextStep = path[idx + stepCount]
				if nextStep.kind ~= "walk" or nextStep.y ~= cy
					or nextStep.x ~= endX + direction then
					break
				end
				endX = nextStep.x
				stepCount += 1
			end
			if stepCount > 1 then
				step = path[idx + stepCount - 1]
			end
		end
		if not pathStep(cx, cy, step, aliveFn) then
			Move.release()
			local landed = Bind.state()
			local moved = landed and landed.grounded
				and not (math.floor(landed.x) == cx and math.floor(landed.y - 0.0001) == cy)
			-- Catat transisi pertama yang gagal. Tanpa ini pathfinder akan
			-- menawarkan jalur yang sama lagi pada percobaan berikutnya.
			-- Kalau karakter tetap pindah tile, jangan blokir: lompat yang
			-- menembus platform sering berhenti satu lantai lebih rendah dan
			-- jalur baru dari posisi itu masih valid.
			if firstStep.kind ~= "walk" and not moved then
				Path.blockEdge(cx, cy, firstStep.x, firstStep.y, 12)
			end
			if not landed or not landed.grounded or not moved then
				return false
			end
			failedTransitions += 1
			if failedTransitions >= 3 then return false end
			path, expect = nil, nil
			task.wait(0.3)
		else
			expect = { x = step.x, y = step.y }
			idx += stepCount
		end
	end
	Move.release()
	return false
end

-- Data pohon (upvalue spliceAt) dipakai untuk cek matang dan sisa waktu.
local function factoryEnsureTreeMap(W)
	if Factory.treeMapWorld ~= W then
		Factory.treeMap = nil
		Factory.treeMapWorld = W
	end
	if Factory.treeMap then
		return Factory.treeMap
	end
	-- findFnByWorld itu getgc scan; jangan diulang tiap tile kalau gagal.
	if Factory.treeMapMissAt and os.clock() - Factory.treeMapMissAt < 5 then
		return nil
	end
	-- treeLook menyimpan sprite pohon yang dekat kamera saja. Data semua
	-- pohon ada di upvalue spliceAt; setiap entri punya waktu tanam p.
	local fn = findFnByWorld("spliceAt", W)
	local ok, upvalues = false, nil
	if fn then
		ok, upvalues = pcall(debug.getupvalues, fn)
	end
	if ok and type(upvalues) == "table" then
		for _, candidate in ipairs(upvalues) do
			if type(candidate) == "table" then
				local _, sample = next(candidate)
				if type(sample) == "table" and type(sample.p) == "number" then
					Factory.treeMap = candidate
					break
				end
			end
		end
	end
	if not Factory.treeMap then
		Factory.treeMapMissAt = os.clock()
	end
	return Factory.treeMap
end

local function factoryTreeRipe(W, x, y, seedId)
	if tileId(x, y) ~= seedId then
		return false
	end
	local treeMap = factoryEnsureTreeMap(W)
	local tree = treeMap and treeMap[y * W.w + x]
	return type(tree) == "table" and type(tree.p) == "number"
		and tree.p + (Factory.seedGrow or 0) <= workspace:GetServerTimeNow()
end

-- Jumlah pohon yang masih tumbuh dan sisa waktu pohon terdekat. Status "diam"
-- tanpa angka membuat pemain mengira bot hang, padahal cuma menunggu matang.
local function factoryGrowInfo(W, seedId)
	local treeMap = factoryEnsureTreeMap(W)
	local w = tonumber(W.w) or 100
	local rows = W.fg
	if not treeMap or not rows then
		return 0, nil
	end
	local now = workspace:GetServerTimeNow()
	local grow = Factory.seedGrow or 0
	local count, soonest = 0, nil
	for key, tree in pairs(treeMap) do
		if type(tree) == "table" and type(tree.p) == "number" then
			local y = math.floor(key / w)
			local x = key - y * w
			if rows[y] and rows[y][x] == seedId then
				local left = tree.p + grow - now
				if left > 0 then
					count += 1
					if not soonest or left < soonest then
						soonest = left
					end
				end
			end
		end
	end
	return count, soonest
end

local function factoryDuration(sec)
	sec = math.max(0, math.floor(tonumber(sec) or 0))
	if sec >= 3600 then
		return string.format("%dj %02dm", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
	elseif sec >= 60 then
		return string.format("%dm %02ds", math.floor(sec / 60), sec % 60)
	end
	return string.format("%ds", sec)
end

-- Contoh: "866 pohon tumbuh, terdekat ~17j 33m".
local function factoryGrowDesc(W, seedId)
	local count, soonest = factoryGrowInfo(W, seedId)
	if count <= 0 then
		return "tidak ada pohon seed ini di world"
	end
	local eta = soonest and ("terdekat ~" .. factoryDuration(soonest)) or "waktu matang tidak terbaca"
	return string.format("%d pohon tumbuh, %s", count, eta)
end

local function factoryHasRipeTree(W, seedId)
	for y = 0, (tonumber(W.h) or 60) - 1 do
		local row = W.fg and W.fg[y]
		if row then
			for x = 0, (tonumber(W.w) or 100) - 1 do
				if row[x] == seedId and factoryTreeRipe(W, x, y, seedId) then
					return true
				end
			end
		end
	end
	return false
end

local function factoryTarget(W, state, seedId, blocked, onlyKind)
	local cy = math.floor(state.y - 0.0001)
	local dist = Path.explore(math.floor(state.x), cy, 6000)
	if not dist then
		return nil
	end
	local function closest(kind, floorMode, allowSelf)
		local best, bestDistance
		for y = 0, (tonumber(W.h) or 60) - 2 do
			local inFloor = floorMode == nil
				or (floorMode == "same" and y == cy)
				or (floorMode == "below" and y > cy)
				or (floorMode == "above" and y < cy)
			local rowBlocked = kind == "plant" and blocked[kind .. ":row:" .. y]
			if inFloor and not (rowBlocked and rowBlocked > os.clock()) then
				local row = W.fg and W.fg[y]
				if row then
					for x = 0, (tonumber(W.w) or 100) - 1 do
						local key = seedId .. ":" .. kind .. ":" .. y .. ":" .. x
						if not blocked[key] or blocked[key] < os.clock() then
							-- Kolom paling kanan terlihat kosong di peta, tetapi tubuh
							-- pemain tertahan batas world sebelum bisa menanam di sana.
							local edgeTile = kind == "plant" and x >= (tonumber(W.w) or 100) - 1
							local reserved = Factory.cycle and kind == "plant"
								and Factory.workX == x and Factory.workY == y
							local suitable = not edgeTile and not reserved and (kind == "harvest"
								and row[x] == seedId and factoryTreeRipe(W, x, y, seedId)
								or kind == "plant" and row[x] == 0 and Bind.solid(x, y + 1))
							if suitable then
								-- Panen: berdiri di samping pohon, bukan di tile pohonnya
								-- (Sugar Cane tidak solid, jadi tile pohon terlihat bisa
								-- diinjak dan bot bisa memukul dari dalam pohon).
								local stands = (kind == "harvest" and not allowSelf)
									and { x - 1, x + 1 } or { x, x - 1, x + 1 }
								for _, standX in ipairs(stands) do
									-- Kolom paling kanan tidak bisa dipakai berdiri:
									-- tubuh pemain tertahan batas world. Tepi kiri
									-- masih bisa (pemain berdiri di x=0.3).
									local edgeStand = standX < 0 or standX >= (tonumber(W.w) or 100) - 1
									local standKey = keyOf(standX, y)
									local distance = dist[standKey]
									if not edgeStand and distance and (not bestDistance or distance < bestDistance) then
										best = { kind = kind, x = x, y = y, standX = standX, standY = y }
										bestDistance = distance
									end
								end
							end
						end
					end
				end
			end
		end
		return best
	end
	-- Target di lantai pemain didahulukan. Transisi turun/jatuh lebih bisa
	-- diandalkan daripada lompat naik, jadi lantai bawah dicoba sebelum
	-- lantai atas; lompat naik yang mustahil tidak dipaksakan.
	local function pick(kind)
		local function pass(mode)
			if kind == "harvest" then
				-- Samping dulu; tile pohon sendiri hanya dipakai kalau tidak
				-- ada sisi yang bisa dipijak.
				return closest(kind, mode, false) or closest(kind, mode, true)
			end
			return closest(kind, mode, true)
		end
		return pass("same") or pass("below") or pass("above")
	end
	if onlyKind == "harvest" or (not onlyKind and Factory.harvest) then
		local target = pick("harvest")
		if target then
			return target
		end
	end
	if onlyKind == "plant" or (not onlyKind and Factory.plant) then
		local inv = Bind.inv
		local ok, count = false, 0
		if inv then
			ok, count = pcall(inv.count, inv, seedId)
		end
		if ok and (tonumber(count) or 0) > 0 then
			return pick("plant")
		end
	end
	return nil
end

local function factoryWork(W, inv, target, seedId, gen)
	local startState = Bind.state()
	local checkedFloor = startState and math.floor(startState.y - 0.0001)
	local retargeted = false
	local alive = function()
		if not factoryAlive(gen) or W.name ~= Bind.name then
			return false
		end
		if target.kind == "harvest" then
			local current = Bind.state()
			local floor = current and math.floor(current.y - 0.0001)
			if floor and current.grounded and floor ~= checkedFloor then
				checkedFloor = floor
				-- Saat perjalanan pindah lantai, jangan terus mengejar
				-- target lama di atas jika sekarang ada pohon matang di
				-- lantai ini atau lantai bawah yang lebih dekat.
				local alternative = factoryTarget(W, current, seedId, {}, "harvest")
				if alternative and alternative.y >= floor and alternative.y ~= target.y then
					retargeted = true
					return false
				end
			end
		end
		return true
	end
	if not Path.moveTo(target.standX, target.standY, alive) then
		return false, retargeted and "retarget" or "path"
	end
	local arrived = Bind.state()
	if not factoryAlive(gen) or Factory.seedId ~= seedId or not (Factory[target.kind] or Factory.cycle)
		or not arrived or standingFloor(arrived) ~= target.y + 1 then
		return false, "floor"
	end
	local x, y = target.x, target.y
	if target.kind == "harvest" then
		-- Pukulan hanya sah dari dekat pohon. Kalau posisi pemain tidak
		-- sesuai, jangan memukul dari jauh: laporkan sebagai gagal jalan.
		if math.abs(math.floor(arrived.x) - x) > 1 then
			return false, "far"
		end
		if not factoryTreeRipe(W, x, y, seedId) then
			-- Data pohon bisa basi (pohon sudah dipanen/ditanam ulang).
			-- Buang cache supaya ripe dibaca ulang dari game.
			Factory.treeMap = nil
			return false, "gone"
		end
		for hit = 1, 12 do
			if not factoryAlive(gen) or tileId(x, y) ~= seedId then
				break
			end
			Dig.punch(x, y, true, hit > 1, false)
			task.wait(0.06)
		end
		if tileId(x, y) ~= 0 then
			return false, "break"
		end
		Factory.harvested += 1
		if Factory.cycle and not Factory.workX and tileId(x, y) == 0
			and Bind.solid(x, y + 1) and (Factory.baseLayer ~= "bg" or bgId(x, y) == 0) then
			local standX = Factory.baseAtSelf and x
				or (Path.standable(x - 1, y) and x - 1)
				or (Path.standable(x + 1, y) and x + 1)
			if standX then
				Factory.workX, Factory.workStandX, Factory.workY = x, standX, y
			end
		end
		if factoryAlive(gen) and Bind.solid(x, y + 1) then
			Move.walkTo(x + 0.5, { timeout = 3, tol = 0.28 })
		end
		local _, blockedId = collectDropsAtTile(W, inv, x, y, function()
			return factoryAlive(gen) and W.name == Bind.name
		end)
		if blockedId then
			Factory.collectNeedsRoom = true
			Factory.blockedDropId = blockedId
		end
		return true
	end
	if tileId(x, y) ~= 0 or not Bind.solid(x, y + 1) then
		return false, "gone"
	end
	local hasOK, count = pcall(inv.count, inv, seedId)
	if not hasOK or (tonumber(count) or 0) < 1 then
		return false, "seed"
	end
	pcall(inv.select, inv, seedId)
	local placed = pcall(Bind.setTile, "fg", x, y, seedId, false, false)
	if not placed or tileId(x, y) ~= seedId then
		return false, "place"
	end
	pcall(inv.remove, inv, seedId, 1)
	Factory.planted += 1
	task.wait(0.16)
	return true
end

local function factoryCount(inv, itemId)
	if not itemId or type(inv.count) ~= "function" then
		return 0
	end
	local ok, count = pcall(inv.count, inv, itemId)
	return ok and (tonumber(count) or 0) or 0
end

-- Cari tile kosong untuk PNB. Lantai pemain dicoba dulu supaya jalurnya
-- cuma jalan kaki (transisi turun/jatuh tidak selalu mendarat tepat).
local function factoryWorkSpot(W, state, blocked)
	local dist = Path.explore(math.floor(state.x), math.floor(state.y - 0.0001), 6000)
	if not dist then return nil end
	local cy = math.floor(state.y - 0.0001)
	local function scan(sameFloor)
		local bestX, bestStandX, bestY, bestDistance
		for y = 0, (tonumber(W.h) or 60) - 2 do
			if not sameFloor or y == cy then
				for x = 0, (tonumber(W.w) or 100) - 2 do
					local blockKey = "pnb:" .. y .. ":" .. x
					local blockedUntil = blocked and blocked[blockKey]
					if (not blockedUntil or blockedUntil < os.clock())
						and tileId(x, y) == 0 and Bind.solid(x, y + 1)
						and (Factory.baseLayer ~= "bg" or bgId(x, y) == 0) then
						local candidates = Factory.baseAtSelf and { x } or { x - 1, x + 1 }
						for _, standX in ipairs(candidates) do
							local standKey = keyOf(standX, y)
							local distance = dist[standKey]
							if distance and (not bestDistance or distance < bestDistance) then
								bestX, bestStandX, bestY, bestDistance = x, standX, y, distance
							end
						end
					end
				end
			end
		end
		return bestX, bestStandX, bestY
	end
	local x, standX, y = scan(true)
	if x then
		return x, standX, y
	end
	return scan(false)
end

local function factoryPNBOne(W, inv, gen, blocked, skipCollect)
	local baseId = Factory.baseId
	if factoryCount(inv, baseId) < 1 then
		return false, "blocks"
	end
	local s = Bind.state()
	if not s then
		return false, "state"
	end
	-- Station dihitung saat dibutuhkan, bukan sekali di awal, supaya tidak
	-- menunjuk tile di lantai lain yang sudah tidak terjangkau.
	if not Factory.workX or not Factory.workY then
		Factory.workX, Factory.workStandX, Factory.workY = factoryWorkSpot(W, s, blocked)
	end
	local x, standX, y = Factory.workX, Factory.workStandX, Factory.workY
	if not x or not standX or not y then
		return false, "station"
	end
	local function releaseStation()
		Factory.workX, Factory.workStandX, Factory.workY = nil, nil, nil
	end
	if pnbTileId(W, Factory.baseLayer, x, y) ~= 0 or tileId(x, y) ~= 0
		or not Bind.solid(x, y + 1) then
		releaseStation()
		return false, "occupied"
	end
	local alive = function()
		return factoryAlive(gen) and W.name == Bind.name
	end
	if not Path.moveTo(standX, y, alive) then
		if blocked then
			blocked["pnb:" .. y .. ":" .. x] = os.clock() + 25
		end
		releaseStation()
		return false, "path"
	end
	local arrived = Bind.state()
	if not factoryAlive(gen) or not arrived or standingFloor(arrived) ~= y + 1
		or pnbTileId(W, Factory.baseLayer, x, y) ~= 0 or tileId(x, y) ~= 0 then
		if blocked then
			blocked["pnb:" .. y .. ":" .. x] = os.clock() + 25
		end
		releaseStation()
		return false, "position"
	end
	pcall(inv.select, inv, baseId)
	local placed = pcall(Bind.setTile, Factory.baseLayer, x, y, baseId, false, false)
	if not placed or pnbTileId(W, Factory.baseLayer, x, y) ~= baseId then
		return false, "place"
	end
	pcall(inv.remove, inv, baseId, 1)
	W.punchReady = os.clock() + 0.15
	task.wait(0.18)
	for hit = 1, 30 do
		if not factoryAlive(gen) or pnbTileId(W, Factory.baseLayer, x, y) ~= baseId then
			break
		end
		Dig.punch(x, y, false, hit > 1, Factory.baseId == 4, Factory.baseLayer == "bg")
		task.wait(0.07)
	end
	if pnbTileId(W, Factory.baseLayer, x, y) ~= 0 then
		return false, "break"
	end
	Factory.pnb += 1
	task.wait(0.3)
	if skipCollect then
		-- Mode hemat ruang: drop pecahan dibiarkan di lantai, tidak dijemput.
		return true
	end
	if factoryAlive(gen) and not Factory.baseAtSelf and Bind.solid(x, y + 1) then
		Move.walkTo(x + 0.5, { timeout = 3, tol = 0.28 })
	end
	local _, blockedId = collectDropsAtTile(W, inv, x, y, alive)
	if blockedId then
		Factory.collectNeedsRoom = true
		Factory.blockedDropId = blockedId
	end
	return true
end

local function factoryHasTrees(W, seedId)
	for y = 0, (tonumber(W.h) or 60) - 1 do
		local row = W.fg and W.fg[y]
		if row then
			for x = 0, (tonumber(W.w) or 100) - 1 do
				if row[x] == seedId then
					return true
				end
			end
		end
	end
	return false
end

local function factoryRoom(inv, itemId)
	local ok, room = pcall(inv.room, inv, itemId)
	return ok and (tonumber(room) or 0) or 0
end

local function factoryBaseDrops(W, baseId)
	if not baseId or type(W.dropList) ~= "function" then return {} end
	local ok, drops = pcall(W.dropList)
	if not ok or type(drops) ~= "table" then return {} end
	local result = {}
	for _, drop in ipairs(drops) do
		if type(drop) == "table" and drop.id == baseId and type(drop.uid) == "number"
			and type(drop.n) == "number" and drop.n > 0
			and type(drop.x) == "number" and type(drop.y) == "number"
			and not (Factory.ignoredDrops and (Factory.ignoredDrops[drop.uid] or 0) > os.clock())
			and (not Factory.dropFilter or Factory.dropFilter[drop.uid]) then
			table.insert(result, drop)
		end
	end
	return result
end

local function factoryCollectDrop(W, inv, state, blocked, gen)
	local drops = factoryBaseDrops(W, Factory.baseId)
	if #drops == 0 then
		-- Selesai (atau filter drop lama sudah habis): buka lagi semua drop.
		Factory.dropFilter = nil
		return "done", 0
	end
	local room = factoryRoom(inv, Factory.baseId)
	if room <= 0 then return "room", #drops end
	local dist = Path.explore(math.floor(state.x), math.floor(state.y - 0.0001), 6000)
	local best, bestCost, eligible = nil, nil, false
	for _, drop in ipairs(drops) do
		if room > 0 then
			eligible = true
			local y = math.floor(drop.y)
			local x = math.floor(drop.x)
			for _, standX in ipairs({ x, x - 1, x + 1 }) do
				local cost = dist and dist[keyOf(standX, y)]
				local dx, dy = drop.x - (standX + 0.5), drop.y - (y + 0.999)
				if cost and Path.standable(standX, y)
					and dx * dx + dy * dy <= 0.9 * 0.9
					and (not blocked["drop:" .. drop.uid] or blocked["drop:" .. drop.uid] < os.clock())
					and (not bestCost or cost < bestCost) then
					best, bestCost = { drop = drop, x = standX, y = y }, cost
				end
			end
		end
	end
	if not best then
		return eligible and "path" or "room", #drops
	end
	local alive = function() return factoryAlive(gen) and W.name == Bind.name end
	if not Path.moveTo(best.x, best.y, alive) then
		blocked["drop:" .. best.drop.uid] = os.clock() + 15
		return "path", #drops
	end
	Move.walkTo(best.x + 0.5, { timeout = 2, tol = 0.25 })
	local collected = collectDropsNearby(W, inv, Bind.state(), 0.9, Factory.dropFilter)
	if collected <= 0 then
		Factory.dropTakeFailures = Factory.dropTakeFailures or {}
		local uid = best.drop.uid
		local failures = (Factory.dropTakeFailures[uid] or 0) + 1
		Factory.dropTakeFailures[uid] = failures
		if failures >= 3 then
			Factory.ignoredDrops = Factory.ignoredDrops or {}
			Factory.ignoredDrops[uid] = os.clock() + 180
			return "ignored", #drops
		end
		if best.drop.n > room then return "room", #drops end
		blocked["drop:" .. best.drop.uid] = os.clock() + 10
		return "take", #drops
	end
	Factory.dropTakeFailures[best.drop.uid] = nil
	return "collected", collected
end

local function factoryHasPlantTile(W)
	for y = 0, (tonumber(W.h) or 60) - 2 do
		local row = W.fg and W.fg[y]
		if row then
			for x = 0, (tonumber(W.w) or 100) - 2 do
				if row[x] == 0 and Bind.solid(x, y + 1)
					and not (Factory.workX == x and Factory.workY == y) then
					return true
				end
			end
		end
	end
	return false
end

local factoryStoreSeeds

-- Kosongkan seluruh blok sebelum fase tanam.
local PNB_DRAIN_BATCH = 8

-- `drain` = slot blok penuh. PNB dipakai untuk membuat ruang, jadi drop tiap
-- blok jangan langsung diambil (200 -> 199 -> 200, tidak ada kemajuan).
-- Kalau ada drop lama di lantai: habiskan DULU semua blok di inventory (drop
-- pecahannya dibiarkan), baru jemput drop lama, lalu tanam/panen. Dengan
-- begitu slot benar-benar kosong dan siklus tidak berulang tiap 8 blok.
local function beginPNB(W, blocks, drain)
	Factory.phase = "pnb"
	Factory.pnbLowWater = 0
	Factory.pnbDraining = drain == true
	Factory.pnbDrainCount = 0
	Factory.pnbOldDrops = nil
	Factory.dropFilter = nil
	Factory.collectNeedsRoom = false
	if Factory.pnbDraining then
		local old, need = {}, 0
		if Factory.baseId then
			for _, d in ipairs(factoryBaseDrops(W, Factory.baseId)) do
				old[d.uid] = true
				need += math.max(1, math.floor(tonumber(d.n) or 1))
			end
		end
		local total = math.max(1, math.floor(tonumber(blocks) or 1))
		-- Ada drop lama: pecah semua blok sampai habis. Tanpa drop lama
		-- (mis. hanya butuh ruang panen), cukup batch kecil agar tidak
		-- menumpuk ratusan drop di lantai.
		local target = need > 0 and total or math.min(total, PNB_DRAIN_BATCH)
		Factory.pnbOldDrops = old
		Factory.pnbDrainTarget = target
		setFactoryStatus(need > 0
			and string.format("Factory: blok %s/200; pecah semua %d blok dulu, baru ambil %d drop lama",
				tostring(blocks or 0), target, need)
			or string.format("Factory: blok %s/200; pecah %d blok dulu untuk ruang",
				tostring(blocks or 0), target))
	end
end

-- Selesai memecah batch: jemput hanya drop lama (sebelum batch). Kalau tidak
-- ada drop lama, kembali panen dan biarkan drop pecahan di lantai.
local function finishPNBDrain(inv)
	local count = Factory.pnbDrainCount or 0
	local old = Factory.pnbOldDrops
	Factory.pnbDraining, Factory.pnbDrainCount, Factory.pnbDrainTarget, Factory.pnbOldDrops = false, 0, nil, nil
	local anyOld = false
	if old then
		for _ in pairs(old) do
			anyOld = true
			break
		end
	end
	local left = factoryCount(inv, Factory.baseId)
	if anyOld then
		Factory.dropFilter = old
		Factory.phase = "collect"
		setFactoryStatus(string.format("Factory: %d blok dipecah dulu (sisa %d); ambil drop lama", count, left))
	else
		Factory.dropFilter = nil
		Factory.phase = "harvest"
		setFactoryStatus(string.format("Factory: %d blok dipecah dulu (sisa %d); lanjut panen", count, left))
	end
end

local function factoryCycleStep(W, inv, state, seedId, blocked, gen)
	local blocks = factoryCount(inv, Factory.baseId)
	local seeds = factoryCount(inv, seedId)
	local room = factoryRoom(inv, Factory.baseId)
	local blockFull = blocks >= 200 or room == 0 or Factory.collectNeedsRoom == true

	if Factory.phase == "harvest" then
		local cy = math.floor(state.y - 0.0001)
		-- Blok penuh: panen cuma membuang drop (inv.room(id) == 0 membuat
		-- takeDrop mengembalikan 0), jadi kosongkan dulu lewat PNB.
		if blockFull and Factory.baseId then
			Factory.collectNeedsRoom = false
			beginPNB(W, blocks, true)
			return 0.1
		end
		-- Mode panen saja tidak punya PNB/tanam untuk mengosongkan blok.
		-- Kalau drop panen tidak muat, berhenti memukul pohon: kalau terus
		-- jalan, hasil panen tertinggal di belakang lalu hilang.
		if Factory.collectNeedsRoom and not Factory.baseId then
			local dropId = Factory.blockedDropId
			local dropRoom = dropId and factoryRoom(inv, dropId) or 0
			if dropRoom > 0 then
				Factory.collectNeedsRoom = false
				Factory.blockedDropId = nil
				local collected = collectDropsNearby(W, inv, state, 1.6)
				if collected > 0 then
					setFactoryStatus(string.format("Factory: ambil drop tertinggal +%d", collected))
					return 0.2
				end
			else
				local def = dropId and selectedItemDefinition(dropId) or nil
				local name = type(def) == "table" and (def.name or tostring(dropId)) or "hasil panen"
				Move.release()
				setFactoryStatus(string.format("Factory: %s penuh; panen ditahan supaya drop tidak tertinggal", name))
				return 1
			end
		end
		local target = factoryTarget(W, state, seedId, blocked, "harvest")
		if target then
			local worked, reason = factoryWork(W, inv, target, seedId, gen)
			if worked then
				Factory.harvestFailures = 0
				if Factory.harvestFailCount then
					Factory.harvestFailCount[seedId .. ":harvest:" .. target.y .. ":" .. target.x] = nil
				end
				task.wait(0.25)
				local _, needsRoom = collectDropsNearby(W, inv, Bind.state(), 1.35)
				if needsRoom then Factory.collectNeedsRoom = true end
				if factoryAlive(gen) then
					setFactoryStatus(string.format("Factory: harvest %d | blok %d/200",
						Factory.harvested, factoryCount(inv, Factory.baseId)))
				end
			else
				if reason == "retarget" then
					setFactoryStatus("Factory: pindah lantai; pilih pohon matang terdekat")
					return 0.1
				end
				local sameFloor = target.y == cy
				local key = seedId .. ":harvest:" .. target.y .. ":" .. target.x
				Factory.harvestFailCount = Factory.harvestFailCount or {}
				local fails = (Factory.harvestFailCount[key] or 0) + 1
				Factory.harvestFailCount[key] = fails
				local reasonText, blockFor
				if reason == "path" or reason == "floor" or reason == "far" then
					-- Karakter tidak sampai ke pohon. Ini bukan gagal panen:
					-- pohonnya tidak pernah dipukul.
					reasonText = "tidak bisa menjangkau pohon"
					blockFor = sameFloor and 4 or 5
				elseif reason == "gone" then
					reasonText = "pohon sudah tidak matang"
					blockFor = 20
				elseif reason == "break" then
					reasonText = "pohon tidak hancur"
					blockFor = 60
				else
					reasonText = "gagal panen"
					blockFor = 20
				end
				blocked[key] = os.clock() + blockFor
				Factory.harvestFailures = (Factory.harvestFailures or 0) + 1
				if factoryAlive(gen) then
					setFactoryStatus(string.format("Factory: %s X=%d Y=%d; coba tree lain",
						reasonText, target.x, target.y))
				end
			end
			return 0.18
		end
		local ripeElsewhere = factoryHasRipeTree(W, seedId)
		-- Beberapa target hanya ditunda beberapa detik setelah input gerak
		-- gagal. Jangan langsung pindah fase selama target itu sebenarnya
		-- bisa dicapai dari posisi sekarang.
		if ripeElsewhere and factoryTarget(W, state, seedId, {}, "harvest") then
			local now, soonest = os.clock(), math.huge
			for key, untilAt in pairs(blocked) do
				if type(key) == "string" and key:sub(1, #(seedId .. ":harvest:")) == seedId .. ":harvest:"
					and type(untilAt) == "number" and untilAt > now then
					soonest = math.min(soonest, untilAt - now)
				end
			end
			if soonest <= 5 then
				setFactoryStatus("Factory: mencoba ulang target panen terdekat")
				return math.min(0.5, soonest)
			end
		end
		-- Jika belum ada target panen yang dipilih, kerjakan blok/seed yang
		-- tersedia; fase grow akan mencoba tree lagi pada putaran berikutnya.
		if blocks <= 0 and seeds > 0 and factoryTarget(W, state, seedId, blocked, "plant") then
			Factory.phase = "plant"
			setFactoryStatus(string.format("Factory: target panen tertunda; lanjut tanam (%d seed)", seeds))
			return 0.1
		end
		if blocks <= 0 then
			Factory.phase = "grow"
			local desc = factoryGrowDesc(W, seedId)
			setFactoryStatus(ripeElsewhere
				and ("Factory: target panen tertunda; coba lagi setelah jeda (" .. desc .. ")")
				or ("Factory: menunggu " .. tostring(Factory.seedName or "tree") .. " matang â€” " .. desc))
			return 1
		end
		beginPNB(W, blocks)
		if ripeElsewhere then
			setFactoryStatus("Factory: target panen tertunda; lanjut PNB sambil coba ulang")
		else
			setFactoryStatus(string.format("Factory: tidak ada tree matang yang terjangkau di world, PNB %d blok", blocks))
		end
		return 0.1
	end

	if Factory.phase == "pnb" then
		if not Factory.baseId then
			-- Seed ini tidak punya blok pasangan untuk PNB; lompati fase PNB.
			Factory.pnbDraining, Factory.pnbDrainCount, Factory.pnbDrainTarget, Factory.pnbOldDrops, Factory.dropFilter = false, 0, nil, nil, nil
			Factory.phase = "plant"
			return 0.2
		end
		if seeds >= 200 then
			Factory.resumePNB = blocks > 0
			Factory.pnbDraining, Factory.pnbDrainCount, Factory.pnbDrainTarget, Factory.pnbOldDrops, Factory.dropFilter = false, 0, nil, nil, nil
			Factory.phase = "plant"
			setFactoryStatus(string.format("Factory: seed penuh %d/200; tanam dulu, sisa %d blok untuk PNB", seeds, blocks))
			return 0.1
		end
		-- Batch pecah blok selesai (atau blok sudah habis): sekarang jemput
		-- drop LAMA saja. Drop pecahan batch ini tetap di lantai.
		if Factory.pnbDraining and (Factory.pnbDrainCount >= (Factory.pnbDrainTarget or PNB_DRAIN_BATCH) or blocks <= 0) then
			finishPNBDrain(inv)
			return 0.2
		end
		if blocks <= 0 then
			Factory.pnbDraining, Factory.pnbDrainCount, Factory.pnbDrainTarget, Factory.pnbOldDrops = false, 0, nil, nil
			local hasDrops = #factoryBaseDrops(W, Factory.baseId) > 0
			Factory.phase = hasDrops and "collect" or "plant"
			Factory.pnbLowWater = nil
			setFactoryStatus(string.format("Factory: PNB selesai | blok %d, seed %d; %s", blocks, seeds,
				hasDrops and "ambil drop tertinggal" or "mulai tanam"))
			return 0.1
		end
		if Factory.pnbSkipUntil and Factory.pnbSkipUntil > os.clock() then
			if Factory.pnbDraining then
				-- Jalur ke tile kerja sedang diblokir; jangan tahan batch pecah
				-- blok sampai 20 detik, selesaikan saja.
				finishPNBDrain(inv)
				return 0.2
			end
			setFactoryStatus(string.format("Factory: menunggu jalur PNB; %d blok tersisa", blocks))
			return 1
		end
		local worked, reason = factoryPNBOne(W, inv, gen, blocked, Factory.pnbDraining)
		if worked then
			Factory.pnbPathFailures = 0
			if Factory.pnbDraining then
				Factory.pnbDrainCount += 1
				if factoryAlive(gen) then
					setFactoryStatus(string.format("Factory: pecah blok %d/%d (blok %d sisa); drop nanti dijemput",
						Factory.pnbDrainCount, Factory.pnbDrainTarget or PNB_DRAIN_BATCH,
						factoryCount(inv, Factory.baseId)))
				end
			elseif factoryAlive(gen) then
				setFactoryStatus(string.format("Factory: PNB %d | blok %d, seed %d",
					Factory.pnb, factoryCount(inv, Factory.baseId), factoryCount(inv, seedId)))
			end
		else
			if reason == "path" or reason == "position" or reason == "occupied" then
				Factory.pnbPathFailures += 1
				if Factory.pnbPathFailures >= 8 then
					Factory.pnbPathFailures = 0
					Factory.workX, Factory.workStandX, Factory.workY = nil, nil, nil
					Factory.pnbSkipUntil = os.clock() + 20
					setFactoryStatus("Factory: jalur PNB gagal; coba lagi dalam 20 detik")
					return 0.2
				end
				setFactoryStatus(string.format("Factory: tile PNB tidak terjangkau, cari tile lain (%d/8)",
					Factory.pnbPathFailures))
			elseif reason == "station" then
				Factory.pnbPathFailures = 0
				if Factory.pnbDraining then
					finishPNBDrain(inv)
					return 0.2
				end
				local ripe = factoryTarget(W, state, seedId, blocked, "harvest")
				if ripe and factoryWork(W, inv, ripe, seedId, gen) then
					setFactoryStatus("Factory: membuka tile kerja PNB dari tree matang")
				else
					setFactoryStatus(string.format("Factory: menunggu tile kerja PNB (%d blok tersisa)", blocks))
				end
				return 2
			elseif reason == "blocks" then
				if Factory.pnbDraining then
					-- Blok sudah habis di tengah drain: jangan lewatkan drop
					-- lama, selesaikan drain (jemput drop lama) dulu.
					finishPNBDrain(inv)
					return 0.2
				end
				Factory.pnbDraining, Factory.pnbDrainCount, Factory.pnbDrainTarget, Factory.pnbOldDrops, Factory.dropFilter = false, 0, nil, nil, nil
				Factory.phase = "plant"
				setFactoryStatus("Factory: blok PNB habis; lanjut tanam")
				return 0.2
			else
				Factory.stop("Factory: PNB gagal (" .. tostring(reason) .. ")")
			end
		end
		return worked and 0.3 or 1
	end

	if Factory.phase == "collect" then
		if seeds >= 200 then
			Factory.resumeCollect = true
			Factory.phase = "plant"
			setFactoryStatus("Factory: seed penuh 200/200; tanam sebelum lanjut ambil drop")
			return 0.1
		end
		local result, amount = factoryCollectDrop(W, inv, state, blocked, gen)
		if result == "done" then
			Factory.phase = "plant"
			setFactoryStatus("Factory: drop blok selesai diambil; mulai tanam")
		elseif result == "room" then
			if blocks > 0 then
				beginPNB(W, blocks, true)
				setFactoryStatus(string.format(
					"Factory: drop masih ada, ruang tidak cukup; pecah %s blok dulu (dari %s)",
					tostring(Factory.pnbDrainTarget or PNB_DRAIN_BATCH), tostring(blocks)))
			else
				Factory.stop("Factory: inventory penuh; tidak ada blok untuk PNB")
			end
		elseif result == "collected" then
			setFactoryStatus(string.format("Factory: mengambil drop blok +%d", amount))
		elseif result == "ignored" then
			setFactoryStatus("Factory: drop lokal ditolak berulang kali; lanjut target lain")
		else
			setFactoryStatus(string.format("Factory: mencoba ulang drop blok (%d tersisa, %s)", amount, result))
		end
		return result == "collected" and 0.15 or 1
	end

	if Factory.phase == "plant" then
		if seeds <= 0 then
			if Factory.resumePNB and blocks > 0 then
				Factory.resumePNB = false
				beginPNB(W, blocks)
				setFactoryStatus(string.format("Factory: seed habis; lanjut PNB %d blok", blocks))
			elseif Factory.resumeCollect then
				Factory.resumeCollect = false
				Factory.phase = "collect"
				setFactoryStatus("Factory: seed habis; lanjut ambil drop blok")
			else
				Factory.resumePNB = false
				Factory.phase = #factoryBaseDrops(W, Factory.baseId) > 0 and "collect" or "grow"
				setFactoryStatus("Factory: seed habis; cek drop, tree, dan sisa blok")
			end
			return 0.1
		end
		local target = factoryTarget(W, state, seedId, blocked, "plant")
		if target then
			local worked, reason = factoryWork(W, inv, target, seedId, gen)
			if worked then
				if factoryAlive(gen) then
					setFactoryStatus(string.format("Factory: plant %d | sisa seed %d",
						Factory.planted, factoryCount(inv, seedId)))
				end
			else
				local now = Bind.state() or state
				local sameFloor = target.y == math.floor(now.y - 0.0001)
				local pathFail = reason == "path" or reason == "floor" or reason == "far"
				if sameFloor then
					blocked[seedId .. ":plant:" .. target.y .. ":" .. target.x] =
						os.clock() + (pathFail and 45 or 10)
				else
					-- Tahan baris sebentar agar jalur lain dicoba, kemudian coba
					-- lagi selama seed masih ada. Timeout lama membuat Plant diam.
					blocked["plant:row:" .. target.y] = os.clock() + (pathFail and 25 or 10)
				end
				if factoryAlive(gen) then
					setFactoryStatus(string.format("Factory: gagal ke tile tanam X=%d Y=%d (%s); coba tile lain",
						target.x, target.y, tostring(reason or "tile berubah")))
				end
			end
			return 0.18
		end
		if factoryHasPlantTile(W) then
			setFactoryStatus(string.format("Factory: menunggu jalur tile tanam terbuka (%d seed tersisa)", seeds))
			return 2
		end
		local stored, reason = factoryStoreSeeds(W, inv, state, seedId, gen)
		if stored then
			Factory.phase = "grow"
			setFactoryStatus("Factory: tile tanam penuh; seed tersimpan di Display Box")
		else
			Factory.stop("Factory: penyimpanan berhenti: " .. tostring(reason))
		end
		return 0.3
	end

	-- Setelah seed habis, mulai lagi dari panen bila ada tree matang.
	-- Jika belum ada, lanjut PNB sisa blok atau tunggu pohon tumbuh.
	if Factory.resumePNB and blocks > 0 then
		Factory.resumePNB = false
		beginPNB(W, blocks)
		setFactoryStatus(string.format("Factory: lanjut PNB %d blok setelah tanam", blocks))
		return 0.1
	end
	if Factory.resumeCollect then
		Factory.resumeCollect = false
		Factory.phase = "collect"
		setFactoryStatus("Factory: lanjut ambil drop setelah tanam")
		return 0.1
	end
	local ripe = factoryTarget(W, state, seedId, blocked, "harvest")
	if ripe and not blockFull then
		Factory.phase = "harvest"
		setFactoryStatus("Factory: tree matang; mulai harvest lagi")
	elseif blocks > 0 then
		beginPNB(W, blocks)
		setFactoryStatus(string.format("Factory: lanjut PNB %d blok sambil menunggu tree", blocks))
	elseif seeds > 0 then
		Factory.phase = "plant"
		setFactoryStatus(string.format("Factory: tanam %d seed yang tersedia", seeds))
	elseif not factoryHasTrees(W, seedId) and blocks <= 0 then
		Factory.stop("berhenti: seed, blok, dan pohon pilihan sudah habis")
	else
		Factory.phase = "grow"
		if factoryHasRipeTree(W, seedId) then
			setFactoryStatus("Factory: tree matang terdeteksi, mencari jalur yang bisa dijangkau")
		else
			setFactoryStatus(string.format("Factory: menunggu %s matang â€” %s (panen %d, PNB %d, tanam %d)",
				Factory.seedName or "seed pilihan", factoryGrowDesc(W, seedId),
				Factory.harvested, Factory.pnb, Factory.planted))
		end
	end
	collectDropsNearby(W, inv, state, 0.9)
	return 1
end

local function startFactory()
	if Factory.running then
		return true
	end
	if Farm.running or PNB.running then
		setFactoryStatus("gagal: matikan Dirt Farm atau PNB terlebih dahulu")
		return false
	end
	Bind.resolve(true)
	if not Factory.seedId and type(Factory.resolveSeedName) == "function" then
		local ok, selected, reason = pcall(Factory.resolveSeedName)
		if not ok or not selected then
			setFactoryStatus(ok and reason or "gagal membaca nama seed")
			return false
		end
	end
	local W, inv = Bind.W, Bind.inv
	local seedId = Factory.seedId
	local def = seedId and selectedItemDefinition(seedId)
	if not (W and inv and Bind.CT and Bind.hit and Bind.setTile and def and def.kind == "seed") then
		setFactoryStatus("gagal: data world, inventory, atau definisi seed belum terbaca")
		return false
	end
	local baseId, baseDef
	if Factory.cycle then
		local items = findItemDB()
		baseId = seedId - 1
		baseDef = items and items[baseId]
		-- Blok pasangan tidak harus bertanda "farmable": Dirt, Rock, dan Cave
		-- Background juga bisa dipasang lalu dihancurkan. Di ItemDB hanya
		-- Sugar Cane yang farmable = true, jadi syarat lama membuat factory
		-- menolak jalan untuk semua seed lain.
		if type(baseDef) ~= "table" or baseDef.kind == "seed"
			or def.name ~= (tostring(baseDef.name) .. " Seed") or Dig.protectedIds[baseId] then
			baseId, baseDef = nil, nil
			log("PNB dimatikan: seed " .. tostring(seedId) .. " tidak punya pasangan blok yang bisa dipasang")
		end
	end
	local state = Bind.state()
	local floorY = state and standingFloor(state)
	if not floorY or not Path.standable(math.floor(state.x), floorY - 1) then
		setFactoryStatus("gagal: karakter harus berdiri di atas lantai")
		return false
	end
	-- Sekali saja: kalau client ini tidak bisa lompat, pathfinder hanya
	-- memakai jalan kaki dan turun supaya tidak mengejar tile di atas.
	local canJump = Path.probeJump()
	if canJump == false then
		log("lompat tidak berfungsi di client ini; pathfinder dibatasi ke jalan/turun")
	end
	Factory.running = true
	Factory.gen += 1
	Factory.treeMap = nil
	Factory.treeMapWorld = nil
	Factory.ignoredDrops = {}
	Factory.dropTakeFailures = {}
	Factory.harvested, Factory.planted = 0, 0
	Factory.pnb = 0
	Factory.phase = Factory.cycle and (#factoryBaseDrops(W, baseId) > 0 and "collect" or "harvest") or "manual"
	Factory.seedName = def.name or ("Seed " .. seedId)
	Factory.seedGrow = tonumber(def.grow) or 0
	Factory.baseId, Factory.baseName = baseId, baseDef and baseDef.name or nil
	Factory.baseLayer = baseDef and (baseDef.background == true and "bg" or "fg") or nil
	Factory.baseAtSelf = baseDef and (baseDef.background == true or baseDef.solid == false) or nil
	Factory.workX, Factory.workStandX, Factory.workY = nil, nil, nil
	Factory.pnbPathFailures = 0
	Factory.pnbSkipUntil = nil
	Factory.pnbLowWater = nil
	Factory.pnbDraining = false
	Factory.pnbDrainCount = 0
	Factory.pnbDrainTarget = nil
	Factory.pnbOldDrops = nil
	Factory.dropFilter = nil
	Factory.collectNeedsRoom = false
	Factory.blockedDropId = nil
	Factory.resumePNB = false
	Factory.resumeCollect = false
	if Factory.cycle and factoryCount(inv, seedId) >= 200 then
		Factory.phase = "plant"
		Factory.resumePNB = baseId ~= nil and factoryCount(inv, baseId) > 0
		Factory.resumeCollect = not Factory.resumePNB and #factoryBaseDrops(W, baseId) > 0
	end
	Factory.harvestFailures = 0
	Factory.harvestSkipUntil = nil
	Factory.harvestFailCount = {}
	Factory.homeWorld = W.name
	Factory.lastRejoinAt = 0
	-- Station PNB sengaja tidak dipilih di sini: lantai pemain bisa berubah
	-- selama factory jalan, jadi station dicari saat fase PNB dimulai.
	local gen, worldName = Factory.gen, W.name
	local blocked = {}
	local missingSince = nil
	setFactoryStatus(string.format("berjalan: %s, lantai Y=%d", Factory.seedName, floorY))
	task.spawn(function()
		local ok, err = pcall(function()
			while factoryAlive(gen) do
				local s = Bind.state()
				local currentW = Bind.getW()
				local inLobby, picker = worldPickerVisible()
				if not inLobby and s and s.dead == true then
					-- Karakter mati: jangan terus memukul dari posisi terakhir.
					Move.release()
					if Factory.status ~= "Factory: karakter mati; menunggu respawn" then
						setFactoryStatus("Factory: karakter mati; menunggu respawn")
					end
					task.wait(0.5)
				elseif inLobby or not s or not standingFloor(s) or not currentW or currentW.name ~= worldName then
					Move.release()
					missingSince = missingSince or os.clock()
					if not Factory.cycle then
						Factory.stop("berhenti: posisi pemain atau world berubah")
						break
					end
					if os.clock() - missingSince >= 2.5
						and os.clock() - Factory.lastRejoinAt >= 5 then
						Factory.lastRejoinAt = os.clock()
						setFactoryStatus("Factory: kembali dari lobby ke " .. worldName)
						local enterWorld = currentW and currentW.enter or W.enter
						if type(enterWorld) == "function" then
							local called, joined, reason, teleporting = pcall(enterWorld, worldName)
							if called and joined == true and not teleporting then
								closeWorldPicker(picker)
								log("Factory rejoin: berhasil ke " .. worldName)
							else
								local why = called and reason or joined
								log("Factory rejoin: " .. tostring(why))
								setFactoryStatus("Factory: masuk ulang " .. worldName .. " gagal; mencoba lagi")
							end
						end
						Bind.resolve(true)
					end
					task.wait(0.5)
				else
					if missingSince then
						Bind.resolve(true)
						if Bind.W and Bind.W.name == worldName then
							W, inv = Bind.W, Bind.inv or inv
						end
						blocked = {}
						missingSince = nil
						setFactoryStatus("Factory: kembali ke " .. worldName .. "; lanjut " .. Factory.phase)
					end
					local currentSeed = Factory.seedId
					local currentFloor = standingFloor(s)
					if Factory.cycle then
						task.wait(factoryCycleStep(W, inv, s, currentSeed, blocked, gen))
					else
						local paused = false
						if Factory.collectNeedsRoom then
							local dropId = Factory.blockedDropId
							local dropRoom = dropId and factoryRoom(inv, dropId) or 0
							if dropRoom > 0 then
								Factory.collectNeedsRoom = false
								Factory.blockedDropId = nil
								local picked = collectDropsNearby(W, inv, s, 1.6)
								if picked > 0 then
									setFactoryStatus(string.format("Factory: ambil drop tertinggal +%d", picked))
									task.wait(0.2)
									paused = true
								end
							else
								local dropDef = dropId and selectedItemDefinition(dropId) or nil
								local dropName = type(dropDef) == "table" and (dropDef.name or tostring(dropId)) or "hasil panen"
								Move.release()
								local msg = string.format("Factory: %s penuh; panen ditahan supaya drop tidak tertinggal", dropName)
								if Factory.status ~= msg then
									setFactoryStatus(msg)
								end
								task.wait(1)
								paused = true
							end
						end
						if not paused then
							local target = factoryTarget(W, s, currentSeed, blocked)
							if target then
								local worked, reason = factoryWork(W, inv, target, currentSeed, gen)
								if factoryAlive(gen) then
									if worked then
										setFactoryStatus(string.format("%s: panen %d, tanam %d (Y=%d)",
												Factory.seedName, Factory.harvested, Factory.planted, currentFloor))
									else
										blocked[currentSeed .. ":" .. target.kind .. ":" .. target.y .. ":" .. target.x] = os.clock() + 4
									end
								end
								task.wait(0.18)
							else
								collectDropsNearby(W, inv, s, 1.35)
								setFactoryStatus(string.format("%s: belum ada pohon matang â€” %s",
									Factory.seedName or "Auto Harvest/Plant", factoryGrowDesc(W, currentSeed)))
								task.wait(1)
							end
						end
					end
				end
			end
		end)
		if not ok and factoryAlive(gen) then
			log("Auto Harvest/Plant error: " .. tostring(err))
			Factory.stop("berhenti: terjadi error (lihat console)")
		end
	end)
	return true
end

function Factory.setMode(mode, on)
	if on and ((mode == "cycle" and (Factory.harvest or Factory.plant))
		or (mode ~= "cycle" and Factory.cycle)) then
		Factory.stop("beralih mode Auto Farming")
	end
	Factory[mode] = on
	if on then
		if startFactory() then
			if Factory.onMode then
				pcall(Factory.onMode)
			end
		else
			Factory[mode] = false
			if Factory.onMode then
				pcall(Factory.onMode)
			end
		end
	elseif Factory.running and not Factory.harvest and not Factory.plant and not Factory.cycle then
		Factory.stop("dimatikan dari toggle")
	end
end

--// ===== 8. UI (WindUI) =====
local WINDUI_URL = "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"
local WINDUI_CACHE = "HumanHub_WindUI.lua"

-- Sumber WindUI diambil sekali lalu disimpan di workspace executor. Kalau
-- GitHub lambat / diblokir, cache dipakai supaya window tetap muncul dan
-- script tidak menggantung menunggu HttpGet.
local function windUISource()
	if type(readfile) == "function" then
		local ok, cached = pcall(readfile, WINDUI_CACHE)
		if ok and type(cached) == "string" and #cached > 5000 then
			return cached, "cache"
		end
	end
	local got, done = nil, false
	task.spawn(function()
		local ok, body = pcall(function()
			return game:HttpGet(WINDUI_URL)
		end)
		if ok and type(body) == "string" and #body > 5000 then
			got = body
		end
		done = true
	end)
	local deadline = os.clock() + 20
	while not done and os.clock() < deadline do
		if Hub.dead then
			return nil, "batal"
		end
		task.wait(0.1)
	end
	if got and type(writefile) == "function" then
		pcall(writefile, WINDUI_CACHE, got)
	end
	return got, got and "unduh" or nil
end

local okLoad, WindUI = pcall(function()
	local src, from = windUISource()
	if not src then
		error("sumber WindUI tidak tersedia (GitHub lambat/diblokir, cache belum ada)", 0)
	end
	log("WindUI dari " .. tostring(from) .. " (" .. tostring(#src) .. " byte)")
	local fn, err = loadstring(src)
	if not fn then
		error("compile WindUI gagal: " .. tostring(err), 0)
	end
	return fn()
end)
if not okLoad or not WindUI then
	warn("[HumanHub] WindUI gagal dimuat, coba sekali lagi: " .. tostring(WindUI))
	if Hub.dead then
		return
	end
	-- WindUI kadang gagal sekali tepat setelah sisa GUI run lama dihapus
	-- (cloneref nil). Percobaan kedua hampir selalu berhasil.
	task.wait(0.2)
	-- Percobaan pertama bisa meninggalkan ScreenGui setengah jadi; hapus dulu
	-- supaya percobaan kedua tidak menumpuk dua window.
	pcall(function()
		local root = (gethui and gethui()) or game:GetService("CoreGui")
		for _, c in ipairs(root:GetChildren()) do
			if c.Name == "WindUI" then
				c:Destroy()
			end
		end
	end)
	okLoad, WindUI = pcall(function()
		local src = windUISource()
		if not src then
			error("sumber WindUI tidak tersedia", 0)
		end
		local fn, err = loadstring(src)
		if not fn then
			error("compile WindUI gagal: " .. tostring(err), 0)
		end
		return fn()
	end)
end
if not okLoad or not WindUI then
	warn("[HumanHub] gagal memuat WindUI: " .. tostring(WindUI))
	return
end

-- Instance ini bisa dimatikan reload lain saat masih menunggu/ memuat WindUI.
-- Tanpa cek ini, startup zombie lanjut membuat window kedua.
if Hub.dead then
	return
end

-- Sisa run lama sudah dibersihkan di bagian atas file, sebelum WindUI dimuat.
-- Jangan hapus ScreenGui "WindUI" setelah CreateWindow: WindUI memakai
-- container itu untuk tab, dan menghapusnya membuat Tab() error
-- ("Frame is not a valid member of ScrollingFrame").
local Window = WindUI:CreateWindow({
	Title = "Human Hub",
	Author = "Dirt Farm + PNB + Auto Factory",
	Icon = "person-standing",
	Size = UDim2.fromOffset(560, 460),
	Theme = "Dark",
	ToggleKey = Enum.KeyCode.RightShift,
})
Hub.Window = Window
Hub.claimGui()

local pnbTab = Window:Tab({ Title = "Auto Farming", Icon = "blocks" })
local guardTab = Window:Tab({ Title = "Penjaga World", Icon = "shield" })
local farmTab = Window:Tab({ Title = "Dirt Farm", Icon = "pickaxe" })
local moveTab = Window:Tab({ Title = "Gerak", Icon = "footprints" })
local infoTab = Window:Tab({ Title = "Info", Icon = "info" })

-- ---- Tab Auto Farming ----
local pnbSec = pnbTab:Section({ Title = "PNB (Place and Break)", Opened = true })
local pnbStatusPara
local pnbToggle

pnbSec:Paragraph({
	Title = "Cara pakai",
	Desc = "Pilih item farmable di hotbar, lalu nyalakan PNB. Background dan item non-solid seperti Pepper Tree dipasang pada tile pemain; blok solid dipasang di depan.",
})

pnbToggle = pnbSec:Toggle({
	Title = "PNB",
	Desc = "Otomatis memilih layer background atau foreground dari jenis item. Auto Collect aktif secara bawaan.",
	Value = false,
	Callback = function(on)
		if on then
			startPNB()
			if not PNB.running and pnbToggle and pnbToggle.Set then
				pcall(pnbToggle.Set, pnbToggle, false)
			end
		else
			PNB.stop("dimatikan dari toggle")
		end
	end,
})

pnbSec:Toggle({
	Title = "Auto Collect",
	Desc = "Item pada posisi pemain: ambil drop langsung. Blok solid di depan: dekati drop, ambil, lalu kembali jika inventory masih punya ruang.",
	Value = true,
	Callback = function(on)
		PNB.autoCollect = on
	end,
})

pnbStatusPara = pnbSec:Paragraph({ Title = "Status PNB", Desc = "idle" })

PNB.onStatus = function(message)
	if pnbStatusPara then
		if pnbStatusPara.SetDesc then
			pcall(pnbStatusPara.SetDesc, pnbStatusPara, message)
		elseif pnbStatusPara.SetTitle then
			pcall(pnbStatusPara.SetTitle, pnbStatusPara, "Status PNB: " .. message)
		end
	end
	if not PNB.running and pnbToggle and pnbToggle.Set then
		pcall(pnbToggle.Set, pnbToggle, false)
	end
end

-- ---- Auto Harvest / Auto Plant ----
local factorySec = pnbTab:Section({ Title = "Auto Harvest & Auto Plant", Opened = true })
factorySec:Paragraph({
	Title = "Cara kerja",
	Desc = "Pilih seed dari inventory. Factory panen, habiskan blok lewat PNB, lalu tanam. Jika tile tanam penuh, seed disimpan ke Display Box yang bisa dijangkau di world ini.",
})

local mobileSeedInput = game:GetService("UserInputService").TouchEnabled
local seedValues, seedByLabel = { "Pilih seed..." }, {}
if not mobileSeedInput then
	seedValues, seedByLabel = Factory.seedOptions()
end
local seedPlaceholder = "Pilih seed..."
Factory.seedId = nil
Factory.seedName = nil
local seedDropdown
if not mobileSeedInput then
	seedDropdown = factorySec:Dropdown({
		Title = "Pilih seed",
		Desc = "Pilih seed secara manual sebelum menyalakan fitur. Seed ini menentukan pohon yang dipanen dan ditanam.",
		Values = seedValues,
		Value = seedPlaceholder,
		Callback = function(label)
			local id = seedByLabel[label]
			if Factory.cycle and Factory.running and id ~= Factory.seedId then
				Factory.stop("seed berubah; nyalakan Auto Factory lagi")
			end
			Factory.seedId = id
			local def = id and selectedItemDefinition(id)
			Factory.seedName = def and def.name or nil
		end,
	})
end

local seedNameTyped = ""
local seedNameStatus = factorySec:Paragraph({
	Title = "Seed berdasarkan nama",
	Desc = "Ketik nama seed lalu tekan Pilih seed dari nama.",
})
local seedNameInput = factorySec:Input({
	Title = "Nama seed",
	Desc = "Contoh: Sugar Cane atau Sugar Cane Seed",
	Placeholder = "Nama seed di inventory...",
	Value = "",
	Type = "Input",
	Callback = function(value)
		seedNameTyped = tostring(value or "")
	end,
})

local function normalizedSeedName(value)
	local name = tostring(value or ""):lower():gsub("%s+", " ")
	name = name:gsub("^%s+", ""):gsub("%s+$", "")
	return name:gsub("%s+seed$", ""):gsub("%s+tree$", "")
end

local function currentSeedNameText()
	local typed = seedNameTyped
	if seedNameInput and type(seedNameInput.Value) == "string" and seedNameInput.Value ~= "" then
		typed = seedNameInput.Value
	end
	-- WindUI di mobile kadang belum memanggil Callback saat keyboard
	-- ditutup. Baca isi TextBox langsung ketika tombol/toggle ditekan.
	for _, root in ipairs({ uiRoot, Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui") }) do
		if root then
			for _, child in ipairs(root:GetDescendants()) do
				if child:IsA("TextBox") and child.PlaceholderText == "Nama seed di inventory..." then
					return child.Text
				end
			end
		end
	end
	return typed
end

Factory.resolveSeedName = function()
	local query = normalizedSeedName(currentSeedNameText())
	if #query < 3 then
		return nil, "Ketik nama seed (minimal 3 huruf) sebelum menyalakan Factory."
	end
	if not Bind.inv then Bind.resolve(true) end
	local inv = Bind.inv
	if not inv then
		return nil, "Inventory game belum terbaca oleh executor. Bind inv=NIL; coba jalankan ulang script di world."
	end
	local items = findItemDB()
	if not items then
		return nil, "Data nama item belum terbaca oleh executor. Bind itemDB=NIL."
	end
	local exact, partial = {}, {}
	for id, def in pairs(items) do
		if type(id) == "number" and type(def) == "table" and def.kind == "seed" then
			local ok, count = pcall(inv.count, inv, id)
			if ok and (tonumber(count) or 0) > 0 then
				local key = normalizedSeedName(def.name)
				if key == query then
					table.insert(exact, { id = id, name = def.name, count = count })
				elseif key:find(query, 1, true) then
					table.insert(partial, { id = id, name = def.name, count = count })
				end
			end
		end
	end
	local matches = #exact > 0 and exact or partial
	if #matches ~= 1 then
		return nil, #matches == 0 and "Seed itu tidak ada di inventory."
			or "Nama cocok dengan beberapa seed; ketik nama lebih lengkap."
	end
	local selected = matches[1]
	if Factory.running and selected.id ~= Factory.seedId then
		Factory.stop("seed berubah; nyalakan Auto Factory lagi")
	end
	Factory.seedId, Factory.seedName = selected.id, selected.name
	if seedNameStatus and seedNameStatus.SetDesc then
		pcall(seedNameStatus.SetDesc, seedNameStatus,
			string.format("Dipilih: %s [#%d] x%d", selected.name, selected.id, selected.count))
	end
	return selected.id
end

factorySec:Button({
	Title = "Pilih seed dari nama",
	Desc = "Gunakan ini jika daftar seed terus memuat di Android.",
	Callback = function()
		local selected, reason = Factory.resolveSeedName()
		if selected then
			setFactoryStatus("Seed dipilih: " .. (Factory.seedName or tostring(selected)))
		else
			if seedNameStatus and seedNameStatus.SetDesc then
				pcall(seedNameStatus.SetDesc, seedNameStatus, reason)
			end
			setFactoryStatus(reason)
		end
	end,
})

local function refreshSeedDropdown(values, byLabel)
	if not seedDropdown then return end
	if not values then
		values, byLabel = Factory.seedOptions()
	end
	seedByLabel = byLabel
	local selected = seedPlaceholder
	for _, label in ipairs(values) do
		if Factory.seedId and byLabel[label] == Factory.seedId then
			selected = label
			break
		end
	end
	seedDropdown:Refresh(values)
	seedDropdown:Select(selected)
	if Factory.cycle and Factory.running and byLabel[selected] ~= Factory.seedId then
		Factory.stop("seed berubah; nyalakan Auto Factory lagi")
	end
	Factory.seedId = byLabel[selected]
	local def = Factory.seedId and selectedItemDefinition(Factory.seedId)
	Factory.seedName = def and def.name or nil
end

if seedDropdown then
	factorySec:Button({
		Title = "Refresh daftar seed",
		Desc = "Perbarui seed yang tersedia setelah inventory berubah.",
		Callback = function() refreshSeedDropdown() end,
	})
	task.spawn(function()
		for _ = 1, 15 do
			task.wait(2)
			if _G.__HumanHub ~= Hub then return end
			local values, byLabel = Factory.seedOptions()
			if next(byLabel) then
				refreshSeedDropdown(values, byLabel)
				return
			end
		end
	end)
end

local harvestToggle, plantToggle, cycleToggle
harvestToggle = factorySec:Toggle({
	Title = "Auto Harvest",
	Desc = "Panen pohon matang dari seed yang dipilih di seluruh world yang bisa dijangkau.",
	Value = false,
	Callback = function(on)
		if not Factory.syncingUI then
			Factory.setMode("harvest", on)
		end
	end,
})
plantToggle = factorySec:Toggle({
	Title = "Auto Plant",
	Desc = "Tanam seed yang dipilih di tile kosong dengan lantai solid di bawahnya.",
	Value = false,
	Callback = function(on)
		if not Factory.syncingUI then
			Factory.setMode("plant", on)
		end
	end,
})
cycleToggle = factorySec:Toggle({
	Title = "Auto Factory",
	Desc = "Urutan: harvest, PNB sampai blok habis, lalu plant. Jika tile tanam penuh, simpan seed ke Display Box di world ini.",
	Value = false,
	Callback = function(on)
		if not Factory.syncingUI then
			Factory.setMode("cycle", on)
		end
	end,
})

local factoryStatusPara = factorySec:Paragraph({ Title = "Status Harvest/Plant", Desc = "idle" })
Factory.onStatus = function(message)
	if factoryStatusPara then
		if factoryStatusPara.SetDesc then
			pcall(factoryStatusPara.SetDesc, factoryStatusPara, message)
		elseif factoryStatusPara.SetTitle then
			pcall(factoryStatusPara.SetTitle, factoryStatusPara, "Status Harvest/Plant: " .. message)
		end
	end
end

-- Status juga ditulis ke TextLabel paragraf oleh thread yang membuat UI.
-- Paragraph.SetDesc tidak selalu terlihat berubah saat dipanggil dari thread
-- factory, dan thread itu bisa punya capability berbeda.
do
	local root = (gethui and gethui()) or game:GetService("CoreGui")
	local function findStatusLabel(inst)
		for _, c in ipairs(inst:GetChildren()) do
			if c:IsA("TextLabel") then
				local parent = c.Parent
				if parent and parent.Name == "TitleFrame" then
					for _, s in ipairs(parent:GetChildren()) do
						if s:IsA("TextLabel") and s ~= c and tostring(s.Text) == "Status Harvest/Plant" then
							return c
						end
					end
				end
			end
			local found = findStatusLabel(c)
			if found then
				return found
			end
		end
		return nil
	end
	Factory.statusLabel = findStatusLabel(root)
	task.spawn(function()
		local label = Factory.statusLabel
		while _G.__HumanHub == Hub do
			task.wait(0.3)
			if not label or not label.Parent then
				label = findStatusLabel(root)
				Factory.statusLabel = label
			end
			local message = Factory.status
			if label and label.Parent and message and label.Text ~= message then
				local ok = pcall(function()
					label.Text = message
				end)
				if not ok then
					return
				end
			end
		end
	end)
end
Factory.onMode = function()
	Factory.syncingUI = true
	if harvestToggle and harvestToggle.Set then
		pcall(harvestToggle.Set, harvestToggle, Factory.harvest)
	end
	if plantToggle and plantToggle.Set then
		pcall(plantToggle.Set, plantToggle, Factory.plant)
	end
	if cycleToggle and cycleToggle.Set then
		pcall(cycleToggle.Set, cycleToggle, Factory.cycle)
	end
	Factory.syncingUI = false
	if Factory.onCycleChanged then
		pcall(Factory.onCycleChanged, Factory.running and Factory.cycle)
	end
end

local function seedCountInDisplay(W, x, y, seedId)
	if not W.displays or type(W.displays.get) ~= "function" then return nil end
	local ok, contents = pcall(W.displays.get, x, y)
	if not ok then return nil end
	local count = 0
	if type(contents) == "table" then
		for _, entry in pairs(contents) do
			if type(entry) == "table" and entry[1] == seedId then
				count += tonumber(entry[2]) or 0
			end
		end
	end
	return count
end

local function nearestDisplayBox(W, state)
	local dist = Path.explore(math.floor(state.x), math.floor(state.y - 0.0001), 6000)
	if not dist then return nil end
	local best, bestDistance
	for y = 0, (tonumber(W.h) or 60) - 1 do
		local row = W.fg and W.fg[y]
		if row then
			for x = 0, (tonumber(W.w) or 100) - 1 do
				if row[x] == 1422 and Path.standable(x, y) then
					local distance = dist[keyOf(x, y)]
					if distance and (not bestDistance or distance < bestDistance) then
						best, bestDistance = { x = x, y = y }, distance
					end
				end
			end
		end
	end
	return best
end

factoryStoreSeeds = function(W, inv, state, seedId, gen)
	local alive = function()
		return factoryAlive(gen) and W.name == Bind.name
	end
	local box = nearestDisplayBox(W, state)
	if not box then return false, "tidak ada Display Box (id 1422) yang bisa dijangkau" end
	setFactoryStatus(string.format("Factory: menuju Display Box (%d,%d)", box.x, box.y))
	if not Path.moveTo(box.x, box.y, alive) then return false, "gagal mencapai Display Box" end
	local arrived = Bind.state()
	local okHere, hereX, hereY = pcall(W.displayHere, arrived and arrived.x or -1)
	if not arrived or not arrived.grounded or not okHere
		or hereX ~= box.x or hereY ~= box.y or tileId(box.x, box.y) ~= 1422 then
		return false, "posisi belum tepat di dalam Display Box"
	end
	if type(W.displayPut) ~= "function" then return false, "fungsi Display Box tidak tersedia" end
	for _ = 1, 20 do
		if not alive() then return false, "Factory dihentikan saat menyimpan seed" end
		local remaining = factoryCount(inv, seedId)
		if remaining <= 0 then return true end
		local beforeBox = seedCountInDisplay(W, box.x, box.y, seedId)
		if beforeBox == nil then return false, "isi Display Box tidak terbaca" end
		local called, err = pcall(W.displayPut, box.x, box.y, seedId, remaining, box.x + 0.5)
		if not called then return false, "gagal mengirim seed: " .. tostring(err) end
		local deadline = os.clock() + 8
		local confirmed = false
		while alive() and os.clock() < deadline do
			local afterBox = seedCountInDisplay(W, box.x, box.y, seedId)
			if afterBox and afterBox > beforeBox then
				confirmed = true
				break
			end
			task.wait(0.15)
		end
		if not confirmed then
			if factoryCount(inv, seedId) >= remaining then
				return false, "server menolak Display Box; akun perlu level 10 atau Discord terverifikasi"
			end
			return false, "server belum mengonfirmasi seed masuk Display Box"
		end
		setFactoryStatus(string.format("Factory: seed masuk Display Box; sisa %d", factoryCount(inv, seedId)))
		task.wait(0.35)
	end
	return false, "batas percobaan Display Box tercapai"
end

Factory.storeSeeds = factoryStoreSeeds

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
		PNB.stop("dihentikan manual")
		Factory.stop("dihentikan manual")
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

local function moveModeName()
	return Move.backend == "touch" and "sentuh" or "VIM"
end

local moveStatus = moveSec:Paragraph({ Title = "Status gerak", Desc = "belum dicek" })

local function refreshMoveStatus()
	local s = Bind.state()
	local W = Bind.getW()
	if not s then
		return "state pemain tidak terbaca"
	end
	local cx, cy = math.floor(s.x), math.floor(s.y - 0.0001)
	local text = string.format(
		"mode=%s | touch=%s | x=%.2f y=%.2f | tile=%d,%d | bisa dipijak=%s | dunia=%s",
		moveModeName(),
		Touch.ready and "siap" or "belum",
		s.x, s.y, cx, cy,
		tostring(moveStandable(W, cx, cy)),
		tostring(W and W.name)
	)
	if moveStatus.SetDesc then
		pcall(moveStatus.SetDesc, moveStatus, text)
	end
	return text
end

local playerInput = game:GetService("UserInputService")
local autoTouch = playerInput.TouchEnabled and not playerInput.KeyboardEnabled

moveSec:Toggle({
	Title = "Input sentuh MobileGui (Android)",
	Desc = "Hub menekan tombol Left/Right/Jump bawaan game, bukan key VirtualInputManager. Kalau karakter tidak bergerak di HP, pastikan ini menyala.",
	Value = Move.forceTouch or autoTouch,
	Callback = function(on)
		Move.forceTouch = on
		Move.noTouch = not on
		Move.release()
		Move.backend = "vim"
		if on then
			if Move.preferTouch() then
				WindUI:Notify({ Title = "Gerak", Content = "Input sentuh MobileGui aktif.", Duration = 3 })
			else
				WindUI:Notify({ Title = "Gerak", Content = "MobileGui tidak ditemukan; tetap VIM.", Duration = 3 })
			end
		end
		refreshMoveStatus()
	end,
})

local function testWalk(dir)
	if Farm.running or PNB.running or Factory.running then
		WindUI:Notify({ Title = "Gerak", Content = "Matikan fitur auto farming dulu.", Duration = 3 })
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
		local now = Bind.state()
		WindUI:Notify({
			Title = "Gerak",
			Content = ok
				and string.format("Sampai di x=%d (mode %s)", target, moveModeName())
				or string.format("Berhenti di x=%.1f (mode %s)", now and now.x or -1, moveModeName()),
			Duration = 4,
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

moveSec:Button({
	Title = "Cek status gerak",
	Callback = function()
		WindUI:Notify({ Title = "Status Gerak", Content = refreshMoveStatus(), Duration = 6 })
	end,
})

moveSec:Button({
	Title = "Tes lompat di tempat",
	Callback = function()
		if Farm.running or PNB.running or Factory.running then
			WindUI:Notify({ Title = "Gerak", Content = "Matikan fitur auto farming dulu.", Duration = 3 })
			return
		end
		local before = Bind.state()
		if not before then
			WindUI:Notify({ Title = "Gerak", Content = "State pemain tidak terbaca.", Duration = 3 })
			return
		end
		local y0 = before.y
		if not Move.jump() then
			WindUI:Notify({ Title = "Gerak", Content = "Tidak bisa lompat sekarang (sedang di udara / baru lompat).", Duration = 3 })
			return
		end
		task.spawn(function()
			local minY = y0
			local deadline = os.clock() + 1.0
			while os.clock() < deadline do
				local now = Bind.state()
				if now then
					minY = math.min(minY, now.y)
				end
				task.wait(0.02)
			end
			WindUI:Notify({
				Title = "Gerak",
				Content = string.format(
					"Lompat %s: naik %.2f tile (mode %s)",
					minY < y0 - 0.5 and "berhasil" or "TIDAK terbaca",
					y0 - minY,
					moveModeName()
				),
				Duration = 4,
			})
		end)
	end,
})

moveSec:Paragraph({
	Title = "Cara kerja",
	Desc = "Di PC hub memakai A/D + Space. Di Android hub menekan tombol MobileGui game. Karakter yang terjepit di tepi world digeser otomatis lalu path dihitung ulang.",
})

-- ---- Penjaga world ----
local guardSec = guardTab:Section({ Title = "Penjaga World", Opened = true })
local Guard = { enabled = false, world = nil, seen = {}, baseline = false, busy = false }
local guardStatus = guardSec:Paragraph({ Title = "Status penjaga", Desc = "nonaktif" })

local function guardMessage(message)
	if guardStatus.SetDesc then
		pcall(guardStatus.SetDesc, guardStatus, message)
	end
end

local function worldPlayers()
	local ok, matches = pcall(function() return filtergc("table", { Keys = { "reset", "showNames", "list" } }) end)
	if not ok or type(matches) ~= "table" then
		return nil
	end
	if type(matches[1]) ~= "table" then
		matches = { matches }
	end
	for _, ctrl in ipairs(matches) do
		if type(ctrl) == "table" and type(ctrl.reset) == "function" and type(ctrl.update) == "function" then
			local okUps, ups = pcall(debug.getupvalues, ctrl.reset)
			if okUps and type(ups) == "table" and type(ups[1]) == "table" then
				return ups[1]
			end
		end
	end
	return nil
end

local function staffRole(player)
	if game.CreatorType ~= Enum.CreatorType.Group or not game.CreatorId then
		return nil
	end
	local okRole, role = pcall(player.GetRoleInGroup, player, game.CreatorId)
	local okRank, rank = pcall(player.GetRankInGroup, player, game.CreatorId)
	if not okRole or not okRank then
		return nil
	end
	local name = string.lower(tostring(role))
	return tonumber(rank) >= 200 or name:find("mod", 1, true) ~= nil
		or name:find("dev", 1, true) ~= nil or name:find("admin", 1, true) ~= nil
		or name:find("owner", 1, true) ~= nil or name:find("staff", 1, true) ~= nil
end

local function worldAuthority(W, userId)
	local lock = W.lock
	if type(lock) ~= "table" then
		return false
	end
	if tonumber(lock.owner) == userId then
		return true
	end
	if type(lock.access) == "table" then
		for _, entry in pairs(lock.access) do
			if type(entry) == "table" and tonumber(entry[1]) == userId then
				return true
			end
		end
	end
	return false
end

local function canBanInWorld(W)
	local myId = Players.LocalPlayer and Players.LocalPlayer.UserId
	return myId ~= nil and worldAuthority(W, myId)
end

local function banWorldPlayer(name)
	local ok, matches = pcall(function() return filtergc("table", { Keys = { "setShown", "setWorld", "isTyping", "add", "onCommand" } }) end)
	if not ok or type(matches) ~= "table" or not name:match("^[%w_]+$") then
		return false
	end
	if type(matches[1]) ~= "table" then
		matches = { matches }
	end
	for _, chat in ipairs(matches) do
		if type(chat) == "table" and type(chat.onCommand) == "function" then
			local sent, handled = pcall(chat.onCommand, "/ban " .. name)
			return sent and handled ~= false
		end
	end
	return false
end

local function randomWorldName()
	local letters = {}
	for i = 1, 7 do
		letters[i] = string.char(math.random(65, 90))
	end
	return table.concat(letters)
end

guardSec:Paragraph({
	Title = "Mengikuti Auto Factory",
	Desc = "Aktif selama Auto Factory berjalan. Staf grup: keluar ke world acak; pemain biasa baru: /ban bila punya akses world.",
})

Factory.onCycleChanged = function(on)
	if Guard.enabled == on then return end
	Guard.enabled = on
	Guard.world, Guard.seen, Guard.baseline, Guard.busy = nil, {}, false, false
	guardMessage(on and "memantau pemain selama Auto Factory berjalan" or "nonaktif")
end
Factory.onCycleChanged(Factory.running and Factory.cycle)

task.spawn(function()
	while _G.__HumanHub == Hub do
		task.wait(1)
		if Guard.enabled and not Guard.busy and not worldPickerVisible() then
			local W = Bind.W
			local others = W and worldPlayers()
			if W and type(W.name) == "string" and others then
				if Guard.world ~= W.name then
					Guard.world, Guard.seen, Guard.baseline = W.name, {}, false
				end
				local present = {}
				for uid, data in pairs(others) do
					local id = tonumber(type(data) == "table" and data.userId or uid)
					if id and id ~= Players.LocalPlayer.UserId then
						present[id] = true
						local player = Players:GetPlayerByUserId(id)
						local isStaff = player and staffRole(player)
						if worldAuthority(W, id) then
							Guard.seen[id] = true
						elseif isStaff == true then
							Guard.busy = true
							if Farm.running then Farm.stop("staf masuk world") end
							if PNB.running then PNB.stop("staf masuk world") end
							if Factory.running then Factory.stop("staf masuk world") end
							local destination = randomWorldName()
							guardMessage("staf terdeteksi; pindah ke " .. destination)
						local called = false
							if type(W.enter) == "function" then
							called = pcall(W.enter, destination)
							end
						if not called then
								guardMessage("gagal pindah world; bot dihentikan")
								Guard.enabled = false
							end
							break
						elseif isStaff == false and Guard.baseline and not Guard.seen[id] then
							if canBanInWorld(W) then
								local name = type(data) == "table" and data.name or nil
								name = type(name) == "string" and name ~= "" and name or player.Name
								guardMessage(banWorldPlayer(name) and ("perintah ban dikirim: " .. name) or ("gagal mengirim ban: " .. name))
							else
								guardMessage("pemain masuk, tetapi tidak punya akses ban di world")
							end
						end
						if isStaff ~= nil or not Guard.baseline then Guard.seen[id] = true end
					end
				end
				for id in pairs(Guard.seen) do
					if not present[id] then Guard.seen[id] = nil end
				end
				Guard.baseline = true
			end
		end
	end
end)

-- ---- Tab Info ----
infoTab:Section({ Title = "Fitur", Opened = true }):Paragraph({
	Title = "Sudah ada",
	Desc = "1) Auto Factory: harvest hingga blok penuh/tak ada tree, PNB hingga blok habis/seed penuh, plant hingga seed habis, lalu ulangi. 2) Auto Harvest/Plant terpisah. 3) PNB. 4) Dirt Farm.",
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
if pnbTab.Select then
	pcall(pnbTab.Select, pnbTab)
end
WindUI:Notify({ Title = "Human Hub", Content = "Siap. Pilih seed di tab Auto Farming.", Duration = 4 })

Hub.debug = {
	Bind = Bind,
	Move = Move,
	Farm = Farm,
	PNB = PNB,
	Factory = Factory,
	Dig = Dig,
	Place = Place,
	Path = Path,
	startFarm = startFarm,
	startPNB = startPNB,
	startFactory = startFactory,
	sweepFloor = sweepFloor,
	descendTo = descendTo,
	rowNeedsDig = rowNeedsDig,
	collectDropsAtTile = collectDropsAtTile,
	beginPNB = beginPNB,
	finishPNBDrain = finishPNBDrain,
	factoryBaseDrops = factoryBaseDrops,
}

-- Load ulang harus benar-benar menghentikan loop run lama. Tanpa ini loop
-- basi tetap menggerakkan karakter dan status di window baru tidak pernah
-- berubah (dua instance berebut).
Hub.onUnload(function()
	Factory.running = false
	Factory.gen += 1
	Farm.running = false
	PNB.running = false
	pcall(Move.release)
	pcall(Move.stop)
end)

--// ===== 9. HEARTBEAT / PENJAGA =====
-- kalau karakter hilang (respawn / keluar world), hentikan bot supaya
-- tidak menekan tombol terus tanpa tujuan.
Hub.keep(RunService.Heartbeat:Connect(function()
	if not Farm.running and not PNB.running and not Factory.running then
		return
	end
	local s = Bind.state()
	if not s then
		if Farm.running then
			Farm.stop("state hilang (respawn / pindah world)")
		end
		if PNB.running then
			PNB.stop("state hilang (respawn / pindah world)")
		end
		if Factory.running and not Factory.cycle then
			Factory.stop("state hilang (respawn / pindah world)")
		end
	end
end))

Hub.onUnload(function()
	Farm.running = false
	Farm.gen += 1
	PNB.running = false
	PNB.gen += 1
	Factory.running = false
	Factory.gen += 1
	Move.stop()
end)
