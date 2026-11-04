--Mileage :: drag race money (CLIENT)
--
-- The server decides each two-player drag run itself and pays its winner (see the Drag
-- money section of the server plugin). The strip's leader tells it who is racing and when
-- the tree went green (mileage/dragLobby.lua); this game tells it about its own car only:
--
--   mileageDragStaged  {run}, once this car is staged in the run
--   mileageDragResult  {run, outcome = "finished", winTime, dial} when this car crosses the
--                      end line, winTime being the game's own winning time (the run's time
--                      plus the reaction), or {run, outcome = "jumped"} once, when the game
--                      disqualified this car
--
-- A run the game takes off the screen after its green, before this car finished (the
-- other racer or the leader left), is still watched: when the car comes within
-- TORN_DOWN_RADIUS of its lane's end line, inside WATCH_SECONDS of this game's own green,
-- the finish is reported timed from that green. The game's timers are gone by then, so it
-- carries no reaction time; it only has to beat a racer who left.
--
-- The server's drag race cards (rxMileageDragRace) go to the Mileage prompts app as the
-- guihook MileageDragRace. Called from the UI: mileage_dragMoney.callOff(), .sendState().

local M = {}

local logTag = "mileage.dragMoney"

local TORN_DOWN_RADIUS = 20
local WATCH_SECONDS = 70

-- This player's run: {run, strip, lane, staged, greenAt, reported}.
local current = nil
-- The last card the server sent, for a UI reload, and the staked race it is about.
local lastCard = nil

local function send(event, message)
	if type(TriggerServerEvent) == "function" then TriggerServerEvent(event, jsonEncode(message)) end
end

local function now()
	return os.clockhp()
end

local function localPlayerId()
	local t = mileage_dragTransport
	return t and t.bridge and t.bridge.getLocalPlayerId and t.bridge.getLocalPlayerId() or nil
end

-- The run this game has on screen, when this player races in its heat.
local function activeRun()
	local t = mileage_dragTransport
	local active = t and t.getLocalClientActiveRace and t.getLocalClientActiveRace()
	if type(active) ~= "table" or type(active.id) ~= "string" then return nil end
	local core = gameplay_drag_core
	local raceState = core and core.getRaceState and core.getRaceState(active.id)
	local queue = raceState and raceState.queue
	local slot = type(queue) == "table" and queue[raceState.currentPairIndex or 1]
	if type(slot) ~= "table" then return nil end
	local own = localPlayerId()
	for _, playerId in pairs(slot) do
		if playerId == own then return active end
	end
	return nil
end

-- This player's own racer in the game's drag data, with the data.
local function ownRacer()
	local core = gameplay_drag_core
	local data = core and core.getData and core.getData()
	local vehId = be:getPlayerVehicleID(0)
	if not data or type(data.racers) ~= "table" or not vehId or vehId == -1 then return nil, data end
	return data.racers[vehId], data
end

local function disqualified(racer)
	return racer.isDisqualified == true or racer.isDesqualified == true
end

local function timerValue(racer, id)
	local timer = type(racer.timers) == "table" and racer.timers[id]
	if type(timer) == "table" and type(timer.value) == "number" then return timer.value end
	return nil
end

-- The value the game's own winner rule ranks this car by.
local function winTimeOf(racer, data)
	local times = gameplay_drag_times
	if type(times) == "table" and type(times.getImportantTimerValueForWin) == "function" then
		local ok, value = pcall(times.getImportantTimerValueForWin, racer, data)
		if ok and type(value) == "number" then return value end
	end
	return timerValue(racer, data.importantTimerId or "time_1_4")
end

local function endLineOf(run)
	local lobby = mileage_dragLobby
	local data = lobby and lobby.resolveStripData and run.strip and lobby.resolveStripData(run.strip)
	local lane = data and data.strip and data.strip.lanes and data.strip.lanes[run.lane]
	local waypoint = lane and lane.waypoints and lane.waypoints.endLine
	local pos = waypoint and waypoint.transform and waypoint.transform.position
	return pos and vec3(pos) or nil
end

local function report(fields)
	current.reported = true
	fields.run = current.run
	send("mileageDragResult", fields)
end

local function reportJumped()
	report({outcome = "jumped"})
	log("I", logTag, "jumped the start in run " .. tostring(current.run) .. " - told the server")
end

--- The game's drag racing: a racer's car crossed the end line.
function M.dragRaceEndLineReached(vehId)
	if not current or current.reported or vehId == nil or vehId ~= be:getPlayerVehicleID(0) then return end
	if MPVehicleGE and type(MPVehicleGE.isOwn) == "function" and not MPVehicleGE.isOwn(vehId) then return end
	local active = activeRun()
	if not active or active.id ~= current.run then return end
	local racer, data = ownRacer()
	if type(racer) ~= "table" then return end
	if disqualified(racer) then
		reportJumped()
		return
	end
	local winTime = winTimeOf(racer, data)
	if not winTime or winTime <= 0 then return end
	report({outcome = "finished", winTime = winTime, dial = timerValue(racer, "dial") or 0})
end

-- The run is on screen: staging, the green and a jump start.
local function followRun()
	local racer = ownRacer()
	if type(racer) ~= "table" then return end
	local phases = racer.phases
	if not current.staged and not current.greenAt and type(phases) == "table" and type(phases[1]) == "table"
			and phases[1].completed then
		current.staged = true
		send("mileageDragStaged", {run = current.run})
	end
	if not current.greenAt then
		local gm = multiplayer_gamemodes_drag_drag
		local startedAt = gm and gm.getRaceStartTime and gm.getRaceStartTime(current.run)
		if startedAt then current.greenAt = type(startedAt) == "number" and startedAt or now() end
	end
	if not current.reported and disqualified(racer) then reportJumped() end
end

-- The run went from the screen after its green, before this car finished: watch for it at
-- the end line. True while there is still something to watch for.
local function watchTornDown()
	if current.reported or not current.greenAt then return false end
	local elapsed = now() - current.greenAt
	if elapsed > WATCH_SECONDS then return false end
	local finish = endLineOf(current)
	local vehId = be:getPlayerVehicleID(0)
	local veh = finish and vehId and vehId ~= -1 and be:getObjectByID(vehId)
	if not veh then return true end
	if finish:distance(veh:getPosition()) <= TORN_DOWN_RADIUS then
		log("I", logTag, string.format("finished run %s after it was called off, %.2f s from the green",
			tostring(current.run), elapsed))
		report({outcome = "finished", winTime = elapsed, dial = 0})
		return false
	end
	return true
end

function M.onUpdate()
	local active = activeRun()
	if active and (not current or current.run ~= active.id) then
		local lobby = mileage_dragLobby
		current = {run = active.id, lane = active.lane,
			strip = lobby and lobby.stripIdForRace and lobby.stripIdForRace(active.id) or nil}
	end
	if not current then return end
	if active then
		followRun()
	elseif not watchTornDown() then
		current = nil
	end
end

--- Calls off the held drag race (before its run's green, both stakes come back).
function M.callOff()
	local race = lastCard and lastCard.race
	if type(race) ~= "string" then return false end
	send("mileageDragCallOff", {race = race})
	return true
end

--- Sends the last drag race card to the prompts app, after a UI reload.
function M.sendState()
	if lastCard then guihooks.trigger("MileageDragRace", lastCard) end
end

local function rxMileageDragRace(data)
	local card = jsonDecode(data)
	if type(card) ~= "table" then return end
	lastCard = card
	guihooks.trigger("MileageDragRace", card)
end

function M.onBeamMPServerLeave()
	current, lastCard = nil, nil
end

function M.onExtensionLoaded()
	if type(AddEventHandler) ~= "function" then
		log("E", logTag, "AddEventHandler unavailable - BeamMP not loaded")
		return
	end
	AddEventHandler("rxMileageDragRace", rxMileageDragRace)
	log("I", logTag, "Mileage drag money LOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
