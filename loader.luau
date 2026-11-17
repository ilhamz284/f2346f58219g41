-- URL unik per Execute: URL raw branch yang sama bisa tersimpan di cache client.
local url = "https://raw.githubusercontent.com/ilhamz284/f2346f58219g41/codex/auto-factory/hub.luau"
local source = game:HttpGet(url .. "?refresh=" .. tostring(DateTime.now().UnixTimestampMillis))
local version = source:match('version%s*=%s*"([^"]+)"')
assert(version, "Human Hub: respons unduhan tidak berisi versi script")
local run, compileError = loadstring(source)
assert(run, "Human Hub: gagal compile: " .. tostring(compileError))
print("[HumanHub Loader] memuat v" .. version)
run()
