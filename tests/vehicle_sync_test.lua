-- Vehicle sync between players: a mission start hides the starter's traffic instead of
-- deleting it (mileage/traffic.lua), traffic and parked cars carry no nametag, and a
-- hide, show or spawn sends one small update (mileageEnabler.lua and the server plugin).

local TRAFFIC = "Resources/Client/Mileage/lua/ge/extensions/mileage/traffic.lua"
local COMPAT = "Resources/Client/Mileage/lua/ge/extensions/mileage/compat.lua"

--== a stand-in game =========================================================

local logs

-- A vehicle the stand-in game holds: setActive and delete are recorded on it.
local function newVehicle(objects, id, fields)
	local veh = {id = id, JBeam = "pickup", active = true, deleted = false}
	for k, v in pairs(fields or {}) do veh[k] = v end
	function veh:setActive(on) self.active = on == 1 end
	function veh:getActive() return self.active end
	function veh:delete() self.deleted = true; objects[self.id] = nil end
	objects[id] = veh
	return veh
end

-- The starter's game: car 1 driven by the player, 2 and 3 AI road traffic (3 a police
-- car), 4 and 5 parked cars, 6 a car of the player's own that is not traffic. The
-- game's freeze and unfreeze do what 0.39.4.0's mission manager relies on: with
-- despawnVehicles they delete every traffic and parked car except exceptVehicleId, and
-- with respawnVehicles they spawn those again as new vehicles.
local function newGame()
	local game = {objects = {}, nextId = 100, calls = {}}
	local objects = game.objects
	newVehicle(objects, 1)
	newVehicle(objects, 2, {JBeam = "covet", isTraffic = "true"})
	newVehicle(objects, 3, {JBeam = "fullsize", isTraffic = "true"})
	newVehicle(objects, 4, {JBeam = "vivace", isParked = "true"})
	newVehicle(objects, 5, {JBeam = "etk800", isParked = "true"})
	newVehicle(objects, 6, {JBeam = "bastion"})
	game.trafficData = {[1] = {isAi = false}, [2] = {isAi = true}, [3] = {isAi = true}}
	game.parked = {4, 5}

	be = {getObjectByID = function(_, id) return objects[id] end}

	local traffic, parking = {}, {}
	function traffic.getTrafficData() return game.trafficData end
	function parking.getParkedCarsList() return game.parked end

	function traffic.freezeState(options)
		table.insert(game.calls, {"freeze", options})
		options = options or {}
		local stash = {}
		for id, entry in pairs(game.trafficData) do
			local obj = objects[id]
			if obj and id ~= options.exceptVehicleId and (entry.isAi or obj.isTraffic == "true") then
				table.insert(stash, id)
			end
		end
		for _, id in ipairs(game.parked) do
			if objects[id] and id ~= options.exceptVehicleId then table.insert(stash, id) end
		end
		local data = {ids = stash}
		-- The game stops traffic and parking: its own lists are cleared.
		game.trafficData, game.parked = {}, {}
		if options.despawnVehicles then
			for _, id in ipairs(stash) do objects[id]:delete() end
		end
		return data, {police = true}, {parking = true}
	end

	function traffic.unfreezeState(trafficData, policeData, parkingData, options)
		table.insert(game.calls, {"unfreeze", options})
		options = options or {}
		game.respawned = 0
		if options.respawnVehicles and trafficData then
			for _ in ipairs(trafficData.ids) do
				game.nextId = game.nextId + 1
				newVehicle(objects, game.nextId)
				game.respawned = game.respawned + 1
			end
		end
	end

	gameplay_traffic, gameplay_parking = traffic, parking
	return game
end

-- A fresh traffic module on a fresh stand-in game, on a server unless opts.mp is false.
local function setupTraffic(opts)
	opts = opts or {}
	logs = {}
	local mp = opts.mp ~= false
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	os.clockhp = function() return 0 end
	MPCoreNetwork = {isMPSession = function() return mp end}
	extensions = {mileage_compat = dofile(COMPAT)}
	mileageEnabler = {getClientConfig = function() return {roadTrafficEnabled = true, roadTrafficAmount = 6,
		parkedTrafficEnabled = true, parkedTrafficAmount = 8} end}
	career_modules_playerDriving = {
		restoreTrafficAfterTutorialPhase = function() end,
		setTrafficAfterTutorial = function() end,
	}
	local game = newGame()
	local module = dofile(TRAFFIC)
	return module, game
end

-- What the game's mission manager does on a mission start and end.
local function missionStart()
	local t, p, k = gameplay_traffic.freezeState({despawnVehicles = true, exceptVehicleId = 1})
	return {t, p, k}
end

local function missionEnd(stashed)
	gameplay_traffic.unfreezeState(stashed[1], stashed[2], stashed[3], {respawnVehicles = true})
end

--== a mission start on a server =============================================

test("a mission start on a server hides the starter's traffic and parked cars instead of deleting them", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	missionStart()
	for id = 2, 5 do
		local veh = game.objects[id]
		expect(veh ~= nil, "car " .. id .. " deleted")
		same(veh.active, false, "car " .. id .. " active")
	end
	same(game.objects[1].active, true, "the car the player drives")
	same(game.objects[6].active, true, "the player's own car that is not traffic")
end)

test("a mission end on a server shows the hidden cars again and spawns none", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	local stashed = missionStart()
	missionEnd(stashed)
	for id = 2, 5 do
		local veh = game.objects[id]
		expect(veh ~= nil, "car " .. id .. " deleted")
		same(veh.active, true, "car " .. id .. " active")
	end
	same(game.respawned, 0, "cars spawned again")
end)

test("the game's freeze and unfreeze are told to keep the cars, with the mission's other options", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	missionEnd(missionStart())
	local freeze, unfreeze = game.calls[1], game.calls[2]
	same(freeze[1], "freeze", "first call")
	same(freeze[2].despawnVehicles, false, "despawnVehicles passed to the game")
	same(freeze[2].exceptVehicleId, 1, "exceptVehicleId passed to the game")
	same(unfreeze[1], "unfreeze", "second call")
	same(unfreeze[2].respawnVehicles, false, "respawnVehicles passed to the game")
end)

test("the log says how many cars a mission start hid and its end showed again", function()
	local module = setupTraffic()
	module.onCareerActive(true)
	missionEnd(missionStart())
	same(countLines(logs, "mission start: 4 traffic and parked cars hidden instead of deleted"), 1, "hide line")
	same(countLines(logs, "mission end: 4 of 4 hidden traffic and parked cars shown again"), 1, "restore line")
end)

test("a hidden car deleted during the mission is skipped at its end", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	local stashed = missionStart()
	game.objects[4]:delete()
	missionEnd(stashed)
	same(game.objects[5].active, true, "car 5 shown")
	same(countLines(logs, "mission end: 3 of 4 hidden traffic and parked cars shown again"), 1, "restore line")
end)

test("a car pooled away before the mission stays hidden after it", function()
	local module, game = setupTraffic()
	game.objects[2].active = false
	module.onCareerActive(true)
	missionEnd(missionStart())
	same(game.objects[2].active, false, "pooled car 2")
	same(game.objects[3].active, true, "car 3")
end)

test("a freeze that does not ask to delete traffic is left to the game, logged once", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	gameplay_traffic.freezeState({exceptVehicleId = 1})
	gameplay_traffic.freezeState()
	same(game.calls[1][2].despawnVehicles, nil, "options passed unchanged")
	same(game.calls[2][2], nil, "no options passed unchanged")
	for id = 2, 5 do same(game.objects[id].active, true, "car " .. id .. " left showing") end
	same(countLines(logs, "the game froze traffic without asking to delete it"), 1, "log lines")
	gameplay_traffic.unfreezeState({ids = {}}, nil, nil, {respawnVehicles = true})
	same(game.calls[3][2].respawnVehicles, true, "an unfreeze with nothing hidden is the game's own")
end)

test("off a server the game's freeze and unfreeze are never replaced", function()
	local module, game = setupTraffic({mp = false})
	local freeze, unfreeze = gameplay_traffic.freezeState, gameplay_traffic.unfreezeState
	module.onCareerActive(true)
	same(gameplay_traffic.freezeState, freeze, "freezeState")
	same(gameplay_traffic.unfreezeState, unfreeze, "unfreezeState")
	missionStart()
	same(game.objects[2], nil, "the game deletes traffic as before")
end)

test("a missing freeze or unfreeze is warned about once and the game is left alone", function()
	local module = setupTraffic()
	gameplay_traffic.unfreezeState = nil
	local freeze = gameplay_traffic.freezeState
	module.onCareerActive(true)
	module.onCareerActive(true)
	same(gameplay_traffic.freezeState, freeze, "freezeState left alone")
	same(countLines(logs, "gameplay_traffic.unfreezeState missing"), 1, "warnings")
end)

test("leaving the server or unloading puts the game's functions back", function()
	for _, hook in ipairs({"onBeamMPServerLeave", "onExtensionUnloaded"}) do
		local module = setupTraffic()
		local freeze, unfreeze = gameplay_traffic.freezeState, gameplay_traffic.unfreezeState
		module.onCareerActive(true)
		expect(gameplay_traffic.freezeState ~= freeze, hook .. ": installed")
		module[hook]()
		same(gameplay_traffic.freezeState, freeze, hook .. ": freezeState")
		same(gameplay_traffic.unfreezeState, unfreeze, hook .. ": unfreezeState")
	end
end)

test("leaving mid-mission shows the hidden cars again", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	missionStart()
	module.onBeamMPServerLeave()
	for id = 2, 5 do same(game.objects[id].active, true, "car " .. id) end
end)

test("a second career start installs once, and a reloaded traffic module gets it again", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	module.onCareerActive(true)
	missionEnd(missionStart())
	same(#game.calls, 2, "game calls through a single replacement")
	newGame()
	module.onCareerActive(true)
	missionStart()
	same(countLines(logs, "mission start: 4 traffic and parked cars hidden"), 2, "hidden on the reloaded module")
end)

test("a mission start hands the mission manager the game's stash, and its end hands it back", function()
	local module, game = setupTraffic()
	local gameUnfreeze = gameplay_traffic.unfreezeState
	local received
	gameplay_traffic.unfreezeState = function(t, p, k, options)
		received = {t, p, k}
		return gameUnfreeze(t, p, k, options)
	end
	module.onCareerActive(true)
	local stashed = missionStart()
	expect(type(stashed[1]) == "table" and #stashed[1].ids == 4, "the game's traffic stash returned")
	same(stashed[2] and stashed[2].police, true, "the game's police stash returned")
	same(stashed[3] and stashed[3].parking, true, "the game's parking stash returned")
	missionEnd(stashed)
	for i = 1, 3 do same(received[i], stashed[i], "stash " .. i .. " handed back to the game") end
	local passed = {gameplay_traffic.freezeState({exceptVehicleId = 1})}
	same(passed[3] and passed[3].parking, true, "a freeze left to the game returns its stash")
end)

test("a mission end with no options still tells the game to keep the cars", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	local stashed = missionStart()
	gameplay_traffic.unfreezeState(stashed[1], stashed[2], stashed[3])
	same(game.calls[2][2].respawnVehicles, false, "respawnVehicles passed to the game")
	for id = 2, 5 do same(game.objects[id].active, true, "car " .. id .. " shown") end
	same(game.respawned, 0, "cars spawned again")
end)

test("a mission hide that fails while finding the cars leaves the mission start to the game", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	be = {getObjectByID = function() error("object lookup broke") end}
	missionStart()
	same(game.calls[1][2].despawnVehicles, true, "despawnVehicles passed to the game")
	same(countLines(logs, "mission hide failed, traffic left to the game"), 1, "error lines")
end)

--== two players and the server ==============================================
-- Each player runs the real enabler on their own stand-in game, the server runs the
-- real plugin, and messages between them queue until pump() delivers them.

local ENABLER = "Resources/Client/Mileage/lua/ge/extensions/mileageEnabler.lua"
local SERVER = "Resources/Server/Mileage/mileage.lua"

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

local world

-- Runs fn with the globals of player p's game.
local function as(p, fn, ...)
	MPVehicleGE, be, gameplay_traffic = p.MPVehicleGE, p.be, p.traffic
	worldReadyState = 2
	function TriggerServerEvent(name, data)
		table.insert(world.toServer, {from = p.id, name = name, data = data})
	end
	function AddEventHandler(name, fn) p.handlers[name] = fn end
	return fn(...)
end

local function newWorld()
	world = {players = {}, toServer = {}, toClients = {}, broadcasts = {}}
	logs = {}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	os.clockhp = function() return 0 end
	jsonEncode, jsonDecode = encode, tryDecode
	settings = {getValue = function() return nil end, setValue = function() end}
	extensions = {
		mileage_compat = {report = function() end, targetGameVersion = "test", isMPSession = function() return true end},
		core_input_actionFilter = {setGroup = function() end, addAction = function() end},
	}
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
		-- The server encodes its tables itself and sends text.
		TriggerClientEvent = function(target, event, data)
			local message = {target = target, event = event, data = data}
			table.insert(world.toClients, message)
			if event == "rxCareerVehSync" then
				message.table = decode(data)
				table.insert(world.broadcasts, message)
			end
		end,
	}
	local realPrint = print
	print = function() end
	dofile(SERVER)
	print = realPrint
	return world
end

local function addPlayer(id, name)
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
	world.players[id] = p
	as(p, function()
		p.enabler = dofile(ENABLER)
		p.enabler.onExtensionLoaded()
		p.handlers.rxClientConfigUpdate(encode({remoteVehicleGhost = false, remoteUnicycleGhost = true,
			localUnicycleGhost = false, consoleEnabled = true, worldEditorEnabled = true}))
	end)
	return p
end

-- Delivers queued messages both ways until none are left.
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
			veh.mileageSpotRacer = fields.mileageSpotRacer
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

-- Runs each player's frame update for the given seconds, in half-second frames.
local function frames(p, seconds)
	for _ = 1, math.floor(seconds * 2 + 0.5) do as(p, p.enabler.onUpdate, 0.5, 0.5, 0.5) end
	pump()
end

local function nametag(p, sid) return p.vehicles[sid].hideNametag end

-- Me (player 0) and my friend (player 1), who drives car 1-0 and has a police car
-- (1-1) in road traffic and a parked car (1-2).
local function twoPlayers()
	newWorld()
	local me, friend = addPlayer(0, "Me"), addPlayer(1, "Friend")
	me.playerVehicle = spawn(0, 0)
	friend.playerVehicle = spawn(1, 0)
	spawn(1, 1, {JBeam = "fullsize", isTraffic = "true", ai = true})
	spawn(1, 2, {JBeam = "covet", isParked = "true"})
	return me, friend
end

--== traffic nametags ========================================================

test("my friend's police and parked cars carry no nametag on my game, the car they drive does", function()
	local me, friend = twoPlayers()
	frames(friend, 1.5)
	same(nametag(me, "1-0"), false, "the car my friend drives")
	same(nametag(me, "1-1"), true, "my friend's police car")
	same(nametag(me, "1-2"), true, "my friend's parked car")
end)

local function count(list, value)
	local n = 0
	for _, v in ipairs(list) do if v == value then n = n + 1 end end
	return n
end

local function marksSent(p) return count(p.serverRequests, "careerVehicleTrafficMarks") end

test("a parked car my friend climbs into gets their nametag within a second, and loses it when they leave", function()
	local me, friend = twoPlayers()
	frames(friend, 1)
	friend.playerVehicle = gameId(1, 2)
	frames(friend, 1)
	same(nametag(me, "1-2"), false, "the parked car my friend drives")
	same(nametag(me, "1-0"), false, "my friend's own car, which is not traffic")
	friend.playerVehicle = gameId(1, 0)
	frames(friend, 1)
	same(nametag(me, "1-2"), true, "the parked car once my friend is out")
end)

test("a car the game lists only as AI traffic, with no traffic or parked flag, carries no nametag", function()
	local me, friend = twoPlayers()
	spawn(1, 3, {JBeam = "etk800", ai = true})
	spawn(1, 4, {JBeam = "bastion", ai = false})
	frames(friend, 1)
	same(nametag(me, "1-3"), true, "my friend's AI road car")
	same(nametag(me, "1-4"), false, "a car in my friend's traffic data that is not AI")
end)

test("my friend's race spot opponent is marked as traffic: no nametag on my game", function()
	local me, friend = twoPlayers()
	spawn(1, 5, {JBeam = "pessima", mileageSpotRacer = "true"})
	frames(friend, 1)
	same(nametag(me, "1-5"), true, "the opponent car")
	same(nametag(me, "1-0"), false, "the car my friend drives")
	same(as(friend, friend.enabler.isTrafficCar, gameId(1, 5), friend.objects[gameId(1, 5)]), true,
		"isTrafficCar says so")
end)

test("marks go out at most once a second, only when they change, and only for the sender's cars", function()
	local me, friend = twoPlayers()
	frames(friend, 0.5)
	same(marksSent(friend), 0, "marks within the first second")
	frames(friend, 0.5)
	same(marksSent(friend), 1, "marks after a second")
	frames(me, 2)
	-- #87: a game with no traffic still sends its cars' first marks, false, once, so other
	-- games know at once that they can ask those cars for their paint.
	same(marksSent(me), 1, "marks from a game with no traffic")
	frames(me, 2)
	same(marksSent(me), 1, "marks from a game with no traffic once nothing changed")
	frames(friend, 3)
	same(marksSent(friend), 1, "marks while nothing changed")
	world.broadcasts = {}
	friend.playerVehicle = gameId(1, 1)
	frames(friend, 1)
	same(#world.broadcasts, 1, "updates for one changed mark")
	local update = world.broadcasts[1].table
	same(update["1-1"].traffic, false, "the changed car's mark")
	same(update["1-2"], nil, "an unchanged car")
end)

test("my game's own marks never hide the nametag on my cars for me", function()
	local me = twoPlayers()
	frames(me, 1)
	same(me.vehicles["0-0"].hideNametag, nil, "my car on my game")
end)

test("the server ignores marks for another player's car, malformed ids, non-booleans and bad payloads", function()
	local me, friend = twoPlayers()
	frames(friend, 1)
	world.broadcasts = {}
	careerVehicleTrafficMarks(0, encode({["1-1"] = false, ["1-2"] = false}))
	careerVehicleTrafficMarks(1, encode({["1-1x"] = false, ["01-"] = false, [1] = false}))
	careerVehicleTrafficMarks(1, encode({["1-1"] = "no", ["1-2"] = 0}))
	careerVehicleTrafficMarks(1, encode({["1-9"] = true}))
	careerVehicleTrafficMarks(1, "{not a table")
	careerVehicleTrafficMarks(1, "")
	careerVehicleTrafficMarks(1, nil)
	pump()
	same(#world.broadcasts, 0, "updates sent")
	same(nametag(me, "1-1"), true, "my friend's police car")
	same(nametag(me, "1-2"), true, "my friend's parked car")
end)

test("a player who joins later gets the marks with the vehicle list", function()
	local _, friend = twoPlayers()
	frames(friend, 1)
	local late = addPlayer(2, "Late")
	for vid, model in pairs({[0] = "pickup", [1] = "fullsize", [2] = "covet"}) do
		local gid = gameId(1, vid)
		local veh = {owner = 1, serverVehicleID = "1-" .. vid, JBeam = model, active = true}
		function veh:setActive(on) self.active = on == 1 end
		function veh:getActive() return self.active end
		function veh:queueLuaCommand() end
		function veh:setField() end
		function veh:setDynDataFieldbyName(name, _, value) self[name] = value end
		late.objects[gid] = veh
		late.vehicles["1-" .. vid] = {gameVehicleID = gid, jbeam = model, isLocal = false}
	end
	careerVehSyncRequested(2, "")
	pump()
	same(nametag(late, "1-0"), false, "the car my friend drives")
	same(nametag(late, "1-1"), true, "my friend's police car")
	same(nametag(late, "1-2"), true, "my friend's parked car")
end)

test("a remote car that is hidden or on the props list has no nametag; a remote car that is ready keeps its mark", function()
	local me, friend = twoPlayers()
	spawn(1, 3, {JBeam = "cones"})
	spawn(1, 4, {JBeam = "bastion"})
	frames(friend, 1)
	same(nametag(me, "1-3"), true, "a prop")
	same(nametag(me, "1-4"), false, "another car of my friend's")
	as(friend, function() friend.objects[gameId(1, 4)]:setActive(0) end)
	pump()
	same(nametag(me, "1-4"), true, "a car my friend hid")
	as(me, me.enabler.onVehicleReady, gameId(1, 1))
	same(nametag(me, "1-1"), true, "the police car once it is ready again")
end)

test("leaving the server forgets the sent marks, so a rejoin sends them again", function()
	local _, friend = twoPlayers()
	frames(friend, 1)
	same(marksSent(friend), 1, "marks before leaving")
	as(friend, friend.enabler.onBeamMPServerLeave)
	frames(friend, 1)
	same(marksSent(friend), 2, "marks after rejoining")
end)

test("a car BeamMP gives a used server id is marked afresh", function()
	local me, friend = twoPlayers()
	frames(friend, 1)
	-- 1-2 is deleted and a new parked car takes its server id under a new game id.
	friend.objects[gameId(1, 2)] = nil
	local veh = {owner = 1, serverVehicleID = "1-2", JBeam = "vivace", isParked = "true", active = true}
	function veh:getActive() return true end
	friend.objects[999] = veh
	friend.vehicles["1-2"].gameVehicleID = 999
	onVehicleSpawnHandler(1, 2, "")
	pump()
	same(nametag(me, "1-2"), false, "before the new car's mark")
	frames(friend, 1)
	same(nametag(me, "1-2"), true, "the new parked car")
end)

test("a traffic car hidden for a mission keeps its mark, so it comes back without a nametag", function()
	local me, friend = twoPlayers()
	frames(friend, 1)
	local sent = marksSent(friend)
	-- The game's freeze clears its traffic list while the car is hidden.
	as(friend, function() friend.objects[gameId(1, 1)]:setActive(0) end)
	friend.trafficData = {}
	pump()
	frames(friend, 2)
	same(marksSent(friend), sent, "marks sent while the car is hidden")
	friend.trafficData = {[gameId(1, 1)] = {isAi = true}}
	as(friend, function() friend.objects[gameId(1, 1)]:setActive(1) end)
	pump()
	same(nametag(me, "1-1"), true, "the police car as soon as it is shown again")
	frames(friend, 1)
	same(marksSent(friend), sent, "marks sent once it is back in traffic")
end)

test("a marked car my friend's game rebuilds and they then drive gets their nametag back", function()
	local me, friend = twoPlayers()
	frames(friend, 1)
	same(nametag(me, "1-2"), true, "the parked car before the rebuild")
	-- The rebuilt parked car has a new game id, and my friend climbs into it.
	friend.objects[gameId(1, 2)] = nil
	local veh = {owner = 1, serverVehicleID = "1-2", JBeam = "covet", isParked = "true", active = true}
	function veh:getActive() return self.active end
	friend.objects[999] = veh
	friend.vehicles["1-2"].gameVehicleID = 999
	friend.playerVehicle = 999
	onVehicleEditedHandler(1, 2, "")
	pump()
	frames(friend, 1)
	same(nametag(me, "1-2"), false, "the rebuilt car my friend drives")
end)

--== one-car updates =========================================================

local function rows(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function toEveryone()
	local list = {}
	for _, m in ipairs(world.broadcasts) do
		if m.target == -1 then table.insert(list, m) end
	end
	return list
end

local function listRequests(p) return count(p.serverRequests, "careerVehSyncRequested") end

-- My friend with 16 cars: the one they drive and 15 traffic and parked cars.
local function busyFriend()
	local me, friend = twoPlayers()
	for vid = 3, 15 do spawn(1, vid, {JBeam = "covet", isParked = "true"}) end
	frames(friend, 1)
	world.broadcasts = {}
	me.serverRequests, friend.serverRequests = {}, {}
	return me, friend
end

local function hide14(friend)
	as(friend, function()
		for vid = 1, 14 do friend.objects[gameId(1, vid)]:setActive(0) end
	end)
	pump()
end

test("hiding 14 cars sends 14 one-car updates", function()
	local _, friend = busyFriend()
	hide14(friend)
	local updates = toEveryone()
	same(#updates, 14, "updates to every player")
	for i, update in ipairs(updates) do
		same(rows(update.table), 1, "cars in update " .. i)
	end
end)

test("my game applies the 14 hides without asking for the list", function()
	local me, friend = busyFriend()
	hide14(friend)
	same(listRequests(me), 0, "list requests from my game")
	for vid = 1, 14 do same(me.objects[gameId(1, vid)].active, false, "car 1-" .. vid .. " on my game") end
	same(me.objects[gameId(1, 15)].active, true, "car 1-15 on my game")
end)

test("a spawn sends every player that car alone", function()
	busyFriend()
	spawn(1, 16, {JBeam = "pickup"})
	local updates = toEveryone()
	same(#updates, 1, "updates to every player")
	same(rows(updates[1].table), 1, "cars in the update")
	expect(updates[1].table["1-16"] ~= nil, "the spawned car is the one sent")
end)

test("a player cannot hide another player's car", function()
	local me, friend = busyFriend()
	as(me, function()
		TriggerServerEvent("careerVehicleActiveHandler", encode({serverVehicleID = "1-0", active = false}))
	end)
	pump()
	same(#toEveryone(), 0, "updates sent")
	same(me.objects[gameId(1, 0)].active, true, "my friend's car on my game")
end)

test("the server ignores hides with a malformed id, a non-boolean or a bad payload", function()
	local me, friend = busyFriend()
	for _, payload in ipairs({encode({serverVehicleID = "1-0x", active = false}), encode({serverVehicleID = 10, active = false}),
			encode({serverVehicleID = "1-0", active = 0}), encode({serverVehicleID = "1-0"}), "{broken", ""}) do
		careerVehicleActiveHandler(1, payload)
	end
	careerVehicleActiveHandler(1, nil)
	-- Ids the server never builds: a leading zero on the player or the vehicle.
	careerVehicleActiveHandler(1, encode({serverVehicleID = "01-0", active = false}))
	careerVehicleActiveHandler(1, encode({serverVehicleID = "1-00", active = false}))
	pump()
	same(#toEveryone(), 0, "updates sent")
	same(me.objects[gameId(1, 0)].active, true, "my friend's car on my game")
end)

test("a car is its owner's by the whole player id, not by the id's first digits", function()
	newWorld()
	onVehicleSpawnHandler(10, 0, "")
	onVehicleSpawnHandler(1, 0, "")
	world.broadcasts = {}
	careerVehicleActiveHandler(1, encode({serverVehicleID = "10-0", active = false}))
	careerVehicleTrafficMarks(1, encode({["10-0"] = true}))
	careerVehicleActiveHandler(10, encode({serverVehicleID = "1-0", active = false}))
	careerVehicleTrafficMarks(10, encode({["1-0"] = true}))
	same(#world.broadcasts, 0, "updates for another player's car")
	careerVehicleActiveHandler(10, encode({serverVehicleID = "10-0", active = false}))
	careerVehicleTrafficMarks(10, encode({["10-0"] = true}))
	same(#world.broadcasts, 2, "updates for player 10's own car")
	local last = world.broadcasts[2].table["10-0"]
	same(last.active, false, "its hide")
	same(last.traffic, true, "its mark")
end)

test("my game ignores a vehicle update that is not a list of car states", function()
	local me = busyFriend()
	for _, data in ipairs({"null", "{broken", "5", encode({["1-1"] = "hidden", ["1-2"] = false}),
			encode({["9-9"] = {active = false}})}) do
		as(me, me.handlers.rxCareerVehSync, data)
	end
	same(me.objects[gameId(1, 1)].active, true, "car 1-1 on my game")
	same(me.objects[gameId(1, 2)].active, true, "car 1-2 on my game")
	as(me, me.handlers.rxCareerVehSync, encode({["1-15"] = {active = false, traffic = true}}))
	same(me.objects[gameId(1, 15)].active, false, "a good update after the bad ones")
end)

test("a hidden car my friend rebuilds shows again on my game", function()
	local me, friend = busyFriend()
	local gid = gameId(1, 15)
	as(friend, function() friend.objects[gid]:setActive(0) end)
	pump()
	same(me.objects[gid].active, false, "the car once hidden")
	-- My friend's game rebuilds the car, which comes back switched on there, and my game
	-- builds its copy again.
	friend.objects[gid].active = true
	onVehicleEditedHandler(1, 15, "")
	me.objects[gid].active = true
	as(me, me.enabler.onVehicleSpawned, gid)
	pump()
	same(me.objects[gid].active, true, "the rebuilt car on my game")
end)

test("a player who asks still gets the full list, hides and marks included", function()
	local me, friend = busyFriend()
	hide14(friend)
	world.broadcasts = {}
	careerVehSyncRequested(0, "")
	same(#world.broadcasts, 1, "lists sent")
	local list = world.broadcasts[1]
	same(list.target, 0, "sent to")
	same(rows(list.table), 17, "cars in the list")
	same(list.table["1-1"].active, false, "a hidden car")
	same(list.table["1-1"].traffic, true, "its mark")
end)

test("a remote car changed by something other than the server asks for the list once", function()
	local me = busyFriend()
	as(me, function() me.objects[gameId(1, 15)]:setActive(0) end)
	pump()
	frames(me, 1)
	same(listRequests(me), 1, "list requests")
	same(me.objects[gameId(1, 15)].active, true, "the car the server says is showing")
end)

test("a remote car the server never sent asks for the list", function()
	local me = busyFriend()
	local veh = {owner = 1, serverVehicleID = "1-40", JBeam = "pickup", active = true}
	function veh:setActive(on) self.active = on == 1; as(me, me.enabler.onVehicleActiveChanged, 999, self.active) end
	function veh:queueLuaCommand() end
	function veh:setDynDataFieldbyName(name, _, value) self[name] = value end
	me.objects[999] = veh
	me.vehicles["1-40"] = {gameVehicleID = 999, jbeam = "pickup", isLocal = false}
	as(me, me.enabler.onVehicleSpawned, 999)
	pump()
	frames(me, 1)
	same(listRequests(me), 1, "requests on spawn")
	as(me, function() veh:setActive(0) end)
	pump()
	frames(me, 1)
	same(listRequests(me), 2, "requests on a change")
end)

test("a remote car built after its hidden state arrived takes it without asking", function()
	local me, friend = busyFriend()
	-- My game has not built car 1-3 yet when my friend hides it.
	local entry = me.vehicles["1-3"]
	me.vehicles["1-3"] = nil
	as(friend, function() friend.objects[gameId(1, 3)]:setActive(0) end)
	pump()
	me.vehicles["1-3"] = entry
	as(me, me.enabler.onVehicleSpawned, gameId(1, 3))
	pump()
	same(listRequests(me), 0, "list requests")
	same(me.objects[gameId(1, 3)].active, false, "car 1-3 on my game")
	same(nametag(me, "1-3"), true, "its nametag")
end)

test("leaving the server forgets the kept states", function()
	local me = busyFriend()
	as(me, me.enabler.onBeamMPServerLeave)
	as(me, me.enabler.onVehicleSpawned, gameId(1, 3))
	pump()
	frames(me, 1)
	same(listRequests(me), 1, "list requests for a car whose state is forgotten")
end)

--== joining a busy server ===================================================

-- My game joins while 100 of my friend's cars appear on it, none with a state yet.
local function joinBusyServer()
	newWorld()
	local friend = addPlayer(1, "Friend")
	for vid = 0, 99 do spawn(1, vid, {JBeam = "covet", isParked = vid > 0 and "true" or nil}) end
	local me = addPlayer(0, "Me")
	world.broadcasts = {}
	for vid = 0, 99 do
		local gid = gameId(1, vid)
		local veh = {owner = 1, serverVehicleID = "1-" .. vid, JBeam = "covet", active = true}
		function veh:setActive(on) self.active = on == 1 end
		function veh:getActive() return self.active end
		function veh:queueLuaCommand() end
		function veh:setField() end
		function veh:setDynDataFieldbyName(name, _, value) self[name] = value end
		me.objects[gid] = veh
		me.vehicles["1-" .. vid] = {gameVehicleID = gid, jbeam = "covet", isLocal = false}
		as(me, me.enabler.onVehicleSpawned, gid)
	end
	pump()
	return me, friend
end

local function listsTo(id)
	local n = 0
	for _, m in ipairs(world.broadcasts) do
		if m.target == id and rows(m.table) > 1 then n = n + 1 end
	end
	return n
end

test("a game that sees 100 cars appear asks for the car list once in that second", function()
	local me = joinBusyServer()
	same(listRequests(me), 0, "list requests before the next frame")
	frames(me, 0.5)
	same(listRequests(me), 1, "list requests in the first second")
	frames(me, 3)
	same(listRequests(me), 1, "list requests once nothing else changed")
	same(me.objects[gameId(1, 5)].active, true, "a car on my game")
end)

test("a car change inside the second after a list request waits for the next second", function()
	local me = joinBusyServer()
	frames(me, 0.5)
	as(me, me.enabler.onVehicleActiveChanged, gameId(1, 7), false)
	frames(me, 0.5)
	same(listRequests(me), 1, "list requests half a second later")
	frames(me, 0.5)
	same(listRequests(me), 2, "list requests a second later")
end)

test("leaving the server drops a list request still waiting", function()
	local me = joinBusyServer()
	as(me, me.enabler.onBeamMPServerLeave)
	frames(me, 2)
	same(listRequests(me), 0, "list requests after leaving")
end)

test("the server answers a player's list requests at most once a second, the rest at the next tick", function()
	newWorld()
	addPlayer(0, "Me")
	addPlayer(1, "Friend")
	spawn(1, 0)
	spawn(1, 1)
	world.broadcasts = {}
	world.now = 10
	for _ = 1, 20 do careerVehSyncRequested(0, "") end
	same(listsTo(0), 1, "answers at once")
	world.now = 10.5
	tick()
	same(listsTo(0), 1, "answers half a second later")
	world.now = 11
	tick()
	same(listsTo(0), 2, "answers a second later")
	world.now = 12
	tick()
	world.now = 13
	tick()
	same(listsTo(0), 2, "answers once nothing more was asked")
	careerVehSyncRequested(0, "")
	same(listsTo(0), 3, "a request a second after the last answer is answered at once")
end)

test("a list request still waiting when its player leaves is never answered", function()
	newWorld()
	local me = addPlayer(0, "Me")
	addPlayer(1, "Friend")
	spawn(1, 0)
	spawn(1, 1)
	world.broadcasts = {}
	careerVehSyncRequested(0, "")
	careerVehSyncRequested(0, "")
	world.players[0] = nil
	onPlayerDisconnectHandler(0)
	world.now = 5
	tick()
	same(listsTo(0), 1, "answers")
end)

test("the cars of a player who leaves are gone from later lists, other players' cars stay", function()
	newWorld()
	addPlayer(0, "Me")
	addPlayer(3, "Three")
	addPlayer(13, "Thirteen")
	spawn(3, 0)
	spawn(3, 1)
	spawn(13, 0)
	spawn(13, 1)
	world.players[3] = nil
	onPlayerDisconnectHandler(3)
	world.broadcasts = {}
	world.now = 5
	careerVehSyncRequested(0, "")
	local list = world.broadcasts[1].table
	same(list["3-0"], nil, "car 3-0")
	same(list["3-1"], nil, "car 3-1")
	expect(list["13-0"] ~= nil and list["13-1"] ~= nil, "player 13's cars kept")
end)

--== requests for traffic ====================================================

-- Captures what the server sends without delivering it.
local function capture(fn)
	world.toClients = {}
	fn()
	local sent = world.toClients
	world.toClients = {}
	return sent
end

local function countEvent(list, target, event)
	local n = 0
	for _, m in ipairs(list) do
		if m.target == target and m.event == event then n = n + 1 end
	end
	return n
end

test("the server drops damage and paint requests for traffic without using up the requester's allowance", function()
	newWorld()
	addPlayer(0, "Me")
	addPlayer(2, "Two")
	spawn(2, 0)
	spawn(2, 1)
	careerVehicleTrafficMarks(2, encode({["2-0"] = true}))
	pump()
	local sent = capture(function()
		for _ = 1, 10 do
			careerDamageRequest(0, encode({v = "2-0"}))
			requestPartPaintsHandler(0, encode({serverVehicleID = "2-0"}))
		end
		careerDamageRequest(0, encode({v = "2-1"}))
		requestPartPaintsHandler(0, encode({serverVehicleID = "2-1"}))
	end)
	same(countEvent(sent, 2, "rxCareerDamageRequest"), 1, "damage requests reaching the owner")
	same(sent[1] and sent[1].data, '{"v":"2-1"}', "the request that got through")
	same(countEvent(sent, 2, "rxRequestPartPaints"), 1, "paint requests reaching the owner")
end)

test("a paint request reaches the owner by the whole player id", function()
	newWorld()
	addPlayer(0, "Me")
	addPlayer(1, "One")
	addPlayer(12, "Twelve")
	spawn(12, 0)
	local sent = capture(function() requestPartPaintsHandler(0, encode({serverVehicleID = "12-0"})) end)
	same(countEvent(sent, 12, "rxRequestPartPaints"), 1, "requests to player 12")
	same(countEvent(sent, 1, "rxRequestPartPaints"), 0, "requests to player 1")
	same(decode(sent[1].data).originID, 0, "who asked")
end)

test("a paint request with a malformed id or for a player who is not here is dropped", function()
	newWorld()
	addPlayer(0, "Me")
	addPlayer(1, "One")
	for _, data in ipairs({encode({serverVehicleID = "x-0"}), encode({serverVehicleID = 5}), encode({}), "{broken",
			encode({serverVehicleID = "7-0"})}) do
		local sent = capture(function() requestPartPaintsHandler(0, data) end)
		same(#sent, 0, "messages sent for " .. data)
	end
end)

test("isRemoteTraffic is true only for another player's car the server marked as traffic", function()
	local me, friend = twoPlayers()
	frames(friend, 1)
	same(me.enabler.isRemoteTraffic("1-1"), true, "my friend's police car")
	same(me.enabler.isRemoteTraffic("1-2"), true, "my friend's parked car")
	same(me.enabler.isRemoteTraffic("1-0"), false, "the car my friend drives")
	same(me.enabler.isRemoteTraffic("1-99"), false, "a car the server never sent")
end)

local PAINT = "Resources/Client/Mileage/lua/ge/extensions/mileagePerPartPaint.lua"

-- The paint requests mileagePerPartPaint sends when cars 1-0 and 1-1 of another player
-- are ready on this game, with the server's traffic marks as `traffic` says.
local function paintRequests(traffic, withCheck)
	local sent = {}
	function log() end
	function setExtensionUnloadMode() end
	jsonEncode = encode
	function TriggerServerEvent(name, data) table.insert(sent, {name = name, data = data}) end
	MPVehicleGE = {
		getServerVehicleID = function(gid) return "1-" .. gid end,
		isOwn = function() return false end,
	}
	mileageEnabler = {}
	if withCheck ~= false then
		mileageEnabler.isRemoteTraffic = function(sid) return traffic[sid] == true end
	end
	local paint = dofile(PAINT)
	paint.onVehicleReady(0)
	paint.onVehicleReady(1)
	local requests = {}
	for _, m in ipairs(sent) do
		if m.name == "requestPartPaints" then table.insert(requests, decode(m.data).serverVehicleID) end
	end
	table.sort(requests)
	return table.concat(requests, ",")
end

test("a game asks for the part paints of another player's car, never of their traffic", function()
	same(paintRequests({["1-1"] = true}), "1-0", "paint requests")
	same(paintRequests({}, false), "1-0,1-1", "paint requests with an enabler that cannot tell traffic")
end)

test("#87: a player who joins, with the real enabler and server, asks only my friend's own car for paint", function()
	local _, friend = twoPlayers()
	frames(friend, 1) -- my friend's game has sent its traffic marks
	local late = addPlayer(2, "Late")
	late.MPVehicleGE.getGameVehicleID = function(sid)
		local entry = late.vehicles[sid]
		return entry and entry.gameVehicleID
	end
	local now = 0
	os.clockhp = function() return now end
	local paint
	as(late, function()
		mileageEnabler = late.enabler
		paint = dofile(PAINT)
		paint.onExtensionLoaded()
	end)
	-- BeamMP builds my friend's car, police car and parked car on the joining game, and
	-- they become ready before the server's vehicle list has arrived.
	for vid, model in pairs({[0] = "pickup", [1] = "fullsize", [2] = "covet"}) do
		local gid = gameId(1, vid)
		local veh = {owner = 1, serverVehicleID = "1-" .. vid, JBeam = model, active = true}
		function veh:setActive(on) self.active = on == 1 end
		function veh:getActive() return self.active end
		function veh:queueLuaCommand() end
		function veh:setField() end
		function veh:setDynDataFieldbyName(name, _, value) self[name] = value end
		late.objects[gid] = veh
		late.vehicles["1-" .. vid] = {gameVehicleID = gid, jbeam = model, isLocal = false}
		as(late, paint.onVehicleReady, gid)
	end
	pump()
	same(count(late.serverRequests, "requestPartPaints"), 0, "paint requests before the vehicle list")
	careerVehSyncRequested(2, "")
	pump()
	now = 0.5
	as(late, paint.onUpdate)
	local asked = {}
	for _, m in ipairs(world.toServer) do
		if m.name == "requestPartPaints" then table.insert(asked, decode(m.data).serverVehicleID) end
	end
	same(table.concat(asked, ","), "1-0", "cars asked for paint once the list arrived")
	pump()
	same(count(late.serverRequests, "requestPartPaints"), 1, "paint requests once the list arrived")
	now = 10
	as(late, paint.onUpdate)
	pump()
	same(count(late.serverRequests, "requestPartPaints"), 1, "paint requests after the 5 s wait")
	os.clockhp = function() return 0 end
end)

test("#87: a traffic car my friend spawns while I am on the server is not asked for paint before its mark", function()
	local me, friend = twoPlayers()
	frames(friend, 1)
	me.MPVehicleGE.getGameVehicleID = function(sid)
		local entry = me.vehicles[sid]
		return entry and entry.gameVehicleID
	end
	local now = 0
	os.clockhp = function() return now end
	local paint
	as(me, function()
		mileageEnabler = me.enabler
		paint = dofile(PAINT)
		paint.onExtensionLoaded()
	end)
	local function paintRequests()
		local asked = {}
		for _, m in ipairs(world.toServer) do
			if m.from == 0 and m.name == "requestPartPaints" then table.insert(asked, decode(m.data).serverVehicleID) end
		end
		table.sort(asked)
		return table.concat(asked, ",")
	end
	-- The server tells every game of each new car with {active = true}; the owner's game
	-- marks its traffic a moment later, once a second.
	local police = spawn(1, 3, {JBeam = "fullsize", isTraffic = "true", ai = true})
	local own = spawn(1, 4, {JBeam = "pickup"})
	world.toServer = {}
	as(me, paint.onVehicleReady, police)
	as(me, paint.onVehicleReady, own)
	same(paintRequests(), "", "paint requests before the owner's marks")
	frames(friend, 1)
	world.toServer = {}
	now = 1
	as(me, paint.onUpdate)
	same(paintRequests(), "1-4", "paint requests once the owner marked both cars")
	world.toServer = {}
	now = 10
	as(me, paint.onUpdate)
	same(paintRequests(), "", "paint requests after the 5 s wait")
	os.clockhp = function() return 0 end
end)

-- Me with the real paint module, on a world where my friend's game has sent its marks.
-- Returns my paint module and a function listing the cars I have asked for paint since
-- the last call.
local function paintOnMyGame()
	local me, friend = twoPlayers()
	frames(friend, 1)
	me.MPVehicleGE.getGameVehicleID = function(sid)
		local entry = me.vehicles[sid]
		return entry and entry.gameVehicleID
	end
	local paint
	as(me, function()
		mileageEnabler = me.enabler
		paint = dofile(PAINT)
		paint.onExtensionLoaded()
	end)
	world.toServer = {}
	local function askedSinceLast()
		local asked = {}
		for _, m in ipairs(world.toServer) do
			if m.from == 0 and m.name == "requestPartPaints" then table.insert(asked, decode(m.data).serverVehicleID) end
		end
		world.toServer = {}
		table.sort(asked)
		return table.concat(asked, ",")
	end
	return me, friend, paint, askedSinceLast
end

-- Puts a new copy of the owner's car sid on every game under game id gid, as BeamMP does
-- when it rebuilds a car or gives a used server id to a new one.
local function replaceCar(sid, oldGid, gid, fields)
	local owner = tonumber(sid:match("^(%d+)"))
	for id, p in pairs(world.players) do
		local veh = {owner = owner, serverVehicleID = sid, JBeam = fields.JBeam, active = true}
		if id == owner then veh.isTraffic, veh.isParked = fields.isTraffic, fields.isParked end
		function veh:setActive(on) self.active = on == 1 end
		function veh:getActive() return self.active end
		function veh:queueLuaCommand() end
		function veh:setField() end
		function veh:setDynDataFieldbyName(name, _, value) self[name] = value end
		p.objects[oldGid] = nil
		p.objects[gid] = veh
		p.vehicles[sid] = {gameVehicleID = gid, jbeam = fields.JBeam, isLocal = id == owner}
	end
end

test("#87: my friend's own car rebuilt under a new game id keeps its mark, so I ask it for paint at once", function()
	local me, _, paint, askedSinceLast = paintOnMyGame()
	os.clockhp = function() return 0 end
	replaceCar("1-0", gameId(1, 0), 997, {JBeam = "pickup"})
	onVehicleEditedHandler(1, 0, "")
	pump()
	as(me, paint.onVehicleDestroyed, gameId(1, 0))
	as(me, paint.onVehicleReady, 997)
	same(askedSinceLast(), "1-0", "paint requests on the frame the rebuilt car is ready")
	as(me, paint.onUpdate)
	same(askedSinceLast(), "", "paint requests on the next frame")
end)

test("#87: a new own car under a used server id is asked for paint once its owner marks it, not after the 5 s wait", function()
	local me, friend, paint, askedSinceLast = paintOnMyGame()
	local now = 0
	os.clockhp = function() return now end
	-- My friend spawns a car of their own, then deletes it; BeamMP gives its server id
	-- to the next car they spawn, under a new game id. Neither car is traffic.
	local first = spawn(1, 5, {JBeam = "pickup"})
	as(me, paint.onVehicleReady, first)
	frames(friend, 1)
	now = 1
	as(me, paint.onUpdate)
	same(askedSinceLast(), "1-5", "paint requests for the first car")
	replaceCar("1-5", first, 998, {JBeam = "vivace"})
	onVehicleSpawnHandler(1, 5, "")
	pump()
	as(me, paint.onVehicleDestroyed, first)
	now = 2
	as(me, paint.onVehicleReady, 998)
	same(askedSinceLast(), "", "paint requests before the new car's mark")
	frames(friend, 1)
	now = 3
	as(me, paint.onUpdate)
	same(askedSinceLast(), "1-5", "paint requests once my friend's game marked the new car")
	now = 10
	as(me, paint.onUpdate)
	same(askedSinceLast(), "", "paint requests after the 5 s wait")
	os.clockhp = function() return 0 end
end)
