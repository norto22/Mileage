--Mileage :: race events the server owner runs (CLIENT)
--
-- The owner schedules a race event (see the Events section of the server plugin). The
-- server tells every game ahead of time (rxMileageEvent "announce"); the player joins or
-- leaves from the prompts app (join, leave). At the start the server gives each joined
-- game a grid pose: this moves the car there with the game's safe teleport and hands the
-- race to mileage/streetRace.lua, which counts down, times it from its own green and
-- reports the finish. For a random finish the server asks one joined game for a point on
-- the game's road map 1.5 to 4 km from the start ("pickFinish"). The prompts app shows
-- every phase (guihook MileageEvent).

local M = {}

local logTag = "mileage.raceEvents"

-- The last event message, for the prompts app after a UI reload.
local current = nil

local function compat()
	local c = extensions.mileage_compat
	if type(c) == "table" then return c end
	return nil
end

local function streetRace()
	local race = extensions.mileage_streetRace
	if type(race) == "table" then return race end
	return nil
end

local function isPoint(p)
	return type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
end

-- A road node's position as a plain {x, y, z}, or nil. The game gives each one as its own
-- vector (cdata), not a table, and reading a field an FFI value lacks raises, hence pcall.
local function nodePoint(pos)
	local kind = type(pos)
	if kind ~= "table" and kind ~= "cdata" and kind ~= "userdata" then return nil end
	local ok, x, y, z = pcall(function() return pos.x, pos.y, pos.z end)
	if not ok or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
	return {x = x, y = y, z = z}
end

local function report(fields)
	TriggerServerEvent("mileageRaceReport", jsonEncode(fields))
end

-- How many random road points pickRoadPoint offers to accept before it gives up.
local PICK_TRIES = 10

--- A random road node between min and max metres (flat) from from: {pos = {x, y, z},
--- node = its name in the game's road map}, or nil when there is none. accept(candidate),
--- when given, is asked about up to PICK_TRIES random candidates and the first it takes is
--- returned; race events pass none, a race against a traffic car passes its road route check.
function M.pickRoadPoint(from, min, max, accept)
	local c = compat()
	local nodes = c and c.getMapNodes()
	if type(nodes) ~= "table" or not isPoint(from) then return nil end
	local low, high = tonumber(min) or 1500, tonumber(max) or 4000
	local candidates = {}
	for name, node in pairs(nodes) do
		local pos = type(node) == "table" and nodePoint(node.pos)
		if pos then
			local dx, dy = pos.x - from.x, pos.y - from.y
			local metres = math.sqrt(dx * dx + dy * dy)
			if metres >= low and metres <= high then
				table.insert(candidates, {pos = pos, node = name})
			end
		end
	end
	for _ = 1, PICK_TRIES do
		if #candidates == 0 then return nil end
		local i = math.random(#candidates)
		local candidate = candidates[i]
		if type(accept) ~= "function" or accept(candidate) then return candidate end
		-- Not offered again.
		candidates[i] = candidates[#candidates]
		candidates[#candidates] = nil
	end
	return nil
end

-- A random road node between min and max metres from start, sent to the server.
local function pickFinish(message)
	local picked = M.pickRoadPoint(message.start, message.min, message.max)
	if not picked then
		log("W", logTag, "no road point within the event's distance; the server uses its own finish")
		return
	end
	report({race = message.id, finish = picked.pos})
end

-- Moves this car to its place on the grid and starts the race here.
local function startAtGrid(message)
	local pose = message.pose
	local c, race = compat(), streetRace()
	if type(pose) ~= "table" or not isPoint(pose.pos) or not isPoint(pose.dir) or not isPoint(pose.up) then return end
	local why, veh = nil, nil
	if race then why, veh = race.eligibility() end
	if not race or not c or why or not veh then
		log("W", logTag, "not able to race at the event's start (" .. tostring(why) .. "); leaving the event")
		guihooks.trigger("toastrMsg", {type = "warning", title = "Race event", msg = why or "Racing is not available.",
			config = {timeOut = 4000}})
		report({race = message.id, gaveUp = true})
		return
	end
	local rot = quatFromDir(vec3(pose.dir.x, pose.dir.y, pose.dir.z), vec3(pose.up.x, pose.up.y, pose.up.z))
	if not c.safeTeleport(veh, vec3(pose.pos.x, pose.pos.y, pose.pos.z), rot) then
		report({race = message.id, gaveUp = true})
		return
	end
	race.startEventRace({id = message.id, finish = message.finish, radius = message.radius,
		seconds = message.seconds})
end

local function rxMileageEvent(data)
	local message = jsonDecode(data)
	if type(message) ~= "table" or type(message.id) ~= "string" then return end
	local phase = message.phase
	if phase == "pickFinish" then
		pickFinish(message)
		return
	end
	if phase == "start" then
		startAtGrid(message)
	elseif phase == "result" or phase == "over" or phase == "cancelled" then
		local race = streetRace()
		if race then race.stopRace(message.id) end
	end
	current = message
	guihooks.trigger("MileageEvent", message)
end

--- Joins the announced event.
function M.join(id)
	if type(id) ~= "string" then return false end
	TriggerServerEvent("mileageOfferAnswer", jsonEncode({id = id, accept = true}))
	return true
end

--- Leaves the announced event, or turns its invitation down.
function M.leave(id)
	if type(id) ~= "string" then return false end
	TriggerServerEvent("mileageOfferAnswer", jsonEncode({id = id, accept = false}))
	return true
end

function M.sendState()
	if current then guihooks.trigger("MileageEvent", current) end
end

--- Whether the server last said this player joined an event that has not ended. Once it
--- starts the race itself (mileage/streetRace.lua) holds the player; a message without
--- youJoined, from an older server, reads as not joined.
function M.signedUp()
	return current ~= nil and current.youJoined == true and current.phase ~= "result" and current.phase ~= "over"
		and current.phase ~= "cancelled"
end

function M.onBeamMPServerLeave()
	current = nil
end

function M.onExtensionLoaded()
	if type(AddEventHandler) ~= "function" then
		log("E", logTag, "AddEventHandler unavailable - BeamMP not loaded")
		return
	end
	AddEventHandler("rxMileageEvent", rxMileageEvent)
	log("I", logTag, "Mileage race events LOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
