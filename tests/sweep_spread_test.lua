-- The six once-a-second checks over every car on a server game: the position check's
-- rules (mileage/positionRate.lua), the far-traffic check (mileage/farTraffic.lua), the
-- cost meter's car count (mileage/perfMeter.lua), the enabler's ghost settings and
-- traffic marks (mileageEnabler.lua) and the damage roles (mileage/damageSync.lua). Each
-- runs at its own point in the second from the career start, so no frame runs two of
-- them, and each still runs once a second.
--
-- All six read the car list through MPVehicleGE.getVehicles; the stand-in tells them apart
-- by the function that asked.

local BASE = "Resources/Client/Mileage/lua/ge/extensions/"
local COMPAT = BASE .. "mileage/compat.lua"
local ENABLER = BASE .. "mileageEnabler.lua"

-- Each check: the file, and the function in it that goes over every car.
local SWEEPS = {
	{name = "position rules", file = BASE .. "mileage/positionRate.lua", fn = "classify"},
	{name = "far traffic", file = BASE .. "mileage/farTraffic.lua", fn = "check"},
	{name = "car count", file = BASE .. "mileage/perfMeter.lua", fn = "countCars"},
	{name = "ghosts", file = ENABLER, fn = "applyGhosts"},
	{name = "traffic marks", file = ENABLER, fn = "sendTrafficMarks"},
	{name = "damage roles", file = BASE .. "mileage/damageSync.lua", fn = "assignRoles"},
}

local FRAME = 1 / 60

-- The line each sweep function starts on, as debug.getinfo gives it.
local function definedAt(file, fn)
	local n = 0
	for line in io.lines(file) do
		n = n + 1
		if line:find("^local function " .. fn .. "%(") then return n end
	end
	error(fn .. " not found in " .. file)
end

local bySource = {}
for _, s in ipairs(SWEEPS) do
	s.line = definedAt(s.file, s.fn)
	bySource[s.file .. ":" .. s.line] = s
end

local function sourceOf(info)
	local src = info.source or ""
	if src:sub(1, 1) == "@" then src = src:sub(2) end
	return src
end

local game, frameSweeps

local function vec(x, y, z) return {x = x, y = y, z = z} end

-- A car on the stand-in game. kind: "player", "traffic", "parked", "remote", "remoteTraffic".
local function addCar(gid, kind, pos)
	local own = kind ~= "remote" and kind ~= "remoteTraffic"
	local veh = {id = gid, pos = pos, active = true, own = own, JBeam = "pickup"}
	if kind == "traffic" then veh.isTraffic = "true" end
	if kind == "parked" then veh.isParked = "true" end
	function veh:getActive() return self.active end
	function veh:getPosition() return self.pos end
	function veh:getVelocity() return vec(0, 0, 0) end
	function veh:queueLuaCommand() end
	function veh:setMeshAlpha() end
	game.objects[gid] = veh
	local sid = (own and "0-" or "1-") .. gid
	game.vehicles[sid] = {gameVehicleID = gid, serverVehicleID = sid}
	game.sids[gid] = sid
	if kind == "player" then game.playerVehicle = gid end
	return veh
end

local function setup()
	game = {objects = {}, vehicles = {}, sids = {}, playerVehicle = -1, handlers = {}}
	frameSweeps = nil
	function log() end
	function setExtensionUnloadMode() end
	function TriggerServerEvent() end
	function AddEventHandler(name, fn) game.handlers[name] = fn end
	jsonEncode = function() return "{}" end
	jsonDecode = function(text) return game.decoded[text] end
	os.clockhp = function() return 0 end
	settings = {getValue = function() return nil end, setValue = function() end}
	MPConfig = {getNickname = function() return "player" end}
	MPCoreNetwork = {isMPSession = function() return true end}
	worldReadyState = 2
	core_camera = nil
	MPVehicleGE = {
		getVehicles = function()
			local info = debug.getinfo(2, "S")
			local s = info and bySource[sourceOf(info) .. ":" .. tostring(info.linedefined)]
			if s and frameSweeps then
				frameSweeps.list[#frameSweeps.list + 1] = s.name
				s.runs = s.runs + 1
			end
			return game.vehicles
		end,
		isOwn = function(gid) local v = game.objects[gid]; return v ~= nil and v.own end,
		getServerVehicleID = function(gid) return game.sids[gid] end,
	}
	be = {
		getObjectByID = function(_, gid) return game.objects[gid] end,
		getPlayerVehicleID = function() return game.playerVehicle end,
	}
	gameplay_traffic = {getTrafficData = function() return {} end}
	-- BeamMP's send and receive functions the position check and the cost meter wrap.
	positionGE = {sendVehiclePosRot = function() end, handle = function() end}
	MPElectricsGE = {sendElectrics = function() end, handle = function() end}
	MPInputsGE = {sendInputs = function() end, handle = function() end}
	MPPowertrainGE = {sendEngineData = function() end, sendLivePowertrain = function() end}
	extensions = {
		mileage_compat = dofile(COMPAT),
		core_input_actionFilter = {setGroup = function() end, addAction = function() end},
	}
	mileageEnabler = dofile(ENABLER)
	extensions.mileageEnabler = mileageEnabler
	game.modules = {mileageEnabler}
	for i = 1, #SWEEPS do
		local s = SWEEPS[i]
		s.runs = 0
		if s.file ~= ENABLER then table.insert(game.modules, dofile(s.file)) end
	end
	addCar(1, "player", vec(0, 0, 0))
	addCar(2, "traffic", vec(100, 0, 0))
	addCar(3, "parked", vec(50, 0, 0))
	addCar(10, "remote", vec(300, 0, 0))
	addCar(11, "remoteTraffic", vec(2000, 0, 0))
	for _, m in ipairs(game.modules) do
		if m.onExtensionLoaded then m.onExtensionLoaded() end
	end
	game.decoded = {config = {remoteVehicleGhost = false, remoteUnicycleGhost = true, localUnicycleGhost = false,
		consoleEnabled = true, worldEditorEnabled = true}}
	game.handlers.rxClientConfigUpdate("config")
end

local function hook(name, ...)
	for _, m in ipairs(game.modules) do
		if type(m[name]) == "function" then m[name](...) end
	end
end

-- One frame: every module's update; returns the checks over every car it ran.
local function frame()
	frameSweeps = {list = {}}
	hook("onUpdate", FRAME, FRAME, FRAME)
	local list = frameSweeps.list
	frameSweeps = nil
	return list
end

-- Runs the game a while before its career starts, then starts the career and runs n
-- frames, calling between(i) after frame i. Returns the frames that ran two or more checks.
local function play(n, between)
	setup()
	for _ = 1, 37 do frame() end
	for _, s in ipairs(SWEEPS) do s.runs = 0 end
	hook("onCareerActive", true)
	local crowded = {}
	for i = 1, n do
		local list = frame()
		if #list > 1 then table.insert(crowded, i .. " (" .. table.concat(list, ", ") .. ")") end
		if between then between(i) end
	end
	return crowded
end

local function describe(crowded)
	if #crowded == 0 then return "none" end
	local first = {}
	for i = 1, math.min(4, #crowded) do first[i] = crowded[i] end
	return #crowded .. ", first " .. table.concat(first, "; ")
end

test("over 10 s at 60 fps from the career start no frame runs two of the six car checks, each runs 10 times", function()
	local crowded = play(600)
	same(#crowded, 0, "frames with two or more checks: " .. describe(crowded))
	for _, s in ipairs(SWEEPS) do same(s.runs, 10, s.name .. " runs") end
end)

test("a career restart at 5 s keeps the six checks apart", function()
	local crowded = play(600, function(i)
		if i == 300 then
			hook("onCareerActive", false)
			hook("onCareerActive", true)
		end
	end)
	same(#crowded, 0, "frames with two or more checks: " .. describe(crowded))
	for _, s in ipairs(SWEEPS) do same(s.runs, 10, s.name .. " runs") end
end)
