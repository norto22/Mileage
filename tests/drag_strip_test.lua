-- Runs at the drag strip: a lone player, two players, and every way a run ends.
--
-- The game's drag code is BeamNG's own and is not in this repository, so the stand-in below
-- behaves like its 0.40.4.0 race start where it matters here: the race start sets up a
-- stand-in racer for every player from the race snapshot, and only swaps this player's
-- stand-in for their real car when the drag mode answers getLocalMPPlayerId; the session
-- handler records this player's run only when the transport's bridge answers the same name.
-- Mileage's real lobby, transport and drag mode run on top.
--
-- This machine is player 1, driving car 7, parked on lane 1's stage line of strip "A".

local LOBBY = "Resources/Client/Mileage/lua/ge/extensions/mileage/dragLobby.lua"
local DRAG_MODE = "Resources/Client/Mileage/lua/ge/extensions/multiplayer/gamemodes/drag/drag.lua"
local TRANSPORT = "Resources/Client/Mileage/lua/ge/extensions/mileage/dragTransport.lua"

local CAR = 7
local ME = 1

local world
local pump, setLeader

local function newVec(x, y, z)
	if type(x) == "table" then x, y, z = x[1] or x.x, x[2] or x.y, x[3] or x.z end
	local v = {x = x or 0, y = y or 0, z = z or 0}
	return setmetatable(v, {__index = {
		distance = function(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end,
	}, __sub = function(a, b) return newVec(a.x - b.x, a.y - b.y, a.z - b.z) end})
end

local function copy(t)
	if type(t) ~= "table" then return t end
	local r = {}
	for k, v in pairs(t) do r[k] = copy(v) end
	return r
end

local function stripData(id)
	return {id = id, strip = {lanes = {
		{waypoints = {
			stage = {transform = {position = {0, 0, 0}}},
			endLine = {transform = {position = {0, 400, 0}}},
		}},
		{waypoints = {
			stage = {transform = {position = {4, 0, 0}}},
			endLine = {transform = {position = {4, 400, 0}}},
		}},
	}}, prefabs = {christmasTree = {treeType = ".500"}}}
end

--== the game's drag code, as 0.40.4.0 behaves ==================================

local function newCore()
	local c = {}
	local dragData, races, latest, lastStarted = nil, {}, nil, nil

	local function setupRacer(vehId, lane)
		dragData.racers[vehId] = {
			vehId = vehId, lane = lane, currentPhase = 1, isFinished = false,
			phases = {{completed = false}, {started = false}, {}},
		}
	end

	function c.getData() return dragData end
	function c.getDragIsStarted() return dragData ~= nil and dragData.isStarted == true end
	function c.setDragRaceData(poiData)
		if not poiData then dragData = nil return end
		dragData = {racers = {}, strip = poiData.strip, isStarted = false, isCompleted = false}
	end
	function c.getRaceState(raceId) return races[raceId or latest] end
	function c.setRaceState(raceId, updates)
		races[raceId] = races[raceId] or {id = raceId}
		for k, v in pairs(updates) do races[raceId][k] = v end
		latest = raceId
	end
	function c.getDragDataForLevel() return world.strips end

	-- The 0.40.4.0 race start: a racer per player in the heat from the snapshot (a stand-in
	-- with the snapshot's key), then this player's stand-in swapped for the real car only
	-- when the drag mode answers the new name.
	function c.onDragRaceStarted(raceId)
		if raceId == lastStarted then return end
		local race = races[raceId]
		if not race or not dragData then return end
		lastStarted = raceId
		local players = race.players or {}
		local slot = race.queue and race.queue[race.currentPairIndex or 1] or {}
		for lane, playerId in pairs(slot) do
			local pd = players[playerId]
			if pd then setupRacer(pd.vehicleId, lane) end
		end
		local drag = multiplayer_gamemodes_drag_drag
		if drag and drag.isMultiplayer and drag.isMultiplayer() then
			local localMP = drag.getLocalMPPlayerId and drag.getLocalMPPlayerId()
			local localVeh = be:getPlayerVehicleID(0)
			if world.renamed then localMP = nil end
			if localMP and localVeh and localVeh > 0 then
				local pd = players[localMP]
				if pd and pd.lane then
					if pd.vehicleId ~= localVeh then dragData.racers[pd.vehicleId] = nil end
					if not dragData.racers[localVeh] then setupRacer(localVeh, pd.lane) end
				end
			end
			for vehId, racer in pairs(dragData.racers) do racer.isLocalRacer = (vehId == localVeh) end
		end
		dragData.isStarted = true
	end

	function c.onDragRaceReset()
		if dragData then
			dragData.isStarted = false
			dragData.isCompleted = false
		end
		lastStarted = nil
	end

	function c.allRacersFinished(data)
		for _, racer in pairs((data or {}).racers or {}) do
			if not racer.isFinished then return false end
		end
		return true
	end

	function c.clear()
		world.cleared = world.cleared + 1
		dragData, races, latest, lastStarted = nil, {}, nil, nil
	end

	function c.finalizeMpPostRace() world.finalized = world.finalized + 1 end
	return c
end

local function newPhaseHandlers()
	local ph = {}
	function ph.areAllRacersStaged(data)
		local staged, total = 0, 0
		for _, racer in pairs(data.racers or {}) do
			total = total + 1
			if racer.phases[1].completed then staged = staged + 1 end
		end
		return total > 0 and staged == total, staged, total
	end
	function ph.changeAllPhases()
		for _, racer in pairs(gameplay_drag_core.getData().racers) do
			if racer.currentPhase == 1 and racer.phases[1].completed then racer.currentPhase = 2 end
		end
	end
	return ph
end

-- The game's session handlers: a run is recorded as ours only through the bridge's new name.
local function newHandlers()
	local h = {}
	function h.handle(msgName, state, bridge, client, senderId, recp, data)
		table.insert(world.applied, msgName)
		local core = gameplay_drag_core
		if msgName == "dragSessionStarted" then
			local r = data.race
			table.insert(world.sessions, {raceId = data.raceId, race = r})
			core.setRaceState(data.raceId, {
				players = r.players, queue = r.queue, currentPairIndex = r.currentPairIndex or 1,
				poiData = r.poiData, lobbyId = data.lobbyId, finishTimes = {},
			})
			state.dragRaces[data.raceId] = {id = data.raceId, lobbyId = data.lobbyId}
			core.setDragRaceData(r.poiData and copy(r.poiData) or nil)
			local localMP = bridge.getLocalMPPlayerId and bridge.getLocalMPPlayerId()
			if world.renamed then localMP = nil end
			local players = r.players or {}
			if localMP and players[localMP] then
				bridge.setLocalClientActiveRace(data.raceId, r.poiData, players[localMP].lane or 1, r.treeType)
			end
		elseif msgName == "dragRaceStarted" then
			core.setRaceState(data.raceId, {isStarted = true})
			extensions.hook("onDragRaceStarted", data.raceId)
		elseif msgName == "dragRaceCountdownStart" then
			local entry = state.dragRaces[data.raceId]
			if entry then entry.syncCountdownStart = data.startTime end
		elseif msgName == "dragRaceReset" then
			local updates = {}
			if data.queue then updates.queue = data.queue end
			if data.currentPairIndex then updates.currentPairIndex = data.currentPairIndex end
			core.setRaceState(data.raceId, updates)
			extensions.hook("onDragRaceReset", data.raceId)
		end
	end
	return h
end

--== the world: this machine, the relay and the clock ===========================

-- leader: who the server says leads strip "A" (this player unless told otherwise).
local function newWorld(opts)
	opts = opts or {}
	world = {
		now = 0, pos = {0, 0, 0}, renamed = false, cleared = 0, finalized = 0,
		strips = {stripData("A")}, logs = {}, wire = {}, applied = {}, flashes = {}, apps = {}, sessions = {},
		queued = {}, handlers = {}, loaded = {},
	}

	function log(level, tag, msg) table.insert(world.logs, level .. " " .. tag .. ": " .. tostring(msg)) end
	function setExtensionUnloadMode() end
	os.clockhp = function() return world.now end
	vec3 = newVec
	deepcopy = copy
	quatFromDir = function(dir) return {dir = dir} end
	function getCurrentLevelIdentifier() return world.level or "west_coast_usa" end
	local car = {getPosition = function() return newVec(world.pos) end}
	be = {
		getPlayerVehicleID = function() return CAR end,
		getObjectByID = function(_, id) return id == CAR and car or nil end,
	}
	MPConfig = {getNickname = function() return "Me" end, getPlayerServerID = function() return ME end}
	guihooks = {trigger = function(name, data)
		if name == "TopCenterAppsFlashMessage" then table.insert(world.flashes, data.msg) end
	end}
	ui_appContainers = {
		showApp = function(_, app) table.insert(world.apps, "show " .. tostring(app)) end,
		hideApp = function(_, app) table.insert(world.apps, "hide " .. tostring(app)) end,
	}
	gameplay_rawPois = {clear = function() world.poiClears = (world.poiClears or 0) + 1 end}
	gameplay_markerInteraction = {clearCache = function() end}
	gameplay_missions_missionManager = nil
	gameplay_drag_dragTypes_dragPracticeRace = nil

	extensions = {
		load = function() end,
		hook = function(name, ...)
			for _, m in ipairs(world.loaded) do
				if type(m[name]) == "function" then m[name](...) end
			end
		end,
	}

	-- BeamMP: a message for "host" reaches the strip's leader, whoever sent it; a message
	-- for a list of players reaches them. Only what reaches this player comes back here.
	function AddEventHandler(name, fn) world.handlers[name] = fn end
	function TriggerServerEvent(name, data)
		if name ~= "dragMP" then return end
		table.insert(world.wire, data)
		local leader = world.leader
		if data.to == "host" and leader == ME then
			table.insert(world.queued, {msg = data.msg, from = ME, data = copy(data.data)})
		end
	end
	jsonEncode = function(t) return t end
	jsonDecode = function(t) return t end

	gameplay_drag_core = newCore()
	gameplay_drag_phaseHandlers = newPhaseHandlers()
	gameplay_drag_mpDragHandlers = newHandlers()
	table.insert(world.loaded, gameplay_drag_core)

	mileage_dragTransport = dofile(TRANSPORT)
	multiplayer_gamemodes_drag_drag = dofile(DRAG_MODE)
	mileage_dragLobby = dofile(LOBBY)
	table.insert(world.loaded, mileage_dragTransport)
	table.insert(world.loaded, multiplayer_gamemodes_drag_drag)
	table.insert(world.loaded, mileage_dragLobby)
	mileage_dragTransport.onExtensionLoaded()
	multiplayer_gamemodes_drag_drag.setEnabled(true)

	world.lobby, world.drag, world.transport = mileage_dragLobby, multiplayer_gamemodes_drag_drag, mileage_dragTransport
	setLeader(opts.leader or ME)
	return world
end

-- Deliver what the relay holds for this player.
function pump()
	while #world.queued > 0 do
		local m = table.remove(world.queued, 1)
		world.handlers.rxDragMP({msg = m.msg, from = m.from, data = m.data})
	end
end

-- The server moves strip "A" to another leader (and tells this player).
function setLeader(playerId)
	world.leader = playerId
	world.handlers.rxDragAuthority({stripId = "A", playerId = playerId})
	pump()
end

-- Another player's lobby message, as the relay delivers it to this player.
local function fromPlayer(playerId, msgName, data)
	world.handlers.rxDragMP({msg = msgName, from = playerId, data = data})
	pump()
end

-- Another player standing on lane `lane`'s line. They keep heart-beating every 5 s, as their
-- client does, until otherLeaves.
local function otherAt(playerId, lane)
	world.others = world.others or {}
	world.others[playerId] = lane
	fromPlayer(playerId, "mileageDragJoin", {stripId = "A", lane = lane, vehicleId = 55,
		pos = lane == 2 and {4, 0, 0} or {0, 0, 0}})
end

local function otherLeaves(playerId)
	world.others[playerId] = nil
	fromPlayer(playerId, "mileageDragLeave", {stripId = "A"})
end

-- Run the clock to `untilSeconds` in half-second frames.
local function runTo(untilSeconds)
	while world.now < untilSeconds - 1e-9 do
		world.now = world.now + 0.5
		if world.leader == ME and world.now % 5 == 0 then
			for playerId, lane in pairs(world.others or {}) do otherAt(playerId, lane) end
		end
		pump()
		world.lobby.onUpdate(0.5)
		world.drag.onUpdate()
		pump()
	end
end

local function wireNamed(name)
	local out = {}
	for _, m in ipairs(world.wire) do if m.msg == name then table.insert(out, m) end end
	return out
end

local function appliedCount(name)
	local n = 0
	for _, m in ipairs(world.applied) do if m == name then n = n + 1 end end
	return n
end

local function racerKeys()
	local data = gameplay_drag_core.getData()
	local keys = {}
	for key, racer in pairs(data and data.racers or {}) do
		table.insert(keys, string.format("%s:lane%s:%s", tostring(key), tostring(racer.lane),
			racer.isLocalRacer and "local" or "remote"))
	end
	table.sort(keys)
	return table.concat(keys, " ")
end

-- Stage every racer in the current run (our beams, and the leader's mark for the others).
local function stageAll()
	for _, racer in pairs(gameplay_drag_core.getData().racers) do racer.phases[1].completed = true end
end

-- Run until the first run starts on this machine (at most `limit` seconds).
local function untilRun(limit)
	local deadline = world.now + (limit or 60)
	while appliedCount("dragRaceStarted") == 0 and world.now < deadline do runTo(world.now + 0.5) end
end

--== the game registers your own car ===========================================

test("alone at the strip: the run registers this player's real car in lane 1, not a stand-in", function()
	newWorld()
	untilRun(60)
	same(appliedCount("dragRaceStarted"), 1, "runs started")
	same(racerKeys(), "7:lane1:local", "racers registered")
	local active = world.transport.getLocalClientActiveRace()
	same(active and active.lane, 1, "this player's run is recorded, in lane")
end)

test("the game's local-player question answers the server id under both names, or nil with none", function()
	newWorld()
	same(world.drag.getLocalMPPlayerId and world.drag.getLocalMPPlayerId(), ME, "drag mode, new name")
	same(world.drag.getLocalPlayerId(), ME, "drag mode, old name")
	same(world.transport.bridge.getLocalMPPlayerId and world.transport.bridge.getLocalMPPlayerId(), ME, "bridge, new name")
	same(world.transport.bridge.getLocalPlayerId(), ME, "bridge, old name")
	MPConfig = nil
	same(world.drag.getLocalMPPlayerId and world.drag.getLocalMPPlayerId(), nil, "drag mode with no server id")
	same(world.transport.bridge.getLocalMPPlayerId and world.transport.bridge.getLocalMPPlayerId(), nil, "bridge with no server id")
end)

--== one sequence per strip on the leader ======================================

-- The heat a run was started with, as "lane:player" pairs in lane order.
local function heatOf(session)
	local slot = session.race.queue[1] or {}
	local parts = {}
	for lane, playerId in pairs(slot) do table.insert(parts, tostring(lane) .. ":" .. tostring(playerId)) end
	table.sort(parts)
	return table.concat(parts, " ")
end

local function lastSession() return world.sessions[#world.sessions] end

-- The players a message on the wire went to, as "2,3".
local function recipients(m)
	if type(m.to) ~= "table" then return tostring(m.to) end
	local ids = {}
	for _, id in ipairs(m.to) do table.insert(ids, tostring(id)) end
	table.sort(ids)
	return table.concat(ids, ",")
end

-- The real car on this machine, and another player's stand-in, by player id.
local function racerOf(playerId)
	local data = gameplay_drag_core.getData()
	if not data then return nil end
	return data.racers[playerId == ME and CAR or -(playerId + 2)]
end

test("alone at the strip: no run before 10 s, one run by 11 s", function()
	newWorld()
	runTo(10)
	same(#world.sessions, 0, "runs started by 10 s")
	runTo(11)
	same(#world.sessions, 1, "runs started by 11 s")
	same(heatOf(lastSession()), "1:1", "heat")
end)

test("two players at the strip: a run at once, each in their own lane", function()
	newWorld()
	runTo(1)
	otherAt(2, 2)
	runTo(1.5)
	same(#world.sessions, 1, "runs started")
	same(heatOf(lastSession()), "1:1 2:2", "heat")
	local sessions = wireNamed("dragSessionStarted")
	same(#sessions, 1, "run sent to the other player")
	same(recipients(sessions[1]), "2", "recipients")
end)

test("a second player who arrives during staging races in the other lane", function()
	newWorld()
	runTo(11)
	same(heatOf(lastSession()), "1:1", "solo heat")
	otherAt(2, 2)
	runTo(11.5)
	same(#world.sessions, 2, "runs started")
	same(heatOf(lastSession()), "1:1 2:2", "rebuilt heat")
	same(racerKeys(), "-4:lane2:remote 7:lane1:local", "racers registered")
end)

test("a player who leaves before the countdown: the run is rebuilt without them", function()
	newWorld()
	runTo(1)
	otherAt(2, 2)
	runTo(2)
	same(heatOf(lastSession()), "1:1 2:2", "first heat")
	otherLeaves(2)
	runTo(2.5)
	same(world.lobby.getRun("A"), nil, "run while one player waits again")
	runTo(13)
	same(#world.sessions, 2, "runs started")
	same(heatOf(lastSession()), "1:1", "heat without the player who left")
end)

test("not staged in 30 s: the run ends and the parked leader sits out until they move 5 m", function()
	newWorld()
	runTo(11)
	local started = world.now
	runTo(started + 29.5)
	expect(world.lobby.getRun("A") ~= nil, "run still staging at 29.5 s")
	runTo(started + 30.5)
	same(world.lobby.getRun("A"), nil, "run after 30 s")
	runTo(started + 60)
	same(#world.sessions, 1, "runs while the leader sits out on the line")
	world.pos = {0, 6, 0}
	runTo(started + 80)
	same(#world.sessions, 2, "runs once the leader moved")
end)

test("an idle leader sits out and still runs the other lane's run", function()
	newWorld()
	runTo(1)
	otherAt(2, 2)
	runTo(2)
	racerOf(2).phases[1].completed = true
	runTo(33)
	same(world.transport.isAuthorityFor("A"), true, "the idle leader still leads the strip")
	runTo(45)
	same(#world.sessions, 2, "runs started")
	same(heatOf(lastSession()), "2:2", "the other lane's solo heat")
	same(recipients(wireNamed("dragSessionStarted")[2]), "2", "sent to the other player")
end)

test("a racer in the run with no racer in the game's race counts as not staged", function()
	newWorld()
	runTo(1)
	otherAt(2, 2)
	runTo(2)
	gameplay_drag_core.getData().racers[-4] = nil
	racerOf(1).phases[1].completed = true
	runTo(32.5)
	same(world.lobby.getRun("A"), nil, "run after 30 s")
	same(appliedCount("dragRaceCountdownStart"), 0, "countdowns")
end)

test("a staged run counts down once; a finish shows the result, and 12 s later the strip resets", function()
	newWorld()
	runTo(11)
	stageAll()
	runTo(12)
	same(appliedCount("dragRaceCountdownStart"), 1, "countdowns")
	same(world.lobby.getRun("A").step, "running", "step")
	runTo(15)
	same(appliedCount("dragRaceCountdownStart"), 1, "countdowns after more frames")
	racerOf(1).isFinished = true
	runTo(15.5)
	same(world.lobby.getRun("A").step, "result", "step after the finish")
	runTo(27)
	same(appliedCount("dragRaceReset"), 0, "resets before 12 s")
	runTo(28)
	same(appliedCount("dragRaceReset"), 1, "resets after 12 s")
	same(world.lobby.getRun("A"), nil, "run after the result")
end)

test("back on the line after the result: another run, as many times as you like", function()
	newWorld()
	for n = 1, 3 do
		untilRun(30)
		same(#world.sessions, n, "runs started")
		stageAll()
		runTo(world.now + 1)
		racerOf(1).isFinished = true
		runTo(world.now + 13)
		same(world.lobby.getRun("A"), nil, "run after result " .. n)
		world.applied = {}
	end
end)

test("nobody finishes in 60 s after the countdown: the result step starts anyway", function()
	newWorld()
	runTo(11)
	stageAll()
	runTo(12)
	local green = world.lobby.getRun("A").since
	runTo(green + 59.5)
	same(world.lobby.getRun("A").step, "running", "step at 59.5 s")
	runTo(green + 60.5)
	same(world.lobby.getRun("A").step, "result", "step after 60 s")
end)

test("a disqualified racer counts as done, so a solo false start goes to the result", function()
	newWorld()
	runTo(11)
	stageAll()
	runTo(12)
	racerOf(1).isDisqualified = true
	runTo(12.5)
	same(world.lobby.getRun("A").step, "result", "step")
end)

--== every way out takes the lights down =======================================

-- A run the strip's leader (player 2) sends this player, as their messages arrive here.
-- players: {{playerId, lane}, ...}, all in heat 1.
local function runFromLeader(raceId, players)
	local list, heat = {}, {}
	for _, p in ipairs(players) do
		table.insert(list, {playerId = p[1], lane = p[2], vehicleId = -(p[1] + 2), persona = "P" .. p[1]})
		table.insert(heat, {lane = p[2], playerId = p[1]})
	end
	fromPlayer(world.leader, "dragSessionStarted", {raceId = raceId, lobbyId = "A",
		race = {id = raceId, poiKey = "A", players = list, queue = {heat}, currentPairIndex = 1}})
	fromPlayer(world.leader, "dragRaceStarted", {raceId = raceId})
end

local function activeRunId()
	local active = world.transport.getLocalClientActiveRace()
	return active and active.id
end

-- Two players racing: staged, and the tree gone.
local function twoPlayersRunning()
	newWorld()
	runTo(1)
	otherAt(2, 2)
	runTo(2)
	stageAll()
	runTo(2.5)
	same(world.lobby.getRun("A").step, "running", "step")
end

test("not staged in 30 s: the leader's display comes down and the other player gets one cancel", function()
	newWorld()
	runTo(1)
	otherAt(2, 2)
	runTo(2)
	world.cleared = 0
	runTo(33)
	local cancels = wireNamed("mileageDragCancel")
	same(#cancels, 1, "cancels sent")
	same(recipients(cancels[1]), "2", "recipients")
	same(cancels[1].data.stripId, "A", "strip")
	same(world.cleared, 1, "displays taken down on the leader")
	same(activeRunId(), nil, "run id kept on the leader")
end)

test("driving away from a run that never counted down takes the display down", function()
	newWorld()
	runTo(11)
	expect(activeRunId() ~= nil, "a run is up")
	world.cleared = 0
	world.pos = {500, 0, 0}
	runTo(11.5)
	same(#wireNamed("mileageDragLeave"), 1, "leave messages")
	expect(world.cleared >= 1, "the display was taken down")
	same(activeRunId(), nil, "run id kept")
end)

test("a cancel from the strip's leader takes the run down; from anyone else, or for another run, nothing", function()
	newWorld({leader = 2})
	runTo(1)
	runFromLeader("A-5", {{1, 1}, {2, 2}})
	same(activeRunId(), "A-5", "run recorded")
	world.cleared = 0
	fromPlayer(3, "mileageDragCancel", {stripId = "A", raceId = "A-5", reason = "staging"})
	fromPlayer(2, "mileageDragCancel", {stripId = "A", raceId = "A-9", reason = "staging"})
	fromPlayer(2, "mileageDragCancel", "not a table")
	same(world.cleared, 0, "displays taken down by the wrong cancels")
	same(activeRunId(), "A-5", "run after the wrong cancels")
	fromPlayer(2, "mileageDragCancel", {stripId = "A", raceId = "A-5", reason = "staging"})
	same(world.cleared, 1, "displays taken down")
	same(activeRunId(), nil, "run id kept")
end)

test("the leader drops out during staging: the run comes down, and a fresh run forms with this player leading", function()
	newWorld({leader = 2})
	runTo(1)
	runFromLeader("A-5", {{1, 1}, {2, 2}})
	world.cleared = 0
	setLeader(ME)
	same(world.cleared, 1, "displays taken down")
	same(activeRunId(), nil, "run id kept")
	runTo(13)
	same(#world.sessions, 2, "runs seen")
	same(heatOf(lastSession()), "1:1", "the fresh run's heat")
end)

test("the leader drops out during a run: the run comes down", function()
	newWorld({leader = 2})
	runTo(1)
	runFromLeader("A-5", {{1, 1}, {2, 2}})
	stageAll()
	world.drag.advanceOutOfStaging()
	world.cleared = 0
	setLeader(3)
	same(world.cleared, 1, "displays taken down")
	same(activeRunId(), nil, "run id kept")
end)

test("a leader change after the result is built leaves the timeslip up", function()
	newWorld({leader = 2})
	runTo(1)
	runFromLeader("A-5", {{1, 1}, {2, 2}})
	gameplay_drag_core.getRaceState("A-5").finishTimes = {[1] = 11.2, [2] = 11.9}
	world.drag.onDragMpTimeslipRequested()
	same(world.drag.isRaceFinalized(), true, "result built")
	world.cleared = 0
	setLeader(3)
	same(world.cleared, 0, "displays taken down")
end)

test("a still-racing racer who leaves mid-run ends the run, with a cancel to them", function()
	twoPlayersRunning()
	otherLeaves(2)
	runTo(3)
	same(world.lobby.getRun("A"), nil, "run")
	local cancels = wireNamed("mileageDragCancel")
	same(#cancels, 1, "cancels sent")
	same(recipients(cancels[1]), "2", "recipients")
end)

test("a finished or disqualified racer driving off does not end the other racer's run", function()
	twoPlayersRunning()
	gameplay_drag_core.getRaceState(world.lobby.getRun("A").raceId).finishTimes = {[2] = 12.3}
	otherLeaves(2)
	runTo(3)
	same(world.lobby.getRun("A").step, "running", "step after a finished racer left")
	same(#wireNamed("mileageDragCancel"), 0, "cancels sent")
end)

test("a disqualified opponent does not end this player's live run", function()
	twoPlayersRunning()
	racerOf(2).isDisqualified = true
	world.drag.setDisqualifiedLights(-4)
	world.pos = {0, 300, 0}
	runTo(4)
	same(#wireNamed("mileageDragLeave"), 0, "leave messages")
	same(world.lobby.getRun("A").step, "running", "step")
end)

--== a run that did not register the real car ==================================

local function warnings()
	local out = {}
	for _, line in ipairs(world.logs) do
		if line:sub(1, 2) == "W " and line:find("did not register", 1, true) then table.insert(out, line) end
	end
	return out
end

test("the game did not register this player's car: one warning naming the strip and racers, and the run ends", function()
	newWorld()
	world.renamed = true
	runTo(11)
	same(#world.sessions, 1, "runs started")
	local w = warnings()
	same(#w, 1, "warnings")
	expect(w[1]:find("'A'", 1, true) and w[1]:find("-3", 1, true), "the warning names the strip and racer keys: " .. w[1])
	same(world.lobby.getRun("A"), nil, "run")
	expect(world.cleared >= 1, "the display was taken down")
end)

test("on a player who is not the leader the same check takes the run off their screen", function()
	newWorld({leader = 2})
	world.renamed = true
	runTo(1)
	world.cleared = 0
	runFromLeader("A-5", {{1, 1}, {2, 2}})
	same(#warnings(), 1, "warnings")
	same(world.cleared, 1, "displays taken down")
end)

test("a run this player is not in is not checked, and a run with the real car logs nothing", function()
	newWorld({leader = 2})
	world.renamed = true
	runTo(1)
	runFromLeader("A-5", {{2, 1}, {3, 2}})
	same(#warnings(), 0, "warnings for a run this player is not in")
	world.renamed = false
	runFromLeader("A-6", {{1, 1}, {2, 2}})
	same(#warnings(), 0, "warnings for a run with the real car")
end)

test("this player's own disqualification lets them leave the strip", function()
	twoPlayersRunning()
	racerOf(1).isDisqualified = true
	world.pos = {0, 300, 0}
	runTo(4)
	same(#wireNamed("mileageDragLeave"), 1, "leave messages")
end)
