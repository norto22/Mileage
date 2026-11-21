-- mileage/traffic.lua: a share that shrinks during a career deletes this player's
-- traffic and parked cars above it (so BeamMP deletes them on every game), and one that
-- grows spawns the missing cars through the game's own spawns, a few a second. A
-- mission's or the tutorial's hide stays a hide until it ends.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileage/traffic.lua"
local COMPAT = "Resources/Client/Mileage/lua/ge/extensions/mileage/compat.lua"
local SERVER = "Resources/Server/Mileage/mileage.lua"

local logs, clock

--== a game =================================================================
-- One player's game: its vehicles, the game's traffic and parking systems, BeamMP and
-- the Mileage traffic meter. Every game keeps its own stand-ins; use(game) makes them
-- the globals the meter reads, as if that game were running.

local Car = {}
Car.__index = Car
function Car:getId() return self.id end
function Car:getActive() return self.active end
function Car:setActive(on) self.active = on == 1 or on == true end
function Car:getPosition() return self.pos end
function Car:delete() self.game.destroy(self.id) end

local function newGame(opts)
	opts = opts or {}
	local g = {
		objects = {}, nextId = 100, calls = {}, spawns = {}, deleted = {},
		camera = {x = 0, y = 0, z = 0}, playerId = 1, missionId = nil, tutorial = false,
		pursuing = {}, notOwn = {}, inventory = {},
		config = {roadTrafficEnabled = true, roadTrafficAmount = 6, parkedTrafficEnabled = true,
			parkedTrafficAmount = 8, trafficShare = opts.share},
		farFrom = opts.farFrom or 200, -- where new cars appear, in metres from the camera
		spots = {}, queued = {},
	}
	-- free parking spots, far from the camera unless a test says otherwise
	for i = 1, 20 do table.insert(g.spots, {x = 0, y = 300 + 20 * i, z = 0}) end
	local traffic = {data = {}, active = nil}
	local parking = {list = {}, active = nil}
	g.traffic, g.parking = traffic, parking

	local function record(...) table.insert(g.calls, {...}) end

	function g.newCar(fields)
		g.nextId = g.nextId + 1
		local car = setmetatable({id = g.nextId, active = true, game = g,
			pos = {x = g.farFrom + 10 * g.nextId % 500, y = 0, z = 0}}, Car)
		for k, v in pairs(fields or {}) do car[k] = v end
		g.objects[car.id] = car
		return car
	end

	-- What the game does when a vehicle goes: its traffic and parking forget it.
	function g.destroy(id)
		g.objects[id] = nil
		traffic.data[id] = nil
		for i, parked in ipairs(parking.list) do
			if parked == id then table.remove(parking.list, i) break end
		end
		table.insert(g.deleted, id)
	end

	function g.addTraffic(fields, entry)
		local car = g.newCar(fields)
		car.isTraffic = "true"
		local e = {isAi = true, role = {name = "standard"}, roleName = "standard"}
		for k, v in pairs(entry or {}) do e[k] = v end
		if e.roleName ~= "standard" then e.role = {name = e.roleName} end
		traffic.data[car.id] = e
		return car
	end

	function g.addParked(fields)
		local car = g.newCar(fields)
		car.isParked = "true"
		table.insert(parking.list, car.id)
		return car
	end

	-- the game's traffic system
	function traffic.getTrafficData() return traffic.data end
	function traffic.getState() return "on" end
	function traffic.removeTraffic(id) record("removeTraffic", id) traffic.data[id] = nil end
	function traffic.setActiveAmount(n) record("trafficActive", n) traffic.active = n end
	function traffic.getTrafficAmount()
		local n = 0
		for _, e in pairs(traffic.data) do if e.isAi then n = n + 1 end end
		return n
	end
	function traffic.toggle() end
	function traffic.freezeState(options)
		record("freeze", options.despawnVehicles)
		-- the game's traffic stops while frozen: its table is empty until unfreeze
		g.frozen, traffic.data = traffic.data, {}
		return "trafficData", "policeData", "parkingData"
	end
	function traffic.unfreezeState(trafficData, policeData, parkingData, options)
		record("unfreeze", options and options.respawnVehicles)
		traffic.data, g.frozen = g.frozen or traffic.data, nil
	end
	function traffic.onVehicleGroupSpawned(ids, _, name)
		if name ~= "autoTraffic" then return end
		for _, id in ipairs(ids) do
			local car = g.objects[id]
			car.isTraffic = "true"
			local role = car.config == "police" and "police" or "standard"
			traffic.data[id] = {isAi = true, role = {name = role}, roleName = role}
		end
	end
	-- The career start, as the game's setupTrafficHelper does it: police from the road
	-- amount, one reserved taxi on top when there is road traffic, then the parked cars.
	function traffic.setupTrafficHelper(road, options, parked)
		record("helper", road, options, parked)
		local police = 0
		if options and options.police and road >= 3 then
			police = math.min(math.ceil(road * 0.25), math.floor(road * 0.4))
		end
		for i = 1, road do g.addTraffic(nil, {roleName = i <= police and "police" or "standard"}) end
		if road > 0 then g.addTraffic(nil, {reserved = "taxi"}) end
		for _ = 1, parked do g.addParked() end
	end

	-- the game's parking system
	function parking.getParkedCarsList() return parking.list end
	function parking.getParkingAmount() return #parking.list end
	function parking.removeVehicle(id)
		record("removeVehicle", id)
		for i, parked in ipairs(parking.list) do
			if parked == id then table.remove(parking.list, i) break end
		end
	end
	function parking.deleteVehicles() error("deleteVehicles takes cars from the front of the list") end
	function parking.setActiveAmount(n) record("parkingActive", n) parking.active = n end
	function parking.setupVehicles(n, options)
		record("setupVehicles", n, options and options.keepCurrent)
		if g.noParkingSpots then return false end
		g.multiSpawn.spawnGroup({{model = "parked"}}, n, {name = "autoParking"})
		return true
	end
	-- The game's spot picker: free spots, nearest first. It does not hold to minDist here,
	-- so the meter's own check is what keeps cars out of view.
	function parking.getRandomParkingSpots(origin, minDist, maxDist, count, filters)
		record("findSpots", minDist, count, filters and filters.checkVehicles)
		if g.noParkingSpots then return {} end
		local list = {}
		for _, spot in ipairs(g.spots) do
			local taken = false
			for _, car in pairs(g.objects) do
				local dx, dy = car.pos.x - spot.x, car.pos.y - spot.y
				if dx * dx + dy * dy < 9 then taken = true break end
			end
			if not taken then
				local dx, dy, dz = spot.x - origin.x, spot.y - origin.y, spot.z - origin.z
				table.insert(list, {ps = {pos = spot, rot = "rot"}, d = dx * dx + dy * dy + dz * dz})
			end
		end
		table.sort(list, function(a, b) return a.d < b.d end)
		return list
	end
	function parking.onVehicleGroupSpawned(ids, _, name)
		if name ~= "autoParking" then return end
		for _, id in ipairs(ids) do
			g.objects[id].isParked = "true"
			table.insert(parking.list, id)
		end
	end

	-- the game's group spawner: builds the cars and fires the group hook
	-- With g.deferSpawns the groups wait in g.queued until g.buildQueued().
	g.multiSpawn = {}
	local function build(group, amount, options)
		local ids = {}
		for i = 1, amount do
			local entry = group[(i - 1) % #group + 1]
			local car = g.newCar({model = entry.model, config = entry.config})
			local spot = options.customTransforms and options.customTransforms[i]
			if spot then car.pos = {x = spot.pos.x, y = spot.pos.y, z = spot.pos.z} end
			table.insert(ids, car.id)
		end
		traffic.onVehicleGroupSpawned(ids, #g.spawns, options.name)
		parking.onVehicleGroupSpawned(ids, #g.spawns, options.name)
		if g.meter and g.meter.onVehicleGroupSpawned then g.meter.onVehicleGroupSpawned(ids, #g.spawns, options.name) end
	end
	function g.multiSpawn.spawnGroup(group, amount, options)
		table.insert(g.spawns, {at = clock, name = options.name, mode = options.mode, n = amount, group = group,
			transforms = options.customTransforms})
		if g.deferSpawns then
			table.insert(g.queued, {group, amount, options})
		else
			build(group, amount, options)
		end
		return #g.spawns
	end
	function g.multiSpawn.createGroup(n, params)
		record("createGroup", n, params.filters.Type.propparked)
		local list = {}
		for _ = 1, n do table.insert(list, {model = "parked"}) end
		return list
	end
	function g.buildQueued()
		local queued = g.queued
		g.queued = {}
		for _, args in ipairs(queued) do build(args[1], args[2], args[3]) end
	end
	g.utils = {
		createTrafficGroup = function(n)
			local list = {}
			for _ = 1, n do table.insert(list, {model = "simple_traffic"}) end
			return list
		end,
		getBaseGroupParams = function() return {filters = {Type = {car = 1}}, minPop = 50} end,
		createPoliceGroup = function(n)
			local list = {}
			for _ = 1, n do table.insert(list, {model = "fullsize", config = "police"}) end
			return list
		end,
	}

	g.be = {
		getObjectByID = function(_, id) return g.objects[id] end,
		getPlayerVehicleID = function() return g.playerId end,
	}
	g.compat = nil
	g.enabler = {getClientConfig = function() return g.config end}
	g.mp = {isOwn = function(id) return not g.notOwn[id] end}
	g.police = {isVehicleInPursuit = function(id) return g.pursuing[id] == true, traffic.data[id] ~= nil end}
	g.driving = {
		restoreTrafficAfterTutorialPhase = function() end,
		setTrafficAfterTutorial = function() end,
	}
	return g
end

local current

local function use(g)
	current = g
	be = g.be
	gameplay_traffic, gameplay_parking = g.traffic, g.parking
	gameplay_police = g.police
	gameplay_traffic_trafficUtils = g.utils
	core_multiSpawn = g.multiSpawn
	core_camera = {getPosition = function() return g.camera end}
	MPVehicleGE = g.mp
	MPCoreNetwork = {isMPSession = function() return true end}
	mileageEnabler = g.enabler
	career_modules_playerDriving = g.driving
	career_modules_tutorial = {isActive = function() return g.tutorial end}
	career_modules_inventory = {getInventoryIdFromVehicleId = function(id) return g.inventory[id] end}
	gameplay_missions_missionManager = {getForegroundMissionId = function() return g.missionId end}
	extensions = {mileage_compat = g.compat, mileage_spotRace = {inRace = function() return g.spotRace == true end},
		mileage_aiRace = {racingCar = function()
			if g.aiRaceBroken then error("aiRace broken") end
			return g.aiRaceCar
		end}}
end

local function startClient(g)
	use(g)
	g.compat = dofile(COMPAT)
	use(g)
	g.meter = dofile(SOURCE)
	return g
end

local function setupClients()
	logs, clock = {}, 0
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	os.clockhp = function() return clock end
end

-- A game whose career has started with the given share (road, parked).
local function careerGame(road, parked, opts)
	opts = opts or {}
	local g = startClient(newGame({share = {road = road, parked = parked}, farFrom = opts.farFrom}))
	g.meter.onBeforeCareerActivate()
	gameplay_traffic.setupTrafficHelper(6, {simpleVehs = true, autoLoadFromFile = true}, 8, nil)
	gameplay_traffic.setActiveAmount(6)
	gameplay_parking.setActiveAmount(8)
	g.meter.onTrafficOrParkingReady()
	g.meter.onCareerActive(true)
	g.calls, g.spawns, g.deleted = {}, {}, {}
	return g
end

local function newShare(g, road, parked)
	use(g)
	g.config.trafficShare = {road = road, parked = parked}
	g.meter.onTrafficShare()
end

-- Lets seconds pass on the games in steps of a quarter second.
local function run(seconds, games)
	for _ = 1, math.floor(seconds * 4 + 0.5) do
		clock = clock + 0.25
		for _, g in ipairs(games) do
			use(g)
			g.meter.onUpdate(0.25)
		end
	end
end

-- The share counts: driving traffic (the reserved taxi on top) and parked cars.
local function counts(g)
	local road, taxis = 0, 0
	for _, e in pairs(g.traffic.data) do
		if e.isAi and e.reserved then taxis = taxis + 1
		elseif e.isAi then road = road + 1 end
	end
	return road, #g.parking.list, taxis
end

local function spawned(g, name)
	local n = 0
	for _, s in ipairs(g.spawns) do
		if name == nil or s.name == name then n = n + s.n end
	end
	return n
end

local function exists(g, car) return g.objects[car.id] ~= nil end

local function callIndex(g, kind, arg)
	for i, c in ipairs(g.calls) do
		if c[1] == kind and (arg == nil or c[2] == arg) then return i end
	end
	return nil
end

--== the server ==============================================================
-- The real server source, as tests/traffic_share_test.lua loads it.

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
	local chunk = (loadstring or load)("return " .. tostring(text))
	if not chunk then error("does not decode") end
	return chunk()
end

local server

local function newServer()
	server = {now = 0, sent = {}, players = {}, delivered = 0}
	Util = {JsonEncode = encode, JsonDecode = decode}
	MP = {
		CreateTimer = function() return {GetCurrent = function() return server.now end, Start = function() end} end,
		GetPlayers = function()
			local copy = {}
			for id, name in pairs(server.players) do copy[id] = name end
			return copy
		end,
		IsPlayerConnected = function(id) return server.players[id] ~= nil end,
		GetPlayerName = function(id) return server.players[id] end,
		TriggerClientEvent = function(target, event, data)
			table.insert(server.sent, {target = target, event = event, data = data})
		end,
		DropPlayer = function() end,
	}
	local realPrint = print
	print = function() end
	dofile(SERVER)
	print = realPrint
	Config = {
		server = {roadTrafficTotal = 18, parkedTrafficTotal = 24},
		client = {roadTrafficEnabled = true, roadTrafficAmount = 6, parkedTrafficEnabled = true,
			parkedTrafficAmount = 8, consoleEnabled = false},
	}
	ReadJson = function() return Config end
	WriteJson = function() return true end
end

-- Hands the server's new messages to the games, as the enabler does: the settings
-- carry the joiner's share, a share on its own goes to the traffic meter.
local function deliver(games)
	while server.delivered < #server.sent do
		server.delivered = server.delivered + 1
		local m = server.sent[server.delivered]
		local g = games[m.target]
		if g and m.event == "rxCareerSync" then
			g.config = decode(m.data)
		elseif g and m.event == "rxCareerTrafficShare" then
			local share = decode(m.data)
			newShare(g, share.road, share.parked)
		end
	end
end

--== a smaller share deletes its extra cars ==================================

test("A1: five players joining at defaults leave 42 traffic and parked cars, plus one taxi each", function()
	setupClients()
	newServer()
	local games = {}
	local all = {}
	for id = 0, 4 do
		local g = startClient(newGame())
		games[id] = g
		table.insert(all, g)
		server.players[id] = "player" .. id
		onPlayerJoinHandler(id)
		careerSyncRequested(id, encode({confirmsStart = true}))
		deliver(games)
		-- the joiner's career starts with the share its settings carried
		use(g)
		g.meter.onBeforeCareerActivate()
		gameplay_traffic.setupTrafficHelper(6, {simpleVehs = true, autoLoadFromFile = true}, 8, nil)
		gameplay_traffic.setActiveAmount(6)
		gameplay_parking.setActiveAmount(8)
		g.meter.onTrafficOrParkingReady()
		g.meter.onCareerActive(true)
		for _ = 1, 5 do
			server.now = server.now + 1
			tick()
			deliver(games)
			run(1, all)
		end
	end
	run(10, all)
	local cars, taxis = 0, 0
	for id = 0, 4 do
		local road, parked, taxi = counts(games[id])
		local share = games[id].config.trafficShare
		same(road, share.road, "driving cars of player " .. id)
		same(parked, share.parked, "parked cars of player " .. id)
		cars, taxis = cars + road + parked, taxis + taxi
	end
	same(cars, 42, "traffic and parked cars across the five games")
	same(taxis, 5, "reserved taxis")
	same(countLines(logs, "E mileage"), 0, "errors logged")
end)

test("A2: a drop of 3 with 2 hidden and 4 visible cars deletes the hidden ones, then the farthest out of view", function()
	setupClients()
	local g = careerGame(6, 8)
	local road = {}
	for id, e in pairs(g.traffic.data) do
		if not e.reserved then table.insert(road, g.objects[id]) end
	end
	table.sort(road, function(a, b) return a.id < b.id end)
	-- hidden: road[2] and road[5]; visible at 200, 400, 300 and 100 m
	road[2].active, road[5].active = false, false
	road[2].pos, road[5].pos = {x = 50, y = 0, z = 0}, {x = 60, y = 0, z = 0}
	road[1].pos, road[3].pos = {x = 200, y = 0, z = 0}, {x = 0, y = 400, z = 0}
	road[4].pos, road[6].pos = {x = 300, y = 0, z = 0}, {x = 100, y = 0, z = 0}
	newShare(g, 3, 8)
	expect(not exists(g, road[2]) and not exists(g, road[5]), "the hidden cars are deleted")
	expect(not exists(g, road[3]), "the farthest visible car (400 m) is deleted")
	expect(exists(g, road[1]) and exists(g, road[4]) and exists(g, road[6]), "the nearer visible cars stay")
	same(select(1, counts(g)), 3, "driving cars")
	same(select(3, counts(g)), 1, "the reserved taxi stays")
	expect(callIndex(g, "removeTraffic", road[2].id) ~= nil, "taken out of the game's traffic before the delete")
	expect(callIndex(g, "removeTraffic", road[3].id) < callIndex(g, "trafficActive", 3),
		"deleted before the active amount is set, so the game hides nothing extra first")
	same(g.traffic.active, 3, "the active amount still follows the share")
	same(spawned(g), 0, "cars spawned")
end)

test("A2: a smaller parked share deletes parked cars through the parking list, never from its front", function()
	setupClients()
	local g = careerGame(6, 8)
	local list = {}
	for i, id in ipairs(g.parking.list) do list[i] = g.objects[id] end
	for i, car in ipairs(list) do car.pos = {x = 160 + 10 * i, y = 0, z = 0} end
	list[8].pos = {x = 20, y = 0, z = 0}
	newShare(g, 6, 5)
	same(select(2, counts(g)), 5, "parked cars")
	expect(exists(g, list[1]) and exists(g, list[2]), "the front of the list stays")
	expect(not exists(g, list[7]) and not exists(g, list[6]) and not exists(g, list[5]), "the three farthest go")
	expect(exists(g, list[8]), "the car near the camera stays")
	expect(callIndex(g, "removeVehicle", list[7].id) ~= nil, "taken out of the parking list")
	same(g.parking.active, 5, "the parked active amount")
end)

test("A3: cars in use are never deleted; the next eligible car goes once there is one", function()
	setupClients()
	local g = careerGame(0, 0)
	local inCar = g.addTraffic()
	g.playerId = inCar.id
	local racer = g.addTraffic({mileageSpotRacer = "true"})
	local taxi = g.addTraffic(nil, {reserved = "taxi"})
	local police = g.addTraffic(nil, {roleName = "police"})
	g.pursuing[police.id] = true
	local near = g.addTraffic()
	near.pos = {x = 80, y = 0, z = 0}
	local bought = g.addTraffic()
	g.inventory[bought.id] = 7
	-- four cars count for the share (the reserved taxi and the bought car do not): 2 above
	newShare(g, 2, 0)
	run(3, {g})
	same(#g.deleted, 0, "cars deleted while every car above the share is in use or in view")
	same(countLines(logs, "in use or in view"), 1, "the wait is logged once")
	near.pos = {x = 0, y = 600, z = 0}
	run(1, {g})
	expect(not exists(g, near), "the car that left the view is deleted")
	same(#g.deleted, 1, "cars deleted")
	g.pursuing[police.id] = nil
	run(1, {g})
	expect(not exists(g, police), "the police car is deleted once its pursuit is over")
	run(5, {g})
	expect(exists(g, inCar) and exists(g, racer) and exists(g, taxi) and exists(g, bought),
		"the player's car, the race spot opponent, the reserved taxi and the player's own bought car stay")
	same(#g.deleted, 2, "cars deleted in all")
	same(countLines(logs, "E mileage"), 0, "errors logged")
end)

test("A3: another player's car in this game's traffic is never deleted", function()
	setupClients()
	local g = careerGame(3, 0)
	local other = g.addTraffic()
	g.notOwn[other.id] = true
	other.active = false
	newShare(g, 2, 0)
	expect(exists(g, other), "another player's hidden car stays")
	same(select(1, counts(g)), 2, "driving cars: two own cars deleted, the other player's kept")
end)

test("an error while deleting logs once and falls back to hiding the cars", function()
	setupClients()
	local g = careerGame(6, 8)
	g.traffic.removeTraffic = function() error("broken traffic") end
	newShare(g, 4, 8)
	same(g.traffic.active, 4, "the active amount still hides the cars above the share")
	same(countLines(logs, "E mileage.traffic: traffic share"), 1, "error logged")
	newShare(g, 2, 3)
	run(3, {g})
	same(g.traffic.active, 2, "a later share still sets the active amount")
	same(g.parking.active, 3, "and the parked one")
	same(#g.deleted, 0, "cars deleted after the error")
	same(countLines(logs, "E mileage.traffic: traffic share"), 1, "still one error")
	use(g)
	g.meter.onBeamMPServerLeave()
end)

--== a share that grows adds cars while playing ==============================

test("A4: a share growing from 3+4 to 6+8 adds the 7 cars within 6 s, never more than 3 a second", function()
	setupClients()
	local g = careerGame(3, 4)
	same(select(1, counts(g)), 3, "driving cars at the start")
	same(select(2, counts(g)), 4, "parked cars at the start")
	newShare(g, 6, 8)
	run(6, {g})
	local road, parked, taxis = counts(g)
	same(road, 6, "driving cars after 6 s")
	same(parked, 8, "parked cars after 6 s")
	same(taxis, 1, "still one reserved taxi")
	same(spawned(g), 7, "cars spawned")
	for _, s in ipairs(g.spawns) do
		local inSecond = 0
		for _, t in ipairs(g.spawns) do
			if t.at >= s.at and t.at < s.at + 1 then inSecond = inSecond + t.n end
		end
		expect(inSecond <= 3, string.format("%d cars spawned in the second from %.2f s", inSecond, s.at))
	end
	for _, s in ipairs(g.spawns) do
		if s.name == "autoTraffic" then same(s.mode, "traffic", "driving cars spawn the way the game's traffic does") end
	end
	same(spawned(g, "autoParking"), 4, "parked cars spawned as the game's parking group")
	same(g.calls[callIndex(g, "createGroup")][3], 1, "parked cars from the game's parked car types")
	same(g.traffic.active, 6, "active driving amount")
	same(g.parking.active, 8, "active parked amount")
	same(countLines(logs, "E mileage"), 0, "errors logged")
end)

test("A4: police come back with a grown driving share as the career start would have them", function()
	setupClients()
	local g = careerGame(2, 0)
	newShare(g, 6, 0)
	run(3, {g})
	local police = 0
	for _, e in pairs(g.traffic.data) do
		if e.roleName == "police" then police = police + 1 end
	end
	same(police, 2, "police cars for a driving share of 6")
	same(select(1, counts(g)), 6, "driving cars")
end)

test("A3: the car an AI race has this game race is never deleted, even 400 m away", function()
	setupClients()
	local g = careerGame(4, 0)
	local road = {}
	for id, e in pairs(g.traffic.data) do
		if not e.reserved then table.insert(road, g.objects[id]) end
	end
	table.sort(road, function(a, b) return a.id < b.id end)
	for i, car in ipairs(road) do car.pos = {x = 200 + 10 * i, y = 0, z = 0} end
	local opponent = road[2]
	opponent.pos = {x = 0, y = 400, z = 0}
	g.aiRaceCar = opponent.id
	newShare(g, 2, 0)
	expect(exists(g, opponent), "the race opponent stays")
	same(select(1, counts(g)), 2, "driving cars: the two farthest others went instead")
	expect(not exists(g, road[4]) and not exists(g, road[3]), "the next farthest cars are deleted")
	g.aiRaceCar = nil
	newShare(g, 1, 0)
	expect(not exists(g, opponent), "once the race is over the car can go")
end)

test("A3: when the AI race cannot say which car it races, no car is deleted that second", function()
	setupClients()
	local g = careerGame(4, 0)
	g.aiRaceBroken = true
	newShare(g, 2, 0)
	run(2, {g})
	same(#g.deleted, 0, "cars deleted while the race cannot tell")
	g.aiRaceBroken = false
	run(1, {g})
	same(select(1, counts(g)), 2, "driving cars once it can")
	same(countLines(logs, "E mileage"), 0, "errors logged")
end)

test("A4: a second grow while the first's cars are still spawning adds only what is still missing", function()
	setupClients()
	local g = careerGame(2, 3)
	g.deferSpawns = true
	newShare(g, 4, 5)
	same(spawned(g), 3, "cars asked for at once by the first grow (2 driving, 1 parked)")
	run(0.5, {g})
	newShare(g, 5, 6)
	same(spawned(g), 3, "cars asked for half a second later, when the second grow arrives")
	g.buildQueued()
	g.deferSpawns = false
	run(12, {g})
	same(spawned(g), 6, "cars asked for in all")
	same(#g.deleted, 0, "cars deleted")
	local road, parked = counts(g)
	same(road, 5, "driving cars")
	same(parked, 6, "parked cars")
end)

test("A4: a group the spawner never builds stops counting after 10 s, so its cars are asked for again", function()
	setupClients()
	local g = careerGame(2, 0)
	g.deferSpawns = true
	newShare(g, 4, 0)
	g.queued = {}
	run(11, {g})
	g.deferSpawns = false
	newShare(g, 4, 0)
	same(select(1, counts(g)), 4, "driving cars")
end)

test("A4: added parked cars land in free spots more than 150 m from the camera", function()
	setupClients()
	local g = careerGame(3, 4)
	g.spots = {{x = 50, y = 0, z = 0}, {x = 0, y = 120, z = 0}, {x = 200, y = 0, z = 0}, {x = 0, y = 260, z = 0},
		{x = 900, y = 0, z = 0}}
	local before = {}
	for _, id in ipairs(g.parking.list) do before[id] = true end
	newShare(g, 3, 7)
	run(2, {g})
	same(select(2, counts(g)), 7, "parked cars")
	for _, id in ipairs(g.parking.list) do
		if not before[id] then
			local p = g.objects[id].pos
			expect(math.sqrt(p.x * p.x + p.y * p.y) > 150, string.format("added parked car %d is %.0f m away", id,
				math.sqrt(p.x * p.x + p.y * p.y)))
		end
	end
	local find = g.calls[callIndex(g, "findSpots")]
	same(find[2], 150, "spots asked for beyond 150 m")
	same(find[4], true, "only spots no car stands in")
end)

test("A4: with no free spot beyond 150 m nothing is added that second, and the car comes once one is free", function()
	setupClients()
	local g = careerGame(3, 4)
	g.spots = {{x = 50, y = 0, z = 0}, {x = 0, y = 120, z = 0}}
	newShare(g, 3, 6)
	run(2, {g})
	same(spawned(g), 0, "parked cars added while only near spots are free")
	table.insert(g.spots, {x = 0, y = 500, z = 0})
	run(1, {g})
	same(spawned(g), 1, "parked cars added once a far spot is free")
	same(select(2, counts(g)), 5, "parked cars")
	same(countLines(logs, "E mileage"), 0, "errors logged")
end)

test("A4: no free parking spots stops the parked additions without an error", function()
	setupClients()
	local g = careerGame(3, 2)
	g.noParkingSpots = true
	newShare(g, 3, 6)
	run(40, {g})
	same(select(2, counts(g)), 2, "parked cars")
	same(countLines(logs, "E mileage"), 0, "errors logged")
	same(countLines(logs, "no free parking spots out of view for 4 more parked cars"), 1, "given up once, after 30 s")
	local tries = 0
	for _, c in ipairs(g.calls) do if c[1] == "findSpots" then tries = tries + 1 end end
	expect(tries >= 25 and tries <= 32, "spots looked for once a second until then: " .. tries)
end)

test("A5: a share change during a mission hide deletes and spawns nothing until the mission ends", function()
	setupClients()
	local g = careerGame(6, 8)
	g.missionId = "delivery"
	use(g)
	local trafficData = gameplay_traffic.freezeState({despawnVehicles = true, exceptVehicleId = g.playerId})
	local hidden = 0
	for _, car in pairs(g.objects) do if not car.active then hidden = hidden + 1 end end
	expect(hidden > 0, "the mission hid the cars")
	newShare(g, 8, 10)
	run(2, {g})
	newShare(g, 4, 6)
	run(5, {g})
	same(#g.deleted, 0, "cars deleted during the mission")
	same(spawned(g), 0, "cars spawned during the mission")
	same(callIndex(g, "trafficActive"), nil, "active amounts set during the mission")
	same(countLines(logs, "traffic share changed"), 0, "shares applied during the mission")
	g.missionId = nil
	gameplay_traffic.unfreezeState(trafficData, nil, nil, {respawnVehicles = true})
	run(3, {g})
	local road, parked = counts(g)
	same(road, 4, "driving cars after the mission")
	same(parked, 6, "parked cars after the mission")
	same(spawned(g), 0, "cars spawned after the mission")
	same(countLines(logs, "traffic share changed"), 1, "the latest share applied once")
end)

test("A5: a share change during the tutorial's hide waits until the tutorial ends", function()
	setupClients()
	local g = careerGame(6, 8)
	g.tutorial = true
	newShare(g, 3, 4)
	run(3, {g})
	same(#g.deleted, 0, "cars deleted during the tutorial")
	same(callIndex(g, "trafficActive"), nil, "active amounts set during the tutorial")
	g.tutorial = false
	run(2, {g})
	same(select(1, counts(g)), 3, "driving cars after the tutorial")
	same(select(2, counts(g)), 4, "parked cars after the tutorial")
end)

test("A5: a share change during a race spot's race waits until the race is over", function()
	setupClients()
	local g = careerGame(6, 8)
	g.spotRace = true
	newShare(g, 3, 4)
	run(3, {g})
	same(#g.deleted, 0, "cars deleted during the race")
	same(callIndex(g, "trafficActive"), nil, "active amounts set during the race")
	g.spotRace = false
	run(2, {g})
	same(select(1, counts(g)), 3, "driving cars after the race")
	same(select(2, counts(g)), 4, "parked cars after the race")
end)

test("a grow followed 1 s later by a shrink ends at the shrunk share with no extra cars", function()
	setupClients()
	local g = careerGame(3, 4)
	newShare(g, 6, 8)
	run(1, {g})
	local before = spawned(g)
	expect(before > 0 and before < 7, "some cars were added before the shrink: " .. before)
	newShare(g, 4, 4)
	run(8, {g})
	same(spawned(g), before, "cars spawned after the shrink")
	local road, parked = counts(g)
	same(road, 4, "driving cars")
	same(parked, 4, "parked cars")
end)

test("leaving the server stops a share being matched", function()
	setupClients()
	local g = careerGame(3, 4)
	newShare(g, 6, 8)
	use(g)
	g.meter.onBeamMPServerLeave()
	local before = spawned(g)
	run(5, {g})
	same(spawned(g), before, "cars spawned after leaving")
end)
