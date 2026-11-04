--Mileage :: races at race spots (CLIENT)
--
-- A race spot is the start of one of the game's West Coast routes (mileage/spotRoutes.lua;
-- mileage/raceSpots.lua puts them on the map and opens the set-up card). The player picks
-- the route, the number of opponents and who to invite, and this game asks the server
-- (mileageSpotRace {request}; see the Spot races section of the server plugin). The server
-- sends each phase here (rxMileageSpotRace):
--
--   invite     (an invited player) who asks, the route, Join or Decline, with a timer
--   inviting   (the starter) who has answered so far
--   grid       move this car to its grid place with the game's safe teleport, hold it and
--              say ready; the starter's game also spawns its opponents there
--   countdown  count down, release the car on green and time the race from that moment
--   standings  every racer's place, once a second
--   result     every racer's place and time, the prize; closed: the race did not start
--
-- While racing this game checks its own car against the route's checkpoints, lap by lap,
-- and reports each pass (progress), its finish (finished) and leaving the route (out,
-- "left": more than OFF_ROUTE_METRES from the next checkpoint for OFF_ROUTE_SECONDS). The
-- server times every racer from its own readings; these reports only show a time sooner.
-- Nothing here calls the street race: a spot race has its own countdown, clock and Give
-- up. The prompts app shows every phase (guihook MileageSpotRace).
--
-- Called from the UI: mileage_spotRace.request(route, opponents, invite), .join(id),
-- .decline(id), .startNow(), .callOff(), .giveUp(), .sendState(); from raceSpots: .openSetup(spot).

local M = {}

local logTag = "mileage.spotRace"

-- A checkpoint counts within its radius plus this, as the server counts it, so the game
-- and the server always agree on which checkpoint is next.
local CHECKPOINT_SLACK = 10
local OFF_ROUTE_METRES = 1000
local OFF_ROUTE_SECONDS = 10
local PANEL_EVERY_SECONDS = 0.25

-- The server's last status: {known, allowed, prize, againUntil, opponentsMax, busy, best, mine}.
local status = {known = false, allowed = false, prize = 0, againUntil = 0, opponentsMax = 0, busy = {}, best = {},
	mine = {}}
-- Seconds since this extension loaded, for the prize's wait.
local clock = 0
-- The set-up card shown: {spot, note}, or nil.
local setup = nil
-- A request sent and not yet answered.
local pending = false
-- The starter's race while its invites are open: the race id.
local starting = nil
-- The race this game is in: {id, route, starter, phase, frozen, countdownLeft, elapsed,
-- passed, lastPos, offFor, ended, rows, opponents, listing, spawnWait, aggression}.
local race = nil
-- An open invite: {id, from, route, opponents, prize, left, sent}.
local invite = nil
-- The last card sent to the prompts app, for a UI reload.
local lastCard = nil
local panelWait = 0

local function compat()
	local c = extensions.mileage_compat
	if type(c) == "table" then return c end
	return nil
end

-- mileage/raceRoad: the race road of a route (see there).
local function raceRoad()
	local r = extensions.mileage_raceRoad
	if type(r) == "table" and type(r.usable) == "function" and type(r.legAfter) == "function" then return r end
	return {usable = function() return nil end, legAfter = function() return nil end}
end

local function routes()
	local r = extensions.mileage_spotRoutes
	if type(r) == "table" and type(r.routes) == "table" then return r.routes end
	return {}
end

local function routeById(id)
	for _, route in ipairs(routes()) do
		if route.id == id then return route end
	end
	return nil
end

local function myName()
	return MPConfig and MPConfig.getNickname() or nil
end

-- Every card carries this player's name, so the app can say "You".
local function ui(data)
	data.you = myName()
	lastCard = data
	guihooks.trigger("MileageSpotRace", data)
end

local function send(fields)
	TriggerServerEvent("mileageSpotRace", jsonEncode(fields))
end

local function point(v)
	return {x = v.x, y = v.y, z = v.z}
end

local function distance(a, b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

local function isPoint(p)
	return type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
end

local function playerVehicle()
	local id = be:getPlayerVehicleID(0)
	if not id or id < 0 then return nil, nil end
	return be:getObjectByID(id), id
end

local function setFrozen(on)
	local veh = playerVehicle()
	if veh then veh:queueLuaCommand("controller.setFreeze(" .. (on and 1 or 0) .. ")") end
	if race then race.frozen = on end
end

-- Where along the path from a to b (0 to 1) it comes within radius of centre, or nil.
local function passesAt(a, b, centre, radius)
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
	local length2 = dx * dx + dy * dy + dz * dz
	local s = 0
	if length2 > 0 then
		s = ((centre.x - a.x) * dx + (centre.y - a.y) * dy + (centre.z - a.z) * dz) / length2
		s = math.max(0, math.min(1, s))
	end
	local px, py, pz = a.x + dx * s - centre.x, a.y + dy * s - centre.y, a.z + dz * s - centre.z
	if px * px + py * py + pz * pz <= radius * radius then return s end
	return nil
end

--- Whether this player can race now (in a mission, not in one of their own cars), or nil
--- with the car.
function M.eligibility()
	local c = compat()
	if not c or not c.hasRaceFunctions() then
		return "Racing needs game functions this version of the game does not have."
	end
	if race then return "You are already in a race." end
	if c.getForegroundMissionId() then return "Finish or leave your mission first." end
	local veh, id = playerVehicle()
	if not veh or veh.JBeam == "unicycle" then return "Get in one of your own cars first." end
	if MPVehicleGE and type(MPVehicleGE.isOwn) == "function" and not MPVehicleGE.isOwn(id) then
		return "Get in one of your own cars first."
	end
	return nil, veh, id
end

--- Whether a spot race runs here: street races, events and traffic races treat it as busy.
function M.inRace()
	return race ~= nil
end

--- Whether this player is in a spot race or waiting for one: the race until their own part
--- ends (finished, left the route, gave up), the set-up card, a request sent, the starter's
--- invites open, or an invite joined and not yet started. An invite not answered is not.
function M.busy()
	return (race ~= nil and not race.ended) or setup ~= nil or pending or starting ~= nil
		or (invite ~= nil and invite.sent == true)
end

--- The server's last status, for raceSpots: {known, allowed}.
function M.getStatus()
	return {known = status.known, allowed = status.allowed}
end

--== the set-up card ===========================================================

local function prizeAgainIn()
	return math.max(0, math.ceil(status.againUntil - clock))
end

local function setupCard()
	if not setup then return end
	local busy = {}
	for _, name in ipairs(status.busy) do busy[name] = true end
	local players = {}
	if MPVehicleGE and type(MPVehicleGE.getPlayers) == "function" then
		for _, p in pairs(MPVehicleGE.getPlayers() or {}) do
			local name = type(p) == "table" and p.name
			if type(name) == "string" and name ~= myName() then
				table.insert(players, {name = name, busy = busy[name] == true})
			end
		end
	end
	table.sort(players, function(a, b) return a.name < b.name end)
	local list = {}
	for _, route in ipairs(routes()) do
		if route.spot == setup.spot then
			local best = status.best[route.id]
			table.insert(list, {id = route.id, name = route.name, laps = route.laps, length = route.length,
				closed = route.closed, best = type(best) == "table" and best.time or nil,
				bestBy = type(best) == "table" and best.name or nil, mine = status.mine[route.id]})
		end
	end
	local spotRoute = routeById(setup.spot)
	-- A car changed since its last performance test, or never tested, gets rivals from an
	-- older result or the class it was bought as.
	local c = compat()
	local _, vid = playerVehicle()
	local class = c and vid and c.carPerformanceClass(vid)
	ui({phase = "setup", spot = setup.spot, spotName = spotRoute and spotRoute.name or setup.spot, routes = list,
		allowed = status.allowed, prize = status.prize, againIn = prizeAgainIn(), opponentsMax = status.opponentsMax,
		players = players, note = setup.note, pending = pending,
		untested = class ~= nil and (class.tested == "changed" or class.tested == "never")})
end

--- Opens the set-up card for a spot (the game's prompt at its start line), and asks the
--- server for its status again so the prize, the bests and who is busy are current.
function M.openSetup(spot)
	if type(spot) ~= "string" or not routeById(spot) then return false end
	if race then return false end
	setup = {spot = spot}
	setupCard()
	send({status = true})
	return true
end

--- Asks the server for a race: route id, number of opponents, invite as a JSON list of names.
function M.request(routeId, opponents, inviteJson)
	if not setup or race or pending then return false end
	local route = routeById(routeId)
	opponents = tonumber(opponents)
	if not route or route.spot ~= setup.spot or not opponents then return false end
	local why = M.eligibility()
	if why then
		setup.note = why
		setupCard()
		return false
	end
	local names = {}
	local list = type(inviteJson) == "string" and jsonDecode(inviteJson) or nil
	for _, name in ipairs(type(list) == "table" and list or {}) do
		if type(name) == "string" then table.insert(names, name) end
	end
	pending = true
	setup.note = nil
	send({request = {route = route.id, opponents = math.floor(opponents), invite = names}})
	setupCard()
	return true
end

--- Closes the set-up card.
function M.closeSetup()
	setup = nil
	pending = false
	ui({phase = "clear"})
end

--== the starter's opponents ==================================================
-- The starter's game spawns cars of its own car's class (the game's class grouping) on
-- the grid places the server gave, marks them (mileageSpotRacer, which makes them traffic
-- to every other game), lists them once BeamMP has given each a server id, drives them
-- through the checkpoints' road nodes at green with the game's race driving at the push
-- the game gives that class, reports their checkpoints, and deletes them at every ending.

local SPAWN_WAIT_SECONDS = 10
-- How far past the finish of a one-lap route the opponents keep driving.
local BEYOND_METRES = 250
local STUCK_SPEED, STUCK_SECONDS = 1, 15
-- An opponent still within START_METRES of its grid place RETRY_SECONDS after the green is
-- sent off again; at REMOVE_SECONDS it is taken out of the race.
local START_METRES, RETRY_SECONDS, REMOVE_SECONDS = 3, 5, 12

-- The cars to race and their push: the game's group for the class of this car as it is now
-- (its latest performance test, upgrades counted), or this car's own model where the game
-- cannot group cars.
local function opponentCars(count, veh, vid)
	local cars, aggression = {}, 1
	local grouping = career_modules_vehicleClassGrouping
	local c = compat()
	if c and type(grouping) == "table" and type(grouping.generateGroup) == "function" then
		local data = c.carPerformanceClass(vid)
		local className = data and data.class
		if type(className) == "string" then
			local okGroup, group = pcall(grouping.generateGroup, className, nil, nil, nil, nil, nil, true, true,
				data.index)
			for _, entry in ipairs(okGroup and type(group) == "table" and type(group.data) == "table" and group.data or {}) do
				if type(entry) == "table" and type(entry.model) == "string" then table.insert(cars, entry) end
			end
			if type(grouping.getAggressionMultiplier) == "function" then
				local okPush, push = pcall(grouping.getAggressionMultiplier, className)
				if okPush and tonumber(push) then aggression = tonumber(push) end
			end
		end
	end
	if #cars == 0 then cars = {{model = veh.JBeam, config = veh.partConfig}} end
	local chosen = {}
	for i = 1, count do chosen[i] = cars[(i - 1) % #cars + 1] end
	return chosen, aggression
end

local function spawnOpponent(entry, pose)
	if type(core_vehicles) ~= "table" or type(core_vehicles.spawnNewVehicle) ~= "function" then return nil end
	local rot = quatFromDir(vec3(pose.dir.x, pose.dir.y, pose.dir.z), vec3(pose.up.x, pose.up.y, pose.up.z))
	local ok, veh = pcall(core_vehicles.spawnNewVehicle, entry.model, {config = entry.config, paintName = entry.paintName,
		pos = vec3(pose.pos.x, pose.pos.y, pose.pos.z), rot = rot, autoEnterVehicle = false})
	if not ok or not veh then
		log("W", logTag, "an opponent could not be spawned: " .. tostring(ok and "no car" or veh))
		return nil
	end
	pcall(function() veh:setDynDataFieldbyName("mileageSpotRacer", 0, "true") end)
	veh:queueLuaCommand("controller.setFreeze(1)")
	return veh
end

local function deleteOpponents()
	for _, opponent in ipairs(race and race.opponents or {}) do
		local veh = be:getObjectByID(opponent.vid)
		if veh then
			local ok, err = pcall(function() veh:delete() end)
			if not ok then log("E", logTag, "an opponent could not be deleted: " .. tostring(err)) end
		end
	end
	if race then race.opponents = {} end
end

-- Spawns one car per opponent grid place. Each gets its server id from BeamMP a moment later.
local function spawnOpponents(poses, veh, vid)
	local cars, aggression = opponentCars(#poses, veh, vid)
	race.aggression = aggression
	race.opponents = {}
	-- The cars that did not start, by model name: the server lists them as such.
	race.failed = {}
	race.spawnWait = SPAWN_WAIT_SECONDS
	local c = compat()
	for i, pose in ipairs(poses) do
		local name = (c and c.getModelName(cars[i].model)) or cars[i].model
		local car = isPoint(pose.pos) and isPoint(pose.dir) and isPoint(pose.up) and spawnOpponent(cars[i], pose) or nil
		if car then
			table.insert(race.opponents, {vid = car:getID(), name = name, passed = 0, slowFor = 0})
		else
			table.insert(race.failed, name)
		end
	end
end

-- The opponents BeamMP has given a server id; true once all have one or the wait is over,
-- when those without one are deleted.
local function opponentsListed(dt)
	local all = true
	for _, opponent in ipairs(race.opponents) do
		if not opponent.sid and MPVehicleGE and type(MPVehicleGE.getServerVehicleID) == "function" then
			opponent.sid = MPVehicleGE.getServerVehicleID(opponent.vid)
		end
		if not opponent.sid then all = false end
	end
	race.spawnWait = race.spawnWait - dt
	if not all and race.spawnWait > 0 then return false end
	local kept = {}
	for _, opponent in ipairs(race.opponents) do
		if opponent.sid then
			opponent.key = "car:" .. opponent.sid
			table.insert(kept, opponent)
		else
			local veh = be:getObjectByID(opponent.vid)
			if veh then pcall(function() veh:delete() end) end
			table.insert(race.failed, opponent.name)
		end
	end
	race.opponents = kept
	return true
end

-- The road nodes of a lap of the race road, in order, with no node twice in a row. On a
-- route of more than one lap the path starts at checkpoint 1's node and ends on it again
-- (the closing road from the finish), as the game's race driving needs to repeat laps.
local function roadNames(road, route)
	local names = {}
	local function add(list)
		for _, name in ipairs(list) do
			if names[#names] ~= tostring(name) then table.insert(names, tostring(name)) end
		end
	end
	if route.laps > 1 and road.closing and #road.legs > 1 then
		for i = 2, #road.legs do add(road.legs[i].nodes) end
		add(road.closing.nodes)
	else
		for i = 1, #road.legs do add(road.legs[i].nodes) end
	end
	return names
end

-- The road node nearest each checkpoint, in order.
local function checkpointNames()
	local c = compat()
	local names = {}
	for _, checkpoint in ipairs(race.route.checkpoints) do
		local node = c and c.getClosestRoadNode(checkpoint.pos)
		if node and names[#names] ~= tostring(node) then table.insert(names, tostring(node)) end
	end
	return names
end

-- names with every road point the game's AI cannot drive left out. The game's AI builds
-- its route once, at the command, and gives up on all of it, for the whole race, at a
-- first point the car does not reach by road or two points in a row no road joins
-- (ai.lua newManualPath); a car with no route never moves. So the first point kept is one
-- the car at fromPos reaches, each next one is joined by road to the one kept before, and
-- a list that ends on its first point (laps repeat) still does. Returns the list and how
-- many points were left out; names as they are where the game cannot tell.
local function drivablePath(names, fromPos)
	local c = compat()
	if not c or #names == 0 then return names, 0 end
	local loops = #names > 1 and names[#names] == names[1]
	local kept = {}
	for i = 1, #names - (loops and 1 or 0) do
		local name = names[i]
		local ok
		if #kept == 0 then
			ok = c.roadReaches(fromPos, name)
			if ok then ok = c.roadJoins(name, name) end
		else
			ok = c.roadJoins(kept[#kept], name)
		end
		if ok == nil then return names, 0 end
		if ok then table.insert(kept, name) end
	end
	if loops then
		while #kept > 1 and not c.roadJoins(kept[#kept], kept[1]) do table.remove(kept) end
		if #kept > 1 then table.insert(kept, kept[1]) end
	end
	return kept, #names - #kept
end

-- The drive command for road points names, or nil for none.
local function driveCommand(names)
	if #names == 0 then return nil end
	local nodes = {}
	for i, name in ipairs(names) do nodes[i] = string.format("%q", name) end
	return "ai.driveUsingPath({wpTargetList = {" .. table.concat(nodes, ", ") .. "}, noOfLaps = "
		.. race.route.laps .. ", aggression = " .. race.aggression .. ", avoidCars = 'on'})"
end

-- Sends one opponent off on names, checked for its own place on the grid first.
local function sendOff(veh, opponent, names, what)
	local path, dropped = drivablePath(names, opponent.gridPos)
	if dropped > 0 then
		log("W", logTag, string.format("%s: dropped %d of %d %s the game's AI cannot drive for %s (car %s)",
			tostring(race.route.id), dropped, #names, what, opponent.name, tostring(opponent.sid)))
	end
	local command = driveCommand(path)
	if command then
		veh:queueLuaCommand(command)
		veh:queueLuaCommand("ai.setRacing(true)")
	end
end

-- names made a whole race: on more than one lap ending on its first node, on one lap
-- going on past the finish.
local function racePath(names)
	local c = compat()
	if #names > 1 and race.route.laps > 1 then
		-- The game's race driving repeats laps only on a path that ends on its first node
		-- (ai.lua's loopPath), as its own races build theirs.
		if names[#names] ~= names[1] then table.insert(names, names[1]) end
	elseif #names > 0 then
		-- One lap: drive on past the finish line instead of braking to a stop on it.
		local last, before = race.route.checkpoints[#race.route.checkpoints].pos,
			race.route.checkpoints[math.max(1, #race.route.checkpoints - 1)].pos
		local dir = {x = last.x - before.x, y = last.y - before.y, z = 0}
		for _, name in ipairs(c and c.getRoadBeyond(names[#names], dir, BEYOND_METRES) or {}) do
			if tostring(name) ~= names[#names] then table.insert(names, tostring(name)) end
		end
	end
	return names
end

-- Green: each opponent drives the route, every lap, at its class's push: every node of
-- the race road where there is one, else the road node nearest each checkpoint.
local function driveOpponents()
	local names = racePath(race.road and roadNames(race.road, race.route) or checkpointNames())
	for _, opponent in ipairs(race.opponents) do
		local veh = be:getObjectByID(opponent.vid)
		if veh then
			opponent.lastPos = point(veh:getPosition())
			opponent.gridPos = opponent.lastPos
			veh:queueLuaCommand("controller.setFreeze(0)")
			sendOff(veh, opponent, names, "road points")
		end
	end
end

--== traffic during the race =================================================
-- At the green each racer's game halves its own active traffic and parked cars, rounded
-- up, to leave room for the racing cars. Its police cars are held out of the game's
-- vehicle pool so none is hidden, and count towards the half. The game hides the rest as
-- it does whenever its amounts change, and Mileage's hide sync shows that to every other
-- game. Once this game's part of the race is over (its own race, and the opponents it
-- drives), the police go back into the pool and the amounts back to what the server sets.

local function thinTraffic()
	local c = compat()
	if not race or race.thinned or not c then return end
	local amounts = c.getTrafficAmounts()
	if not amounts then return end
	local police = {}
	if amounts.road then
		for _, id in ipairs(c.getPoliceCars()) do
			local pool = c.takeOutOfPool(id)
			if pool then table.insert(police, {pool = pool, id = id}) end
		end
	end
	race.thinned = {road = amounts.road, parked = amounts.parked, police = police}
	c.setTrafficAmounts(amounts.road and math.max(0, math.ceil(amounts.activeRoad / 2) - #police),
		amounts.parked and math.ceil(amounts.activeParked / 2))
end

-- The server's amounts now (a share it sent during the race included), or nil.
local function serverAmounts()
	local traffic, enabler = extensions.mileage_traffic, mileageEnabler
	if type(traffic) ~= "table" or type(traffic.serverAmounts) ~= "function" or type(enabler) ~= "table"
			or type(enabler.getClientConfig) ~= "function" then
		return nil
	end
	local ok, road, parked = pcall(function() return traffic.serverAmounts(enabler.getClientConfig()) end)
	if ok and tonumber(road) and tonumber(parked) then return road, parked end
	return nil
end

local function restoreTraffic()
	local thinned = race and race.thinned
	if not thinned then return end
	race.thinned = nil
	local c = compat()
	if not c then return end
	for _, held in ipairs(thinned.police) do c.putBackInPool(held.pool, held.id) end
	local road, parked = serverAmounts()
	c.setTrafficAmounts(thinned.road and (road or thinned.road), thinned.parked and (parked or thinned.parked))
end

-- This racer's own race is over: its traffic comes back unless it still drives opponents.
local function ownRaceOver()
	for _, opponent in ipairs(race.opponents) do
		if not opponent.ended then return end
	end
	restoreTraffic()
end

--== the race ================================================================

-- Takes the checkpoint markers and the line off the screen.
local function clearGuidance()
	if not race or not (race.markers or race.lineSet) then return end
	local c = compat()
	if c and race.markers then c.clearRaceMarkers() end
	if c and race.lineSet then c.clearNavigation() end
	race.markers, race.lineSet = nil, nil
end

local function endHere()
	if race and race.frozen then setFrozen(false) end
	clearGuidance()
	restoreTraffic()
	deleteOpponents()
	race = nil
end

local function routeName()
	return race and race.route and race.route.name or ""
end

-- The server vehicle id of the car this player drives, which the server times.
local function ownCarId()
	local _, vid = playerVehicle()
	if not vid or not MPVehicleGE or type(MPVehicleGE.getServerVehicleID) ~= "function" then return nil end
	return MPVehicleGE.getServerVehicleID(vid)
end

-- Ready on the grid, naming this player's car; the starter's game also lists its opponents
-- once BeamMP has given them their ids.
local function sendReady()
	race.listing = false
	local list = {}
	for _, opponent in ipairs(race.opponents) do table.insert(list, {car = opponent.sid, model = opponent.name}) end
	send({ready = {race = race.id, car = ownCarId(), opponents = list, failed = race.failed or {}}})
end

-- Moves this car to its grid place and holds it there; the race is under way from now.
local function onGrid(message)
	local route = routeById(message.route)
	local pose = message.pose
	if not route or type(pose) ~= "table" or not isPoint(pose.pos) or not isPoint(pose.dir) or not isPoint(pose.up) then
		return
	end
	local starter = message.starter == myName()
	if race and race.id ~= message.id then return end
	if not race then
		local why, veh = M.eligibility()
		local c = compat()
		local rot = quatFromDir(vec3(pose.dir.x, pose.dir.y, pose.dir.z), vec3(pose.up.x, pose.up.y, pose.up.z))
		if why or not veh or not c or not c.safeTeleport(veh, vec3(pose.pos.x, pose.pos.y, pose.pos.z), rot) then
			log("W", logTag, "this car cannot race at the spot (" .. tostring(why) .. "); leaving the race")
			send({gaveUp = message.id})
			ui({phase = "closed", id = message.id, why = why or "Your car could not be moved to the start."})
			return
		end
		race = {id = message.id, route = route, starter = starter, phase = "grid", passed = 0, offFor = 0, opponents = {}}
		-- The race road is worked out now, with the cars waiting on the grid; where this
		-- game's check does not pass for the route, the game's own navigation is used.
		race.road = raceRoad().usable(route)
		if not race.road then
			log("W", logTag, tostring(route.id) .. ": no race road that passes the check; using the game's navigation")
		end
		setup, pending, invite, starting = nil, false, nil, nil
		setFrozen(true)
		if starter and type(message.opponentPoses) == "table" and #message.opponentPoses > 0 then
			spawnOpponents(message.opponentPoses, veh, be:getPlayerVehicleID(0))
			race.listing = true
		end
	end
	ui({phase = "grid", id = race.id, routeName = routeName()})
	if not race.listing or opponentsListed(0) then sendReady() end
end

local function onCountdown(message)
	if not race or race.id ~= message.id then return end
	race.phase = "countdown"
	race.countdownLeft = tonumber(message.seconds) or 5
	race.racers = type(message.racers) == "table" and message.racers or {}
	race.prize = tonumber(message.prize) or 0
	if not race.frozen then setFrozen(true) end
	ui({phase = "countdown", id = race.id, routeName = routeName(), count = math.ceil(race.countdownLeft),
		racers = race.racers, prize = race.prize})
end

-- This racer's row in the server's standings, its place and the racer ahead of it.
local function placeOf(rows)
	local me = myName()
	for i, row in ipairs(rows or {}) do
		if not row.car and row.name == me then
			local ahead = rows[i - 1]
			local gap = nil
			if ahead and ahead.passed == row.passed and tonumber(ahead.at) and tonumber(row.at) then
				gap = row.at - ahead.at
			end
			return i, #rows, ahead and ahead.name or nil, gap
		end
	end
	return nil, rows and #rows or 0, nil, nil
end

local function racingPanel(nextMetres)
	local n = #race.route.checkpoints
	local place, of, ahead, gap = placeOf(race.rows)
	ui({phase = "racing", id = race.id, routeName = routeName(), place = place, of = of, ahead = ahead, gap = gap,
		lap = math.min(race.route.laps, math.floor(race.passed / n) + 1), laps = race.route.laps,
		checkpoint = math.min(n, race.passed % n + 1), checkpoints = n, elapsed = race.elapsed,
		offRoute = race.offFor > 0 and math.max(0, math.ceil(OFF_ROUTE_SECONDS - race.offFor)) or nil,
		nextMetres = nextMetres and math.floor(nextMetres) or nil})
end

-- The checkpoints a racer (this car, or one of the starter's opponents: state.passed,
-- state.lastPos) passed between its last position and pos, reported to the server as key.
-- Returns true at its finish.
local function passCheckpoints(state, pos, key)
	local checkpoints = race.route.checkpoints
	local total = #checkpoints * race.route.laps
	local last = state.lastPos or pos
	state.lastPos = pos
	while state.passed < total do
		local checkpoint = checkpoints[state.passed % #checkpoints + 1]
		if not passesAt(last, pos, checkpoint.pos, checkpoint.r + CHECKPOINT_SLACK) then return false end
		state.passed = state.passed + 1
		local lap = math.floor((state.passed - 1) / #checkpoints) + 1
		local index = (state.passed - 1) % #checkpoints + 1
		send({progress = {race = race.id, racer = key, checkpoint = index, lap = lap, at = race.elapsed}})
		if state.passed == total then
			send({finished = {race = race.id, racer = key, seconds = race.elapsed}})
			return true
		end
	end
	return false
end

-- An opponent that has not left its grid place: sent off again on the checkpoints' road
-- points RETRY_SECONDS after the green (the game's AI builds a route only when it is given
-- one, so the whole command goes again), then deleted and reported stuck at
-- REMOVE_SECONDS, so the race goes on without it. Returns true once it is taken out.
local function watchStart(opponent, veh, pos)
	if opponent.started or not opponent.gridPos then return false end
	if distance(pos, opponent.gridPos) > START_METRES then
		opponent.started = true
		return false
	end
	local car = string.format("%s: %s (car %s)", tostring(race.route.id), opponent.name, tostring(opponent.sid))
	if race.elapsed >= REMOVE_SECONDS then
		opponent.ended = "stuck"
		local ok, err = pcall(function() veh:delete() end)
		if not ok then log("E", logTag, "an opponent could not be deleted: " .. tostring(err)) end
		log("W", logTag, car .. " never left the grid; taken out of the race")
		send({out = {race = race.id, racer = opponent.key, why = "stuck"}})
		return true
	end
	if race.elapsed >= RETRY_SECONDS and not opponent.retried then
		opponent.retried = true
		log("I", logTag, string.format("%s has not moved %d s after the green; sent off again", car, RETRY_SECONDS))
		race.retryNames = race.retryNames or racePath(checkpointNames())
		sendOff(veh, opponent, race.retryNames, "checkpoint road points")
	end
	return false
end

-- Each opponent's checkpoints; out when its car is gone or stands for STUCK_SECONDS, or
-- taken out when it never leaves the grid.
local function watchOpponents(dt)
	for _, opponent in ipairs(race.opponents) do
		if not opponent.ended then
			local veh = be:getObjectByID(opponent.vid)
			if not veh then
				opponent.ended = "gone"
				send({out = {race = race.id, racer = opponent.key, why = "gone"}})
			elseif not watchStart(opponent, veh, point(veh:getPosition())) then
				local pos = point(veh:getPosition())
				local before = opponent.lastPos or pos
				if passCheckpoints(opponent, pos, opponent.key) then
					opponent.ended = "finished"
				elseif dt > 0 then
					if distance(pos, before) / dt < STUCK_SPEED then opponent.slowFor = opponent.slowFor + dt
					else opponent.slowFor = 0 end
					if opponent.slowFor >= STUCK_SECONDS then
						opponent.ended = "stuck"
						send({out = {race = race.id, racer = opponent.key, why = "stuck"}})
					end
				end
			end
		end
	end
end

-- This car's own checkpoints, lap by lap, from its last position to where it is now.
-- The next checkpoint is the route on the big map and the navigation, set again after each
-- pass, so the racer always knows where to drive.
local function showNextCheckpoint()
	if race.shownFor == race.passed then return end
	race.shownFor = race.passed
	local c = compat()
	if not c then return end
	local checkpoints = race.route.checkpoints
	local n = #checkpoints
	local leg = race.road and raceRoad().legAfter(race.road, race.passed, n)
	if leg and c.setNavigationPath(leg.points) then
		race.lineSet = true
	else
		c.setNavigationTarget(checkpoints[race.passed % n + 1].pos)
	end
	if race.markers then
		-- The checkpoint to drive to is red (blue at the finish: the game's marker calls that
		-- mode "final"), the one after it black.
		local total = n * race.route.laps
		local modes = {}
		local current = race.passed % n + 1
		modes["cp" .. current] = race.passed + 1 == total and "final" or "default"
		if race.passed + 2 <= total and current % n + 1 ~= current then modes["cp" .. (current % n + 1)] = "next" end
		c.setRaceMarkerModes(modes)
	end
end

local function checkOwnCar(dt)
	local veh = playerVehicle()
	if not veh then return end
	local pos = point(veh:getPosition())
	local checkpoints = race.route.checkpoints
	if passCheckpoints(race, pos, myName()) then
		race.ended = "finished"
		ui({phase = "finished", id = race.id, routeName = routeName(), elapsed = race.elapsed})
		return
	end
	showNextCheckpoint()
	local nextPos = checkpoints[race.passed % #checkpoints + 1].pos
	local away = distance(pos, nextPos)
	if away > OFF_ROUTE_METRES then race.offFor = race.offFor + dt else race.offFor = 0 end
	if race.offFor >= OFF_ROUTE_SECONDS then
		race.ended = "left"
		send({out = {race = race.id, racer = myName(), why = "left"}})
		ui({phase = "out", id = race.id, routeName = routeName(), why = "left"})
		return
	end
	panelWait = panelWait - dt
	if panelWait <= 0 then
		panelWait = PANEL_EVERY_SECONDS
		racingPanel(away)
	end
end

local function updateRace(dt)
	if race.phase == "grid" then
		if race.listing and opponentsListed(dt) then sendReady() end
		return
	end
	if race.phase == "countdown" and race.countdownLeft then
		local before = math.ceil(race.countdownLeft)
		race.countdownLeft = race.countdownLeft - dt
		if race.countdownLeft <= 0 then
			-- Green: this car goes and its clock starts now, whatever the server's delay.
			race.phase = "racing"
			race.elapsed = -race.countdownLeft
			local veh = playerVehicle()
			race.lastPos = veh and point(veh:getPosition()) or nil
			setFrozen(false)
			local c = compat()
			if c then
				local wps = {}
				for i, checkpoint in ipairs(race.route.checkpoints) do
					wps[i] = {name = "cp" .. i, pos = checkpoint.pos, r = checkpoint.r}
				end
				race.markers = c.setRaceMarkers(wps)
			end
			showNextCheckpoint()
			driveOpponents()
			thinTraffic()
			ui({phase = "go", id = race.id, routeName = routeName()})
		elseif math.ceil(race.countdownLeft) ~= before then
			ui({phase = "countdown", id = race.id, routeName = routeName(), count = math.ceil(race.countdownLeft),
				racers = race.racers, prize = race.prize})
		end
		return
	end
	if race.phase ~= "racing" then return end
	race.elapsed = race.elapsed + dt
	if race.markers then
		local c = compat()
		if c then c.renderRaceMarkers(dt) end
	end
	if not race.ended then checkOwnCar(dt) end
	watchOpponents(dt)
	if race.ended then
		clearGuidance()
		if race.thinned then ownRaceOver() end
	end
end

--- Gives up the race under way: before the green the starter calls it off for everyone.
function M.giveUp()
	if not race then return false end
	send({gaveUp = race.id})
	if race.phase ~= "racing" then
		endHere()
		return true
	end
	race.ended = "gaveUp"
	ownRaceOver()
	ui({phase = "out", id = race.id, routeName = routeName(), why = "gaveUp"})
	return true
end

--- The starter starts the race now, without waiting for the other invites.
function M.startNow()
	if not starting then return false end
	send({start = starting})
	return true
end

--- The starter calls the race off while the invites are open.
function M.callOff()
	if not starting then return false end
	send({cancel = starting})
	return true
end

--== invites ===================================================================

local function inviteCard(note)
	ui({phase = "invite", id = invite.id, from = invite.from, route = invite.route, opponents = invite.opponents,
		prize = invite.prize, seconds = math.max(0, invite.left), note = note})
end

--- Joins the race this player is invited to: its car is moved to the grid when it starts.
function M.join(id)
	if not invite or invite.id ~= id or invite.sent then return false end
	local why = M.eligibility()
	if why then
		inviteCard(why)
		return false
	end
	invite.sent = true
	send({join = id})
	inviteCard("Joined: your car moves to the grid when it starts.")
	return true
end

--- Turns the invite down.
function M.decline(id)
	if not invite or invite.id ~= id then return false end
	send({decline = id})
	invite = nil
	ui({phase = "inviteClosed", id = id})
	return true
end

--== messages from the server ==================================================

local function rxMileageSpotRace(data)
	local message = jsonDecode(data)
	if type(message) ~= "table" then return end
	local phase = message.phase
	if phase == "status" then
		status = {known = true, allowed = message.allowed == true, prize = tonumber(message.prize) or 0,
			againUntil = clock + (tonumber(message.againIn) or 0), opponentsMax = tonumber(message.opponentsMax) or 0,
			busy = type(message.busy) == "table" and message.busy or {},
			best = type(message.best) == "table" and message.best or {},
			mine = type(message.mine) == "table" and message.mine or {}}
		local spots = extensions.mileage_raceSpots
		if type(spots) == "table" and type(spots.statusChanged) == "function" then spots.statusChanged() end
		if setup then setupCard() end
	elseif phase == "refused" then
		pending = false
		if setup then
			setup.note = type(message.why) == "string" and message.why or "The race could not start."
			setupCard()
		end
	elseif phase == "inviting" and type(message.id) == "string" then
		-- The set-up card gives way to the starter's card of who has answered.
		pending, setup, starting = false, nil, message.id
		local route = routeById(message.route)
		message.routeName = route and route.name or ""
		ui(message)
	elseif phase == "invite" and type(message.id) == "string" then
		if race then return end
		invite = {id = message.id, from = message.from, route = message.route, opponents = message.opponents,
			prize = message.prize, left = tonumber(message.seconds) or 30}
		inviteCard(nil)
	elseif phase == "closed" then
		-- Only for the race, invite or starter's card this game has now: a closing for an
		-- older invite must not cover a newer one.
		local mine = (race and race.id == message.id) or (invite and invite.id == message.id) or starting == message.id
		if not mine then return end
		if race and race.id == message.id then endHere() end
		if invite and invite.id == message.id then invite = nil end
		if starting == message.id then starting = nil end
		pending = false
		ui(message)
	elseif phase == "grid" and type(message.id) == "string" then
		onGrid(message)
	elseif phase == "countdown" then
		onCountdown(message)
	elseif phase == "standings" then
		if race and race.id == message.id then race.rows = type(message.rows) == "table" and message.rows or {} end
	elseif phase == "result" then
		if race and race.id == message.id then endHere() end
		local route = routeById(message.route)
		message.routeName = route and route.name or ""
		if tonumber(message.againIn) then status.againUntil = clock + tonumber(message.againIn) end
		ui(message)
	end
end

function M.onUpdate(dtReal)
	local dt = math.max(0, math.min(1, tonumber(dtReal) or 0))
	clock = clock + dt
	if invite and not invite.sent then
		invite.left = invite.left - dt
		if invite.left <= 0 then
			local id = invite.id
			invite = nil
			ui({phase = "inviteClosed", id = id})
		end
	end
	if race then updateRace(dt) end
end

--- Sends the card under way to the prompts app again, after a UI reload.
function M.sendState()
	if lastCard then guihooks.trigger("MileageSpotRace", lastCard) end
end

local function reset()
	endHere()
	setup, pending, invite, starting, lastCard = nil, false, nil, nil, nil
	status = {known = false, allowed = false, prize = 0, againUntil = 0, opponentsMax = 0, busy = {}, best = {}, mine = {}}
end

function M.onBeamMPServerLeave()
	reset()
end

function M.onExtensionUnloaded()
	-- A reload mid-race must not leave the traffic thinned or the markers up.
	clearGuidance()
	restoreTraffic()
	deleteOpponents()
end

function M.onExtensionLoaded()
	if type(AddEventHandler) ~= "function" then
		log("E", logTag, "AddEventHandler unavailable - BeamMP not loaded")
		return
	end
	AddEventHandler("rxMileageSpotRace", rxMileageSpotRace)
	log("I", logTag, "Mileage race spots LOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
