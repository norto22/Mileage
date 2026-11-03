--Mileage :: drag multiplayer gamemode
--
-- gameplay/drag/core.lua looks for an extension at multiplayer/gamemodes/drag/drag --
-- this file -- and every multiplayer path inside gameplay/drag/ is gated behind it
-- being present:
--
--     local function getDragGamemode()
--       -- Restore the two lines below once multiplayer drag is ready to ship.
--       -- local ext = _G[DRAG_MP_GAMEMODE_EXT]
--       ...
--       return nil
--     end
--
-- mileage/dragSync.lua un-stubs that getter and points it here.
--
-- The important thing: this is a *network adapter*, not a race implementation. BeamNG's
-- drag code already calls these methods at exactly the right moments -- when a car
-- stages, when the tree goes green, when a timer resolves -- so the job is to turn those
-- calls into protocol messages, and to answer state queries from what the protocol has
-- delivered.
--
-- Mapping (call sites verified against the 0.39 source):
--
--   syncStageLightState      display.lua:1261,1297 -> dragRaceTreeLightUpdate    (host)
--   syncTreeLightState       display.lua:251,254   -> dragRaceTreeLightUpdate    (host)
--   notifyRaceStart          display.lua:662       -> dragRaceStart              (all)
--   updateTimerValue         times.lua:131         -> dragRaceTimerUpdateRequest (host)
--   broadcastRulesUpdate     dragBridge.lua:510    -> dragRaceRulesUpdate        (all)
--   getSynchronizedRandValue display.lua:674       <- host's randValue

local M = {}

local logTag = "mileage.drag"

-- Set by mileage/dragSync once the server has enabled native drag sync.
local enabled = false

-- Menu/context bookkeeping the game asks about but does not drive itself.
local menuOpen = false
local context = nil

--- The race we have already announced a start for; see M.notifyRaceStart.
local raceStartSentFor = nil

--- Whether a timeslip has been requested for the current heat; see M.onDragMpTimeslipRequested.
local timeslipPending = false

--- Whether the result screen for the current race has been produced.
---
--- Mod state on purpose. Every field the game offers for "this race is over" is unusable
--- here: onDragRaceReset sets data.isCompleted back to false (core.lua:1181) and nothing
--- can set it true again, and allRacersFinished is structurally false in MP because the
--- remote stub is created with isFinished = false (core.lua:227) and headsUpRace.onUpdate
--- skips remote racers (headsUpRace.lua:76) before any phase function could set it.
--- Keeping the flag here means core.onDragRaceReset cannot reach it.
local raceFinalized = false

--- When that happened, so the race can wind itself up once the result has been read.
local finalizedAt = nil

--- When a racer was disqualified without finishing, which arms the void backstop.
---
--- A false start never produces a finish: setRacerDisqualification sets four DQ flags and
--- nothing else (phaseHandlers.lua:155), the car never crosses the line, so
--- core.sendTimeslipDataToUi is never called and onDragMpTimeslipRequested never fires.
--- timeslipPending therefore stays false and tryFinalizeRace returns on its very first
--- line -- taking the DQ_GRACE shortcut below with it, which was written for exactly this
--- case but sits underneath that gate. Nothing then arms the finalise, tearDownRaceUI is
--- never reached, and the drag UI stays up for the rest of the session.
local dqAt = nil

--- When our own car stopped and the game first asked for a result.
---
--- Needed because "every car is in" is not answerable on a participant. Only the strip's
--- authority collects finish times, so only its copy of the opponent ever becomes
--- isFinished; on every other client the opponent is a stub that stays unfinished for
--- ever, and data.isCompleted is not set there either. The 01/08 18:27 logs show it
--- plainly -- the desktop logged "race finalised" at 253.33 and the laptop logged no such
--- line at all, so its race never ended.
---
--- So the real test is raceState.finishTimes, which IS populated on both sides -- the
--- authority fills it in handleDragRaceFinishTime as each player reports, and participants
--- get the same entries via handleDragRaceFinishTimeBroadcast. The grace period below is
--- only a backstop for an opponent who never reports at all (disconnect, crash, DNF).
local timeslipRequestedAt = nil
--- How many times we will try to restart a racer's tree before giving up on it.
---
--- The repair below had no bound at all, and a false start put racer -2 into a state it
--- could not fix: the 01/08 log has "tree never started for racer -2 - re-issuing the
--- countdown" repeated about two hundred times a second for the rest of the session, ten
--- thousand lines of it, with the race frozen behind it. A repair that cannot succeed has
--- to give up rather than spin.
local MAX_TREE_REPAIRS = 3
local treeRepairs = {}

-- Backstop only: how long to wait for a finish time that may never arrive.
--
-- Was 5 s, which was short enough to fire while the other car was still on the strip and
-- produce a slip with the opponent's 1/4 mile blank.
local FINALIZE_GRACE = 30
-- Shorter, for a run somebody already spoiled with a false start.
local DQ_GRACE = 8
-- For a DQ where NOBODY ever stops, so there is no "car stopped" event to count from.
--
-- Measured from the disqualification, which happens at or before the green, so it has to
-- outlast a whole pass: the clean race in the 01/08 log took about 25 s from countdown to
-- finalise. Long enough that a real race is never cut short, short enough that a spoiled
-- one does not strand the strip.
local DQ_VOID = 45

local function transport()
	return mileage_dragTransport
end

--- The two functions the game calls every frame of a race -- onUpdate and checkTimerDrift,
--- the latter from inside the game's own drag timer -- catch their own errors. The game's
--- frame loop has no protection, so an error escaping either one would end that frame's
--- updates for the drag timer and everything after it. The first failure of each is
--- logged with its traceback; repeats are not logged every frame.
local traceback = (type(debug) == "table" and type(debug.traceback) == "function") and debug.traceback
	or function(msg) return msg end

local frameErrorLogged = {}

local function frameErrorHandler(name)
	return function(err)
		if not frameErrorLogged[name] then
			frameErrorLogged[name] = true
			log("E", logTag, string.format("%s failed and returned quietly; later failures are not logged: %s",
				name, tostring(traceback(tostring(err), 2))))
		end
		return err
	end
end

local onFinalizeError = frameErrorHandler("multiplayer_gamemodes_drag_drag.onUpdate")
local onTimerDriftError = frameErrorHandler("multiplayer_gamemodes_drag_drag.checkTimerDrift")

local function core()
	return gameplay_drag_core
end

--== identity / session ======================================================

--- Is a career mission running in the foreground?
---
--- A drag mission -- the BMRA events, racing an AI bot -- is a SINGLE-player race that
--- happens to take place on the same strip. Its whole flow is the singleplayer one: the
--- mission spawns the opponent, poi.lua takes its non-MP branch, and gameplay/drag runs
--- the local paths. Reporting multiplayer during one hands those races to code that is
--- expecting network racers, and separately lets our lobby claim the strip out from under
--- the mission -- which is exactly what happened: the mission set up its race at 317.7 and
--- our lobby logged "alone at strip - starting a solo run" at 367.5 on top of it.
---
--- getForegroundMissionId is the game's own test for this; phaseHandlers.lua:902 and :910
--- use it to decide whether the mission owns the result screen.
---
--- Only a DRAG mission owns the strip (#22): a time trial or any other mission driven past
--- a strip leaves multiplayer drag on. The mission's type names it, as BeamNG's "Drag Race"
--- type does, and is read the way parkingChallenge.lua spots parking missions. A mission
--- whose type cannot be read still owns the strip, as every mission did before.
local loggedMissionId = nil

local function isDragMission(id)
	local list = gameplay_missions_missions
	if not list or type(list.getMissionById) ~= "function" then return true end
	local ok, mission = pcall(list.getMissionById, id)
	if not ok or type(mission) ~= "table" or type(mission.missionType) ~= "string" then return true end
	local drag = string.find(string.lower(mission.missionType), "drag", 1, true) ~= nil
	if loggedMissionId ~= id then
		loggedMissionId = id
		log("I", logTag, string.format("foreground mission %s: type=%s drag=%s",
			tostring(id), mission.missionType, tostring(drag)))
	end
	return drag
end

local function inForegroundMission()
	local mm = gameplay_missions_missionManager
	if not mm or type(mm.getForegroundMissionId) ~= "function" then return false end
	local ok, id = pcall(mm.getForegroundMissionId)
	if not ok or id == nil or id == false then return false end
	return isDragMission(id)
end

--- Is the career performance test running?
---
--- The performance index is a drag race in disguise. career/modules/vehiclePerformance.lua
--- loads alderStrip's own settings file (:182), sets the racers, and calls
--- startDragRaceActivity (:211) -- so with drag sync on, our layer treated the player's
--- certification run as a multiplayer race and put the head-to-head UI over it.
---
--- The strip data cannot tell the two apart: the performance test loads the very same
--- alderStrip.dragSettings.json that our races resolve, so data.context is identical
--- either way. vehiclePerformance's own flag is the discriminator, and it is exported
--- (:634), set at :119 and cleared on both exit paths (:414, :434).
local function inPerformanceTest()
	local vp = career_modules_vehiclePerformance
	if not vp or type(vp.isTestInProgress) ~= "function" then return false end
	local ok, running = pcall(vp.isTestInProgress)
	return ok and running ~= nil and running ~= false
end

--- Any single-player drag activity that happens to use a strip we also race on.
local function inSoloDragActivity()
	return inForegroundMission() or inPerformanceTest()
end

M.inSoloDragActivity = inSoloDragActivity
M.inForegroundMission = inForegroundMission
M.inPerformanceTest = inPerformanceTest

function M.isMultiplayer()
	return enabled and not inSoloDragActivity()
end

--- "Host" here means the authority for the strip we are standing at, not a session-wide
--- host. Every caller in gameplay/drag (core.lua:953, :1028, :1260, display.lua:914 and
--- both dragTypes) asks it to decide who computes results for the race in progress, and
--- that is the strip's authority by construction.
function M.isServerHost()
	local t = transport()
	return enabled and t ~= nil and t.isHost()
end

function M.getLocalPlayerId()
	local t = transport()
	return t and t.bridge.getLocalPlayerId() or nil
end

--- The same answer under the name the game asks since 0.40.4.0 (core.lua:1198 and :1224).
--- Unanswered, the race start keeps this player's own car as a stand-in for someone on
--- another machine, which can never stage, so the lights never count down. The old name
--- stays for anything that still asks it.
M.getLocalMPPlayerId = M.getLocalPlayerId

function M.getPlayerIdByClientId(clientId)
	local t = transport()
	return t and t.bridge.getPlayerIdByClientId(clientId) or clientId
end

--- Despite the name, this means "are we in a multiplayer drag session", not "are we the
--- host". BeamNG's own code makes that clear: times.lua:141 assigns it to a local called
--- `isMP`, and display.lua:266's guard is commented "in MP, only allow UI updates for
--- the local racer's vehicle".
---
--- It matters. poi.lua:65 uses it to decide whether entering a lane starts a local race
--- or defers to the session; if only the host answered true, every other player driving
--- onto the strip would kick off their own private singleplayer race. And clients are
--- *supposed* to report their own lane's lights -- the host-only enforcement lives on the
--- receiving end, where handleDragRaceTreeLightUpdate rejects anything sent to a
--- non-host.
function M.shouldSyncState()
	return enabled and not inSoloDragActivity()
end

--== race state ==============================================================
-- gameplay_drag_core owns the state; the protocol handlers write into it via
-- setRaceState. Reading it back through core keeps one source of truth.

function M.getRaceState(raceId)
	local c = core()
	if not c or not c.getRaceState then return nil end
	return c.getRaceState(raceId)
end

--- The live race state, not the stub we were handed when the race was announced.
---
--- setLocalClientActiveRace only carries id/poiData/lane/treeType. Returning that
--- directly would satisfy the `if active then` test and thereby suppress the
--- getRaceState() fallback, starving every consumer that needs the parts it does not
--- carry -- players, timerValues and finishTimes, read by dragBridge.lua:17,
--- times.lua:57, timeslip.lua:85, display.lua:174 and core.lua:1525.
function M.getActiveDragRace()
	local t = transport()
	local active = t and t.getLocalClientActiveRace()
	if not active then return M.getRaceState() end

	local raceState = active.id and M.getRaceState(active.id)
	if not raceState then return active end

	-- Fill in only what the state store does not already know.
	if raceState.lane == nil then raceState.lane = active.lane end
	if raceState.treeType == nil then raceState.treeType = active.treeType end
	return raceState
end

function M.getLocalClientActiveRace()
	local t = transport()
	return t and t.getLocalClientActiveRace() or nil
end

function M.clearLocalClientActiveRace()
	local t = transport()
	if t then t.bridge.clearLocalClientActiveRace() end
end

--- Per-race bookkeeping the handlers maintain: the host's clock values for countdown
--- and race start, plus our own clock at the moment we received them. That pairing is
--- what makes cross-machine timing possible at all -- see the clock notes in the docs.
local function raceEntry(raceId)
	local t = transport()
	if not t then return nil end
	local s = t.getState()
	if not s or not s.dragRaces then return nil end
	if raceId then return s.dragRaces[raceId] end
	local active = M.getActiveDragRace()
	return (active and active.id) and s.dragRaces[active.id] or nil
end

M.getRaceEntry = raceEntry

--- Both of these are compared against a local os.clockhp() by the caller, so they have to
--- be in the CALLER's clock frame.
---
--- os.clockhp() is process-relative: two machines' values are unrelated numbers. The host
--- stamps syncRaceStart from its own clock, and times.lua:183 then computes
--- `os.clockhp() - raceStartTime` on the receiving client -- mixing two processes'
--- uptimes. Measured offsets on this pair of machines were +33.5 s, +135.0 s and -59.6 s
--- across three sessions, so client timers read tens of seconds high; and when the offset
--- is negative the elapsed time goes negative, math.max(0, ...) pins it to zero, and the
--- reaction timer resolves under 0.0005 -- an automatic red-light disqualification for the
--- non-host on every single run.
---
--- mpDragHandlers records localRaceStart/localCountdownStart (os.clockhp() at the moment
--- the message arrived) alongside the host's value precisely for this. The host keeps its
--- own raw stamp, because handleDragRaceFinishTime reads syncRaceStart there to work out
--- elapsed times for everybody.
function M.getRaceStartTime(raceId)
	local entry = raceEntry(raceId)
	if not entry then return nil end
	if M.isServerHost() then return entry.syncRaceStart end
	return entry.localRaceStart or entry.syncRaceStart
end

function M.getCountdownStartTime(raceId)
	local entry = raceEntry(raceId)
	if not entry then return nil end
	if M.isServerHost() then return entry.syncCountdownStart end
	return entry.localCountdownStart or entry.syncCountdownStart
end

--- The tree's amber delay is randomised. Every client has to use the *same* value or
--- the lights diverge, so the host picks it and ships it with the countdown;
--- display.lua reads it here in place of its own rand.
function M.getSynchronizedRandValue()
	local entry = raceEntry()
	return entry and entry.syncRandValue or nil
end

--== outbound ================================================================

local function send(msgName, to, data)
	local t = transport()
	if not t then
		log("E", logTag, "transport unavailable - dropping " .. tostring(msgName))
		return
	end
	t.send(msgName, to, data)
end

--- The players at a race's strip (except us), as the lobby's own race messages use, so a
--- player elsewhere on the server never gets a race they are not in. Without the lobby
--- there is no way to tell, so the message goes to everyone, as it used to, and that is
--- logged once.
local warnedNoLobby = false
local function raceRecipients(raceId)
	local lobby = mileage_dragLobby
	if not (lobby and lobby.recipientsFor and lobby.stripIdForRace) then
		if not warnedNoLobby then
			warnedNoLobby = true
			log("W", logTag, "drag lobby not loaded - race start and rules go to every player")
		end
		return "all"
	end
	return lobby.recipientsFor(lobby.stripIdForRace(raceId))
end

-- Sends to the race's players; nothing goes out when nobody else is at the strip.
local function sendToRace(msgName, raceId, data)
	local to = raceRecipients(raceId)
	if to ~= "all" and #to == 0 then return end
	send(msgName, to, data)
end

local function activeRaceId(raceId)
	if raceId then return raceId end
	local active = M.getActiveDragRace()
	return active and active.id or nil
end

--- May our own lights, timers and race start go to other players? Not while a drag
--- mission or the performance test owns the strip (#21). The game's callers check for a
--- multiplayer race first today; this keeps the senders quiet if a game update changes one.
local function sendersOn()
	return enabled and not inSoloDragActivity()
end

--- Our own car's stage / pre-stage beams changed. Reported to the host, which marks the
--- lane staged (after the same one-second hold single player uses) and re-broadcasts
--- the lights so the other racers see them.
function M.syncStageLightState(raceId, lane, staged)
	if not sendersOn() then return end
	local id = activeRaceId(raceId)
	if not id or not lane then return end
	send("dragRaceTreeLightUpdate", "host", {
		type = "treeLightUpdate",
		raceId = id,
		lane = lane,
		lightState = { stageLights = { stageLight = staged and true or false } },
	})
end

--- Tree light changes (countdown ambers, stage lights) from display.lua.
function M.syncTreeLightState(raceId, lane, lightState)
	if not sendersOn() then return end
	local id = activeRaceId(raceId)
	if not id or not lane or not lightState then return end
	send("dragRaceTreeLightUpdate", "host", {
		type = "treeLightUpdate",
		raceId = id,
		lane = lane,
		lightState = lightState,
	})
end

--- The tree went green. Only the host may declare this: display.lua calls it from
--- whichever client's racer started, so without the gate every client would announce
--- its own start time and they would disagree about when the race began.
function M.notifyRaceStart(raceId)
	if not sendersOn() or not M.isServerHost() then return end
	local id = activeRaceId(raceId)
	if not id then return end

	-- Once per heat, not once per racer.
	--
	-- display.notifyRaceStartIfNeeded latches on racer.raceStartBroadcasted, which is per
	-- racer, and after the staging fix the host owns BOTH trees -- its own car and the
	-- remote stub. They share one countdown start and the same dialOffset, so both cross
	-- the green threshold on the same frame and this would fire twice with two different
	-- os.clockhp() values, the second overwriting entry.syncRaceStart everywhere.
	if raceStartSentFor == id then return end
	raceStartSentFor = id

	local payload = {
		type = "raceStart",
		raceId = id,
		startTime = os.clockhp(),
	}
	sendToRace("dragRaceStart", id, payload)

	-- And apply it to ourselves. The send never includes the sender, so without this
	-- the one client that declared the start is the only one that never records it:
	-- entry.syncRaceStart stays nil, handleDragRaceFinishTime returns early, and the
	-- authority collects no finish times and shows no timeslip.
	if mileage_dragLobby and mileage_dragLobby.applyLocally then
		mileage_dragLobby.applyLocally("dragRaceStart", payload)
	end
end

--- A timer resolved for our car (60ft, 1/8, 1/4, dial...). Each machine times only its
--- own vehicle; the host collects and re-broadcasts so everyone sees one board.
function M.updateTimerValue(raceId, vehId, timerName, value)
	if not sendersOn() then return end
	local id = activeRaceId(raceId)
	if not id or not timerName then return end
	-- A NAME, not the whole vehicle.
	--
	-- veh.partConfig on a career vehicle is the entire config table serialised -- 5834
	-- characters in the logged session. timeslip.lua:156 uses configName verbatim as the
	-- racer's displayName, so the opponent's name on the result panel became ~200 wrapped
	-- lines of Lua table and pushed the actual times out of a 260x800 app. The timeslip was
	-- rendering correctly the whole time; it was unreadable, not missing.
	--
	-- It is also re-broadcast on every timer update (mpDragHandlers.lua:226) and is
	-- dragBridge's persona fallback, so the cap matters as much as the lookup.
	local configName
	local details = vehId and core_vehicles and core_vehicles.getVehicleDetails
		and core_vehicles.getVehicleDetails(vehId)
	if details and details.configs and details.configs.Name then
		configName = tostring(details.configs.Name)
	else
		local veh = vehId and be:getObjectByID(vehId)
		local pc = veh and veh.partConfig
		-- A leading brace means a serialised table rather than a vehicles/... path.
		if type(pc) == "string" and pc:sub(1, 1) ~= "{" then configName = pc end
	end
	if configName and #configName > 64 then configName = configName:sub(1, 64) end
	send("dragRaceTimerUpdateRequest", "host", {
		type = "timerUpdateRequest",
		raceId = id,
		timerName = timerName,
		timerValue = value,
		vehicleId = vehId,
		configName = configName,
	})
end

--- Host changed the strip rules; push them so clients pick them up without restarting.
function M.broadcastRulesUpdate(rules)
	if not enabled or not M.isServerHost() then return end
	local id = activeRaceId(nil)
	if not id or not rules then return end
	sendToRace("dragRaceRulesUpdate", id, {
		type = "rulesUpdate",
		raceId = id,
		dragType = rules.dragType,
		treeType = rules.treeType,
		importantTimerId = rules.importantTimerId,
	})
end

--- A heat ended and the next is being armed. The race id stays the same across heats, so
--- the per-heat guard in notifyRaceStart has to be released here or heat 2 would never be
--- told it had started -- turning a sub-millisecond double-send into a hard stall.
function M.onDragRaceReset(raceId)
	raceStartSentFor = nil
	timeslipPending = false
end

--- Run the post-race finalisation the game leaves to the session layer.
---
--- core.finalizeMpPostRace (core.lua:1302) is the multiplayer equivalent of everything a
--- single-player race does once the cars have stopped: display signs for every racer,
--- phaseHandlers.generateWinData() for the result, then doSendTimeslipDataToUi() for the
--- full slip. It is defined and exported (core.lua:1557) and called by NOTHING in the
--- shipped game -- the same dormant-MP pattern as getDragGamemode.
---
--- Without it the only thing that happened was core.sendTimeslipDataToUi raising
--- onDragMpTimeslipRequested and returning (core.lua:49-56), which nobody handled. My
--- first attempt answered that hook by building a slip by hand; it produced the small
--- notification rather than the real panel, because it skipped the win data and the
--- display signs that make up the rest of the result screen.
---
--- Timing is the other half. phaseHandlers.lua:885 says it outright -- "Win data,
--- timeslip, and history are triggered later by onDragRaceTimerUpdated once ALL network
--- timer values arrive" -- and the hook fires per car as each one stops. Finalising on the
--- first would show a result with the opponent's column empty.
local function tryFinalizeRace()
	if not timeslipPending then return end

	local c = core()
	local data = c and c.getData and c.getData()
	if not data or not data.racers then return end

	-- Everyone in the race has reported a finish time. This is the condition that works on
	-- both the authority and a participant, and it is true only once the LAST car is across.
	local allReported = false
	local race = c.getRaceState and c.getRaceState()
	if race and race.players and next(race.players) then
		local finishTimes = race.finishTimes or {}
		allReported = true
		for playerId in pairs(race.players) do
			if finishTimes[playerId] == nil then
				allReported = false
				break
			end
		end
	end

	-- Every car in the race on this machine finished or was disqualified: nothing more can
	-- arrive, so show the result now. A solo false start is the common case; it used to wait
	-- out the void backstop and then show no result at all.
	local allOut = next(data.racers) ~= nil
	for _, racer in pairs(data.racers) do
		if not (racer.isFinished or racer.isDisqualified or racer.isDesqualified) then
			allOut = false
			break
		end
	end

	local allDone = allReported
		or allOut
		or data.isCompleted
		or (c.allRacersFinished and c.allRacersFinished(data))

	-- A false start disqualifies a racer without finishing it, so it never reports a time
	-- and allReported can never come true. Do not make everyone sit through the full
	-- backstop for a run that is already void.
	local anyDq = false
	for _, racer in pairs(data.racers) do
		if racer.isDisqualified or racer.isDesqualified then
			anyDq = true
			break
		end
	end
	local grace = anyDq and DQ_GRACE or FINALIZE_GRACE

	if not allDone then
		-- Count from whichever happened: a car stopping, or a disqualification. A false
		-- start only ever produces the latter.
		local since = timeslipRequestedAt or dqAt
		if not since then return end
		if not timeslipRequestedAt then grace = DQ_VOID end
		if (os.clockhp() - since) < grace then return end

		-- Nobody finished, so there is no result -- void the run instead of printing a
		-- timeslip full of dashes. timeslipRequestedAt is set the moment ANY car stops
		-- after crossing, so a race where the opponent completed still shows a proper
		-- result and only the disqualified column is blank; this is strictly the case
		-- where the run was abandoned before anyone got to the far end.
		if not timeslipRequestedAt then
			timeslipPending = false
			raceFinalized = true
			finalizedAt = os.clockhp()
			log("I", logTag, "run voided - nobody finished, so no result screen")
			return
		end
		log("I", logTag, "no finish time from every racer after " .. grace ..
			"s - finalising with what has arrived")
	end
	if type(c.finalizeMpPostRace) ~= "function" then
		log("W", logTag, "gameplay_drag_core.finalizeMpPostRace missing - no result screen")
		timeslipPending = false
		return
	end

	timeslipPending = false
	local ok, err = pcall(c.finalizeMpPostRace)
	if not ok then
		log("W", logTag, "finalizeMpPostRace failed: " .. tostring(err))
		return
	end
	raceFinalized = true
	finalizedAt = os.clockhp()
	log("I", logTag, "race finalised - win data and timeslip sent")
end

function M.isRaceFinalized()
	return raceFinalized
end

--- os.clockhp() at the moment the result screen was produced, or nil.
function M.getFinalizedAt()
	return raceFinalized and finalizedAt or nil
end

--- A new race is arming, so the previous result is history.
function M.onDragRaceStarted()
	raceFinalized = false
	timeslipRequestedAt = nil
	dqAt = nil
	treeRepairs = {}
end

--- Raised by core.sendTimeslipDataToUi as each car comes to a stop.
function M.onDragMpTimeslipRequested()
	if not enabled then return end
	timeslipPending = true
	timeslipRequestedAt = timeslipRequestedAt or os.clockhp()
	tryFinalizeRace()
end

--- Raised by phaseHandlers.lua:224 on the frame a racer is disqualified.
---
--- This is the only event a false start generates that we can hear, and arming
--- timeslipPending from it is what lets the race void at all. Without it the run sits in
--- phase 3 for ever: a disqualified car that stops is refused by every exit from race() --
--- checkRacerStuckOrCrashed is skipped for DQ'd racers (phaseHandlers.lua:846) and it owns
--- the only phase.completed for a stopped car, the finish timer never sets, and
--- stationaryTooLong just calls disqualifyRacer again, which is already a no-op.
---
--- Single player recovers from this with checkFreeroamDqReStage ("Reverse to re-stage"),
--- but that bails whenever getDragGamemode() is merely non-nil (phaseHandlers.lua:590)
--- rather than when isMultiplayer() -- so restoring the getter switched it off, even for a
--- solo run at a strip. This replaces it.
function M.setDisqualifiedLights(vehId)
	if not enabled then return end
	if dqAt then return end
	dqAt = os.clockhp()
	timeslipPending = true
	log("I", logTag, string.format(
		"racer %s disqualified - arming the void backstop (%ds)", tostring(vehId), DQ_VOID))
	tryFinalizeRace()
end

--- The other two chances to notice that the last car is in.
function M.onDragRaceTimerUpdated()
	if not enabled then return end
	tryFinalizeRace()
end

function M.onDragRaceFinishTimesUpdated()
	if not enabled then return end
	tryFinalizeRace()
end

--- The grace period above expires on a clock, not on a message, so it has to be polled.
function M.onUpdate()
	if not enabled or not timeslipPending then return end
	xpcall(tryFinalizeRace, onFinalizeError)
end

--- Tear the drag UI down at the end of a race.
---
--- gameplay_drag_dragBridge.reset() clears the race state, the racers, the timeslip and
--- the tree lights, and in single player poi.lua:50-56 calls it when you drive back to the
--- lane after finishing. That branch is explicitly `not isMultiplayer()`, and nothing on
--- the MP path calls it at all -- so the drag app stays on screen with the finished race's
--- times for the rest of the session.
function M.tearDownRaceUI()
	local c = core()
	if not c or not c.clear then return end

	-- clear(), not dragBridge.reset().
	--
	-- They are opposites for the one option that matters here:
	--
	--   core.reset  ->  if opts.treeLightStaging then guihooks.trigger('updateTreeLightStaging', true)  end
	--   core.clear  ->  if opts.treeLightStaging then guihooks.trigger('updateTreeLightStaging', false) end
	--
	-- dragBridge.reset() passes treeLightStaging = true, so using it to end a race switched
	-- the staging lights back ON -- the race "ended" and the tree lit up for a run that was
	-- already over. reset() is for re-arming between heats; clear() is for finishing. clear
	-- also hides the drag app and clears its messages, which reset never did, and empties
	-- raceStateStore so a later getRaceState() cannot resolve a stale race.
	--
	-- extensions is deliberately not set: unloadAllExtensions would take the drag
	-- extensions down with it, and the transport keeps mpDragHandlers loaded by hand.
	local ok, err = pcall(c.clear, {
		hooks = true,
		transitionLock = true,
		localRace = true,
		data = true,
		context = true,
		ui = true,
		treeLightStaging = true,
	})
	if not ok then
		log("W", logTag, "drag clear failed: " .. tostring(err))
		return
	end
	timeslipRequestedAt = nil
	dqAt = nil
	raceFinalized = false
	finalizedAt = nil
	treeRepairs = {}
	-- Forget the run too, so a later light or timer message cannot name a run that is gone.
	M.clearLocalClientActiveRace()
	log("I", logTag, "race over - drag UI reset")
end

function M.onDragRaceListChanged()
	extensions.hook("onMileageDragRaceListChanged")
end

--- Moves every staging racer into the countdown phase. Idempotent.
---
--- This is the work core.lua does for a CLIENT at core.lua:956-968 and, deliberately, for
--- nobody on the host -- `if isMP and not isHost` is false for us and `elseif not isMP` is
--- false too, so onDragRaceCountdownStart advances nothing on the authority.
---
--- WHEN it happens is as important as that it happens, which is what the first attempt at
--- this got wrong. core.lua:976-984 runs an unconditional tail loop straight afterwards:
---
---   extensions.hook("startDragCountdown", racer.vehId, 0)
---   racer.phases[2].started = true
---
--- and display.startDragCountdown (display.lua:1305, the ONLY writer of
--- `racer.treeStarted = true` anywhere in gameplay/drag) discards that call at :1311 if the
--- racer is not already in phase 2. The `started = true` on the next line lands anyway, and
--- phaseHandlers.countdown will not retry because it is gated on `if not phase.started`
--- (:708). So a single frame's ordering permanently blanks the tree: updateRacerCountdown
--- returns at display.lua:893 for ever, the green light never fires startRaceFromTree,
--- phases[2].completed is never set, and no dragRaceStart is ever sent -- which strands the
--- clients too, since display.lua:915 makes them pure receivers of host-generated lights.
---
--- Hence this must run BEFORE the countdown message is applied, not a frame later.
function M.advanceOutOfStaging()
	local c = core()
	local dragData = c and c.getData()
	if not dragData or not dragData.racers or not gameplay_drag_phaseHandlers then
		return false
	end

	local anyInPhase1 = false
	for _, racer in pairs(dragData.racers) do
		if not racer.vehicleRemoved and racer.currentPhase == 1 then
			anyInPhase1 = true
			break
		end
	end
	if not anyInPhase1 then return false end

	for _, racer in pairs(dragData.racers) do
		if not racer.vehicleRemoved and racer.phases and racer.phases[1] then
			racer.phases[1].completed = true
		end
	end
	gameplay_drag_phaseHandlers.changeAllPhases()
	return true
end

--- Per-frame host-side repair, called from times.lua:144.
---
--- Two jobs. It still advances anyone left in staging, which covers the case where the
--- countdown arrives without dragLobby having advanced us first. And it restarts a tree
--- that was lost to the ordering trap above: a racer sitting in phase 2 with
--- phases[2].started set but treeStarted never assigned can only have got there by having
--- its startDragCountdown discarded, and nothing in the base game will try again.
---
--- That second half is not hypothetical. changeAllPhases refuses the 1 -> 2 transition for
--- a non-stub racer that is marginally outside its lane zone (phaseHandlers.lua:307), so
--- if the authority's car is over the line at the instant the countdown fires, only the
--- stub advances and the local racer lands in exactly that state.
local function repairTimerDrift()
	if not M.isServerHost() then return end

	local c = core()
	local dragData = c and c.getData()
	if not dragData or not dragData.racers or not next(dragData.racers) then return end

	local startTime = M.getCountdownStartTime()
	if not startTime or os.clockhp() < startTime then return end

	if M.advanceOutOfStaging() then
		log("I", logTag, "countdown due - advancing racers out of staging (host)")
	end

	-- Re-issue a countdown that was discarded. startDragCountdown recomputes dialOffset
	-- from getCountdownStartTime(), so arriving late self-corrects rather than desyncing.
	local display = gameplay_drag_display
	if not display or not display.startDragCountdown then return end
	for _, racer in pairs(dragData.racers) do
		local vehId = racer.vehId
		local dq = racer.isDisqualified or racer.isDesqualified
		if not racer.vehicleRemoved and not dq
			and racer.currentPhase == 2 and not racer.treeStarted
			and racer.phases and racer.phases[2] and racer.phases[2].started then

			local tries = (treeRepairs[vehId] or 0) + 1
			treeRepairs[vehId] = tries
			if tries <= MAX_TREE_REPAIRS then
				racer.phases[2].timerOffset = racer.phases[2].startedOffset or 0
				display.startDragCountdown(vehId, 0)
				log("I", logTag, string.format(
					"tree never started for racer %s - re-issuing the countdown (%d/%d)",
					tostring(vehId), tries, MAX_TREE_REPAIRS))
			elseif tries == MAX_TREE_REPAIRS + 1 then
				log("W", logTag, string.format(
					"racer %s will not start its tree after %d tries - leaving it alone",
					tostring(vehId), MAX_TREE_REPAIRS))
			end
		end
	end
end

--- Returns 0, as it always has, whether or not the repair fails.
function M.checkTimerDrift()
	if not enabled then return 0 end
	xpcall(repairTimerDrift, onTimerDriftError)
	return 0
end

--== menu / context ==========================================================

--- poi.lua calls setContext and then openMenu when a player drives into a lane trigger,
--- expecting a session layer to present a lobby. There is no lobby UI here by design --
--- players drive up, stage and race, the way Mileage always worked -- so entering a
--- lane is treated as the join signal instead.
function M.setContext(stripData, laneIndex)
	context = { stripData = stripData, lane = laneIndex }
	if mileage_dragLobby then
		mileage_dragLobby.setLocalContext(stripData, laneIndex)
	end
end

function M.openMenu(stripData, laneIndex)
	menuOpen = true
	-- poi.lua only calls this after setContext, but it passes the data again, so use it
	-- if setContext was somehow skipped.
	if stripData and mileage_dragLobby then
		mileage_dragLobby.setLocalContext(stripData, laneIndex)
	end
end

function M.isMenuOpen() return menuOpen end
function M.setMenuState(open) menuOpen = open and true or false end
function M.getContext() return context end

M.dragType = nil
M.treeType = nil
M.util = {}

--== control =================================================================

function M.setEnabled(state)
	enabled = state and true or false
	if not enabled then
		menuOpen = false
		context = nil
		raceStartSentFor = nil
		timeslipPending = false
		raceFinalized = false
		finalizedAt = nil
		timeslipRequestedAt = nil
		dqAt = nil
	end
	log("I", logTag, string.format("drag gamemode %s (host=%s, playerId=%s)",
		enabled and "ENABLED" or "disabled",
		tostring(M.isServerHost()), tostring(M.getLocalPlayerId())))
end

function M.isEnabled() return enabled end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
