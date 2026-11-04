-- mileagePrefabSync.lua: another player's mission props are placed one per frame, and
-- the map's collision is rebuilt once after the last of them, not once per prop.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileagePrefabSync.lua"

local game

local realOpen = io.open

local function setup()
	game = {files = {}, spawned = {}, removed = {}, rebuilds = 0, handlers = {}, objects = {}}
	function log() end
	function setExtensionUnloadMode() end
	function AddEventHandler(name, fn) game.handlers[name] = fn end
	function TriggerServerEvent() end
	jsonDecode = function(text) return game.decoded[text] end
	jsonEncode = function() return "" end
	worldReadyState = 2
	FS = {fileExists = function(_, path) return game.files[path] ~= nil end}
	scenetree = {findObject = function(name) return game.objects[name] end}
	be = {reloadCollision = function() game.rebuilds = game.rebuilds + 1 end}
	function spawnPrefab(name) table.insert(game.spawned, name); game.objects[name] = true end
	function removePrefab(name) table.insert(game.removed, name); game.objects[name] = nil end
	-- Prefab files live in memory: the mission's and the cleaned copies written next to them.
	io.open = function(path, mode)
		if (mode or "r"):sub(1, 1) == "r" then
			local text = game.files[path]
			if not text then return nil end
			return {read = function() return text end, close = function() end}
		end
		return {write = function(_, text) game.files[path] = text end, close = function() end}
	end
	local module = dofile(SOURCE)
	module.onExtensionLoaded()
	return module
end

local function done() io.open = realOpen end

-- The real io.open is put back after every test, failed or not.
local realTest = test
local function test(name, fn)
	realTest(name, function()
		local ok, err = pcall(fn)
		done()
		if not ok then error(err, 0) end
	end)
end

-- A mission folder holding a prefab file for each of `bases`.
local function mission(folder, bases)
	for _, base in ipairs(bases) do
		game.files[folder .. "/" .. base .. ".prefab.json"] = '{"class":"TSStatic"}\n'
	end
end

local function receive(name, folder, load)
	local text = name .. (load and "+" or "-")
	game.decoded = game.decoded or {}
	game.decoded[text] = {pName = name, pPath = folder, pLoad = load}
	game.handlers.rxPrefabSync(text)
end

local function frames(module, n)
	for _ = 1, n do module.onUpdate(0.016) end
end

test("five props are placed one per frame and the collision is rebuilt once, after the last", function()
	local module = setup()
	mission("m1", {"arrive", "deco", "logs", "ramp", "road"})
	receive("race-1", "m1", true)
	frames(module, 4)
	same(#game.spawned, 4, "props after 4 frames")
	same(game.rebuilds, 0, "rebuilds before the last prop")
	frames(module, 1)
	same(#game.spawned, 5, "props after 5 frames")
	same(game.rebuilds, 1, "rebuilds after the last prop")
	frames(module, 20)
	same(game.rebuilds, 1, "rebuilds with nothing left to place")
	done()
end)

test("a second mission arriving while the first is placed rebuilds once after the last of both", function()
	local module = setup()
	mission("m1", {"arrive", "deco", "logs"})
	mission("m2", {"ramp", "road", "targets"})
	receive("race-1", "m1", true)
	frames(module, 2)
	receive("drift-2", "m2", true)
	frames(module, 10)
	same(#game.spawned, 6, "props placed")
	same(game.rebuilds, 1, "rebuilds")
	done()
end)

test("a removed mission's props rebuild the collision at once", function()
	local module = setup()
	mission("m1", {"arrive", "deco"})
	receive("race-1", "m1", true)
	frames(module, 5)
	same(game.rebuilds, 1, "after placing")
	receive("race-1", nil, false)
	same(game.rebuilds, 2, "rebuilt at once on removal")
	expect(#game.removed >= 2, "props removed: " .. #game.removed)
	done()
end)

test("nothing is placed or rebuilt before the world is ready", function()
	local module = setup()
	mission("m1", {"arrive", "deco"})
	worldReadyState = 1
	receive("race-1", "m1", true)
	frames(module, 10)
	same(#game.spawned, 0, "props before the world is ready")
	same(game.rebuilds, 0, "rebuilds before the world is ready")
	worldReadyState = 2
	frames(module, 3)
	same(#game.spawned, 2, "props once ready")
	same(game.rebuilds, 1, "rebuilds once ready")
	done()
end)
