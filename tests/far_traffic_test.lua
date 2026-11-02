-- Far-away traffic on a server: another player's traffic and parked cars more than 1 km
-- from my camera, while that player is too, are hidden on my game only
-- (mileage/farTraffic.lua and the vehicle sync in mileageEnabler.lua), and show again
-- once that player comes within 1 km.
--
-- Stand-in games run the real enabler and the real far-traffic check against the real
-- server plugin; messages between them queue until pump() delivers them. As in BeamMP, a
-- car switched off on a game keeps the position it had there when it was switched off.

local ENABLER = "Resources/Client/Mileage/lua/ge/extensions/mileageEnabler.lua"
local FAR = "Resources/Client/Mileage/lua/ge/extensions/mileage/farTraffic.lua"
local SERVER = "Resources/Server/Mileage/mileage.lua"

local hasFfi, ffi = pcall(require, "ffi")
local GameVec = hasFfi and ffi.typeof("struct { double x, y, z; }") or nil

--== stand-in games and the server ===========================================

local function encode(v)
	if type(v) == "table" then
		local parts = {}
		for k, val in pairs(v) do table.insert(parts, "[" .. encode(k) .. "]=" .. encode(val)) end
		table.sort(parts)
		return "{" .. table.concat(parts, ",") .. "}"
	elseif type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

local function decode(text)
	if type(text) ~= "string" then error("not text") end
	local chunk = (loadstring or load)("return " .. text)
	if not chunk then error("does not decode") end
	return chunk()
end

local function tryDecode(text)
	local ok, value = pcall(decode, text)
	if ok then return value end
	return nil
end

local world, logs

-- Runs fn with the globals of player p's game.
local function as(p, fn, ...)
	MPVehicleGE, be, gameplay_traffic = p.MPVehicleGE, p.be, p.traffic
	extensions, mileageEnabler = p.extensions, p.enabler
	core_camera = p.camera
	worldReadyState = 2
	function TriggerServerEvent(name, data)
		table.insert(world.toServer, {from = p.id, name = name, data = data})
	end
	function AddEventHandler(name, fn) p.handlers[name] = fn end
	return fn(...)
end

local function newWorld()
	world = {players = {}, toServer = {}, toClients = {}}
	logs = {}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	os.clockhp = function() return 0 end
	jsonEncode, jsonDecode = encode, tryDecode
	settings = {getValue = function() return nil end, setValue = function() end}
	MPConfig = {getNickname = function() return "player" end}
	Util = {JsonDecode = decode, JsonEncode = encode}
	world.now = 0
	MP = {
		CreateTimer = function() return {GetCurrent = function() return world.now end, Start = function() end} end,
		GetPlayers = function()
			local names = {}
			for id, p in pairs(world.players) do names[id] = p.name end
			return names
		end,
		IsPlayerConnected = function(id) return world.players[id] ~= nil end,
		GetPlayerName = function(id) return world.players[id] and world.players[id].name end,
		TriggerClientEvent = function(target, event, data)
			table.insert(world.toClients, {target = target, event = event, data = data})
		end,
	}
	local realPrint = print
	print = function() end
	dofile(SERVER)
	print = realPrint
end

local function addPlayer(id, name, opts)
	opts = opts or {}
	local p = {id = id, name = name, vehicles = {}, objects = {}, trafficData = {}, handlers = {},
		playerVehicle = -1, serverRequests = {}}
	p.MPVehicleGE = {
		getVehicles = function() return p.vehicles end,
		isOwn = function(gid) local o = p.objects[gid]; return o ~= nil and o.owner == id end,
		getServerVehicleID = function(gid) local o = p.objects[gid]; return o and o.serverVehicleID end,
	}
	p.be = {
		getObjectByID = function(_, gid) return p.objects[gid] end,
		getPlayerVehicleID = function() return p.playerVehicle end,
	}
	p.traffic = {getTrafficData = function() return p.trafficData end}
	p.extensions = {
		mileage_compat = {report = function() end, targetGameVersion = "test",
			isMPSession = function() return opts.mp ~= false end},
		core_input_actionFilter = {setGroup = function() end, addAction = function() end},
	}
	world.players[id] = p
	as(p, function()
		p.enabler = dofile(ENABLER)
		p.extensions.mileageEnabler = p.enabler
		if opts.far ~= false then
			p.far = dofile(FAR)
			p.extensions.mileage_farTraffic = p.far
		end
	end)
	as(p, function()
		p.enabler.onExtensionLoaded()
		p.handlers.rxClientConfigUpdate(encode({remoteVehicleGhost = false, remoteUnicycleGhost = true,
			localUnicycleGhost = false, consoleEnabled = true, worldEditorEnabled = true}))
		if p.far then p.far.onCareerActive(true) end
	end)
	return p
end

local function pump()
	for _ = 1, 200 do
		if #world.toServer == 0 and #world.toClients == 0 then return end
		local toServer, toClients = world.toServer, world.toClients
		world.toServer, world.toClients = {}, {}
		for _, m in ipairs(toServer) do
			table.insert(world.players[m.from].serverRequests, m.name)
			local handler = _G[m.name]
			if handler then handler(m.from, m.data) end
		end
		for _, m in ipairs(toClients) do
			for id, p in pairs(world.players) do
				if m.target == -1 or m.target == id then
					local handler = p.handlers[m.event]
					if handler then as(p, handler, m.data) end
				end
			end
		end
	end
	error("messages never stopped")
end

local function gameId(owner, vid) return owner * 100 + vid + 1 end

-- A position as the game hands it out: a vec3 (an FFI struct under LuaJIT), a table
-- elsewhere.
local function gamePos(x, y)
	if GameVec then return GameVec(x, y, 0) end
	return {x = x, y = y, z = 0}
end

-- Spawns owner's vehicle vid at x, y on every game. fields: JBeam, isTraffic, isParked,
-- ai (traffic data).
local function spawn(owner, vid, x, y, fields)
	fields = fields or {}
	local sid = owner .. "-" .. vid
	local gid = gameId(owner, vid)
	for id, p in pairs(world.players) do
		local veh = {owner = owner, serverVehicleID = sid, JBeam = fields.JBeam or "pickup", active = true,
			x = x, y = y}
		if id == owner then
			veh.isTraffic, veh.isParked = fields.isTraffic, fields.isParked
			if fields.ai ~= nil then p.trafficData[gid] = {isAi = fields.ai} end
		end
		function veh:setActive(on)
			local now = on == 1
			if now == self.active then return end
			self.active = now
			as(p, p.enabler.onVehicleActiveChanged, gid, now)
		end
		function veh:getActive() return self.active end
		function veh:getPosition() return gamePos(self.x, self.y) end
		function veh:queueLuaCommand() end
		function veh:setField() end
		function veh:setDynDataFieldbyName(name, _, value) self[name] = value end
		p.objects[gid] = veh
		p.vehicles[sid] = {gameVehicleID = gid, jbeam = veh.JBeam, isLocal = id == owner}
	end
	onVehicleSpawnHandler(owner, vid, "")
	for _, p in pairs(world.players) do
		as(p, p.enabler.onVehicleSpawned, gid)
		as(p, p.enabler.onVehicleReady, gid)
	end
	pump()
	return gid
end

-- Moves owner's vehicle vid to x, y: on its owner's game, and on every game where it is
-- switched on (a switched-off copy keeps its old position, as in BeamMP).
local function move(owner, vid, x, y)
	for id, p in pairs(world.players) do
		local veh = p.objects[gameId(owner, vid)]
		if veh and (id == owner or veh.active) then veh.x, veh.y = x, y end
	end
end

-- Runs a player's frame updates for the given seconds, in half-second frames.
local function frames(p, seconds)
	for _ = 1, math.floor(seconds * 2 + 0.5) do
		as(p, function()
			p.enabler.onUpdate(0.5, 0.5, 0.5)
			if p.far then p.far.onUpdate(0.5) end
		end)
	end
	pump()
end

local function active(p, owner, vid) return p.objects[gameId(owner, vid)].active end

local function count(list, value)
	local n = 0
	for _, v in ipairs(list) do if v == value then n = n + 1 end end
	return n
end

local function listRequests(p)
	frames(p, 1)
	return count(p.serverRequests, "careerVehSyncRequested")
end

-- Me (player 0) at the origin, and my friend (player 1) driving car 1-0 at friendX with a
-- traffic car (1-1) and a parked car (1-2) beside him. Both games have run their marks.
-- opts.trafficX puts the traffic car elsewhere.
local function twoPlayers(friendX, opts)
	opts = opts or {}
	newWorld()
	local me, friend = addPlayer(0, "Me", opts), addPlayer(1, "Friend")
	friendX = friendX or 2000
	me.playerVehicle = spawn(0, 0, 0, 0)
	friend.playerVehicle = spawn(1, 0, friendX, 0)
	spawn(1, 1, opts.trafficX or friendX + 50, 0, {JBeam = "fullsize", isTraffic = "true", ai = true})
	spawn(1, 2, friendX - 20, 0, {JBeam = "covet", isParked = "true"})
	frames(friend, 1)
	frames(me, 1)
	me.serverRequests, friend.serverRequests = {}, {}
	return me, friend
end

--== hidden when far ==========================================================

test("my friend's traffic and parked cars over 1 km away are hidden on my game, the car he drives is not", function()
	local me, friend = twoPlayers(2000)
	same(active(me, 1, 1), false, "my friend's traffic car")
	same(active(me, 1, 2), false, "my friend's parked car")
	same(active(me, 1, 0), true, "the car my friend drives")
	for vid = 0, 2 do same(active(friend, 1, vid), true, "car 1-" .. vid .. " on my friend's game") end
end)

test("hiding far traffic asks the server for nothing and changes nothing for anyone else", function()
	local me, friend = twoPlayers(2000)
	frames(me, 3)
	same(count(me.serverRequests, "careerVehicleActiveHandler"), 0, "hide updates from my game")
	same(listRequests(me), 0, "list requests from my game")
	frames(friend, 1)
	for vid = 0, 2 do same(active(friend, 1, vid), true, "car 1-" .. vid .. " on my friend's game") end
end)

test("a third player next to my friend still sees his traffic", function()
	newWorld()
	local me, friend, third = addPlayer(0, "Me"), addPlayer(1, "Friend"), addPlayer(2, "Third")
	me.playerVehicle = spawn(0, 0, 0, 0)
	friend.playerVehicle = spawn(1, 0, 2000, 0)
	third.playerVehicle = spawn(2, 0, 2100, 0)
	spawn(1, 1, 2050, 0, {JBeam = "fullsize", isTraffic = "true", ai = true})
	frames(friend, 1)
	frames(me, 1)
	frames(third, 1)
	same(active(me, 1, 1), false, "my friend's traffic car on my game")
	same(active(third, 1, 1), true, "my friend's traffic car on the third player's game")
end)

test("my friend's traffic car within 1 km stays showing while my friend is farther away", function()
	local me = twoPlayers(1500, {trafficX = 900})
	frames(me, 2)
	same(active(me, 1, 1), true, "my friend's traffic car 900 m away")
	same(active(me, 1, 2), false, "my friend's parked car 1480 m away")
end)

test("nothing is hidden while my friend drives within 1 km", function()
	local me = twoPlayers(600)
	move(1, 1, 1400, 0)
	frames(me, 2)
	same(active(me, 1, 1), true, "my friend's traffic car 1400 m away")
	same(active(me, 1, 2), true, "my friend's parked car")
end)

test("a traffic car my friend's game spawns far away is hidden once its mark arrives", function()
	local me, friend = twoPlayers(2000)
	spawn(1, 3, 2200, 0, {JBeam = "vivace", isTraffic = "true", ai = true})
	same(active(me, 1, 3), true, "before its mark arrives")
	frames(friend, 1)
	frames(me, 1)
	same(active(me, 1, 3), false, "my friend's new traffic car")
end)

--== shown again ==============================================================

test("hidden cars show again when my friend comes within 1 km, wherever my game last had them", function()
	local me = twoPlayers(2000)
	same(active(me, 1, 1), false, "hidden at first")
	move(1, 0, 950, 0)
	move(1, 1, 1000, 0)
	move(1, 2, 930, 0)
	same(me.objects[gameId(1, 1)].x, 2050, "my game's copy kept its old position while hidden")
	frames(me, 1)
	same(active(me, 1, 1), true, "my friend's traffic car")
	same(active(me, 1, 2), true, "my friend's parked car")
	same(count(me.serverRequests, "careerVehicleActiveHandler"), 0, "hide updates from my game")
end)

test("a friend driving along the limit does not make his cars flicker", function()
	local me = twoPlayers(1050)
	move(1, 1, 1200, 0)
	move(1, 2, 1200, 0)
	frames(me, 2)
	same(active(me, 1, 1), true, "my friend at 1050 m: not far enough to hide his cars")
	move(1, 0, 1150, 0)
	frames(me, 1)
	same(active(me, 1, 1), false, "my friend at 1150 m: his traffic car is hidden")
	move(1, 0, 1050, 0)
	frames(me, 3)
	same(active(me, 1, 1), false, "my friend back at 1050 m: it stays hidden")
	move(1, 0, 990, 0)
	frames(me, 1)
	same(active(me, 1, 1), true, "my friend at 990 m: it shows again")
	frames(me, 3)
	same(active(me, 1, 1), true, "and stays showing")
end)

test("a car my friend hid himself stays hidden when he comes near, and shows when he shows it", function()
	local me, friend = twoPlayers(2000)
	as(friend, function() friend.objects[gameId(1, 1)]:setActive(0) end)
	pump()
	move(1, 0, 100, 0)
	frames(me, 1)
	same(active(me, 1, 1), false, "the traffic car my friend hid")
	same(active(me, 1, 2), true, "my friend's parked car")
	as(friend, function() friend.objects[gameId(1, 1)]:setActive(1) end)
	pump()
	same(active(me, 1, 1), true, "the traffic car my friend showed again")
end)

test("my friend's traffic shows when none of his own cars is showing on my game", function()
	local me, friend = twoPlayers(2000)
	-- My friend steps into a garage menu: the career hides the car he drives.
	as(friend, function() friend.objects[gameId(1, 0)]:setActive(0) end)
	pump()
	frames(me, 1)
	same(active(me, 1, 0), false, "the car my friend drives, hidden by him")
	same(active(me, 1, 1), true, "my friend's traffic car")
	same(active(me, 1, 2), true, "my friend's parked car")
end)

test("my friend's own car left near me keeps his traffic showing", function()
	local me = twoPlayers(2000)
	spawn(1, 4, 100, 0, {JBeam = "etk800"})
	frames(me, 1)
	same(active(me, 1, 1), true, "my friend's traffic car")
end)

--== where my game looks from =================================================

test("my camera decides, so watching my friend far away shows his traffic", function()
	local me = twoPlayers(2000)
	same(active(me, 1, 1), false, "hidden while my camera is on my car")
	me.camera = {getPosition = function() return gamePos(2010, 5) end}
	frames(me, 1)
	same(active(me, 1, 1), true, "my friend's traffic car while my camera is beside him")
	me.camera = {getPosition = function() return gamePos(0, 5) end}
	frames(me, 1)
	same(active(me, 1, 1), false, "hidden again once my camera is back")
end)

test("a camera that fails or has no position falls back to the car I drive", function()
	local me = twoPlayers(2000)
	me.camera = {getPosition = function() error("no camera") end}
	frames(me, 1)
	same(active(me, 1, 1), false, "my friend's traffic car with a failing camera")
	me.camera = {getPosition = function() return nil end}
	frames(me, 1)
	same(active(me, 1, 1), false, "my friend's traffic car with no camera position")
end)

test("with no camera and no car of mine, every car shows", function()
	local me = twoPlayers(2000)
	me.playerVehicle = -1
	frames(me, 1)
	same(active(me, 1, 1), true, "my friend's traffic car")
	same(active(me, 1, 2), true, "my friend's parked car")
end)

--== off and on ==============================================================

test("off a server nothing is hidden", function()
	local me = twoPlayers(2000, {mp = false})
	frames(me, 2)
	same(active(me, 1, 1), true, "my friend's traffic car")
	same(me.far.isHidden("1-1"), false, "held hidden")
end)

test("without the far-traffic extension nothing is hidden", function()
	local me = twoPlayers(2000, {far = false})
	frames(me, 2)
	same(active(me, 1, 1), true, "my friend's traffic car")
end)

test("the career ending shows every hidden car again", function()
	local me = twoPlayers(2000)
	as(me, me.far.onCareerActive, false)
	same(active(me, 1, 1), true, "my friend's traffic car")
	same(active(me, 1, 2), true, "my friend's parked car")
	frames(me, 2)
	same(active(me, 1, 1), true, "still showing while the career is off")
end)

test("leaving the server or unloading forgets every hidden car", function()
	local me = twoPlayers(2000)
	as(me, me.far.onBeamMPServerLeave)
	same(me.far.isHidden("1-1"), false, "after leaving")
	frames(me, 2)
	same(me.far.isHidden("1-1"), false, "no check runs after leaving")
	as(me, me.far.onCareerActive, true)
	frames(me, 1)
	same(active(me, 1, 1), false, "hidden again once the career runs again")
	as(me, me.far.onExtensionUnloaded)
	same(active(me, 1, 1), true, "shown when the extension unloads")
end)

test("a failing check shows every car and logs once", function()
	local me = twoPlayers(2000)
	local real = me.enabler.isRemoteTraffic
	me.enabler.isRemoteTraffic = function() error("broken lookup") end
	as(me, function() for _ = 1, 6 do me.far.onUpdate(0.5) end end)
	me.enabler.isRemoteTraffic = real
	pump()
	same(active(me, 1, 1), true, "my friend's traffic car")
	same(countLines(logs, "far traffic check failed"), 1, "error lines")
end)

test("a car gone from my game is dropped from the hidden list", function()
	local me = twoPlayers(2000)
	same(me.far.isHidden("1-1"), true, "held hidden")
	me.vehicles["1-1"], me.objects[gameId(1, 1)] = nil, nil
	frames(me, 1)
	same(me.far.isHidden("1-1"), false, "after the car is gone")
	same(me.far.isHidden("1-2"), true, "the parked car is still held hidden")
end)
