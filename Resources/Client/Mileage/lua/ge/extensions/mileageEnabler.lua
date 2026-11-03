--Mileage :: enabler (CLIENT)
--
-- Starts career when a Mileage server's settings arrive and keeps it in step with
-- the server.
--
--   * Game APIs that BeamNG.drive 0.39 renamed go through mileage_compat (every
--     "saveSlot" symbol became "profile", among others).
--   * Career start passes a startingOptions table with startMode = "freshStart"
--     ("Open World"). The third parameter of createOrLoadCareerAndStart is a table;
--     passing a boolean silently leaves no starting mode applied.
--   * The BeamMP nickname is sanitised locally before use as a profile name. The
--     game lowercases and strips non-alphanumerics, then de-duplicates against
--     profiles already on that client -- which would make the nickname -> save
--     mapping machine-dependent.
--   * A join keeps one loading screen up until the career has started, and tells the
--     server whether it started (see "Join" below).
--   * The pause menu's Mods entry and editable environment are kept out of the career
--     by mileage_patches (#15).
--   * Menu hooks come from mileage_patches (runtime wrappers around the game's
--     career modules).

local M = {}

local logTag = "mileage"

local compat = nil
local patches = nil

local nickname = nil

local blockedInputActions = {}
local clientConfig

local mileageActive = false
local syncRequested = false


local inComputerMenus = false

--Settings

local userTrafficSettings = {}
local mileageTrafficSettings = {}

local userGameplaySettings = {}
local mileageGameplaySettings = {}

local function getClientConfig()
	return clientConfig
end

-- The player's own values, saved before the first override of each join and put back
-- when they leave, so preferences changed between joins are kept.
local userSettingsSaved = false

local function getUserTrafficSettings()
	userTrafficSettings.trafficSmartSelections = settings.getValue('trafficSmartSelections')
	userTrafficSettings.trafficSimpleVehicles = settings.getValue('trafficSimpleVehicles')
	userTrafficSettings.trafficAllowMods = settings.getValue('trafficAllowMods')
end

local function setTrafficSettings(trafficSettings)
	for setting, value in pairs(trafficSettings) do
		settings.setValue(setting, value)
	end
end

local function getUserGameplaySettings()
	userGameplaySettings.simplifyRemoteVehicles = settings.getValue("simplifyRemoteVehicles")
	userGameplaySettings.spawnVehicleIgnitionLevel = settings.getValue("spawnVehicleIgnitionLevel")
	userGameplaySettings.skipOtherPlayersVehicles = settings.getValue("skipOtherPlayersVehicles")
end

local function setGameplaySettings(gameplaySettings)
	for setting, value in pairs(gameplaySettings) do
		settings.setValue(setting, value)
	end
end

--Hidden Nametags by Vehicle Model
-- Props, trailers and traffic that would otherwise spam nametags across the map.
local hiddens = {
	anticut = true, ball = true, barrels = true, barrier = true,
	barrier_plastic = true, blockwall = true, bollard = true, boxutility = true,
	boxutility_large = true, cannon = true, caravan = true, cardboard_box = true,
	cargotrailer = true, chair = true, christmas_tree = true, cones = true,
	containerTrailer = true, couch = true, crowdbarrier = true, delineator = true,
	dolly = true, dryvan = true, engine_props = true, flail = true,
	flatbed = true, flipramp = true, frameless_dump = true, fridge = true,
	gate = true, haybale = true, inflated_mat = true, kickplate = true,
	large_angletester = true, large_bridge = true, large_cannon = true,
	large_crusher = true, large_hamster_wheel = true, large_roller = true,
	large_spinner = true, large_tilt = true, large_tire = true,
	log_trailer = true, logs = true, mattress = true, metal_box = true,
	metal_ramp = true, piano = true, porta_potty = true, pressure_ball = true,
	rallyflags = true, rallysigns = true, rallytape = true, roadsigns = true,
	rocks = true, rollover = true, roof_crush_tester = true, sawhorse = true,
	shipping_container = true, simple_traffic = true, spikestrip = true,
	steel_coil = true, streetlight = true, suspensionbridge = true,
	tanker = true, testroller = true, tiltdeck = true, tirestacks = true,
	tirewall = true, trafficbarrel = true, trampoline = true, trashbin = true,
	tsfb = true, tub = true, tube = true, tv = true, wall = true,
	weightpad = true, woodcrate = true, woodplanks = true,
}

--Vehicles and part paints

-- The last state the server sent for each vehicle, by server vehicle id:
-- {active = <boolean>, traffic = <boolean or nil>}.
local knownStates = {}

-- BeamMP draws a player's nametag over every vehicle their game owns, so it is hidden on
-- a hidden car, a prop or trailer, and a car the owner's game marks as traffic or parked.
local function nametagHidden(jbeam, state)
	if hiddens[jbeam] then return true end
	if type(state) ~= "table" then return false end
	return state.active == false or state.traffic == true
end

-- The other player's game knows nothing of this player's parking challenge, so while one
-- runs here (mileage/parkingChallenge.lua) their traffic and parked cars are kept hidden
-- on this game only. rawget: a plain lookup on extensions loads a missing extension.
local PARKING_CHALLENGE = "mileage_parkingChallenge"

local function parkingChallengeActive()
	local parking = type(extensions) == "table" and rawget(extensions, PARKING_CHALLENGE) or rawget(_G, PARKING_CHALLENGE)
	return type(parking) == "table" and type(parking.isActive) == "function" and parking.isActive() == true
end

-- Another player's traffic far from this game's camera is held hidden on this game only
-- (mileage/farTraffic.lua), by server vehicle id.
local FAR_TRAFFIC = "mileage_farTraffic"

local function farTrafficHidden(serverVehicleID)
	local far = type(extensions) == "table" and rawget(extensions, FAR_TRAFFIC) or rawget(_G, FAR_TRAFFIC)
	return type(far) == "table" and type(far.isHidden) == "function" and far.isHidden(serverVehicleID) == true
end

-- Whether another player's car should be showing on this game, from the server's state.
local function shownHere(state, serverVehicleID)
	if not state.active then return false end
	if state.traffic ~= true then return true end
	return not (parkingChallengeActive() or farTrafficHidden(serverVehicleID))
end

-- Puts the server's last state on another player's car on this game; false when the
-- car is not here yet, is our own, or the server never sent its state.
local function applyKnownState(serverVehicleID)
	local state = knownStates[serverVehicleID]
	local entry = MPVehicleGE.getVehicles()[serverVehicleID]
	local gameVehicleID = entry and entry.gameVehicleID
	if not state or not gameVehicleID or gameVehicleID == -1 or MPVehicleGE.isOwn(gameVehicleID) then return false end
	local veh = be:getObjectByID(gameVehicleID)
	if not veh then return false end
	-- Only a change is applied: switching an already active car on again disturbs its
	-- physics on this screen, and a full list arrives every time a car spawns anywhere.
	local active = shownHere(state, serverVehicleID)
	if veh:getActive() ~= active then
		veh:setActive(active and 1 or 0)
	end
	entry.hideNametag = nametagHidden(entry.jbeam, state)
	return true
end

-- The whole list is asked for at most once every LIST_EVERY_SECONDS: a game joining a
-- busy server sees many cars appear at once, and one answer puts them all right.
local LIST_EVERY_SECONDS = 1
local listWanted = false
local sinceList = LIST_EVERY_SECONDS

local function requestVehicleStates()
	listWanted = true
end

local function updateListRequest(dtReal)
	local dt = tonumber(dtReal)
	if dt and dt > 0 then sinceList = math.min(sinceList + dt, LIST_EVERY_SECONDS) end
	if not listWanted or sinceList < LIST_EVERY_SECONDS then return end
	listWanted = false
	sinceList = 0
	TriggerServerEvent("careerVehSyncRequested", "")
end

-- true when the server says another player's car is their traffic or a parked car.
local function isRemoteTraffic(serverVehicleID)
	local state = knownStates[serverVehicleID]
	return type(state) == "table" and state.traffic == true
end

-- true once the server holds the owner's traffic mark for another player's car, so
-- isRemoteTraffic's answer for it is the owner's and not just "not marked yet". A car's
-- first state ({active = true} at spawn) carries no mark; the owner's game sends its
-- first mark, true or false, within a second (an older Mileage marks only traffic).
local function hasTrafficMark(serverVehicleID)
	local state = knownStates[serverVehicleID]
	return type(state) == "table" and type(state.traffic) == "boolean"
end

-- Career constantly hides/shows vehicles (garage, shopping, missions). A vehicle
-- hidden locally must be hidden for everyone, so the server keeps the
-- authoritative active-state map and we apply it to everything we do not own. The
-- server sends the whole map on request and one entry per change otherwise.
local function rxCareerVehSync(data)
	if data == "null" then return end
	local vehicleStates = jsonDecode(data)
	if type(vehicleStates) ~= "table" then return end
	for serverVehicleID, state in pairs(vehicleStates) do
		if type(state) == "table" then
			knownStates[serverVehicleID] = state
			applyKnownState(serverVehicleID)
		end
	end
end

-- Puts every kept state on this game again, for a change that is not the server's, such
-- as a parking challenge starting or ending here, or far-away traffic hidden or shown.
local function reapplyRemoteStates()
	for serverVehicleID in pairs(knownStates) do
		applyKnownState(serverVehicleID)
	end
end

--Traffic marks
--
-- Only the owner's game knows which of its cars are traffic or parked: the game flags
-- them (AI in the traffic data, isTraffic, isParked), and the models are ordinary cars.
-- Once a second the owner's game sends the marks that changed; the server stores them
-- with each car's state and passes them on.

local MARKS_EVERY_SECONDS = 1
local sinceMarks = 0

-- The mark last sent for each own vehicle: {gameVehicleID, mark}. The game id tells a
-- car apart from a new one BeamMP gave the same server id.
local sentMarks = {}

local function isAiTraffic(gameVehicleID)
	if not gameplay_traffic or type(gameplay_traffic.getTrafficData) ~= "function" then return false end
	local entry = (gameplay_traffic.getTrafficData() or {})[gameVehicleID]
	return type(entry) == "table" and entry.isAi == true
end

-- The car the player is in is theirs to drive, even one taken from traffic. A race spot's
-- opponent (mileage/spotRace.lua) counts as traffic: no nametag, hidden far away.
local function isTrafficCar(gameVehicleID, veh)
	if gameVehicleID == be:getPlayerVehicleID(0) then return false end
	if veh.isTraffic == "true" or veh.isParked == "true" or veh.mileageSpotRacer == "true" then return true end
	return isAiTraffic(gameVehicleID)
end

local function sendTrafficMarks()
	local changed, seen = nil, {}
	for serverVehicleID, entry in pairs(MPVehicleGE.getVehicles()) do
		local gameVehicleID = entry.gameVehicleID
		if gameVehicleID and gameVehicleID ~= -1 and MPVehicleGE.isOwn(gameVehicleID) then
			local veh = be:getObjectByID(gameVehicleID)
			if veh then
				seen[serverVehicleID] = true
				local mark = isTrafficCar(gameVehicleID, veh)
				local sent = sentMarks[serverVehicleID]
				-- Every car's first mark is sent, false too: other games wait for it before
				-- asking the car for its paint (#87). A car rebuilt under a new game id keeps
				-- the server's old mark, so its mark is sent again.
				local previous = nil
				if sent and sent.gameVehicleID == gameVehicleID then previous = sent.mark end
				if mark ~= previous then
					changed = changed or {}
					changed[serverVehicleID] = mark
				end
				sentMarks[serverVehicleID] = {gameVehicleID = gameVehicleID, mark = mark}
			end
		end
	end
	for serverVehicleID in pairs(sentMarks) do
		if not seen[serverVehicleID] then sentMarks[serverVehicleID] = nil end
	end
	if changed then TriggerServerEvent("careerVehicleTrafficMarks", jsonEncode(changed)) end
end

local function updateTrafficMarks(dtReal)
	local dt = tonumber(dtReal)
	if dt and dt > 0 then sinceMarks = sinceMarks + dt end
	if sinceMarks < MARKS_EVERY_SECONDS then return end
	sinceMarks = 0
	sendTrafficMarks()
end

local function onVehicleActiveChanged(gameVehicleID, active)
	if not gameVehicleID then return end
	if MPVehicleGE.isOwn(gameVehicleID) then
		local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
		if serverVehicleID then
			TriggerServerEvent("careerVehicleActiveHandler", jsonEncode({
				active = active,
				serverVehicleID = serverVehicleID,
			}))
		end
	else
		-- Another player's car changed here. Applying the server's own update, a parking
		-- challenge's hide or a far-away car's hide needs no answer; any other change is
		-- put right from the server's full map.
		local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
		local known = serverVehicleID and knownStates[serverVehicleID]
		if known and shownHere(known, serverVehicleID) == (active and true or false) then return end
		requestVehicleStates()
	end
end

local function onVehicleSpawned(gameVehicleID)
	if not gameVehicleID then return end
	local veh = be:getObjectByID(gameVehicleID)
	if veh then
		veh:queueLuaCommand('mileageEnabler.onVehicleReady()')
	end
	if MPVehicleGE.isOwn(gameVehicleID) then return end
	-- A car BeamMP builds after its state arrived takes the kept state.
	local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
	if not (serverVehicleID and applyKnownState(serverVehicleID)) then
		requestVehicleStates()
	end
end

-- The ghost setting last queued to each car, by game vehicle id. onUpdate queues it only
-- when it differs; a car whose vehicle Lua restarted (ready again) or was reset is
-- forgotten, so it gets the setting again.
local appliedGhost = {}

local function forgetGhost(gameVehicleID)
	if gameVehicleID then appliedGhost[gameVehicleID] = nil end
end

local function onVehicleReady(gameVehicleID)
	forgetGhost(gameVehicleID)
	local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
	if not serverVehicleID then return end
	local veh = be:getObjectByID(gameVehicleID)
	if not veh then return end

	if not MPVehicleGE.isOwn(gameVehicleID) then
		-- The game's own "not traffic" flag: its traffic checks it before adopting the
		-- player's car, so spectating this car never hands it to this game's traffic and
		-- police (gameplay/traffic.lua checkPlayer).
		veh:setDynDataFieldbyName("ignoreTraffic", 0, "true")
		-- Ghosting is not queued here: the vehicle side only has setGhost, and it is
		-- applied in onUpdate against the server's ghost config keys.
		local vehicles = MPVehicleGE.getVehicles()
		if vehicles[serverVehicleID] then
			vehicles[serverVehicleID].hideNametag = nametagHidden(veh.JBeam, knownStates[serverVehicleID])
		end
	end
	-- Raised so other players stay visible at big-map distances.
	veh:setField('renderDistance', '', 1610)
end

-- Re-entrancy guard.
--
-- Everything this handler does to correct a bad switch - enterNextVehicle,
-- setWalkingMode, enterVehicle - switches vehicles again, and the engine fires
-- onVehicleSwitched synchronously for each. Without a guard the handler calls
-- itself through the engine: entering a unicycle while inComputerMenus was set
-- recursed until the Lua stack overflowed, which showed up as walking mode simply
-- not working (the overflow surfaced inside gameplay_walk.toggleWalkingMode).
local handlingVehicleSwitch = false

-- While the camera sits on another player's car, this game's traffic would follow the
-- camera once the player's own car stops (gameplay/traffic.lua falls back to the camera
-- below 5 m/s), respawning around the car being watched. So spectating pins the traffic
-- focus on the own car the player left, and returning to an own car hands it back.
local trafficFocusPinned = false

local function updateTrafficFocus(oldGameVehicleID, newGameVehicleID)
	local newIsOwn = MPVehicleGE.isOwn(newGameVehicleID)
	local oldIsOwn = oldGameVehicleID ~= nil and oldGameVehicleID ~= -1
		and be:getObjectByID(oldGameVehicleID) ~= nil and MPVehicleGE.isOwn(oldGameVehicleID)
	if newIsOwn and not trafficFocusPinned then return end
	if not newIsOwn and not oldIsOwn then return end
	local c = compat or extensions.mileage_compat
	local setFocus = c and c.pickOrWarn(gameplay_traffic, "gameplay_traffic", "setFocus",
		"traffic follows the camera while spectating")
	if not setFocus then return end
	if newIsOwn then
		setFocus()
		trafficFocusPinned = false
	else
		setFocus('vehicle', {vehId = oldGameVehicleID, auto = false})
		trafficFocusPinned = true
	end
end

local function handleVehicleSwitch(oldGameVehicleID, newGameVehicleID)
	local newVeh = be:getObjectByID(newGameVehicleID)
	local oldVeh = be:getObjectByID(oldGameVehicleID)
	if not newVeh then return end

	updateTrafficFocus(oldGameVehicleID, newGameVehicleID)

	-- Never let the player end up controlling someone else's prop.
	if hiddens[newVeh.JBeam] and not MPVehicleGE.isOwn(newGameVehicleID) then
		be:enterNextVehicle(0, 1)
		return
	end

	-- Career's computer menus act on the vehicle the player occupies, so being
	-- dropped onto the unicycle mid-menu has to be undone. Clear the flag first:
	-- this is a one-shot correction, and leaving it set arms the same branch for
	-- every future switch.
	if newVeh.JBeam == "unicycle" and inComputerMenus then
		inComputerMenus = false
		gameplay_walk.setWalkingMode(false)
		if oldVeh then be:enterVehicle(0, oldVeh) end
	end
end

local function onVehicleSwitched(oldGameVehicleID, newGameVehicleID)
	if handlingVehicleSwitch then return end
	handlingVehicleSwitch = true
	local ok, err = pcall(handleVehicleSwitch, oldGameVehicleID, newGameVehicleID)
	handlingVehicleSwitch = false
	if not ok then
		log("E", logTag, "onVehicleSwitched failed: " .. tostring(err))
	end
end

--Traffic Signals and Cameras

-- A player's AI traffic counts as that player's own vehicles in multiplayer, so a
-- traffic car caught by a camera would be announced under the player's name
-- (isAiTraffic, above).

local function onSpeedTrapTriggered(speedTrapData, playerSpeed, overSpeed)
	if not MPVehicleGE.isOwn(speedTrapData.subjectID) then return end
	if isAiTraffic(speedTrapData.subjectID) then return end
	local veh = be:getObjectByID(speedTrapData.subjectID)
	if not veh then return end
	local highscore, leaderboard = gameplay_speedTrapLeaderboards.addRecord(speedTrapData, playerSpeed, overSpeed, veh)
	speedTrapData.licensePlate = veh:getDynDataFieldbyName("licenseText", 0) or "Illegible"
	speedTrapData.vehicleModel = core_vehicles.getModel(veh.JBeam).model.Name
	speedTrapData.playerSpeed = playerSpeed
	speedTrapData.overSpeed = overSpeed
	speedTrapData.highscore = highscore
	speedTrapData.leaderboard = leaderboard
	TriggerServerEvent("speedTrap", jsonEncode(speedTrapData))
end

local function onRedLightCamTriggered(redLightData, playerSpeed)
	if not MPVehicleGE.isOwn(redLightData.subjectID) then return end
	if isAiTraffic(redLightData.subjectID) then return end
	local veh = be:getObjectByID(redLightData.subjectID)
	if not veh then return end
	redLightData.licensePlate = veh:getDynDataFieldbyName("licenseText", 0) or "Illegible"
	redLightData.vehicleModel = core_vehicles.getModel(veh.JBeam).model.Name
	redLightData.playerSpeed = playerSpeed
	TriggerServerEvent("redLight", jsonEncode(redLightData))
end

local function rxTrafficSignalTimer(data)
	core_trafficSignals.setTimer(tonumber(data))
end

--Garage / Office Computer Handling

-- Career's computer menus act on the vehicle the player occupies. In MP the
-- player is usually walking, so put them in the target vehicle first. Fed by the
-- enriched hooks from mileage_patches, which carry the vehicle id that the
-- stock hooks omit.
local function computerMenuHandler(targetVehicleID)
	if not targetVehicleID then return end
	local veh = be:getObjectByID(targetVehicleID)
	if not veh or veh.JBeam == "unicycle" then return end
	if gameplay_walk.isWalking() then
		gameplay_walk.getInVehicle(veh)
	else
		be:enterVehicle(0, veh)
	end
	inComputerMenus = true
end

local function onComputerOpenedMP()
	inComputerMenus = false
end

--Patch BeamMP behavior

-- The mirrored driver side on remote vehicles is corrected by BeamMP itself
-- (beammp_multiplayer installs core_camera.getDriverData). BeamMP re-asserts
-- getDriverData from its own onUpdate every frame, so wrapping it would produce the
-- same mutual recursion documented in mileage/patches.lua. Leave it alone.

--Initial Syncs and Updates

local function actionsCheck()
	blockedInputActions = {}
	if not clientConfig.consoleEnabled then
		table.insert(blockedInputActions, "toggleConsoleNG")
	end
	if not clientConfig.worldEditorEnabled then
		table.insert(blockedInputActions, "editorToggle")
		table.insert(blockedInputActions, "editorSafeModeToggle")
		table.insert(blockedInputActions, "objectEditorToggle")
	end
	extensions.core_input_actionFilter.setGroup('mileage', blockedInputActions)
	extensions.core_input_actionFilter.addAction(0, 'mileage', #blockedInputActions > 0)
end

local function saveUserSettings()
	if userSettingsSaved then return end
	getUserTrafficSettings()
	getUserGameplaySettings()
	userSettingsSaved = true
end

local function restoreUserSettings()
	if not userSettingsSaved then return end
	setTrafficSettings(userTrafficSettings)
	setGameplaySettings(userGameplaySettings)
	userSettingsSaved = false
end

local function settingsCheck()
	saveUserSettings()
	mileageTrafficSettings.trafficAllowMods = clientConfig.trafficAllowMods
	mileageTrafficSettings.trafficSimpleVehicles = clientConfig.trafficSimpleVehicles
	mileageTrafficSettings.trafficSmartSelections = clientConfig.trafficSmartSelections
	setTrafficSettings(mileageTrafficSettings)
	mileageGameplaySettings.simplifyRemoteVehicles = clientConfig.simplifyRemoteVehicles
	mileageGameplaySettings.spawnVehicleIgnitionLevel = clientConfig.spawnVehicleIgnitionLevel
	mileageGameplaySettings.skipOtherPlayersVehicles = clientConfig.skipOtherPlayersVehicles
	setGameplaySettings(mileageGameplaySettings)
end

-- Profile name = sanitised BeamMP nickname (or the server-configured name),
-- plus the server's suffix. Sanitising here keeps the mapping deterministic
-- across clients; see compat.sanitizeProfileName.
local function resolveProfileName()
	local base = MPConfig.getNickname()
	if clientConfig and clientConfig.serverSaveNameEnabled and clientConfig.serverSaveName ~= "" then
		base = clientConfig.serverSaveName
	end
	local suffix = (clientConfig and clientConfig.serverSaveSuffix) or ""
	return compat.sanitizeProfileName(tostring(base) .. tostring(suffix))
end

--Join: one loading screen, then the career or a reported failure
--
-- On a join the map is already loaded, so the game's career start opens its own
-- 'careerActivate' loading screen and closes it only after every career-active handler
-- has run; one failing handler leaves it open for good. Mileage therefore:
--   * holds the map's loading screen under JOIN_HOLD_TAG from world-ready 1, so the
--     career's screens join it instead of showing a second one;
--   * runs the start under a traceback handler and closes the career's screens itself
--     when the start fails;
--   * tells the server the outcome (careerStartResult), so a player whose career cannot
--     start is dropped instead of waiting forever.

local JOIN_HOLD_TAG = "mileageJoin"
local JOIN_MAX_SECONDS = 60          -- matches the server's limit from settings request to start
local TRAFFIC_SCREEN_MAX_SECONDS = 30
local CAREER_SCREEN_TAGS = {"careerActivate", "careerVehicles"}
local REASON_MAX_LENGTH = 200

-- hold:    time the join hold was taken, while Mileage holds the loading screen
-- waiting: {since} from the settings' arrival while the career protection is not ready
-- start:   {since, deadline, level, ...} from the career start until it settles; since is
--          when the start began, deadline when the join's 60 s from the settings run out
-- checked: the join report stages already logged (compat.reportJoin)
local function newJoin()
	return {hold = nil, waiting = nil, start = nil, reported = false, navigated = false, checked = {}}
end

local join = newJoin()

local function currentLevel()
	return type(getCurrentLevelIdentifier) == "function" and getCurrentLevelIdentifier() or nil
end

local function openCareerScreens()
	local open = {}
	for _, tag in ipairs(CAREER_SCREEN_TAGS) do
		if compat.getLoadingStatus(tag) then table.insert(open, tag) end
	end
	return open
end

local function holdJoinLoadingScreen()
	if join.hold or mileageActive or not compat.isMPSession() then return end
	if compat.requestEnterLoadingScreen(JOIN_HOLD_TAG) then
		join.hold = os.clockhp()
		log("I", logTag, "join: holding the loading screen until the career starts")
	end
end

local function releaseJoinHold(why)
	if not join.hold then return end
	join.hold = nil
	compat.requestExitLoadingScreen(JOIN_HOLD_TAG)
	log("I", logTag, "join: loading screen released (" .. why .. ")")
end

-- BeamMP moves the interface to the in-game screen when its loading screen clears; the
-- held screen clears later, so the same step is repeated once it has.
local function moveToPlay()
	if join.navigated or join.hold or #openCareerScreens() > 0 then return end
	join.navigated = true
	compat.navigateToPlay()
end

local function reportCareerStart(started, reason)
	if join.reported then return end
	join.reported = true
	local payload = {started = started}
	if not started then payload.reason = reason end
	TriggerServerEvent("careerStartResult", jsonEncode(payload))
	if started then
		log("I", logTag, "join: career start confirmed to the server")
	else
		log("E", logTag, "join: career start failed, reported to the server: " .. reason)
	end
end

local function firstLine(text)
	local line = tostring(text):match("^[^\n]*") or ""
	return line:sub(1, REASON_MAX_LENGTH)
end

local function failCareerStart(reason)
	for _, tag in ipairs(openCareerScreens()) do
		compat.requestExitLoadingScreen(tag)
		log("W", logTag, "join: closed loading screen '" .. tag .. "' left open by the failed career start")
	end
	join.start = nil
	releaseJoinHold("career start failed")
	reportCareerStart(false, firstLine(reason))
	moveToPlay()
end

-- The game's insurance records do not always load on a join, which breaks Repair and the
-- Insurances page (see mileage/insuranceRestore.lua). A failing check is logged and the
-- join still completes: a broken repair screen is less harmful than a dropped player.
local function ensureInsuranceLoaded()
	local restore = extensions.mileage_insuranceRestore
	if not restore then
		log("E", logTag, "join: mileage_insuranceRestore is not loaded - insurance records not checked")
		return
	end
	local ok, err = pcall(restore.ensureLoaded)
	if not ok then
		log("E", logTag, "join: insurance check failed: " .. firstLine(err))
	end
end

-- Each stage of the join report is logged once per join.
local function reportJoinOnce(stage)
	if join.checked[stage] then return end
	join.checked[stage] = true
	compat.reportJoin(stage)
end

-- Per frame while the career start settles: it is done once the career is active and
-- its loading screens are released.
local function updateCareerStart()
	local start = join.start
	if not start then return end
	local elapsed = os.clockhp() - start.since

	if not start.trafficReleased and elapsed >= TRAFFIC_SCREEN_MAX_SECONDS
			and compat.getLoadingStatus("careerVehicles") then
		start.trafficReleased = true
		compat.releaseCareerTrafficScreen()
		log("W", logTag, string.format("join: traffic never reported ready - released loading screen " ..
			"'careerVehicles' after %ds", TRAFFIC_SCREEN_MAX_SECONDS))
	end

	if not start.levelChangeLogged and currentLevel() ~= start.level then
		start.levelChangeLogged = true
		log("W", logTag, string.format("join: the career start changed the map from '%s' to '%s' " ..
			"(the save names another map)", tostring(start.level), tostring(currentLevel())))
	end

	local open = openCareerScreens()
	if #open == 0 and compat.isCareerActive() ~= false then
		join.start = nil
		log("I", logTag, "join: career active")
		releaseJoinHold("career active")
		reportJoinOnce("active")
		ensureInsuranceLoaded()
		reportCareerStart(true)
		moveToPlay()
		return
	end

	if #open > 0 and not start.waitLogged then
		start.waitLogged = true
		log("I", logTag, "join: waiting for loading screens still open: " .. table.concat(open, ", "))
	end

	if os.clockhp() >= start.deadline then
		failCareerStart(string.format("career start did not finish within %ds (loading screens open: %s; career active: %s)",
			JOIN_MAX_SECONDS, #open > 0 and table.concat(open, ", ") or "none", tostring(compat.isCareerActive())))
	end
end

-- The hold never outlasts the server's limit, whatever the career start is doing.
local function updateJoinHold()
	if join.hold and os.clockhp() - join.hold >= JOIN_MAX_SECONDS then
		log("W", logTag, string.format("join: loading screen '%s' held for %ds - releasing",
			JOIN_HOLD_TAG, JOIN_MAX_SECONDS))
		releaseJoinHold("time limit")
		moveToPlay()
	end
end

local function refuseCareerStart()
	log("E", logTag, "career patches not applied - refusing to start career " ..
		"(would delete other players' vehicles)")
	failCareerStart("career vehicle protection not available")
end

-- Starts the career once the career protection is in place. arrived is when the settings
-- arrived: the start's 60 s limit counts from there, the same moment the server's confirm
-- clock measures, so time spent waiting for the protection is not given back. The traffic
-- screen's own 30 s count from the start itself.
local function beginCareerStart(arrived)
	local careerPatches = extensions.mileage_careerPatches
	reportJoinOnce("career")
	local profileName = resolveProfileName()
	log("I", logTag, string.format("join: career start begun for profile '%s' (nickname '%s', startMode '%s')",
		profileName, tostring(nickname), compat.defaultStartMode))
	join.start = {since = os.clockhp(), deadline = arrived + JOIN_MAX_SECONDS, level = currentLevel()}

	-- The shield has to wrap this call, not activateCareer.
	--
	-- career.lua's createOrLoadCareerAndStart invokes its *local* activateCareer() with
	-- no arguments, so removeVehicles defaults to true and it runs
	-- core_vehicles.removeAll() -- wiping every vehicle in the level, including other
	-- players' cars. A wrapper on career_career.activateCareer never sees that call,
	-- because a local call does not go through the module table. Observed live: a second
	-- player joining deleted the first player's car on their own screen the instant
	-- their career activated.
	local ok, started = careerPatches.withRemoteVehiclesProtected(function()
		return compat.createOrLoadCareerAndStart(profileName, false, compat.defaultStartMode)
	end)

	if not ok then
		failCareerStart(started)
		return
	end
	if not started then
		failCareerStart("could not set career profile '" .. profileName .. "'")
		return
	end
	mileageActive = true
	updateCareerStart()
end

local function rxCareerSync(data)
	local arrived = os.clockhp()
	clientConfig = jsonDecode(data)
	if not clientConfig then
		log("E", logTag, "rxCareerSync: could not decode client config")
		failCareerStart("could not read the server's Mileage settings")
		return
	end
	log("I", logTag, "join: settings received")
	reportJoinOnce("settings")
	nickname = MPConfig.getNickname()
	settingsCheck()
	actionsCheck()

	if mileageActive or join.start or join.waiting then return end

	-- Must be in place before the career activates, or activation deletes every
	-- other player's vehicle. The game can load its career module after the settings
	-- arrive; the start then waits for it (updateWaitingStart).
	local careerPatches = extensions.mileage_careerPatches
	if not careerPatches then
		refuseCareerStart()
		return
	end
	if not careerPatches.ensure() then
		log("W", logTag, "join: career protection not ready, waiting")
		join.waiting = {since = arrived}
		return
	end
	beginCareerStart(arrived)
end

-- Per frame while the career start waits for the career protection: start on the first
-- frame it is ready, or fail once the join's 60 s are up.
local function updateWaitingStart()
	local waiting = join.waiting
	if not waiting then return end
	if mileageActive or join.start then
		join.waiting = nil
		return
	end
	-- The limit is checked first: a protection that only turns up after it (a long frame)
	-- must not start a career the server is about to drop.
	if os.clockhp() - waiting.since >= JOIN_MAX_SECONDS then
		join.waiting = nil
		refuseCareerStart()
		return
	end
	local careerPatches = extensions.mileage_careerPatches
	if careerPatches and careerPatches.ensure() then
		join.waiting = nil
		log("I", logTag, string.format("join: career protection ready after %.1fs", os.clockhp() - waiting.since))
		beginCareerStart(waiting.since)
	end
end

local function rxClientConfigUpdate(data)
	local decoded = jsonDecode(data)
	if not decoded then return end
	-- The shared settings carry no traffic share; this player's last one is kept.
	if decoded.trafficShare == nil and clientConfig then decoded.trafficShare = clientConfig.trafficShare end
	clientConfig = decoded
	settingsCheck()
	actionsCheck()
end

-- A player joined or left a full server: this player's new share of the server's
-- traffic total, {road, parked}. It is kept in the client config (which a career start
-- under way already holds) and handed to the traffic meter.
local function rxCareerTrafficShare(data)
	local ok, share = pcall(jsonDecode, data)
	if not ok or type(share) ~= "table" or tonumber(share.road) == nil or tonumber(share.parked) == nil then
		log("W", logTag, "rxCareerTrafficShare: not a traffic share, ignored")
		return
	end
	if not clientConfig then return end
	clientConfig.trafficShare = {road = tonumber(share.road), parked = tonumber(share.parked)}
	log("I", logTag, string.format("traffic share from the server - road %d, parked %d",
		clientConfig.trafficShare.road, clientConfig.trafficShare.parked))
	local traffic = extensions.mileage_traffic
	if traffic and type(traffic.onTrafficShare) == "function" then traffic.onTrafficShare() end
end

-- Career activation spawns the player's own starter vehicle; drop the BeamMP
-- vehicles we already own so we do not end up with duplicates. Never touches
-- vehicles owned by other players.
local function onCareerActive(active)
	if not (active and mileageActive) then return end
	local vehicles = MPVehicleGE.getVehicles()
	for _, vehicle in pairs(vehicles) do
		if vehicle.isLocal and vehicle.jbeam ~= "unicycle" then
			local veh = be:getObjectByID(vehicle.gameVehicleID)
			if veh then veh:delete() end
		end
	end
end

-- World-ready 1 comes while the map's loading screen is still up, so the hold taken
-- there keeps that same screen up. The settings request says this client confirms its
-- career start, so the server waits for careerStartResult instead of counting the
-- request as a started career.
local function onWorldReadyState(state)
	if state == 1 then
		holdJoinLoadingScreen()
	elseif state == 2 and not syncRequested then
		TriggerServerEvent("prefabSyncRequested", "")
		TriggerServerEvent("careerSyncRequested", jsonEncode({confirmsStart = true}))
		syncRequested = true
		log("I", logTag, "join: world ready, settings requested")
	end
end

local function onUpdate(dtReal, dtSim, dtRaw)
	updateWaitingStart()
	updateCareerStart()
	updateJoinHold()
	updateListRequest(dtReal)
	if worldReadyState ~= 2 or not clientConfig then return end
	updateTrafficMarks(dtReal)
	local vehicles = MPVehicleGE.getVehicles()
	for serverVehicleID in pairs(vehicles) do
		local gameVehicleID = vehicles[serverVehicleID].gameVehicleID
		local veh = be:getObjectByID(gameVehicleID)
		if veh then
			local ghost = nil
			if not MPVehicleGE.isOwn(gameVehicleID) then
				if veh.JBeam == "unicycle" then
					ghost = clientConfig.remoteUnicycleGhost
				else
					ghost = clientConfig.remoteVehicleGhost
				end
			elseif veh.JBeam == "unicycle" then
				ghost = clientConfig.localUnicycleGhost
			end
			if ghost ~= nil and appliedGhost[gameVehicleID] ~= ghost then
				appliedGhost[gameVehicleID] = ghost
				veh:queueLuaCommand(string.format('mileageEnabler.setGhost(%s)', tostring(ghost)))
			end
		end
	end
end

--Loading / Unloading

local function onExtensionLoaded()
	compat = extensions.mileage_compat
	patches = extensions.mileage_patches
	if not compat then
		log("E", logTag, "mileage_compat failed to load - aborting")
		return false
	end

	compat.report()

	nickname = MPConfig.getNickname()

	AddEventHandler("rxCareerSync", rxCareerSync)
	AddEventHandler("rxClientConfigUpdate", rxClientConfigUpdate)
	AddEventHandler("rxCareerTrafficShare", rxCareerTrafficShare)
	AddEventHandler("rxCareerVehSync", rxCareerVehSync)
	AddEventHandler("rxTrafficSignalTimer", rxTrafficSignalTimer)

	log("I", logTag, "Mileage Enabler LOADED (target BeamNG " .. compat.targetGameVersion .. ")")
end

local function onExtensionUnloaded()
	releaseJoinHold("Mileage unloaded")
	log("I", logTag, "Mileage Enabler UNLOADED")
end

-- BeamMP fires onBeamMPServerLeave when the player leaves a server (MPCoreNetwork
-- leaveServer). Resetting the join state here is what lets a rejoin in the same game
-- session start the career again.
local function onBeamMPServerLeave()
	blockedInputActions = {}
	extensions.core_input_actionFilter.setGroup('mileage', blockedInputActions)
	extensions.core_input_actionFilter.addAction(0, 'mileage', false)
	restoreUserSettings()
	releaseJoinHold("left the server")
	join = newJoin()
	mileageActive = false
	syncRequested = false
	knownStates = {}
	listWanted = false
	sinceList = LIST_EVERY_SECONDS
	sentMarks = {}
	sinceMarks = 0
	trafficFocusPinned = false
	appliedGhost = {}
end

--Access

M.getClientConfig = getClientConfig
M.isTrafficCar = isTrafficCar
M.isRemoteTraffic = isRemoteTraffic
M.hasTrafficMark = hasTrafficMark
M.reapplyRemoteStates = reapplyRemoteStates

M.onCareerActive = onCareerActive

M.onVehicleActiveChanged = onVehicleActiveChanged
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleReady = onVehicleReady
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleResetted = forgetGhost
M.onVehicleDestroyed = forgetGhost

M.onSpeedTrapTriggered = onSpeedTrapTriggered
M.onRedLightCamTriggered = onRedLightCamTriggered

M.onComputerOpenedMP = onComputerOpenedMP

-- Enriched hooks published by mileage_patches. The stock hooks carry no
-- vehicle id, so the patches add it.
M.onCareerTuningStartedMP = computerMenuHandler
M.onPartShoppingStartedMP = computerMenuHandler
M.onVehiclePaintingUiOpenedMP = computerMenuHandler
M.onPerformanceTestStartedMP = computerMenuHandler

M.onWorldReadyState = onWorldReadyState
M.onUpdate = onUpdate

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.onBeamMPServerLeave = onBeamMPServerLeave

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
