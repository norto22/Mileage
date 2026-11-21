--Mileage :: send rate of traffic and parked cars (CLIENT)
--
-- BeamMP sends every car this game owns, traffic and parked cars included, as if a player
-- drove it: its position up to 50 times a second, its lights 15 and its pedals and
-- steering 30 times a second when they change, its engine and powertrain when they
-- change, and the server passes each one to every other player. While the career runs
-- on a server, Mileage's checks sit in front of BeamMP's sends, which BeamMP's vehicle
-- Lua calls by name for each update (positionGE.sendVehiclePosRot,
-- MPElectricsGE.sendElectrics, MPInputsGE.sendInputs, MPPowertrainGE.sendEngineData,
-- MPPowertrainGE.sendLivePowertrain, MPPowertrainGE.sendHydroBeamData,
-- nodesGE.sendBreakGroups and nodesGE.sendControllerData):
--
--   * a parked car moving under PARKED_STILL_SPEED sends at most once a second;
--   * driving traffic more than FAR_DISTANCE from every other player's car (their
--     traffic not counted) is "far" and sends its position at most twice a second;
--   * other driving traffic is "near" and sends its position at most 20 times a second,
--     which keeps every gap at half of the 0.1 s for which another game keeps steering a
--     car without an update;
--   * a hidden car sends no position;
--   * lights, inputs, engine, powertrain, hydros, break groups and controller data of
--     these cars are never dropped: BeamMP sends only what changed, so each car's changed
--     values are merged (the latest value of each kept, every break group kept) and the
--     merged set is sent at the rate in SPACING, a hidden car's once it is shown again;
--   * everything else - the car the player drives, the player's other cars, a parked car
--     that is moving - sends every update, as before.
--
-- BeamMP also asks every own car for each update many times a second (its ticks:
-- positionGE.tick 50 times, MPInputsGE.tick 30, nodesGE, MPElectricsGE and MPControllerGE
-- 15, MPPowertrainGE 10), and each car's vehicle Lua works out the answer. Mileage's
-- checks sit around these ticks too: a still parked car is asked once a second for each
-- kind, so what it answers is sent as it comes; a hidden car is not asked at all; every
-- other car is asked as BeamMP asks it. A tick that no longer reads BeamMP's list of own
-- cars is put back after one line in the log.
--
-- Each car's rule is worked out once a second (a still parked car's speed four times a
-- second, so a car that is hit is sent at once), never on each send. If one of BeamMP's
-- functions is missing the log says so once and BeamMP sends it as it always does; if a
-- check fails the update goes through. BeamMP's own files are not changed. Every send of
-- a position, lights, inputs, engine or powertrain BeamMP asks for, and whether it went
-- through, is told to the cost meter (mileage/perfMeter.lua); hydros, break groups and
-- controller data are not counted.

local M = {}

local logTag = "mileage.positionRate"

local PARKED_STILL_SPEED = 0.5   -- metres a second
local FAR_DISTANCE = 500         -- metres from every other player's car
local CLASSIFY_EVERY = 1         -- seconds between working out each car's rule
-- Six checks go over every car once a second. Each runs at its own point in the second,
-- counted from the first frame after the career start, so no frame runs two of them:
-- these rules at 0 s, the enabler's traffic marks at 1/6 s, far traffic (farTraffic.lua)
-- at 2/6 s, the enabler's ghost settings at 3/6 s, the cost meter's car count
-- (perfMeter.lua) at 4/6 s and the damage roles (damageSync.lua) at 5/6 s. A check's
-- timer is left empty at the career start and set on that first frame.
local CLASSIFY_AT = 0
local PARKED_CHECK_EVERY = 0.25  -- seconds between speed checks of still parked cars

-- Seconds between sends of each update by a car's rule; none for a hidden car (its
-- position is dropped, its other updates held until it is shown). eng is the engine's
-- ignition, stall and starter, ptr its powertrain device modes (BeamMP sends both only
-- when they change).
local SPACING = {
	pos = {parked = 1, far = 0.5, near = 0.05},
	elec = {parked = 1, far = 1, near = 0.2},
	inp = {parked = 1, far = 1, near = 0.1},
	eng = {parked = 1, far = 1, near = 0.2},
	ptr = {parked = 1, far = 1, near = 0.2},
	hyd = {parked = 1, far = 1, near = 0.2},
	brk = {parked = 1, far = 1, near = 0.2},
	ctl = {parked = 1, far = 1, near = 0.2},
}
-- The updates whose changes are merged and held, never dropped.
local MERGED = {"elec", "inp", "eng", "ptr", "hyd", "brk", "ctl"}
local UPDATES = {"pos", "elec", "inp", "eng", "ptr", "hyd", "brk", "ctl"}

-- BeamMP's send functions: the module's global name, the function, the update kind and
-- the kind the cost meter counts it under (none: not counted); merge is how held changes
-- are put together (fields when not given).
local TARGETS = {
	{global = "positionGE", field = "sendVehiclePosRot", update = "pos", meter = "pos",
		missing = "every car's position is sent at BeamMP's own rate"},
	{global = "MPElectricsGE", field = "sendElectrics", update = "elec", meter = "elec",
		missing = "traffic's lights are sent at BeamMP's own rate"},
	{global = "MPInputsGE", field = "sendInputs", update = "inp", meter = "inp",
		missing = "traffic's pedals and steering are sent at BeamMP's own rate"},
	{global = "MPPowertrainGE", field = "sendEngineData", update = "eng", meter = "eng",
		missing = "traffic's engine updates are sent at BeamMP's own rate"},
	{global = "MPPowertrainGE", field = "sendLivePowertrain", update = "ptr", meter = "eng",
		missing = "traffic's powertrain updates are sent at BeamMP's own rate"},
	-- {"tagName": length} of the hydros that moved, like the lights.
	{global = "MPPowertrainGE", field = "sendHydroBeamData", update = "hyd",
		missing = "traffic's hydros are sent at BeamMP's own rate"},
	-- ["groupName", ...] just broken. The other games break each group listed, so the
	-- groups held are kept together, each once, and sent as one list.
	{global = "nodesGE", field = "sendBreakGroups", update = "brk", merge = "groups",
		missing = "traffic's break groups are sent as BeamMP sends them"},
	-- One controller function call: {"controllerName", "functionName", "variables"}. Only a
	-- set call is merged (the latest kept, per controller, function and every argument but
	-- the last); any other call (a toggle, a next or a start) goes out at once, after what
	-- was held, as the other games run each one.
	{global = "nodesGE", field = "sendControllerData", update = "ctl", merge = "calls",
		missing = "traffic's controller updates are sent at BeamMP's own rate"},
}
local METER_KIND, MERGE_STYLE = {}, {}
for _, target in ipairs(TARGETS) do
	METER_KIND[target.update] = target.meter
	MERGE_STYLE[target.update] = target.merge or "fields"
end

-- BeamMP's ticks: the module's global name, the kind of ask, the sends whose answers come
-- only from it (a still parked car's are sent as they come, as it is asked once a second)
-- and what it asks for. Controller data is also sent outside the tick, whenever a
-- controller function runs, so its sends keep their own spacing.
local POLLS = {
	{global = "positionGE", poll = "pos", answers = {"pos"}, what = "position"},
	{global = "nodesGE", poll = "nodes", answers = {"brk"}, what = "break groups"},
	{global = "MPInputsGE", poll = "inp", answers = {"inp"}, what = "inputs"},
	{global = "MPElectricsGE", poll = "elec", answers = {"elec"}, what = "lights"},
	{global = "MPPowertrainGE", poll = "ptr", answers = {"eng", "ptr", "hyd"}, what = "engine and powertrain"},
	{global = "MPControllerGE", poll = "ctl", answers = {}, what = "controller data"},
}
local POLL_NAMES, ASKED_BY = {}, {}
for _, p in ipairs(POLLS) do
	table.insert(POLL_NAMES, p.poll)
	for _, update in ipairs(p.answers) do ASKED_BY[update] = p.poll end
end
local POLL_EVERY = 1  -- seconds between asks of a still parked car, for each kind

-- {module, original, check} by update kind while that BeamMP function is wrapped.
local wraps = {}
-- {module, original, check, global, what} by kind of ask while that BeamMP tick is wrapped.
local pollWraps = {}
-- BeamMP ticks found not reading the list of own cars, left as they are from then on.
local leftAlone = setmetatable({}, {__mode = "k"})

local function perUpdate(kinds)
	local t = {}
	for _, kind in ipairs(kinds) do t[kind] = {} end
	return t
end

-- The rule of each own car under one, by game vehicle id: "parked" | "far" | "near" |
-- "hidden". A car not listed sends every update.
local limited = {}
-- When each car may next send each update: nextDue[update][gameVehicleID] = clock.
local nextDue = perUpdate(UPDATES)
-- Changes held since a car's last send, merged: held[update][gameVehicleID].
local held = perUpdate(MERGED)
-- When a still parked car may next be asked: nextPoll[poll][gameVehicleID] = clock.
local nextPoll = perUpdate(POLL_NAMES)
-- true while some own car is still parked or hidden, so a tick has cars to leave out.
local quiet = false

local clock = 0
local sinceClassify = nil
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
	local kind = METER_KIND[update]
	if not kind then return end
	local meter = extensions.mileage_perfMeter
	if meter and meter.sent then meter.sent(kind, isTrafficCar, through) end
end

local function failed(err)
	limited, quiet = {}, false
	if failureLogged then return end
	failureLogged = true
	log("E", logTag, "send check failed, every update is sent: " .. tostring(err))
end

local function anyQuiet()
	for _, kind in pairs(limited) do
		if kind == "parked" or kind == "hidden" then return true end
	end
	return false
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
	quiet = anyQuiet()
	-- Cars gone from the game keep no times or held updates.
	for _, perUpdate in ipairs({nextDue, held, nextPoll}) do
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
	quiet = anyQuiet()
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
	-- A car whose rule became faster (far traffic coming near) is not held to the slower
	-- rule's deadline.
	if nextAt and nextAt - clock > every + 1e-3 then nextAt = clock end
	if nextAt and clock < nextAt - 1e-6 then return false end
	if nextAt and clock - nextAt < every then
		byCar[gameVehicleID] = nextAt + every
	else
		byCar[gameVehicleID] = clock + every
	end
	return true
end

-- The rule a car's send of this update is held to, and whether the car is under a rule
-- at all. A still parked car asked once a second by a wrapped tick sends what it answers.
local function sendRule(update, gameVehicleID)
	local kind = limited[gameVehicleID]
	if kind == "parked" and ASKED_BY[update] and pollWraps[ASKED_BY[update]] then return nil, true end
	return kind, kind ~= nil
end

--== positions ===============================================================

local function letPositionThrough(gameVehicleID)
	local kind, ruled = sendRule("pos", gameVehicleID)
	local through = not kind or due("pos", gameVehicleID, kind)
	tellMeter("pos", ruled, through)
	return through
end

local function positionCheck(original)
	return function(data, gameVehicleID, ...)
		local ok, through = pcall(letPositionThrough, gameVehicleID)
		if not ok or through then return original(data, gameVehicleID, ...) end
	end
end

--== lights, inputs and engine ==============================================

-- Merges a change into what is held: the latest value of each key wins, and a key
-- holding a table (one engine of the engine data, one powertrain device) is merged the
-- same way, so an earlier change to another field of it is kept.
local function merge(into, change)
	for key, value in pairs(change) do
		if type(value) == "table" and type(into[key]) == "table" then
			merge(into[key], value)
		elseif type(value) == "table" then
			local copy = {}
			merge(copy, value)
			into[key] = copy
		else
			into[key] = value
		end
	end
end

-- The arguments of a controller call that name what it sets (all but the last), as text.
local function callKey(call)
	local key = call.controllerName .. "\0" .. call.functionName .. "\0" .. tostring(call.vehID)
	local variables = call.variables
	if type(variables) == "table" and #variables > 1 then
		local leading = {}
		for i = 1, #variables - 1 do leading[i] = variables[i] end
		key = key .. "\0" .. jsonEncode(leading)
	end
	return key
end

-- true when a decoded update can be merged into what is held; anything else goes out at
-- once, after what was held.
local function holdable(update, decoded)
	local style = MERGE_STYLE[update]
	if style == "groups" then
		local n = 0
		for _ in pairs(decoded) do n = n + 1 end
		return n > 0 and n == #decoded
	elseif style == "calls" then
		return type(decoded.controllerName) == "string" and type(decoded.functionName) == "string"
			and decoded.functionName:sub(1, 3) == "set"
	end
	return true
end

-- Adds an update to what is held for a car and returns what is held.
local function addHeld(update, pending, decoded, data)
	local style = MERGE_STYLE[update]
	if style == "groups" then
		pending = pending or {list = {}, seen = {}}
		for _, group in ipairs(decoded) do
			if not pending.seen[group] then
				pending.seen[group] = true
				table.insert(pending.list, group)
			end
		end
	elseif style == "calls" then
		pending = pending or {order = {}, texts = {}}
		local key = callKey(decoded)
		if pending.texts[key] then
			for i, k in ipairs(pending.order) do
				if k == key then table.remove(pending.order, i) break end
			end
		end
		table.insert(pending.order, key)
		pending.texts[key] = data
	else
		pending = pending or {}
		merge(pending, decoded)
	end
	return pending
end

-- What is held, as the texts to send in order.
local function heldTexts(update, pending)
	local style = MERGE_STYLE[update]
	if style == "groups" then return {jsonEncode(pending.list)} end
	if style == "calls" then
		local texts = {}
		for _, key in ipairs(pending.order) do table.insert(texts, pending.texts[key]) end
		return texts
	end
	return {jsonEncode(pending)}
end

-- Takes what is held for a car as the texts to send, or nil.
local function takeHeld(update, gameVehicleID)
	local pending = held[update][gameVehicleID]
	if not pending then return nil end
	held[update][gameVehicleID] = nil
	return heldTexts(update, pending)
end

-- What to send now for this call: the held texts, then one more text; nothing while it
-- is held. A car with no rule sends at once, after anything held for it from when it had
-- one. Text that does not decode, or a call that is not merged, goes out unchanged, after
-- what was held, so an older value never follows a newer one.
local function gate(update, data, gameVehicleID)
	local kind, ruled = sendRule(update, gameVehicleID)
	if not kind and not held[update][gameVehicleID] then
		tellMeter(update, ruled, true)
		return nil, data
	end
	local decoded = jsonDecode(data)
	if type(decoded) ~= "table" or not holdable(update, decoded) then
		tellMeter(update, ruled, true)
		return takeHeld(update, gameVehicleID), data
	end
	held[update][gameVehicleID] = addHeld(update, held[update][gameVehicleID], decoded, data)
	local now = not kind or due(update, gameVehicleID, kind)
	tellMeter(update, ruled, now)
	if not now then return nil end
	return takeHeld(update, gameVehicleID)
end

local function mergeCheck(update, original)
	return function(data, gameVehicleID, ...)
		local ok, texts, last = pcall(gate, update, data, gameVehicleID)
		if not ok then
			-- What was held goes first, so the newer call is the last word.
			local okHeld, before = pcall(takeHeld, update, gameVehicleID)
			if okHeld and before then
				for _, text in ipairs(before) do original(text, gameVehicleID, ...) end
			end
			return original(data, gameVehicleID, ...)
		end
		if texts then
			local n = #texts
			for i, text in ipairs(texts) do
				if i == n and not last then return original(text, gameVehicleID, ...) end
				original(text, gameVehicleID, ...)
			end
		end
		if last then return original(last, gameVehicleID, ...) end
	end
end

-- Sends each held set whose spacing has passed, so the last change of a car is never
-- left waiting for its next one.
local function flushHeld()
	local meter = extensions.mileage_perfMeter
	for update, byCar in pairs(held) do
		local w = wraps[update]
		for gameVehicleID, pending in pairs(byCar) do
			local kind = sendRule(update, gameVehicleID)
			if not w then
				byCar[gameVehicleID] = nil
			elseif not kind or due(update, gameVehicleID, kind) then
				byCar[gameVehicleID] = nil
				if meter and meter.flushed and METER_KIND[update] then meter.flushed(METER_KIND[update]) end
				for _, text in ipairs(heldTexts(update, pending)) do w.original(text, gameVehicleID) end
			end
		end
	end
end

--== BeamMP's ticks ==========================================================
-- Each tick walks MPVehicleGE.getPlayerVehicleObjects(own player id) and asks every car
-- in it. While a tick runs and some own car is still parked or hidden, that function
-- hands the tick a new list without the cars to leave out this time; the list BeamMP
-- keeps is never changed, and the function is BeamMP's own again as soon as the tick
-- returns.

-- The tick running now: its kind of ask, BeamMP's function for the list, and whether
-- the tick read the list.
local tickPoll, tickList, tickRead = nil, nil, false

-- true when a still parked car may be asked now; it then counts as asked. An ask is due
-- POLL_EVERY after the last one was due, as sends are.
local function pollDue(poll, gameVehicleID)
	local byCar = nextPoll[poll]
	local nextAt = byCar[gameVehicleID]
	if nextAt and clock < nextAt - 1e-6 then return false end
	if nextAt and clock - nextAt < POLL_EVERY then
		byCar[gameVehicleID] = nextAt + POLL_EVERY
	else
		byCar[gameVehicleID] = clock + POLL_EVERY
	end
	return true
end

-- The cars of BeamMP's list to ask this tick, as a new list with the same keys.
local function pickCars(cars)
	local picked = {}
	for key, veh in pairs(cars) do
		if veh then
			local gameVehicleID = veh:getID()
			local kind = limited[gameVehicleID]
			if kind ~= "hidden" and (kind ~= "parked" or pollDue(tickPoll, gameVehicleID)) then
				picked[key] = veh
			end
		end
	end
	return picked
end

-- Stands in for MPVehicleGE.getPlayerVehicleObjects while a tick runs.
local function askedCars(...)
	tickRead = true
	local cars = tickList(...)
	if type(cars) ~= "table" then return cars end
	local ok, picked = pcall(pickCars, cars)
	if ok then return picked end
	failed(picked)
	return cars
end

-- Puts back a tick that did not read the list of own cars, with one line in the log.
local function leaveTick(poll)
	local w = pollWraps[poll]
	if not w then return end
	pollWraps[poll] = nil
	if w.module.tick == w.check then w.module.tick = w.original end
	leftAlone[w.original] = true
	log("W", logTag, w.global .. ".tick does not read MPVehicleGE.getPlayerVehicleObjects - BeamMP asks " ..
		"every car for its " .. w.what .. " at its own rate")
end

local function pollCheck(poll, original)
	return function(...)
		local vehicles = MPVehicleGE
		local list = quiet and not tickList and type(vehicles) == "table" and vehicles.getPlayerVehicleObjects
		if type(list) ~= "function" then return original(...) end
		tickPoll, tickList, tickRead = poll, list, false
		vehicles.getPlayerVehicleObjects = askedCars
		local ok, err = pcall(original, ...)
		if vehicles.getPlayerVehicleObjects == askedCars then vehicles.getPlayerVehicleObjects = list end
		local read = tickRead
		tickPoll, tickList, tickRead = nil, nil, false
		if not ok then error(err, 0) end
		if not read then leaveTick(poll) end
	end
end

--== wrapping ================================================================

local function isActive() return next(wraps) ~= nil or next(pollWraps) ~= nil end

local function clearState()
	limited, nextDue, held = {}, perUpdate(UPDATES), perUpdate(MERGED)
	nextPoll, quiet = perUpdate(POLL_NAMES), false
end

local function unwrap(why)
	if not isActive() then return end
	for _, target in ipairs(TARGETS) do
		local w = wraps[target.update]
		if w and w.module[target.field] == w.check then w.module[target.field] = w.original end
	end
	for _, w in pairs(pollWraps) do
		if w.module.tick == w.check then w.module.tick = w.original end
	end
	wraps, pollWraps = {}, {}
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
	local list = compat and compat.pickOrWarn(MPVehicleGE, "MPVehicleGE", "getPlayerVehicleObjects",
		"BeamMP asks every own car for every update at its own rate")
	for _, p in ipairs(list and POLLS or {}) do
		local module = rawget(_G, p.global)
		local w = pollWraps[p.poll]
		if not (w and w.module == module and type(module) == "table" and module.tick == w.check) then
			-- BeamMP reloaded its module: the old table is no longer used and is left as it is.
			pollWraps[p.poll] = nil
			local original = compat.pickOrWarn(module, p.global, "tick",
				"BeamMP asks every car for its " .. p.what .. " at its own rate")
			if original and not leftAlone[original] then
				local check = pollCheck(p.poll, original)
				pollWraps[p.poll] = {module = module, original = original, check = check, global = p.global,
					what = p.what}
				module.tick = check
				added.tick = true
			end
		end
	end
	if next(added) == nil then return end
	clearState()
	sinceClassify, sinceParkedCheck, failureLogged = nil, 0, false
	if added.pos then
		log("I", logTag, string.format("position check active - still parked cars send once a second, " ..
			"traffic over %d m from other players twice a second, other traffic 20 times a second", FAR_DISTANCE))
	end
	if added.elec or added.inp or added.eng or added.ptr then
		log("I", logTag, "lights, inputs and engine check active - traffic's changes are merged and sent 5 " ..
			"(inputs 10) times a second near players, once a second far away or parked")
	end
	if added.hyd or added.brk or added.ctl then
		log("I", logTag, "hydros, break groups and controller check active - traffic's are merged and sent " ..
			"5 times a second near players, once a second far away or parked")
	end
	if added.tick then
		log("I", logTag, "tick check active - BeamMP asks a still parked car once a second, a hidden car never")
	end
end

--== hooks ===================================================================

function M.onCareerActive(active)
	local compat = extensions.mileage_compat
	if active and compat and compat.isMPSession() then
		wrap()
		sinceClassify = nil
	else
		unwrap("career not active")
	end
end

function M.onUpdate(dtReal)
	if not isActive() then return end
	local dt = tonumber(dtReal)
	if not dt or dt < 0 then dt = 0 end
	clock = clock + dt
	if sinceClassify then sinceClassify = sinceClassify + dt else sinceClassify = CLASSIFY_EVERY - CLASSIFY_AT end
	sinceParkedCheck = sinceParkedCheck + dt
	if sinceClassify >= CLASSIFY_EVERY then
		-- What is left over keeps the check at its point in the second.
		sinceClassify, sinceParkedCheck = sinceClassify % CLASSIFY_EVERY, 0
		local ok, err = pcall(classify)
		if not ok then failed(err) end
	elseif sinceParkedCheck >= PARKED_CHECK_EVERY then
		sinceParkedCheck = 0
		local ok, err = pcall(checkParked)
		if not ok then failed(err) end
	end
	local anyHeld = false
	for _, byCar in pairs(held) do
		if next(byCar) then anyHeld = true break end
	end
	if anyHeld then
		local ok, err = pcall(flushHeld)
		if not ok then
			held = perUpdate(MERGED)
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
