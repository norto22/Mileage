-- Drag racing between players: who each race message reaches, and the clock estimate the
-- strip's leader converts finish times with.
--
-- #18: the race-start and rules messages go only to the players at that race's strip.
-- #19: a message for the strip's leader carries the sender's strip, so the server can still
--      route it when the message itself names no strip, and logs one it cannot place.
-- #20: starting a mission or performance test at a strip releases the player's claim.
-- #24: a clock estimate's age is the age of the sample it was made from.

local LOBBY = "Resources/Client/Mileage/lua/ge/extensions/mileage/dragLobby.lua"
local DRAG_MODE = "Resources/Client/Mileage/lua/ge/extensions/multiplayer/gamemodes/drag/drag.lua"
local TRANSPORT = "Resources/Client/Mileage/lua/ge/extensions/mileage/dragTransport.lua"
local SYNCLIB = "Resources/Client/Mileage/lua/ge/extensions/multiplayer/synclib.lua"
local SERVER = "Resources/Server/Mileage/mileage.lua"

local logs, sent, game

--== a stand-in game for the client files =====================================

local function newVec(x, y, z)
	if type(x) == "table" then x, y, z = x[1] or x.x, x[2] or x.y, x[3] or x.z end
	local v = {x = x or 0, y = y or 0, z = z or 0}
	function v:distance(o)
		return math.sqrt((self.x - o.x) ^ 2 + (self.y - o.y) ^ 2 + (self.z - o.z) ^ 2)
	end
	return v
end

local function stripData(id)
	return {id = id, strip = {lanes = {
		{waypoints = {stage = {transform = {position = {0, 0, 0}}}}},
		{waypoints = {stage = {transform = {position = {4, 0, 0}}}}},
	}}}
end

-- The game with this player (id 1) driving a car at the stage line of every strip, the
-- transport recording what it sends, and the drag mode as a stand-in unless the real one
-- is loaded on top.
local function newGame(strips)
	logs, sent = {}, {}
	game = {now = 0, mission = false, authority = {}}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. tostring(msg)) end
	function setExtensionUnloadMode() end
	os.clockhp = function() return game.now end
	vec3 = newVec
	function getCurrentLevelIdentifier() return "test_level" end
	local car = {getPosition = function() return newVec(0, 0, 0) end}
	be = {getPlayerVehicleID = function() return 7 end, getObjectByID = function(_, id) return id == 7 and car or nil end}
	MPConfig = {getNickname = function() return "Me" end, getPlayerServerID = function() return 1 end}
	local list = {}
	for _, id in ipairs(strips or {"A"}) do table.insert(list, stripData(id)) end
	gameplay_drag_core = {getDragDataForLevel = function() return list end, getData = function() return nil end}
	gameplay_drag_mpDragHandlers = {handle = function(msgName)
		table.insert(sent, {msg = msgName, to = "local"})
	end}
	mileage_dragTransport = {
		send = function(msgName, to, data) table.insert(sent, {msg = msgName, to = to, data = data}) end,
		isAuthorityFor = function(stripId) return game.authority[stripId] == true end,
		isHost = function() return true end,
		getState = function() return {} end,
		getLocalClientActiveRace = function() return game.activeRace end,
		bridge = {getLocalPlayerId = function() return 1 end},
	}
	multiplayer_gamemodes_drag_drag = {
		isEnabled = function() return true end,
		isMultiplayer = function() return not game.mission end,
		inSoloDragActivity = function() return game.mission end,
	}
	mileage_dragLobby = dofile(LOBBY)
	return mileage_dragLobby
end

-- Players standing at a strip this player leads, as the lobby hears them announce it.
local function arrive(lobby, playerId, stripId, lane)
	game.authority[stripId] = true
	lobby.onMileageDragMessage("mileageDragJoin", playerId, {stripId = stripId, lane = lane or 2})
end

local function sentNamed(name)
	local out = {}
	for _, m in ipairs(sent) do if m.msg == name then table.insert(out, m) end end
	return out
end

local function idList(to)
	if type(to) ~= "table" then return tostring(to) end
	local ids = {}
	for _, id in ipairs(to) do table.insert(ids, tostring(id)) end
	table.sort(ids)
	return table.concat(ids, ",")
end

-- The real drag mode on top of the game, enabled, as the strip's leader.
local function realDragMode()
	local drag = dofile(DRAG_MODE)
	drag.setEnabled(true)
	multiplayer_gamemodes_drag_drag = drag
	return drag
end

--== #18: start and rules go to the strip's players ===========================

test("#18: the race start goes to the players at the race's strip, not to everyone", function()
	local lobby = newGame({"A", "B"})
	arrive(lobby, 2, "A")
	arrive(lobby, 3, "A")
	arrive(lobby, 4, "B")
	local drag = realDragMode()
	drag.notifyRaceStart("A-123")
	local starts = sentNamed("dragRaceStart")
	same(#starts, 2, "start messages (one sent, one applied locally)")
	same(idList(starts[1].to), "2,3", "recipients")
	same(starts[2].to, "local", "the leader applies the start to itself")
end)

test("#18: a strip whose id starts another's gets only its own race's messages", function()
	local lobby = newGame({"drag", "drag-north"})
	arrive(lobby, 2, "drag")
	arrive(lobby, 3, "drag-north")
	local drag = realDragMode()
	drag.notifyRaceStart("drag-north-77")
	same(idList(sentNamed("dragRaceStart")[1].to), "3", "recipients of a drag-north race")
	same(lobby.stripIdForRace("drag-77"), "drag", "strip of a drag race")
	same(lobby.stripIdForRace("other-77"), nil, "strip of a race at no known strip")
end)

test("#18: the rules update goes to the players at the race's strip", function()
	local lobby = newGame({"A", "B"})
	arrive(lobby, 2, "A")
	arrive(lobby, 4, "B")
	local drag = realDragMode()
	game.activeRace = {id = "B-9"}
	drag.broadcastRulesUpdate({dragType = "headsUp", treeType = ".500"})
	local rules = sentNamed("dragRaceRulesUpdate")
	same(#rules, 1, "rules messages")
	same(idList(rules[1].to), "4", "recipients")
end)

test("#18: nobody else at the strip: nothing goes out, the leader still applies the start", function()
	newGame({"A"})
	game.authority.A = true
	local drag = realDragMode()
	drag.notifyRaceStart("A-1")
	local starts = sentNamed("dragRaceStart")
	same(#starts, 1, "start messages")
	same(starts[1].to, "local", "the one start is the local apply")
end)

test("#18: without the lobby the start goes to everyone, and that is logged once", function()
	newGame({"A"})
	local drag = realDragMode()
	mileage_dragLobby = nil
	drag.notifyRaceStart("A-1")
	drag.onDragRaceReset("A-1")
	drag.notifyRaceStart("A-1")
	local starts = sentNamed("dragRaceStart")
	same(#starts, 2, "start messages")
	same(starts[1].to, "all", "recipients")
	same(countLines(logs, "drag lobby not loaded"), 1, "log lines")
end)

--== #19: the client puts its strip on a leader message =======================

local function realTransport(localStrip)
	local wire = {}
	function TriggerServerEvent(name, data) table.insert(wire, {name = name, data = data}) end
	function jsonEncode(t) return t end
	function log() end
	function setExtensionUnloadMode() end
	mileage_dragLobby = {getLocalStripId = function() return localStrip end}
	local transport = dofile(TRANSPORT)
	return transport, wire
end

test("#19: a message for the strip's leader carries the sender's strip", function()
	local transport, wire = realTransport("B")
	transport.send("dragRaceFinishTime", "host", {rawTime = 12.3})
	same(#wire, 1, "messages sent")
	same(wire[1].name, "dragMP", "event")
	same(wire[1].data.stripId, "B", "envelope strip")
	same(wire[1].data.data.stripId, nil, "the game's data is untouched")
end)

test("#19: only leader messages carry a strip, and only from a player at one", function()
	local transport, wire = realTransport("B")
	transport.send("dragRaceStart", "all", {raceId = "B-1"})
	transport.send("dragRaceStart", {2, 3}, {raceId = "B-1"})
	same(wire[1].data.stripId, nil, "strip on a message to everyone")
	same(wire[2].data.stripId, nil, "strip on a message to a list")
	local away, awayWire = realTransport(nil)
	away.send("dragRaceFinishTime", "host", {rawTime = 1})
	same(awayWire[1].data.stripId, nil, "strip from a player at no strip")
end)

--== #19: the server routes a leader message by the envelope's strip ==========

local function encode(v)
	if type(v) == "table" then
		local parts = {}
		for k, val in pairs(v) do table.insert(parts, "[" .. encode(k) .. "]=" .. encode(val)) end
		table.sort(parts)
		return "{" .. table.concat(parts, ",") .. "}"
	elseif type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

local function decode(text)
	local chunk = (loadstring or load)("return " .. tostring(text))
	if not chunk then error("does not decode") end
	return chunk()
end

local server

-- The real plugin on a stand-in BeamMP server with players 1 to 4.
local function newServer()
	server = {now = 0, sent = {}, printed = {}, players = {}}
	FS = {Exists = function() return true end, CreateDirectory = function() end}
	for id = 1, 4 do server.players[id] = "player" .. id end
	Util = {JsonEncode = encode, JsonDecode = decode}
	MP = {
		CreateTimer = function() return {GetCurrent = function() return server.now end, Start = function() end} end,
		GetPlayers = function()
			local copy = {}
			for id, name in pairs(server.players) do copy[id] = name end
			return copy
		end,
		IsPlayerConnected = function(id) return server.players[id] ~= nil end,
		GetPlayerName = function(id) return server.players[id] end,
		TriggerClientEvent = function(target, event, data)
			table.insert(server.sent, {target = target, event = event, data = data})
		end,
		SendNotification = function() end,
		DropPlayer = function() end,
	}
	local realPrint = print
	print = function() end
	dofile(SERVER)
	print = function(line) table.insert(server.printed, tostring(line)) end
	server.restorePrint = function() print = realPrint end
	return server
end

local function dragFrom(playerId, envelope)
	server.sent = {}
	local ok, err = pcall(dragMP, playerId, encode(envelope))
	if not ok then
		server.restorePrint()
		error(err, 0)
	end
	return server.sent
end

local function relayedTo(list)
	local targets = {}
	for _, m in ipairs(list) do
		if m.event == "rxDragMP" then table.insert(targets, tostring(m.target)) end
	end
	table.sort(targets)
	return table.concat(targets, ",")
end

-- Strip A led by player 1, strip B led by player 2 with player 3 also there.
local function twoBusyStrips()
	newServer()
	dragFrom(1, {msg = "mileageDragJoin", to = "host", data = {stripId = "A"}})
	dragFrom(2, {msg = "mileageDragJoin", to = "host", data = {stripId = "B"}})
	dragFrom(3, {msg = "mileageDragJoin", to = "host", data = {stripId = "B"}})
end

local function finally(fn)
	local ok, err = pcall(fn)
	if server and server.restorePrint then server.restorePrint() end
	if not ok then error(err, 0) end
end

test("#19: with two busy strips a finish time naming no strip reaches the sender's strip leader", function()
	finally(function()
		twoBusyStrips()
		local out = dragFrom(3, {msg = "dragRaceFinishTime", to = "host", data = {rawTime = 12.3}, stripId = "B"})
		same(relayedTo(out), "2", "relayed to")
		local out2 = dragFrom(4, {msg = "dragRaceFinishTime", to = "host", data = {rawTime = 11.1}, stripId = "A"})
		same(relayedTo(out2), "1", "relayed to for strip A")
	end)
end)

test("#19: the message's own strip and race id still win over the envelope's", function()
	finally(function()
		twoBusyStrips()
		same(relayedTo(dragFrom(3, {msg = "x", to = "host", data = {stripId = "A"}, stripId = "B"})), "1",
			"a message naming strip A")
		same(relayedTo(dragFrom(3, {msg = "x", to = "host", data = {raceId = "A-5"}, stripId = "B"})), "1",
			"a message for race A-5")
	end)
end)

test("#19: an unknown or non-text envelope strip is ignored", function()
	finally(function()
		twoBusyStrips()
		same(relayedTo(dragFrom(3, {msg = "x", to = "host", data = {rawTime = 1}, stripId = "C"})), "", "unknown strip")
		same(relayedTo(dragFrom(3, {msg = "y", to = "host", data = {rawTime = 1}, stripId = 2})), "", "a number")
		same(relayedTo(dragFrom(3, {msg = "z", to = "host", data = {rawTime = 1}, stripId = {"B"}})), "", "a list")
	end)
end)

test("#19: a leader message that matches no strip is logged once per 10 s by name and sender", function()
	finally(function()
		twoBusyStrips()
		server.printed = {}
		for _ = 1, 5 do
			same(relayedTo(dragFrom(3, {msg = "dragRaceFinishTime", to = "host", data = {rawTime = 1}})), "", "relayed to")
		end
		same(countLines(server.printed, "drag: no strip leader for dragRaceFinishTime from 3; not sent"), 1, "log lines")
		dragFrom(4, {msg = "dragRaceFinishTime", to = "host", data = {rawTime = 1}})
		same(countLines(server.printed, "from 4; not sent"), 1, "another sender's line")
		server.now = 10
		dragFrom(3, {msg = "dragRaceFinishTime", to = "host", data = {rawTime = 1}})
		same(countLines(server.printed, "from 3; not sent"), 2, "log lines after 10 s")
	end)
end)

test("#19: a message name with control characters is logged on one line", function()
	finally(function()
		twoBusyStrips()
		server.printed = {}
		dragFrom(3, {msg = "bad\nname", to = "host", data = {rawTime = 1}})
		same(#server.printed, 1, "printed lines")
		expect(not server.printed[1]:find("\n", 1, true), "a line break was printed: " .. server.printed[1])
	end)
end)

test("#19: with one busy strip a message naming no strip still reaches its leader, as before", function()
	finally(function()
		newServer()
		dragFrom(1, {msg = "mileageDragJoin", to = "host", data = {stripId = "A"}})
		same(relayedTo(dragFrom(3, {msg = "dragRaceFinishTime", to = "host", data = {rawTime = 1}})), "1", "relayed to")
	end)
end)

--== #20: a mission at the strip releases the claim ===========================

test("#20: starting a mission at the strip sends one leave on its first frame and clears the strip", function()
	local lobby = newGame({"A"})
	lobby.setLocalContext(stripData("A"), 1)
	same(lobby.getLocalStripId(), "A", "strip held before the mission")
	sent = {}
	game.mission = true
	game.now = 1
	lobby.onUpdate(1 / 60)
	local leaves = sentNamed("mileageDragLeave")
	same(#leaves, 1, "leave messages")
	same(leaves[1].data.stripId, "A", "strip left")
	same(lobby.getLocalStripId(), nil, "strip held during the mission")
	for _ = 1, 10 do
		game.now = game.now + 1
		lobby.onUpdate(1 / 60)
	end
	same(#sentNamed("mileageDragLeave"), 1, "leave messages after more frames")
	same(#sentNamed("mileageDragJoin"), 0, "the strip is not claimed again during the mission")
end)

test("#20: releasing the strip for a mission leaves the mission's race on screen", function()
	local lobby = newGame({"A"})
	lobby.setLocalContext(stripData("A"), 1)
	local tornDown = 0
	-- The last multiplayer race still counts as over, and the mission's racers are in the
	-- drag core's data.
	multiplayer_gamemodes_drag_drag.isRaceOver = function() return true end
	multiplayer_gamemodes_drag_drag.tearDownRaceUI = function() tornDown = tornDown + 1 end
	gameplay_drag_core.getData = function() return {racers = {[7] = {}}} end
	game.mission = true
	lobby.onUpdate(1 / 60)
	same(#sentNamed("mileageDragLeave"), 1, "leave messages")
	same(tornDown, 0, "race displays torn down")
end)

test("#20: a mission with no strip held sends nothing", function()
	local lobby = newGame({"A"})
	be.getObjectByID = function() return nil end
	game.mission = true
	lobby.onUpdate(1 / 60)
	same(#sent, 0, "messages")
end)

--== #24: a clock estimate's age =============================================

local function clock()
	logs, sent = {}, {}
	game = {now = 0}
	function log() end
	function setExtensionUnloadMode() end
	os.clockhp = function() return game.now end
	multiplayer_gamemodes_drag_drag = nil
	mileage_dragTransport = {send = function(msgName, to, data) table.insert(sent, {msg = msgName, data = data}) end}
	return dofile(SYNCLIB)
end

-- One probe to peer 5 at time t, answered after rtt with the peer's clock ahead by offset.
-- The game's clock starts at 1000 s, so the first probe is due at once.
local START = 1000
local function sample(sync, t, rtt, offset)
	t = START + t
	game.now = t
	sent = {}
	sync.probe(5)
	local token = sent[1] and sent[1].data.token
	expect(token, "no probe sent at " .. t)
	game.now = t + rtt
	sync.onMileageDragMessage("mileageClockPong", 5, {token = token, t1 = t + rtt / 2 + offset})
end

test("#24: later worse samples do not keep an old estimate fresh past 120 s", function()
	local sync = clock()
	sample(sync, 0, 0.125, 100)
	for t = 10, 110, 10 do sample(sync, t, 0.5, 105) end
	game.now = START + 119
	same(sync.mapOtherClock(5, 200), 100, "the best sample, still within 120 s")
	game.now = START + 121
	same(sync.mapOtherClock(5, 200), nil, "an estimate from a 121 s old sample")
end)

test("#24: once the stored sample is stale the next one replaces it, even if worse", function()
	local sync = clock()
	sample(sync, 0, 0.125, 100)
	sample(sync, 130, 0.5, 105)
	same(sync.mapOtherClock(5, 200), 95, "the estimate from the new sample")
	same(sync.getOffsetInfo(5).rtt, 0.5, "stored round trip")
end)

test("#24: a better sample replaces the stored one at any age", function()
	local sync = clock()
	sample(sync, 0, 0.5, 100)
	sample(sync, 10, 0.0625, 99)
	same(sync.mapOtherClock(5, 200), 101, "the estimate from the better sample")
	same(sync.getOffsetInfo(5).samples, 2, "samples counted")
end)

--== edges of the strip routing and the clock age =============================

test("#18: a race id that is not text, or does not start with a known strip and a dash, has no strip", function()
	local lobby = newGame({"A"})
	arrive(lobby, 2, "A")
	same(lobby.stripIdForRace(42), nil, "a number")
	same(lobby.stripIdForRace(nil), nil, "nothing")
	same(lobby.stripIdForRace("A"), nil, "the strip id alone")
	same(lobby.stripIdForRace("AB-1"), nil, "a race at strip AB, which this game does not know")
	same(lobby.stripIdForRace("A-1"), "A", "a race at strip A")
end)

test("#19: a message whose data is not a table still reaches the envelope strip's leader, and nothing raises", function()
	finally(function()
		twoBusyStrips()
		same(relayedTo(dragFrom(3, {msg = "x", to = "host", data = 5, stripId = "B"})), "2", "data is a number")
		same(relayedTo(dragFrom(3, {msg = "y", to = "host", data = "text", stripId = "A"})), "1", "data is text")
		same(relayedTo(dragFrom(3, {msg = "z", to = "host", data = 5})), "", "data is a number, no envelope strip")
	end)
end)

test("#19: a leader who has left the server: the message is logged, not sent", function()
	finally(function()
		twoBusyStrips()
		server.players[2] = nil
		server.printed = {}
		same(relayedTo(dragFrom(3, {msg = "dragRaceFinishTime", to = "host", data = {rawTime = 1}, stripId = "B"})), "",
			"relayed to")
		same(countLines(server.printed, "drag: no strip leader for dragRaceFinishTime from 3; not sent"), 1, "log lines")
	end)
end)

test("#19: the last player leaving a strip is not logged as an unsent message", function()
	finally(function()
		twoBusyStrips()
		server.printed = {}
		dragFrom(1, {msg = "mileageDragLeave", to = "host", data = {stripId = "A"}})
		dragFrom(4, {msg = "mileageDragLeave", to = "host", data = {stripId = "C"}})
		same(countLines(server.printed, "not sent"), 0, "unsent lines for presence messages")
	end)
end)

test("#24: at exactly 120 s a worse sample does not replace the stored one, which is still used", function()
	local sync = clock()
	sample(sync, 0, 0.125, 100)
	-- The stored sample was taken at START + 0.125; this one lands exactly 120 s later.
	sample(sync, 119.875, 0.25, 105)
	same(sync.getOffsetInfo(5).rtt, 0.125, "stored round trip")
	same(sync.mapOtherClock(5, 200), 100, "the estimate at 120 s")
end)

--== leaving the strip by driving away still clears a finished race ===========

test("#20: driving away from the strip after a finished race still takes the race off the screen", function()
	local lobby = newGame({"A"})
	lobby.setLocalContext(stripData("A"), 1)
	local tornDown = 0
	multiplayer_gamemodes_drag_drag.isRaceOver = function() return true end
	multiplayer_gamemodes_drag_drag.tearDownRaceUI = function() tornDown = tornDown + 1 end
	gameplay_drag_core.getData = function() return {racers = {[7] = {}}} end
	local far = {getPosition = function() return newVec(500, 0, 0) end}
	be.getObjectByID = function(_, id) return id == 7 and far or nil end
	sent = {}
	game.now = 1
	lobby.onUpdate(1 / 60)
	same(#sentNamed("mileageDragLeave"), 1, "leave messages")
	same(lobby.getLocalStripId(), nil, "strip held after driving away")
	same(tornDown, 1, "race displays torn down")
end)

--== #22: only a drag mission takes the strip from multiplayer drag ==========

-- A foreground mission of this type, as the game's mission manager and mission list
-- report it. missionType = nil gives a mission with no type; found = false an id the
-- list cannot find.
local function foregroundMission(missionType, found)
	gameplay_missions_missionManager = {getForegroundMissionId = function() return "m1" end}
	gameplay_missions_missions = {getMissionById = function(id)
		if found == false or id ~= "m1" then return nil end
		return {id = id, missionType = missionType}
	end}
end

local function noMission()
	gameplay_missions_missionManager = {getForegroundMissionId = function() return nil end}
	gameplay_missions_missions = nil
	career_modules_vehiclePerformance = nil
end

local function dragState(drag)
	return tostring(drag.isMultiplayer()) .. " " .. tostring(drag.shouldSyncState())
end

test("#22: a non-drag mission leaves multiplayer drag on", function()
	newGame({"A"})
	noMission()
	local drag = realDragMode()
	same(dragState(drag), "true true", "multiplayer and sync with no mission")
	foregroundMission("timeTrial")
	same(dragState(drag), "true true", "multiplayer and sync during a time trial")
	foregroundMission("chase")
	same(dragState(drag), "true true", "multiplayer and sync during a chase")
	noMission()
end)

test("#22: a drag mission and the performance test still turn multiplayer drag off", function()
	newGame({"A"})
	noMission()
	local drag = realDragMode()
	for _, missionType in ipairs({"drag", "dragRace", "Drag Race", "bmraDRAG"}) do
		foregroundMission(missionType)
		same(dragState(drag), "false false", "multiplayer and sync during a " .. missionType .. " mission")
	end
	noMission()
	career_modules_vehiclePerformance = {isTestInProgress = function() return true end}
	same(dragState(drag), "false false", "multiplayer and sync during the performance test")
	noMission()
end)

test("#22: a mission whose type cannot be read still takes the strip, as before", function()
	newGame({"A"})
	noMission()
	local drag = realDragMode()
	foregroundMission(nil)
	same(dragState(drag), "false false", "a mission with no type")
	foregroundMission(42)
	same(dragState(drag), "false false", "a mission whose type is not text")
	foregroundMission("timeTrial", false)
	same(dragState(drag), "false false", "a mission id the mission list cannot find")
	foregroundMission("timeTrial")
	gameplay_missions_missions = nil
	same(dragState(drag), "false false", "no mission list")
	foregroundMission("timeTrial")
	gameplay_missions_missions = {getMissionById = function() error("mission list broke") end}
	same(dragState(drag), "false false", "a mission lookup that raises")
	noMission()
end)

--== #21: the drag senders stay quiet while a mission owns the strip ===========

-- Calls each of the four senders once for race A-1 at strip A, with player 2 there too.
-- Returns the names of what went out, in order, with where each went.
local function callSenders(drag)
	sent = {}
	drag.syncStageLightState("A-1", 1, true)
	drag.syncTreeLightState("A-1", 1, {stageLights = {stageLight = true}})
	drag.updateTimerValue("A-1", 7, "time_60", 2.1)
	drag.notifyRaceStart("A-1")
	local out = {}
	for _, m in ipairs(sent) do table.insert(out, m.msg .. ">" .. idList(m.to)) end
	return table.concat(out, " ")
end

local ALL_SENT = "dragRaceTreeLightUpdate>host dragRaceTreeLightUpdate>host dragRaceTimerUpdateRequest>host "
	.. "dragRaceStart>2 dragRaceStart>local"

test("#21: no drag light, timer or race start goes out while a drag mission owns the strip", function()
	local lobby = newGame({"A"})
	arrive(lobby, 2, "A")
	noMission()
	local drag = realDragMode()
	foregroundMission("dragRace")
	same(callSenders(drag), "", "messages during a drag mission")
	noMission()
	career_modules_vehiclePerformance = {isTestInProgress = function() return true end}
	same(callSenders(drag), "", "messages during the performance test")
	noMission()
end)

test("#21: once the mission ends the race start for the same race still goes out", function()
	local lobby = newGame({"A"})
	arrive(lobby, 2, "A")
	noMission()
	local drag = realDragMode()
	foregroundMission("dragRace")
	callSenders(drag)
	noMission()
	same(callSenders(drag), ALL_SENT, "messages after the mission")
end)

test("#21: a non-drag mission does not hold the senders back", function()
	local lobby = newGame({"A"})
	arrive(lobby, 2, "A")
	noMission()
	local drag = realDragMode()
	foregroundMission("timeTrial")
	same(callSenders(drag), ALL_SENT, "messages during a time trial")
	noMission()
end)

-- The mission types 0.40.4.0 labels as drag races, and its generated time trial
-- (lua/ge/extensions/ui/gameplaySelector/tileGenerators/missionTiles.lua:3-6).
test("#22: the game's own drag mission types take the strip; its generated time trial does not", function()
	newGame({"A"})
	noMission()
	local drag = realDragMode()
	for _, missionType in ipairs({"dragStripRace", "dragStripAPM"}) do
		foregroundMission(missionType)
		same(dragState(drag), "false false", "multiplayer and sync during a " .. missionType .. " mission")
	end
	foregroundMission("generatedTimeTrial")
	same(dragState(drag), "true true", "multiplayer and sync during a generatedTimeTrial mission")
	noMission()
end)

test("#22: a mission's type is logged once per mission, not on every check", function()
	newGame({"A"})
	noMission()
	local drag = realDragMode()
	foregroundMission("timeTrial")
	for _ = 1, 5 do drag.isMultiplayer() drag.shouldSyncState() end
	same(countLines(logs, "type=timeTrial"), 1, "log lines for the time trial")
	gameplay_missions_missionManager = {getForegroundMissionId = function() return "m2" end}
	gameplay_missions_missions = {getMissionById = function(id) return {id = id, missionType = "dragRace"} end}
	for _ = 1, 5 do drag.isMultiplayer() end
	same(countLines(logs, "type=dragRace"), 1, "log lines for the next mission")
	noMission()
end)
