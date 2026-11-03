--Mileage :: drag multiplayer transport
--
-- BeamNG 0.39 ships a complete multiplayer drag racing implementation -- the receive
-- handlers (gameplay/drag/mpDragHandlers.lua, 16 message types), the state application
-- (gameplay_drag_core.setRaceState and friends), the phase machine, the UI and the
-- timeslip. What it does not ship is the layer underneath: a session manager, a
-- transport, and the object the handlers are called with.
--
-- This file is that layer, implemented over BeamMP. It provides:
--
--   * multiplayer_sessionManager -- the 5 functions the game looks for
--   * the `bridge` object mpDragHandlers is called with (10 functions)
--   * the `state` table it keeps race bookkeeping in
--   * routing of inbound messages into gameplay_drag_mpDragHandlers.handle
--
-- Deliberately thin. The protocol lives entirely in BeamNG's code, so if a game update
-- changes it, this file should not need to.

local M = {}

local logTag = "mileage.dragTransport"

-- The state table mpDragHandlers reads and writes. Shape is dictated by the handlers:
--   dragRaces[raceId] = { id, lobbyId, poiKey, syncCountdownStart, syncRaceStart,
--                         syncRandValue, localCountdownStart, localRaceStart, ... }
--   localClientActiveRace = the race this client is taking part in, or nil
local state = {
	dragRaces = {},
	localClientActiveRace = nil,
}

-- Authority is per strip, elected by the server, and held only while that player is
-- standing at the strip.
--
-- The first design made one player authoritative for all drag racing (lowest connected
-- id). That breaks racing outright: the authority decides when everyone is staged by
-- reading its OWN local drag state, so a player off doing deliveries has no drag data
-- and the countdown never fires for anyone. Scoping it to the strip guarantees the
-- authority is someone actually there.
--
-- authorityByStrip[stripId] = playerId
local authorityByStrip = {}

local function getLocalPlayerId()
	if not MPConfig or not MPConfig.getPlayerServerID then return nil end
	return MPConfig.getPlayerServerID()
end

--- Which strip are we standing at, if any? The lobby owns that fact.
local function localStripId()
	local lobby = mileage_dragLobby
	return lobby and lobby.getLocalStripId and lobby.getLocalStripId() or nil
end

local function isAuthorityFor(stripId)
	if not stripId then return false end
	local own = getLocalPlayerId()
	return own ~= nil and authorityByStrip[stripId] == own
end

--- "Are we the authority?" means "for the strip we are at". A player is only ever at
--- one strip, so there is no ambiguity, and someone who is not at a strip is never
--- authoritative for anything.
local function isHost()
	return isAuthorityFor(localStripId())
end

--== sending =================================================================
-- One enveloped event. `to` is "all", "host", or a list of player ids; the server
-- routes it without interpreting the payload.
--
-- A message for the strip's leader also carries the strip we are at, on the envelope and
-- never in the game's data. Some of the game's messages name no strip or race (the
-- finish time carries only its time), and with several strips busy the server could not
-- tell whose leader should get them.
local function send(msgName, to, data)
	if type(TriggerServerEvent) ~= "function" then
		log("E", logTag, "TriggerServerEvent unavailable - BeamMP not loaded")
		return
	end
	local envelope = { msg = msgName, to = to, data = data }
	if to == "host" then
		local stripId = localStripId()
		if type(stripId) == "string" then envelope.stripId = stripId end
	end
	TriggerServerEvent("dragMP", jsonEncode(envelope))
end

M.send = send
M.sendToHost = function(msgName, data) send(msgName, "host", data) end
M.sendToAll = function(msgName, data) send(msgName, "all", data) end

--== bridge ==================================================================
-- The object mpDragHandlers is called with. Every function here is one the shipped
-- handlers call; nothing is speculative.
local bridge = {}

-- BeamMP identifies players by a numeric server id, and the drag protocol distinguishes
-- "client id" from "player id". With BeamMP there is exactly one client per player, so
-- the two are the same number and the mapping functions are identities. Keeping them
-- separate anyway, because the handlers do.
function bridge.getLocalClientId()
	return getLocalPlayerId()
end

function bridge.getLocalPlayerId()
	return getLocalPlayerId()
end

-- The name the game's session handler asks since 0.40.4.0 (mpDragHandlers.lua:31) before it
-- records this player's run; unanswered, the run is never recorded as ours.
bridge.getLocalMPPlayerId = bridge.getLocalPlayerId

function bridge.getPlayerIdByClientId(clientId)
	return clientId
end

--- The shipped handlers use this to mean "am I the authority for this race". Scoped to
--- the strip we are at, so a bystander never claims it.
function bridge.isSessionHost()
	return isHost()
end

function bridge.getRaceState(raceId)
	if not gameplay_drag_core or not gameplay_drag_core.getRaceState then return nil end
	return gameplay_drag_core.getRaceState(raceId)
end

-- persona is the display name the UI shows for each racer (dragBridge.lua builds
-- racersList and waitingList from it), so it maps to the BeamMP nickname.
function bridge.getSessionPlayers()
	local players = {}
	if not MPVehicleGE or not MPVehicleGE.getPlayers then return players end
	for _, playerData in pairs(MPVehicleGE.getPlayers() or {}) do
		local id = playerData.playerID
		if id then
			players[id] = { persona = playerData.name or ("Player " .. tostring(id)) }
		end
	end
	return players
end

-- Who should receive timer and light updates for a race: everyone taking part in it.
-- Falls back to the whole session if the race has no player list yet, so early
-- messages are not silently dropped.
function bridge.getTimerRecipientClientIds(raceId)
	local ids = {}
	local raceState = bridge.getRaceState(raceId)
	if raceState and raceState.players and next(raceState.players) then
		for playerId in pairs(raceState.players) do
			ids[playerId] = true
		end
		return ids
	end
	for playerId in pairs(bridge.getSessionPlayers()) do
		ids[playerId] = true
	end
	return ids
end

function bridge.sendToClientIds(clientIds, msgName, data)
	if not clientIds then return end
	local list = {}
	for id, wanted in pairs(clientIds) do
		if wanted then table.insert(list, id) end
	end
	if #list == 0 then return end
	send(msgName, list, data)
end

--- mpDragHandlers.lua:35 calls this as
---     bridge.setLocalClientActiveRace(raceId, r.poiData, pd.lane or 1, r.treeType)
--- -- four arguments, the first a raceId STRING, not a race table. Taking one parameter
--- meant state.localClientActiveRace became the id string.
---
--- This never fired before, because players[localPlayerId] missed on the JSON-stringified
--- key and the handler skipped the call entirely. Fixing the wire shape unmasks it, so
--- the two changes have to land together.
function bridge.setLocalClientActiveRace(raceId, poiData, lane, treeType)
	state.localClientActiveRace = {
		id = raceId,
		poiData = poiData,
		lane = lane,
		treeType = treeType,
	}
end

function bridge.clearLocalClientActiveRace()
	state.localClientActiveRace = nil
end

M.bridge = bridge
M.getState = function() return state end
M.isHost = isHost
M.isAuthorityFor = isAuthorityFor
M.getAuthorityFor = function(stripId) return authorityByStrip[stripId] end
M.getLocalClientActiveRace = function() return state.localClientActiveRace end

--== receiving ===============================================================

--- Fills in the strip definition a message deliberately did not carry.
---
--- handleDragSessionStarted does setDragRaceData(r.poiData), and if that is nil then
--- core.onDragRaceStarted gives up with "dragData is nil after setDragRaceData" and no
--- racers are ever registered -- a silent, total failure.
---
--- The definition is ~15 KB and cannot be sent (BeamMP's transport truncates it and the
--- server rejects the whole message), so the sender includes only poiKey and every
--- receiver looks the strip up on its own disk. Applied here so the remote path and the
--- host's own local-apply path both get it.
local function hydrateStripData(race, lobbyId)
	if not race or race.poiData then return end

	local key = race.poiKey or lobbyId
	if not key then return end

	local lobby = mileage_dragLobby
	local stripData = lobby and lobby.resolveStripData and lobby.resolveStripData(key)
	if stripData then
		-- A COPY. Assigning the cached table by reference is what caused the wheel-maths
		-- crash on the second client.
		--
		-- resolveStripData returns entries of BeamNG's process-lifetime levelDragStrips
		-- cache verbatim (dragLobby.lua:139), and core.setupRacerMpStub writes every remote
		-- stub it builds into getLocalClientActiveRace().poiData.racers (core.lua:237-241).
		-- With poiData aliasing the cache, those stubs were written into the level's own
		-- strip definition and outlived the race -- so the next race's
		-- setDragRaceData(deepcopy(poiData)) installed a racers table pre-populated with
		-- stale stubs, and setDragRaceData deliberately does not clear it (core.lua:461).
		-- display.getPlayableRacer then falls back to the first isPlayable racer
		-- (display.lua:798), stubs are playable, and phaseHandlers.lua:58 does
		-- pairs(racer.wheelsCenter) on something that has never had wheels.
		--
		-- BeamNG's own path always hands it a copy (mpDragHandlers.lua:29, core.lua:1095),
		-- and poi.lua:75 spells the rule out: "Work on a local copy so the cached level
		-- data is never mutated by user rules." Stubs now land in a per-race copy that dies
		-- with the race.
		race.poiData = deepcopy(stripData)
	else
		log("E", logTag, "cannot resolve strip '" .. tostring(key) ..
			"' locally - the race will not start on this client")
	end
end

--- The lobby sends `players` as a dense array of records; rebuild the id-keyed map that
--- gameplay/drag reads (mpDragHandlers.lua:33, core.lua:1114, dragBridge.lua:660).
---
--- Ids are coerced with tonumber because they have made a round trip through JSON object
--- keys before now, and a string "1" does not match the number 1 that
--- MPConfig.getPlayerServerID() returns. One coercion here covers every consumer.
local function normalizePlayers(list)
	if type(list) ~= "table" then return nil end
	local out, found = {}, false
	for _, rec in pairs(list) do
		if type(rec) == "table" and rec.playerId ~= nil then
			out[tonumber(rec.playerId) or rec.playerId] = {
				vehicleId = tonumber(rec.vehicleId) or rec.vehicleId,
				lane = tonumber(rec.lane) or rec.lane,
				persona = rec.persona,
			}
			found = true
		end
	end
	return found and out or nil
end

--- Same, for the heat queue: array of { lane, playerId } back into lane-keyed slots, the
--- shape core.lua:1113 indexes as slot[lane].
local function normalizeQueue(list)
	if type(list) ~= "table" then return nil end
	local out, found = {}, false
	for i, heat in ipairs(list) do
		local slot = {}
		if type(heat) == "table" then
			for _, pair in pairs(heat) do
				if type(pair) == "table" and pair.lane ~= nil and pair.playerId ~= nil then
					slot[tonumber(pair.lane) or pair.lane] = tonumber(pair.playerId) or pair.playerId
					found = true
				end
			end
		end
		out[i] = slot
	end
	return found and out or nil
end

--- Turn a payload as sent into a payload as the shipped handlers expect.
---
--- Applied on the receive path AND on the authority's own local apply, so both walk the
--- identical code path. Mutates in place; the send always happens before the local apply,
--- so the wire never sees the rebuilt form.
function M.normalizeIncoming(msgName, data)
	if not data then return end

	if msgName == "dragSessionStarted" then
		local race = data.race
		if not race then return end
		race.players = normalizePlayers(race.players) or race.players
		race.queue = normalizeQueue(race.queue) or race.queue
		hydrateStripData(race, data.lobbyId)

	elseif msgName == "dragRacePlayerJoined" or msgName == "dragRaceReset" then
		data.players = normalizePlayers(data.players) or data.players
		data.queue = normalizeQueue(data.queue) or data.queue
	end
end

--- The namespace of our own lobby messages (mileageDragJoin, mileageClockPong, ...).
local LOBBY_PREFIX = "mileage"

local function onDragMessage(payload)
	local envelope = jsonDecode(payload)
	if not envelope or not envelope.msg then return end

	-- Our own lobby messages share this relay rather than adding a second event pair.
	-- They are namespaced so they can never collide with a BeamNG protocol message, now
	-- or after a game update.
	-- Measured from the prefix itself: a hard-coded length outlived a rename once and sent
	-- every lobby message to the game's handlers, so no race ever formed.
	if type(envelope.msg) == "string" and envelope.msg:sub(1, #LOBBY_PREFIX) == LOBBY_PREFIX then
		extensions.hook("onMileageDragMessage", envelope.msg,
			tonumber(envelope.from) or envelope.from, envelope.data)
		return
	end

	local handlers = gameplay_drag_mpDragHandlers
	if not handlers or not handlers.handle then
		log("E", logTag, "gameplay_drag_mpDragHandlers unavailable - cannot dispatch " ..
			tostring(envelope.msg))
		return
	end

	M.normalizeIncoming(envelope.msg, envelope.data)

	-- The handlers identify the sender through `client.id`, and attribute finish times
	-- by it. The server stamps `from`, so a client cannot claim to be someone else.
	-- Coerced to a number: it is compared against MPConfig.getPlayerServerID() and used as
	-- a table key, and a string id silently matches nothing.
	local from = tonumber(envelope.from) or envelope.from
	local client = { id = from }

	local ok, err = pcall(handlers.handle,
		envelope.msg, state, bridge, client, from, nil, envelope.data)
	if not ok then
		log("E", logTag, string.format("handler for %s failed: %s", tostring(envelope.msg), tostring(err)))
	end
end

local function onDragAuthority(payload)
	local data = jsonDecode(payload)
	if not data or not data.stripId then return end
	local previous = authorityByStrip[data.stripId]
	data.playerId = tonumber(data.playerId) or data.playerId
	authorityByStrip[data.stripId] = data.playerId
	if previous ~= data.playerId then
		log("I", logTag, string.format("drag authority for '%s' is now player %s (we are %s)",
			data.stripId, tostring(data.playerId),
			isAuthorityFor(data.stripId) and "AUTHORITY" or "a participant"))
		extensions.hook("onMileageDragAuthorityChanged", data.stripId, data.playerId,
			isAuthorityFor(data.stripId))
	end
end

--== lifecycle ===============================================================

function M.reset()
	state.dragRaces = {}
	state.localClientActiveRace = nil
end

-- Nothing in the game loads gameplay_drag_mpDragHandlers: no module declares it as a
-- dependency and no code requires it, so it sits on disk unused. It is the entire
-- receive half of the protocol, so loading it is step one.
local function ensureHandlersLoaded()
	if gameplay_drag_mpDragHandlers then return true end
	extensions.load("gameplay/drag/mpDragHandlers")
	if gameplay_drag_mpDragHandlers then
		log("I", logTag, "loaded gameplay_drag_mpDragHandlers (unused by the base game)")
		return true
	end
	log("E", logTag, "could not load gameplay/drag/mpDragHandlers - drag sync will not work")
	return false
end

M.ensureHandlersLoaded = ensureHandlersLoaded

local function onExtensionLoaded()
	if type(AddEventHandler) ~= "function" then
		log("E", logTag, "AddEventHandler unavailable - BeamMP not loaded")
		return
	end
	ensureHandlersLoaded()
	AddEventHandler("rxDragMP", onDragMessage)
	AddEventHandler("rxDragAuthority", onDragAuthority)
	-- Ask who holds each strip; we may have joined after the last election.
	if type(TriggerServerEvent) == "function" then
		TriggerServerEvent("dragAuthorityRequest", jsonEncode({}))
	end
	log("I", logTag, "Mileage drag transport LOADED")
end

local function onExtensionUnloaded()
	M.reset()
	log("I", logTag, "Mileage drag transport UNLOADED")
end

local function onBeamMPServerLeave()
	authorityByStrip = {}
	M.reset()
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onBeamMPServerLeave = onBeamMPServerLeave

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
