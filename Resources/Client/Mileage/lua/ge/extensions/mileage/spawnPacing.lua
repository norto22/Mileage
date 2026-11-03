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
-- Queued spawns moved aside during BeamMP's call: serverVehicleID -> {entry, queue}.
local aside = {}

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

-- Leaves the first waiting car in BeamMP's queue and moves the others aside; returns it.
local function keepOne(vehicles)
	local list = waitingRemote(vehicles)
	for i = 2, #list do
		local entry = vehicles[list[i]]
		aside[list[i]] = {entry = entry, queue = entry.spawnQueue}
		entry.spawnQueue = nil
	end
	return list[1]
end

-- Puts every moved spawn back on its car, unless the car is gone or has a new one. With
-- no vehicle list (it failed) every spawn goes back: a removed car's entry is no longer
-- BeamMP's, so its spawn is never built.
local function putBack(vehicles)
	for serverVehicleID, moved in pairs(aside) do
		local present = not vehicles or vehicles[serverVehicleID] == moved.entry
		if present and moved.entry.spawnQueue == nil then
			moved.entry.spawnQueue = moved.queue
		end
	end
	aside = {}
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

local function stopPacing(err)
	putBack(getVehiclesSafely())
	if releasing then buildAllWaiting() end
	releasing, kept = false, nil
	if err then
		disabled = true
		log("E", logTag, "join pacing failed, BeamMP builds joining cars at once until the next career start: " ..
			tostring(err))
	end
end

local function makeCheck(original)
	return function(dt, ...)
		if disabled then return original(dt, ...) end
		local ok, err = pcall(function() kept = keepOne(wrapped.module.getVehicles()) end)
		if not ok then
			stopPacing(err)
			return original(dt, ...)
		end
		local okOriginal, originalErr = pcall(original, dt, ...)
		putBack(getVehiclesSafely())
		if not okOriginal then
			stopPacing(originalErr)
			error(originalErr, 0)
		end
		local okAfter, afterErr = pcall(afterFrame, tonumber(dt) or 0)
		if not okAfter then stopPacing(afterErr) end
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
