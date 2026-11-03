-- mileageEnabler.lua: what this game does to other players' cars. They carry the game's
-- "not traffic" flag, spectating one keeps this player's traffic on their own car, and
-- their active and ghost settings are sent only when they change.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileageEnabler.lua"
local COMPAT = "Resources/Client/Mileage/lua/ge/extensions/mileage/compat.lua"

local logs, focusCalls

-- A car in the stand-in game: dynamic fields, setActive and queued vehicle commands are
-- recorded on it.
local function newVehicle(objects, id, jbeam)
	local veh = {id = id, JBeam = jbeam or "pickup", active = true, activeCalls = 0, queued = {}, fields = {}}
	function veh:setDynDataFieldbyName(name, index, value) self.fields[name] = value; self[name] = value end
	function veh:setField() end
	function veh:setActive(on) self.active = on == 1; self.activeCalls = self.activeCalls + 1 end
	function veh:getActive() return self.active end
	function veh:queueLuaCommand(cmd) table.insert(self.queued, cmd) end
	objects[id] = veh
	return veh
end

-- Cars 1 and 2 are this player's own (2 their traffic); 9 and 10 belong to player 1.
-- opts.noTraffic removes gameplay_traffic, opts.noSetFocus only its setFocus.
local function setup(opts)
	opts = opts or {}
	logs, focusCalls = {}, {}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	function TriggerServerEvent() end
	function jsonEncode() return "{}" end
	function jsonDecode(s) return loadstring and loadstring("return " .. s)() or load("return " .. s)() end
	local objects = {}
	newVehicle(objects, 1)
	newVehicle(objects, 2, "covet")
	newVehicle(objects, 9)
	newVehicle(objects, 10, "etk800")
	local ids = {[1] = "0-0", [2] = "0-1", [9] = "1-0", [10] = "1-1"}
	local vehicles = {}
	for gameId, serverId in pairs(ids) do
		vehicles[serverId] = {gameVehicleID = gameId, jbeam = objects[gameId].JBeam}
	end
	MPVehicleGE = {
		isOwn = function(id) return id == 1 or id == 2 end,
		getServerVehicleID = function(id) return ids[id] end,
		getVehicles = function() return vehicles end,
	}
	be = {
		getObjectByID = function(_, id) return objects[id] end,
		getPlayerVehicleID = function() return 1 end,
	}
	if opts.noTraffic then
		gameplay_traffic = nil
	else
		gameplay_traffic = {getTrafficData = function() return {[2] = {isAi = true}} end}
		if not opts.noSetFocus then
			gameplay_traffic.setFocus = function(mode, data) table.insert(focusCalls, {mode = mode, data = data}) end
		end
	end
	extensions = {mileage_compat = dofile(COMPAT)}
	worldReadyState = 2
	local enabler = dofile(SOURCE)
	return enabler, objects, vehicles
end

--== the "not traffic" flag ==================================================

test("another player's car is flagged so this game's traffic and police leave it alone", function()
	local enabler, objects = setup()
	enabler.onVehicleReady(9)
	same(objects[9].fields.ignoreTraffic, "true", "ignoreTraffic on car 9")
	same(objects[9].ignoreTraffic, "true", "read back as obj.ignoreTraffic")
end)

test("this player's own cars and traffic never get the flag", function()
	local enabler, objects = setup()
	enabler.onVehicleReady(1)
	enabler.onVehicleReady(2)
	same(objects[1].fields.ignoreTraffic, nil, "own car")
	same(objects[2].fields.ignoreTraffic, nil, "own traffic car")
end)

--== traffic focus while spectating ==========================================

test("spectating another player pins this player's traffic on the car they left", function()
	local enabler = setup()
	enabler.onVehicleSwitched(1, 9)
	same(#focusCalls, 1, "setFocus calls")
	same(focusCalls[1].mode, "vehicle", "mode")
	same(focusCalls[1].data and focusCalls[1].data.vehId, 1, "focus vehicle")
	same(focusCalls[1].data and focusCalls[1].data.auto, false, "automatic switching off")
end)

test("returning to an own car hands traffic focus back to the game", function()
	local enabler = setup()
	enabler.onVehicleSwitched(1, 9)
	enabler.onVehicleSwitched(9, 1)
	same(#focusCalls, 2, "setFocus calls")
	same(focusCalls[2].mode, nil, "back to the game's automatic focus")
	same(focusCalls[2].data, nil, "no focus data")
end)

test("moving the camera between two other players' cars keeps the focus pinned", function()
	local enabler = setup()
	enabler.onVehicleSwitched(1, 9)
	enabler.onVehicleSwitched(9, 10)
	same(#focusCalls, 1, "setFocus calls")
end)

test("switching between own cars leaves traffic focus to the game", function()
	local enabler = setup()
	enabler.onVehicleSwitched(2, 1)
	same(#focusCalls, 0, "setFocus calls")
end)

test("without the traffic system or its setFocus the switch is logged once and goes on", function()
	for _, opts in ipairs({{noTraffic = true}, {noSetFocus = true}}) do
		local enabler = setup(opts)
		enabler.onVehicleSwitched(1, 9)
		enabler.onVehicleSwitched(9, 1)
		same(countLines(logs, "setFocus missing"), 1, "warnings")
		same(countLines(logs, "onVehicleSwitched failed"), 0, "switch errors")
	end
end)

--== active and ghost settings only on change ===============================

local function ghostCommands(veh)
	local n = 0
	for _, cmd in ipairs(veh.queued) do
		if string.find(cmd, "mileageEnabler.setGhost", 1, true) then n = n + 1 end
	end
	return n
end

-- The enabler with the server's settings in place, as rxCareerSync leaves them.
local function startedEnabler()
	local enabler, objects, vehicles = setup()
	local config = {remoteVehicleGhost = false, remoteUnicycleGhost = true, localUnicycleGhost = false}
	local i = 1
	while true do
		local n = debug.getupvalue(enabler.onUpdate, i)
		if n == nil then break end
		if n == "clientConfig" then debug.setupvalue(enabler.onUpdate, i, config) end
		i = i + 1
	end
	extensions.core_input_actionFilter = {setGroup = function() end, addAction = function() end}
	return enabler, objects, vehicles
end

local FULL_MAP = '{["1-0"] = {active = true}, ["1-1"] = {active = true}}'

-- The server's vehicle-state event, which onExtensionLoaded registers with BeamMP.
local function vehSync(enabler, data)
	local i = 1
	while true do
		local n, v = debug.getupvalue(enabler.onExtensionLoaded, i)
		if n == nil then error("rxCareerVehSync not found") end
		if n == "rxCareerVehSync" then return v(data) end
		i = i + 1
	end
end

test("the same vehicle list twice switches another player's hidden car on once", function()
	local enabler, objects = setup()
	objects[9].active, objects[10].active = false, false
	vehSync(enabler, FULL_MAP)
	vehSync(enabler, FULL_MAP)
	same(objects[9].activeCalls, 1, "setActive calls on car 9")
	same(objects[10].activeCalls, 1, "setActive calls on car 10")
	same(objects[9].active, true, "car 9 shown")
end)

test("a list that matches the cars on this screen switches nothing", function()
	local enabler, objects = setup()
	vehSync(enabler, FULL_MAP)
	same(objects[9].activeCalls, 0, "setActive calls on car 9")
	same(objects[10].activeCalls, 0, "setActive calls on car 10")
end)

test("a changed state is still applied, and the nametag follows it", function()
	local enabler, objects, vehicles = setup()
	vehSync(enabler, FULL_MAP)
	vehSync(enabler, '{["1-0"] = {active = false}}')
	same(objects[9].active, false, "car 9 hidden")
	same(objects[9].activeCalls, 1, "setActive calls")
	same(vehicles["1-0"].hideNametag, true, "nametag hidden")
	vehSync(enabler, '{["1-0"] = {active = true}}')
	same(objects[9].active, true, "car 9 shown")
	same(vehicles["1-0"].hideNametag, false, "nametag shown")
end)

test("a car hidden here by other code is shown again by the server's list", function()
	local enabler, objects = setup()
	vehSync(enabler, FULL_MAP)
	objects[9]:setActive(0)
	vehSync(enabler, FULL_MAP)
	same(objects[9].active, true, "car 9 shown")
end)

test("two frames queue another player's ghost setting once", function()
	local enabler, objects = startedEnabler()
	enabler.onUpdate(0.016)
	enabler.onUpdate(0.016)
	same(ghostCommands(objects[9]), 1, "setGhost commands on car 9")
	same(objects[9].queued[1], "mileageEnabler.setGhost(false)", "the server's setting")
end)

test("a car that is ready again or reset gets its ghost setting again", function()
	for _, hook in ipairs({"onVehicleReady", "onVehicleResetted"}) do
		local enabler, objects = startedEnabler()
		enabler.onUpdate(0.016)
		enabler[hook](9)
		enabler.onUpdate(0.016)
		same(ghostCommands(objects[9]), 2, hook .. ": setGhost commands on car 9")
		same(ghostCommands(objects[10]), 1, hook .. ": setGhost commands on car 10")
	end
end)

test("a changed ghost setting is sent once to each car within a second", function()
	local enabler, objects = startedEnabler()
	enabler.onUpdate(0.016)
	local i = 1
	while true do
		local n, v = debug.getupvalue(enabler.onUpdate, i)
		if n == nil then error("clientConfig not found") end
		if n == "clientConfig" then v.remoteVehicleGhost = true; break end
		i = i + 1
	end
	for _ = 1, 62 do enabler.onUpdate(1 / 60) end
	same(ghostCommands(objects[9]), 2, "setGhost commands on car 9")
	same(objects[9].queued[2], "mileageEnabler.setGhost(true)", "the new setting")
end)

-- How often the stand-in game is asked for a car while fn runs.
local function lookups(fn)
	local realBe = be
	local n = 0
	be = setmetatable({getObjectByID = function(self, id) n = n + 1; return realBe.getObjectByID(self, id) end},
		{__index = realBe})
	fn()
	be = realBe
	return n
end

test("over a second of frames the ghost check goes over the cars once, not every frame", function()
	local enabler = startedEnabler()
	enabler.onUpdate(1 / 60)
	local n = lookups(function() for _ = 1, 60 do enabler.onUpdate(1 / 60) end end)
	-- Four cars, once for the ghost check and once for the traffic marks.
	expect(n <= 8, "cars looked up in a second: " .. n)
end)

test("a car built between checks gets its ghost setting in the frame it is built", function()
	local enabler, objects, vehicles = startedEnabler()
	enabler.onUpdate(1 / 60)
	enabler.onUpdate(1 / 60)
	local veh = {id = 11, JBeam = "pickup", active = true, queued = {}, fields = {}}
	function veh:queueLuaCommand(cmd) table.insert(self.queued, cmd) end
	function veh:getActive() return self.active end
	function veh:setActive(on) self.active = on == 1 end
	function veh:setDynDataFieldbyName() end
	objects[11] = veh
	vehicles["1-2"] = {gameVehicleID = 11}
	local realServerId = MPVehicleGE.getServerVehicleID
	MPVehicleGE.getServerVehicleID = function(id) if id == 11 then return "1-2" end return realServerId(id) end
	enabler.onVehicleSpawned(11)
	same(ghostCommands(veh), 1, "setGhost commands on the new car")
	same(veh.queued[2], "mileageEnabler.setGhost(false)", "the server's setting")
	enabler.onUpdate(1 / 60)
	same(ghostCommands(veh), 1, "setGhost commands after the next frame")
end)

test("another player's unicycle follows remoteUnicycleGhost even when it is off and cars are ghosted", function()
	local enabler, objects = startedEnabler()
	objects[10].JBeam = "unicycle"
	local i = 1
	while true do
		local n, v = debug.getupvalue(enabler.onUpdate, i)
		if n == nil then error("clientConfig not found") end
		if n == "clientConfig" then v.remoteVehicleGhost, v.remoteUnicycleGhost = true, false; break end
		i = i + 1
	end
	enabler.onUpdate(0.016)
	same(objects[9].queued[1], "mileageEnabler.setGhost(true)", "the other player's car")
	same(objects[10].queued[1], "mileageEnabler.setGhost(false)", "the other player's unicycle")
end)

test("leaving the server forgets the ghost settings, so a rejoin sends them again", function()
	local enabler, objects = startedEnabler()
	enabler.onUpdate(0.016)
	enabler.onBeamMPServerLeave()
	enabler.onUpdate(0.016)
	same(ghostCommands(objects[9]), 2, "setGhost commands on car 9")
end)

test("spectating after this player's own car was removed pins nothing", function()
	local enabler, objects = setup()
	objects[1] = nil
	enabler.onVehicleSwitched(1, 9)
	same(#focusCalls, 0, "setFocus calls")
end)

test("a destroyed car's ghost setting is forgotten, so a new car under that id gets it", function()
	local enabler, objects = startedEnabler()
	enabler.onUpdate(0.016)
	enabler.onVehicleDestroyed(9)
	enabler.onUpdate(0.016)
	same(ghostCommands(objects[9]), 2, "setGhost commands on car 9")
	same(ghostCommands(objects[10]), 1, "setGhost commands on car 10")
end)
