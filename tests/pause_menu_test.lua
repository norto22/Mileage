-- #15: in a Mileage career the 0.40 pause menu offers no Mods entry, and its time,
-- weather, simulation and traffic pages stay read-only even with the game's "restrict
-- scenarios" option off. Outside a career the menu is the game's own.
--
-- Loads the real mileage/patches.lua with stand-ins shaped like the game's pause modules:
-- ui/pause/actions.lua's registerButton skips a button whose visible is false (:10-13),
-- and ui/pause/providers/routeData/environment.lua's pages are editable in freeroam or
-- with "restrict scenarios" off (:12-14). The pause modules load only when the menu
-- first opens, through extensions.load.

local PATCHES = "Resources/Client/Mileage/lua/ge/extensions/mileage/patches.lua"
local PAUSE_ACTIONS = "ui_pause_actions"
local PAUSE_ENVIRONMENT = "ui_pause_providers_routeData_environment"

local game, logs

local function installPauseModules()
	ui_pause_actions = {registerButton = function(metadata, callback)
		if metadata.visible == false then return metadata end
		table.insert(game.buttons, metadata.id)
		return metadata
	end}
	local function editable(context)
		return context.mode == "freeroam" or context.mode == "multiplayer"
			or not settings.getValue("restrictScenarios", true)
	end
	ui_pause_providers_routeData_environment = {
		getEnvironmentData = function(context) return {actionState = {enabled = editable(context)}} end,
		getEnvironmentWeatherData = function(context) return {editable = editable(context)} end,
		getEnvironmentSimulationData = function(context) return {editable = editable(context)} end,
		getEnvironmentTrafficData = function(context)
			if game.trafficRaises then error("traffic page broke") end
			return {editable = editable(context)}
		end,
		requestEnvironmentTrafficPayload = function(payload) return {editable = payload.editable ~= false} end,
	}
end

-- A game in a career (o.career = false: none) with "restrict scenarios" switched off and
-- the pause modules loaded (o.pauseLoaded = false: not yet).
local function setup(o)
	o = o or {}
	logs = {}
	game = {career = o.career ~= false, settings = {restrictScenarios = false}, buttons = {}, writes = 0}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. tostring(msg)) end
	function setExtensionUnloadMode() end
	deepcopy = deepcopy or function(t)
		local r = {}
		for k, v in pairs(t) do r[k] = v end
		return r
	end
	settings = {
		getValue = function(key, default)
			local v = game.settings[key]
			if v == nil then return default end
			return v
		end,
		setValue = function() game.writes = game.writes + 1 end,
	}
	game.getValue = settings.getValue
	career_career = {isActive = function() return game.career end}
	ui_pause_actions, ui_pause_providers_routeData_environment = nil, nil
	extensions = {load = function(name)
		if name == PAUSE_ACTIONS or name == PAUSE_ENVIRONMENT then installPauseModules() end
	end}
	if o.pauseLoaded ~= false then installPauseModules() end
	return dofile(PATCHES)
end

-- The system rail's buttons as the game builds it, by id.
local function systemRail()
	game.buttons = {}
	for _, id in ipairs({"system.settings", "system.mods", "system.hudApps", "system.stats"}) do
		ui_pause_actions.registerButton({id = id, visible = true, enabled = true}, function() end)
	end
	return table.concat(game.buttons, ",")
end

local ALL_BUTTONS = "system.settings,system.mods,system.hudApps,system.stats"
local NO_MODS = "system.settings,system.hudApps,system.stats"

-- Whether each environment page is editable in career mode: time and weather overview,
-- weather, simulation, traffic, and the traffic panel's controls.
local function environment()
	local env = ui_pause_providers_routeData_environment
	local context = {mode = "career"}
	return table.concat({
		tostring(env.getEnvironmentData(context).actionState.enabled),
		tostring(env.getEnvironmentWeatherData(context).editable),
		tostring(env.getEnvironmentSimulationData(context).editable),
		tostring(env.getEnvironmentTrafficData(context).editable),
		tostring(env.requestEnvironmentTrafficPayload({editable = true}).editable),
	}, " ")
end

local READ_ONLY = "false false false false false"
local EDITABLE = "true true true true true"

test("#15: in a Mileage career the pause menu has no Mods entry and the environment is read-only", function()
	local patches = setup()
	patches.apply()
	same(systemRail(), NO_MODS, "system buttons in a career")
	same(environment(), READ_ONLY, "environment pages with restrict scenarios off")
end)

test("#15: pause modules that load after the career started are patched before their first use", function()
	local patches = setup({pauseLoaded = false})
	patches.apply()
	extensions.load(PAUSE_ACTIONS)
	same(systemRail(), NO_MODS, "system buttons on the first open")
	same(environment(), READ_ONLY, "environment pages on the first open")
end)

test("#15: the pause modules not being loaded is not a patch failure", function()
	local patches = setup({pauseLoaded = false})
	patches.apply()
	for _, name in ipairs(patches.getFailures()) do
		expect(not name:find("ui_pause", 1, true) and not name:find("extensions.load", 1, true),
			"listed as a failure: " .. name)
	end
end)

test("#15: outside a career, and after the patches are reverted, the menu is the game's own", function()
	local patches = setup({career = false})
	patches.apply()
	same(systemRail(), ALL_BUTTONS, "system buttons with no career")
	same(environment(), EDITABLE, "environment pages with no career")
	game.career = true
	same(systemRail(), NO_MODS, "system buttons once the career is active")
	patches.revert()
	same(systemRail(), ALL_BUTTONS, "system buttons after the revert")
	same(environment(), EDITABLE, "environment pages after the revert")
	extensions.load(PAUSE_ACTIONS)
	same(systemRail(), ALL_BUTTONS, "system buttons of a module loaded after the revert")
end)

test("#15: the player's restrict scenarios setting is read as it is and never written", function()
	local patches = setup()
	patches.apply()
	environment()
	same(settings.getValue, game.getValue, "settings.getValue after the pages ran")
	same(settings.getValue("restrictScenarios", true), false, "the player's setting")
	game.trafficRaises = true
	local ok, err = pcall(ui_pause_providers_routeData_environment.getEnvironmentTrafficData, {mode = "career"})
	same(ok, false, "a page that raises still raises")
	expect(tostring(err):find("traffic page broke", 1, true), "its error: " .. tostring(err))
	same(settings.getValue, game.getValue, "settings.getValue after a page raised")
	same(game.writes, 0, "settings written")
end)

test("#15: freeroam in the pause menu is untouched by the career check", function()
	local patches = setup()
	patches.apply()
	same(ui_pause_providers_routeData_environment.getEnvironmentWeatherData({mode = "freeroam"}).editable, true,
		"weather in freeroam mode")
end)

test("#15: applying twice wraps the pause modules once", function()
	local patches = setup()
	local gameRegister, gameLoad = ui_pause_actions.registerButton, extensions.load
	patches.apply()
	local register, load = ui_pause_actions.registerButton, extensions.load
	expect(register ~= gameRegister, "registerButton patched")
	patches.apply()
	same(ui_pause_actions.registerButton == register, true, "registerButton after a second apply")
	same(extensions.load == load, true, "extensions.load after a second apply")
	patches.revert()
	same(ui_pause_actions.registerButton == gameRegister, true, "registerButton after one revert")
	same(extensions.load == gameLoad, true, "extensions.load after one revert")
	same(systemRail(), ALL_BUTTONS, "system buttons after one revert")
end)
