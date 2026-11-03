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

test("the server and the game list the same twelve routes", function()
	local server, client = serverRoutes(), clientRoutes()
	same(#server, 12, "server routes")
	same(#client, 12, "game routes")
	expect(equal(server, client), "the server's and the game's route lists differ")
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
