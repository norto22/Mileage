-- Resources/Client/Mileage/lua/ge/extensions/mileageUIApps.lua: a player's saved UI
-- layouts. A layout stamped for this game build keeps the player's own apps, an older
-- one is rebuilt from the game's original, and Mileage's apps go where the shipped or
-- the player's override puts them.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileageUIApps.lua"
local BUILD = "0.40.4.0.12345"
local USER_DEFAULT = "settings/ui_apps/layouts/default/"
local ORIGINAL_DEFAULT = "settings/ui_apps/originalLayouts/default/"

local files, written, logs

local function copy(t)
	if type(t) ~= "table" then return t end
	local r = {}
	for k, v in pairs(t) do r[k] = copy(v) end
	return r
end

-- A catalogue big enough for the module to trust (it ignores one under 10 apps).
local function catalogue()
	local apps = {}
	for i = 1, 12 do apps["gameApp" .. i] = {} end
	apps.mileageplayerlist = {}
	apps.multiplayerchat = {}
	apps.multiplayersession = {}
	return apps
end

local function loadModule(existing)
	files, written, logs = existing, {}, {}
	beamng_versionb = BUILD
	deepcopy = copy
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function jsonReadFile(path) return copy(files[path]) end
	function jsonWriteFile(path, data) written[path] = copy(data) end
	function setExtensionUnloadMode() end
	ui_apps = {getUIAppsData = catalogue}
	return dofile(SOURCE)
end

local function names(layout)
	local out = {}
	for _, app in ipairs(layout.apps) do table.insert(out, app.appName) end
	return out
end

local function indexOf(list, wanted)
	for i, v in ipairs(list) do
		if v == wanted then return i end
	end
end

local function savedCareerLayout(stamp)
	return {
		mileageBuild = stamp,
		apps = {
			{appName = "gameApp1", placement = {left = "0px"}},
			{appName = "mileageplayerlist", placement = {left = "10px", top = "200px"}},
			{appName = "gameApp2", placement = {left = "20px"}},
			{appName = "multiplayerchat"},
			{appName = "multiplayersession"},
		},
	}
end

local OLD_PLACEMENT = {position = "absolute", left = "10px", top = "200px", width = "320px", height = "410px"}

test("a layout stamped for this build keeps the player's own apps", function()
	local M = loadModule({
		[USER_DEFAULT .. "career.uilayout.json"] = savedCareerLayout(BUILD),
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp9"}}},
	})
	M.migrateLayouts()
	local layout = written[USER_DEFAULT .. "career.uilayout.json"]
	local list = names(layout)
	expect(indexOf(list, "gameApp2"), "player's own app kept")
	same(indexOf(list, "gameApp9"), nil, "not rebuilt from the original")
	same(layout.mileageBuild, BUILD, "stamped for this build")
	same(countLines(logs, "rebuilding from this build's default"), 0, "no rebuild logged")
end)

test("a layout stamped for an older build is rebuilt from this build's original", function()
	local M = loadModule({
		[USER_DEFAULT .. "career.uilayout.json"] = savedCareerLayout("0.39.2.1.0"),
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp9"}}},
	})
	M.migrateLayouts()
	local list = names(written[USER_DEFAULT .. "career.uilayout.json"])
	expect(indexOf(list, "gameApp9"), "rebuilt from the original")
	expect(indexOf(list, "mileageplayerlist"), "Mileage player list added")
	same(countLines(logs, "was written for build 0.39.2.1.0"), 1, "old stamp named in the log")
end)

test("a layout with no stamp is rebuilt from this build's original", function()
	local layout = savedCareerLayout(BUILD)
	layout.mileageBuild = nil
	local M = loadModule({
		[USER_DEFAULT .. "career.uilayout.json"] = layout,
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp9"}}},
	})
	M.migrateLayouts()
	local list = names(written[USER_DEFAULT .. "career.uilayout.json"])
	expect(indexOf(list, "gameApp9"), "rebuilt from the original")
	same(countLines(logs, "was written for build none"), 1, "missing stamp named in the log")
end)

test("an app the game no longer has is dropped from a current layout", function()
	local layout = savedCareerLayout(BUILD)
	table.insert(layout.apps, {appName = "goneApp", placement = {left = "5px"}})
	local M = loadModule({
		[USER_DEFAULT .. "career.uilayout.json"] = layout,
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp1"}}},
	})
	M.migrateLayouts()
	local list = names(written[USER_DEFAULT .. "career.uilayout.json"])
	same(indexOf(list, "goneApp"), nil, "missing app dropped")
	expect(indexOf(list, "gameApp2"), "player's own app kept")
end)

test("BeamMP's own player list is replaced at Mileage's default place", function()
	local layout = savedCareerLayout(BUILD)
	layout.apps[2] = {appName = "beammpPlayerListVue", placement = copy(OLD_PLACEMENT)}
	local M = loadModule({
		[USER_DEFAULT .. "career.uilayout.json"] = layout,
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp1"}}},
	})
	M.migrateLayouts()
	local saved = written[USER_DEFAULT .. "career.uilayout.json"]
	local list = names(saved)
	same(indexOf(list, "beammpPlayerListVue"), nil, "BeamMP's player list")
	local i = indexOf(list, "mileageplayerlist")
	expect(i, "Mileage player list")
	same(saved.apps[i].placement.top, "240px", "Mileage's default top")
	same(saved.apps[i].placement.left, "", "Mileage's default left")
end)

test("the shipped override places the player list", function()
	local M = loadModule({
		[USER_DEFAULT .. "mileage.uilayout.json"] = {
			apps = {{appName = "mileageplayerlist", placement = {left = "100px"}}},
		},
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp1"}}},
	})
	M.migrateLayouts()
	local layout = written[USER_DEFAULT .. "career.uilayout.json"]
	local i = indexOf(names(layout), "mileageplayerlist")
	expect(i, "player list added")
	same(layout.apps[i].placement.left, "100px", "shipped override placement")
end)

test("only mileage.uilayout.json overrides the player list's place", function()
	local M = loadModule({
		[USER_DEFAULT .. "mileage.uilayout.json"] = {
			apps = {{appName = "mileageplayerlist", placement = {left = "100px"}}},
		},
		[USER_DEFAULT .. "other.uilayout.json"] = {
			apps = {{appName = "mileageplayerlist", placement = {left = "777px"}}},
		},
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp1"}}},
	})
	M.migrateLayouts()
	local layout = written[USER_DEFAULT .. "career.uilayout.json"]
	local i = indexOf(names(layout), "mileageplayerlist")
	same(layout.apps[i].placement.left, "100px", "shipped override placement")
end)

test("broken entries in mileage.uilayout.json are skipped and its player list still applies", function()
	local M = loadModule({
		[USER_DEFAULT .. "mileage.uilayout.json"] = {
			apps = {"junk", {placement = {left = "1px"}}, {appName = "mileageplayerlist", placement = {left = "777px"}}},
		},
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp1"}}},
	})
	M.migrateLayouts()
	local layout = written[USER_DEFAULT .. "career.uilayout.json"]
	local i = indexOf(names(layout), "mileageplayerlist")
	expect(i, "player list added")
	same(layout.apps[i].placement.left, "777px", "override placement")
end)

test("a mileage.uilayout.json whose apps is not a list leaves Mileage's defaults in charge", function()
	local M = loadModule({
		[USER_DEFAULT .. "mileage.uilayout.json"] = {apps = "not a list"},
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp1"}}},
	})
	M.migrateLayouts()
	local layout = written[USER_DEFAULT .. "career.uilayout.json"]
	local i = indexOf(names(layout), "mileageplayerlist")
	expect(i, "player list added")
	same(layout.apps[i].placement.top, "240px", "Mileage's default top")
end)

test("the Mileage prompts app is added beside the player list, once", function()
	local M = loadModule({
		[USER_DEFAULT .. "career.uilayout.json"] = savedCareerLayout(BUILD),
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp1"}}},
	})
	M.migrateLayouts()
	files[USER_DEFAULT .. "career.uilayout.json"] = written[USER_DEFAULT .. "career.uilayout.json"]
	M.migrateLayouts()
	local layout = written[USER_DEFAULT .. "career.uilayout.json"]
	local count, placement = 0, nil
	for _, app in ipairs(layout.apps) do
		if app.appName == "mileageoffers" then count, placement = count + 1, app.placement end
	end
	same(count, 1, "prompts app in the layout")
	same(placement.right, "305px", "beside the player list")
end)
