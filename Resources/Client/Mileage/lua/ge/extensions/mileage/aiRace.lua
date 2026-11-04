--Mileage :: racing your own traffic cars on the road (CLIENT)
--
-- While the player drives beside one of this game's own traffic cars, the prompts app
-- offers "Race this car" (guihook MileageAiRace). The press picks a random road finish 1.5
-- to 4 km away that the car can reach and asks the server (mileageAiRace {request}; see the
-- AI races section of the server plugin). On the server's countdown this game keeps the
-- car in the game's traffic but takes it off traffic duty (the game's "empty" role, no
-- respawning or pooling), and everyone keeps driving through a rolling countdown run by
-- mileage/streetRace.lua. At zero the car gets the game's race driving to the finish at
-- full push, and this game reports its time on the street race's clock. Every ending gives
-- the car back to traffic, as the game's police chase hands a car back.
--
-- Another player's traffic beside the player is shown with the button off: only the game
-- that spawned a car can drive it. Players near the host are invited by the server: this
-- game shows the invite, joins (press or the Join button) and races rolling from where it
-- is. The window never calls the opponent AI: it is "this car" or its model's name.
--
-- Called from the UI and the key action: mileage_aiRace.press(), .join(id), .decline().

local M = {}

local logTag = "mileage.aiRace"

local SCAN_EVERY_SECONDS = 0.25
local BESIDE_METRES = 25
local HEADING_COS = math.cos(math.rad(45))
local FINISH_MIN, FINISH_MAX = 1500, 4000
local FINISH_RADIUS = 20
-- The push the game's own races give their fastest class.
local AGGRESSION = 1
local BEYOND_METRES = 250
local STUCK_SPEED = 1
local STUCK_SECONDS = 15
local PENDING_SECONDS = 10
local KEY_ACTION = "mileageAiRace"
local ACTIONS_FILE = "/lua/ge/extensions/core/input/actions/mileage.json"

local NO_FINISH = "No reachable finish from here, try another road."

-- The server's last status: {known, allowed, prize, againUntil}.
local status = {known = false, allowed = false, prize = 0, againUntil = 0}
-- Seconds since this extension loaded, for the reward's wait.
local clock = 0
local scanWait = 0
-- The traffic car beside the player: {vid, own, model, owner}, or nil.
local candidate = nil
-- The last card sent, as text, so it is sent on change only.
local shownKey = nil
-- A note on the card until the car beside the player changes (a refusal, no finish).
local note = nil
-- A request sent: {vid, node, model, sentAt}.
local pending = nil
-- The race this game is in: {id, host, vid, node, finish, model, saved, driving,
-- reported, lastPos, slowFor, given}.
local race = nil
-- An open invite: {id, host, car, distance, prize, left}.
local invite = nil
local loggedMissing = {}

local function compat()
	local c = extensions.mileage_compat
	if type(c) == "table" then return c end
	return nil
end

local function streetRace()
	local r = extensions.mileage_streetRace
	if type(r) == "table" then return r end
	return nil
end

local function raceEvents()
	local r = extensions.mileage_raceEvents
	if type(r) == "table" then return r end
	return nil
end

local function missing(what)
	if loggedMissing[what] then return end
	loggedMissing[what] = true
	log("W", logTag, what .. " is not available; traffic cars cannot be raced")
end

local function ui(data)
	guihooks.trigger("MileageAiRace", data)
end

local function send(fields)
	TriggerServerEvent("mileageAiRace", jsonEncode(fields))
end

local function report(fields)
	TriggerServerEvent("mileageRaceReport", jsonEncode(fields))
end

local function point(v)
	return {x = v.x, y = v.y, z = v.z}
end

local function distance(a, b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

local function myName()
	return MPConfig and MPConfig.getNickname() or nil
end

local function trafficEntry(vid)
	local c = compat()
	local data = c and c.getTrafficData()
	local entry = data and data[vid]
	if type(entry) == "table" then return entry end
	return nil
end

local function enabler()
	local e = type(extensions) == "table" and rawget(extensions, "mileageEnabler") or rawget(_G, "mileageEnabler")
	if type(e) == "table" then return e end
	return nil
end

--== the traffic car beside the player ========================================

-- Metres from the player's car to veh when it is beside it and heading the same way.
local function besideMetres(playerPos, playerDir, veh)
	local pos = veh:getPosition()
	local metres = distance(pos, playerPos)
	if metres > BESIDE_METRES then return nil end
	local dir = veh:getDirectionVector()
	local a = math.sqrt(dir.x * dir.x + dir.y * dir.y)
	local b = math.sqrt(playerDir.x * playerDir.x + playerDir.y * playerDir.y)
	if a < 1e-6 or b < 1e-6 then return nil end
	if (dir.x * playerDir.x + dir.y * playerDir.y) / (a * b) < HEADING_COS then return nil end
	return metres
end

local function modelName(veh)
	local c = compat()
	return (c and c.getModelName(veh.JBeam)) or tostring(veh.JBeam or "car")
end

-- The nearest own traffic car, or another player's traffic, beside the player's car.
local function findCandidate()
	local playerId = be:getPlayerVehicleID(0)
	if not playerId or playerId < 0 then return nil end
	local playerVeh = be:getObjectByID(playerId)
	if not playerVeh then return nil end
	local playerPos, playerDir = playerVeh:getPosition(), playerVeh:getDirectionVector()
	local best, bestMetres = nil, nil
	local function consider(vid, own, owner)
		if vid == playerId then return end
		local veh = be:getObjectByID(vid)
		-- A race spot's opponent is already racing.
		if veh and veh.mileageSpotRacer == "true" then return end
		local metres = veh and besideMetres(playerPos, playerDir, veh)
		if metres and (not bestMetres or metres < bestMetres) then
			best, bestMetres = {vid = vid, own = own, owner = owner, model = modelName(veh)}, metres
		end
	end
	local c = compat()
	local mp = MPVehicleGE
	for vid, entry in pairs((c and c.getTrafficData()) or {}) do
		if type(entry) == "table" and entry.isAi == true
				and (not mp or type(mp.isOwn) ~= "function" or mp.isOwn(vid)) then
			consider(vid, true, nil)
		end
	end
	local e = enabler()
	if mp and type(mp.getVehicles) == "function" and e and type(e.isRemoteTraffic) == "function" then
		for serverVehicleID, entry in pairs(mp.getVehicles() or {}) do
			local vid = type(entry) == "table" and entry.gameVehicleID
			if vid and vid ~= -1 and not mp.isOwn(vid) and e.isRemoteTraffic(serverVehicleID) then
				consider(vid, false, entry.ownerName and tostring(entry.ownerName) or nil)
			end
		end
	end
	return best
end

-- What the named race module answers, read only from a table with that function; a missing
-- module or function, or one that raises, reads as false.
local function asks(name, fn)
	local ext = extensions[name]
	if type(ext) ~= "table" or type(ext[fn]) ~= "function" then return false end
	local ok, answer = pcall(ext[fn])
	return ok and answer == true
end

-- Whether this player is in a race, or committed to one, so no traffic race is offered:
-- this module's own race until its result, a race against a player or an event race until
-- this car crosses the line, a race spot, an event signed up to, a drag strip's line or run,
-- or a mission. Asked every scan, so the card comes back by itself once all are over.
local function busy()
	if race then return true end
	local sr = streetRace()
	if sr and type(sr.current) == "function" then
		local ok, current = pcall(sr.current)
		if ok and type(current) == "table" and not current.finished then return true end
	end
	if asks("mileage_spotRace", "busy") or asks("mileage_raceEvents", "signedUp")
			or asks("mileage_dragLobby", "busy") then
		return true
	end
	local c = compat()
	return c ~= nil and c.getForegroundMissionId() and true or false
end

local function prizeAgainIn()
	return math.max(0, math.ceil(status.againUntil - clock))
end

-- The card for the car beside the player, sent when it changed. Nothing is sent while a
-- race or an invite has the app.
local function showCandidate(force)
	if race or invite then return end
	local message
	if not status.known or not candidate then
		message = {phase = "none"}
	else
		local c = compat()
		message = {phase = "available", own = candidate.own, car = candidate.model, owner = candidate.owner,
			allowed = status.allowed, prize = status.prize, prizeAgainIn = prizeAgainIn(),
			key = c and c.getControlForAction(KEY_ACTION) or nil, note = note}
	end
	-- The wait is shown in minutes, so a new card a minute is enough.
	local parts = {}
	for _, field in ipairs({"phase", "own", "car", "owner", "allowed", "prize", "key", "note"}) do
		table.insert(parts, tostring(message[field]))
	end
	table.insert(parts, tostring(math.ceil((message.prizeAgainIn or 0) / 60)))
	local key = table.concat(parts, "|")
	if not force and key == shownKey then return end
	shownKey = key
	ui(message)
end

local function scan()
	local found = nil
	local isBusy = busy()
	-- An invite not yet joined goes once this player is busy; the server's invite times out
	-- by itself.
	if isBusy and invite and not invite.sent then
		local id = invite.id
		invite = nil
		ui({phase = "inviteClosed", race = id})
	end
	if status.known and not isBusy and not invite and compat() then
		found = findCandidate()
	end
	local before = candidate
	candidate = found
	if (before and before.vid) ~= (found and found.vid) then note = nil end
	showCandidate(false)
end

local function setNote(text)
	note = text
	showCandidate(true)
end

--== pressing the button or the key ===========================================

--- Joins the open invite, or asks for a race against the own traffic car beside the
--- player. Returns true when something was sent.
function M.press()
	if invite then return M.join(invite.id) end
	if race or pending or not status.known or not candidate or not candidate.own then return false end
	if not status.allowed then
		setNote("Racing traffic is off on this server.")
		return false
	end
	local sr, events, c = streetRace(), raceEvents(), compat()
	if not sr or not events or not c then return false end
	local why, veh = sr.eligibility()
	if why then
		setNote(why)
		return false
	end
	local car = be:getObjectByID(candidate.vid)
	if not car then return false end
	local carPos = point(car:getPosition())
	local picked = events.pickRoadPoint(point(veh:getPosition()), FINISH_MIN, FINISH_MAX, function(option)
		return c.getPointNodePath(carPos, option.node) ~= nil
	end)
	if not picked then
		setNote(NO_FINISH)
		return false
	end
	local serverVehicleID = MPVehicleGE and type(MPVehicleGE.getServerVehicleID) == "function"
		and MPVehicleGE.getServerVehicleID(candidate.vid) or nil
	if not serverVehicleID then
		missing("MPVehicleGE.getServerVehicleID")
		return false
	end
	pending = {vid = candidate.vid, node = picked.node, model = candidate.model, sentAt = clock}
	send({request = {car = serverVehicleID, start = point(veh:getPosition()), finish = picked.pos,
		model = candidate.model}})
	return true
end

--- Joins the race this player is invited to.
function M.join(id)
	if not invite or invite.id ~= id or invite.sent then return false end
	local sr = streetRace()
	local why = "Racing is not available."
	if sr then why = sr.eligibility() end
	if why then
		invite.note = why
		ui({phase = "invite", race = invite.id, host = invite.host, car = invite.car, distance = invite.distance,
			prize = invite.prize, seconds = math.max(0, invite.left), note = why})
		return false
	end
	invite.sent = true
	send({join = id})
	return true
end

--- Turns the invite down: nothing is sent, the card goes.
function M.decline()
	if not invite then return false end
	local id = invite.id
	invite = nil
	ui({phase = "inviteClosed", race = id})
	showCandidate(true)
	return true
end

--== the race ================================================================

-- The traffic car stays in the game's traffic, so other games still see it as traffic,
-- but nothing the traffic does reaches it until it is given back.
local function takeOffDuty(r)
	local entry = trafficEntry(r.vid)
	if not entry or type(entry.setRole) ~= "function" then return false end
	r.saved = {roleName = entry.roleName, enableAutoPooling = entry.enableAutoPooling}
	local ok, err = pcall(entry.setRole, entry, "empty")
	if not ok then log("E", logTag, "taking the car off traffic duty failed: " .. tostring(err)) end
	entry.enableRespawn = false
	entry.enableAutoPooling = false
	return true
end

-- Once per race, after any ending: the car's own role, pooling and respawning come back,
-- and the traffic's next refresh sends it traffic driving again.
local function giveBack(r)
	if not r or not r.host or r.given then return end
	r.given = true
	local veh = be:getObjectByID(r.vid)
	if veh and r.driving then veh:queueLuaCommand("ai.setRacing(false)") end
	local entry = trafficEntry(r.vid)
	if not entry or not r.saved then return end
	if type(entry.setRole) == "function" then
		local ok, err = pcall(entry.setRole, entry, r.saved.roleName or entry.autoRole)
		if not ok then log("E", logTag, "giving the car back to traffic failed: " .. tostring(err)) end
	end
	entry.enableAutoPooling = r.saved.enableAutoPooling
	entry.enableRespawn = true
end

local function aiOut(r, why)
	r.reported = true
	report({race = r.id, aiOut = why})
end

-- Zero: the game's race driving to the finish and on past it, at full push, round other cars.
local function drive(r)
	r.driving = true
	local veh = be:getObjectByID(r.vid)
	local c = compat()
	if not veh or not c then
		aiOut(r, "gone")
		return
	end
	local pos = veh:getPosition()
	local dir = {x = r.finish.x - pos.x, y = r.finish.y - pos.y, z = 0}
	local nodes = {string.format("%q", r.node)}
	for _, name in ipairs(c.getRoadBeyond(r.node, dir, BEYOND_METRES)) do
		if name ~= r.node then table.insert(nodes, string.format("%q", tostring(name))) end
	end
	veh:queueLuaCommand("ai.driveUsingPath({wpTargetList = {" .. table.concat(nodes, ", ") .. "}, aggression = "
		.. AGGRESSION .. ", avoidCars = 'on'})")
	veh:queueLuaCommand("ai.setRacing(true)")
	r.lastPos = point(pos)
	r.slowFor = 0
end

-- The traffic car's time, on the street race's clock, once it reaches the finish; out
-- when it is gone or stands for STUCK_SECONDS.
local function watch(r, elapsed, dt)
	local veh = be:getObjectByID(r.vid)
	if not veh or not trafficEntry(r.vid) then
		aiOut(r, "gone")
		return
	end
	local pos = point(veh:getPosition())
	if distance(pos, r.finish) <= FINISH_RADIUS then
		r.reported = true
		report({race = r.id, aiFinished = elapsed})
		return
	end
	if dt > 0 then
		if distance(pos, r.lastPos) / dt < STUCK_SPEED then r.slowFor = r.slowFor + dt else r.slowFor = 0 end
	end
	r.lastPos = pos
	if r.slowFor >= STUCK_SECONDS then aiOut(r, "stuck") end
end

-- "the Ibishu Pessima", or "the Ibishu Pessima and Sam" with the other racers.
local function againstText(car, racers)
	local others = {}
	for _, name in ipairs(type(racers) == "table" and racers or {}) do
		if name ~= myName() then table.insert(others, tostring(name)) end
	end
	local text = "the " .. tostring(car or "car")
	if #others > 0 then text = text .. " and " .. table.concat(others, ", ") end
	return text
end

local function onCountdown(message)
	local sr = streetRace()
	if not sr or race then return end
	if message.host == myName() then
		if not pending then return end
		race = {id = message.race, host = true, vid = pending.vid, node = pending.node, finish = message.finish,
			model = message.car}
		pending = nil
		if not takeOffDuty(race) then
			aiOut(race, "gone")
		end
	else
		if not invite or invite.id ~= message.race then return end
		race = {id = message.race, host = false, model = message.car}
		invite = nil
	end
	ui({phase = "racing", race = race.id})
	if not sr.startRollingRace({id = message.race, finish = message.finish, radius = message.radius,
			seconds = message.seconds, other = againstText(message.car, message.racers), reward = message.prize}) then
		report({race = message.race, gaveUp = true})
	end
end

local function onResult(message)
	if race and race.id == message.race then
		giveBack(race)
		local sr = streetRace()
		if sr then sr.stopRace(message.race) end
		race = nil
	end
	if invite and invite.id == message.race then invite = nil end
	if tonumber(message.prizeAgainIn) then status.againUntil = clock + tonumber(message.prizeAgainIn) end
	ui(message)
	shownKey = nil
end

local function rxMileageAiRace(data)
	local message = jsonDecode(data)
	if type(message) ~= "table" then return end
	local phase = message.phase
	if phase == "status" then
		status = {known = true, allowed = message.allowed == true, prize = tonumber(message.prize) or 0,
			againUntil = clock + (tonumber(message.prizeAgainIn) or 0)}
		showCandidate(true)
	elseif phase == "refused" then
		pending = nil
		setNote(type(message.why) == "string" and message.why or "The race could not start.")
	elseif phase == "countdown" then
		onCountdown(message)
	elseif phase == "invite" and type(message.race) == "string" then
		if busy() then return end
		invite = {id = message.race, host = message.host, car = message.car, distance = message.distance,
			prize = message.prize, left = tonumber(message.seconds) or 5}
		ui(message)
	elseif phase == "joined" then
		local sr = streetRace()
		if race and race.id == message.race and sr then
			sr.setRaceInfo(message.race, {reward = message.prize, other = againstText(race.model, message.racers)})
		end
	elseif phase == "inviteClosed" then
		if invite and invite.id == message.race then
			invite = nil
			ui(message)
			showCandidate(true)
		end
	elseif phase == "result" then
		onResult(message)
	end
end

function M.onUpdate(dtReal)
	local dt = math.max(0, math.min(1, tonumber(dtReal) or 0))
	clock = clock + dt
	if pending and clock - pending.sentAt >= PENDING_SECONDS then pending = nil end
	if invite and not invite.sent then
		invite.left = invite.left - dt
		if invite.left <= 0 then
			local id = invite.id
			invite = nil
			ui({phase = "inviteClosed", race = id})
		end
	end
	if race and race.host and not race.reported then
		local sr = streetRace()
		local current = sr and sr.current()
		if current and current.id == race.id and current.phase == "racing" then
			if not race.driving then
				drive(race)
			else
				watch(race, current.elapsed or 0, dt)
			end
		end
	end
	scanWait = scanWait - dt
	if scanWait <= 0 then
		scanWait = SCAN_EVERY_SECONDS
		scan()
	end
end

--- Sends the card or the invite to the prompts app again, after a UI reload.
function M.sendState()
	if invite then
		ui({phase = "invite", race = invite.id, host = invite.host, car = invite.car, distance = invite.distance,
			prize = invite.prize, seconds = math.max(0, invite.left)})
		return
	end
	showCandidate(true)
end

local function reset()
	giveBack(race)
	race, invite, pending, candidate, note, shownKey = nil, nil, nil, nil, nil, nil
	status = {known = false, allowed = false, prize = 0, againUntil = 0}
end

function M.onBeamMPServerLeave()
	reset()
end

function M.onExtensionUnloaded()
	giveBack(race)
end

-- The game reads its list of key actions once, before Mileage's files arrive: asking it to
-- read Mileage's file again makes "Race the car beside you" appear in Controls.
local function loadKeyAction()
	local actions = core_input_actions
	if type(actions) ~= "table" or type(actions.onFileChanged) ~= "function" then
		log("W", logTag, "the game's key actions could not be reloaded; the key for racing traffic is not offered")
		return
	end
	pcall(actions.onFileChanged, ACTIONS_FILE)
	local listed = false
	if type(actions.getActiveActions) == "function" then
		local ok, list = pcall(actions.getActiveActions)
		listed = ok and type(list) == "table" and list[KEY_ACTION] ~= nil
	end
	log(listed and "I" or "W", logTag, "key action " .. KEY_ACTION .. (listed and " is listed in Controls"
		or " is not listed in Controls; the button still works"))
end

function M.onExtensionLoaded()
	if type(AddEventHandler) ~= "function" then
		log("E", logTag, "AddEventHandler unavailable - BeamMP not loaded")
		return
	end
	AddEventHandler("rxMileageAiRace", rxMileageAiRace)
	loadKeyAction()
	log("I", logTag, "Mileage traffic races LOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
