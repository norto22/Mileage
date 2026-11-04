--Mileage :: street races between players (CLIENT)
--
-- A race from the player list: the challenger sets a route on the big map, whose end is
-- the finish. The server runs the race (see the Races section of the server plugin) and
-- sends each phase here (rxMileageRace):
--
--   staking    both stakes are being taken (mileage/transfers.lua does that)
--   pose       (challenger) report where this car stands and hold it still
--   teleport   (challenged) move this car 4 m to the right of the challenger's, facing
--              the same way, with the game's safe teleport, hold it still, report ready
--   countdown  count down, release the car on green and time the race from that moment
--   result     who won, both times, the money; calledOff: the race did not start
--
-- The game reports its time once the car comes within the finish radius, and Give up
-- reports that instead. The prompts app shows each phase (guihook MileageRace).
--
-- Called from the UI: mileage_streetRace.giveUp(); from mileage/offers.lua: checkStart.

local M = {}

local logTag = "mileage.streetRace"

local BESIDE_METRES = 4
local PANEL_EVERY_SECONDS = 0.25

-- The race under way here: {id, phase, other, stake, finish, radius, countdownLeft,
-- elapsed, reported, frozen, rolling, reward}
local race = nil
local panelWait = 0

local function compat()
	local c = extensions.mileage_compat
	if type(c) == "table" then return c end
	return nil
end

local function report(fields)
	TriggerServerEvent("mileageRaceReport", jsonEncode(fields))
end

-- A rolling race's panel also shows that nobody stops, and the race reward; an event
-- race's shows the prize for the racers who started.
local function ui(data)
	if race and race.rolling and data.race == race.id then
		data.rolling = true
		data.reward = race.reward
	elseif race and race.event and data.race == race.id then
		data.event = true
		data.prize = race.prize
		data.racers = race.racers
	end
	guihooks.trigger("MileageRace", data)
end

local function playerVehicle()
	local id = be:getPlayerVehicleID(0)
	if not id or id < 0 then return nil, nil end
	return be:getObjectByID(id), id
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

local function setFrozen(on)
	local veh = playerVehicle()
	if veh then veh:queueLuaCommand("controller.setFreeze(" .. (on and 1 or 0) .. ")") end
	if race then race.frozen = on end
end

local function endRace()
	if race and race.frozen then setFrozen(false) end
	race = nil
end

--- Why this player cannot race now (already racing, in a mission, not driving one of
--- their own cars), or nil with the car and its id. Checked when a challenge is made, when
--- it is accepted, and again when the car is about to be moved.
function M.eligibility()
	local c = compat()
	if not c or not c.hasRaceFunctions() then
		return "Racing needs game functions this version of the game does not have."
	end
	if race then return "You are already in a race." end
	local spot = extensions.mileage_spotRace
	if type(spot) == "table" and type(spot.inRace) == "function" and spot.inRace() then
		return "You are already in a race."
	end
	if c.getForegroundMissionId() then return "Finish or leave your mission first." end
	local veh, id = playerVehicle()
	if not veh or veh.JBeam == "unicycle" then return "Get in one of your own cars first." end
	if MPVehicleGE and type(MPVehicleGE.isOwn) == "function" and not MPVehicleGE.isOwn(id) then
		return "Get in one of your own cars first."
	end
	return nil, veh, id
end

--- Whether this player can start a race now: {why} when not, otherwise {distance,
--- start, finish} with the car's position and the finish as {x, y, z}.
function M.checkStart(minDistance)
	local why, veh = M.eligibility()
	if why then return {why = why} end
	local target = compat().getNavigationTarget()
	if not target then return {why = "Set a route on the big map first: its end is the finish line."} end
	local start = point(veh:getPosition())
	local finish = point(target)
	local metres = distance(start, finish)
	minDistance = tonumber(minDistance) or 0
	if metres < minDistance then
		return {why = string.format("The finish is closer than this server's shortest race (%d m).", minDistance),
			distance = math.floor(metres)}
	end
	return {distance = math.floor(metres), start = start, finish = finish}
end

--- Give up the race under way: from the countdown on this loses the stake.
function M.giveUp()
	if not race then return false end
	report({race = race.id, gaveUp = true})
	return true
end

--== the phases ================================================================

-- The challenger's car: where it stands and which way it faces, for the other car.
-- Whether this car may be moved and held for the race now: not in a mission, in one of
-- the player's own cars. (The race itself is already under way here.)
local function carProblem()
	local c = compat()
	if c and c.getForegroundMissionId() then return "in a mission" end
	local veh, id = playerVehicle()
	if not veh or veh.JBeam == "unicycle" then return "not in a car" end
	if MPVehicleGE and type(MPVehicleGE.isOwn) == "function" and not MPVehicleGE.isOwn(id) then
		return "not in their own car"
	end
	return nil
end

local function sendPose(message)
	local veh = playerVehicle()
	local problem = carProblem()
	if problem then
		report({race = message.race, failed = "the challenger was " .. problem})
		return
	end
	setFrozen(true)
	report({race = message.race, pose = {pos = point(veh:getPosition()), dir = point(veh:getDirectionVector()),
		up = point(veh:getDirectionVectorUp())}})
end

-- The challenged car goes BESIDE_METRES to the right of the challenger's.
local function moveBeside(message)
	local pose = message.pose
	local veh = playerVehicle()
	local c = compat()
	if type(pose) ~= "table" or not isPoint(pose.pos) or not isPoint(pose.dir) or not isPoint(pose.up) then return end
	local problem = carProblem()
	if problem or not c then
		report({race = message.race, failed = "the challenged player was " .. (problem or "not ready")})
		return
	end
	local d, u = pose.dir, pose.up
	-- Forward x up points right in the game's right-handed frame.
	local rx, ry, rz = d.y * u.z - d.z * u.y, d.z * u.x - d.x * u.z, d.x * u.y - d.y * u.x
	local length = math.sqrt(rx * rx + ry * ry + rz * rz)
	if length < 1e-6 then
		report({race = message.race, failed = "the challenger's car could not be read"})
		return
	end
	local pos = vec3(pose.pos.x + rx / length * BESIDE_METRES, pose.pos.y + ry / length * BESIDE_METRES,
		pose.pos.z + rz / length * BESIDE_METRES)
	local rot = quatFromDir(vec3(d.x, d.y, d.z), vec3(u.x, u.y, u.z))
	if not c.safeTeleport(veh, pos, rot) then
		report({race = message.race, failed = "the challenged car could not be moved"})
		return
	end
	setFrozen(true)
	report({race = message.race, ready = true})
end

local function rxMileageRace(data)
	local message = jsonDecode(data)
	if type(message) ~= "table" or type(message.race) ~= "string" then return end
	local phase = message.phase
	if phase == "staking" then
		race = {id = message.race, phase = "staking", stake = message.stake,
			other = message.a == MPConfig.getNickname() and message.b or message.a}
		ui({phase = "staking", race = race.id, other = race.other, stake = race.stake})
		return
	end
	if phase == "result" or phase == "calledOff" then
		if race and race.id == message.race then endRace() end
		ui(message)
		return
	end
	if not race or race.id ~= message.race then
		race = {id = message.race, other = message.other, stake = message.stake}
	end
	race.phase = phase
	if phase == "pose" then
		sendPose(message)
		ui({phase = "lining up", race = race.id, other = race.other})
	elseif phase == "teleport" then
		moveBeside(message)
		ui({phase = "lining up", race = race.id, other = race.other})
	elseif phase == "countdown" and isPoint(message.finish) then
		race.finish = message.finish
		race.radius = tonumber(message.radius) or 20
		race.countdownLeft = tonumber(message.seconds) or 3
		race.stake = message.stake
		race.other = message.a == MPConfig.getNickname() and message.b or message.a
		if not race.frozen then setFrozen(true) end
		-- The challenged player has set no route: the finish is shown on their map too.
		local c = compat()
		if c then c.setNavigationTarget(race.finish) end
		ui({phase = "countdown", race = race.id, other = race.other, stake = race.stake,
			count = math.ceil(race.countdownLeft)})
	end
end

local function updateRace(dt)
	if race.phase == "countdown" and race.countdownLeft then
		local before = math.ceil(race.countdownLeft)
		race.countdownLeft = race.countdownLeft - dt
		if race.countdownLeft <= 0 then
			-- Green: this car goes and its clock starts now, whatever the other game's delay.
			race.phase = "racing"
			race.elapsed = -race.countdownLeft
			setFrozen(false)
			ui({phase = "go", race = race.id, other = race.other, stake = race.stake})
		elseif math.ceil(race.countdownLeft) ~= before then
			ui({phase = "countdown", race = race.id, other = race.other, stake = race.stake,
				count = math.ceil(race.countdownLeft)})
		end
		return
	end
	if race.phase ~= "racing" then return end
	-- The clock runs on after this car's finish: a race against a traffic car times that car
	-- on it (current()).
	race.elapsed = race.elapsed + dt
	if race.reported then return end
	local veh = playerVehicle()
	local left = veh and race.finish and distance(veh:getPosition(), race.finish) or nil
	if left and left <= race.radius then
		race.reported = true
		report({race = race.id, finished = race.elapsed})
		ui({phase = "finished", race = race.id, other = race.other, elapsed = race.elapsed})
		return
	end
	panelWait = panelWait - dt
	if panelWait <= 0 then
		panelWait = PANEL_EVERY_SECONDS
		ui({phase = "racing", race = race.id, other = race.other, stake = race.stake, elapsed = race.elapsed,
			distance = left and math.floor(left) or nil})
	end
end

function M.onUpdate(dtReal)
	if not race then return end
	updateRace(math.max(0, math.min(1, tonumber(dtReal) or 0)))
end

--- A race event's race, after mileage/raceEvents.lua moved this car to the grid: the
--- same countdown, timing and finish report as a street race, without stakes.
--- info: {id, finish, radius, seconds, prize, racers}
function M.startEventRace(info)
	if type(info) ~= "table" or type(info.id) ~= "string" or not isPoint(info.finish) then return false end
	race = {id = info.id, phase = "countdown", other = "the race event", stake = 0, event = true,
		prize = tonumber(info.prize) or 0, racers = tonumber(info.racers) or 0,
		finish = info.finish, radius = tonumber(info.radius) or 20, countdownLeft = tonumber(info.seconds) or 5}
	setFrozen(true)
	local c = compat()
	if c then c.setNavigationTarget(race.finish) end
	ui({phase = "countdown", race = race.id, other = race.other, stake = 0, count = math.ceil(race.countdownLeft)})
	return true
end

--- A race with a rolling start (a race against a traffic car): the same countdown, timing,
--- finish report and Give up as an event race, but no car is held or moved, so everyone
--- keeps driving through the countdown. info: {id, finish, radius, seconds, other, reward}
function M.startRollingRace(info)
	if type(info) ~= "table" or type(info.id) ~= "string" or not isPoint(info.finish) then return false end
	race = {id = info.id, phase = "countdown", other = type(info.other) == "string" and info.other or "the race",
		stake = 0, rolling = true, reward = tonumber(info.reward) or 0, finish = info.finish,
		radius = tonumber(info.radius) or 20, countdownLeft = tonumber(info.seconds) or 5}
	local c = compat()
	if c then c.setNavigationTarget(race.finish) end
	ui({phase = "countdown", race = race.id, other = race.other, stake = 0, count = math.ceil(race.countdownLeft)})
	return true
end

--- The race under way here, {id, phase, elapsed, finished}, or nil; finished once this
--- car's finish is reported (the phase stays "racing": a race against a traffic car times
--- that car on this clock).
function M.current()
	if not race then return nil end
	return {id = race.id, phase = race.phase, elapsed = race.elapsed, finished = race.reported == true}
end

--- Changes who a rolling race is against and its race reward (a player joined).
--- info: {other, reward}
function M.setRaceInfo(id, info)
	if not race or race.id ~= id or not race.rolling or type(info) ~= "table" then return false end
	if type(info.other) == "string" then race.other = info.other end
	if tonumber(info.reward) then race.reward = tonumber(info.reward) end
	if race.phase == "countdown" and race.countdownLeft then
		ui({phase = "countdown", race = race.id, other = race.other, stake = 0, count = math.ceil(race.countdownLeft)})
	end
	return true
end

--- Ends the race with this id here (an event's result came, or it was called off).
function M.stopRace(id)
	if race and race.id == id then
		endRace()
		-- Takes the countdown, race panel or waiting panel off the screen.
		ui({phase = "clear", race = id})
	end
end

--- Sends the race under way to the prompts app, after a UI reload.
function M.sendState()
	if race then ui({phase = race.phase, race = race.id, other = race.other, stake = race.stake,
		elapsed = race.elapsed}) end
end

function M.onBeamMPServerLeave()
	endRace()
end

function M.onExtensionLoaded()
	if type(AddEventHandler) ~= "function" then
		log("E", logTag, "AddEventHandler unavailable - BeamMP not loaded")
		return
	end
	AddEventHandler("rxMileageRace", rxMileageRace)
	log("I", logTag, "Mileage street races LOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
