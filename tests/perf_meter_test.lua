-- mileage/perfMeter.lua: while the career runs on a server, each game counts its frame
-- time, long frames, the updates it sent and received and its cars, and every 30 seconds
-- writes one log line and sends the same numbers to the server (mileagePerfReport).

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileage/perfMeter.lua"
local COMPAT = "Resources/Client/Mileage/lua/ge/extensions/mileage/compat.lua"

local logs, game

local function vec(x, y, z) return {x = x, y = y, z = z} end

-- A car on the stand-in game. kind: "player", "own", "traffic", "parked", "remote",
-- "remoteTraffic". owner is the server id's player part.
local function addCar(gid, kind, pos, fields)
	local own = kind ~= "remote" and kind ~= "remoteTraffic"
	local veh = {id = gid, pos = pos or vec(0, 0, 0), active = true, own = own}
	for k, v in pairs(fields or {}) do veh[k] = v end
	if kind == "traffic" then veh.isTraffic = "true" end
	if kind == "parked" then veh.isParked = "true" end
	function veh:getActive() return self.active end
	function veh:getPosition() return self.pos end
	game.objects[gid] = veh
	local sid = (own and "0" or tostring(veh.owner or 1)) .. "-" .. gid
	game.vehicles[sid] = {gameVehicleID = gid}
	if kind == "remoteTraffic" then game.remoteTraffic[sid] = true end
	if kind == "player" then game.playerVehicle = gid end
	return veh
end

local function setup(opts)
	opts = opts or {}
	logs = {}
	game = {objects = {}, vehicles = {}, playerVehicle = -1, remoteTraffic = {}, toServer = {}, handled = {},
		getVehiclesCalls = 0}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	function TriggerServerEvent(name, data) table.insert(game.toServer, {name = name, data = data}) end
	jsonEncode = function(v) game.lastReport = v; return "report" end
	MPCoreNetwork = {isMPSession = function() return opts.mp ~= false end}
	extensions = {mileage_compat = dofile(COMPAT)}
	MPVehicleGE = {
		getVehicles = function() game.getVehiclesCalls = game.getVehiclesCalls + 1; return game.vehicles end,
		isOwn = function(gid) local v = game.objects[gid]; return v ~= nil and v.own end,
	}
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
	local function receiver(name)
		return {handle = function(raw, extra)
			table.insert(game.handled, {name = name, raw = raw, extra = extra})
			return "handled " .. name
		end}
	end
	positionGE = not opts.noPosition and receiver("pos") or nil
	MPElectricsGE = receiver("elec")
	MPInputsGE = receiver("inp")
	game.originals = {pos = positionGE and positionGE.handle, elec = MPElectricsGE.handle, inp = MPInputsGE.handle}
	return dofile(SOURCE)
end

local function frames(module, n, dt)
	for _ = 1, n do module.onUpdate(dt) end
end

-- A player's car, an own car, 3 own traffic cars and 2 parked cars, one hidden; another
-- player's car 300 m away and one 900 m away, and another player's traffic car.
local function busyGame()
	local module = setup()
	addCar(1, "player", vec(0, 0, 0))
	addCar(2, "own", vec(5, 0, 0))
	for i = 0, 2 do addCar(10 + i, "traffic", vec(100 + i, 0, 0)) end
	addCar(20, "parked", vec(50, 0, 0))
	addCar(21, "parked", vec(55, 0, 0), {active = false})
	addCar(30, "remote", vec(300, 0, 0), {owner = 1})
	addCar(31, "remote", vec(900, 0, 0), {owner = 2})
	addCar(32, "remoteTraffic", vec(10, 0, 0), {owner = 2})
	module.onCareerActive(true)
	return module
end

local function reports()
	local list = {}
	for _, m in ipairs(game.toServer) do
		if m.name == "mileagePerfReport" then table.insert(list, m) end
	end
	return list
end

--== the report ==============================================================

test("after 30 s one log line and one report hold the frame time, the long frame, the cars and the players near", function()
	local module = busyGame()
	frames(module, 900, 1 / 60)
	module.onUpdate(0.2)
	frames(module, 888, 1 / 60)
	same(#reports(), 1, "reports sent")
	same(reports()[1].data, "report", "the encoded report")
	same(countLines(logs, "I mileage.perf: 30 s: 1789 frames"), 1, "log lines")
	local r = game.lastReport
	same(r.v, 1, "version")
	same(r.s, 30, "seconds")
	same(r.frames, 1789, "frames")
	same(r.worstMs, 200, "worst frame")
	same(r.hitches, 1, "frames over 100 ms")
	expect(r.avgMs > 16.7 and r.avgMs < 16.9, "average frame: " .. r.avgMs)
	same(r.cars.own, 2, "own cars, the driven one included")
	same(r.cars.ownTraffic, 3, "own driving traffic")
	same(r.cars.ownParked, 2, "own parked cars")
	same(r.cars.remote, 2, "other players' cars")
	same(r.cars.remoteTraffic, 1, "other players' traffic")
	same(r.cars.hidden, 1, "hidden cars")
	same(r.near[1], 1, "fewest players near")
	same(r.near[2], 1, "most players near")
	for _, key in ipairs({"sent", "recv", "built"}) do expect(r[key] ~= nil, "report has " .. key) end
end)

test("a second report comes 30 s after the first and the counts start again", function()
	local module = busyGame()
	frames(module, 750, 0.02)
	module.sent("pos", true, false)
	frames(module, 2250, 0.02)
	same(#reports(), 2, "reports in 60 s")
	same(game.lastReport.sent.traffic.pos[1], 0, "the sends of the first window are not in the second")
	same(game.lastReport.frames, 1500, "frames in the second window")
end)

test("sent and built calls land in the next report, own and traffic apart", function()
	local module = busyGame()
	module.sent("pos", false, true)
	module.sent("pos", false, true)
	module.sent("pos", true, true)
	module.sent("pos", true, false)
	module.sent("elec", true, false)
	module.sent("inp", false, true)
	module.sent("nonsense", true, true)
	module.flushed("elec")
	module.flushed("nonsense")
	module.built()
	module.built()
	frames(module, 1500, 0.02)
	local r = game.lastReport
	same(r.sent.own.pos[1], 2, "own positions asked")
	same(r.sent.own.pos[2], 2, "own positions let through")
	same(r.sent.traffic.pos[1], 2, "traffic positions asked")
	same(r.sent.traffic.pos[2], 1, "traffic positions let through")
	same(r.sent.traffic.elec[1], 1, "traffic lights asked")
	same(r.sent.traffic.elec[2], 1, "traffic lights let through, the merged set sent later")
	same(r.sent.own.inp[2], 1, "own inputs let through")
	same(r.built, 2, "cars built")
end)

test("the players near go from fewest to most as another player drives up", function()
	local module = busyGame()
	frames(module, 500, 0.02)
	game.objects[31].pos = vec(400, 0, 0)
	frames(module, 1000, 0.02)
	same(game.lastReport.near[1], 1, "fewest")
	same(game.lastReport.near[2], 2, "most")
end)

-- Rejects a near count that ignores whether the car is shown: a car switched off on this
-- game is not a player driving with this one.
test("another player's car hidden on this game does not count as near", function()
	local module = busyGame()
	game.objects[31].pos = vec(400, 0, 0)
	game.objects[31].active = false
	frames(module, 1500, 0.02)
	same(game.lastReport.near[1], 1, "fewest")
	same(game.lastReport.near[2], 1, "most")
end)

-- Rejects a meter that fails or guesses a distance when this player has no car.
test("with no car of its own the game reports no players near and still counts its cars", function()
	local module = setup()
	addCar(30, "remote", vec(10, 0, 0), {owner = 1})
	module.onCareerActive(true)
	frames(module, 1500, 0.02)
	same(#reports(), 1, "reports")
	same(game.lastReport.near[1], 0, "fewest")
	same(game.lastReport.near[2], 0, "most")
	same(game.lastReport.cars.remote, 1, "other players' cars")
end)

-- Rejects a hitch test written as >= : only a frame longer than 100 ms is a long frame.
test("a frame of exactly 100 ms is not a long frame, one just longer is", function()
	local module = busyGame()
	module.onUpdate(0.1)
	module.onUpdate(0.1001)
	frames(module, 1500, 0.02)
	same(game.lastReport.hitches, 1, "frames over 100 ms")
	same(game.lastReport.worstMs, 100, "worst frame")
end)

-- Rejects a meter that raises or turns its clock back on a frame time it cannot use.
test("a missing or negative frame time counts the frame and adds no time", function()
	local module = busyGame()
	module.onUpdate(nil)
	module.onUpdate(-5)
	frames(module, 1500, 0.02)
	same(#reports(), 1, "reports")
	same(game.lastReport.frames, 1502, "frames")
	same(game.lastReport.hitches, 0, "frames over 100 ms")
end)

test("cars are counted once a second, not every frame", function()
	local module = busyGame()
	frames(module, 600, 1 / 60)
	expect(game.getVehiclesCalls <= 11, "car lists read in 10 s: " .. game.getVehiclesCalls)
end)

--== received updates ========================================================

test("every received update is counted by kind and still reaches BeamMP with the same arguments", function()
	local module = busyGame()
	same(positionGE.handle("Zp:1-30:{}", 7), "handled pos", "position result")
	positionGE.handle("Zp:1-30:{}")
	MPElectricsGE.handle("We:1-30:{}")
	MPInputsGE.handle("Vi:1-30:{}")
	MPInputsGE.handle("Vi:1-30:{}")
	MPInputsGE.handle("Vi:1-30:{}")
	same(#game.handled, 6, "updates passed on")
	same(game.handled[1].raw, "Zp:1-30:{}", "first update's text")
	same(game.handled[1].extra, 7, "first update's second argument")
	frames(module, 1500, 0.02)
	same(game.lastReport.recv.pos, 2, "positions received")
	same(game.lastReport.recv.elec, 1, "lights received")
	same(game.lastReport.recv.inp, 3, "inputs received")
end)

test("with no positionGE the meter logs it once and still counts lights and inputs", function()
	local module = setup({noPosition = true})
	addCar(1, "player")
	module.onCareerActive(true)
	module.onCareerActive(true)
	MPElectricsGE.handle("We:1-30:{}")
	frames(module, 1500, 0.02)
	same(countLines(logs, "positionGE.handle missing"), 1, "warnings")
	same(game.lastReport.recv.elec, 1, "lights received")
end)

test("a meter that fails reading the cars skips that count, logs once and every update still goes through", function()
	local module = busyGame()
	be.getObjectByID = function() error("lookup broke") end
	local ok, err = pcall(frames, module, 1500, 0.02)
	expect(ok, "did not raise: " .. tostring(err))
	positionGE.handle("Zp:1-30:{}")
	same(#game.handled, 1, "update passed on")
	same(countLines(logs, "cost meter failed"), 1, "error lines")
end)

--== switching on and off ====================================================

test("off a server nothing is wrapped and nothing is sent", function()
	local module = setup({mp = false})
	addCar(1, "player")
	module.onCareerActive(true)
	frames(module, 1600, 0.02)
	same(positionGE.handle, game.originals.pos, "positionGE.handle")
	same(#reports(), 0, "reports")
end)

test("leaving the server, an ended career and unloading put BeamMP's functions back and stop the reports", function()
	local module = busyGame()
	expect(MPInputsGE.handle ~= game.originals.inp, "wrapped while on the server")
	module.onBeamMPServerLeave()
	same(positionGE.handle, game.originals.pos, "positions after leaving")
	same(MPElectricsGE.handle, game.originals.elec, "lights after leaving")
	same(MPInputsGE.handle, game.originals.inp, "inputs after leaving")
	frames(module, 1600, 0.02)
	same(#reports(), 0, "reports after leaving")
	module.onCareerActive(true)
	expect(MPInputsGE.handle ~= game.originals.inp, "wrapped again on the next career start")
	module.onCareerActive(false)
	same(MPInputsGE.handle, game.originals.inp, "after the career ended")
	module.onCareerActive(true)
	module.onExtensionUnloaded()
	same(MPInputsGE.handle, game.originals.inp, "after unloading")
end)

test("a career start while already active wraps nothing twice", function()
	local module = busyGame()
	module.onCareerActive(true)
	positionGE.handle("Zp:1-30:{}")
	frames(module, 1500, 0.02)
	same(game.lastReport.recv.pos, 1, "one position counted once")
end)

test("engine updates are counted apart, own and traffic, and appear in the log line", function()
	local module = busyGame()
	module.sent("eng", true, false)
	module.sent("eng", true, true)
	module.flushed("eng")
	module.sent("eng", false, true)
	frames(module, 1500, 0.02)
	same(game.lastReport.sent.traffic.eng[1], 2, "traffic engine updates asked")
	same(game.lastReport.sent.traffic.eng[2], 2, "traffic engine updates sent")
	same(game.lastReport.sent.own.eng[2], 1, "own engine updates sent")
	same(countLines(logs, "traffic pos 0/0 elec 0/0 inp 0/0 eng 2/2"), 1, "log line")
end)
