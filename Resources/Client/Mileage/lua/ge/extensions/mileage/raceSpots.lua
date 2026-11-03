--Mileage :: race spots on the big map and the road (CLIENT)
--
-- The game asks every extension for its places on a level (onGetRawPoiListForLevel) and
-- builds both the big map's markers and the markers on the road from them. This adds one
-- place per race spot (mileage/spotRoutes.lua, the start of each of the game's West Coast
-- routes but the drag strip), with the look of a mission marker. Stopping in one opens the
-- game's prompt, which asks every extension for its rows (onActivityAcceptGatherData):
-- this adds "Set up race", which opens the set-up card in the prompts app
-- (mileage_spotRace.openSetup). The game's own rules for hiding places (before the first
-- car is bought, in a test drive or the tutorial) apply to these too.
--
-- Nothing is added until the server says race spots are on (status from mileage/spotRace);
-- a change clears the game's place and marker caches so the map follows at once.

local M = {}

local logTag = "mileage.raceSpots"

local LEVEL = "west_coast_usa"
local TYPE = "mileageRaceSpot"
local ICON = "mission_cup_triangle"
local RADIUS = 6

-- Whether places were last built with race spots on, to clear the caches on a change.
local shownAllowed = false

local function spotRace()
	local s = extensions.mileage_spotRace
	if type(s) == "table" then return s end
	return nil
end

local function routes()
	local r = extensions.mileage_spotRoutes
	if type(r) == "table" and type(r.routes) == "table" then return r.routes end
	return {}
end

local function allowed()
	local s = spotRace()
	local status = s and s.getStatus()
	return status ~= nil and status.known and status.allowed
end

-- Each spot once, by the route that names it, with every route that starts there.
local function spots()
	local list, byId = {}, {}
	for _, route in ipairs(routes()) do
		local spot = byId[route.spot]
		if not spot then
			spot = {id = route.spot, routes = {}}
			byId[route.spot] = spot
			table.insert(list, spot)
		end
		table.insert(spot.routes, route)
		if route.id == route.spot then spot.main = route end
	end
	for _, spot in ipairs(list) do spot.main = spot.main or spot.routes[1] end
	return list, byId
end

local function km(metres)
	return string.format("%.1f km", (tonumber(metres) or 0) / 1000)
end

local function describe(spot)
	if #spot.routes > 1 then return string.format("Race spot · %d layouts", #spot.routes) end
	local route = spot.main
	return string.format("Race spot · %d lap%s · %s", route.laps, route.laps == 1 and "" or "s", km(route.length))
end

--- The game's places on a level: one per race spot on West Coast, while race spots are on.
function M.onGetRawPoiListForLevel(levelIdentifier, elements)
	if levelIdentifier ~= LEVEL or type(elements) ~= "table" or not allowed() then return end
	for _, spot in ipairs((spots())) do
		local grid = spot.main.grid
		local pos = vec3(grid.pos.x, grid.pos.y, grid.pos.z)
		local rot = quatFromDir(vec3(grid.dir.x, grid.dir.y, grid.dir.z), vec3(0, 0, 1))
		local id = "mileageSpot_" .. spot.id
		table.insert(elements, {
			id = id,
			data = {type = TYPE, id = id, spot = spot.id},
			clusterType = "missionMarker",
			markerInfo = {
				missionMarker = {pos = pos, rot = rot, radius = RADIUS, icon = ICON},
				bigmapMarker = {pos = pos, icon = ICON, name = spot.main.name, description = describe(spot)},
			},
		})
	end
end

--- The game's prompt at a marker: a "Set up race" row for a race spot.
function M.onActivityAcceptGatherData(elemData, activityData)
	if type(elemData) ~= "table" or type(activityData) ~= "table" then return end
	local _, byId = spots()
	for _, elem in ipairs(elemData) do
		local spot = type(elem) == "table" and elem.type == TYPE and byId[elem.spot]
		if spot then
			local props = {{icon = "ui_icons_distance", keyLabel = "Route", valueLabel = describe(spot):gsub("^Race spot · ", "")}}
			table.insert(activityData, {
				icon = ICON,
				heading = spot.main.name,
				preheadings = {"Race spot"},
				props = props,
				buttonLabel = "Set up race",
				buttonFun = function()
					local s = spotRace()
					if s then s.openSetup(spot.id) end
					if ui_missionInfo and type(ui_missionInfo.closeDialogue) == "function" then
						pcall(ui_missionInfo.closeDialogue)
					end
				end,
				sorting = {type = TYPE, id = spot.id},
			})
		end
	end
end

-- The game keeps its places and markers until told to build them again.
local function clearCaches()
	if gameplay_rawPois and type(gameplay_rawPois.clear) == "function" then pcall(gameplay_rawPois.clear) end
	if gameplay_markerInteraction and type(gameplay_markerInteraction.clearCache) == "function" then
		pcall(gameplay_markerInteraction.clearCache)
	end
end

--- The server's status arrived (mileage/spotRace): the places follow when race spots were
--- switched on or off.
function M.statusChanged()
	local now = allowed() == true
	if now == shownAllowed then return end
	shownAllowed = now
	clearCaches()
	log("I", logTag, now and "race spots shown on the map" or "race spots taken off the map")
end

function M.onBeamMPServerLeave()
	if shownAllowed then
		shownAllowed = false
		clearCaches()
	end
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
