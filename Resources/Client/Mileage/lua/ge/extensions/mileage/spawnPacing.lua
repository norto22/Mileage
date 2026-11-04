--Mileage :: join pacing (CLIENT)
--
-- When a player joins, BeamMP queues each of their cars (traffic included) and, once
-- this player has slowed down for a few seconds, builds every waiting car in one frame:
-- one long freeze on every game. While the career runs on a server, Mileage steps in
-- front of BeamMP's frame function (MPVehicleGE.onPreRender) and lets BeamMP's queue
-- hold one waiting car at a time:
--
--   * BeamMP's own rule still decides when building starts (each player's BeamMP queue
--     settings); only one waiting car is in the queue when it does;
--   * once BeamMP has built that car, the next waiting car is built every PACE_SECONDS
--     (MPVehicleGE.applyPlayerQueues), until none waits;
--   * edits of cars already built, and this player's own cars, go through as before.
--
-- The other cars' queued spawns are only moved aside for the length of BeamMP's call
-- and put back straight after, so a car removed while it waits is never built. On any
-- error every queued spawn is put back, BeamMP builds as it does today, and pacing stays
-- off until the next career start. The game caches each hook's functions, so the cache
-- is refreshed after the wrap is put in place and after it is taken away.
--
-- BeamMP draws a car's marker in the same call, coloured from the queued spawn: a car
-- whose spawn is moved aside would get the magenta "unknown" marker. So for the call a
-- held car is also marked as built (BeamMP draws it no marker) with its name tag lifted
-- the metre BeamMP lifts it above a marker, and once everything is put back Mileage
-- draws its marker in BeamMP's queued colour. BeamMP's queue count (UI.updateQueue) would
-- miss the held cars too, so while any car is held a count BeamMP sends is held back, and
-- once every car is back it is sent once, counted the way BeamMP counts it.

local M = {}

local logTag = "mileage.spawnPacing"

local PACE_SECONDS = 0.25

-- {module, original, check} while BeamMP's frame function is wrapped.
local wrapped = nil
local disabled = false
-- True from BeamMP building the first waiting car until none waits.
local releasing = false
local sinceRelease = 0
-- The waiting car left in BeamMP's queue on the last frame.
local kept = nil
-- Queued spawns moved aside during BeamMP's call: serverVehicleID -> {entry, queue, edit,
-- spawned, position, lifted}; lifted is the name-tag position swapped in, when it was.
local aside = {}
-- One reused lifted position per held car, so a held car costs no new vector each frame.
local liftedBySid = {}
-- The colour this frame's held cars are drawn in, or nil when none are drawn.
local heldColour = nil
-- The held cars Mileage draws a marker for this frame, collected before the put-back.
local heldIds, heldEntries, heldCount = {}, {}, 0
local warnedNoMarkers = false
-- The last queued colour built, by BeamMP's colour setting.
local colourHex, colourValue = nil, nil
-- While held cars are aside: BeamMP's UI module, its own updateQueue, and whether BeamMP
-- sent a count meanwhile.
local countUi, countReal, countSent = nil, nil, false

local function recordCount() countSent = true end

-- From now until releaseCount, a count BeamMP sends is only noted.
local function holdCount()
	if countUi then return end
	local ui = rawget(_G, "UI")
	if type(ui) ~= "table" or type(ui.updateQueue) ~= "function" then return end
	countUi, countReal, countSent = ui, ui.updateQueue, false
	ui.updateQueue = recordCount
end

-- Puts BeamMP's updateQueue back; returns it when BeamMP sent a count meanwhile.
local function releaseCount()
	local ui, real, sent = countUi, countReal, countSent
	if not ui then return nil end
	countUi, countReal, countSent = nil, nil, false
	if ui.updateQueue == recordCount then ui.updateQueue = real end
	return sent and real or nil
end

-- BeamMP's getQueueCounts: queued spawns, queued edits and, with queued players
-- highlighted, the players who own them.
local function queueCounts(vehicles)
	local spawns, edits, owners = 0, 0, {}
	local s = rawget(_G, "settings")
	local highlight = type(s) == "table" and type(s.getValue) == "function" and s.getValue("highlightQueuedPlayers")
	for _, entry in pairs(vehicles) do
		if type(entry) == "table" then
			if entry.spawnQueue then spawns = spawns + 1 end
			if entry.editQueue then edits = edits + 1 end
			if highlight and (entry.spawnQueue or entry.editQueue) then owners[entry.ownerID] = true end
		end
	end
	return spawns, edits, owners
end

local function refreshHookCache()
	local ext = extensions
	if type(ext) == "table" and type(ext.hookUpdate) == "function" then pcall(ext.hookUpdate, "onPreRender") end
end

local function tellMeter()
	local meter = extensions.mileage_perfMeter
	if meter and meter.built then meter.built() end
end

-- Other players' cars waiting to be built, in a fixed order.
local function waitingRemote(vehicles)
	local list = {}
	for serverVehicleID, entry in pairs(vehicles) do
		if type(entry) == "table" and entry.spawnQueue and not entry.isLocal then
			table.insert(list, serverVehicleID)
		end
	end
	table.sort(list, function(a, b) return tostring(a) < tostring(b) end)
	return list
end

-- BeamMP's queued marker colour, or nil when BeamMP would draw held cars no marker
-- (markers off, or queued markers hidden) or Mileage has nothing to draw one with.
local function queuedMarkerColour()
	local s = rawget(_G, "settings")
	if type(s) ~= "table" or type(s.getValue) ~= "function" then return nil end
	if not s.getValue("enableBlobs") or not s.getValue("showBlobQueued") then return nil end
	local helpers, colorF = rawget(_G, "MPHelpers"), rawget(_G, "ColorF")
	if type(helpers) ~= "table" or type(helpers.hex2rgb) ~= "function" or colorF == nil
			or rawget(_G, "debugDrawer") == nil or type(rawget(_G, "vec3")) ~= "function" then
		if not warnedNoMarkers then
			warnedNoMarkers = true
			log("W", logTag, "BeamMP's helpers or the game's debug drawer are missing: no queued markers " ..
				"are drawn for cars waiting to be built")
		end
		return nil
	end
	local hex = s.getValue("blobColorQueued")
	if colourValue == nil or colourHex ~= hex then
		local rgb = helpers.hex2rgb(hex)
		colourHex, colourValue = hex, colorF(rgb[1], rgb[2], rgb[3], 127 / 255)
	end
	return colourValue
end

-- The held car's position one metre up, where BeamMP puts a name tag above a marker.
local function liftedPosition(serverVehicleID, position)
	local lifted = liftedBySid[serverVehicleID]
	if lifted == nil then
		lifted = vec3(position.x, position.y, position.z + 1)
		liftedBySid[serverVehicleID] = lifted
	else
		lifted.x, lifted.y, lifted.z = position.x, position.y, position.z + 1
	end
	return lifted
end

-- Leaves the first waiting car in BeamMP's queue and moves the others aside; returns it.
-- A waiting car's queued edit moves with its spawn: BeamMP applies a car's spawn and then
-- its edit, and an edit applied to a car not built yet is lost. A held car not built yet
-- is marked as built for the call, so BeamMP draws it no magenta marker, and its name
-- tag is lifted when Mileage draws the marker under it.
local function keepOne(vehicles)
	local list = waitingRemote(vehicles)
	if #list < 2 then
		if next(liftedBySid) then liftedBySid = {} end
		return list[1]
	end
	heldColour = queuedMarkerColour()
	for i = 2, #list do
		local serverVehicleID = list[i]
		local entry = vehicles[serverVehicleID]
		local moved = {entry = entry, queue = entry.spawnQueue, edit = entry.editQueue,
			spawned = entry.isSpawned, position = entry.position}
		aside[serverVehicleID] = moved
		entry.spawnQueue, entry.editQueue = nil, nil
		if not moved.spawned then
			entry.isSpawned = true
			if heldColour and moved.position then
				moved.lifted = liftedPosition(serverVehicleID, moved.position)
				entry.position = moved.lifted
			end
		end
	end
	return list[1]
end

-- Puts every moved spawn and edit back on its car, unless the car is gone or has a new
-- one. With no vehicle list (it failed) everything goes back: a removed car's entry is no
-- longer BeamMP's, so its spawn is never built. The built mark and the name-tag position
-- go back on every held car, removed or not, unless BeamMP changed them meanwhile.
local function putBack(vehicles)
	for serverVehicleID, moved in pairs(aside) do
		local entry = moved.entry
		local present = not vehicles or vehicles[serverVehicleID] == entry
		if present then
			if entry.spawnQueue == nil then entry.spawnQueue = moved.queue end
			if entry.editQueue == nil then entry.editQueue = moved.edit end
		end
		if not moved.spawned and entry.isSpawned == true then entry.isSpawned = moved.spawned end
		if moved.lifted and entry.position == moved.lifted then entry.position = moved.position end
	end
	aside = {}
end

-- Before the put-back: the held cars this frame's markers are drawn for.
local function collectHeld()
	heldCount = 0
	if not heldColour then return end
	for serverVehicleID, moved in pairs(aside) do
		if not moved.spawned then
			heldCount = heldCount + 1
			heldIds[heldCount], heldEntries[heldCount] = serverVehicleID, moved.entry
		end
	end
end

-- After the put-back: each held car still waiting gets the marker BeamMP would have drawn,
-- at its place, radius 1, in the queued colour.
local function drawHeld(vehicles)
	local drawer = rawget(_G, "debugDrawer")
	for i = 1, heldCount do
		local serverVehicleID, entry = heldIds[i], heldEntries[i]
		heldEntries[i] = nil
		if vehicles and drawer and vehicles[serverVehicleID] == entry and entry.spawnQueue
				and not entry.isSpawned and entry.position then
			drawer:drawSphere(entry.position, 1, heldColour, true)
		end
	end
	heldCount = 0
end

local function wasBuilt(vehicles, serverVehicleID)
	local entry = serverVehicleID and vehicles[serverVehicleID]
	return entry ~= nil and entry ~= false and entry.spawnQueue == nil
end

-- After BeamMP's own call: notices the first car built, then builds one more every
-- PACE_SECONDS while any waits.
local function afterFrame(dt)
	local module = wrapped.module
	local vehicles = module.getVehicles()
	if kept and wasBuilt(vehicles, kept) then
		tellMeter()
		releasing, sinceRelease, kept = true, 0, nil
		return
	end
	kept = nil
	if not releasing then return end
	sinceRelease = sinceRelease + dt
	if sinceRelease < PACE_SECONDS - 1e-6 then return end
	local nextCar = keepOne(vehicles)
	if not nextCar then
		putBack(vehicles)
		releasing = false
		return
	end
	sinceRelease = 0
	if next(aside) then holdCount() end
	local ok, err = pcall(module.applyPlayerQueues, vehicles[nextCar].ownerID)
	putBack(vehicles)
	if not ok then error(err, 0) end
	if wasBuilt(vehicles, nextCar) then tellMeter() end
end

local function getVehiclesSafely()
	local module = wrapped and wrapped.module
	if not module or type(module.getVehicles) ~= "function" then return nil end
	local ok, vehicles = pcall(module.getVehicles)
	return ok and type(vehicles) == "table" and vehicles or nil
end

-- Lets BeamMP build every car still waiting, as it does without Mileage. BeamMP's own
-- rule no longer would: it stopped waiting when it built the first car.
local function buildAllWaiting()
	local vehicles = getVehiclesSafely()
	if vehicles and #waitingRemote(vehicles) == 0 then return end
	local apply = wrapped.module.applyQueuedEvents
	if type(apply) == "function" then pcall(apply) end
end

-- Once every car is back: the count BeamMP sent while cars were held, sent for real.
local function sendHeldCount(vehicles)
	local real = releaseCount()
	if real and vehicles then real(queueCounts(vehicles)) end
end

-- A car kept in BeamMP's queue this frame may have been built before the failure, which
-- stops BeamMP waiting too, so the cars left are built as well.
local function stopPacing(err)
	local vehicles = getVehiclesSafely()
	putBack(vehicles)
	heldCount, liftedBySid = 0, {}
	pcall(sendHeldCount, vehicles)
	local keptBuilt = kept and (not vehicles or wasBuilt(vehicles, kept))
	if releasing or keptBuilt then buildAllWaiting() end
	releasing, kept = false, nil
	if err then
		disabled = true
		log("E", logTag, "join pacing failed, BeamMP builds joining cars at once until the next career start: " ..
			tostring(err))
	end
end

local function prepare()
	kept = keepOne(wrapped.module.getVehicles())
	if next(aside) then holdCount() end
end

local function makeCheck(original)
	return function(dt, ...)
		if disabled then return original(dt, ...) end
		kept = nil
		local ok, err = pcall(prepare)
		if not ok then
			stopPacing(err)
			return original(dt, ...)
		end
		local okOriginal, originalErr = pcall(original, dt, ...)
		local vehicles = getVehiclesSafely()
		collectHeld()
		putBack(vehicles)
		if not okOriginal then
			stopPacing(originalErr)
			error(originalErr, 0)
		end
		local okDraw, drawErr = pcall(drawHeld, vehicles)
		if not okDraw then
			stopPacing(drawErr)
			return
		end
		local okAfter, afterErr = pcall(afterFrame, tonumber(dt) or 0)
		if not okAfter then
			stopPacing(afterErr)
			return
		end
		-- BeamMP's vehicle list is one table for the session, so this frame's read still holds.
		local okCount, countErr = pcall(sendHeldCount, vehicles)
		if not okCount then stopPacing(countErr) end
	end
end

local function unwrap(why)
	if not wrapped then return end
	stopPacing(nil)
	if wrapped.module.onPreRender == wrapped.check then
		wrapped.module.onPreRender = wrapped.original
		refreshHookCache()
	end
	wrapped = nil
	log("D", logTag, "join pacing removed (" .. why .. ")")
end

local function wrap()
	local module = rawget(_G, "MPVehicleGE")
	if wrapped and wrapped.module == module and module.onPreRender == wrapped.check then return end
	-- BeamMP reloaded its module: the old table is no longer used and is left as it is.
	wrapped = nil
	local compat = extensions.mileage_compat
	local consequence = "joining players' cars are built all at once"
	local original = compat and compat.pickOrWarn(module, "MPVehicleGE", "onPreRender", consequence)
	local hasQueues = compat and compat.pickOrWarn(module, "MPVehicleGE", "applyPlayerQueues", consequence)
	local hasList = compat and compat.pickOrWarn(module, "MPVehicleGE", "getVehicles", consequence)
	if not (original and hasQueues and hasList) then return end
	local check = makeCheck(original)
	wrapped = {module = module, original = original, check = check}
	module.onPreRender = check
	releasing, sinceRelease, kept, aside = false, 0, nil, {}
	refreshHookCache()
	log("I", logTag, string.format("join pacing active - another player's cars are built one every %.2f s",
		PACE_SECONDS))
end

--== hooks ===================================================================

function M.onCareerActive(active)
	local compat = extensions.mileage_compat
	if active and compat and compat.isMPSession() then
		disabled = false
		wrap()
	else
		unwrap("career not active")
	end
end

function M.onBeamMPServerLeave()
	unwrap("left the server")
end

function M.onExtensionLoaded()
	log("I", logTag, "Mileage join pacing LOADED")
end

function M.onExtensionUnloaded()
	unwrap("unloaded")
	log("I", logTag, "Mileage join pacing UNLOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
