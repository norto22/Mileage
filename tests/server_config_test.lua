-- Resources/Server/Mileage/mileage.lua: the config a new server writes, what an
-- existing config keeps, and the retired extra-traffic settings.

local SOURCE = "Resources/Server/Mileage/mileage.lua"

local printed, stored, written, sentToClients

-- prepareConfig is local to the plugin; onInit calls it, so it is one of onInit's
-- upvalues.
local function upvalue(fn, name)
	local i = 1
	while true do
		local n, v = debug.getupvalue(fn, i)
		if n == nil then return nil end
		if n == name then return v end
		i = i + 1
	end
end

-- Loads the real plugin with a stand-in BeamMP server.
local function loadPlugin()
	printed, written, sentToClients = {}, nil, nil
	Util = {JsonEncode = function() return "{}" end}
	MP = {
		CreateTimer = function() return {GetCurrent = function() return 0 end, Start = function() end} end,
		GetPlayers = function() return {} end,
		TriggerClientEvent = function(player, event, data)
			sentToClients = sentToClients or {}
			sentToClients[event] = {event = event, data = data}
		end,
	}
	dofile(SOURCE)
	local prepareConfig = upvalue(onInit, "prepareConfig")
	assert(type(prepareConfig) == "function", "prepareConfig not found in onInit")
	print = function(line) table.insert(printed, tostring(line)) end
	ReadJson = function() return stored end
	WriteJson = function(_, data) written = data; return true end
	return prepareConfig
end

local realPrint = print

local function run(fn)
	local ok, err = pcall(fn)
	print = realPrint
	if not ok then error(err, 0) end
end

-- The settings an existing server has today (the owner's file from this task's Discuss).
local function ownersConfig()
	return {
		client = {consoleEnabled = false, extraTrafficAmount = 80, extraTrafficEnabled = true,
			localUnicycleGhost = false, nativeDragSyncEnabled = true, parkedTrafficAmount = 20,
			parkedTrafficEnabled = true, remoteUnicycleGhost = true, remoteVehicleGhost = false,
			roadTrafficAmount = 0, roadTrafficEnabled = false, serverSaveName = "",
			serverSaveNameEnabled = false, serverSaveSuffix = "", simplifyRemoteVehicles = false,
			skipOtherPlayersVehicles = false, spawnVehicleIgnitionLevel = 0, trafficAllowMods = false,
			trafficSimpleVehicles = true, trafficSmartSelections = true, worldEditorEnabled = false},
		server = {allowTransactions = true, autoExit = true, autoUpdate = true, longWindowMax = 10000,
			longWindowSeconds = 300, sessionReceiveMax = 200000, sessionSendingMax = 100000,
			shortWindowMax = 1000, shortWindowSeconds = 30},
	}
end

test("a fresh install writes road traffic on at 6 and parked on at 8, without extra traffic", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = nil
		prepareConfig()
		expect(written ~= nil, "config written")
		same(written.client.roadTrafficEnabled, true, "roadTrafficEnabled")
		same(written.client.roadTrafficAmount, 6, "roadTrafficAmount")
		same(written.client.parkedTrafficEnabled, true, "parkedTrafficEnabled")
		same(written.client.parkedTrafficAmount, 8, "parkedTrafficAmount")
		same(written.client.extraTrafficAmount, nil, "extraTrafficAmount")
		same(written.client.extraTrafficEnabled, nil, "extraTrafficEnabled")
	end)
end)

test("the new defaults are within the 0 to 50 range the client accepts", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = nil
		prepareConfig()
		for _, key in ipairs({"roadTrafficAmount", "parkedTrafficAmount"}) do
			local v = written.client[key]
			expect(type(v) == "number" and v >= 0 and v <= 50 and v == math.floor(v), key .. " in range")
		end
	end)
end)

test("an existing config keeps the owner's traffic values and loses only extra traffic", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = ownersConfig()
		prepareConfig()
		expect(written ~= nil, "file rewritten")
		same(written.client.roadTrafficEnabled, false, "roadTrafficEnabled")
		same(written.client.roadTrafficAmount, 0, "roadTrafficAmount")
		same(written.client.parkedTrafficAmount, 20, "parkedTrafficAmount")
		same(written.client.extraTrafficAmount, nil, "extraTrafficAmount")
		same(written.client.extraTrafficEnabled, nil, "extraTrafficEnabled")
		same(countLines(printed, "[Mileage] ---------- Mileage Config client extraTrafficAmount removed: extra traffic was never used by the game"), 1, "removal line for the amount")
		same(countLines(printed, "[Mileage] ---------- Mileage Config client extraTrafficEnabled removed: extra traffic was never used by the game"), 1, "removal line for the switch")
		same(countLines(printed, "extraTraffic"), 2, "no other line names extra traffic")
	end)
end)

test("a config missing only the traffic settings gets the new defaults for them", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = ownersConfig()
		for _, key in ipairs({"roadTrafficEnabled", "roadTrafficAmount", "parkedTrafficEnabled", "parkedTrafficAmount"}) do
			stored.client[key] = nil
		end
		prepareConfig()
		same(written.client.roadTrafficEnabled, true, "roadTrafficEnabled")
		same(written.client.roadTrafficAmount, 6, "roadTrafficAmount")
		same(written.client.parkedTrafficEnabled, true, "parkedTrafficEnabled")
		same(written.client.parkedTrafficAmount, 8, "parkedTrafficAmount")
	end)
end)

test("a fresh install has a server-wide traffic total of 18 driving and 24 parked cars", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = nil
		prepareConfig()
		same(written.server.roadTrafficTotal, 18, "roadTrafficTotal")
		same(written.server.parkedTrafficTotal, 24, "parkedTrafficTotal")
	end)
end)

test("an existing config gains the traffic totals at their defaults and keeps every other value", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = ownersConfig()
		local before = ownersConfig()
		prepareConfig()
		same(written.server.roadTrafficTotal, 18, "roadTrafficTotal")
		same(written.server.parkedTrafficTotal, 24, "parkedTrafficTotal")
		for section, fields in pairs(before) do
			for key, value in pairs(fields) do
				if not key:find("^extraTraffic") then
					same(written[section][key], value, section .. " " .. key)
				end
			end
		end
	end)
end)

test("an owner's own traffic totals are kept, and SetConfig changes one", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = ownersConfig()
		stored.server.roadTrafficTotal, stored.server.parkedTrafficTotal = 0, 40
		prepareConfig()
		same(written.server.roadTrafficTotal, 0, "roadTrafficTotal")
		same(written.server.parkedTrafficTotal, 40, "parkedTrafficTotal")
		stored, written = written, nil
		SetConfig({"server", "roadTrafficTotal", "30"})
		same(written and written.server.roadTrafficTotal, 30, "roadTrafficTotal after SetConfig")
	end)
end)

test("an unknown setting in the server section is still called invalid", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = ownersConfig()
		stored.server.extraTrafficAmount = 5
		stored.client.somethingElse = 1
		prepareConfig()
		same(countLines(printed, "Mileage Config server extraTrafficAmount is invalid, removing"), 1, "server section line")
		same(countLines(printed, "Mileage Config client somethingElse is invalid, removing"), 1, "client section line")
		same(written.server.extraTrafficAmount, nil, "removed from server")
	end)
end)

test("a cleaned config is not rewritten on the next start", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = ownersConfig()
		prepareConfig()
		stored, written, printed = written, nil, {}
		prepareConfig()
		same(written, nil, "file written")
		same(countLines(printed, "removed:"), 0, "removal lines")
	end)
end)

test("a fresh install and an existing config get the racing, request and event settings at their defaults", function()
	local defaults = {allowRacing = true, allowMoneyRequests = true, allowEvents = true, raceStakeMax = 10000,
		racePrize = 2000, racePrizeCooldownMinutes = 5, raceMinDistance = 500, raceTimeLimitMinutes = 15,
		allowAiRaces = true, aiRacePrize = 2000, aiRacePrizeCooldownMinutes = 5,
		allowSpotRaces = true, spotRacePrize = 2000, spotRacePrizeCooldownMinutes = 5, spotRaceOpponentsMax = 5,
		dragRacePrize = 2000, dragRacePrizeCooldownMinutes = 5}
	for _, existing in ipairs({false, true}) do
		run(function()
			local prepareConfig = loadPlugin()
			stored = existing and ownersConfig() or nil
			prepareConfig()
			for key, value in pairs(defaults) do
				same(written.server[key], value, key .. (existing and " added to an existing config" or ""))
			end
			if existing then same(written.server.longWindowMax, 10000, "the owner's other settings kept") end
		end)
	end
end)

--== race prizes: the $2000 defaults and the one-time move ==================

local PRIZES = {"racePrize", "aiRacePrize", "spotRacePrize", "dragRacePrize"}
local WAITS = {"racePrizeCooldownMinutes", "aiRacePrizeCooldownMinutes", "spotRacePrizeCooldownMinutes"}

-- An owner's file from before the $2000 defaults: every prize off, the 10-minute waits,
-- and no drag wait setting, as earlier versions wrote it.
local function preUpdateConfig()
	local config = ownersConfig()
	for _, key in ipairs(PRIZES) do config.server[key] = 0 end
	for _, key in ipairs(WAITS) do config.server[key] = 10 end
	return config
end

local function movedLine(key, from, to)
	return string.format("[Mileage] ---------- Mileage Config server %s moved from %d to %d (the new default);"
		.. " to keep it as it was: Mileage SetConfig server %s %d", key, from, to, key, from)
end

test("a fresh install pays $2000 prizes with 5-minute waits and says nothing was moved", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = nil
		prepareConfig()
		for _, key in ipairs(PRIZES) do same(written.server[key], 2000, key) end
		for _, key in ipairs(WAITS) do same(written.server[key], 5, key) end
		same(written.server.dragRacePrizeCooldownMinutes, 5, "drag wait")
		same(countLines(printed, "moved from"), 0, "no moved lines")
	end)
end)

test("a file from before the $2000 defaults moves its $0 prizes and 10-minute waits once, naming each", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = preUpdateConfig()
		prepareConfig()
		for _, key in ipairs(PRIZES) do
			same(written.server[key], 2000, key)
			same(countLines(printed, movedLine(key, 0, 2000)), 1, key .. " moved line")
		end
		for _, key in ipairs(WAITS) do
			same(written.server[key], 5, key)
			same(countLines(printed, movedLine(key, 10, 5)), 1, key .. " moved line")
		end
		same(written.server.dragRacePrizeCooldownMinutes, 5, "drag wait added")
		same(countLines(printed, "moved from"), 7, "one line per moved setting")
		same(written.server.longWindowMax, 10000, "the owner's other settings kept")
	end)
end)

test("the move keeps every prize and wait the owner set to something else", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = preUpdateConfig()
		stored.server.racePrize, stored.server.dragRacePrize = 500, 1
		stored.server.aiRacePrizeCooldownMinutes, stored.server.spotRacePrizeCooldownMinutes = 30, 0
		stored.server.spotRacePrize = "0"
		prepareConfig()
		same(written.server.racePrize, 500, "racePrize kept")
		same(written.server.dragRacePrize, 1, "dragRacePrize kept")
		same(written.server.aiRacePrizeCooldownMinutes, 30, "a 30-minute wait kept")
		same(written.server.spotRacePrizeCooldownMinutes, 0, "a wait of 0 kept")
		same(written.server.spotRacePrize, "0", "a prize written as text is left as it is")
		same(written.server.aiRacePrize, 2000, "an untouched prize still moves")
		same(written.server.racePrizeCooldownMinutes, 5, "an untouched wait still moves")
		same(countLines(printed, "moved from"), 2, "lines only for what moved")
	end)
end)

test("after the move, a prize the owner sets back to $0 stays at $0 through later starts", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = preUpdateConfig()
		prepareConfig()
		stored, written, printed = written, nil, {}
		SetConfig({"server", "racePrize", "0"})
		same(written and written.server.racePrize, 0, "set back to 0")
		for _ = 1, 2 do
			stored, written, printed = written or stored, nil, {}
			prepareConfig()
			same(countLines(printed, "moved from"), 0, "nothing moves again")
			same((written or stored).server.racePrize, 0, "still 0")
		end
	end)
end)

test("a file with the drag wait already set keeps a $0 prize and a 10-minute wait", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = preUpdateConfig()
		stored.server.dragRacePrizeCooldownMinutes = 0
		prepareConfig()
		local server = (written or stored).server
		for _, key in ipairs(PRIZES) do same(server[key], 0, key) end
		for _, key in ipairs(WAITS) do same(server[key], 10, key) end
		same(countLines(printed, "moved from"), 0, "no moved lines")
	end)
end)

test("a file with no server section gets the new defaults and no moved lines", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = ownersConfig()
		stored.server = nil
		prepareConfig()
		for _, key in ipairs(PRIZES) do same(written.server[key], 2000, key) end
		same(written.server.dragRacePrizeCooldownMinutes, 5, "drag wait")
		same(countLines(printed, "moved from"), 0, "no moved lines")
	end)
end)

test("SetConfig refuses the removed extra-traffic settings and still sets road traffic", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = ownersConfig()
		prepareConfig()
		stored, written, printed = written, nil, {}
		SetConfig({"client", "extraTrafficAmount", "10"})
		same(countLines(printed, "[Mileage] ---------- Unknown key: client extraTrafficAmount"), 1, "unknown key line")
		same(written, nil, "file written for a refused key")
		SetConfig({"client", "roadTrafficEnabled", "true"})
		expect(written ~= nil, "file written")
		same(written.client.roadTrafficEnabled, true, "roadTrafficEnabled")
		expect(sentToClients and sentToClients.rxClientConfigUpdate, "players told")
		expect(sentToClients.rxMileageFeatures, "players told the server's switches")
	end)
end)

--== alive message ==========================================================

test("every second tick sends each connected player one alive message", function()
	run(function()
		loadPlugin()
		local sent = {}
		MP.GetPlayers = function() return {[0] = "Ann", [1] = "Bob", [2] = "Cy"} end
		MP.IsPlayerConnected = function(id) return id ~= 2 end
		MP.TriggerClientEvent = function(id, event, data) table.insert(sent, {id = id, event = event, data = data}) end
		tick()
		tick()
		local to = {}
		for _, s in ipairs(sent) do
			same(s.event, "rxMileageAlive", "event")
			same(s.data, "", "alive content")
			to[s.id] = (to[s.id] or 0) + 1
		end
		same(#sent, 2, "alive messages in two ticks")
		same(to[0], 1, "to player 0")
		same(to[1], 1, "to player 1")
		same(to[2], nil, "to the player who is not connected")
		tick()
		tick()
		same(#sent, 4, "messages after four ticks")
	end)
end)

test("the join activation check still runs on a tick that sends no alive message", function()
	run(function()
		local now = 0
		local dropped, sent = {}, {}
		MP = {
			CreateTimer = function() return {GetCurrent = function() return now end, Start = function() end} end,
			GetPlayers = function() return {[0] = "Ann"} end,
			IsPlayerConnected = function() return true end,
			GetPlayerName = function() return "Ann" end,
			DropPlayer = function(id) table.insert(dropped, id) end,
			TriggerClientEvent = function(id, event) table.insert(sent, event) end,
		}
		dofile(SOURCE)
		print = function() end
		onPlayerJoinHandler(0)
		now = 90
		tick()
		same(#sent, 0, "alive messages on the first tick")
		same(#dropped, 1, "a player who never asked for settings is dropped on the first tick")
		same(dropped[1], 0, "dropped player")
	end)
end)
