-- Race spots: the route list built from the game's West Coast route files, which the
-- server and every game share, and the places and prompt row a game adds for them.

local SERVER = "Resources/Server/Mileage/mileage.lua"
local CLIENT_ROUTES = "Resources/Client/Mileage/lua/ge/extensions/mileage/spotRoutes.lua"

local function readText(path)
	local f = assert(io.open(path, "r"))
	local text = f:read("*a")
	f:close()
	return text
end

-- The server's route list: the generated block of mileage.lua, evaluated on its own.
local function serverRoutes()
	local text = readText(SERVER)
	local block = text:match("%-%- BEGIN GENERATED SPOT ROUTES\n(.-)%-%- END GENERATED SPOT ROUTES")
	assert(block, "mileage.lua has no generated spot route block")
	local chunk = assert((loadstring or load)(block .. "\nreturn SPOT_ROUTES"))
	return chunk()
end

local function clientRoutes()
	return dofile(CLIENT_ROUTES).routes
end

local function byId(routes)
	local map = {}
	for _, route in ipairs(routes) do map[route.id] = route end
	return map
end

-- Deep equality of two plain values.
local function equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

-- The route without the walls, which only the game's copy carries.
local function withoutWalls(routes)
	local list = {}
	for i, route in ipairs(routes) do
		local copy = {}
		for k, v in pairs(route) do if k ~= "walls" then copy[k] = v end end
		list[i] = copy
	end
	return list
end

test("the server and the game list the same twelve routes", function()
	local server, client = serverRoutes(), clientRoutes()
	same(#server, 12, "server routes")
	same(#client, 12, "game routes")
	expect(equal(server, withoutWalls(client)), "the server's and the game's route lists differ")
end)

test("the game's routes carry the walls of their courses' barriers; the server's carry none", function()
	local routes = byId(clientRoutes())
	-- The rally track and the highway endurance run have no barriers in their prefabs.
	for id, route in pairs(routes) do
		if id == "rally_track" or id == "highway_endurance" then
			same(route.walls and #route.walls or 0, 0, id .. " has no walls")
		else
			expect(type(route.walls) == "table" and #route.walls > 0, id .. " has walls")
			for i, wall in ipairs(route.walls) do
				same(#wall, 4, id .. " wall " .. i .. " is x1, y1, x2, y2")
				local length = math.sqrt((wall[3] - wall[1]) ^ 2 + (wall[4] - wall[2]) ^ 2)
				-- A join is at most 4.5 m; the longest piece is a caution tape barricade's, 5.9 m.
				expect(length > 0 and length <= 6, id .. " wall " .. i .. " joins near neighbours only")
			end
		end
	end
	-- City Race 1: its 188 concrete barriers, caution tape and the forward prefab's pole fences.
	expect(#routes.city_race_1.walls >= 188, "a wall piece for every barrier")
	-- A barrier of City Race 1 (city_race_1.prefab, its first TSStatic) lies on a wall.
	local onWall = false
	for _, wall in ipairs(routes.city_race_1.walls) do
		local mx, my = (wall[1] + wall[3]) / 2, (wall[2] + wall[4]) / 2
		if math.abs(mx + 350.408) < 0.2 and math.abs(my - 307.84) < 0.2 then onWall = true end
	end
	expect(onWall, "the barrier at -350.4, 307.8 is the middle of a wall piece")
	for _, route in ipairs(serverRoutes()) do
		same(route.walls, nil, route.id .. ": the server's copy has no walls")
	end
end)

test("every route but the drag strip is a route, in ten spots", function()
	local routes = byId(clientRoutes())
	expect(routes.drag_race == nil, "the drag strip is not a race spot")
	local spots = {}
	for _, route in pairs(routes) do spots[route.spot] = true end
	local n = 0
	for _ in pairs(spots) do n = n + 1 end
	same(n, 10, "spots")
	for _, id in ipairs({"race_track", "race_track_short", "race_track_chicane"}) do
		same(routes[id].spot, "race_track", id .. " spot")
	end
	same(routes.race_track_alternative.spot, "race_track_alternative", "the alternative layout starts elsewhere")
	same(routes.city_race_1.spot, "city_race_1", "a route alone at its start is its own spot")
end)

test("checkpoints follow the game's order, finish line last, with laps and names", function()
	local routes = byId(clientRoutes())
	local short = routes.race_track_short
	same(#short.checkpoints, 12, "race track short checkpoints")
	same(short.laps, 2, "race track short laps")
	same(short.closed, true, "race track short is a circuit")
	same(short.name, "Race Track Short", "display name")
	-- Checkpoint_1 and Checkpoint_finish of race_track_short.prefab.
	local first, last = short.checkpoints[1], short.checkpoints[12]
	expect(math.abs(first.pos.x - 57.875) < 0.01 and math.abs(first.pos.y + 151.004) < 0.01, "first checkpoint")
	expect(math.abs(last.pos.x - 391.87) < 0.01 and math.abs(last.pos.y + 252.528) < 0.01, "finish line last")
	expect(math.abs(last.r - 12) < 0.01, "finish line radius from its scale")
	-- An open route runs once, whatever its file says.
	same(routes.cell_tower.closed, false, "cell tower is open")
	same(routes.cell_tower.laps, 1, "an open route is one lap")
	same(#routes.cell_tower.checkpoints, 6, "cell tower: five waypoints and the finish")
	-- City race 1 takes checkpoints from its _forward prefab too.
	same(#routes.city_race_1.checkpoints, 13, "city race 1 checkpoints")
end)

test("each route has a standing start facing its way and a length", function()
	for _, route in ipairs(clientRoutes()) do
		local g = route.grid
		expect(type(g.pos.x) == "number" and type(g.pos.z) == "number", route.id .. " start")
		local d = g.dir
		local length = math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
		expect(math.abs(length - 1) < 0.01, route.id .. " direction is a unit vector")
		expect(route.length > 500, route.id .. " length")
		for i, cp in ipairs(route.checkpoints) do
			expect(type(cp.pos.y) == "number" and cp.r > 0, route.id .. " checkpoint " .. i)
		end
	end
	-- A car at the start faces along the spawn's -Y: race_track_short's faces west, towards
	-- its first checkpoint, and highway_endurance's towards its own.
	local routes = byId(clientRoutes())
	expect(routes.race_track_short.grid.dir.x < -0.99, "race track short faces the first checkpoint")
	local endurance = routes.highway_endurance
	local cp = endurance.checkpoints[1].pos
	local dx, dy = cp.x - endurance.grid.pos.x, cp.y - endurance.grid.pos.y
	local cos = (dx * endurance.grid.dir.x + dy * endurance.grid.dir.y) / math.sqrt(dx * dx + dy * dy)
	expect(cos > 0.9, "highway endurance faces its first checkpoint")
	-- rally_track's prefab gives an axis and angle (z, 182.78 degrees) instead of a matrix.
	expect(routes.rally_track.grid.dir.y > 0.99, "rally track faces north")
end)

--== the places on the map and the prompt =========================================

local World = dofile("tests/money_world.lua")

local function places(world, p, level)
	local list = {}
	world:as(p, function() mileage_raceSpots.onGetRawPoiListForLevel(level or "west_coast_usa", list) end)
	return list
end

World.test("with race spots on, the map has a place with a mission marker at each of the ten spots", function(world)
	local ann = world:join("Ann", 1000, 0)
	local list = places(world, ann)
	same(#list, 10, "ten places")
	local byId = {}
	for _, place in ipairs(list) do byId[place.id] = place end
	local city = byId.mileageSpot_city_race_1
	expect(city, "City Race 1 is a place")
	same(city.clusterType, "missionMarker", "clustered like a mission")
	same(city.data.type, "mileageRaceSpot", "Mileage's own type")
	same(city.data.id, "mileageSpot_city_race_1", "the data names the place")
	same(city.data.spot, "city_race_1", "and the spot")
	local marker = city.markerInfo.missionMarker
	same(marker.radius, 6, "a 6 m marker")
	same(marker.icon, "mission_cup_triangle", "the race icon")
	local start = clientRoutes()[2].grid.pos
	expect(math.abs(marker.pos.x - start.x) < 0.01 and math.abs(marker.pos.y - start.y) < 0.01, "at the start line")
	same(city.markerInfo.bigmapMarker.name, "City Race 1", "named on the big map")
	same(city.markerInfo.bigmapMarker.description, "Race spot · 2 laps · 5.0 km", "laps and length")
	same(byId.mileageSpot_race_track.markerInfo.bigmapMarker.description, "Race spot · 2 laps · 8.1 km · 3 layouts",
		"the race track's layouts share one place")
	same(byId.mileageSpot_race_track_short, nil, "no second marker on the same start line")
	same(#places(world, ann, "italy"), 0, "no places on other levels")
end)

World.test("with race spots off there are no places, and a change clears the game's caches", function(world)
	local ann = world:join("Ann", 1000, 0)
	local clears = ann.poiClears
	same(clears >= 1, true, "the first status put the places on the map")
	world:setConfig("server", "allowSpotRaces", "false")
	same(#places(world, ann), 0, "no places")
	same(ann.poiClears, clears + 1, "the place list is built again")
	same(ann.markerClears >= 2, true, "and the markers")
	world:setConfig("server", "spotRacePrize", "500")
	same(ann.poiClears, clears + 1, "a status that changes nothing for the map clears nothing")
	world:setConfig("server", "allowSpotRaces", "true")
	same(#places(world, ann), 10, "back on the map")
	same(ann.poiClears, clears + 2, "built again")
end)

World.test("the prompt at a spot has a Set up race row that opens the set-up card", function(world)
	local ann = world:join("Ann", 1000, 0)
	world:join("Bob", 1000, 1)
	local rows = {}
	world:as(ann, function()
		mileage_raceSpots.onActivityAcceptGatherData({{type = "mission", missionId = "x"},
			{type = "mileageRaceSpot", id = "mileageSpot_race_track", spot = "race_track"}}, rows)
	end)
	same(#rows, 1, "one row, for the race spot only")
	same(rows[1].heading, "Race Track", "the spot's name")
	same(rows[1].preheadings[1], "Race spot", "called a race spot")
	same(rows[1].buttonLabel, "Set up race", "the button")
	world:as(ann, function() rows[1].buttonFun() end)
	world:pump()
	same(ann.promptCloses, 1, "the game's prompt closes")
	local cards = world:ui(ann, "MileageSpotRace")
	local card = cards[#cards]
	same(card.phase, "setup", "the set-up card opens")
	same(card.spot, "race_track", "for the race track")
	same(#card.routes, 3, "with its three layouts")
	same(card.routes[1].id, "race_track", "the full track first")
	same(card.opponentsMax, 5, "up to five opponents")
	same(#card.players, 1, "the other player to invite")
	same(card.players[1].name, "Bob", "Bob")
	same(card.players[1].busy, false, "not busy")
end)
