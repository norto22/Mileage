-- Races at race spots: the server's request checks and phases (invites, grid, countdown,
-- racing, result), its own timing of every racer from its readings of their cars, the
-- racer's game on the grid and its own checkpoints, the starter's opponents, the prize and
-- the spot times on the leaderboard.

local World = dofile("tests/money_world.lua")
local ROUTES = dofile("Resources/Client/Mileage/lua/ge/extensions/mileage/spotRoutes.lua").routes

local function route(id)
	for _, r in ipairs(ROUTES) do
		if r.id == id then return r end
	end
	error("no route " .. id)
end

local function copy(p) return {x = p.x, y = p.y, z = p.z} end

local function send(world, p, fields)
	world:queue({way = "toServer", from = p.id, name = "mileageSpotRace", data = World.encode(fields)})
	world:pump()
end

-- The rxMileageSpotRace messages the server sent p, of phase.
local function heard(world, p, phase)
	local found = {}
	for _, m in ipairs(world:received(p, "rxMileageSpotRace")) do
		if m.phase == phase then table.insert(found, m) end
	end
	return found
end

local function last(world, p, phase)
	local found = heard(world, p, phase)
	return found[#found]
end

local function metres(a, b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

-- p's car standing on routeId's start line.
local function atStart(p, routeId)
	p.car.pos = copy(route(routeId).grid.pos)
end

local function request(world, p, routeId, opponents, invite)
	send(world, p, {request = {route = routeId, opponents = opponents or 0, invite = invite or {}}})
end

-- Each player says ready, as its game does once its car is on the grid.
local function ready(world, players)
	for _, p in ipairs(players) do
		local grid = last(world, p, "grid")
		if grid then send(world, p, {ready = {race = grid.id}}) end
	end
end

-- Advances until the server sent p a message of phase, at most limit seconds.
local function untilPhase(world, p, phase, limit)
	local before = #heard(world, p, phase)
	for _ = 1, limit or 60 do
		if #heard(world, p, phase) > before then return true end
		world:advance(1)
	end
	return #heard(world, p, phase) > before
end

-- Drives p's car in a straight line to target, speed metres each second.
local function driveTo(world, p, target, speed)
	speed = speed or 40
	while true do
		local from = p.car.pos
		local left = metres(from, target)
		if left < 0.01 then return end
		local step = math.min(left, speed)
		local s = step / left
		expect(world:drive(p, from.x + (target.x - from.x) * s, from.y + (target.y - from.y) * s,
			from.z + (target.z - from.z) * s), p.name .. "'s car is free to drive")
		world:advance(1)
	end
end

-- Drives p's car through every checkpoint of the route, every lap. skip: a checkpoint it
-- goes round, 300 m to the side.
local function driveRoute(world, p, r, speed, skip)
	for _ = 1, r.laps do
		for i, checkpoint in ipairs(r.checkpoints) do
			if i == skip then
				local c = checkpoint.pos
				driveTo(world, p, {x = c.x - r.grid.dir.y * 300, y = c.y + r.grid.dir.x * 300, z = c.z}, speed)
			else
				driveTo(world, p, checkpoint.pos, speed)
			end
		end
	end
end

-- A race started at the highway race spot, alone, up to its green.
local function soloToGreen(world, p, routeId)
	routeId = routeId or "highway_race"
	atStart(p, routeId)
	request(world, p, routeId, 0, {})
	ready(world, {p})
	expect(last(world, p, "countdown"), "the countdown started")
	world:advance(6)
end

local function standingsRow(world, p, name)
	local s = last(world, p, "standings")
	for _, row in ipairs(s and s.rows or {}) do
		if row.name == name then return row end
	end
	return nil
end

--== the request and its phases ===================================================

World.test("a solo run: a grid place behind the start facing the route, a countdown, the server's time", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 0, {})
	local grid = last(world, ann, "grid")
	expect(grid, "Ann was given a grid place")
	same(grid.route, "highway_race", "the route")
	expect(metres(grid.pose.pos, r.grid.pos) < 5, "the grid place is at the start line")
	expect(math.abs(grid.pose.dir.x - r.grid.dir.x) < 0.01 and math.abs(grid.pose.dir.y - r.grid.dir.y) < 0.01,
		"facing the way the start faces")
	same(#grid.opponentPoses, 0, "no opponents asked for")
	ready(world, {ann})
	local countdown = last(world, ann, "countdown")
	expect(countdown, "the countdown starts once everyone is ready")
	same(countdown.seconds, 5, "five seconds")
	world:advance(6)
	local startedAt = world.now
	driveRoute(world, ann, r, 40)
	world:advance(1)
	local result = last(world, ann, "result")
	expect(result, "the result came at the finish")
	same(result.places[1].name, "Ann", "Ann has the only place")
	local seconds = result.places[1].seconds
	expect(seconds > 0 and seconds <= world.now - startedAt + 6, "the server's own time, from its green")
	same(result.withheld, "alone", "nobody else raced, so no prize")
	same(result.prize, 0, "nothing paid")
	same(result.ranked, true, "the server followed the race")
	local board = world:dataFile("leaderboard.json")
	same(board and board.wins and board.wins.Ann, nil, "a run alone is no race win")
end)

World.test("each refused request says why", function(world)
	local ann = world:join("Ann", 1000, 0)
	local bob = world:join("Bob", 1000, 1)
	local function refused(fields)
		send(world, ann, {request = fields})
		local m = last(world, ann, "refused")
		return m and m.why
	end
	atStart(ann, "highway_race")
	same(refused({route = "nowhere", opponents = 0}), "That race spot is not on this server.", "unknown route")
	same(refused({route = "drag_race", opponents = 0}), "That race spot is not on this server.", "the drag strip")
	same(refused({route = "highway_race\n", opponents = 0}), "That race spot is not on this server.", "odd text")
	same(refused({route = "highway_race", opponents = 6}), "This server allows fewer opponents.", "six opponents")
	same(refused({route = "highway_race", opponents = 1.5}), "This server allows fewer opponents.", "half an opponent")
	world:setConfig("server", "spotRaceOpponentsMax", "2")
	same(refused({route = "highway_race", opponents = 3}), "This server allows fewer opponents.", "above the owner's max")
	same(refused({route = "highway_race", opponents = 0,
		invite = {"a", "b", "c", "d", "e", "f", "g", "h"}}), "Invite at most 7 players.", "eight invites")
	same(refused({route = "highway_race", opponents = 0, invite = {"Nobody"}}),
		"A player you invited cannot race now.", "a player not on the server")
	same(refused({route = "highway_race", opponents = 0, invite = {"Ann"}}),
		"A player you invited cannot race now.", "inviting yourself")
	ann.car.pos = {x = 0, y = 0, z = 0}
	same(refused({route = "highway_race", opponents = 0}), "Drive into the start marker first.", "far from the start")
	world:setConfig("server", "allowSpotRaces", "false")
	atStart(ann, "highway_race")
	same(refused({route = "highway_race", opponents = 0}), "Race spots are off on this server.", "switched off")
	world:setConfig("server", "allowSpotRaces", "true")
	-- Bob's race at the spot is still on the grid: the spot is taken.
	atStart(bob, "highway_race")
	request(world, bob, "highway_race", 0, {})
	same(refused({route = "highway_race", opponents = 0}), "A race is starting at this spot; try again in a moment.",
		"another race on the grid here")
	same(#heard(world, ann, "grid"), 0, "no refused request reached the grid")
end)

World.test("a player in a spot race is busy for another race, an invite and a street race challenge", function(world)
	local ann = world:join("Ann", 1000, 0)
	local bob = world:join("Bob", 1000, 1)
	soloToGreen(world, ann)
	atStart(ann, "cell_tower")
	request(world, ann, "cell_tower", 0, {})
	same(last(world, ann, "refused").why, "You are already in a race.", "a second race")
	atStart(bob, "cell_tower")
	request(world, bob, "cell_tower", 0, {"Ann"})
	same(last(world, bob, "refused").why, "A player you invited cannot race now.", "Ann cannot be invited")
	world:queue({way = "toServer", from = bob.id, name = "mileageOffer", data = World.encode({kind = "race",
		to = ann.id, amount = 0, start = {x = 0, y = 0, z = 0}, finish = {x = 0, y = 3000, z = 0}})})
	world:pump()
	local closed = world:received(bob, "rxMileageOfferClosed")
	expect(#closed > 0 and closed[#closed].why == "busy", "the challenge is refused as busy")
	local status = last(world, bob, "status")
	send(world, bob, {status = true})
	status = last(world, bob, "status")
	same(status.busy[1], "Ann", "the set-up card shows Ann as busy")
end)

World.test("the starter's Give up before the green calls the race off; after it, it ends their run", function(world)
	local ann = world:join("Ann", 1000, 0)
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 0, {})
	expect(last(world, ann, "countdown"), "Ann's game put her car on the grid and said ready")
	world:advance(2)
	world:as(ann, function() expect(mileage_spotRace.giveUp(), "Give up pressed in the countdown") end)
	world:pump()
	same(last(world, ann, "closed").why, "The starter gave up.", "called off")
	same(ann.car.frozen, false, "Ann's car is released")
	world:advance(6)
	same(#heard(world, ann, "standings"), 0, "no race for a race called off")
	soloToGreen(world, ann, "cell_tower")
	id = last(world, ann, "countdown").id
	send(world, ann, {gaveUp = id})
	world:advance(1)
	local result = last(world, ann, "result")
	expect(result, "the race ended")
	same(result.places[1].out, "gaveUp", "Ann gave up")
	same(result.winner, nil, "no winner")
end)

World.test("the starter's car not ready on the grid in 20 seconds calls the race off", function(world)
	local ann = world:join("Ann", 1000, 0)
	atStart(ann, "highway_race")
	-- Ann's game never answers the grid.
	world.filter = function(m)
		if m.way == "toServer" and m.name == "mileageSpotRace" and not m.data:find("request", 1, true) then return "drop" end
	end
	request(world, ann, "highway_race", 0, {})
	world:advance(19)
	same(#heard(world, ann, "closed"), 0, "still waiting at 19 s")
	world:advance(2)
	same(last(world, ann, "closed").why, "The starter's car was not ready.", "called off")
	same(#heard(world, ann, "countdown"), 0, "no countdown")
end)

World.test("a starter whose car cannot be moved to the grid leaves the race at once", function(world)
	local ann = world:join("Ann", 1000, 0)
	atStart(ann, "highway_race")
	ann.inCar = false
	request(world, ann, "highway_race", 0, {})
	same(last(world, ann, "closed").why, "The starter gave up.", "called off")
	local card = world:ui(ann, "MileageSpotRace")
	same(card[#card].phase, "closed", "the card says why")
end)

World.test("the time limit ends a race nobody finished, with no winner", function(world)
	local ann = world:join("Ann", 1000, 0)
	world:setConfig("server", "raceTimeLimitMinutes", "1")
	soloToGreen(world, ann)
	world:advance(61)
	local result = last(world, ann, "result")
	expect(result, "the race ended")
	same(result.why, "timeout", "at the time limit")
	same(result.winner, nil, "no winner")
	same(result.places[1].seconds, nil, "no time")
end)

World.test("status tells each game the owner's settings, and SetConfig sends it again", function(world)
	local ann = world:join("Ann", 1000, 0)
	local status = last(world, ann, "status")
	expect(status, "a status on career start")
	same(status.allowed, true, "on by default")
	same(status.prize, 0, "no prize by default")
	same(status.opponentsMax, 5, "five opponents")
	world:setConfig("server", "spotRacePrize", "2000")
	same(last(world, ann, "status").prize, 2000, "the new prize")
	world:setConfig("server", "spotRaceOpponentsMax", "9")
	same(last(world, ann, "status").opponentsMax, 5, "clamped to five")
end)

--== the server's own timing ======================================================

World.test("a car at 80 m/s whose readings fall 40 m either side of a checkpoint passes it", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	soloToGreen(world, ann)
	local cp = r.checkpoints[1].pos
	local g = r.grid.pos
	local d = metres(g, cp)
	local ux, uy, uz = (cp.x - g.x) / d, (cp.y - g.y) / d, (cp.z - g.z) / d
	driveTo(world, ann, {x = cp.x - ux * 40, y = cp.y - uy * 40, z = cp.z - uz * 40}, 30)
	same(standingsRow(world, ann, "Ann").passed, 0, "not passed 40 m short")
	driveTo(world, ann, {x = cp.x + ux * 40, y = cp.y + uy * 40, z = cp.z + uz * 40}, 80)
	world:advance(1)
	same(standingsRow(world, ann, "Ann").passed, 1, "passed between two readings")
end)

World.test("a car that skips a checkpoint does not finish, and a teleport passes none", function(world)
	local ann = world:join("Ann", 1000, 0)
	world:setConfig("server", "raceTimeLimitMinutes", "2")
	local r = route("highway_race")
	soloToGreen(world, ann)
	driveRoute(world, ann, r, 40, 2)
	world:advance(1)
	same(standingsRow(world, ann, "Ann").passed, 1, "stuck at the skipped checkpoint")
	-- Thrown straight to the finish in one second: too far to drive, so nothing passes.
	local finish = r.checkpoints[#r.checkpoints].pos
	ann.car.pos = copy(r.checkpoints[2].pos)
	world:advance(1)
	same(standingsRow(world, ann, "Ann").passed, 1, "a teleport passes no checkpoint")
	expect(metres(ann.car.pos, finish) > 100, "not at the finish")
	world:advance(130)
	local result = last(world, ann, "result")
	same(result.why, "timeout", "the race ran out of time")
	same(result.places[1].seconds, nil, "no finish")
end)

World.test("a game's finish report never decides: 0.1 s after green from a standing car counts for nothing", function(world)
	local ann = world:join("Ann", 1000, 0)
	world:setConfig("server", "raceTimeLimitMinutes", "1")
	soloToGreen(world, ann)
	local id = last(world, ann, "countdown").id
	send(world, ann, {finished = {race = id, racer = "Ann", seconds = 0.1}})
	world:advance(2)
	send(world, ann, {finished = {race = id, racer = "Ann", seconds = 3}})
	world:advance(1)
	same(last(world, ann, "result"), nil, "a reported finish ends nothing the server can see")
	world:advance(60)
	local result = last(world, ann, "result")
	same(result.places[1].seconds, nil, "no time for a car that never moved")
	same(result.winner, nil, "no winner")
	local board = world:dataFile("leaderboard.json")
	same(board and board.spots, nil, "no time kept")
end)

World.test("a race the server cannot read is shown, unranked: no win, no time kept", function(world)
	local ann = world:join("Ann", 1000, 0)
	world.hidePositions = true
	soloToGreen(world, ann)
	local id = last(world, ann, "countdown").id
	world:advance(60)
	send(world, ann, {finished = {race = id, racer = "Ann", seconds = 60}})
	world:advance(1)
	local result = last(world, ann, "result")
	expect(result, "the race ended on the game's report")
	same(result.ranked, false, "unranked")
	same(result.withheld, "unseen", "no prize: the server could not follow it")
	same(result.places[1].seconds, 60, "the game's time is shown")
	local board = world:dataFile("leaderboard.json")
	same(board and board.wins and board.wins.Ann, nil, "no win")
	same(board and board.spots, nil, "no time kept")
end)

World.test("standings each second show laps, checkpoints and the racer's progress", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("rally_track")
	soloToGreen(world, ann, "rally_track")
	for i = 1, 3 do driveTo(world, ann, r.checkpoints[i].pos, 40) end
	world:advance(1)
	local row = standingsRow(world, ann, "Ann")
	same(row.passed, 3, "three checkpoints")
	same(row.lap, 1, "first lap")
	same(row.checkpoint, 3, "checkpoint 3 of the lap")
	for i = 4, #r.checkpoints do driveTo(world, ann, r.checkpoints[i].pos, 40) end
	driveTo(world, ann, r.checkpoints[1].pos, 40)
	world:advance(1)
	row = standingsRow(world, ann, "Ann")
	same(row.lap, 2, "second lap")
	same(row.checkpoint, 1, "first checkpoint of it")
end)

--== the racer's game ============================================================

-- Messages p's game sent the server under mileageSpotRace with this key.
local function sentKey(world, p, key)
	local found = {}
	for _, m in ipairs(world.serverLog) do
		if m.from == p.id and m.name == "mileageSpotRace" then
			local decoded = World.decode(m.data)
			if decoded[key] ~= nil then table.insert(found, decoded[key]) end
		end
	end
	return found
end

local function lastCard(world, p, phase)
	local found = nil
	for _, m in ipairs(world:ui(p, "MileageSpotRace")) do
		if not phase or m.phase == phase then found = m end
	end
	return found
end

World.test("the racer's game moves its car to the grid, holds it for the count and releases it on green", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	ann.car.pos = {x = r.grid.pos.x + 20, y = r.grid.pos.y, z = r.grid.pos.z}
	request(world, ann, "highway_race", 0, {})
	local pose = last(world, ann, "grid").pose
	same(#ann.teleports, 1, "moved once")
	expect(metres(ann.car.pos, pose.pos) < 0.01, "on its grid place")
	same(ann.car.dir.x, pose.dir.x, "facing the route")
	same(ann.car.frozen, true, "held on the grid")
	same(#sentKey(world, ann, "ready"), 1, "said ready")
	same(lastCard(world, ann).phase, "countdown", "the countdown shows")
	world:advance(3)
	same(ann.car.frozen, true, "still held in the count")
	world:advance(3)
	same(ann.car.frozen, false, "released on green")
	same(lastCard(world, ann).phase, "racing", "the race panel shows")
	world:as(ann, function()
		same(mileage_streetRace.eligibility(), "You are already in a race.", "street races see the spot race")
	end)
end)

World.test("each checkpoint pass sends progress, the last one the finish, and nothing goes through street races", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("rally_track")
	-- The server cannot read the car here, so it waits for the game's own reports (a server
	-- that reads the finish first sends the result before the game's last report).
	world.hidePositions = true
	soloToGreen(world, ann, "rally_track")
	driveRoute(world, ann, r, 40)
	world:advance(1)
	local progress = sentKey(world, ann, "progress")
	same(#progress, #r.checkpoints * r.laps, "one report per checkpoint, every lap")
	same(progress[1].checkpoint, 1, "checkpoint 1 first")
	same(progress[#progress].lap, 2, "the second lap last")
	same(progress[#progress].racer, "Ann", "for Ann")
	local finished = sentKey(world, ann, "finished")
	same(#finished, 1, "one finish")
	local result = last(world, ann, "result")
	same(result.places[1].seconds, finished[1].seconds, "shown with the game's time, unranked")
	local reports = 0
	for _, m in ipairs(world.serverLog) do
		if m.name == "mileageRaceReport" or m.name == "mileageOffer" then reports = reports + 1 end
	end
	same(reports, 0, "nothing sent as a street race")
	same(lastCard(world, ann).phase, "result", "the result shows")
	world:as(ann, function() same(mileage_spotRace.inRace(), false, "the race is over here") end)
end)

World.test("a car off the route for 10 seconds is out, and its race ends", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	soloToGreen(world, ann)
	local g = r.grid.pos
	driveTo(world, ann, {x = g.x - r.grid.dir.y * 1500, y = g.y + r.grid.dir.x * 1500, z = g.z}, 80)
	world:advance(11)
	local out = sentKey(world, ann, "out")
	same(#out, 1, "out sent once")
	same(out[1].why, "left", "left the route")
	local result = last(world, ann, "result")
	expect(result, "the race ended")
	same(result.places[1].out, "left", "listed as left the route")
end)

--== the starter's opponents ======================================================

-- A road node at each checkpoint of the route, named cp1, cp2, ...
local function roadsAt(world, r)
	world.roadNodes = {}
	for i, checkpoint in ipairs(r.checkpoints) do world.roadNodes["cp" .. i] = {pos = copy(checkpoint.pos)} end
end

-- The game's class lookup and class grouping on p's game: class B, two cars, push 0.8.
local function withClass(p)
	p.globals.gameplay_vehiclePerformance = {getClassFromVehId = function(vid)
		p.classAskedFor = vid
		return {class = {name = "B"}, performanceIndex = 52}
	end}
	p.globals.career_modules_vehicleClassGrouping = {
		generateGroup = function(class, _, _, _, _, _, _, _, index)
			p.groupAsked = {class = class, index = index}
			return {data = {{model = "pessima", config = "base_M"}, {model = "etk800", config = "sport_A"}}}
		end,
		getAggressionMultiplier = function(class) return class == "B" and 0.8 or 1 end,
	}
end

local function spawned(world, p)
	local list = {}
	for _, s in pairs(world.spawned) do
		if s.owner == p then table.insert(list, s) end
	end
	table.sort(list, function(a, b) return a.vid < b.vid end)
	return list
end

World.test("two opponents are cars of the starter's class on the next grid places, held, marked and listed", function(world)
	local ann = world:join("Ann", 1000, 0)
	withClass(ann)
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 2, {})
	local grid = last(world, ann, "grid")
	same(#grid.opponentPoses, 2, "two opponent places")
	same(ann.classAskedFor, ann.car.id, "the class of the car Ann drives")
	same(ann.groupAsked.class, "B", "a group of class B")
	same(ann.groupAsked.index, 52, "near its performance index")
	local cars = spawned(world, ann)
	same(#cars, 2, "two cars spawned")
	same(cars[1].car.JBeam, "pessima", "the group's first car")
	same(cars[1].car.config, "base_M", "with its config")
	same(cars[2].car.JBeam, "etk800", "the group's second car")
	for i, s in ipairs(cars) do
		expect(metres(s.car.pos, grid.opponentPoses[i].pos) < 0.01, "opponent " .. i .. " on its grid place")
		same(s.car.dir.x, grid.opponentPoses[i].dir.x, "facing the route")
		same(s.car.frozen, true, "held on the grid")
		same(s.car.mileageSpotRacer, "true", "marked as a race spot opponent")
	end
	same(world.spawnRequests[1].opts.autoEnterVehicle, false, "the player stays in their own car")
	local ready = sentKey(world, ann, "ready")
	same(#ready, 1, "ready once")
	same(#ready[1].opponents, 2, "both listed")
	same(ready[1].opponents[1].car, cars[1].sid, "by server vehicle id")
	same(ready[1].opponents[1].model, "Ibishu Pessima", "named by model")
	local countdown = last(world, ann, "countdown")
	same(#countdown.racers, 3, "three racers on the grid")
	same(countdown.racers[2].name, "Ibishu Pessima", "the first opponent by its model")
	same(countdown.racers[2].car, true, "a car")
end)

World.test("at green each opponent drives the checkpoints' road nodes for every lap at its class's push", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("rally_track")
	roadsAt(world, r)
	withClass(ann)
	atStart(ann, "rally_track")
	request(world, ann, "rally_track", 1, {})
	local car = spawned(world, ann)[1].car
	world:advance(3)
	same(car.frozen, true, "held through the count")
	world:advance(3)
	same(car.frozen, false, "released on green")
	local drive = nil
	for _, cmd in ipairs(car.commands) do
		if cmd:find("ai.driveUsingPath", 1, true) then drive = cmd end
	end
	expect(drive, "sent the game's race driving")
	expect(drive:find('wpTargetList = {"cp1", "cp2", "cp3"', 1, true), "through the checkpoints' road nodes in order")
	expect(drive:find('"cp11"}', 1, true), "to the finish line's")
	expect(drive:find("noOfLaps = 2", 1, true), "both laps")
	expect(drive:find("aggression = 0.8", 1, true), "at class B's push")
	expect(drive:find("avoidCars = 'on'", 1, true), "round other cars")
	same(car.commands[#car.commands], "ai.setRacing(true)", "racing")
end)

World.test("an opponent that cannot spawn, or never gets a server id, is left out and the race goes on", function(world)
	local ann = world:join("Ann", 1000, 0)
	withClass(ann)
	world.spawnRefused = true
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 2, {})
	local ready = sentKey(world, ann, "ready")
	same(#ready, 1, "ready at once")
	same(#ready[1].opponents, 0, "no opponents")
	expect(last(world, ann, "countdown"), "the race goes on alone")
	world:advance(6)
	world:as(ann, function() mileage_spotRace.giveUp() end)
	world:advance(2)
	expect(last(world, ann, "result"), "that race is over")
	world.spawnRefused, world.noServerIds = false, true
	atStart(ann, "cell_tower")
	local before = #sentKey(world, ann, "ready")
	request(world, ann, "cell_tower", 1, {})
	world:advance(9)
	same(#sentKey(world, ann, "ready"), before, "waiting up to 10 s for the server id")
	world:advance(2)
	ready = sentKey(world, ann, "ready")
	same(#ready, before + 1, "ready without it")
	same(#ready[#ready].opponents, 0, "the car is left out")
	same(spawned(world, ann)[1].car.deleted, true, "and deleted")
end)

World.test("an opponent standing 15 s is reported stuck, and a vanished one gone", function(world)
	local ann = world:join("Ann", 1000, 0)
	roadsAt(world, route("highway_race"))
	withClass(ann)
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 2, {})
	local cars = spawned(world, ann)
	cars[1].car.speed = 0
	world:advance(6)
	cars[2].gone = true
	world:advance(1)
	local outs = sentKey(world, ann, "out")
	same(#outs, 1, "the vanished car first")
	same(outs[1].racer, "car:" .. cars[2].sid, "for that car")
	same(outs[1].why, "gone", "gone")
	world:advance(15)
	outs = sentKey(world, ann, "out")
	same(outs[2].racer, "car:" .. cars[1].sid, "then the standing car")
	same(outs[2].why, "stuck", "stuck")
end)

World.test("the result, a call-off and leaving the server delete every opponent", function(world)
	local ann = world:join("Ann", 1000, 0)
	withClass(ann)
	world:setConfig("server", "raceTimeLimitMinutes", "1")
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 2, {})
	world:advance(70)
	expect(last(world, ann, "result"), "the race ended")
	for _, s in ipairs(spawned(world, ann)) do same(s.car.deleted, true, "deleted after the result") end
	world:advance(1)
	atStart(ann, "cell_tower")
	request(world, ann, "cell_tower", 1, {})
	world:as(ann, function() mileage_spotRace.giveUp() end)
	world:pump()
	same(spawned(world, ann)[3].car.deleted, true, "deleted when Ann calls it off on the grid")
	atStart(ann, "rally_track")
	request(world, ann, "rally_track", 1, {})
	world:hook(ann, "onBeamMPServerLeave")
	same(spawned(world, ann)[4].car.deleted, true, "deleted when Ann leaves the server")
end)

World.test("without the game's class grouping, the opponents are the starter's own model", function(world)
	local ann = world:join("Ann", 1000, 0)
	ann.globals.gameplay_vehiclePerformance = false
	ann.globals.career_modules_vehicleClassGrouping = false
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 2, {})
	local cars = spawned(world, ann)
	same(#cars, 2, "two cars")
	same(cars[1].car.JBeam, "pickup", "Ann's own model")
	same(cars[2].car.JBeam, "pickup", "both")
end)

--== the server and the opponents =================================================

World.test("the server times opponents: one that beats Ann is first even when the starter's game hides its finish", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	roadsAt(world, r)
	withClass(ann)
	world.opponentSpeed = 60
	-- Ann's game never reports a finish for its opponents.
	world.filter = function(m)
		if m.way == "toServer" and m.name == "mileageSpotRace" and m.data:find('"finished"', 1, true)
				and m.data:find("car:", 1, true) then
			return "drop"
		end
	end
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 1, {})
	world:advance(6)
	driveRoute(world, ann, r, 30)
	world:advance(2)
	local result = last(world, ann, "result")
	expect(result, "the race ended")
	same(result.places[1].car, true, "the opponent is first")
	same(result.places[1].name, "Ibishu Pessima", "named by its model")
	same(result.places[2].name, "Ann", "Ann second")
	expect(result.places[1].seconds < result.places[2].seconds, "on the server's times")
	same(result.winner, nil, "no player won")
	same(result.carWon, true, "a car won")
	same(result.withheld, "car won", "no prize")
	local board = world:dataFile("leaderboard.json")
	same(board and board.wins and board.wins.Ann, nil, "no win for second place")
end)

World.test("the server takes only cars the starter spawned for the race, as many as it asked for", function(world)
	local ann = world:join("Ann", 1000, 0)
	local bob = world:join("Bob", 1000, 1)
	-- Ann's game says ready with a list of its own making.
	world.filter = function(m)
		if m.way == "toServer" and m.from == ann.id and m.name == "mileageSpotRace" and m.data:find('"ready"', 1, true)
				and not m.data:find("forged", 1, true) then
			return "drop"
		end
	end
	local old = world:spawnCar(ann, "pessima", {pos = {x = 0, y = 0, z = 0}})
	world:advance(1)
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 1, {})
	local id = last(world, ann, "grid").id
	local fresh1 = world:spawnCar(ann, "pessima", {pos = {x = 0, y = 0, z = 0}})
	local fresh2 = world:spawnCar(ann, "pessima", {pos = {x = 0, y = 0, z = 0}})
	local function sid(car)
		for k, s in pairs(world.spawned) do if s.car == car then return k end end
	end
	send(world, ann, {ready = {race = id, forged = true, opponents = {
		{car = bob.id .. "-0", model = "Bob's car"}, {car = ann.id .. "-0", model = "Ann's own"},
		{car = sid(old), model = "parked before"}, {car = sid(fresh1), model = "one"}, {car = sid(fresh2), model = "two"}}}})
	local countdown = last(world, ann, "countdown")
	expect(countdown, "the race starts")
	same(#countdown.racers, 2, "Ann and one opponent")
	same(countdown.racers[2].name, "one", "the first car spawned for the race")
end)

World.test("an out claim for an opponent the server sees driving is ignored; one it sees standing 20 s is out", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	roadsAt(world, r)
	withClass(ann)
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 2, {})
	local id = last(world, ann, "countdown").id
	local cars = spawned(world, ann)
	world:advance(8)
	send(world, ann, {out = {race = id, racer = "car:" .. cars[1].sid, why = "stuck"}})
	world:advance(1)
	expect(standingsRow(world, ann, "Ibishu Pessima").out == nil, "a car still driving is not out on the game's word")
	-- The second car stops; Ann's game is told nothing about it here.
	world.filter = function(m)
		if m.way == "toServer" and m.data and m.data:find('"out"', 1, true) then return "drop" end
	end
	cars[2].car.speed = 0
	world:advance(21)
	local rows = last(world, ann, "standings").rows
	local etk = nil
	for _, row in ipairs(rows) do if row.name == "ETK 800 Series" then etk = row end end
	same(etk.out, "stuck", "the server's own reading puts it out")
end)

World.test("a race spot opponent is never offered for a traffic race, and the server refuses one", function(world)
	local ann = world:join("Ann", 1000, 0)
	withClass(ann)
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 1, {})
	local s = spawned(world, ann)[1]
	-- Even listed as AI traffic in the game's traffic data, 4 m beside Ann and facing her way.
	ann.trafficData[s.car.id] = {isAi = true}
	s.car.pos = {x = ann.car.pos.x + 4, y = ann.car.pos.y, z = ann.car.pos.z}
	s.car.dir = copy(ann.car.dir)
	world:advance(1)
	local cards = world:ui(ann, "MileageAiRace")
	for _, card in ipairs(cards) do
		expect(card.phase ~= "available", "the traffic race card never offers the opponent")
	end
	world:queue({way = "toServer", from = ann.id, name = "mileageAiRace", data = World.encode({request = {car = s.sid,
		start = copy(ann.car.pos), finish = {x = ann.car.pos.x, y = ann.car.pos.y + 2500, z = 0}, model = "Ibishu Pessima"}})})
	world:pump()
	local refused = world:received(ann, "rxMileageAiRace")
	expect(refused[#refused].phase == "refused", "the server refuses the request")
end)

World.test("the starter leaving after the green ends the race with no winner", function(world)
	local ann = world:join("Ann", 1000, 0)
	withClass(ann)
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 1, {})
	world:advance(8)
	world:leave(ann)
	world:advance(1)
	same(world:printedMatching("no winner (starterLeft)"), 1, "ended for everyone")
end)

--== invited players ==============================================================

-- Ann at the highway race spot with Bob and Cat on the server, far from it.
local function threePlayers(world)
	local ann = world:join("Ann", 1000, 0)
	local bob = world:join("Bob", 1000, 1)
	local cat = world:join("Cat", 1000, 2)
	atStart(ann, "highway_race")
	return ann, bob, cat
end

local function answer(world, p, key)
	local invite = last(world, p, "invite")
	world:as(p, function()
		if key == "join" then mileage_spotRace.join(invite.id) else mileage_spotRace.decline(invite.id) end
	end)
	world:pump()
end

World.test("an invited player who joins is moved onto the grid beside the starter", function(world)
	local ann, bob = threePlayers(world)
	request(world, ann, "highway_race", 0, {"Bob"})
	local invite = last(world, bob, "invite")
	expect(invite, "Bob is invited")
	same(invite.from, "Ann", "by Ann")
	same(invite.route.id, "highway_race", "to the highway race")
	same(invite.seconds, 30, "for 30 seconds")
	same(last(world, ann, "inviting").answers[1].answer, "waiting", "Ann sees Bob has not answered")
	answer(world, bob, "join")
	same(last(world, ann, "inviting").answers[1].answer, "joined", "Ann sees Bob joined")
	local annGrid, bobGrid = last(world, ann, "grid"), last(world, bob, "grid")
	expect(annGrid and bobGrid, "everyone answered: both get a grid place")
	same(annGrid.id, bobGrid.id, "the same race")
	expect(metres(annGrid.pose.pos, bobGrid.pose.pos) > 3, "side by side")
	expect(metres(bob.car.pos, bobGrid.pose.pos) < 0.01, "Bob's car is on its grid place")
	same(bob.car.frozen, true, "held there")
	local countdown = last(world, bob, "countdown")
	expect(countdown, "the countdown starts once both are ready")
	same(countdown.racers[1].name, "Ann", "the starter first")
	same(countdown.racers[2].name, "Bob", "then Bob")
end)

World.test("the race starts at Start now or at 30 s, and Call off closes it for everyone", function(world)
	local ann, bob, cat = threePlayers(world)
	request(world, ann, "highway_race", 0, {"Bob", "Cat"})
	answer(world, bob, "join")
	same(last(world, ann, "grid"), nil, "Cat has not answered")
	world:as(ann, function() expect(mileage_spotRace.startNow(), "Start now pressed") end)
	world:pump()
	expect(last(world, ann, "grid"), "started without Cat")
	same(last(world, cat, "closed").why, "The race started without you.", "Cat is told")
	world:advance(6)
	world:as(ann, function() mileage_spotRace.giveUp() end)
	world:as(bob, function() mileage_spotRace.giveUp() end)
	world:advance(2)
	expect(last(world, bob, "result"), "that race is over")
	-- Nobody answers: the race starts at 30 s.
	atStart(ann, "cell_tower")
	request(world, ann, "cell_tower", 0, {"Bob"})
	world:advance(29)
	local grids = #heard(world, ann, "grid")
	world:advance(2)
	same(#heard(world, ann, "grid"), grids + 1, "started at 30 s")
	world:advance(6)
	world:as(ann, function() mileage_spotRace.giveUp() end)
	world:advance(2)
	-- Ann calls it off while Bob has joined and Cat is still invited.
	atStart(ann, "rally_track")
	request(world, ann, "rally_track", 0, {"Bob", "Cat"})
	answer(world, bob, "join")
	world:as(ann, function() expect(mileage_spotRace.callOff(), "Call off pressed") end)
	world:pump()
	same(last(world, bob, "closed").why, "The starter called it off.", "Bob is told")
	same(last(world, cat, "closed").why, "The starter called it off.", "Cat is told")
	same(last(world, ann, "closed").why, "The starter called it off.", "Ann's card closes")
end)

World.test("an invited player who started another race cannot join; one who leaves after the green drops out", function(world)
	local ann, bob, cat = threePlayers(world)
	request(world, ann, "highway_race", 0, {"Bob", "Cat"})
	atStart(bob, "cell_tower")
	request(world, bob, "cell_tower", 0, {})
	expect(last(world, bob, "countdown"), "Bob races alone at another spot")
	send(world, bob, {join = last(world, bob, "invite").id})
	same(last(world, bob, "closed").why, "Finish your race first, then join.", "Bob is told")
	same(last(world, ann, "inviting").answers[1].answer, "declined", "and counted as declining")
	answer(world, cat, "join")
	world:advance(6)
	world:leave(cat)
	world:advance(1)
	same(standingsRow(world, ann, "Cat").out, "quit", "Cat is out: left the server")
end)

World.test("a joined player not on the grid in 20 s drops out and the race goes on", function(world)
	local ann, bob = threePlayers(world)
	request(world, ann, "highway_race", 0, {"Bob"})
	world.filter = function(m)
		if m.way == "toServer" and m.from == bob.id and m.name == "mileageSpotRace" and m.data:find('"ready"', 1, true) then
			return "drop"
		end
	end
	answer(world, bob, "join")
	same(last(world, ann, "countdown"), nil, "waiting for Bob")
	world:advance(21)
	same(last(world, bob, "closed").why, "Your car was not on the grid in time.", "Bob is told")
	local countdown = last(world, ann, "countdown")
	expect(countdown, "the race goes on")
	same(#countdown.racers, 1, "Ann alone")
end)

World.test("a minute after the first finish the result comes, with anyone still racing as not finished", function(world)
	local ann, bob = threePlayers(world)
	local r = route("highway_race")
	request(world, ann, "highway_race", 0, {"Bob"})
	answer(world, bob, "join")
	world:advance(6)
	driveRoute(world, ann, r, 40)
	world:advance(1)
	same(last(world, ann, "result"), nil, "Bob is still racing")
	world:advance(60)
	local result = last(world, bob, "result")
	expect(result, "the result came a minute after Ann's finish")
	same(result.places[1].name, "Ann", "Ann first")
	same(result.places[2].name, "Bob", "Bob listed")
	same(result.places[2].seconds, nil, "without a time")
	same(result.winner, "Ann", "Ann won")
	same(result.withheld, "slow", "Bob never drove: no prize")
	local board = world:dataFile("leaderboard.json")
	same(board and board.wins and board.wins.Ann, nil, "no win against a player who never raced")
end)

World.test("Join while in a mission says why and sends nothing; Decline sends decline; an unanswered invite closes", function(world)
	local ann, bob, cat = threePlayers(world)
	request(world, ann, "highway_race", 0, {"Bob", "Cat"})
	bob.mission = "delivery"
	local id = last(world, bob, "invite").id
	world:as(bob, function() same(mileage_spotRace.join(id), false, "not joined") end)
	same(#sentKey(world, bob, "join"), 0, "nothing sent")
	local card = lastCard(world, bob)
	same(card.phase, "invite", "the invite stays")
	same(card.note, "Finish or leave your mission first.", "saying why")
	answer(world, cat, "decline")
	same(#sentKey(world, cat, "decline"), 1, "decline sent")
	same(lastCard(world, cat).phase, "inviteClosed", "the card goes")
	same(last(world, ann, "inviting").answers[2].answer, "declined", "Ann sees Cat declined")
	world:advance(31)
	same(lastCard(world, bob).phase ~= "invite", true, "Bob's invite closed on its own")
	same(#heard(world, bob, "grid"), 0, "Bob is not in the race")
end)

--== the prize ===================================================================

-- Ann races the highway race against one opponent driving at speed (0: held still), Ann at
-- 40 m/s; returns her result.
local function raceOne(world, ann, speed)
	local r = route("highway_race")
	roadsAt(world, r)
	withClass(ann)
	world.opponentSpeed = speed
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 1, {})
	world:advance(6)
	driveRoute(world, ann, r, 40)
	for _ = 1, 70 do
		if last(world, ann, "result") and last(world, ann, "result").id == last(world, ann, "countdown").id then break end
		world:advance(1)
	end
	return last(world, ann, "result")
end

local function wins(world, name)
	local board = world:dataFile("leaderboard.json")
	return board and board.wins and board.wins[name] or 0
end

World.test("a player who beats a driving opponent is paid the owner's prize and gets a race win", function(world)
	world:setConfig("server", "spotRacePrize", "2000")
	local ann = world:join("Ann", 1000, 0)
	local result = raceOne(world, ann, 30)
	same(result.winner, "Ann", "Ann won")
	same(result.places[2].car, true, "the opponent second")
	expect(result.places[2].seconds, "the opponent finished too")
	same(result.prize, 2000, "the prize")
	same(result.withheld, nil, "nothing withheld")
	world:advance(2)
	same(ann.money, 3000, "paid into Ann's career")
	same(ann.history[#ann.history].label, "Race spot prize", "labelled")
	same(wins(world, "Ann"), 1, "a race win")
	same(world:printedMatching("Ann wins, $2000 prize"), 1, "the console says so")
end)

World.test("no prize while the owner has set none; the win still counts", function(world)
	local ann = world:join("Ann", 1000, 0)
	local result = raceOne(world, ann, 30)
	same(result.winner, "Ann", "Ann won")
	same(result.prize, 0, "no prize")
	same(result.withheld, nil, "nothing withheld: there is no prize")
	world:advance(2)
	same(ann.money, 1000, "nothing paid")
	same(wins(world, "Ann"), 1, "a race win")
end)

World.test("opponents held still, racing alone, or a second win inside the wait pay no prize", function(world)
	world:setConfig("server", "spotRacePrize", "2000")
	world:setConfig("server", "spotRacePrizeCooldownMinutes", "30")
	local ann = world:join("Ann", 1000, 0)
	local result = raceOne(world, ann, 0)
	same(result.winner, "Ann", "Ann was first")
	same(result.withheld, "slow", "the opponent never drove")
	same(result.prize, 0, "no prize")
	same(wins(world, "Ann"), 0, "and no win")
	world:advance(2)
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 0, {})
	world:advance(6)
	driveRoute(world, ann, route("highway_race"), 40)
	world:advance(1)
	result = last(world, ann, "result")
	same(result.withheld, "alone", "nobody else raced")
	same(result.prize, 0, "no prize")
	world:advance(2)
	result = raceOne(world, ann, 30)
	same(result.prize, 2000, "a real race pays")
	world:advance(2)
	result = raceOne(world, ann, 30)
	same(result.withheld, "wait", "inside the 30 minute wait")
	same(result.prize, 0, "no prize")
	expect(result.againIn > 0, "the card says when")
	same(wins(world, "Ann"), 2, "both real races count as wins")
	world:advance(2)
	same(ann.money, 3000, "paid once")
	same(last(world, ann, "status").againIn > 0, true, "the set-up card knows the wait")
end)

World.test("a starter's game reporting its own finish 0.1 s after green while standing still wins nothing", function(world)
	world:setConfig("server", "spotRacePrize", "2000")
	local ann = world:join("Ann", 1000, 0)
	roadsAt(world, route("highway_race"))
	withClass(ann)
	world.opponentSpeed = 30
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 1, {})
	local id = last(world, ann, "countdown").id
	world:advance(6)
	send(world, ann, {finished = {race = id, racer = "Ann", seconds = 0.1}})
	for _ = 1, 140 do
		if last(world, ann, "result") then break end
		world:advance(1)
	end
	local result = last(world, ann, "result")
	same(result.places[1].car, true, "the opponent won")
	same(result.places[2].seconds, nil, "Ann has no time")
	same(result.prize, 0, "no prize")
	world:advance(2)
	same(ann.money, 1000, "nothing paid")
end)

--== spot times on the leaderboard ================================================

World.test("a leaderboard file from before race spots keeps its wins and drag times and gains the spot time", function(world)
	world.disk["Resources/Server/Mileage/data/leaderboard.json"] = World.encode({wins = {Ann = 3},
		drag = {alder_dragway = {Ann = {et = 11.2, trap = 50, at = 1}}}})
	world:restart()
	local ann = world:join("Ann", 1000, 0)
	soloToGreen(world, ann)
	driveRoute(world, ann, route("highway_race"), 40)
	world:advance(1)
	local result = last(world, ann, "result")
	local board = world:dataFile("leaderboard.json")
	same(board.wins.Ann, 3, "the wins kept")
	same(board.drag.alder_dragway.Ann.et, 11.2, "the drag time kept")
	same(board.spots.highway_race.Ann.time, result.places[1].seconds, "Ann's server time under the route")
	same(result.best.improved, true, "the card says it is on the board")
	same(result.best.old, nil, "her first time here")
end)

World.test("only a strictly faster time replaces a player's best at a route", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	local function run(speed)
		soloToGreen(world, ann)
		driveRoute(world, ann, r, speed)
		world:advance(2)
		return last(world, ann, "result")
	end
	local first = run(30)
	local slower = run(20)
	same(slower.best.improved, false, "a slower run is not a best")
	same(world:dataFile("leaderboard.json").spots.highway_race.Ann.time, first.places[1].seconds, "the first time kept")
	local faster = run(50)
	same(faster.best.improved, true, "a faster run is")
	same(faster.best.old, first.places[1].seconds, "the card shows the old best")
	same(world:dataFile("leaderboard.json").spots.highway_race.Ann.time, faster.places[1].seconds, "replaced")
	same(last(world, ann, "status").mine.highway_race, faster.places[1].seconds, "the set-up card knows it")
end)

World.test("leaving the server ends the race here and releases the car", function(world)
	local ann = world:join("Ann", 1000, 0)
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 0, {})
	same(ann.car.frozen, true, "held on the grid")
	world:hook(ann, "onBeamMPServerLeave")
	same(ann.car.frozen, false, "released")
	world:as(ann, function() same(mileage_spotRace.inRace(), false, "no race here") end)
end)
