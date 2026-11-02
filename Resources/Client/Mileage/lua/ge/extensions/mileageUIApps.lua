--Mileage :: UI app injection (CLIENT)
--
-- Missions, challenges and scenarios each switch to their own UI app layout,
-- none of which include the multiplayer apps. Without this you lose chat and the
-- player list (and with it the ability to see who is around or leave the
-- session) the moment you start a mission. This walks the layout the game is
-- about to use and injects the MP apps into it.
--
-- On BeamNG.drive 0.39:
--   * layouts are refreshed through compat.notifyLayoutsChanged (fires the
--     UiAppLayoutsChanged guihook). The game also watches the layout files itself
--     and refreshes on change, so this is belt-and-braces.
--   * there is no rallyModeRecce mission layout, and there is a gravityRace default
--     layout.

local M = {}

local logTag = "mileage.uiApps"

local compat = nil

local missionUIToResolve = false
local stateToUpdate = false

local defaultAppLayoutDirectory = "settings/ui_apps/originalLayouts/default/"
local missionAppLayoutDirectory = "settings/ui_apps/originalLayouts/mission/"
local userDefaultAppLayoutDirectory = "settings/ui_apps/layouts/default/"
local userMissionAppLayoutDirectory = "settings/ui_apps/layouts/mission/"

local defaultLayouts = {
	busRouteScenario = { filename = "busRouteScenario" },
	busStuntMinSpeed = { filename = "busStuntMinSpeed" },
	career = { filename = "career" },
	careerBigMap = { filename = "careerBigMap" },
	careerMission = { filename = "careerMission" },
	careerMissionEnd = { filename = "careerMissionEnd" },
	careerPause = { filename = "careerPause" },
	careerRefuel = { filename = "careerRefuel" },
	collectionEvent = { filename = "collectionEvent" },
	crawl = { filename = "crawl" },
	damageScenario = { filename = "damageScenario" },
	dderbyScenario = { filename = "dderbyScenario" },
	discover = { filename = "discover" },
	driftScenario = { filename = "driftScenario" },
	exploration = { filename = "exploration" },
	externalui = { filename = "externalUI" },
	freeroam = { filename = "freeroam" },
	garage = { filename = "garage" },
	garage_v2 = { filename = "garage_v2" },
	gravityRace = { filename = "gravityRace" }, -- added in 0.39
	multiseatscenario = { filename = "multiseatscenario" },
	noncompeteScenario = { filename = "noncompeteScenario" },
	offroadScenario = { filename = "offroadScenario" },
	proceduralScenario = { filename = "proceduralScenario" },
	quickraceScenario = { filename = "quickraceScenario" },
	radial = { filename = "radial" },
	scenario = { filename = "scenario" },
	scenario_cinematic_start = { filename = "scenario_cinematic_start" },
	singleCheckpointScenario = { filename = "singleCheckpointScenario" },
	tasklist = { filename = "tasklist" },
	tasklistTall = { filename = "tasklistTall" },
	unicycle = { filename = "unicycle" }
}

local missionLayouts = {
	aRunForLifeMission = { filename = "aRunForLife" },
	basicMissionLayout = { filename = "basicMission" },
	crashTestMission = { filename = "crashTestMission" },
	crawlMission = { filename = "crawlMission" },
	dragMission = { filename = "dragMission" },
	driftMission = { filename = "driftMission" },
	driftNavigationMission = { filename = "driftNavigationMission" },
	evadeMission = { filename = "evadeMission" },
	garageToGarageMission = { filename = "garageToGarage" },
	rallyModeLoop = { filename = "rallyModeLoop" },
	rallyModeLoopStage = { filename = "rallyModeLoopStage" },
	-- rallyModeRecce removed in 0.39
	rallyModeStage = { filename = "rallyModeStage" },
	scenarioMission = { filename = "scenarioMission" },
	timeTrialMission = { filename = "timeTrialMission" }
}

-- BeamMP renamed all of its UI apps for 0.39: multiplayerchat -> beammpChat,
-- multiplayersession -> beammpSession, multiplayerplayerlist -> beammpPlayerList*.
-- An app name in a layout that no longer exists is drawn by the game as a red
-- dashed "Unknown app: <name>" placeholder, which is what the old names now produce.
--
-- Names here are the app.json `directive` values, which is what the game keys its
-- app catalogue by (apps.lua: appName = appName or directive, and none of BeamMP's
-- app.json files set appName). BeamMP's own shipped layout writes `beammpchat` and
-- `beammpsession` in lowercase, which does not match the catalogue key -- not copied
-- here on purpose.
--
-- Placements are taken from BeamMP's own default layout so the apps land where their
-- authors intended.
local multiplayerApps = {
	-- The drag result panel.
	--
	-- Not one of ours -- it is BeamNG's dragRace app -- but it ships pinned to the top
	-- right corner, where the timeslip reads as a notification you catch out of the corner
	-- of your eye rather than a result screen. It is the very same <Timeslip> component the
	-- career mission end screen puts front and centre (MissionTimeSlipPanel.vue:5,
	-- dragRace/app.vue:7); freeroam multiplayer races are not missions, so that screen
	-- never opens for them and the app is all there is.
	--
	-- Shipped size, middle of the screen. top/bottom/left/right at 0 with margin auto is
	-- the standard absolute-centring trick, so it sits dead centre at whatever resolution.
	-- Clicking the slip cancels its auto-dismiss (dragRace/app.vue:7
	-- @click="cancelClearTimeout") if you want longer to read it.
	dragRace = {
		appName = "dragRace",
		-- 260px is the shipped width, sized for a corner strip, and it cuts the right lane
		-- clean off -- the timeslip is a two-column table and only one column fits. Wide
		-- enough for both, centred so it does not read as a notification.
		placement = {
			position = "absolute",
			width = "640px",
			height = "800px",
			top = 0,
			bottom = 0,
			left = 0,
			right = 0,
			margin = "auto"
		}
	},
	beammpChat = {
		appName = "beammpChat",
		placement = {
			width = "550px",
			bottom = "0px",
			height = "170px",
			-- 305px rather than BeamMP's 180px: Mileage shifts chat right to clear
			-- the career UI. Matches the shipped mileage.uilayout.json.
			left = "305px"
		}
	},
	beammpSession = {
		appName = "beammpSession",
		placement = {
			bottom = "",
			height = "40px",
			left = 0,
			margin = "auto",
			position = "absolute",
			right = 0,
			top = "0px",
			width = "700px"
		}
	},
	mileageplayerlist = {
		appName = "mileageplayerlist",
		placement = {
			bottom = "",
			height = "560px",
			left = "",
			position = "absolute",
			right = "0px",
			top = "240px",
			width = "300px"
		}
	},
	-- Mileage's prompts: race challenges, money requests, the race countdown and result,
	-- race events and the leaderboard. Beside the player list, which opens most of them.
	mileageoffers = {
		appName = "mileageoffers",
		placement = {
			bottom = "",
			height = "520px",
			left = "",
			position = "absolute",
			right = "305px",
			top = "240px",
			width = "340px"
		}
	}
}

-- App names Mileage used to inject, or that it replaces with its own. These are
-- actively removed from layouts: leaving them behind is what produces the red
-- "Unknown app" boxes after a BeamMP update.
local retiredApps = {
	"multiplayerchat",
	"multiplayersession",
	"multiplayerplayerlist",
}

-- BeamMP's player lists, replaced by Mileage's (which also shows career money) at
-- Mileage's own place.
local replacedPlayerLists = {
	"beammpPlayerListVue",
	"beammpPlayerListAngular",
	"multiplayerplayerlist", -- pre-0.39 name
}

-- Cached catalogue of apps that actually exist on disk right now.
-- getUIAppsData scans every app.json, and the game itself warns when it takes over
-- 100ms, so this is fetched once and reused.
local availableApps = nil

local function getAvailableApps()
	if availableApps then return availableApps end
	if not ui_apps or type(ui_apps.getUIAppsData) ~= "function" then return nil end
	local data = ui_apps.getUIAppsData()
	if type(data) ~= "table" then return nil end
	local count = 0
	for _ in pairs(data) do count = count + 1 end
	-- Refuse to trust a suspiciously small catalogue: if this is called before the
	-- app list is populated, pruning against it would strip the layout bare.
	if count < 10 then
		log("D", logTag, "app catalogue too small (" .. count .. ") - not caching yet")
		return nil
	end
	availableApps = data
	return availableApps
end

-- Apps Mileage is about to (re)insert, so pruning must not race ahead and strip them.
-- Retired names are deliberately NOT protected: they are the ones that need removing.
local function isManagedApp(name)
	return multiplayerApps[name] ~= nil
end

-- Drops app names Mileage itself put there in an earlier version, or that a BeamMP
-- update renamed out from under the layout. Unlike pruneMissingApps this does not
-- consult the app catalogue, so it works even when the catalogue is unavailable.
local function removeRetiredApps(layout)
	local removed = {}
	for _, retired in ipairs(retiredApps) do
		for i = #layout.apps, 1, -1 do
			if layout.apps[i].appName == retired then
				table.insert(removed, retired)
				table.remove(layout.apps, i)
			end
		end
	end
	if #removed > 0 then
		log("I", logTag, "removed retired app(s): " .. table.concat(removed, ", "))
		return true
	end
	return false
end

-- Removes apps that no longer exist in this build of the game.
--
-- Layouts live in the user folder and shadow the game's originals, so a layout
-- written under 0.38.6 keeps its apps forever - including ones 0.39 deleted, which
-- then sit on screen doing nothing. Previously the only cure was resetting the
-- layout to default, which also threw away the multiplayer apps. This removes
-- exactly the dead entries and leaves everything else, including the player's own
-- customisation, alone.
local function pruneMissingApps(layout)
	local catalogue = getAvailableApps()
	if not catalogue then return false end

	local removed = {}
	for i = #layout.apps, 1, -1 do
		local name = layout.apps[i].appName
		if name and not catalogue[name] and not isManagedApp(name) then
			table.insert(removed, name)
			table.remove(layout.apps, i)
		end
	end

	if #removed > 0 then
		log("I", logTag, "pruned app(s) that no longer exist in this game build: " ..
			table.concat(removed, ", "))
		return true
	end
	return false
end

local function findApp(layout, name)
	for i, app in ipairs(layout.apps) do
		if app.appName == name then return i, app end
	end
end

-- Adds the app if absent, and collapses duplicates if a previous run (or the
-- user) left more than one. Returns whether the layout was modified.
local function checkApp(layout, appData)
	local firstIndex = nil
	local removed = false
	for i = #layout.apps, 1, -1 do
		local app = layout.apps[i]
		if app.appName == appData.appName then
			if not firstIndex then
				firstIndex = i
			else
				table.remove(layout.apps, i)
				removed = true
			end
		end
	end
	if not firstIndex then
		table.insert(layout.apps, deepcopy(appData))
		return true
	end
	return removed
end

-- Repositions an app that already exists in the layout, leaving everything else alone.
-- Unlike checkApp this never inserts: if the player's layout does not have the app, that
-- is their choice and we do not second-guess it.
local function resizeApp(layout, appData)
	local i, app = findApp(layout, appData.appName)
	if not i or not app then return false end

	local wanted = appData.placement
	if not wanted then return false end

	local changed = false
	app.placement = app.placement or {}
	for k, v in pairs(wanted) do
		if app.placement[k] ~= v then
			app.placement[k] = v
			changed = true
		end
	end
	return changed
end

local function replaceApp(layout, oldName, newApp)
	local i = findApp(layout, oldName)
	if i then
		layout.apps[i] = deepcopy(newApp)
		return true
	end
end

-- Build of the game we are running, used to tell a layout written for this version
-- from one carried over from an older install.
local function getGameBuild()
	return tostring(beamng_versionb or beamng_version or "unknown")
end

-- Prefer the user's copy of a layout; fall back to the shipped original. Writes
-- always go to the user directory.
--
-- Second return value says whether the user's copy predates this build of the game.
-- Layouts in the user folder shadow the game's originals and are never migrated, so
-- after a game update a player keeps their old layout indefinitely: it still holds
-- apps the update deleted, and it is missing the ones the update added. Going 0.38.6
-- to 0.39 that means a career layout still carrying `messagesTasksApps` and with no
-- `topLeftApps`, `topCenterApps` or `dragRace` at all.
--
-- Pruning alone cannot fix that (it can drop the dead app but not add the new ones),
-- which is why a stale layout is rebuilt from the game's current original instead.
local function loadLayout(customDir, defaultDir, filename)
	local custom = jsonReadFile(customDir .. filename .. ".uilayout.json")
	local default = jsonReadFile(defaultDir .. filename .. ".uilayout.json")

	if custom then
		local stamp = custom.mileageBuild
		local stale = stamp ~= getGameBuild()
		if stale and default then
			log("I", logTag, string.format(
				"layout '%s' was written for build %s, rebuilding from this build's default (%s)",
				filename, tostring(stamp or "none"), getGameBuild()))
			return deepcopy(default), customDir, true
		end
		return deepcopy(custom), customDir, false
	end

	if default then return deepcopy(default), customDir, true end
end

-- Lets a server or user override app placement by shipping their own
-- mileage.uilayout.json.
local function loadMpAppOverrides()
	local mpLayout = jsonReadFile(userDefaultAppLayoutDirectory .. "mileage.uilayout.json")
	if mpLayout and type(mpLayout.apps) == "table" then
		for _, app in pairs(mpLayout.apps) do
			if type(app) == "table" and app.appName then
				multiplayerApps[app.appName] = app
			end
		end
	end
end

local function processLayout(layoutInfo, isDefault)
	if not layoutInfo then return false end

	local customDir = isDefault and userDefaultAppLayoutDirectory or userMissionAppLayoutDirectory
	local defaultDir = isDefault and defaultAppLayoutDirectory or missionAppLayoutDirectory

	local layout, saveDir, rebuilt = loadLayout(customDir, defaultDir, layoutInfo.filename)
	if not layout or not layout.apps then return false end

	-- A rebuilt layout is already this build's default, so it needs stamping and
	-- writing even if adding our apps happens to change nothing.
	local updated = rebuilt or false

	-- Belt and braces for layouts that are already current: drop anything the game
	-- no longer ships. A rebuilt layout has nothing to prune.
	if not rebuilt then
		updated = pruneMissingApps(layout) or updated
	end

	-- Always run, rebuilt or not: a rebuilt layout comes from the game's default, but
	-- a current one may still carry names from an older Mileage or an older BeamMP.
	updated = removeRetiredApps(layout) or updated

	updated = checkApp(layout, multiplayerApps.beammpChat) or updated
	updated = checkApp(layout, multiplayerApps.beammpSession) or updated
	-- BeamMP's own player list is replaced by ours, which also shows career money.
	for _, name in ipairs(replacedPlayerLists) do
		updated = replaceApp(layout, name, multiplayerApps.mileageplayerlist) or updated
	end
	updated = checkApp(layout, multiplayerApps.mileageplayerlist) or updated
	updated = checkApp(layout, multiplayerApps.mileageoffers) or updated
	updated = resizeApp(layout, multiplayerApps.dragRace) or updated

	if updated then
		-- Stamp so the rebuild happens once per game build rather than every check.
		layout.mileageBuild = getGameBuild()
		jsonWriteFile(saveDir .. layoutInfo.filename .. ".uilayout.json", layout, 1)
		stateToUpdate = true
	end
	return updated
end

-- Migrates every layout Mileage knows about, not just the one currently on screen.
--
-- processLayout only ever touches the active layout, so on its own a player would
-- get their career layout fixed on join and then discover a stale one each time they
-- opened the big map, started a mission, hit the garage screen and so on. Doing them
-- all at join means the whole UI is consistent from the start.
--
-- Runs once per session. Layouts already stamped for this build are read and skipped,
-- so the cost after the first join is a few dozen file reads and no writes.
local migrationDone = false

local function migrateAllLayouts()
	if migrationDone then return end
	migrationDone = true

	loadMpAppOverrides()

	local migrated = 0
	for _, layoutInfo in pairs(defaultLayouts) do
		if processLayout(layoutInfo, true) then migrated = migrated + 1 end
	end
	for _, layoutInfo in pairs(missionLayouts) do
		if processLayout(layoutInfo, false) then migrated = migrated + 1 end
	end

	if migrated > 0 then
		log("I", logTag, string.format("updated %d UI layout(s) for game build %s", migrated, getGameBuild()))
	end
end

local function checkUIApps(state)
	if not state or not state.appLayout then return end
	loadMpAppOverrides()

	local isDefault = defaultLayouts[state.appLayout] ~= nil
	local layoutInfo = defaultLayouts[state.appLayout] or missionLayouts[state.appLayout]
	if not layoutInfo then return end

	processLayout(layoutInfo, isDefault)
end

-- Last layout we processed, so the check can be re-run without waiting for the game
-- to change state. Resetting a layout from the UI does not raise a game state
-- update, so without this the multiplayer apps would stay gone until the player
-- happened to switch state (enter a vehicle, open the map, start a mission...).
local lastState = nil

local function refresh()
	if not lastState then return false end
	checkUIApps(lastState)
	return stateToUpdate
end

local function onGameStateUpdate(state)
	if not state or not state.appLayout then return end
	lastState = deepcopy(state)
	-- Leaving a mission drops the game back to the freeroam layout; career has to
	-- be re-asserted or the career UI never comes back.
	if missionUIToResolve and state.appLayout == "freeroam" then
		core_gamestate.setGameState("career", "career", nil)
		missionUIToResolve = false
	end
	if not state.appLayout:find("career") then
		missionUIToResolve = true
	end
	checkUIApps(state)
end

local function onUpdate(dtReal, dtSim, dtRaw)
	if worldReadyState == 2 and stateToUpdate then
		compat.notifyLayoutsChanged()
		stateToUpdate = false
	end
end

local function onExtensionLoaded()
	compat = extensions.mileage_compat
	if not compat then
		log("E", logTag, "mileage_compat unavailable - UI app injection disabled")
		return false
	end
	log("I", logTag, "Mileage UI Apps LOADED")
end

local function onExtensionUnloaded()
	log("I", logTag, "Mileage UI Apps UNLOADED")
end

-- Career activation is the point where the career layouts become the ones in use,
-- and it is also a convenient moment to re-assert the multiplayer apps after a
-- player has reset a layout.
local function onCareerActive(active)
	if not active then return end
	migrateAllLayouts()
	refresh()
end

-- worldReadyState 2 is the earliest point at which the app catalogue is populated
-- and layouts can be written, so this is where a joining player's layouts get
-- brought up to date - before they have a chance to see a stale one.
local function onWorldReadyState(state)
	if state == 2 then migrateAllLayouts() end
end

-- Manual entry point: mileageUIApps.refresh() from the console re-applies the
-- multiplayer apps and prunes dead ones without rejoining.
M.refresh = refresh
-- mileageUIApps.migrateLayouts() from the console re-runs the sweep on demand.
M.migrateLayouts = function() migrationDone = false; migrateAllLayouts() end

M.onGameStateUpdate = onGameStateUpdate
M.onCareerActive = onCareerActive
M.onWorldReadyState = onWorldReadyState

M.onUpdate = onUpdate

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
