--Mileage :: career traffic meter
--
-- The game's own career module (career/modules/playerDriving.lua) spawns career
-- traffic. It takes its road and parked amounts from the player's own settings and
-- hands them over in one place:
--
--   gameplay_traffic.setupTrafficHelper(trafficAmount, trafficOptions, parkingAmount, nil)
--   gameplay_traffic.setActiveAmount(trafficAmount)
--   gameplay_parking.setActiveAmount(parkingAmount)
--
-- On a server every player's traffic is shared with everyone, so the server decides
-- the amounts: this player's share of the server's traffic total, which shrinks as the
-- server fills (see "share changes"). For one career start this extension replaces those three functions so
-- the server's amounts go through instead, and each puts the game's function back after
-- its one call. Everything else (police, pursuits, fines, parking, tutorial handling)
-- stays the game's own code for whatever version the player runs.
--
-- If the career ever stops handing its amounts over this way, traffic still spawns at
-- the player's own setting and the log says the server's amounts were not applied.
--
-- For the whole server session it also hides the player's traffic around a mission
-- instead of letting the game delete and respawn it (see "mission hide"), and during a
-- career it deletes or adds cars when the server's share changes (see "matching the
-- share").

local M = {}

local logTag = "mileage.traffic"

local MAX_AMOUNT = 50          -- the game's own upper limit for career traffic
local METER_MAX_SECONDS = 60   -- matches the join's limit from settings request to career start

-- Game functions replaced for the current career start, by "<module>.<function>":
-- {module = <table>, name = <function name>, original = <function>}.
local replaced = {}

-- The current career start, from onBeforeCareerActivate until traffic is ready:
-- {armedAt, applied = {road, parked} once the setup went through the meter}.
local start = nil

-- The tutorial restore replacement, kept for the whole server session.
local tutorial = nil

-- Settings already warned about in this join, so a bad value is reported once.
local warned = {}

-- The traffic options the career start handed the game (police asked for), for the cars
-- a share that grows adds later.
local careerOptions = nil

--== replacing game functions ================================================

local function replace(module, moduleName, fnName, makeReplacement)
	if type(module) ~= "table" or type(module[fnName]) ~= "function" then return false end
	local key = moduleName .. "." .. fnName
	if replaced[key] then return true end
	local original = module[fnName]
	replaced[key] = {module = module, name = fnName, original = original}
	module[fnName] = makeReplacement(original, key)
	return true
end

local function restore(key)
	local entry = replaced[key]
	if not entry then return end
	entry.module[entry.name] = entry.original
	replaced[key] = nil
end

local function restoreAll(why)
	if not next(replaced) then return end
	for key in pairs(replaced) do restore(key) end
	log("D", logTag, "game traffic functions restored (" .. why .. ")")
end

--== server amounts ==========================================================

local function warnOnce(setting, value, used)
	if warned[setting] then return end
	warned[setting] = true
	log("W", logTag, string.format("%s = %s is out of range, using %d", setting, tostring(value), used))
end

local function amountFor(config, enabledKey, amountKey)
	if config[enabledKey] ~= true then return 0 end
	local raw = config[amountKey]
	local amount = tonumber(raw)
	if amount == nil or amount ~= amount then
		warnOnce(amountKey, raw, 0)
		return 0
	end
	local used = math.floor(math.max(0, math.min(MAX_AMOUNT, amount)))
	if used ~= amount then warnOnce(amountKey, raw, used) end
	return used
end

-- This player's share of the server's traffic total, when the server sent one.
local function shareFor(config, enabledKey, kind)
	if config[enabledKey] ~= true then return 0 end
	local raw = config.trafficShare[kind]
	local amount = tonumber(raw)
	if amount == nil or amount ~= amount then
		warnOnce("trafficShare." .. kind, raw, 0)
		return 0
	end
	local used = math.floor(math.max(0, math.min(MAX_AMOUNT, amount)))
	if used ~= amount then warnOnce("trafficShare." .. kind, raw, used) end
	return used
end

--- The road and parked amounts this player spawns: 0 for a switched-off kind, otherwise
--- the player's share of the server's traffic total (config.trafficShare) when the server
--- sent one, else the per-player amount, held to whole numbers from 0 to 50.
function M.serverAmounts(config)
	if type(config) ~= "table" then return 0, 0 end
	if type(config.trafficShare) == "table" then
		return shareFor(config, "roadTrafficEnabled", "road"), shareFor(config, "parkedTrafficEnabled", "parked")
	end
	return amountFor(config, "roadTrafficEnabled", "roadTrafficAmount"),
		amountFor(config, "parkedTrafficEnabled", "parkedTrafficAmount")
end

-- The server's client config while on a server, otherwise nil.
local function serverConfig()
	local compat = extensions.mileage_compat
	if type(compat) ~= "table" or not compat.isMPSession() then return nil end
	local enabler = mileageEnabler
	if type(enabler) ~= "table" or type(enabler.getClientConfig) ~= "function" then return nil end
	local config = enabler.getClientConfig()
	if type(config) ~= "table" then return nil end
	return config
end

local function onOff(enabled)
	return enabled == true and "on" or "off"
end

local function pack(...)
	return {n = select("#", ...), ...}
end

--== the career start ========================================================

-- The next call of <module>.setActiveAmount passes the server's amount instead of its
-- own, then the game's function is back.
local function setActiveAmountOnce(module, moduleName, amount)
	replace(module, moduleName, "setActiveAmount", function(original, key)
		return function(_, ...)
			restore(key)
			return original(amount, ...)
		end
	end)
end

-- Works out what to hand the game: the server's amounts and a copy of the options that
-- asks for police when there is road traffic. Arms the two active-amount calls.
local function prepareSetup(config, trafficOptions)
	local road, parked = M.serverAmounts(config)
	log("I", logTag, string.format("applying server traffic - road %d (%s), parked %d (%s)",
		road, onOff(config.roadTrafficEnabled), parked, onOff(config.parkedTrafficEnabled)))

	local options = {}
	if type(trafficOptions) == "table" then
		for k, v in pairs(trafficOptions) do options[k] = v end
	end
	-- The game's police provider adds police only when asked: about a quarter of the
	-- road cars, once there are at least 3.
	if road > 0 then options.police = true end

	setActiveAmountOnce(gameplay_traffic, "gameplay_traffic", road)
	setActiveAmountOnce(gameplay_parking, "gameplay_parking", parked)
	if start then start.applied = {road = road, parked = parked} end
	careerOptions = options
	return road, options, parked
end

local function meterSetupTrafficHelper(config)
	return replace(gameplay_traffic, "gameplay_traffic", "setupTrafficHelper", function(original, key)
		return function(trafficAmount, trafficOptions, parkingAmount, parkingOptions, ...)
			-- One call only: the next setup (free roam, a mission) keeps its own amounts.
			restore(key)
			local prepared = pack(xpcall(prepareSetup, debug.traceback, config, trafficOptions))
			if not prepared[1] then
				log("E", logTag, "server traffic amounts not applied: " .. tostring(prepared[2]))
				return original(trafficAmount, trafficOptions, parkingAmount, parkingOptions, ...)
			end
			return original(prepared[2], prepared[3], prepared[4], parkingOptions, ...)
		end
	end)
end

local function arm()
	if start then return end
	local config = serverConfig()
	if not config then return end
	-- Anything left from an earlier start is put back before arming again.
	restoreAll("new career start")
	if not meterSetupTrafficHelper(config) then
		log("W", logTag, "gameplay_traffic.setupTrafficHelper missing - server traffic amounts not applied")
		return
	end
	start = {armedAt = os.clockhp(), applied = nil}
	log("D", logTag, "armed for the career start")
end

local function warnNotApplied()
	log("W", logTag, "the career set up traffic without Mileage - server traffic amounts not applied")
end

--== tutorial restore ========================================================
-- At the end of a tutorial phase the game puts traffic back from the player's own
-- settings and switches road traffic on even when none was spawned, which turns every
-- untagged vehicle into traffic. On a server the restore uses the server's amounts and
-- leaves road traffic off when the server has it off.

local function serverRestoreTrafficAfterTutorialPhase(module)
	local ok, err = xpcall(function()
		local road, parked = M.serverAmounts(serverConfig() or {})
		if road > 0 and gameplay_traffic.getState() == "off" then
			gameplay_traffic.toggle(true)
		end
		gameplay_traffic.setActiveAmount(road)
		gameplay_parking.setActiveAmount(parked)
		module.setTrafficAfterTutorial()
	end, debug.traceback)
	if not ok then log("E", logTag, "tutorial traffic restore failed: " .. tostring(err)) end
end

-- The game loads its career modules afresh on a career start, so this is checked on
-- each one and installed on the module table that is current.
local function installTutorialRestore()
	local module = career_modules_playerDriving
	if tutorial and tutorial.module == module then return end
	-- A missing function is reported once, by name, through compat like every other
	-- game function Mileage relies on.
	local compat = extensions.mileage_compat
	local consequence = "the tutorial traffic restore keeps the player's own amounts"
	local restoreFn = compat.pickOrWarn(module, "career_modules_playerDriving", "restoreTrafficAfterTutorialPhase", consequence)
	local afterFn = compat.pickOrWarn(module, "career_modules_playerDriving", "setTrafficAfterTutorial", consequence)
	if not restoreFn or not afterFn then return end
	tutorial = {module = module, original = module.restoreTrafficAfterTutorialPhase}
	module.restoreTrafficAfterTutorialPhase = function()
		serverRestoreTrafficAfterTutorialPhase(module)
	end
end

local function removeTutorialRestore()
	if not tutorial then return end
	tutorial.module.restoreTrafficAfterTutorialPhase = tutorial.original
	tutorial = nil
end

--== mission hide ============================================================
-- On a mission start the game's mission manager stashes traffic with
--
--   gameplay_traffic.freezeState({despawnVehicles = true, exceptVehicleId = <player's car>})
--
-- which deletes every traffic, police and parked car except the one the player drives,
-- and spawns them all again at the end with unfreezeState(..., {respawnVehicles = true}).
-- On a server each of those is a new vehicle on every other player's game, announced
-- and queued by BeamMP and then built at once, which stalls their game. On a server the
-- cars are hidden for the mission instead, which Mileage's hide/show sync carries to
-- everyone, and shown again at the end. Any other freeze is left to the game.

local unpack = table.unpack or unpack

-- {module, freeze, unfreeze} while the replacement is installed on that module table.
local mission = nil

-- Cars hidden by a mission start and not yet shown again.
local hiddenForMission = nil

local passThroughLogged = false

local function copyWith(options, key, value)
	local copy = {}
	if type(options) == "table" then
		for k, v in pairs(options) do copy[k] = v end
	end
	copy[key] = value
	return copy
end

local function callOr(module, fnName, fallback)
	if type(module) ~= "table" or type(module[fnName]) ~= "function" then return fallback end
	local ok, value = pcall(module[fnName])
	if ok and type(value) == "table" then return value end
	return fallback
end

-- The cars the game's freeze would delete (AI or isTraffic road traffic and parked
-- cars, except exceptId) that are showing now. Pooled cars are already hidden and the
-- game's traffic pool puts them back itself.
local function missionCars(exceptId)
	local ids, seen = {}, {}
	local function add(id)
		if id == exceptId or seen[id] then return end
		local obj = be:getObjectByID(id)
		if obj and obj:getActive() then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	local trafficIds = {}
	for id, entry in pairs(callOr(gameplay_traffic, "getTrafficData", {})) do
		if type(entry) == "table" then
			local obj = be:getObjectByID(id)
			if entry.isAi == true or (obj and obj.isTraffic == "true") then table.insert(trafficIds, id) end
		end
	end
	table.sort(trafficIds)
	for _, id in ipairs(trafficIds) do add(id) end
	for _, id in ipairs(callOr(gameplay_parking, "getParkedCarsList", {})) do add(id) end
	return ids
end

local function makeMissionFreeze(original)
	return function(options, ...)
		if type(options) ~= "table" or options.despawnVehicles ~= true then
			if not passThroughLogged then
				passThroughLogged = true
				log("I", logTag, "the game froze traffic without asking to delete it - left to the game")
			end
			return original(options, ...)
		end
		local found, ids = xpcall(missionCars, debug.traceback, options.exceptVehicleId)
		if not found then
			log("E", logTag, "mission hide failed, traffic left to the game: " .. tostring(ids))
			return original(options, ...)
		end
		local results = pack(original(copyWith(options, "despawnVehicles", false), ...))
		hiddenForMission = hiddenForMission or {}
		local hidden = 0
		for _, id in ipairs(ids) do
			local obj = be:getObjectByID(id)
			if obj then
				obj:setActive(0)
				table.insert(hiddenForMission, id)
				hidden = hidden + 1
			end
		end
		log("I", logTag, string.format("mission start: %d traffic and parked cars hidden instead of deleted", hidden))
		return unpack(results, 1, results.n)
	end
end

-- Shows the cars a mission start hid that still exist; returns how many.
local function showMissionCars()
	local ids = hiddenForMission
	hiddenForMission = nil
	if not ids then return nil, 0 end
	local shown = 0
	for _, id in ipairs(ids) do
		local obj = be:getObjectByID(id)
		if obj then
			obj:setActive(1)
			shown = shown + 1
		end
	end
	return shown, #ids
end

local function makeMissionUnfreeze(original)
	return function(trafficData, policeData, parkingData, options, ...)
		local shown, total = showMissionCars()
		if not shown then return original(trafficData, policeData, parkingData, options, ...) end
		log("I", logTag, string.format("mission end: %d of %d hidden traffic and parked cars shown again", shown, total))
		return original(trafficData, policeData, parkingData, copyWith(options, "respawnVehicles", false), ...)
	end
end

-- Installed on the game's traffic module that is current at each career start.
local function installMissionHide()
	local module = gameplay_traffic
	if mission and mission.module == module then return end
	local compat = extensions.mileage_compat
	local consequence = "a mission start deletes and respawns traffic for every player"
	local freezeFn = compat.pickOrWarn(module, "gameplay_traffic", "freezeState", consequence)
	local unfreezeFn = compat.pickOrWarn(module, "gameplay_traffic", "unfreezeState", consequence)
	if not freezeFn or not unfreezeFn then return end
	mission = {module = module, freeze = freezeFn, unfreeze = unfreezeFn}
	module.freezeState = makeMissionFreeze(freezeFn)
	module.unfreezeState = makeMissionUnfreeze(unfreezeFn)
end

-- Cars still hidden for a mission are shown again: the game's own unfreeze has no
-- copies to spawn them from.
local function removeMissionHide()
	local shown, total = showMissionCars()
	if shown then
		log("I", logTag, string.format("mission hide removed: %d of %d hidden cars shown again", shown, total))
	end
	passThroughLogged = false
	if not mission then return end
	mission.module.freezeState = mission.freeze
	mission.module.unfreezeState = mission.unfreeze
	mission = nil
end

--== matching the share =====================================================
-- A share that shrinks deletes this player's cars above it, and BeamMP then deletes them
-- on every game: a hidden car is still built and kept by everyone. Hidden cars go first,
-- then visible cars farthest from the camera that are more than 150 m away. The car the
-- player is in, a race spot's opponent, a reserved or working taxi, a car in a police
-- pursuit and the player's own career cars are never deleted; cars above the share that
-- cannot go yet are tried again every second. A share that grows spawns the missing cars
-- through the game's own traffic and parking spawns, at most 3 a second, and a later
-- share replaces what is still to add. Any error stops this until the next join and a
-- share then only hides cars, as before.

local KEEP_CLEAR_METRES = 150
local ADD_PER_STEP = 3
local STEP_SECONDS = 1
-- Cars added this long ago may still arrive above a share that shrank since; a group
-- asked for and not built by then is taken as lost.
local LATE_SECONDS = 10
-- Seconds a parked car still to add waits for a free spot out of view before it is left.
local PARKED_WAIT_SECONDS = 30

local RESIZE_CONSEQUENCE = "a smaller traffic share only hides cars and a larger one adds none"
local ADD_CONSEQUENCE = "a larger traffic share adds no cars"

-- While the cars do not match the share yet: {road, parked, add = {road, parked},
-- addPolice, startedAt, nextAt, lastAddAt, waitLogged}.
local resize = nil
local resizeOff = false

-- Groups this game asked the game's spawner for and that are not built yet, oldest
-- first: {n, police, at}. They count as there, so a share that grows again while they
-- spawn adds only what is still missing.
local inFlight = {road = {}, parked = {}}

-- No cars are added before this, so a new share arriving just after a batch still keeps
-- to 3 a second.
local addAllowedAt = 0

local function inFlightCount(kind, now)
	local list = inFlight[kind]
	while list[1] and now - list[1].at >= LATE_SECONDS do table.remove(list, 1) end
	local n, police = 0, 0
	for _, group in ipairs(list) do n, police = n + group.n, police + group.police end
	return n, police
end

-- A mission or the tutorial has traffic hidden, or a race spot has it thinned and holds
-- police out of the pool: a share waits until that ends.
local function trafficHeld()
	if hiddenForMission then return true end
	local compat, spotRace = extensions.mileage_compat, extensions.mileage_spotRace
	local ok, held = pcall(function()
		if type(spotRace) == "table" and type(spotRace.inRace) == "function" and spotRace.inRace() then return true end
		return compat.getForegroundMissionId() ~= nil or compat.isTutorialActive() == true
	end)
	return ok and held == true
end

-- The game functions deleting needs (a missing one is reported once and its kind left
-- to the active amounts), or nil before the game is up.
local function resizeFns()
	if be == nil then return nil end
	local compat = extensions.mileage_compat
	return {
		trafficData = compat.pickOrWarn(gameplay_traffic, "gameplay_traffic", "getTrafficData", RESIZE_CONSEQUENCE),
		removeTraffic = compat.pickOrWarn(gameplay_traffic, "gameplay_traffic", "removeTraffic", RESIZE_CONSEQUENCE),
		parkedList = compat.pickOrWarn(gameplay_parking, "gameplay_parking", "getParkedCarsList", RESIZE_CONSEQUENCE),
		removeParked = compat.pickOrWarn(gameplay_parking, "gameplay_parking", "removeVehicle", RESIZE_CONSEQUENCE),
	}
end

-- A car the player owns in the career (bought, or left out in the world).
local function inventoryCar(id)
	local inventory = career_modules_inventory
	if type(inventory) ~= "table" or type(inventory.getInventoryIdFromVehicleId) ~= "function" then return false end
	local ok, inventoryId = pcall(inventory.getInventoryIdFromVehicleId, id)
	return not ok or inventoryId ~= nil
end

-- This game's cars the share counts, as {id, entry}, or nil when the game cannot tell.
-- The reserved taxi comes on top of the share.
local function carsOf(kind, fns)
	local cars = {}
	if kind == "road" then
		if not fns.trafficData or not fns.removeTraffic then return nil end
		local data = fns.trafficData()
		for id, entry in pairs(type(data) == "table" and data or {}) do
			if type(entry) == "table" and entry.isAi == true and not entry.reserved and not inventoryCar(id) then
				table.insert(cars, {id = id, entry = entry})
			end
		end
	else
		if not fns.parkedList or not fns.removeParked then return nil end
		local list = fns.parkedList()
		for _, id in ipairs(type(list) == "table" and list or {}) do
			if not inventoryCar(id) then table.insert(cars, {id = id}) end
		end
	end
	return cars
end

local function roleOf(entry)
	if type(entry) ~= "table" then return nil end
	return entry.roleName or (type(entry.role) == "table" and entry.role.name) or nil
end

local function policeCount(cars)
	local n = 0
	for _, car in ipairs(cars) do
		if roleOf(car.entry) == "police" then n = n + 1 end
	end
	return n
end

-- The police the game's police provider puts in this many road cars at a career start.
local function policeFor(road)
	local options = careerOptions or {police = road > 0}
	if not options.police or road < 3 then return 0 end
	return math.min(math.ceil(road * 0.25), math.floor(road * 0.4))
end

-- The own traffic car an AI race (mileage/aiRace.lua) has this game race, or nil; false
-- when it cannot tell, and then no car is taken that step.
local function aiRaceCar()
	local aiRace = extensions.mileage_aiRace
	if type(aiRace) ~= "table" or type(aiRace.racingCar) ~= "function" then return nil end
	local ok, id = pcall(aiRace.racingCar)
	if not ok then return false end
	return id
end

-- keep: {player = the player's car, racing = aiRaceCar()}.
local function inUse(car, obj, keep)
	if car.id == keep.player or keep.racing == false or car.id == keep.racing then return true end
	local mp = MPVehicleGE
	if type(mp) == "table" and type(mp.isOwn) == "function" and not mp.isOwn(car.id) then return true end
	if obj.mileageSpotRacer == "true" then return true end
	local entry = car.entry
	if entry and (entry.reserved or entry.claimed) then return true end
	local police = gameplay_police
	if entry and type(police) == "table" and type(police.isVehicleInPursuit) == "function" then
		local ok, pursuing = pcall(police.isVehicleInPursuit, car.id)
		if not ok or pursuing then return true end
	end
	return false
end

-- Where the player looks from: the camera, else the player's car.
local function viewPoint()
	local camera = core_camera
	if type(camera) == "table" and type(camera.getPosition) == "function" then
		local ok, pos = pcall(camera.getPosition)
		if ok and pos then return pos end
	end
	local veh = be:getObjectByID(be:getPlayerVehicleID(0) or -1)
	return veh and veh:getPosition() or nil
end

local function metres(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Up to `over` cars to delete: hidden ones first, then visible ones out of view,
-- farthest first.
local function pickCars(cars, over, from, keep)
	local hidden, far = {}, {}
	for _, car in ipairs(cars) do
		local obj = be:getObjectByID(car.id)
		if obj and not inUse(car, obj, keep) then
			local pos = obj:getPosition()
			car.metres = (from and pos) and metres(from, pos) or nil
			if not obj:getActive() then
				table.insert(hidden, car)
			elseif car.metres and car.metres > KEEP_CLEAR_METRES then
				table.insert(far, car)
			end
		end
	end
	local function farthest(a, b)
		if (a.metres or 0) ~= (b.metres or 0) then return (a.metres or 0) > (b.metres or 0) end
		return a.id < b.id
	end
	table.sort(hidden, farthest)
	table.sort(far, farthest)
	local picked = {}
	for _, list in ipairs({hidden, far}) do
		for _, car in ipairs(list) do
			if #picked >= over then return picked end
			table.insert(picked, car)
		end
	end
	return picked
end

-- Taken out of the game's traffic or parking first, never with parking's
-- deleteVehicles, which takes the cars at the front of its list.
local function deleteCar(kind, id, fns)
	local obj = be:getObjectByID(id)
	if kind == "road" then fns.removeTraffic(id) else fns.removeParked(id) end
	if obj then obj:delete() end
end

-- Spawns n road cars, police first, under the game's own traffic group name so its
-- traffic system takes them in as at the career start. Not spawnTraffic: that restarts
-- the traffic system, which resets the player's pursuit and career traffic state.
local function addRoad(n, police, now)
	local compat = extensions.mileage_compat
	if not core_multiSpawn and type(extensions.load) == "function" then extensions.load("core_multiSpawn") end
	local spawnGroup = compat.pickOrWarn(core_multiSpawn, "core_multiSpawn", "spawnGroup", ADD_CONSEQUENCE)
	local utils = gameplay_traffic_trafficUtils
	local createTraffic = compat.pickOrWarn(utils, "gameplay_traffic_trafficUtils", "createTrafficGroup", ADD_CONSEQUENCE)
	if not spawnGroup or not createTraffic then return nil end
	local options = careerOptions or {}
	local group = {}
	if police > 0 then
		local createPolice = compat.pick(utils, "createPoliceGroup")
		local list = createPolice and createPolice(police, options.allMods) or {}
		-- the game's police provider uses the same car when a group comes back empty
		for i = 1, police do table.insert(group, list[i] or {model = "fullsize", config = "police"}) end
	end
	local civilians = n - #group
	if civilians > 0 then
		local list = createTraffic(civilians, options.allMods, options.allConfigs, options.simpleVehs) or {}
		for i = 1, civilians do
			table.insert(group, list[(i - 1) % math.max(1, #list) + 1] or {model = "pickup"})
		end
	end
	-- Counted before the spawn: the group can be built before spawnGroup returns.
	table.insert(inFlight.road, {n = #group, police = police, at = now})
	spawnGroup(group, #group, {name = "autoTraffic", mode = "traffic", gap = 20, randomPaints = true})
	return #group
end

-- Spawns up to n parked cars in free spots more than 150 m from the camera, as the game's
-- setupVehicles does it but out of view: that one also takes spots next to the player.
-- Returns how many, 0 when no spot that far is free now, nil when the game cannot.
local function addParked(n, from, now)
	local compat = extensions.mileage_compat
	if not core_multiSpawn and type(extensions.load) == "function" then extensions.load("core_multiSpawn") end
	local findSpots = compat.pickOrWarn(gameplay_parking, "gameplay_parking", "getRandomParkingSpots", ADD_CONSEQUENCE)
	local createGroup = compat.pickOrWarn(core_multiSpawn, "core_multiSpawn", "createGroup", ADD_CONSEQUENCE)
	local spawnGroup = compat.pickOrWarn(core_multiSpawn, "core_multiSpawn", "spawnGroup", ADD_CONSEQUENCE)
	local baseParams = compat.pickOrWarn(gameplay_traffic_trafficUtils, "gameplay_traffic_trafficUtils",
		"getBaseGroupParams", ADD_CONSEQUENCE)
	if not findSpots or not createGroup or not spawnGroup or not baseParams then return nil end
	if not from then return 0 end
	local transforms = {}
	local spots = findSpots(from, KEEP_CLEAR_METRES, nil, n, {checkVehicles = true, standardSize = true})
	for _, entry in ipairs(type(spots) == "table" and spots or {}) do
		local ps = type(entry) == "table" and entry.ps
		if ps and ps.pos and metres(from, ps.pos) > KEEP_CLEAR_METRES then
			table.insert(transforms, {pos = ps.pos, rot = ps.rot})
			if #transforms >= n then break end
		end
	end
	-- The spawner places the cars at these spots only when there is one for each car.
	if #transforms == 0 then return 0 end
	local params = baseParams()
	params.allConfigs = true
	params.filters = params.filters or {}
	params.filters.Type = {propparked = 1}
	params.minPop = 0
	local group = createGroup(#transforms, params)
	if type(group) ~= "table" or not group[1] then return nil end
	table.insert(inFlight.parked, {n = #transforms, police = 0, at = now})
	spawnGroup(group, #transforms, {name = "autoParking", mode = "roadBehind", gap = 50, customTransforms = transforms,
		randomPaints = true})
	return #transforms
end

local function resizeStep(now)
	local fns = resizeFns()
	if not fns then
		resize = nil
		return
	end
	local keep = {player = be:getPlayerVehicleID(0), racing = aiRaceCar()}
	local from = viewPoint()
	local deleted, added, waiting = {road = 0, parked = 0}, {road = 0, parked = 0}, 0
	local cars = {}
	for _, kind in ipairs({"road", "parked"}) do
		cars[kind] = carsOf(kind, fns)
		local over = cars[kind] and (#cars[kind] - resize[kind]) or 0
		if over > 0 then
			for _, car in ipairs(pickCars(cars[kind], over, from, keep)) do
				deleteCar(kind, car.id, fns)
				deleted[kind] = deleted[kind] + 1
			end
			waiting = waiting + over - deleted[kind]
		end
		if not cars[kind] then resize.add[kind] = 0 end
	end

	local budget = now >= addAllowedAt and ADD_PER_STEP or 0
	if budget > 0 and resize.add.road > 0 then
		local n = math.min(budget, resize.add.road)
		local police = math.min(n, resize.addPolice)
		local spawned = addRoad(n, police, now)
		if spawned then
			resize.add.road, resize.addPolice = resize.add.road - n, resize.addPolice - police
			added.road, budget = spawned, budget - n
		else
			resize.add.road = 0
		end
	end
	if budget > 0 and resize.add.parked > 0 then
		local spawned = addParked(math.min(budget, resize.add.parked), from, now)
		if spawned and spawned > 0 then
			resize.add.parked, added.parked = resize.add.parked - spawned, spawned
		elseif spawned == 0 and now - resize.startedAt < PARKED_WAIT_SECONDS then
			-- no free spot out of view this second: tried again the next
		else
			if spawned == 0 then
				log("I", logTag, string.format("traffic share: no free parking spots out of view for %d more parked cars",
					resize.add.parked))
			end
			resize.add.parked = 0
		end
	end

	if deleted.road + deleted.parked > 0 then
		log("I", logTag, string.format("traffic share: %d driving and %d parked cars deleted", deleted.road, deleted.parked))
	end
	if added.road + added.parked > 0 then
		resize.lastAddAt, addAllowedAt = now, now + STEP_SECONDS
		log("I", logTag, string.format("traffic share: %d driving and %d parked cars added", added.road, added.parked))
	end
	if waiting > 0 and not resize.waitLogged then
		resize.waitLogged = true
		log("I", logTag, string.format("traffic share: %d cars above the share are in use or in view - tried again every second",
			waiting))
	end
	local late = (resize.lastAddAt and (now - resize.lastAddAt) < LATE_SECONDS)
		or inFlightCount("road", now) > 0 or inFlightCount("parked", now) > 0
	if waiting == 0 and resize.add.road == 0 and resize.add.parked == 0 and not late then resize = nil end
end

local function startResize(road, parked, now)
	local fns = resizeFns()
	if not fns then return end
	resize = {road = road, parked = parked, add = {road = 0, parked = 0}, addPolice = 0, startedAt = now}
	local cars = carsOf("road", fns)
	local coming, comingPolice = inFlightCount("road", now)
	if cars and road > #cars + coming then
		resize.add.road = road - #cars - coming
		resize.addPolice = math.max(0, policeFor(road) - policeCount(cars) - comingPolice)
	end
	cars = carsOf("parked", fns)
	coming = inFlightCount("parked", now)
	if cars and parked > #cars + coming then resize.add.parked = parked - #cars - coming end
	resizeStep(now)
	if resize then resize.nextAt = now + STEP_SECONDS end
end

-- Runs fn; an error is logged once and from then on a share only hides cars.
local function guarded(fn, ...)
	local ok, err = xpcall(fn, debug.traceback, ...)
	if ok then return end
	resize, resizeOff = nil, true
	log("E", logTag, "traffic share: cars could not be deleted or added, a share now only hides them: " .. tostring(err))
end

--== share changes ===========================================================
-- When a player joins or leaves a full server, the server sends everyone already in a new
-- share of its traffic total (the enabler keeps it with the client config). During a
-- career the cars are matched to the share (see "matching the share") and the game's
-- active amounts follow it; a career start reads it in its own setup, and one that
-- arrives while the start is setting up traffic, or while a mission or the tutorial
-- hides traffic, is applied once that is over.

local careerActive = false
local shareWaiting = false
local waitCheckAt = 0

local function applyShare()
	local config = serverConfig()
	if not config then return end
	-- No career start is under way, so a replacement still armed is stale.
	restoreAll("traffic share changed")
	local road, parked = M.serverAmounts(config)
	-- Cars go before the active amounts change, so the game hides none it would keep.
	if not resizeOff then guarded(startResize, road, parked, os.clockhp()) end
	local compat = extensions.mileage_compat
	local consequence = "a new traffic share waits for the next career start"
	local setRoad = compat.pickOrWarn(gameplay_traffic, "gameplay_traffic", "setActiveAmount", consequence)
	local setParked = compat.pickOrWarn(gameplay_parking, "gameplay_parking", "setActiveAmount", consequence)
	if setRoad then setRoad(road) end
	if setParked then setParked(parked) end
	log("I", logTag, string.format("traffic share changed - road %d, parked %d", road, parked))
end

--- The enabler received a new share from the server.
function M.onTrafficShare()
	if not serverConfig() then return end
	if start or (careerActive and trafficHeld()) then
		shareWaiting = true
	elseif careerActive then
		applyShare()
	end
end

local function applyWaitingShare()
	if not shareWaiting or trafficHeld() then return end
	shareWaiting = false
	if careerActive then applyShare() end
end

-- Every frame of a career: a waiting share and the cars still to match, once a second.
local function shareTick(now)
	if shareWaiting then
		if start or now < waitCheckAt then return end
		waitCheckAt = now + STEP_SECONDS
		applyWaitingShare()
		return
	end
	if not resize or now < resize.nextAt then return end
	resize.nextAt = now + STEP_SECONDS
	if trafficHeld() then return end
	guarded(resizeStep, now)
end

local function stopResize()
	resize, resizeOff, careerOptions = nil, false, nil
	inFlight, addAllowedAt = {road = {}, parked = {}}, 0
end

--- Fired by the game's spawner when a group is built: the oldest group this game asked
--- for under that name is there now.
function M.onVehicleGroupSpawned(_, _, groupName)
	local kind = (groupName == "autoTraffic" and "road") or (groupName == "autoParking" and "parked") or nil
	if kind and inFlight[kind][1] then table.remove(inFlight[kind], 1) end
end

--== hooks ===================================================================

--- Fired by the game's career.lua at the top of activateCareer, before its modules set
--- up traffic.
function M.onBeforeCareerActivate()
	arm()
end

function M.onCareerActive(active)
	careerActive = active == true and serverConfig() ~= nil
	if careerActive then
		installTutorialRestore()
		installMissionHide()
	else
		resize = nil
	end
end

local function count(module, fnName)
	local fn = type(module) == "table" and module[fnName]
	if type(fn) ~= "function" then return "?" end
	local ok, value = pcall(fn)
	return ok and tostring(value) or "?"
end

--- Fired by the game's traffic system once road and parked cars are spawned. With both
--- amounts at 0 it fires inside setupTrafficHelper itself.
function M.onTrafficOrParkingReady()
	if not start then return end
	local applied = start.applied
	start = nil
	if not applied then
		warnNotApplied()
		restoreAll("traffic ready without the meter")
	else
		log("I", logTag, string.format("traffic ready - %s road, %s parked",
			count(gameplay_traffic, "getTrafficAmount"), count(gameplay_parking, "getParkingAmount")))
	end
	applyWaitingShare()
end

-- Safety net: a career start that never sets up traffic, or never calls the active
-- amounts, must not leave the game's functions replaced.
local replacedSince = nil

function M.onUpdate()
	if careerActive then shareTick(os.clockhp()) end
	if not next(replaced) and not start then
		replacedSince = nil
		return
	end
	replacedSince = replacedSince or os.clockhp()
	if (os.clockhp() - replacedSince) <= METER_MAX_SECONDS then return end
	if start and not start.applied then
		warnNotApplied()
	elseif start then
		log("W", logTag, string.format("traffic not ready %ds after the career start - asked for road %d, parked %d",
			METER_MAX_SECONDS, start.applied.road, start.applied.parked))
	end
	start = nil
	restoreAll("timed out")
	replacedSince = nil
	applyWaitingShare()
end

function M.onBeamMPServerLeave()
	start = nil
	careerActive, shareWaiting = false, false
	stopResize()
	restoreAll("left the server")
	removeTutorialRestore()
	removeMissionHide()
	warned = {}
end

function M.onExtensionLoaded()
	log("I", logTag, "Mileage traffic meter LOADED")
end

function M.onExtensionUnloaded()
	start = nil
	careerActive, shareWaiting = false, false
	stopResize()
	restoreAll("unloaded")
	removeTutorialRestore()
	removeMissionHide()
	log("I", logTag, "Mileage traffic meter UNLOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
