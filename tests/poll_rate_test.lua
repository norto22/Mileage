-- mileage/positionRate.lua around BeamMP's update ticks. Many times a second BeamMP asks
-- every car this game owns for its position (positionGE.tick), break groups
-- (nodesGE.tick), inputs (MPInputsGE.tick), lights (MPElectricsGE.tick), engine,
-- powertrain and hydros (MPPowertrainGE.tick) and controller data (MPControllerGE.tick).
-- While the career runs on a server a still parked own car is asked once a second for
-- each kind, a hidden own car not at all, and every other car as BeamMP does. Break
-- groups, controller data and hydros of traffic and parked cars are merged and sent at
-- the rate of their lights.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileage/positionRate.lua"
local COMPAT = "Resources/Client/Mileage/lua/ge/extensions/mileage/compat.lua"

local FRAME = 1 / 60

local logs, game

--== a small JSON for the stand-in game ======================================
-- Objects with keys in order (equal tables give equal text), arrays, strings, numbers,
-- booleans.

local function isArray(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n > 0 and n == #t
end

local function encode(v)
	local kind = type(v)
	if kind == "table" then
		local parts = {}
		if isArray(v) then
			for _, item in ipairs(v) do table.insert(parts, encode(item)) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for k in pairs(v) do table.insert(keys, tostring(k)) end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local item = v[k]
			if item == nil then item = v[tonumber(k)] end
			table.insert(parts, encode(k) .. ":" .. encode(item))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif kind == "string" then
		return '"' .. v:gsub('[\\"]', "\\%0") .. '"'
	elseif kind == "number" then
		if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
		return string.format("%.14g", v)
	end
	return tostring(v)
end

local function decode(text)
	if type(text) ~= "string" then return nil end
	local pos = 1
	local value
	local function space() pos = text:find("[^%s]", pos) or #text + 1 end
	local function fail() error("bad json at " .. pos, 0) end
	function value()
		space()
		local c = text:sub(pos, pos)
		if c == "{" then
			local t = {}
			pos = pos + 1
			space()
			if text:sub(pos, pos) == "}" then pos = pos + 1 return t end
			while true do
				local k = value()
				space()
				if text:sub(pos, pos) ~= ":" then fail() end
				pos = pos + 1
				t[k] = value()
				space()
				local sep = text:sub(pos, pos)
				pos = pos + 1
				if sep == "}" then return t end
				if sep ~= "," then fail() end
			end
		elseif c == "[" then
			local t = {}
			pos = pos + 1
			space()
			if text:sub(pos, pos) == "]" then pos = pos + 1 return t end
			while true do
				table.insert(t, value())
				space()
				local sep = text:sub(pos, pos)
				pos = pos + 1
				if sep == "]" then return t end
				if sep ~= "," then fail() end
			end
		elseif c == '"' then
			local out = {}
			pos = pos + 1
			while true do
				local ch = text:sub(pos, pos)
				if ch == "" then fail() end
				if ch == '"' then pos = pos + 1 break end
				if ch == "\\" then pos = pos + 1 ch = text:sub(pos, pos) end
				table.insert(out, ch)
				pos = pos + 1
			end
			return table.concat(out)
		elseif text:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
		elseif text:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
		end
		local num = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
		if not num or num == "" then fail() end
		pos = pos + #num
		return tonumber(num)
	end
	local ok, result = pcall(value)
	if not ok then return nil end
	return result
end

--== the stand-in game and BeamMP ============================================

local function vec(x, y, z)
	local v = {x = x, y = y, z = z}
	function v:length() return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end
	return v
end

-- What each of BeamMP's ticks asks a car for.
local POLL = {
	pos = "positionVE.getVehicleRotation()",
	nodes = "nodesVE.getBreakGroups()",
	inp = "MPInputsVE.getInputs()",
	elec = "MPElectricsVE.check()",
	ptr = "MPPowertrainVE.check()",
	ctl = "controllerSyncVE.getControllerData()",
}
local POLL_KINDS = {"pos", "nodes", "inp", "elec", "ptr", "ctl"}

-- A car on the stand-in game. kind: "player", "own", "traffic", "parked", "remote".
local function addCar(gid, kind, pos, fields)
	local veh = {id = gid, pos = pos or vec(0, 0, 0), vel = vec(0, 0, 0), active = true, own = kind ~= "remote",
		kind = kind, polls = {}, pollTimes = {}, queue = {}, lights = 0, ignition = 0}
	for k, v in pairs(fields or {}) do veh[k] = v end
	if kind == "traffic" then veh.isTraffic = "true" end
	if kind == "parked" then veh.isParked = "true" end
	veh.sentLights, veh.sentIgnition = veh.lights, veh.ignition
	function veh:getID() return self.id end
	function veh:getActive() return self.active end
	function veh:getPosition() return self.pos end
	function veh:getVelocity() return self.vel end
	function veh:queueLuaCommand(cmd)
		self.polls[cmd] = (self.polls[cmd] or 0) + 1
		self.pollTimes[cmd] = self.pollTimes[cmd] or {}
		table.insert(self.pollTimes[cmd], game.clock)
		table.insert(self.queue, cmd)
	end
	game.objects[gid] = veh
	local sid = (veh.own and "0-" or "1-") .. gid
	game.vehicles[sid] = {gameVehicleID = gid}
	if veh.own then game.ownObjects[sid] = veh end
	if kind == "player" then game.playerVehicle = gid end
	return veh
end

-- The car's vehicle Lua answering what was asked, as BeamMP's does: a position every
-- time, lights and engine only when they changed.
local function answer(veh)
	local queue = veh.queue
	veh.queue = {}
	for _, cmd in ipairs(queue) do
		if cmd == POLL.pos then
			positionGE.sendVehiclePosRot('{"pos":[0,0,0]}', veh.id)
		elseif cmd == POLL.elec and veh.lights ~= veh.sentLights then
			veh.sentLights = veh.lights
			MPElectricsGE.sendElectrics(encode({lights = veh.lights}), veh.id)
		elseif cmd == POLL.ptr and veh.ignition ~= veh.sentIgnition then
			veh.sentIgnition = veh.ignition
			MPPowertrainGE.sendEngineData(encode({ignition = veh.ignition}), veh.id)
		end
	end
end

-- BeamMP's tick of each kind, as it is written in BeamMP: every own car is asked.
local function beamTick(kind)
	return function()
		for _, v in pairs(MPVehicleGE.getPlayerVehicleObjects(MPConfig.getPlayerServerID())) do
			if v then v:queueLuaCommand(POLL[kind]) end
		end
	end
end

-- MPUpdatesGE's timers, calling each tick by its module's name.
local TICKRATE = {nodes = 1 / 15, pos = 0.020, inp = 1 / 30, elec = 1 / 15, ptr = 1 / 10, ctl = 1 / 15}
local TICK_MODULE = {pos = "positionGE", nodes = "nodesGE", inp = "MPInputsGE", elec = "MPElectricsGE",
	ptr = "MPPowertrainGE", ctl = "MPControllerGE"}

local function beamUpdate(dt)
	for _, kind in ipairs(POLL_KINDS) do
		game.timers[kind] = game.timers[kind] + dt
		local rate = TICKRATE[kind]
		if game.timers[kind] >= rate then
			game.timers[kind] = (game.timers[kind] - rate) % rate
			local module = rawget(_G, TICK_MODULE[kind])
			if module and module.tick then
				game.ticks[kind] = game.ticks[kind] + 1
				module.tick()
			end
		end
	end
end

local function setup(opts)
	opts = opts or {}
	logs = {}
	game = {objects = {}, vehicles = {}, ownObjects = {}, playerVehicle = -1, remoteTraffic = {}, clock = 0,
		timers = {}, ticks = {}, net = {}}
	for _, kind in ipairs(POLL_KINDS) do game.timers[kind], game.ticks[kind] = 0, 0 end
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	MPCoreNetwork = {isMPSession = function() return opts.mp ~= false end}
	extensions = {mileage_compat = dofile(COMPAT)}
	MPConfig = {getPlayerServerID = function() return 0 end}
	MPVehicleGE = {
		getVehicles = function() return game.vehicles end,
		isOwn = function(gid) local v = game.objects[gid]; return v ~= nil and v.own end,
		getPlayerVehicleObjects = function(pid)
			if pid == 0 then return game.ownObjects end
			return {}
		end,
	}
	if opts.noObjectList then MPVehicleGE.getPlayerVehicleObjects = nil end
	game.objectList = MPVehicleGE.getPlayerVehicleObjects
	be = {
		getObjectByID = function(_, gid) return game.objects[gid] end,
		getPlayerVehicleID = function() return game.playerVehicle end,
	}
	mileageEnabler = {
		isTrafficCar = function(gid, veh)
			if gid == game.playerVehicle then return false end
			return veh.isTraffic == "true" or veh.isParked == "true"
		end,
		isRemoteTraffic = function(sid) return game.remoteTraffic[sid] == true end,
	}
	-- BeamMP's sends put each text on the network, by kind and car, with the time.
	local function sender(kind)
		game.net[kind] = {}
		return function(data, gid)
			local byCar = game.net[kind]
			byCar[gid] = byCar[gid] or {}
			table.insert(byCar[gid], {t = game.clock, data = data})
		end
	end
	positionGE = {sendVehiclePosRot = sender("pos"), tick = beamTick("pos")}
	nodesGE = {sendBreakGroups = sender("brk"), sendControllerData = sender("ctl"), tick = beamTick("nodes")}
	MPInputsGE = {sendInputs = sender("inp"), tick = beamTick("inp")}
	MPElectricsGE = {sendElectrics = sender("elec"), tick = beamTick("elec")}
	MPPowertrainGE = {sendEngineData = sender("eng"), sendLivePowertrain = sender("ptr"),
		sendHydroBeamData = sender("hyd"), tick = beamTick("ptr")}
	MPControllerGE = {tick = beamTick("ctl")}
	if opts.noController then MPControllerGE = nil end
	if opts.noBreakGroups then nodesGE.sendBreakGroups = nil end
	game.originalTicks = {}
	for _, kind in ipairs(POLL_KINDS) do
		local module = rawget(_G, TICK_MODULE[kind])
		game.originalTicks[kind] = module and module.tick
	end
	game.originalSends = {brk = nodesGE.sendBreakGroups, ctl = nodesGE.sendControllerData,
		hyd = MPPowertrainGE.sendHydroBeamData}
	jsonDecode, jsonEncode = decode, encode
	extensions.mileage_perfMeter = nil
	return dofile(SOURCE)
end

-- Runs `seconds` of frames: the cars answer what they were asked last frame, then the
-- module's update, then BeamMP's ticks. each(t) runs at the start of every frame.
local function run(module, seconds, each, frame)
	frame = frame or FRAME
	local elapsed, i = 0, 0
	while elapsed < seconds - 1e-9 do
		i = i + 1
		local dt = type(frame) == "function" and frame(i) or frame
		elapsed = elapsed + dt
		game.clock = game.clock + dt
		if each then each(game.clock) end
		for _, veh in pairs(game.objects) do if veh.own then answer(veh) end end
		module.onUpdate(dt)
		beamUpdate(dt)
	end
end

local function polls(gid, kind) return game.objects[gid].polls[POLL[kind]] or 0 end

local function pollsBetween(gid, kind, from, to)
	local n = 0
	for _, t in ipairs(game.objects[gid].pollTimes[POLL[kind]] or {}) do
		if t >= from - 1e-9 and t < to - 1e-9 then n = n + 1 end
	end
	return n
end

local function sent(kind, gid) return (game.net[kind] or {})[gid] or {} end

-- One player's game: the car they drive, an own car, driving traffic near another
-- player's car, a still parked car and a hidden traffic car.
local function ownCars(opts)
	local module = setup(opts)
	addCar(1, "player", vec(10, 0, 0))
	addCar(500, "remote", vec(0, 0, 0))
	addCar(10, "own", vec(20, 0, 0))
	addCar(20, "traffic", vec(100, 0, 0), {vel = vec(12, 0, 0)})
	addCar(40, "parked", vec(2000, 0, 0))
	addCar(60, "traffic", vec(30, 0, 0), {active = false})
	module.onCareerActive(true)
	return module
end

--== T7: BeamMP's ticks ======================================================

test("A17: over 10 s of BeamMP's ticks a still parked car is asked once a second for each kind, a hidden car never, the rest as BeamMP does", function()
	local module = ownCars()
	run(module, 10)
	for _, kind in ipairs(POLL_KINDS) do
		local ticks = game.ticks[kind]
		same(polls(1, kind), ticks, "the car the player drives, " .. kind)
		same(polls(10, kind), ticks, "the player's own car, " .. kind)
		same(polls(20, kind), ticks, "driving traffic, " .. kind)
		local parked = polls(40, kind)
		expect(parked >= 9 and parked <= 11, "still parked car, " .. kind .. ": " .. parked)
		same(polls(60, kind), 0, "hidden car, " .. kind)
	end
end)

test("A17: a still parked car is asked once in each second, never twice in one", function()
	local module = ownCars()
	run(module, 1.2)
	run(module, 8)
	for _, kind in ipairs(POLL_KINDS) do
		local times = game.objects[40].pollTimes[POLL[kind]]
		for i = 2, #times do
			local gap = times[i] - times[i - 1]
			expect(gap > 0.9 and gap < 1.1, kind .. " gap " .. i .. ": " .. gap)
		end
	end
end)

test("A17: BeamMP's car list is the same table, untouched, after every tick", function()
	local module = ownCars()
	local before = {}
	for sid, veh in pairs(game.ownObjects) do before[sid] = veh end
	run(module, 3)
	same(MPVehicleGE.getPlayerVehicleObjects, game.objectList, "MPVehicleGE.getPlayerVehicleObjects")
	for sid, veh in pairs(before) do same(game.ownObjects[sid], veh, "car " .. sid) end
	for sid in pairs(game.ownObjects) do expect(before[sid], "no car added: " .. sid) end
end)

test("A24: a still parked car's light change reaches the network within about a second", function()
	local module = ownCars()
	run(module, 2.37)
	game.objects[40].lights = 1
	local changedAt = game.clock
	run(module, 1.5)
	local out = sent("elec", 40)
	same(#out, 1, "light sends")
	same(decode(out[1].data).lights, 1, "the new value")
	local delay = out[1].t - changedAt
	expect(delay <= 1 + 3 * FRAME, "seconds until it was sent: " .. delay)
end)

test("A24: a still parked car's ignition change reaches the network within about a second", function()
	local module = ownCars()
	run(module, 4.61)
	game.objects[40].ignition = 1
	local changedAt = game.clock
	run(module, 1.5)
	local out = sent("eng", 40)
	same(#out, 1, "engine sends")
	same(decode(out[1].data).ignition, 1, "the new value")
	local delay = out[1].t - changedAt
	expect(delay <= 1 + 3 * FRAME, "seconds until it was sent: " .. delay)
end)

test("A24: every position a still parked car gives when asked is sent, even with uneven frames", function()
	local module = ownCars()
	-- frames of 1/60, 1/30 and 1/45 s in turn
	local frames = {1 / 60, 1 / 30, 1 / 45}
	run(module, 12, nil, function(i) return frames[i % 3 + 1] end)
	local asked = polls(40, "pos")
	expect(asked >= 10, "positions asked: " .. asked)
	-- the last one asked may not have been answered yet
	local given = #sent("pos", 40)
	expect(given == asked or given == asked - 1, "positions sent " .. given .. " of " .. asked)
end)

test("A25: a still parked car hit at 3.1 s is asked at BeamMP's full rate by 3.6 s", function()
	local module = ownCars()
	run(module, 3.1)
	game.objects[40].vel = vec(3, 0, 0)
	run(module, 1.6)
	-- every tick from 3.6 s on asks it: as many asks as the driving traffic car got
	for _, kind in ipairs(POLL_KINDS) do
		same(pollsBetween(40, kind, 3.6, 4.7), pollsBetween(20, kind, 3.6, 4.7), "asks of " .. kind .. " from 3.6 s")
	end
	expect(pollsBetween(40, "pos", 3.6, 4.6) >= 49, "positions asked in the second from 3.6 s")
end)

test("A25: a car that just stopped stays at full rate until the next check finds it still", function()
	local module = ownCars()
	game.objects[40].vel = vec(3, 0, 0)
	run(module, 2.5)
	game.objects[40].vel = vec(0, 0, 0)
	run(module, 2)
	local n = pollsBetween(40, "pos", 3.1, 4.1)
	expect(n >= 1 and n <= 2, "positions asked in a second once still: " .. n)
end)

test("a hidden car shown again is asked at BeamMP's full rate within a quarter of a second", function()
	local module = ownCars()
	run(module, 2)
	same(polls(60, "pos"), 0, "asked while hidden")
	game.objects[60].active = true
	run(module, 0.26)
	local from = game.clock
	run(module, 0.5)
	same(pollsBetween(60, "pos", from, game.clock + 1), pollsBetween(20, "pos", from, game.clock + 1),
		"positions asked in the half second after")
end)

test("a BeamMP build without MPControllerGE still wraps the other ticks, and says so once", function()
	local module = ownCars({noController = true})
	module.onCareerActive(true)
	run(module, 10)
	same(countLines(logs, "MPControllerGE.tick missing"), 1, "warnings")
	local parked = polls(40, "pos")
	expect(parked >= 9 and parked <= 11, "still parked car's positions asked: " .. parked)
	same(polls(60, "elec"), 0, "hidden car's lights asked")
	same(polls(20, "pos"), game.ticks.pos, "driving traffic's positions asked")
end)

test("without MPVehicleGE.getPlayerVehicleObjects the log says so once and every tick is BeamMP's own", function()
	local module = ownCars({noObjectList = true})
	module.onCareerActive(true)
	same(countLines(logs, "MPVehicleGE.getPlayerVehicleObjects missing"), 1, "warnings")
	for _, kind in ipairs(POLL_KINDS) do
		same(rawget(_G, TICK_MODULE[kind]).tick, game.originalTicks[kind], TICK_MODULE[kind] .. ".tick")
	end
end)

test("a tick that no longer reads BeamMP's car list is put back after one warning", function()
	local module = setup()
	local asked = 0
	local changed = function() asked = asked + 1 end
	MPElectricsGE.tick = changed
	addCar(1, "player")
	addCar(40, "parked", vec(2000, 0, 0))
	module.onCareerActive(true)
	run(module, 3)
	same(countLines(logs, "MPElectricsGE.tick"), 1, "warnings naming it")
	same(MPElectricsGE.tick, changed, "MPElectricsGE.tick")
	same(asked, game.ticks.elec, "its calls")
	local parked = polls(40, "pos")
	expect(parked >= 2 and parked <= 4, "the other ticks still space the parked car: " .. parked)
end)

test("a tick that fails puts BeamMP's car list back and the error goes on to BeamMP", function()
	local module = setup()
	local broken = function()
		MPVehicleGE.getPlayerVehicleObjects(0)
		error("tick broke")
	end
	MPInputsGE.tick = broken
	addCar(1, "player")
	addCar(40, "parked", vec(2000, 0, 0))
	module.onCareerActive(true)
	expect(MPInputsGE.tick ~= broken, "the tick is wrapped")
	for _ = 1, 30 do module.onUpdate(FRAME) end
	local ok, err = pcall(MPInputsGE.tick)
	expect(not ok and tostring(err):find("tick broke", 1, true), "the error came through: " .. tostring(err))
	same(MPVehicleGE.getPlayerVehicleObjects, game.objectList, "MPVehicleGE.getPlayerVehicleObjects")
	same(game.objects[40].polls[POLL.inp], nil, "no ask was made")
end)

test("leaving the server, a career that stops and unloading put every tick back", function()
	for _, how in ipairs({"leave", "stop", "unload"}) do
		local module = ownCars()
		for _, kind in ipairs(POLL_KINDS) do
			expect(rawget(_G, TICK_MODULE[kind]).tick ~= game.originalTicks[kind], how .. ": wrapped " .. kind)
		end
		run(module, 1.5)
		if how == "leave" then module.onBeamMPServerLeave()
		elseif how == "stop" then module.onCareerActive(false)
		else module.onExtensionUnloaded() end
		for _, kind in ipairs(POLL_KINDS) do
			same(rawget(_G, TICK_MODULE[kind]).tick, game.originalTicks[kind], how .. ": " .. TICK_MODULE[kind] .. ".tick")
		end
		same(MPVehicleGE.getPlayerVehicleObjects, game.objectList, how .. ": the car list")
		local before, ticksBefore = polls(40, "pos"), game.ticks.pos
		run(module, 1)
		same(polls(40, "pos") - before, game.ticks.pos - ticksBefore, how .. ": parked car asked by BeamMP")
	end
end)

test("off a server no tick is wrapped", function()
	local module = setup({mp = false})
	module.onCareerActive(true)
	for _, kind in ipairs(POLL_KINDS) do
		same(rawget(_G, TICK_MODULE[kind]).tick, game.originalTicks[kind], TICK_MODULE[kind] .. ".tick")
	end
end)

test("a check that fails reading the cars lets BeamMP ask every car", function()
	local module = ownCars()
	run(module, 2)
	be.getObjectByID = function() error("lookup broke") end
	pcall(run, module, 2)
	local from = game.clock
	pcall(run, module, 1)
	same(pollsBetween(40, "pos", from, from + 2), pollsBetween(20, "pos", from, from + 2),
		"a still parked car's asks once the check failed")
end)

--== T8: break groups, controller data and hydros ===========================

local function sendEachFrame(seconds, module, fn)
	local i = 0
	run(module, seconds, function()
		i = i + 1
		fn(i)
	end)
end

test("A18: 30 controller updates from a near traffic car in a second go out 5 times a second, ending in the last", function()
	local module = ownCars()
	run(module, 1.5)
	local frame = 0
	run(module, 1, function()
		frame = frame + 1
		if frame % 2 == 0 then
			nodesGE.sendControllerData(encode({controllerName = "axleLift", functionName = "setParameters",
				variables = {{lift = frame}}}), 20)
		end
	end)
	run(module, 0.5)
	local out = sent("ctl", 20)
	expect(#out >= 4 and #out <= 7, "controller sends: " .. #out)
	local last = decode(out[#out].data)
	same(last.variables[1].lift, 60, "the last value")
	same(last.controllerName, "axleLift", "controller")
end)

test("A18: a far traffic car's and a still parked car's controller updates go out once a second", function()
	local module = ownCars()
	addCar(30, "traffic", vec(9000, 0, 0), {vel = vec(10, 0, 0)})
	module.onCareerActive(true)
	run(module, 1.5)
	run(module, 3, function(t)
		for _, gid in ipairs({30, 40}) do
			nodesGE.sendControllerData(encode({controllerName = "lightbar", functionName = "setModeIndex",
				variables = {math.floor(t * 100)}}), gid)
		end
	end)
	for _, gid in ipairs({30, 40}) do
		local n = #sent("ctl", gid)
		expect(n >= 2 and n <= 4, "car " .. gid .. " controller sends in 3 s: " .. n)
	end
end)

test("A18: two different break groups broken in the same window both arrive", function()
	local module = ownCars()
	run(module, 1.5)
	nodesGE.sendBreakGroups('["door_L"]', 20)
	run(module, 0.05)
	nodesGE.sendBreakGroups('["hood"]', 20)
	nodesGE.sendBreakGroups('["door_L","bumper_F"]', 20)
	run(module, 1)
	local groups = {}
	for _, s in ipairs(sent("brk", 20)) do
		for _, g in ipairs(decode(s.data)) do groups[g] = (groups[g] or 0) + 1 end
	end
	expect(groups.door_L, "door_L arrived")
	expect(groups.hood, "hood arrived")
	expect(groups.bumper_F, "bumper_F arrived")
	expect(#sent("brk", 20) <= 2, "break group sends: " .. #sent("brk", 20))
end)

test("A18: a stream of break groups from traffic is held to the light rate and loses none", function()
	local module = ownCars()
	run(module, 1.5)
	local broken = {}
	sendEachFrame(1, module, function(i)
		local g = "group" .. i
		broken[g] = true
		nodesGE.sendBreakGroups(encode({g}), 20)
	end)
	run(module, 0.5)
	local arrived = {}
	for _, s in ipairs(sent("brk", 20)) do
		for _, g in ipairs(decode(s.data)) do arrived[g] = true end
	end
	for g in pairs(broken) do expect(arrived[g], "arrived: " .. g) end
	local n = #sent("brk", 20)
	expect(n >= 4 and n <= 7, "break group sends: " .. n)
end)

test("A18: a traffic car's hydros are merged by beam, latest wins, at the light rate", function()
	local module = ownCars()
	run(module, 1.5)
	sendEachFrame(1, module, function(i)
		MPPowertrainGE.sendHydroBeamData(encode({boom = i, arm = i % 2 == 0 and i or nil}), 20)
	end)
	run(module, 0.5)
	local out = sent("hyd", 20)
	expect(#out >= 4 and #out <= 7, "hydro sends: " .. #out)
	local state = {}
	for _, s in ipairs(out) do for k, v in pairs(decode(s.data)) do state[k] = v end end
	same(state.boom, 60, "last boom")
	same(state.arm, 60, "last arm")
end)

test("A18: a toggle is never merged away; each one goes out, after what was held", function()
	local module = ownCars()
	run(module, 1.5)
	nodesGE.sendControllerData(encode({controllerName = "axleLift", functionName = "setParameters",
		variables = {{lift = 1}}}), 20)
	nodesGE.sendControllerData(encode({controllerName = "axleLift", functionName = "setParameters",
		variables = {{lift = 2}}}), 20)
	nodesGE.sendControllerData(encode({controllerName = "lightbar", functionName = "toggleMode", variables = {}}), 20)
	nodesGE.sendControllerData(encode({controllerName = "lightbar", functionName = "toggleMode", variables = {}}), 20)
	run(module, 1)
	local toggles, lastLift = 0, nil
	for _, s in ipairs(sent("ctl", 20)) do
		local d = decode(s.data)
		if d.functionName == "toggleMode" then
			toggles = toggles + 1
			expect(lastLift ~= nil, "the held setting went out before the toggle")
		else
			lastLift = d.variables[1].lift
		end
	end
	same(toggles, 2, "toggles")
	same(lastLift, 2, "the last setting")
end)

test("A18: setting two groups of one controller in the same window keeps both", function()
	local module = ownCars()
	run(module, 1.5)
	local function setGroup(group, state)
		nodesGE.sendControllerData(encode({controllerName = "tirePressureControl", functionName = "setGroupState",
			variables = {group, state}}), 20)
	end
	setGroup("front", true)
	setGroup("rear", true)
	setGroup("front", false)
	run(module, 1)
	local state = {}
	for _, s in ipairs(sent("ctl", 20)) do
		local d = decode(s.data)
		state[d.variables[1]] = d.variables[2]
	end
	same(state.front, false, "front")
	same(state.rear, true, "rear")
end)

test("A18: the player's own cars send break groups, controller data and hydros at once, unchanged", function()
	local module = ownCars()
	run(module, 1.5)
	for _, gid in ipairs({1, 10}) do
		for i = 1, 30 do
			nodesGE.sendBreakGroups('["g' .. i .. '"]', gid)
			nodesGE.sendControllerData('{"controllerName":"axleLift","functionName":"setParameters","variables":[' .. i .. ']}', gid)
			MPPowertrainGE.sendHydroBeamData('{"boom":' .. i .. '}', gid)
		end
		same(#sent("brk", gid), 30, "car " .. gid .. " break group sends")
		same(#sent("ctl", gid), 30, "car " .. gid .. " controller sends")
		same(#sent("hyd", gid), 30, "car " .. gid .. " hydro sends")
		same(sent("brk", gid)[30].data, '["g30"]', "car " .. gid .. " break group text")
		same(sent("ctl", gid)[30].data,
			'{"controllerName":"axleLift","functionName":"setParameters","variables":[30]}', "car " .. gid .. " controller text")
		same(sent("hyd", gid)[30].data, '{"boom":30}', "car " .. gid .. " hydro text")
	end
end)

test("A18: break groups held for a hidden car go out once it is shown", function()
	local module = ownCars()
	run(module, 1.5)
	nodesGE.sendBreakGroups('["wheel_FR"]', 60)
	run(module, 1)
	same(#sent("brk", 60), 0, "sends while hidden")
	game.objects[60].active = true
	run(module, 1)
	same(#sent("brk", 60), 1, "sends once shown")
	same(sent("brk", 60)[1].data, '["wheel_FR"]', "the groups")
end)

test("A18: text that is not JSON goes out unchanged, after what was held", function()
	local module = ownCars()
	run(module, 1.5)
	nodesGE.sendBreakGroups('["a"]', 20)
	nodesGE.sendBreakGroups('["b"]', 20)
	nodesGE.sendBreakGroups("not json", 20)
	local out = sent("brk", 20)
	same(#out >= 1 and out[#out].data, "not json", "the last text")
	local seen = {}
	for i = 1, #out - 1 do for _, g in ipairs(decode(out[i].data)) do seen[g] = true end end
	expect(seen.a and seen.b, "what was held went first")
end)

test("A18: without nodesGE.sendBreakGroups the log says so once and controller data is still merged", function()
	local module = ownCars({noBreakGroups = true})
	module.onCareerActive(true)
	same(countLines(logs, "nodesGE.sendBreakGroups missing"), 1, "warnings")
	run(module, 1.5)
	for _ = 1, 20 do
		nodesGE.sendControllerData(encode({controllerName = "axleLift", functionName = "setParameters",
			variables = {{lift = 1}}}), 20)
	end
	expect(#sent("ctl", 20) <= 1, "controller sends: " .. #sent("ctl", 20))
end)

test("A18: leaving the server puts BeamMP's break group, controller and hydro sends back", function()
	local module = ownCars()
	expect(nodesGE.sendBreakGroups ~= game.originalSends.brk, "break groups wrapped")
	expect(nodesGE.sendControllerData ~= game.originalSends.ctl, "controller data wrapped")
	expect(MPPowertrainGE.sendHydroBeamData ~= game.originalSends.hyd, "hydros wrapped")
	module.onBeamMPServerLeave()
	same(nodesGE.sendBreakGroups, game.originalSends.brk, "break groups")
	same(nodesGE.sendControllerData, game.originalSends.ctl, "controller data")
	same(MPPowertrainGE.sendHydroBeamData, game.originalSends.hyd, "hydros")
end)
