-- mileage/positionRate.lua: Mileage's checks around BeamMP's sends of each own car's
-- position (positionGE.sendVehiclePosRot), lights (MPElectricsGE.sendElectrics) and
-- inputs (MPInputsGE.sendInputs). A parked car standing still sends its position once a
-- second, driving traffic more than 500 m from every other player's car twice a second,
-- other driving traffic 20 times a second, a hidden car never; traffic's lights and
-- inputs are merged and sent at a steady rate; every other send goes through untouched.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileage/positionRate.lua"
local COMPAT = "Resources/Client/Mileage/lua/ge/extensions/mileage/compat.lua"

local FRAME = 0.02 -- BeamMP's position tick rate

local logs, game

-- The flat JSON objects BeamMP's lights and inputs use: string keys, number or string
-- values. Keys are written in order, so equal sets give equal text.
function flatEncode(t)
	local keys = {}
	for k in pairs(t) do table.insert(keys, k) end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do
		local v = t[k]
		table.insert(parts, string.format('"%s":%s', k, type(v) == "string" and ('"' .. v .. '"') or tostring(v)))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

function flatDecode(text)
	if type(text) ~= "string" or not text:match("^%s*{.*}%s*$") then return nil end
	local t = {}
	for k, v in text:gmatch('"([^"]+)"%s*:%s*("?[^,}"]*"?)') do
		if v:sub(1, 1) == '"' then t[k] = v:sub(2, -2) else t[k] = tonumber(v) end
	end
	return t
end

local function vec(x, y, z)
	local v = {x = x, y = y, z = z}
	function v:length() return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end
	return v
end

-- A car on the stand-in game. kind: "player", "own", "traffic", "parked", "remote".
local function addCar(gid, kind, pos, fields)
	local veh = {id = gid, pos = pos or vec(0, 0, 0), vel = vec(0, 0, 0), active = true, own = kind ~= "remote",
		kind = kind, positionReads = 0}
	for k, v in pairs(fields or {}) do veh[k] = v end
	if kind == "traffic" then veh.isTraffic = "true" end
	if kind == "parked" then veh.isParked = "true" end
	function veh:getActive() return self.active end
	function veh:getPosition() self.positionReads = self.positionReads + 1; return self.pos end
	function veh:getVelocity() return self.vel end
	game.objects[gid] = veh
	game.vehicles[(veh.own and "0-" or "1-") .. gid] = {gameVehicleID = gid}
	if kind == "player" then game.playerVehicle = gid end
	return veh
end

local function setup(opts)
	opts = opts or {}
	logs = {}
	game = {objects = {}, vehicles = {}, playerVehicle = -1, forwarded = {}, remoteTraffic = {}}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	MPCoreNetwork = {isMPSession = function() return opts.mp ~= false end}
	extensions = {mileage_compat = dofile(COMPAT)}
	MPVehicleGE = {
		getVehicles = function() return game.vehicles end,
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
	game.original = function(data, gid)
		game.forwarded[gid] = (game.forwarded[gid] or 0) + 1
		game.lastData = data
	end
	positionGE = nil
	if opts.positionGE ~= false then positionGE = {} end
	if positionGE and not opts.noSend then positionGE.sendVehiclePosRot = game.original end
	-- BeamMP's lights and inputs sends record each text they get, by car.
	game.sentElec, game.sentInp = {}, {}
	local function recorder(into)
		return function(data, gid)
			into[gid] = into[gid] or {}
			table.insert(into[gid], data)
		end
	end
	MPElectricsGE = opts.noElectrics and {} or {sendElectrics = recorder(game.sentElec)}
	MPInputsGE = {sendInputs = recorder(game.sentInp)}
	game.sentEng, game.sentPtr = {}, {}
	MPPowertrainGE = {sendEngineData = recorder(game.sentEng), sendLivePowertrain = recorder(game.sentPtr)}
	game.originalElec, game.originalInp = MPElectricsGE.sendElectrics, MPInputsGE.sendInputs
	jsonDecode, jsonEncode = flatDecode, flatEncode
	if opts.meter then
		game.meter = {}
		extensions.mileage_perfMeter = {
			sent = function(update, isTraffic, through)
				local key = update .. (isTraffic and ".traffic" or ".own")
				local c = game.meter[key] or {0, 0}
				c[1], c[2] = c[1] + 1, c[2] + (through and 1 or 0)
				game.meter[key] = c
			end,
			flushed = function(update)
				local key = update .. ".traffic"
				local c = game.meter[key] or {0, 0}
				c[2] = c[2] + 1
				game.meter[key] = c
			end,
		}
	end
	return dofile(SOURCE)
end

-- Runs `seconds` of frames: the module's update, then BeamMP's send for every own car.
local function run(module, seconds)
	for _ = 1, math.floor(seconds / FRAME + 0.5) do
		module.onUpdate(FRAME)
		for gid, veh in pairs(game.objects) do
			if veh.own then positionGE.sendVehiclePosRot('{"pos":[0,0,0]}', gid) end
		end
	end
end

local function forwarded(gid) return game.forwarded[gid] or 0 end

-- One player's game: the car they drive, own cars, near and far traffic, still and
-- moving parked cars and hidden cars; another player's car at the origin and another
-- player's traffic car far away.
local function busyGame(opts)
	local module = setup(opts)
	addCar(1, "player", vec(10, 0, 0))
	addCar(500, "remote", vec(0, 0, 0))
	addCar(501, "remote", vec(5000, 5000, 0))
	game.remoteTraffic["1-501"] = true
	for i = 0, 3 do addCar(10 + i, "own", vec(20, i, 0)) end
	for i = 0, 4 do addCar(20 + i, "traffic", vec(100 + i, 0, 0)) end
	for i = 0, 4 do addCar(30 + i, "traffic", vec(800 + i * 10, 0, 0)) end
	-- far from the other player, near the other player's traffic only
	addCar(35, "traffic", vec(5000, 5010, 0))
	for i = 0, 7 do addCar(40 + i, "parked", vec(2000, i * 5, 0)) end
	for i = 0, 3 do addCar(50 + i, "parked", vec(50, i * 5, 0), {vel = vec(2, 0, 0)}) end
	for i = 0, 2 do addCar(60 + i, "traffic", vec(30, i, 0), {active = false}) end
	module.onCareerActive(true)
	return module
end

--== the rules ===============================================================

test("over 10 seconds each car's positions reach BeamMP at the rate of its rule", function()
	local module = busyGame()
	run(module, 10)
	local sends = math.floor(10 / FRAME + 0.5)
	same(forwarded(1), sends, "the car the player drives")
	for i = 0, 3 do same(forwarded(10 + i), sends, "own car " .. (10 + i) .. " that is not traffic") end
	for i = 0, 4 do
		local n = forwarded(20 + i)
		expect(n >= 199 and n <= 201, "traffic within 500 m of another player's car " .. (20 + i) .. ": " .. n)
	end
	for i = 0, 4 do
		local n = forwarded(30 + i)
		expect(n >= 19 and n <= 21, "far traffic " .. (30 + i) .. ": " .. n)
	end
	local nearTheirTraffic = forwarded(35)
	expect(nearTheirTraffic >= 19 and nearTheirTraffic <= 21,
		"far traffic next to another player's traffic only: " .. nearTheirTraffic)
	for i = 0, 7 do
		local n = forwarded(40 + i)
		expect(n >= 9 and n <= 11, "still parked car " .. (40 + i) .. ": " .. n)
	end
	for i = 0, 3 do same(forwarded(50 + i), sends, "moving parked car " .. (50 + i)) end
	for i = 0, 2 do same(forwarded(60 + i), 0, "hidden car " .. (60 + i)) end
end)

test("a forwarded send is BeamMP's own, unchanged", function()
	local module = busyGame()
	run(module, 0.1)
	same(game.lastData, '{"pos":[0,0,0]}', "data passed on")
end)

test("cars are read once a second, not on every send", function()
	local module = busyGame()
	run(module, 10)
	local reads = 0
	for _, veh in pairs(game.objects) do reads = reads + veh.positionReads end
	expect(reads <= 11 * 40, "position reads in 10 seconds: " .. reads)
end)

test("a still parked car that gets hit sends every position within a quarter of a second", function()
	local module = busyGame()
	run(module, 2)
	-- The other player drives into it.
	game.objects[500].pos = vec(2000, 5, 0)
	game.objects[40].vel = vec(4, 0, 0)
	run(module, 0.26)
	local before = forwarded(40)
	run(module, 1)
	same(forwarded(40) - before, 50, "sends in the second after the hit")
end)

test("a hidden traffic car shown again near a player sends 20 positions a second within a quarter of a second", function()
	local module = busyGame()
	run(module, 2)
	game.objects[60].active = true
	run(module, 0.26)
	local before = forwarded(60)
	run(module, 0.5)
	local n = forwarded(60) - before
	expect(n >= 9 and n <= 11, "sends in the half second after it was shown: " .. n)
end)

test("a hidden own car that is not traffic sends every position within a quarter of a second of being shown", function()
	local module = busyGame()
	addCar(64, "own", vec(30, 9, 0), {active = false})
	run(module, 1.5)
	same(forwarded(64), 0, "sends while hidden")
	game.objects[64].active = true
	run(module, 0.26)
	local before = forwarded(64)
	run(module, 0.2)
	same(forwarded(64) - before, 10, "sends in the fifth of a second after it was shown")
end)

test("traffic that comes within 500 m of another player's car sends 20 positions a second from the next second", function()
	local module = busyGame()
	run(module, 2)
	game.objects[30].pos = vec(300, 0, 0)
	run(module, 1)
	local before = forwarded(30)
	run(module, 1)
	local n = forwarded(30) - before
	expect(n >= 19 and n <= 21, "sends in the next second: " .. n)
end)

test("a car the player climbs into sends every position from the next second", function()
	local module = busyGame()
	run(module, 2)
	game.playerVehicle = 40
	run(module, 1)
	local before = forwarded(40)
	run(module, 1)
	same(forwarded(40) - before, 50, "sends in the next second")
end)

test("a car spawned since the last check sends every position until it is checked", function()
	local module = busyGame()
	run(module, 1.5)
	addCar(70, "parked", vec(3000, 0, 0))
	run(module, 0.4)
	same(forwarded(70), 20, "sends before its first check")
end)

--== stepping aside ==========================================================

test("with no positionGE the check logs one warning naming the function and sends stay BeamMP's", function()
	local module = setup({positionGE = false})
	addCar(1, "player")
	local ok, err = pcall(module.onCareerActive, true)
	expect(ok, "did not raise: " .. tostring(err))
	module.onCareerActive(true)
	pcall(module.onUpdate, FRAME)
	same(countLines(logs, "positionGE.sendVehiclePosRot missing"), 1, "warnings")
	same(countLines(logs, "position check active"), 0, "active lines")
end)

test("with positionGE but no sendVehiclePosRot the check warns once and wraps nothing", function()
	local module = setup({noSend = true})
	module.onCareerActive(true)
	module.onCareerActive(true)
	same(positionGE.sendVehiclePosRot, nil, "positionGE.sendVehiclePosRot")
	same(countLines(logs, "positionGE.sendVehiclePosRot missing"), 1, "warnings")
end)

test("the log says once that the check is active", function()
	local module = busyGame()
	module.onCareerActive(true)
	same(countLines(logs, "position check active"), 1, "active lines")
end)

test("a check that fails reading the cars forwards every send and logs it once", function()
	local module = busyGame()
	run(module, 2)
	be.getObjectByID = function() error("lookup broke") end
	local ok, err = pcall(run, module, 2)
	expect(ok, "did not raise: " .. tostring(err))
	local before = forwarded(40)
	pcall(run, module, 1)
	same(forwarded(40) - before, 50, "a still parked car's sends once the check failed")
	same(countLines(logs, "send check failed"), 1, "error lines")
end)

test("leaving the server and unloading put BeamMP's function back", function()
	local module = busyGame()
	expect(positionGE.sendVehiclePosRot ~= game.original, "wrapped while on the server")
	module.onBeamMPServerLeave()
	same(positionGE.sendVehiclePosRot, game.original, "after leaving")
	module.onCareerActive(true)
	expect(positionGE.sendVehiclePosRot ~= game.original, "wrapped again on the next career start")
	module.onExtensionUnloaded()
	same(positionGE.sendVehiclePosRot, game.original, "after unloading")
end)

test("a reloaded positionGE is wrapped again on the next career start, the old one left alone", function()
	local module = busyGame()
	local old = positionGE
	local wrappedOld = old.sendVehiclePosRot
	local reloadedSends = 0
	positionGE = {sendVehiclePosRot = function() reloadedSends = reloadedSends + 1 end}
	local reloadedOriginal = positionGE.sendVehiclePosRot
	module.onCareerActive(true)
	expect(positionGE.sendVehiclePosRot ~= reloadedOriginal, "the reloaded module is wrapped")
	same(old.sendVehiclePosRot, wrappedOld, "the old module is not touched")
	module.onBeamMPServerLeave()
	same(positionGE.sendVehiclePosRot, reloadedOriginal, "the reloaded module's function back after leaving")
end)

test("off a server nothing is wrapped", function()
	local module = setup({mp = false})
	module.onCareerActive(true)
	same(positionGE.sendVehiclePosRot, game.original, "positionGE.sendVehiclePosRot")
end)

test("a career that is no longer active puts BeamMP's function back", function()
	local module = busyGame()
	module.onCareerActive(false)
	same(positionGE.sendVehiclePosRot, game.original, "positionGE.sendVehiclePosRot")
end)

test("traffic exactly 500 m from another player's car sends 20 positions a second, traffic just past it twice a second", function()
	local module = setup()
	addCar(1, "player", vec(0, 0, 0))
	addCar(500, "remote", vec(0, 0, 0))
	addCar(20, "traffic", vec(500, 0, 0))
	addCar(21, "traffic", vec(0, 501, 0))
	module.onCareerActive(true)
	run(module, 10)
	local near = forwarded(20)
	expect(near >= 199 and near <= 201, "traffic at 500 m: " .. near)
	local n = forwarded(21)
	expect(n >= 19 and n <= 21, "traffic at 501 m: " .. n)
end)

test("a moving parked car far from every other player sends every position, as it is not driving traffic", function()
	local module = setup()
	addCar(1, "player", vec(0, 0, 0))
	addCar(500, "remote", vec(0, 0, 0))
	addCar(40, "parked", vec(2000, 0, 0), {vel = vec(3, 0, 0)})
	module.onCareerActive(true)
	run(module, 2)
	same(forwarded(40), 100, "positions of a moving parked car 2 km away")
end)

test("a parked car moving at half a metre a second sends every position, one just slower once a second", function()
	local module = setup()
	addCar(1, "player", vec(0, 0, 0))
	addCar(500, "remote", vec(0, 0, 0))
	addCar(40, "parked", vec(50, 0, 0), {vel = vec(0.5, 0, 0)})
	addCar(41, "parked", vec(50, 5, 0), {vel = vec(0.49, 0, 0)})
	module.onCareerActive(true)
	run(module, 10)
	same(forwarded(40), 500, "parked car at 0.5 m/s")
	local n = forwarded(41)
	expect(n >= 9 and n <= 11, "parked car at 0.49 m/s: " .. n)
end)

--== the cost meter ==========================================================

test("the meter hears every position BeamMP asked to send, own and traffic apart, and how many went through", function()
	local module = busyGame({meter = true})
	run(module, 10)
	local own, traffic = game.meter["pos.own"], game.meter["pos.traffic"]
	local ownSent, trafficSent, asked = 0, 0, 0
	for gid, veh in pairs(game.objects) do
		if veh.own then
			asked = asked + 500
			if gid == 1 or (gid >= 10 and gid <= 13) or (gid >= 50 and gid <= 53) then
				ownSent = ownSent + forwarded(gid)
			else
				trafficSent = trafficSent + forwarded(gid)
			end
		end
	end
	same(own[1] + traffic[1], asked, "positions asked")
	same(own[1], own[2], "own positions all went through")
	same(own[2] + traffic[2], ownSent + trafficSent, "positions that went through")
	expect(traffic[2] * 2 < traffic[1], "traffic positions let through " .. traffic[2] .. " of " .. traffic[1])
end)

--== lights and inputs =======================================================

-- Calls BeamMP's inputs or lights send for a car once per frame of `seconds`, with the
-- text make(frame) gives (nil skips that frame), running the module's update each frame.
local function sendEach(module, seconds, fn, gid, make)
	for frame = 1, math.floor(seconds / FRAME + 0.5) do
		module.onUpdate(FRAME)
		local data = make(frame)
		if data then fn(data, gid) end
	end
end

local function texts(into, gid) return into[gid] or {} end

-- The state a car shows on another game after every text, applied in order.
local function applied(list)
	local state = {}
	for _, text in ipairs(list) do
		for k, v in pairs(flatDecode(text)) do state[k] = v end
	end
	return state
end

test("a near traffic car's inputs go out 10 times a second, merged, ending in the last throttle", function()
	local module = busyGame()
	run(module, 1)
	local all = {}
	sendEach(module, 2, function(d, g) table.insert(all, d); MPInputsGE.sendInputs(d, g) end, 20, function(frame)
		return flatEncode({t = frame / 100})
	end)
	local sent = texts(game.sentInp, 20)
	expect(#sent >= 19 and #sent <= 21, "inputs sent in 2 s: " .. #sent)
	run(module, 0.1)
	same(applied(sent).t, applied(all).t, "the last throttle")
end)

test("a near traffic car's lights go out 5 times a second and a far one's once a second", function()
	local module = busyGame()
	run(module, 1)
	sendEach(module, 4, function(d, g) MPElectricsGE.sendElectrics(d, g); MPElectricsGE.sendElectrics(d, 30) end, 20,
		function(frame) return flatEncode({lowbeam = frame % 2}) end)
	local near, far = #texts(game.sentElec, 20), #texts(game.sentElec, 30)
	expect(near >= 19 and near <= 21, "near lights sent in 4 s: " .. near)
	expect(far >= 4 and far <= 5, "far lights sent in 4 s: " .. far)
end)

test("the merged sends end in the same state as every single update applied in order, isnil included", function()
	local module = busyGame()
	run(module, 1)
	local all = {}
	local script = {
		[1] = {signal_L = 1, lowbeam = 1}, [3] = {brake = 0.5}, [4] = {signal_L = "isnil"}, [7] = {hazard = 1},
		[8] = {lowbeam = 0}, [12] = {brake = 0}, [13] = {horn = 1}, [14] = {horn = "isnil"},
	}
	sendEach(module, 1, function(d, g) table.insert(all, d); MPElectricsGE.sendElectrics(d, g) end, 20, function(frame)
		return script[frame] and flatEncode(script[frame]) or nil
	end)
	run(module, 1)
	local got, wanted = applied(texts(game.sentElec, 20)), applied(all)
	for k, v in pairs(wanted) do same(got[k], v, "lights value " .. k) end
	for k, v in pairs(got) do same(wanted[k], v, "lights value " .. k) end
end)

test("a change sent once and then never again still goes out within the spacing", function()
	local module = busyGame()
	run(module, 1)
	MPElectricsGE.sendElectrics(flatEncode({lowbeam = 1}), 30)
	MPElectricsGE.sendElectrics(flatEncode({lowbeam = 0}), 30)
	same(#texts(game.sentElec, 30), 1, "first change of a far car sent at once")
	run(module, 1.02)
	same(#texts(game.sentElec, 30), 2, "the held change after a second, with no new call")
	same(applied(texts(game.sentElec, 30)).lowbeam, 0, "the last value")
end)

test("the player's own cars send lights and inputs at once, with BeamMP's own text", function()
	local module = busyGame()
	run(module, 1)
	for _, gid in ipairs({1, 10, 50}) do
		for i = 1, 30 do
			local text = '{"t":' .. i .. '}'
			MPInputsGE.sendInputs(text, gid)
			MPElectricsGE.sendElectrics(text, gid)
		end
		same(#texts(game.sentInp, gid), 30, "inputs of car " .. gid)
		same(#texts(game.sentElec, gid), 30, "lights of car " .. gid)
		same(texts(game.sentInp, gid)[30], '{"t":30}', "the text of car " .. gid)
	end
end)

test("a hidden car's lights wait until it is shown, then go out at once", function()
	local module = busyGame()
	run(module, 1)
	MPElectricsGE.sendElectrics(flatEncode({lowbeam = 1}), 60)
	MPElectricsGE.sendElectrics(flatEncode({signal_R = 1}), 60)
	run(module, 3)
	same(#texts(game.sentElec, 60), 0, "sent while hidden")
	game.objects[60].active = true
	run(module, 0.26)
	same(#texts(game.sentElec, 60), 1, "sent once shown")
	local state = applied(texts(game.sentElec, 60))
	same(state.lowbeam, 1, "lowbeam")
	same(state.signal_R, 1, "right signal")
end)

-- Rejects a gate that drops what it held once a car leaves its rule: the player taking a
-- traffic car must not leave its last light change unsent.
test("lights held for a traffic car the player climbs into go out within a second, ending in the last value", function()
	local module = busyGame()
	run(module, 1)
	MPElectricsGE.sendElectrics(flatEncode({lowbeam = 1}), 30)
	MPElectricsGE.sendElectrics(flatEncode({lowbeam = 0, signal_L = 1}), 30)
	same(#texts(game.sentElec, 30), 1, "sent before the player climbs in")
	game.playerVehicle = 30
	run(module, 1)
	same(#texts(game.sentElec, 30), 2, "the held set once the car is the player's")
	local state = applied(texts(game.sentElec, 30))
	same(state.lowbeam, 0, "lowbeam")
	same(state.signal_L, 1, "left signal")
	MPElectricsGE.sendElectrics('{"horn":1}', 30)
	same(texts(game.sentElec, 30)[3], '{"horn":1}', "the next call goes out at once with BeamMP's own text")
end)

-- Rejects a gate with no spacing for still parked cars (their inputs would be held for
-- good) or one that sends them every call.
test("a still parked car's inputs go out once a second, ending in the last value", function()
	local module = busyGame()
	run(module, 1)
	sendEach(module, 4, MPInputsGE.sendInputs, 40, function(frame) return flatEncode({t = frame}) end)
	local n = #texts(game.sentInp, 40)
	expect(n >= 4 and n <= 5, "parked inputs sent in 4 s: " .. n)
	run(module, 1.02)
	same(applied(texts(game.sentInp, 40)).t, 200, "the last input")
end)

test("text that is not a JSON object goes out unchanged, and a failing check sends the call through", function()
	local module = busyGame()
	run(module, 1)
	MPInputsGE.sendInputs("not json", 20)
	same(texts(game.sentInp, 20)[1], "not json", "text passed on")
	jsonDecode = function() error("decoder broke") end
	MPInputsGE.sendInputs('{"t":1}', 20)
	MPInputsGE.sendInputs('{"t":2}', 20)
	same(#texts(game.sentInp, 20), 3, "calls passed on once the check failed")
end)

test("without MPElectricsGE.sendElectrics the log says so once and positions and inputs are still checked", function()
	local module = busyGame({noElectrics = true})
	module.onCareerActive(true)
	same(countLines(logs, "MPElectricsGE.sendElectrics missing"), 1, "warnings")
	same(MPElectricsGE.sendElectrics, nil, "nothing put in its place")
	run(module, 2)
	sendEach(module, 1, MPInputsGE.sendInputs, 20, function(frame) return flatEncode({t = frame}) end)
	local n = #texts(game.sentInp, 20)
	expect(n >= 9 and n <= 11, "inputs of near traffic still merged: " .. n)
	local p = forwarded(30)
	expect(p <= 7, "far traffic positions still slowed: " .. p)
end)

test("leaving the server puts BeamMP's lights and inputs back and drops what was held", function()
	local module = busyGame()
	run(module, 1)
	MPElectricsGE.sendElectrics(flatEncode({lowbeam = 1}), 60)
	expect(MPElectricsGE.sendElectrics ~= game.originalElec, "wrapped while on the server")
	module.onBeamMPServerLeave()
	same(MPElectricsGE.sendElectrics, game.originalElec, "lights after leaving")
	same(MPInputsGE.sendInputs, game.originalInp, "inputs after leaving")
	module.onCareerActive(true)
	game.objects[60].active = true
	run(module, 2)
	same(#texts(game.sentElec, 60), 0, "nothing held from before leaving was sent")
	module.onCareerActive(false)
	same(MPInputsGE.sendInputs, game.originalInp, "inputs after the career ended")
end)

test("the meter hears held lights as asked and the merged set sent later as let through", function()
	local module = busyGame({meter = true})
	run(module, 1)
	MPElectricsGE.sendElectrics(flatEncode({lowbeam = 1}), 30)
	MPElectricsGE.sendElectrics(flatEncode({lowbeam = 0}), 30)
	MPElectricsGE.sendElectrics(flatEncode({lowbeam = 1}), 1)
	run(module, 1.02)
	local traffic, own = game.meter["elec.traffic"], game.meter["elec.own"]
	same(traffic[1], 2, "traffic lights asked")
	same(traffic[2], 2, "traffic lights sent, the merged set included")
	same(own[1], 1, "own lights asked")
	same(own[2], 1, "own lights sent")
end)

--== second review ===========================================================

test("text that does not decode goes out after what was held, so an older value never follows it", function()
	local module = busyGame()
	run(module, 1)
	MPInputsGE.sendInputs(flatEncode({b = 1}), 30)
	MPInputsGE.sendInputs(flatEncode({b = 0.5}), 30)
	-- BeamMP's newest text reaches the check in a form it cannot read.
	MPInputsGE.sendInputs("b=0", 30)
	run(module, 2)
	local sent = texts(game.sentInp, 30)
	same(sent[#sent], "b=0", "the newest text is the last one sent")
	same(sent[#sent - 1], flatEncode({b = 0.5}), "what was held went first")
end)

test("a decoder that fails sends what was held first, then the call", function()
	local module = busyGame()
	run(module, 1)
	MPInputsGE.sendInputs(flatEncode({b = 1}), 30)
	MPInputsGE.sendInputs(flatEncode({b = 0.5}), 30)
	local realDecode = jsonDecode
	jsonDecode = function() error("decoder broke") end
	MPInputsGE.sendInputs('{"b":0}', 30)
	jsonDecode = realDecode
	run(module, 2)
	local sent = texts(game.sentInp, 30)
	same(sent[#sent], '{"b":0}', "the newest text is the last one sent")
end)

test("far traffic that comes near sends its lights at the near rate from the next check", function()
	local module = busyGame()
	run(module, 1)
	-- Sent while far, just before the next check: the far rule's next send is a second away.
	MPElectricsGE.sendElectrics(flatEncode({brake = 1}), 30)
	same(#texts(game.sentElec, 30), 1, "first change sent at once")
	game.objects[30].pos = vec(300, 0, 0)
	run(module, 0.06)
	MPElectricsGE.sendElectrics(flatEncode({brake = 0}), 30)
	run(module, 0.22)
	same(#texts(game.sentElec, 30), 2, "the change sent within the near spacing")
	same(applied(texts(game.sentElec, 30)).brake, 0, "the last value")
end)

--== engine and powertrain ===================================================

-- Engine data is nested (one table per engine); these texts stand for tables.
local function nestedCodec()
	local byText, encoded = {}, {}
	local function copy(t)
		local c = {}
		for k, v in pairs(t) do c[k] = type(v) == "table" and copy(v) or v end
		return c
	end
	jsonDecode = function(text) return byText[text] and copy(byText[text]) end
	jsonEncode = function(t)
		table.insert(encoded, copy(t))
		return "#" .. #encoded
	end
	local function text(t)
		local key = "T" .. tostring(t)
		byText[key] = t
		return key
	end
	return text, encoded
end

test("a near traffic car's engine changes are merged field by field and go out 5 times a second", function()
	local module = busyGame({meter = true})
	run(module, 1)
	local text, encoded = nestedCodec()
	MPPowertrainGE.sendEngineData(text({ignLvl = 2}), 20)
	MPPowertrainGE.sendEngineData(text({ICE = {mainEngine = {ign = 1, isStalled = false}}}), 20)
	MPPowertrainGE.sendEngineData(text({ICE = {mainEngine = {starter = 1}}}), 20)
	same(#texts(game.sentEng, 20), 1, "sent at once, the rest held")
	run(module, 0.22)
	same(#texts(game.sentEng, 20), 2, "the merged set within the spacing")
	local merged = encoded[#encoded]
	same(merged.ICE.mainEngine.ign, 1, "ignition kept")
	same(merged.ICE.mainEngine.starter, 1, "starter")
	same(merged.ICE.mainEngine.isStalled, false, "stall kept")
	local c = game.meter["eng.traffic"]
	same(c[1], 3, "engine updates asked")
	same(c[2], 2, "engine updates sent")
end)

test("a far traffic car's powertrain changes go out once a second; the player's own car's at once", function()
	local module = busyGame()
	run(module, 1)
	local text = nestedCodec()
	for i = 1, 10 do
		MPPowertrainGE.sendLivePowertrain(text({rearDiff = {mode = "m" .. i}}), 30)
		MPPowertrainGE.sendLivePowertrain(text({rearDiff = {mode = "m" .. i}}), 1)
		run(module, 0.1)
	end
	local far = #texts(game.sentPtr, 30)
	expect(far >= 1 and far <= 2, "far traffic powertrain sends in 1 s: " .. far)
	same(#texts(game.sentPtr, 1), 10, "the player's car sends every change")
end)

test("without MPPowertrainGE the log says so once and lights and inputs are still checked", function()
	local module = setup()
	MPPowertrainGE = nil
	addCar(1, "player")
	module.onCareerActive(true)
	module.onCareerActive(true)
	same(countLines(logs, "MPPowertrainGE.sendEngineData missing"), 1, "warnings")
	expect(MPInputsGE.sendInputs ~= game.originalInp, "inputs still wrapped")
end)

--== gaps between positions =================================================

-- Rejects a limiter that keeps the count but bunches the sends (say 20 at the start of
-- each second, then nothing): another game stops steering a car 0.1 s after its last
-- position, so the count alone does not keep near traffic smooth. BeamMP's 50-a-second
-- tick calls the send at most once a frame, so at 30 frames a second it comes every
-- 1/30 s; no gap may be longer than the 0.05 s spacing plus one frame.
test("a near traffic car's positions are never further apart than the spacing plus one frame, at 50 or 30 frames a second", function()
	for _, frame in ipairs({0.02, 1 / 30}) do
		local module = busyGame()
		run(module, 1)
		local clock, last, worst, count = 0, nil, 0, 0
		for _ = 1, math.floor(5 / frame + 0.5) do
			clock = clock + frame
			module.onUpdate(frame)
			local before = forwarded(20)
			positionGE.sendVehiclePosRot('{"pos":[0,0,0]}', 20)
			if forwarded(20) > before then
				if last then worst = math.max(worst, clock - last) end
				last, count = clock, count + 1
			end
		end
		local fps = math.floor(1 / frame + 0.5)
		expect(worst <= 0.05 + frame + 1e-9, fps .. " frames a second: longest gap " .. worst)
		expect(worst < 0.1, fps .. " frames a second: a gap reached BeamMP's 0.1 s limit: " .. worst)
		expect(count >= 98 and count <= 102, fps .. " frames a second: positions in 5 s: " .. count)
	end
end)
