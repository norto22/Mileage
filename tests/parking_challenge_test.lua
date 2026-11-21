-- Parking challenges on a server: another player's traffic and parked cars come from
-- their own game, which knows nothing about my challenge, so while my parking challenge
-- runs they are hidden on my game only (mileage/parkingChallenge.lua and the vehicle
-- sync in mileageEnabler.lua), and come back as their owner has them when it ends.
--
-- Two stand-in games run the real enabler against the real server plugin; messages
-- between them queue until pump() delivers them. The game's mission manager is played
-- by firing its hooks on every extension each game has loaded.

local ENABLER = "Resources/Client/Mileage/lua/ge/extensions/mileageEnabler.lua"
local PARKING = "Resources/Client/Mileage/lua/ge/extensions/mileage/parkingChallenge.lua"

-- An object with methods reached only through its metatable, like the engine's FS: a
-- userdata where newproxy exists (LuaJIT, 5.1), an empty table elsewhere.
local function engineObject(methods)
	local proxy = newproxy and newproxy(true) or setmetatable({}, {})
	getmetatable(proxy).__index = methods
	return proxy
end
local SERVER = "Resources/Server/Mileage/mileage.lua"

--== two stand-in games and the server =======================================

-- Payloads travel as text, like BeamMP's JSON: Lua table syntax read back with load.
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
	extensions, mileageEnabler, FS = p.extensions, p.enabler, p.FS
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

local function addPlayer(id, name)
	local p = {id = id, name = name, vehicles = {}, objects = {}, trafficData = {}, handlers = {},
		playerVehicle = -1, serverRequests = {}, files = {}}
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
	p.FS = {fileExists = function(_, path) return p.files[path] == true end}
	p.extensions = {
		mileage_compat = {report = function() end, targetGameVersion = "test", isMPSession = function() return true end},
		core_input_actionFilter = {setGroup = function() end, addAction = function() end},
	}
	world.players[id] = p
	as(p, function()
		p.enabler = dofile(ENABLER)
		p.extensions.mileageEnabler = p.enabler
		p.parking = dofile(PARKING)
		p.extensions.mileage_parkingChallenge = p.parking
	end)
	as(p, function()
		p.enabler.onExtensionLoaded()
		p.handlers.rxClientConfigUpdate(encode({remoteVehicleGhost = false, remoteUnicycleGhost = true,
			localUnicycleGhost = false, consoleEnabled = true, worldEditorEnabled = true}))
	end)
	return p
end

-- Delivers queued messages both ways until none are left.
local function pump()
	for _ = 1, 200 do
		-- Car states leave the server on its quarter-second timer.
		vehicleStatesTimer()
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

-- A vehicle game id: the same number on every game, which keeps the tests readable.
local function gameId(owner, vid) return owner * 100 + vid + 1 end

-- Spawns owner's vehicle vid on every game, through the server's spawn event and each
-- game's spawn and ready hooks. fields: JBeam, isTraffic, isParked, ai (traffic data).
local function spawn(owner, vid, fields)
	fields = fields or {}
	local sid = owner .. "-" .. vid
	local gid = gameId(owner, vid)
	for id, p in pairs(world.players) do
		local veh = {owner = owner, serverVehicleID = sid, JBeam = fields.JBeam or "pickup", active = true}
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

-- Runs a player's frame update for the given seconds, in half-second frames.
local function frames(p, seconds)
	for _ = 1, math.floor(seconds * 2 + 0.5) do as(p, p.enabler.onUpdate, 0.5, 0.5, 0.5) end
	pump()
end

-- Fires a game hook on every extension player p's game has loaded, as the game does.
local function hook(p, name, ...)
	local args = {...}
	as(p, function()
		for _, ext in pairs(p.extensions) do
			local fn = type(ext) == "table" and rawget(ext, name)
			if type(fn) == "function" then fn((table.unpack or unpack)(args)) end
		end
	end)
	pump()
end

local function active(p, owner, vid) return p.objects[gameId(owner, vid)].active end

local function count(list, value)
	local n = 0
	for _, v in ipairs(list) do if v == value then n = n + 1 end end
	return n
end

-- The list requests p's game has sent; a wanted request goes out on its next frame, so
-- a second of frames runs first.
local function listRequests(p)
	frames(p, 1)
	return count(p.serverRequests, "careerVehSyncRequested")
end

-- Me (player 0) and my friend (player 1), who drives car 1-0 and has a police car (1-1)
-- in road traffic and a parked car (1-2). My friend's game has sent its traffic marks.
local function twoPlayers()
	newWorld()
	local me, friend = addPlayer(0, "Me"), addPlayer(1, "Friend")
	me.playerVehicle = spawn(0, 0)
	friend.playerVehicle = spawn(1, 0)
	spawn(1, 1, {JBeam = "fullsize", isTraffic = "true", ai = true})
	spawn(1, 2, {JBeam = "covet", isParked = "true"})
	frames(friend, 1)
	frames(me, 1)
	me.serverRequests, friend.serverRequests = {}, {}
	return me, friend
end

local PARKING_MISSION = {id = "west_coast_usa/parking/001", missionType = "parking",
	missionFolder = "/gameplay/missions/west_coast_usa/parking/001"}

--== the reported defect =====================================================

test("my friend's parked and police cars are hidden on my game when I start a parking challenge", function()
	local me, friend = twoPlayers()
	same(active(me, 1, 2), true, "my friend's parked car before the challenge")
	hook(me, "onAnyMissionChanged", "started", PARKING_MISSION, {})
	same(active(me, 1, 2), false, "my friend's parked car active")
	same(active(me, 1, 1), false, "my friend's police car active")
	same(active(me, 1, 0), true, "the car my friend drives")
	same(active(friend, 1, 1), true, "my friend's police car on their own game")
	same(active(friend, 1, 2), true, "my friend's parked car on their own game")
end)

--== which missions count ====================================================

local function startMission(p, mission) hook(p, "onAnyMissionChanged", "started", mission, {}) end
local function stopMission(p, mission) hook(p, "onAnyMissionChanged", "stopped", mission) end

test("a delivery or race hides nothing and logs that it is not a parking challenge", function()
	local me = twoPlayers()
	startMission(me, {id = "delivery/004", missionType = "delivery", missionFolder = "/gameplay/missions/delivery/004"})
	same(active(me, 1, 1), true, "my friend's police car")
	same(active(me, 1, 2), true, "my friend's parked car")
	same(countLines(logs, "I mileage.parkingChallenge: mission start: type=delivery parking=false"), 1, "log lines")
end)

test("a mission type naming parking in any case counts, and the start is logged", function()
	local me = twoPlayers()
	startMission(me, {id = "x", missionType = "ParkingChallenge", missionFolder = "/m/x"})
	same(active(me, 1, 2), false, "my friend's parked car")
	same(countLines(logs, "I mileage.parkingChallenge: mission start: type=ParkingChallenge parking=true"), 1, "log lines")
end)

test("a mission whose folder ships the parking-lot clutter layout counts", function()
	for _, file in ipairs({"parkingLotClutter.prefab.json", "parkingLotClutter.prefab"}) do
		local me = twoPlayers()
		me.files["/m/challenge/" .. file] = true
		startMission(me, {id = "challenge", missionType = "timeTrial", missionFolder = "/m/challenge"})
		same(active(me, 1, 2), false, "my friend's parked car with " .. file)
	end
end)

test("a game whose FS is an engine object, not a Lua table, still finds the clutter layout", function()
	local me = twoPlayers()
	-- The game's FS is an object of the engine called with a colon, like be; a userdata
	-- with methods stands in for it.
	me.FS = engineObject({fileExists = function(_, path) return path == "/m/challenge/parkingLotClutter.prefab.json" end})
	startMission(me, {id = "challenge", missionType = "timeTrial", missionFolder = "/m/challenge"})
	same(active(me, 1, 2), false, "my friend's parked car")
	same(countLines(logs, "mission start: type=timeTrial parking=true"), 1, "log lines")
end)

test("a mission start with no mission table changes nothing", function()
	local me = twoPlayers()
	hook(me, "onAnyMissionChanged", "started", nil)
	same(me.parking.isActive(), false, "parking challenge mode")
	same(active(me, 1, 2), true, "my friend's parked car")
end)

--== nobody else notices =====================================================

test("my parking challenge asks the server for nothing and changes nothing on my friend's game", function()
	local me, friend = twoPlayers()
	startMission(me, PARKING_MISSION)
	stopMission(me, PARKING_MISSION)
	same(listRequests(me), 0, "list requests from my game")
	same(count(me.serverRequests, "careerVehicleActiveHandler"), 0, "hide updates from my game")
	for vid = 0, 2 do same(active(friend, 1, vid), true, "car 1-" .. vid .. " on my friend's game") end
end)

test("without the parking challenge extension a parking mission hides nothing", function()
	local me, friend = twoPlayers()
	me.extensions.mileage_parkingChallenge = nil
	startMission(me, PARKING_MISSION)
	as(friend, function() friend.objects[gameId(1, 1)]:setActive(0) end)
	pump()
	as(friend, function() friend.objects[gameId(1, 1)]:setActive(1) end)
	pump()
	same(active(me, 1, 1), true, "my friend's police car")
	same(active(me, 1, 2), true, "my friend's parked car")
end)

--== during the challenge ====================================================

test("a car my friend shows again during my challenge stays hidden on my game", function()
	local me, friend = twoPlayers()
	startMission(me, PARKING_MISSION)
	as(friend, function() friend.objects[gameId(1, 2)]:setActive(0) end)
	pump()
	as(friend, function() friend.objects[gameId(1, 2)]:setActive(1) end)
	pump()
	same(active(me, 1, 2), false, "my friend's parked car")
	same(listRequests(me), 0, "list requests from my game")
end)

test("a parked car my friend spawns during my challenge is hidden once its mark arrives", function()
	local me, friend = twoPlayers()
	startMission(me, PARKING_MISSION)
	spawn(1, 3, {JBeam = "vivace", isParked = "true"})
	frames(friend, 1)
	same(active(me, 1, 3), false, "my friend's new parked car")
	same(active(me, 1, 0), true, "the car my friend drives")
end)

test("a parked car my friend climbs into during my challenge shows on my game", function()
	local me, friend = twoPlayers()
	startMission(me, PARKING_MISSION)
	friend.playerVehicle = gameId(1, 2)
	frames(friend, 1)
	same(active(me, 1, 2), true, "the parked car my friend now drives")
	same(active(me, 1, 1), false, "my friend's police car")
end)

--== after the challenge =====================================================

for _, ending in ipairs({
	{"the mission manager reports it stopped", function(p) stopMission(p, PARKING_MISSION) end},
	{"it is stopped", function(p) hook(p, "onMissionStopped", PARKING_MISSION) end},
	{"it is abandoned", function(p) hook(p, "onMissionAbandoned", PARKING_MISSION) end},
}) do
	test("my friend's cars show again as they have them when " .. ending[1], function()
		local me, friend = twoPlayers()
		startMission(me, PARKING_MISSION)
		as(friend, function() friend.objects[gameId(1, 1)]:setActive(0) end)
		pump()
		ending[2](me)
		same(me.parking.isActive(), false, "parking challenge mode")
		same(active(me, 1, 2), true, "my friend's parked car")
		same(active(me, 1, 1), false, "the police car my friend hid")
		same(active(me, 1, 0), true, "the car my friend drives")
		same(listRequests(me), 0, "list requests from my game")
	end)
end

test("every way out ending the same challenge shows the cars once", function()
	local me = twoPlayers()
	startMission(me, PARKING_MISSION)
	hook(me, "onMissionAbandoned", PARKING_MISSION)
	stopMission(me, PARKING_MISSION)
	hook(me, "onMissionStopped", PARKING_MISSION)
	same(countLines(logs, "showing other players' traffic and parked cars again"), 1, "log lines")
	same(active(me, 1, 2), true, "my friend's parked car")
end)

test("a non-parking mission started after a challenge shows the cars again", function()
	local me = twoPlayers()
	startMission(me, PARKING_MISSION)
	startMission(me, {id = "delivery/004", missionType = "delivery", missionFolder = "/m/d"})
	same(active(me, 1, 2), true, "my friend's parked car")
end)

test("leaving the server mid-challenge ends it, and my friend's updates apply again", function()
	local me, friend = twoPlayers()
	startMission(me, PARKING_MISSION)
	hook(me, "onBeamMPServerLeave")
	same(me.parking.isActive(), false, "parking challenge mode")
	-- Back on the server, my friend's car states reach my game as before.
	as(friend, function() friend.objects[gameId(1, 2)]:setActive(0) end)
	pump()
	as(friend, function() friend.objects[gameId(1, 2)]:setActive(1) end)
	pump()
	same(active(me, 1, 2), true, "my friend's parked car")
end)

--== edges past the script ===================================================

test("a mission start with no type and no folder hides nothing and logs it as not parking", function()
	local me = twoPlayers()
	startMission(me, {id = "x"})
	same(me.parking.isActive(), false, "parking challenge mode")
	same(active(me, 1, 2), true, "my friend's parked car")
	same(countLines(logs, "I mileage.parkingChallenge: mission start: type=nil parking=false"), 1, "log lines")
end)

test("my own parked car stays showing on my game and is not reported hidden during my challenge", function()
	local me, friend = twoPlayers()
	spawn(0, 1, {JBeam = "etk800", isParked = "true"})
	frames(me, 1)
	me.serverRequests = {}
	startMission(me, PARKING_MISSION)
	same(active(me, 0, 1), true, "my own parked car on my game")
	same(active(friend, 0, 1), true, "my own parked car on my friend's game")
	same(count(me.serverRequests, "careerVehicleActiveHandler"), 0, "hide updates from my game")
end)

test("a third player still sees my friend's traffic and parked cars during my challenge", function()
	local me, friend = twoPlayers()
	local third = addPlayer(2, "Third")
	-- The third player joins late: their game gets the cars from the server's full map.
	for vid = 0, 2 do
		local gid = gameId(1, vid)
		local veh = {owner = 1, serverVehicleID = "1-" .. vid, JBeam = "pickup", active = true}
		function veh:setActive(on)
			local now = on == 1
			if now == self.active then return end
			self.active = now
			as(third, third.enabler.onVehicleActiveChanged, gid, now)
		end
		function veh:getActive() return self.active end
		function veh:queueLuaCommand() end
		function veh:setField() end
		function veh:setDynDataFieldbyName() end
		third.objects[gid] = veh
		third.vehicles["1-" .. vid] = {gameVehicleID = gid, jbeam = "pickup", isLocal = false}
		as(third, third.enabler.onVehicleSpawned, gid)
	end
	frames(third, 1)
	startMission(me, PARKING_MISSION)
	frames(friend, 1)
	frames(third, 1)
	for vid = 0, 2 do same(active(third, 1, vid), true, "car 1-" .. vid .. " on the third player's game") end
	same(active(me, 1, 2), false, "my friend's parked car on my game")
end)

test("starting the parking challenge again after abandoning it hides the cars again", function()
	local me = twoPlayers()
	startMission(me, PARKING_MISSION)
	hook(me, "onMissionAbandoned", PARKING_MISSION)
	same(active(me, 1, 2), true, "my friend's parked car after abandoning")
	startMission(me, PARKING_MISSION)
	same(me.parking.isActive(), true, "parking challenge mode on the second start")
	same(active(me, 1, 2), false, "my friend's parked car on the second start")
	same(active(me, 1, 1), false, "my friend's police car on the second start")
	stopMission(me, PARKING_MISSION)
	same(active(me, 1, 2), true, "my friend's parked car after passing")
end)

test("unloading the parking challenge extension mid-challenge shows the cars again", function()
	local me = twoPlayers()
	startMission(me, PARKING_MISSION)
	hook(me, "onExtensionUnloaded")
	me.extensions.mileage_parkingChallenge = nil
	same(active(me, 1, 2), true, "my friend's parked car")
	same(active(me, 1, 1), true, "my friend's police car")
	same(listRequests(me), 0, "list requests from my game")
end)

--== the game's file system past the script =================================

test("a game whose FS fails or has no fileExists counts no clutter layout, and the start still logs", function()
	local broken = {
		{what = "an FS whose fileExists raises", fs = {fileExists = function() error("engine file system busy") end}},
		{what = "an FS with no fileExists", fs = {}},
	}
	for _, case in ipairs(broken) do
		local me = twoPlayers()
		me.FS = case.fs
		local ok, err = pcall(startMission, me, {id = "challenge", missionType = "timeTrial", missionFolder = "/m/challenge"})
		same(ok, true, case.what .. ": mission start went through (" .. tostring(err) .. ")")
		same(me.parking.isActive(), false, case.what .. ": parking challenge mode")
		same(active(me, 1, 2), true, case.what .. ": my friend's parked car")
		same(countLines(logs, "I mileage.parkingChallenge: mission start: type=timeTrial parking=false"), 1, case.what .. ": log lines")
	end
end)

test("a game whose FS is an engine object finds a clutter layout shipped as a plain .prefab", function()
	local me = twoPlayers()
	me.FS = engineObject({fileExists = function(_, path) return path == "/m/challenge/parkingLotClutter.prefab" end})
	startMission(me, {id = "challenge", missionType = "timeTrial", missionFolder = "/m/challenge"})
	same(active(me, 1, 2), false, "my friend's parked car")
	same(countLines(logs, "mission start: type=timeTrial parking=true"), 1, "log lines")
end)

test("with no FS at all a parking type still counts and any other mission hides nothing", function()
	local me = twoPlayers()
	me.FS = nil
	startMission(me, {id = "challenge", missionType = "timeTrial", missionFolder = "/m/challenge"})
	same(me.parking.isActive(), false, "parking challenge mode for a time trial")
	same(active(me, 1, 2), true, "my friend's parked car during a time trial")
	stopMission(me, {id = "challenge"})
	startMission(me, PARKING_MISSION)
	same(me.parking.isActive(), true, "parking challenge mode for a parking type")
	same(active(me, 1, 2), false, "my friend's parked car during the parking challenge")
end)
