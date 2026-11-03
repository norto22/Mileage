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
		strips = {stripData("A")}, logs = {}, wire = {}, applied = {}, flashes = {}, apps = {},
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

-- Run the clock to `untilSeconds` in half-second frames.
local function runTo(untilSeconds)
	while world.now < untilSeconds - 1e-9 do
		world.now = world.now + 0.5
		pump()
		world.lobby.onUpdate(0.5)
		world.drag.onUpdate()
		pump()
	end
end

-- Another player's lobby message, as the relay delivers it to this player.
local function fromPlayer(playerId, msgName, data)
	world.handlers.rxDragMP({msg = msgName, from = playerId, data = data})
	pump()
end

-- Another player standing on lane `lane`'s line, heart-beating as their client does.
local function otherAt(playerId, lane)
	fromPlayer(playerId, "mileageDragJoin", {stripId = "A", lane = lane, vehicleId = 55,
		pos = lane == 2 and {4, 0, 0} or {0, 0, 0}})
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
