--Mileage :: multiplayer_synclib
--
-- Cross-machine clock mapping. Without this, multiplayer drag finish times are
-- meaningless -- not imprecise, meaningless.
--
-- gameplay/drag/phaseHandlers.lua sends a finish as `rawTime = os.clockhp()`, and the
-- host computes `elapsed = finishTime - hostStart`. os.clockhp() is process-relative:
-- the engine uses it as `t0 = os.clockhp() ... dt = os.clockhp() - t0` for measuring
-- intervals inside one process. Two machines' values are unrelated -- someone an hour
-- into their session reads ~3600 while a fresh joiner reads ~120 -- so subtracting one
-- from the other yields the difference in process uptimes, not an elapsed time.
--
-- BeamNG anticipated this: mpDragHandlers.lua calls
-- multiplayer_synclib.mapOtherClock(clientId, rawTime) and, when the extension is
-- missing, logs "using raw time" and carries on. That fallback avoids a nil error; it
-- does not produce a usable number. This file is the missing extension.
--
-- Two mechanisms, in order of preference:
--
--   1. Race anchor. The drag handlers already record, for every client, the host's
--      clock at race start (syncRaceStart) alongside our own clock at the moment we
--      received it (localRaceStart). That pairing converts between the two clocks with
--      no extra traffic. Error is one-way latency of the start broadcast.
--
--   2. Offset probe. A few round trips against the same peer, keeping the sample with
--      the lowest round-trip time, which is the one least distorted by queueing. This
--      is what removes the host's inherent accuracy advantage: without it, the host's
--      own times need no correction while everyone else's carry latency error, which on
--      a close run can decide the wrong winner.
--
-- Probing refines the anchor rather than replacing it, so a race can start before any
-- probe has completed.

local M = {}

local logTag = "mileage.synclib"

-- clientId -> { offset, rtt, samples, updatedAt }
-- offset is added to a remote timestamp to express it in our clock.
local offsets = {}

local PROBE_INTERVAL = 10      -- seconds between probes to a given peer
local MAX_SAMPLE_AGE = 120     -- drop stale estimates entirely
local PENDING_MAX_AGE = 30     -- forget a probe whose answer has not come in this long

local pendingProbes = {}
local lastProbeAt = {}

local function transport()
	return mileage_dragTransport
end

local function now()
	return os.clockhp()
end

--== offset estimation ========================================================

-- updatedAt is when the stored sample was taken, so an estimate's age is its sample's age:
-- a later, worse sample is counted but does not make an old estimate look fresh.
local function recordSample(clientId, offset, rtt)
	local entry = offsets[clientId]
	-- Keep the lowest-RTT sample rather than an average: a delayed packet can only ever
	-- inflate the apparent offset, never reduce it, so the minimum is the closest estimate
	-- of the true difference. Once the kept sample is too old to be used, the next one
	-- replaces it even if its round trip is longer, so a long session keeps an estimate.
	if not entry or rtt < (entry.rtt or math.huge) or now() - entry.updatedAt > MAX_SAMPLE_AGE then
		offsets[clientId] = { offset = offset, rtt = rtt, samples = ((entry and entry.samples) or 0) + 1, updatedAt = now() }
		return true
	end
	entry.samples = (entry.samples or 0) + 1
	return false
end

--- Standard round-trip estimate: with t0/t3 on our clock and t1 on theirs,
--- offset = t1 - (t0 + t3) / 2.
local function completeProbe(clientId, t0, t1, t3)
	local rtt = t3 - t0
	if rtt < 0 then return end
	local offset = t1 - (t0 + rtt / 2)
	local improved = recordSample(clientId, offset, rtt)
	if improved then
		log("D", logTag, string.format("clock offset to client %s: %.4fs (rtt %.0fms)",
			tostring(clientId), offset, rtt * 1000))
	end
end

--- Fire a probe at a peer, if one is not already outstanding and it is due.
function M.probe(clientId)
	if clientId == nil then return end
	local t = transport()
	if not t then return end

	-- A peer never probed is due at once, whatever the clock reads.
	local last = lastProbeAt[clientId]
	if last and (now() - last) < PROBE_INTERVAL then return end
	lastProbeAt[clientId] = now()

	-- A probe whose answer never came would otherwise stay until the player left the
	-- server. Its late answer, if it ever arrives, is then ignored like any unknown token.
	for pendingToken, pending in pairs(pendingProbes) do
		if now() - pending.t0 > PENDING_MAX_AGE then pendingProbes[pendingToken] = nil end
	end

	local token = tostring(clientId) .. "-" .. tostring(math.floor(now() * 1000))
	pendingProbes[token] = { clientId = clientId, t0 = now() }
	t.send("mileageClockPing", { clientId }, { token = token })
end

--- Message hook, routed here by the transport (mileage* namespace).
function M.onMileageDragMessage(msgName, fromClientId, data)
	local t = transport()
	if not t or not data then return end

	if msgName == "mileageClockPing" then
		-- Answer with our own clock reading.
		t.send("mileageClockPong", { fromClientId }, { token = data.token, t1 = now() })

	elseif msgName == "mileageClockPong" then
		local probe = pendingProbes[data.token]
		if not probe then return end
		pendingProbes[data.token] = nil
		completeProbe(probe.clientId, probe.t0, data.t1, now())
	end
end

--== the interface BeamNG calls ===============================================

--- Convert a timestamp taken on another client's clock into ours.
---
--- Called by gameplay/drag/mpDragHandlers.lua when the host receives a finish time.
--- Returns nil if we have no basis for the conversion, which the caller treats as
--- "fall back to raw" -- better to be visibly wrong than silently precise.
function M.mapOtherClock(clientId, remoteTime)
	if not clientId or not remoteTime then return nil end

	local entry = offsets[clientId]
	if entry and (now() - entry.updatedAt) <= MAX_SAMPLE_AGE then
		return remoteTime - entry.offset
	end

	-- No probe yet: fall back to the race anchor, which needs no extra traffic.
	local gm = multiplayer_gamemodes_drag_drag
	if gm and gm.getRaceEntry then
		local raceEntry = gm.getRaceEntry()
		if raceEntry and raceEntry.syncRaceStart and raceEntry.localRaceStart then
			-- Their clock at race start is unknown, but the host's is, and every client
			-- recorded its own clock at the same broadcast. Expressing their finish
			-- relative to that shared instant is accurate to one-way latency.
			local sinceStartOnTheirClock = remoteTime - raceEntry.syncRaceStart
			return raceEntry.localRaceStart + sinceStartOnTheirClock
		end
	end

	return nil
end

--- How good the estimate for a peer currently is, for diagnostics.
function M.getOffsetInfo(clientId)
	local entry = offsets[clientId]
	if not entry then return nil end
	return { offset = entry.offset, rtt = entry.rtt, samples = entry.samples,
		age = now() - entry.updatedAt }
end

--== lifecycle ================================================================

--- Keep offsets fresh for the players at the strips this machine leads, so a finish
--- time is always mapped through a recent probe. Only a strip's leader maps finish times,
--- so a machine that leads no strip probes nobody (it still answers probes it receives).
--- The lobby probes a player the moment they arrive; this keeps it fresh while they stay.
local function onUpdate()
	local gm = multiplayer_gamemodes_drag_drag
	if not gm or not gm.isEnabled() then return end

	local lobby = mileage_dragLobby
	if not lobby or not lobby.clockCheckTargets then return end

	for playerId in pairs(lobby.clockCheckTargets()) do M.probe(playerId) end
end

function M.reset()
	offsets = {}
	pendingProbes = {}
	lastProbeAt = {}
end

local function onExtensionLoaded()
	log("I", logTag, "Mileage synclib LOADED (clock mapping for multiplayer drag)")
end

local function onBeamMPServerLeave()
	M.reset()
end

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onBeamMPServerLeave = onBeamMPServerLeave

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
