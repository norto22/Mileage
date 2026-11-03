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

World.test("the server times the car the player is on the grid in, not another of theirs parked nearby", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 0, {})
	local pose = last(world, ann, "grid").pose
	-- Another car of Ann's parked 10 m behind her grid place.
	ann.parkedCar = {pos = {x = pose.pos.x - pose.dir.x * 10, y = pose.pos.y - pose.dir.y * 10, z = pose.pos.z}}
	world:advance(6)
	driveRoute(world, ann, r, 40)
	world:advance(1)
	local result = last(world, ann, "result")
	expect(result, "the race ended at Ann's finish")
	expect(result.places[1].seconds, "Ann's car was timed")
end)

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

World.test("a car that stands 10 s and then jumps 1.2 km in one second passes no checkpoint", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	soloToGreen(world, ann)
	world:advance(10)
	local cp = r.checkpoints[2].pos
	ann.car.pos = copy(cp)
	world:advance(1)
	same(standingsRow(world, ann, "Ann").passed, 0, "nothing passed on the jump")
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

World.test("the racer's map route points at the next checkpoint and moves on after each pass", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	soloToGreen(world, ann)
	expect(ann.route and metres(ann.route, r.checkpoints[1].pos) < 0.01, "at green: the first checkpoint")
	driveTo(world, ann, r.checkpoints[1].pos, 40)
	expect(metres(ann.route, r.checkpoints[2].pos) < 0.01, "after it: the second")
	driveTo(world, ann, r.checkpoints[2].pos, 40)
	expect(metres(ann.route, r.checkpoints[3].pos) < 0.01, "then the third")
end)

World.test("the racer's game counts a checkpoint as far out as the server does, its radius plus 10 m", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	soloToGreen(world, ann)
	local cp = r.checkpoints[1]
	local side = {x = -r.grid.dir.y, y = r.grid.dir.x}
	driveTo(world, ann, {x = cp.pos.x + side.x * (cp.r + 5), y = cp.pos.y + side.y * (cp.r + 5), z = cp.pos.z}, 40)
	world:advance(1)
	same(#sentKey(world, ann, "progress"), 1, "the game counted it")
	same(standingsRow(world, ann, "Ann").passed, 1, "and so did the server")
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

--== the race road ================================================================

-- A test route on a small road map: from the grid (g) north to checkpoint 1 (b), then
-- east to checkpoint 2 (c). The race road goes round by r1 and r2; the side street b-s-c
-- is shorter, but a wall closes it. Links are given one way only, as a one-way road.
local WALLED = {id = "walled", name = "Walled", closed = false, laps = 1, length = 320,
	grid = {pos = {x = 0, y = -20, z = 0}, dir = {x = 0, y = 1, z = 0}},
	checkpoints = {{pos = {x = 0, y = 100, z = 0}, r = 8}, {pos = {x = 200, y = 100, z = 0}, r = 8}},
	walls = {{50, 90, 50, 110}}}

local function walledMap(world)
	local function node(x, y, links)
		local l = {}
		for _, name in ipairs(links or {}) do l[name] = {oneWay = true} end
		return {pos = {x = x, y = y, z = 0}, links = l}
	end
	world.roadNodes = {
		g = node(0, -20, {"a"}), a = node(0, 0, {"b"}), b = node(0, 100, {"r1", "s"}),
		r1 = node(0, 200, {"r2"}), r2 = node(200, 200, {"c"}), s = node(100, 100, {"c"}), c = node(200, 100),
	}
end

local function withRoutes(world, p, list)
	world:as(p, function() mileage_spotRoutes.routes = list end)
end

local function logged(p)
	p.logLines = {}
	p.globals.log = function(level, tag, text)
		if tag == "mileage.raceRoad" then table.insert(p.logLines, level .. " " .. text) end
	end
end

World.test("the race road keeps off a side street a wall closes, one-way rules ignored", function(world)
	local ann = world:join("Ann", 1000, 0)
	walledMap(world)
	local road = world:as(ann, function() return mileage_raceRoad.road(WALLED) end)
	expect(road, "a road")
	same(table.concat(road.nodes, " "), "g a b r1 r2 c", "round by the race road, not the side street")
	same(#road.legs, 2, "a leg to each checkpoint")
	same(table.concat(road.legs[2].nodes, " "), "b r1 r2 c", "checkpoint 1 to 2 along the race road")
	same(road.fallbacks, 0, "every leg crosses no wall")
	same(road.points[4].y, 200, "the points follow the nodes")
	WALLED.walls = {}
	local open = world:as(ann, function() return mileage_raceRoad.road(WALLED) end)
	same(open, road, "worked out once and kept")
	world:hook(ann, "onBeamMPServerLeave")
	open = world:as(ann, function() return mileage_raceRoad.road(WALLED) end)
	same(table.concat(open.nodes, " "), "g a b s c", "without the wall, worked out again after leaving: the side street")
	WALLED.walls = {{50, 90, 50, 110}}
end)

World.test("a leg no road reaches without crossing a wall takes the walls-ignored road and says so", function(world)
	local ann = world:join("Ann", 1000, 0)
	walledMap(world)
	logged(ann)
	local closed = {}
	for k, v in pairs(WALLED) do closed[k] = v end
	closed.id = "closed_off"
	closed.walls = {{50, 90, 50, 110}, {90, 190, 90, 210}}
	local road = world:as(ann, function() return mileage_raceRoad.road(closed) end)
	same(table.concat(road.legs[2].nodes, " "), "b s c", "the shortest road, walls ignored")
	same(road.legs[2].fallback, true, "marked as such")
	same(road.fallbacks, 1, "one leg")
	same(countLines(ann.logLines, "closed_off: no road to checkpoint 2 crosses no wall"), 1, "logged")
end)

World.test("the race road check logs a line per route: passes, a fallback leg, a missed checkpoint", function(world)
	local ann = world:join("Ann", 1000, 0)
	walledMap(world)
	world.roadNodes.far = {pos = {x = 600, y = 600, z = 0}, links = {c = {}}}
	logged(ann)
	local closed, missed = {}, {}
	for k, v in pairs(WALLED) do closed[k], missed[k] = v, v end
	closed.id, closed.walls = "closed_off", {{50, 90, 50, 110}, {90, 190, 90, 210}}
	missed.id = "missed"
	missed.checkpoints = {WALLED.checkpoints[1], WALLED.checkpoints[2], {pos = {x = 400, y = 100, z = 0}, r = 8}}
	missed.length = 520
	-- A checkpoint on a road the map does not join to the others.
	world.roadNodes.island = {pos = {x = -300, y = 100, z = 0}, links = {}}
	local island = {}
	for k, v in pairs(WALLED) do island[k] = v end
	island.id = "island"
	island.checkpoints = {WALLED.checkpoints[1], {pos = {x = -300, y = 100, z = 0}, r = 8}}
	withRoutes(world, ann, {WALLED, closed, missed, island})
	local result = world:as(ann, function() return mileage_raceRoad.check() end)
	same(result.passed, 1, "one route passes")
	same(result.total, 4, "of four")
	same(countLines(ann.logLines, "W race road island: FAILS: no road reaches checkpoint 2"), 1,
		"a checkpoint no road reaches fails it, said as such")
	same(countLines(ann.logLines, "I race road walled: passes: 2 legs on roads that cross no wall, 2 checkpoints in order"),
		1, "the walled route passes")
	same(countLines(ann.logLines, "W race road closed_off: FAILS: the road to checkpoint 2 crosses a wall"), 1,
		"a fallback leg fails the check")
	same(countLines(ann.logLines, "W race road missed: FAILS: lap 1 misses checkpoint 3 (nearest"), 1,
		"a checkpoint the road does not reach fails it")
	same(countLines(ann.logLines, "W race road check: 1 of 4 routes pass"), 1, "and a summary")
end)

World.test("the race road check runs once at each career start on a server", function(world)
	local ann = world:join("Ann", 1000, 0)
	walledMap(world)
	logged(ann)
	withRoutes(world, ann, {WALLED})
	world:startCareer(ann)
	same(countLines(ann.logLines, "race road check: 1 of 1 routes pass"), 1, "checked at the career start")
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

-- p's car is career car 7 with these performance tests: current (its latest test, or nil
-- when it changed since) and history (earlier results, newest first), each {class, index}.
-- The game's stock lookup says class E at 18.
local function withTests(p, current, history)
	withClass(p)
	p.globals.gameplay_vehiclePerformance.getClassFromVehId = function()
		return {class = {name = "E"}, performanceIndex = 18}
	end
	p.globals.gameplay_vehiclePerformance.getClassFromData = function(data)
		return {class = {name = data.class}, performanceIndex = data.index}
	end
	local vehicle = {certificationData = current, performanceHistory = history}
	p.globals.career_modules_inventory = {
		getInventoryIdFromVehicleId = function(vid) return vid == p.car.id and 7 or nil end,
		getVehicles = function() return {[7] = vehicle} end,
	}
	p.globals.career_modules_vehiclePerformance = {getVehicleClass = function(id)
		local data = id == 7 and vehicle.certificationData
		return data and p.globals.gameplay_vehiclePerformance.getClassFromData(data) or nil
	end}
end

World.test("an upgraded starter whose latest test is class S gets opponents grouped for S", function(world)
	local ann = world:join("Ann", 1000, 0)
	withTests(ann, {class = "S", index = 92})
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 2, {})
	same(ann.groupAsked.class, "S", "grouped for the class of its latest test")
	same(ann.groupAsked.index, 92, "near that test's performance index")
end)

World.test("a car changed since its test races on its newest earlier result; one never tested on its stock class", function(world)
	local ann = world:join("Ann", 1000, 0)
	withTests(ann, nil, {{class = "A", index = 71}, {class = "B", index = 55}})
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 1, {})
	same(ann.groupAsked.class .. " " .. ann.groupAsked.index, "A 71", "the newest earlier result")
	world:as(ann, function() mileage_spotRace.giveUp() end)
	world:pump()
	withTests(ann, nil, nil)
	atStart(ann, "cell_tower")
	request(world, ann, "cell_tower", 1, {})
	same(ann.groupAsked.class .. " " .. ann.groupAsked.index, "E 18", "the class it was bought as")
end)

World.test("the set-up card says the rivals may not match a car changed since its test, or never tested", function(world)
	local ann = world:join("Ann", 1000, 0)
	withTests(ann, {class = "S", index = 92})
	world:as(ann, function() mileage_spotRace.openSetup("city_race_1") end)
	same(lastCard(world, ann, "setup").untested, false, "a current test: nothing to say")
	withTests(ann, nil, {{class = "S", index = 92}})
	world:as(ann, function() mileage_spotRace.openSetup("city_race_1") end)
	same(lastCard(world, ann, "setup").untested, true, "changed since its test")
	withTests(ann, nil, nil)
	world:as(ann, function() mileage_spotRace.openSetup("city_race_1") end)
	same(lastCard(world, ann, "setup").untested, true, "never tested")
	ann.globals.career_modules_inventory = false
	ann.globals.career_modules_vehiclePerformance = false
	world:as(ann, function() mileage_spotRace.openSetup("city_race_1") end)
	same(lastCard(world, ann, "setup").untested, false, "not a career car: nothing to say")
end)

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
	expect(drive:find('"cp10", "cp11", "cp1"}', 1, true), "to the finish line's, and round to the first again so laps repeat")
	expect(drive:find("noOfLaps = 2", 1, true), "both laps")
	expect(drive:find("aggression = 0.8", 1, true), "at class B's push")
	expect(drive:find("avoidCars = 'on'", 1, true), "round other cars")
	same(car.commands[#car.commands], "ai.setRacing(true)", "racing")
end)

World.test("on a one-lap route the opponents drive on past the finish instead of braking on it", function(world)
	local ann = world:join("Ann", 1000, 0)
	roadsAt(world, route("highway_race"))
	withClass(ann)
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 1, {})
	world:advance(6)
	local drive = nil
	for _, cmd in ipairs(spawned(world, ann)[1].car.commands) do
		if cmd:find("ai.driveUsingPath", 1, true) then drive = cmd end
	end
	expect(drive:find('{"cp1", "cp2", "cp3", "cp4", "cp4+1", "cp4+2"}', 1, true), "the road beyond the finish follows it")
	expect(drive:find("noOfLaps = 1", 1, true), "one lap")
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
	same(#ready[1].failed, 2, "both reported as not started")
	expect(last(world, ann, "countdown"), "the race goes on alone")
	world:advance(6)
	local rows = last(world, ann, "standings").rows
	same(#rows, 3, "Ann and the two cars that did not start")
	same(rows[2].out, "spawn", "listed as did not start")
	same(rows[3].out, "spawn", "both")
	same(rows[2].car, true, "as cars")
	same(rows[2].name .. "," .. rows[3].name, "ETK 800 Series,Ibishu Pessima", "by model")
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
	same(#ready[#ready].failed, 1, "and reported as not started")
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

--== traffic during the race =======================================================

-- p's game has road traffic cars (police of them police) and parked cars, all active.
local function withTraffic(world, p, road, police, parked)
	p.amounts = {road = road, parked = parked, roadCars = road, parkedCars = parked}
	local ids = {}
	for i = 1, police do
		local t = world:giveTraffic(p, {x = 5000 + i * 10, y = 5000})
		t.entry.roleName = "police"
		table.insert(ids, t.car.id)
	end
	p.amountsSet = {}
	return ids
end

World.test("at the green each racer's game halves its traffic and parked cars, keeping its police on the road", function(world)
	local ann = world:join("Ann", 1000, 0)
	local bob = world:join("Bob", 1000, 1)
	local police = withTraffic(world, ann, 9, 2, 6)
	withTraffic(world, bob, 8, 0, 5)
	withClass(ann)
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 1, {"Bob"})
	local invite = last(world, bob, "invite")
	world:as(bob, function() mileage_spotRace.join(invite.id) end)
	world:pump()
	world:advance(3)
	same(#ann.amountsSet + #bob.amountsSet, 0, "nothing changes before the green")
	world:advance(4)
	same(table.concat(ann.amountsSet, ", "), "out " .. police[1] .. ", out " .. police[2] .. ", road 3, parked 3",
		"the starter's police out of the pool, then 5 of 9 on the road with them, 3 of 6 parked")
	same(table.concat(bob.amountsSet, ", "), "road 4, parked 3", "a joined player's game too: 4 of 8, 3 of 5")
	world:advance(5)
	same(#ann.amountsSet, 4, "once a race")
	world:as(ann, function() mileage_spotRace.giveUp() end)
	world:as(bob, function() mileage_spotRace.giveUp() end)
	world:pump()
	same(table.concat(bob.amountsSet, ", "), "road 4, parked 3, road 8, parked 5",
		"a racer whose own race is over gets its traffic back at once")
	same(#ann.amountsSet, 4, "the starter's opponents still race, so its traffic stays thin")
	-- Its opponent has no road to drive here, so it stands and is out as stuck after 15 s.
	world:advance(16)
	same(#ann.amountsSet, 8, "back once its last opponent is out too")
	world:advance(70)
	expect(last(world, ann, "result"), "the race is over")
	same(table.concat(ann.amountsSet, ", "), "out " .. police[1] .. ", out " .. police[2] .. ", road 3, parked 3, in " ..
		police[1] .. " active, in " .. police[2] .. " active, road 9, parked 6",
		"at the result the police go back into the pool, then the amounts")
end)

World.test("every ending puts the traffic back: a finish, leaving the route and leaving the server", function(world)
	local ann = world:join("Ann", 1000, 0)
	withTraffic(world, ann, 6, 0, 4)
	local r = route("highway_race")
	soloToGreen(world, ann)
	same(table.concat(ann.amountsSet, ", "), "road 3, parked 2", "thinned at the green")
	driveRoute(world, ann, r, 40)
	world:advance(1)
	same(table.concat(ann.amountsSet, ", "), "road 3, parked 2, road 6, parked 4", "back at the finish")
	ann.amountsSet = {}
	soloToGreen(world, ann)
	local g = r.grid.pos
	driveTo(world, ann, {x = g.x - r.grid.dir.y * 1500, y = g.y + r.grid.dir.x * 1500, z = g.z}, 80)
	world:advance(11)
	same(table.concat(ann.amountsSet, ", "), "road 3, parked 2, road 6, parked 4", "back on leaving the route")
	ann.amountsSet = {}
	soloToGreen(world, ann)
	world:hook(ann, "onBeamMPServerLeave")
	same(table.concat(ann.amountsSet, ", "), "road 3, parked 2, road 6, parked 4", "back on leaving the server")
end)

World.test("a game without the traffic functions races as before", function(world)
	local ann = world:join("Ann", 1000, 0)
	ann.globals.gameplay_traffic = false
	ann.globals.gameplay_parking = false
	soloToGreen(world, ann)
	world:as(ann, function() same(mileage_spotRace.inRace(), true, "racing") end)
	same(ann.car.frozen, false, "released on green")
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

World.test("a player who joined can still pull out with Decline before the race starts", function(world)
	local ann, bob, cat = threePlayers(world)
	request(world, ann, "highway_race", 0, {"Bob", "Cat"})
	answer(world, bob, "join")
	same(last(world, ann, "inviting").answers[1].answer, "joined", "Bob joined")
	answer(world, bob, "decline")
	same(last(world, ann, "inviting").answers[1].answer, "declined", "then pulled out")
	answer(world, cat, "join")
	expect(last(world, cat, "grid"), "the race starts once Cat answers")
	same(#heard(world, bob, "grid"), 0, "Bob is not moved onto the grid")
	same(#last(world, ann, "countdown").racers, 2, "Ann and Cat race")
end)

World.test("a closing for an older invite leaves a newer invite on the card", function(world)
	local ann, bob, cat = threePlayers(world)
	atStart(cat, "cell_tower")
	request(world, cat, "cell_tower", 0, {"Bob"})
	local first = last(world, bob, "invite").id
	request(world, ann, "highway_race", 0, {"Bob"})
	local second = last(world, bob, "invite").id
	expect(first ~= second, "two invites")
	world:as(cat, function() mileage_spotRace.callOff() end)
	world:pump()
	same(last(world, bob, "closed").id, first, "the first invite closed")
	local card = lastCard(world, bob)
	same(card.phase, "invite", "the card still shows an invite")
	same(card.id, second, "the newer one, with its Join")
	answer(world, bob, "join")
	expect(last(world, bob, "grid"), "Bob can still join it")
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

--== the whole race ===============================================================

-- Drives several players' cars through the route together, each at its own speed in
-- metres a second, one second at a time, until every one has done every lap.
local function driveTogether(world, r, speeds)
	local paths = {}
	for p, speed in pairs(speeds) do
		local targets = {}
		for _ = 1, r.laps do
			for _, checkpoint in ipairs(r.checkpoints) do table.insert(targets, checkpoint.pos) end
		end
		paths[p] = {targets = targets, index = 1, speed = speed}
	end
	for _ = 1, 600 do
		local moving = false
		for p, path in pairs(paths) do
			local left = path.speed
			local pos = copy(p.car.pos)
			while left > 0 and path.index <= #path.targets do
				local target = path.targets[path.index]
				local d = metres(pos, target)
				local step = math.min(d, left)
				if d > 0 then
					pos = {x = pos.x + (target.x - pos.x) * step / d, y = pos.y + (target.y - pos.y) * step / d,
						z = pos.z + (target.z - pos.z) * step / d}
				end
				left = left - step
				if step >= d then path.index = path.index + 1 end
			end
			if path.index <= #path.targets or left < path.speed then
				moving = true
				expect(world:drive(p, pos.x, pos.y, pos.z), p.name .. "'s car is free to drive")
			end
		end
		if not moving then return end
		world:advance(1)
	end
	error("the cars never finished")
end

World.test("the Oracle race: two opponents and an invited friend, all four places, the prize once, the time kept", function(world)
	world:setConfig("server", "spotRacePrize", "2000")
	local ann = world:join("Ann", 1000, 0)
	local bob = world:join("Bob", 1000, 1)
	local cat = world:join("Cat", 1000, 2)
	local r = route("rally_track")
	roadsAt(world, r)
	withClass(ann)
	world.opponentSpeed = 30
	bob.car.pos = {x = r.grid.pos.x + 900, y = r.grid.pos.y, z = r.grid.pos.z}
	atStart(ann, "rally_track")
	-- Through Ann's set-up card, as she would.
	world:as(ann, function() expect(mileage_spotRace.openSetup("rally_track"), "the card opens") end)
	world:pump()
	world:as(ann, function()
		expect(mileage_spotRace.request("rally_track", 2, '["Bob"]'), "Start race pressed")
	end)
	world:pump()
	answer(world, bob, "join")
	local bobGrid = last(world, bob, "grid")
	expect(metres(bob.car.pos, bobGrid.pose.pos) < 0.01, "Bob was moved onto the grid")
	local countdown = last(world, ann, "countdown")
	same(#countdown.racers, 4, "Ann, Bob and two opponents on the grid")
	same(#heard(world, cat, "grid"), 0, "Cat is not in the race")
	world:advance(6)
	driveTogether(world, r, {[ann] = 45, [bob] = 25})
	for _ = 1, 70 do
		if last(world, bob, "result") then break end
		world:advance(1)
	end
	local result = last(world, bob, "result")
	expect(result, "everyone hears the result")
	same(#result.places, 4, "four places")
	same(result.places[1].name, "Ann", "Ann first")
	for i = 1, 4 do expect(result.places[i].seconds, "place " .. i .. " has a time") end
	local names = {}
	for i = 2, 4 do names[result.places[i].name] = true end
	expect(names.Bob and names["Ibishu Pessima"] and names["ETK 800 Series"], "Bob and both opponents placed")
	same(result.winner, "Ann", "Ann won")
	same(result.ranked, true, "the server followed every car")
	same(last(world, ann, "result").prize, 2000, "Ann is paid")
	same(result.prize, 2000, "Bob's card says what the winner was paid")
	world:advance(2)
	same(ann.money, 3000, "paid once")
	same(bob.money, 1000, "nothing for Bob")
	local board = world:dataFile("leaderboard.json")
	same(board.spots.rally_track.Ann.time, result.places[1].seconds, "Ann's time kept under the spot")
	expect(board.spots.rally_track.Bob, "Bob's time kept too")
	same(board.wins.Ann, 1, "a race win")
	for _, s in ipairs(spawned(world, ann)) do same(s.car.deleted, true, "the opponents are gone") end
	-- Again, with the opponents held still and Bob not driving: Ann is first but paid nothing.
	world.opponentSpeed = 0
	atStart(ann, "rally_track")
	world:as(ann, function() mileage_spotRace.openSetup("rally_track") end)
	world:as(ann, function() mileage_spotRace.request("rally_track", 2, "[]") end)
	world:pump()
	world:advance(6)
	driveTogether(world, r, {[ann] = 45})
	world:advance(2)
	local again = last(world, ann, "result")
	same(again.winner, "Ann", "Ann first again")
	same(again.withheld, "slow", "nobody else drove")
	same(again.prize, 0, "no prize")
	world:advance(2)
	same(ann.money, 3000, "still paid once")
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

--== edges: checkpoint reach, finish timing, foreign messages, ranges ===============

-- p races the highway race alone and drives past its first checkpoint offset metres to the
-- side, 45 m between readings so no reading lands beside it; returns the checkpoints the
-- server counted.
local function pastFirstCheckpoint(world, p, offset)
	local r = route("highway_race")
	soloToGreen(world, p)
	local cp, g = r.checkpoints[1].pos, r.grid.pos
	local d = metres(g, cp)
	local ux, uy, uz = (cp.x - g.x) / d, (cp.y - g.y) / d, (cp.z - g.z) / d
	local flat = math.sqrt(ux * ux + uy * uy)
	local nx, ny = -uy / flat, ux / flat
	driveTo(world, p, {x = cp.x - ux * 60 + nx * offset, y = cp.y - uy * 60 + ny * offset, z = cp.z - uz * 60}, 45)
	driveTo(world, p, {x = cp.x + ux * 60 + nx * offset, y = cp.y + uy * 60 + ny * offset, z = cp.z + uz * 60}, 45)
	world:advance(1)
	return standingsRow(world, p, p.name).passed
end

World.test("a checkpoint counts when the path between readings comes within its radius plus 10 m, and not beyond", function(world)
	local ann = world:join("Ann", 1000, 0)
	same(route("highway_race").checkpoints[1].r, 9.5, "the first checkpoint's radius")
	same(pastFirstCheckpoint(world, ann, 19), 1, "19 m to the side, inside 9.5 + 10 m: passed")
	world:as(ann, function() mileage_spotRace.giveUp() end)
	world:pump()
	world:advance(2)
	expect(last(world, ann, "result"), "that run is over")
	same(pastFirstCheckpoint(world, ann, 20), 0, "20 m to the side, outside 9.5 + 10 m: not passed")
end)

World.test("a finish is timed where the path between two readings meets the finish, from the server's green", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 0, {})
	ready(world, {ann})
	expect(last(world, ann, "countdown"), "the countdown started")
	local goAt = world.now + 5
	world:advance(6)
	for i = 1, #r.checkpoints - 1 do driveTo(world, ann, r.checkpoints[i].pos, 40) end
	local a, b = r.checkpoints[#r.checkpoints - 1].pos, r.checkpoints[#r.checkpoints].pos
	local d = metres(a, b)
	local ux, uy, uz = (b.x - a.x) / d, (b.y - a.y) / d, (b.z - a.z) / d
	driveTo(world, ann, {x = b.x - ux * 30, y = b.y - uy * 30, z = b.z - uz * 30}, 40)
	-- Standing 30 m short of the finish for three readings, then 40 m in one second.
	world:advance(3)
	expect(world:drive(ann, b.x + ux * 10, b.y + uy * 10, b.z + uz * 10), "free to drive")
	world:advance(1)
	local readAt = world.now
	world:advance(1)
	local result = last(world, ann, "result")
	expect(result, "the finish ended the run")
	-- Between the reading a second earlier (30 m short) and this one (10 m past), the path
	-- meets the finish three quarters of the way along.
	local wanted = (readAt - 1) + 0.75 - goAt
	expect(math.abs(result.places[1].seconds - wanted) < 1e-6,
		string.format("finish %.3f s, wanted %.3f s", result.places[1].seconds, wanted))
end)

World.test("malformed messages, and messages about another racer or the starter's cars, change nothing", function(world)
	local ann, bob, cat = threePlayers(world)
	local r = route("highway_race")
	roadsAt(world, r)
	withClass(ann)
	world.opponentSpeed = 30
	local function from(p, data)
		world:queue({way = "toServer", from = p.id, name = "mileageSpotRace", data = data})
		world:pump()
	end
	for _, data in ipairs({"not json", "[]", "null", World.encode({request = "highway_race"}),
			World.encode({ready = 5}), World.encode({progress = "x"}), World.encode({out = {why = "gone"}})}) do
		from(cat, data)
	end
	from(cat, World.encode({request = {route = 7, opponents = 0}}))
	same(last(world, cat, "refused").why, "That race spot is not on this server.", "a route that is not text")
	from(cat, World.encode({request = {route = "highway_race", opponents = "2"}}))
	same(last(world, cat, "refused").why, "This server allows fewer opponents.", "opponents that are not a number")
	local refusals = #heard(world, cat, "refused")
	from(cat, World.encode({request = {route = "highway_race", opponents = 0, invite = "Bob"}}))
	same(#heard(world, cat, "refused"), refusals + 1, "an invite list that is not a list is refused")
	same(#heard(world, cat, "grid"), 0, "none of it reached a grid")

	request(world, ann, "highway_race", 1, {"Bob"})
	local id = last(world, ann, "inviting").id
	send(world, cat, {start = id})
	send(world, cat, {cancel = id})
	send(world, cat, {join = id})
	same(#heard(world, ann, "grid"), 0, "only the starter can start it")
	same(#heard(world, ann, "closed"), 0, "only the starter can call it off")
	same(last(world, ann, "inviting").answers[1].name, "Bob", "Cat, never invited, did not join")
	same(#last(world, ann, "inviting").answers, 1, "still only Bob asked")
	answer(world, bob, "join")
	expect(last(world, ann, "countdown"), "the race lines up")
	world:advance(6)
	local opponent = "car:" .. sentKey(world, ann, "ready")[1].opponents[1].car
	send(world, bob, {out = {race = id, racer = "Ann", why = "left"}})
	send(world, bob, {out = {race = id, racer = opponent, why = "stuck"}})
	send(world, bob, {finished = {race = id, racer = "Ann", seconds = 50}})
	send(world, cat, {gaveUp = id})
	send(world, ann, {progress = {race = id, racer = "Ann", checkpoint = 0, lap = 9}})
	send(world, ann, {finished = {race = id, racer = "Ann", seconds = -1}})
	send(world, ann, {out = {race = id, racer = "Ann", why = "teleported"}})
	world:advance(1)
	for _, name in ipairs({"Ann", "Bob", "Ibishu Pessima"}) do
		local row = standingsRow(world, ann, name)
		expect(row, name .. " is in the standings")
		same(row.out, nil, name .. " is still racing")
		same(row.seconds, nil, name .. " has no time")
	end
	same(standingsRow(world, ann, "Cat"), nil, "Cat is not in the race")
end)

World.test("the owner's prize and wait are held to their ranges", function(world)
	world:setConfig("server", "spotRacePrize", "5000000")
	world:setConfig("server", "spotRacePrizeCooldownMinutes", "99999")
	local ann = world:join("Ann", 1000, 0)
	same(last(world, ann, "status").prize, 1000000, "the prize is at most $1,000,000")
	local result = raceOne(world, ann, 30)
	same(result.prize, 1000000, "paid at most $1,000,000")
	world:advance(2)
	same(ann.money, 1001000, "into Ann's career")
	local againIn = last(world, ann, "status").againIn
	expect(againIn <= 1440 * 60 and againIn > 1439 * 60, "the wait is at most 1440 minutes, got " .. tostring(againIn))
end)

World.test("a full grid: the starter, seven invited players and five opponents each get their own place behind the start", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	roadsAt(world, r)
	withClass(ann)
	local names, players = {}, {}
	for i = 1, 7 do
		local p = world:join("P" .. i, 1000, i)
		table.insert(names, p.name)
		table.insert(players, p)
	end
	atStart(ann, "highway_race")
	request(world, ann, "highway_race", 5, names)
	for _, p in ipairs(players) do answer(world, p, "join") end
	local grid = last(world, ann, "grid")
	expect(grid, "everyone joined: the grid")
	same(#grid.opponentPoses, 5, "five opponent places for the starter's game")
	local poses = {grid.pose}
	for _, p in ipairs(players) do table.insert(poses, last(world, p, "grid").pose) end
	for _, pose in ipairs(grid.opponentPoses) do table.insert(poses, pose) end
	same(#poses, 13, "thirteen places")
	for i, pose in ipairs(poses) do
		local ahead = (pose.pos.x - r.grid.pos.x) * r.grid.dir.x + (pose.pos.y - r.grid.pos.y) * r.grid.dir.y
		expect(ahead <= 0.01, "place " .. i .. " is not past the start line")
		for j = i + 1, #poses do
			expect(metres(pose.pos, poses[j].pos) > 3, "places " .. i .. " and " .. j .. " are apart")
		end
	end
	local countdown = last(world, ann, "countdown")
	expect(countdown, "the count starts")
	same(#countdown.racers, 13, "thirteen racers on the grid")
end)

World.test("Join after the invite ran out sends nothing", function(world)
	local ann, bob = threePlayers(world)
	request(world, ann, "highway_race", 0, {"Bob"})
	local id = last(world, bob, "invite").id
	world:advance(31)
	world:as(bob, function() same(mileage_spotRace.join(id), false, "no invite to join") end)
	world:pump()
	same(#sentKey(world, bob, "join"), 0, "nothing sent")
end)

World.test("off the route means more than 1000 m from the next checkpoint for 10 seconds", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	soloToGreen(world, ann)
	local cp, g = r.checkpoints[1].pos, r.grid.pos
	local d = metres(g, cp)
	local ux, uy = (cp.x - g.x) / d, (cp.y - g.y) / d
	local flat = math.sqrt(ux * ux + uy * uy)
	local nx, ny = -uy / flat, ux / flat
	driveTo(world, ann, {x = cp.x + nx * 990, y = cp.y + ny * 990, z = cp.z}, 80)
	world:advance(15)
	same(#sentKey(world, ann, "out"), 0, "990 m away is still on the route")
	driveTo(world, ann, {x = cp.x + nx * 1010, y = cp.y + ny * 1010, z = cp.z}, 80)
	world:advance(8)
	same(#sentKey(world, ann, "out"), 0, "not yet: under 10 seconds off the route")
	world:advance(3)
	local out = sentKey(world, ann, "out")
	same(#out, 1, "out after 10 seconds more than 1000 m away")
	same(out[1].why, "left", "left the route")
end)

--== the car each racer names, cars that did not start, closings for other races ====

-- Holds back the ready each listed player's own game sends on the grid, so the test can
-- send the ready it wants in its place.
local function holdReady(world, players)
	world.filter = function(m)
		if m.way ~= "toServer" or m.name ~= "mileageSpotRace" then return nil end
		for _, p in ipairs(players) do
			if m.from == p.id and m.data:find('"ready"', 1, true) then return "drop" end
		end
		return nil
	end
end

World.test("a car the racer names in ready that stands far from its grid place is not the one timed", function(world)
	local ann = world:join("Ann", 1000, 0)
	local r = route("highway_race")
	atStart(ann, "highway_race")
	holdReady(world, {ann})
	request(world, ann, "highway_race", 0, {})
	local grid = last(world, ann, "grid")
	world.filter = nil
	-- Another car of Ann's, parked 300 m from her grid place, never moves.
	ann.parkedCar = {pos = {x = grid.pose.pos.x - grid.pose.dir.x * 300, y = grid.pose.pos.y - grid.pose.dir.y * 300,
		z = grid.pose.pos.z}}
	send(world, ann, {ready = {race = grid.id, car = ann.id .. "-9", opponents = {}}})
	expect(last(world, ann, "countdown"), "the countdown started")
	world:advance(6)
	driveRoute(world, ann, r, 40)
	world:advance(1)
	local result = last(world, ann, "result")
	expect(result, "the race ended at the finish of the car Ann drove")
	expect(result and result.places[1].seconds, "Ann's grid car was timed, not the parked one")
end)

World.test("a car of another player's named in ready is not timed for the racer who named it", function(world)
	local ann = world:join("Ann", 1000, 0)
	local bob = world:join("Bob", 1000, 1)
	local r = route("highway_race")
	atStart(ann, "highway_race")
	holdReady(world, {ann})
	request(world, ann, "highway_race", 0, {})
	local grid = last(world, ann, "grid")
	world.filter = nil
	-- Bob stands 5 m to the side of Ann's grid place and never moves.
	bob.car.pos = {x = grid.pose.pos.x - grid.pose.dir.y * 5, y = grid.pose.pos.y + grid.pose.dir.x * 5,
		z = grid.pose.pos.z}
	send(world, ann, {ready = {race = grid.id, car = bob.id .. "-0", opponents = {}}})
	world:advance(6)
	driveRoute(world, ann, r, 40)
	world:advance(1)
	local result = last(world, ann, "result")
	expect(result, "the race ended at Ann's own finish")
	expect(result and result.places[1].seconds, "Ann's own car was timed")
end)

World.test("cars that did not start: at most the rest of those asked for, and only from the starter", function(world)
	local ann = world:join("Ann", 1000, 0)
	local bob = world:join("Bob", 1000, 1)
	atStart(ann, "highway_race")
	holdReady(world, {ann, bob})
	request(world, ann, "highway_race", 2, {"Bob"})
	answer(world, bob, "join")
	local annGrid, bobGrid = last(world, ann, "grid"), last(world, bob, "grid")
	expect(annGrid and bobGrid, "both on the grid")
	world.filter = nil
	send(world, bob, {ready = {race = bobGrid.id, opponents = {}, failed = {"Bob's claim"}}})
	send(world, ann, {ready = {race = annGrid.id, opponents = {}, failed = {"A", "B", "C", "D", "E"}}})
	expect(last(world, ann, "countdown"), "the countdown started")
	world:advance(7)
	local rows = last(world, ann, "standings").rows
	local spawn, names = 0, {}
	for _, row in ipairs(rows) do
		if row.out == "spawn" then spawn = spawn + 1 end
		names[row.name] = true
	end
	same(spawn, 2, "two asked for, two listed as not started")
	same(names["Bob's claim"], nil, "a joined player cannot list cars that did not start")
	same(#rows, 4, "Ann, Bob and the two cars")
end)

World.test("a closing for another race while racing leaves this race and its card", function(world)
	local ann = world:join("Ann", 1000, 0)
	soloToGreen(world, ann)
	world:queue({way = "toClient", target = ann.id, event = "rxMileageSpotRace",
		data = World.encode({phase = "closed", id = "someone-elses", why = "The starter left."})})
	world:pump()
	world:as(ann, function() same(mileage_spotRace.inRace(), true, "still racing") end)
	same(lastCard(world, ann, "closed"), nil, "no closed card for a race this game is not in")
end)
