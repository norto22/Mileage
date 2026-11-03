--Mileage :: cost meter (CLIENT)
--
-- While the career runs on a server, this game measures what playing together costs it
-- and reports it, so a session before and after a change can be compared:
--
--   * frame time (average and worst) and frames longer than HITCH_SECONDS;
--   * updates BeamMP asked to send for this game's cars and how many went through, by
--     kind (position, lights, inputs) and apart for own cars and traffic - the send
--     checks in mileage/positionRate.lua tell the meter through sent();
--   * updates received for other players' cars, counted by a wrap of BeamMP's handle
--     functions that always passes the update on;
--   * cars built by spawn pacing (built()), cars by kind and shown or hidden, and how
--     many other players had a car within NEAR_DISTANCE of this player's car.
--
-- Every REPORT_SECONDS it writes one line under mileage.perf and sends the same numbers
-- to the server (mileagePerfReport), which prints them in `Mileage Stats`. Cars are
-- counted once a second, never per frame. A missing BeamMP function is logged once and
-- the rest is still counted; a count never stops an update reaching BeamMP.

local M = {}

local logTag = "mileage.perf"

local REPORT_SECONDS = 30
local HITCH_SECONDS = 0.1
local COUNT_EVERY = 1        -- seconds between car counts
local NEAR_DISTANCE = 500    -- metres from this player's car

-- BeamMP's receive functions, called by name for each update of another player's car.
local RECEIVERS = {
	{global = "positionGE", update = "pos"},
	{global = "MPElectricsGE", update = "elec"},
	{global = "MPInputsGE", update = "inp"},
}

local active = false
-- {module, original, check} per wrapped receive function.
local wraps = {}
local window = nil
local cars = nil
local sinceCount = COUNT_EVERY
local failureLogged = false

local function pair() return {0, 0} end

local function newWindow()
	return {
		seconds = 0, frames = 0, sum = 0, worst = 0, hitches = 0,
		sent = {
			own = {pos = pair(), elec = pair(), inp = pair()},
			traffic = {pos = pair(), elec = pair(), inp = pair()},
		},
		recv = {pos = 0, elec = 0, inp = 0},
		built = 0,
		near = nil,
	}
end

local function newCars()
	return {own = 0, ownTraffic = 0, ownParked = 0, remote = 0, remoteTraffic = 0, hidden = 0}
end

local function enabler()
	local e = mileageEnabler
	return type(e) == "table" and e or nil
end

local function isTrafficCar(gameVehicleID, veh)
	local e = enabler()
	return e ~= nil and type(e.isTrafficCar) == "function" and e.isTrafficCar(gameVehicleID, veh) == true
end

local function isRemoteTraffic(serverVehicleID)
	local e = enabler()
	return e ~= nil and type(e.isRemoteTraffic) == "function" and e.isRemoteTraffic(serverVehicleID) == true
end

local function distanceSquared(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return dx * dx + dy * dy + dz * dz
end

-- Counts every car by kind and the other players with a car near this player's car.
local function countCars()
	local counts = newCars()
	local playerID = be:getPlayerVehicleID(0)
	local playerVeh = playerID and playerID ~= -1 and be:getObjectByID(playerID) or nil
	local playerPos = playerVeh and playerVeh:getPosition() or nil
	local nearOwners = {}
	for serverVehicleID, entry in pairs(MPVehicleGE.getVehicles()) do
		local gameVehicleID = entry.gameVehicleID
		local veh = gameVehicleID and gameVehicleID ~= -1 and be:getObjectByID(gameVehicleID)
		if veh then
			local shown = veh:getActive()
			if not shown then counts.hidden = counts.hidden + 1 end
			if MPVehicleGE.isOwn(gameVehicleID) then
				if not isTrafficCar(gameVehicleID, veh) then
					counts.own = counts.own + 1
				elseif veh.isParked == "true" then
					counts.ownParked = counts.ownParked + 1
				else
					counts.ownTraffic = counts.ownTraffic + 1
				end
			elseif isRemoteTraffic(serverVehicleID) then
				counts.remoteTraffic = counts.remoteTraffic + 1
			else
				counts.remote = counts.remote + 1
				local owner = tostring(serverVehicleID):match("^(%d+)%-")
				if shown and playerPos and owner
					and distanceSquared(veh:getPosition(), playerPos) <= NEAR_DISTANCE * NEAR_DISTANCE then
					nearOwners[owner] = true
				end
			end
		end
	end
	cars = counts
	if playerPos then
		local near = 0
		for _ in pairs(nearOwners) do near = near + 1 end
		if not window.near then
			window.near = {near, near}
		else
			window.near[1] = math.min(window.near[1], near)
			window.near[2] = math.max(window.near[2], near)
		end
	end
end

local function round1(x) return math.floor(x * 10 + 0.5) / 10 end

local function buildReport()
	local w = window
	local c = cars or newCars()
	return {
		v = 1,
		s = math.floor(w.seconds + 0.5),
		frames = w.frames,
		avgMs = w.frames > 0 and round1(w.sum / w.frames * 1000) or 0,
		worstMs = math.floor(w.worst * 1000 + 0.5),
		hitches = w.hitches,
		sent = w.sent,
		recv = w.recv,
		built = w.built,
		near = w.near or {0, 0},
		cars = {own = c.own, ownTraffic = c.ownTraffic, ownParked = c.ownParked, remote = c.remote,
			remoteTraffic = c.remoteTraffic, hidden = c.hidden},
	}
end

local function sentText(group)
	return string.format("pos %d/%d elec %d/%d inp %d/%d", group.pos[2], group.pos[1], group.elec[2],
		group.elec[1], group.inp[2], group.inp[1])
end

local function logLine(r)
	local c = r.cars
	return string.format("%d s: %d frames, avg %.1f ms, worst %d ms, %d over %d ms | sent own %s; traffic %s" ..
		" | received pos %d elec %d inp %d | built %d | players near %d-%d | cars own %d, traffic %d, parked %d," ..
		" others' %d, others' traffic %d, hidden %d",
		r.s, r.frames, r.avgMs, r.worstMs, r.hitches, HITCH_SECONDS * 1000, sentText(r.sent.own),
		sentText(r.sent.traffic), r.recv.pos, r.recv.elec, r.recv.inp, r.built, r.near[1], r.near[2], c.own,
		c.ownTraffic, c.ownParked, c.remote, c.remoteTraffic, c.hidden)
end

local function report()
	local r = buildReport()
	log("I", logTag, logLine(r))
	TriggerServerEvent("mileagePerfReport", jsonEncode(r))
end

local function failed(err)
	if failureLogged then return end
	failureLogged = true
	log("E", logTag, "cost meter failed, this report is skipped: " .. tostring(err))
end

--== receive counters ========================================================

local function unwrapReceivers()
	for _, w in ipairs(wraps) do
		if w.module.handle == w.check then w.module.handle = w.original end
	end
	wraps = {}
end

local function wrapReceivers()
	unwrapReceivers()
	local compat = extensions.mileage_compat
	for _, receiver in ipairs(RECEIVERS) do
		local module = rawget(_G, receiver.global)
		local original = compat and compat.pickOrWarn(module, receiver.global, "handle",
			"received " .. receiver.update .. " updates are not counted")
		if original then
			local update = receiver.update
			local check = function(...)
				if window then window.recv[update] = window.recv[update] + 1 end
				return original(...)
			end
			module.handle = check
			table.insert(wraps, {module = module, original = original, check = check})
		end
	end
end

local function start()
	if active then return end
	active = true
	window, cars, sinceCount, failureLogged = newWindow(), nil, COUNT_EVERY, false
	wrapReceivers()
	log("I", logTag, string.format("cost meter active - a line every %d s", REPORT_SECONDS))
end

local function stop(why)
	if not active then return end
	active = false
	unwrapReceivers()
	window, cars = nil, nil
	log("D", logTag, "cost meter stopped (" .. why .. ")")
end

--== called by the send checks and spawn pacing ==============================

-- One update BeamMP asked to send: update is "pos", "elec" or "inp"; isTraffic for a car
-- under a send rule; through when it went on to BeamMP.
function M.sent(update, isTraffic, through)
	if not window then return end
	local counts = window.sent[isTraffic and "traffic" or "own"][update]
	if not counts then return end
	counts[1] = counts[1] + 1
	if through then counts[2] = counts[2] + 1 end
end

-- One car of another player built.
function M.built()
	if window then window.built = window.built + 1 end
end

--== hooks ===================================================================

function M.onCareerActive(isActive)
	local compat = extensions.mileage_compat
	if isActive and compat and compat.isMPSession() then
		start()
	else
		stop("career not active")
	end
end

function M.onUpdate(dtReal)
	if not active then return end
	local dt = tonumber(dtReal)
	if not dt or dt < 0 then dt = 0 end
	local w = window
	w.seconds = w.seconds + dt
	w.frames = w.frames + 1
	w.sum = w.sum + dt
	if dt > w.worst then w.worst = dt end
	if dt > HITCH_SECONDS then w.hitches = w.hitches + 1 end
	sinceCount = sinceCount + dt
	if sinceCount >= COUNT_EVERY then
		sinceCount = 0
		local ok, err = pcall(countCars)
		if not ok then failed(err) end
	end
	if w.seconds >= REPORT_SECONDS - 1e-6 then
		local ok, err = pcall(report)
		if not ok then failed(err) end
		window = newWindow()
	end
end

function M.onBeamMPServerLeave()
	stop("left the server")
end

function M.onExtensionLoaded()
	log("I", logTag, "Mileage cost meter LOADED")
end

function M.onExtensionUnloaded()
	stop("unloaded")
	log("I", logTag, "Mileage cost meter UNLOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
