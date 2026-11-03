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
-- The race this game is in: {id, route, starter, phase, frozen, countdownLeft, elapsed,
-- passed, lastPos, offFor, ended, rows, inviting}.
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
	ui({phase = "setup", spot = setup.spot, spotName = spotRoute and spotRoute.name or setup.spot, routes = list,
		allowed = status.allowed, prize = status.prize, againIn = prizeAgainIn(), opponentsMax = status.opponentsMax,
		players = players, note = setup.note, pending = pending})
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
	setup.requested = {route = route, opponents = math.floor(opponents)}
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
local STUCK_SPEED, STUCK_SECONDS = 1, 15

-- The cars to race and their push: the game's group for this car's class, or this car's
-- own model where the game cannot group cars.
local function opponentCars(count, veh, vid)
	local cars, aggression = {}, 1
	local perf, grouping = gameplay_vehiclePerformance, career_modules_vehicleClassGrouping
	if type(perf) == "table" and type(grouping) == "table" and type(perf.getClassFromVehId) == "function"
			and type(grouping.generateGroup) == "function" then
		local ok, data = pcall(perf.getClassFromVehId, vid)
		local className = ok and type(data) == "table" and (type(data.class) == "table" and data.class.name or data.class)
		if type(className) == "string" then
			local okGroup, group = pcall(grouping.generateGroup, className, nil, nil, nil, nil, nil, true, true,
				data.performanceIndex)
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
	race.spawnWait = SPAWN_WAIT_SECONDS
	local c = compat()
	for i, pose in ipairs(poses) do
		if isPoint(pose.pos) and isPoint(pose.dir) and isPoint(pose.up) then
			local car = spawnOpponent(cars[i], pose)
			if car then
				table.insert(race.opponents, {vid = car:getID(), name = (c and c.getModelName(cars[i].model)) or cars[i].model,
					passed = 0, slowFor = 0})
			end
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
		end
	end
	race.opponents = kept
	return true
end

-- Green: each opponent drives the route's checkpoints, every lap, at its class's push.
local function driveOpponents()
	local c = compat()
	local nodes = {}
	for _, checkpoint in ipairs(race.route.checkpoints) do
		local node = c and c.getClosestRoadNode(checkpoint.pos)
		if node and nodes[#nodes] ~= string.format("%q", tostring(node)) then
			table.insert(nodes, string.format("%q", tostring(node)))
		end
	end
	for _, opponent in ipairs(race.opponents) do
		local veh = be:getObjectByID(opponent.vid)
		if veh then
			opponent.lastPos = point(veh:getPosition())
			veh:queueLuaCommand("controller.setFreeze(0)")
			if #nodes > 0 then
				veh:queueLuaCommand("ai.driveUsingPath({wpTargetList = {" .. table.concat(nodes, ", ") .. "}, noOfLaps = "
					.. race.route.laps .. ", aggression = " .. race.aggression .. ", avoidCars = 'on'})")
				veh:queueLuaCommand("ai.setRacing(true)")
			end
		end
	end
end

--== the race ================================================================

local function endHere()
	if race and race.frozen then setFrozen(false) end
	deleteOpponents()
	race = nil
end

local function routeName()
	return race and race.route and race.route.name or ""
end

-- The starter says ready once its opponents are listed.
local function sendReadyWithOpponents()
	race.listing = false
	local list = {}
	for _, opponent in ipairs(race.opponents) do table.insert(list, {car = opponent.sid, model = opponent.name}) end
	send({ready = {race = race.id, opponents = list}})
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
		setup, pending, invite = nil, false, nil
		setFrozen(true)
		if starter and type(message.opponentPoses) == "table" and #message.opponentPoses > 0 then
			spawnOpponents(message.opponentPoses, veh, be:getPlayerVehicleID(0))
			race.listing = true
		end
	end
	ui({phase = "grid", id = race.id, routeName = routeName()})
	if not race.listing then
		send({ready = {race = race.id, opponents = {}}})
	elseif opponentsListed(0) then
		sendReadyWithOpponents()
	end
end

local function onCountdown(message)
	if not race or race.id ~= message.id then return end
	race.phase = "countdown"
	race.countdownLeft = tonumber(message.seconds) or 5
	race.racers = type(message.racers) == "table" and message.racers or {}
	if not race.frozen then setFrozen(true) end
	ui({phase = "countdown", id = race.id, routeName = routeName(), count = math.ceil(race.countdownLeft),
		racers = race.racers})
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
		if not passesAt(last, pos, checkpoint.pos, checkpoint.r) then return false end
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

-- Each opponent's checkpoints; out when its car is gone or stands for STUCK_SECONDS.
local function watchOpponents(dt)
	for _, opponent in ipairs(race.opponents) do
		if not opponent.ended then
			local veh = be:getObjectByID(opponent.vid)
			if not veh then
				opponent.ended = "gone"
				send({out = {race = race.id, racer = opponent.key, why = "gone"}})
			else
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
		if race.listing and opponentsListed(dt) then sendReadyWithOpponents() end
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
			driveOpponents()
			ui({phase = "go", id = race.id, routeName = routeName()})
		elseif math.ceil(race.countdownLeft) ~= before then
			ui({phase = "countdown", id = race.id, routeName = routeName(), count = math.ceil(race.countdownLeft),
				racers = race.racers})
		end
		return
	end
	if race.phase ~= "racing" then return end
	race.elapsed = race.elapsed + dt
	if not race.ended then checkOwnCar(dt) end
	watchOpponents(dt)
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
	ui({phase = "out", id = race.id, routeName = routeName(), why = "gaveUp"})
	return true
end

--- The starter starts the race now, without waiting for the other invites.
function M.startNow()
	local id = setup and setup.inviting
	if not id then return false end
	send({start = id})
	return true
end

--- The starter calls the race off while the invites are open.
function M.callOff()
	local id = setup and setup.inviting
	if not id then return false end
	send({cancel = id})
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
	inviteCard("Joined. Your car moves to the start grid when the race starts.")
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
		if setup and not setup.inviting then setupCard() end
	elseif phase == "refused" then
		pending = false
		if setup then
			setup.note = type(message.why) == "string" and message.why or "The race could not start."
			setupCard()
		end
	elseif phase == "inviting" and type(message.id) == "string" then
		pending = false
		local requested = setup and setup.requested
		if setup then setup.inviting = message.id end
		message.routeName = requested and requested.route.name or ""
		message.opponents = requested and requested.opponents or 0
		ui(message)
	elseif phase == "invite" and type(message.id) == "string" then
		if race then return end
		invite = {id = message.id, from = message.from, route = message.route, opponents = message.opponents,
			prize = message.prize, left = tonumber(message.seconds) or 30}
		inviteCard(nil)
	elseif phase == "closed" then
		if race and race.id == message.id then endHere() end
		if invite and invite.id == message.id then invite = nil end
		if setup and setup.inviting == message.id then setup = nil end
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
	setup, pending, invite, lastCard = nil, false, nil, nil
	status = {known = false, allowed = false, prize = 0, againUntil = 0, opponentsMax = 0, busy = {}, best = {}, mine = {}}
end

function M.onBeamMPServerLeave()
	reset()
end

function M.onExtensionUnloaded()
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
