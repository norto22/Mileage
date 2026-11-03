--Mileage :: send rate of traffic and parked cars (CLIENT)
--
-- BeamMP sends every car this game owns, traffic and parked cars included, as if a player
-- drove it: its position up to 50 times a second, its lights 15 and its pedals and
-- steering 30 times a second when they change, and the server passes each one to every
-- other player. While the career runs on a server, Mileage's checks sit in front of
-- BeamMP's sends, which BeamMP's vehicle Lua calls by name for each update
-- (positionGE.sendVehiclePosRot, MPElectricsGE.sendElectrics, MPInputsGE.sendInputs):
--
--   * a parked car moving under PARKED_STILL_SPEED sends at most once a second;
--   * driving traffic more than FAR_DISTANCE from every other player's car (their
--     traffic not counted) is "far" and sends its position at most twice a second;
--   * other driving traffic is "near" and sends its position at most 20 times a second,
--     which keeps every gap at half of the 0.1 s for which another game keeps steering a
--     car without an update;
--   * a hidden car sends no position;
--   * lights and inputs of these cars are never dropped: BeamMP sends only what changed,
--     so each car's changed values are merged (the latest value of each kept) and the
--     merged set is sent at the rate in SPACING, a hidden car's once it is shown again;
--   * everything else - the car the player drives, the player's other cars, a parked car
--     that is moving - sends every update, as before.
--
-- Each car's rule is worked out once a second (a still parked car's speed four times a
-- second, so a car that is hit is sent at once), never on each send. If one of BeamMP's
-- functions is missing the log says so once and BeamMP sends it as it always does; if a
-- check fails the update goes through. BeamMP's own files are not changed. Every send
-- BeamMP asks for, and whether it went through, is told to the cost meter
-- (mileage/perfMeter.lua).

local M = {}

local logTag = "mileage.positionRate"

local PARKED_STILL_SPEED = 0.5   -- metres a second
local FAR_DISTANCE = 500         -- metres from every other player's car
local CLASSIFY_EVERY = 1         -- seconds between working out each car's rule
local PARKED_CHECK_EVERY = 0.25  -- seconds between speed checks of still parked cars

-- Seconds between sends of each update by a car's rule; none for a hidden car (its
-- position is dropped, its lights and inputs held until it is shown).
local SPACING = {
	pos = {parked = 1, far = 0.5, near = 0.05},
	elec = {parked = 1, far = 1, near = 0.2},
	inp = {parked = 1, far = 1, near = 0.1},
}

-- BeamMP's send functions: the module's global name, the function and the update kind.
local TARGETS = {
	{global = "positionGE", field = "sendVehiclePosRot", update = "pos",
		missing = "every car's position is sent at BeamMP's own rate"},
	{global = "MPElectricsGE", field = "sendElectrics", update = "elec",
		missing = "traffic's lights are sent at BeamMP's own rate"},
	{global = "MPInputsGE", field = "sendInputs", update = "inp",
		missing = "traffic's pedals and steering are sent at BeamMP's own rate"},
}

-- {module, original, check} by update kind while that BeamMP function is wrapped.
local wraps = {}

-- The rule of each own car under one, by game vehicle id: "parked" | "far" | "near" |
-- "hidden". A car not listed sends every update.
local limited = {}
-- When each car may next send each update: nextDue[update][gameVehicleID] = clock.
local nextDue = {pos = {}, elec = {}, inp = {}}
-- Lights and inputs changed since a car's last send, merged: held[update][gameVehicleID].
local held = {elec = {}, inp = {}}

local clock = 0
local sinceClassify = CLASSIFY_EVERY
local sinceParkedCheck = 0
local failureLogged = false

local function isTraffic(gameVehicleID, veh)
	local enabler = mileageEnabler
	return type(enabler) == "table" and type(enabler.isTrafficCar) == "function"
		and enabler.isTrafficCar(gameVehicleID, veh) == true
end

local function isRemoteTraffic(serverVehicleID)
	local enabler = mileageEnabler
	return type(enabler) == "table" and type(enabler.isRemoteTraffic) == "function"
		and enabler.isRemoteTraffic(serverVehicleID) == true
end

local function farFromAll(pos, others)
	for _, other in ipairs(others) do
		local dx, dy, dz = pos.x - other.x, pos.y - other.y, pos.z - other.z
		if dx * dx + dy * dy + dz * dz <= FAR_DISTANCE * FAR_DISTANCE then return false end
	end
	return true
end

local function isStill(veh)
	return veh:getVelocity():length() < PARKED_STILL_SPEED
end

local function tellMeter(update, isTrafficCar, through)
	local meter = extensions.mileage_perfMeter
	if meter and meter.sent then meter.sent(update, isTrafficCar, through) end
end

-- Works out the rule of every own car.
local function classify()
	local vehicles = MPVehicleGE.getVehicles()
	local playerVehicle = be:getPlayerVehicleID(0)
	local others, own = {}, {}
	for serverVehicleID, entry in pairs(vehicles) do
		local gameVehicleID = entry.gameVehicleID
		local veh = gameVehicleID and gameVehicleID ~= -1 and be:getObjectByID(gameVehicleID)
		if veh then
			if MPVehicleGE.isOwn(gameVehicleID) then
				if gameVehicleID ~= playerVehicle then own[gameVehicleID] = veh end
			elseif veh:getActive() and not isRemoteTraffic(serverVehicleID) then
				table.insert(others, veh:getPosition())
			end
		end
	end
	local rules = {}
	for gameVehicleID, veh in pairs(own) do
		if not veh:getActive() then
			rules[gameVehicleID] = "hidden"
		elseif veh.isParked == "true" then
			-- A parked car that moves was pushed or hit: every update goes through.
			if isStill(veh) then rules[gameVehicleID] = "parked" end
		elseif isTraffic(gameVehicleID, veh) then
			rules[gameVehicleID] = farFromAll(veh:getPosition(), others) and "far" or "near"
		end
	end
	limited = rules
	-- Cars gone from the game keep no times or held updates.
	for _, perUpdate in ipairs({nextDue, held}) do
		for _, byCar in pairs(perUpdate) do
			for gameVehicleID in pairs(byCar) do
				if not be:getObjectByID(gameVehicleID) then byCar[gameVehicleID] = nil end
			end
		end
	end
end

-- A still parked car that starts moving (it was hit) or a hidden car shown again sends
-- every update until the next full check gives it its rule.
local function checkParked()
	for gameVehicleID, kind in pairs(limited) do
		if kind == "parked" or kind == "hidden" then
			local veh = be:getObjectByID(gameVehicleID)
			if not veh or (kind == "parked" and not isStill(veh)) or (kind == "hidden" and veh:getActive()) then
				limited[gameVehicleID] = nil
			end
		end
	end
end

-- true when a car under a rule may send this update now; it then counts as sent. A send
-- is due SPACING after the last one was due, so BeamMP's 50-a-second calls give the
-- spacing's rate on average (0.04 and 0.06 s gaps for 0.05); a car that sent nothing
-- for longer starts again from now.
local function due(update, gameVehicleID, kind)
	local every = SPACING[update][kind]
	if not every then return false end
	local byCar = nextDue[update]
	local nextAt = byCar[gameVehicleID]
	if nextAt and clock < nextAt - 1e-6 then return false end
	if nextAt and clock - nextAt < every then
		byCar[gameVehicleID] = nextAt + every
	else
		byCar[gameVehicleID] = clock + every
	end
	return true
end

--== positions ===============================================================

local function letPositionThrough(gameVehicleID)
	local kind = limited[gameVehicleID]
	local through = not kind or due("pos", gameVehicleID, kind)
	tellMeter("pos", kind ~= nil, through)
	return through
end

local function positionCheck(original)
	return function(data, gameVehicleID, ...)
		local ok, through = pcall(letPositionThrough, gameVehicleID)
		if not ok or through then return original(data, gameVehicleID, ...) end
	end
end

--== lights and inputs =======================================================

-- The text to send now for this call, or nil while it is held. A car with no rule sends
-- at once, together with anything held for it from when it had one.
local function gate(update, data, gameVehicleID)
	local kind = limited[gameVehicleID]
	local pending = held[update][gameVehicleID]
	if not kind and not pending then
		tellMeter(update, false, true)
		return data
	end
	local decoded = jsonDecode(data)
	if type(decoded) ~= "table" then
		tellMeter(update, kind ~= nil, true)
		return data
	end
	pending = pending or {}
	for key, value in pairs(decoded) do pending[key] = value end
	held[update][gameVehicleID] = pending
	local now = not kind or due(update, gameVehicleID, kind)
	tellMeter(update, kind ~= nil, now)
	if not now then return nil end
	held[update][gameVehicleID] = nil
	return jsonEncode(pending)
end

local function mergeCheck(update, original)
	return function(data, gameVehicleID, ...)
		local ok, text = pcall(gate, update, data, gameVehicleID)
		if not ok then return original(data, gameVehicleID, ...) end
		if text then return original(text, gameVehicleID, ...) end
	end
end

-- Sends each held set whose spacing has passed, so the last change of a car is never
-- left waiting for its next one.
local function flushHeld()
	local meter = extensions.mileage_perfMeter
	for update, byCar in pairs(held) do
		local w = wraps[update]
		for gameVehicleID, pending in pairs(byCar) do
			local kind = limited[gameVehicleID]
			if not w then
				byCar[gameVehicleID] = nil
			elseif not kind or due(update, gameVehicleID, kind) then
				byCar[gameVehicleID] = nil
				if meter and meter.flushed then meter.flushed(update) end
				w.original(jsonEncode(pending), gameVehicleID)
			end
		end
	end
end

--== wrapping ================================================================

local function isActive() return next(wraps) ~= nil end

local function clearState()
	limited, nextDue, held = {}, {pos = {}, elec = {}, inp = {}}, {elec = {}, inp = {}}
end

local function unwrap(why)
	if not isActive() then return end
	for _, target in ipairs(TARGETS) do
		local w = wraps[target.update]
		if w and w.module[target.field] == w.check then w.module[target.field] = w.original end
	end
	wraps = {}
	clearState()
	log("D", logTag, "send checks removed (" .. why .. ")")
end

local function wrap()
	local compat = extensions.mileage_compat
	local added = {}
	for _, target in ipairs(TARGETS) do
		local module = rawget(_G, target.global)
		local w = wraps[target.update]
		if not (w and w.module == module and type(module) == "table" and module[target.field] == w.check) then
			-- BeamMP reloaded its module: the old table is no longer used and is left as it is.
			wraps[target.update] = nil
			local original = compat and compat.pickOrWarn(module, target.global, target.field, target.missing)
			if original then
				local check = target.update == "pos" and positionCheck(original) or mergeCheck(target.update, original)
				wraps[target.update] = {module = module, original = original, check = check}
				module[target.field] = check
				added[target.update] = true
			end
		end
	end
	if next(added) == nil then return end
	clearState()
	sinceClassify, sinceParkedCheck, failureLogged = CLASSIFY_EVERY, 0, false
	if added.pos then
		log("I", logTag, string.format("position check active - still parked cars send once a second, " ..
			"traffic over %d m from other players twice a second, other traffic 20 times a second", FAR_DISTANCE))
	end
	if added.elec or added.inp then
		log("I", logTag, "lights and inputs check active - traffic's changes are merged and sent 5 and 10 times " ..
			"a second near players, once a second far away or parked")
	end
end

local function failed(err)
	limited = {}
	if failureLogged then return end
	failureLogged = true
	log("E", logTag, "send check failed, every update is sent: " .. tostring(err))
end

--== hooks ===================================================================

function M.onCareerActive(active)
	local compat = extensions.mileage_compat
	if active and compat and compat.isMPSession() then
		wrap()
	else
		unwrap("career not active")
	end
end

function M.onUpdate(dtReal)
	if not isActive() then return end
	local dt = tonumber(dtReal)
	if not dt or dt < 0 then dt = 0 end
	clock = clock + dt
	sinceClassify = sinceClassify + dt
	sinceParkedCheck = sinceParkedCheck + dt
	if sinceClassify >= CLASSIFY_EVERY then
		sinceClassify, sinceParkedCheck = 0, 0
		local ok, err = pcall(classify)
		if not ok then failed(err) end
	elseif sinceParkedCheck >= PARKED_CHECK_EVERY then
		sinceParkedCheck = 0
		local ok, err = pcall(checkParked)
		if not ok then failed(err) end
	end
	if next(held.elec) or next(held.inp) then
		local ok, err = pcall(flushHeld)
		if not ok then
			held = {elec = {}, inp = {}}
			failed(err)
		end
	end
end

function M.onBeamMPServerLeave()
	unwrap("left the server")
end

function M.onExtensionLoaded()
	log("I", logTag, "Mileage position rate LOADED")
end

function M.onExtensionUnloaded()
	unwrap("unloaded")
	log("I", logTag, "Mileage position rate UNLOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
