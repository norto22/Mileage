-- The server leaderboard: race wins counted by the server, each player's best drag run
-- per strip reported by their own game, the top 10 of each on request, all kept in
-- data/leaderboard.json across restarts, and `Mileage Leaderboard [reset]`.

local World = dofile("tests/money_world.lua")

local STRIP = "alder_dragway"

-- p's game at the strip, its car finishing a run the game timed at et, trap m/s.
local function dragRun(world, p, et, trap, opts)
	opts = opts or {}
	p.extensions.mileage_dragLobby = {getLocalStripId = function() return opts.strip ~= false and STRIP or nil end}
	p.dragData = {importantTimerId = "time_1_4", racers = {
		[p.car.id] = {isDisqualified = opts.disqualified or false, timers = {
			time_1_4 = {value = et, isSet = true}, velAt_1_4 = {value = trap, isSet = true}}},
	}}
	world:hook(p, "dragRaceEndLineReached", opts.vehId or p.car.id)
	world:pump()
end

local function leaderboardFor(world, p)
	world:as(p, function() mileage_leaderboard.request() end)
	world:pump()
	local shown = world:ui(p, "MileageLeaderboard")
	return shown[#shown]
end

local function sendTime(world, p, run)
	world:serverOutput(function() mileageDragTime(p.id, World.encode(run)) end)
end

World.test("a drag run reported by the racer's own game is on the leaderboard after a restart", function(world)
	local ann, bob = world:join("Ann", 0), world:join("Bob", 0)
	dragRun(world, ann, 10.84, 56.4)
	world:restart()
	local board = leaderboardFor(world, bob)
	same(board.drag[STRIP][1].name, "Ann", "Ann's run")
	same(board.drag[STRIP][1].et, 10.84, "her time")
	same(board.drag[STRIP][1].trap, 56.4, "her trap speed")
end)

World.test("only a faster run replaces a player's best on a strip", function(world)
	local ann = world:join("Ann", 0)
	dragRun(world, ann, 11.5, 50)
	dragRun(world, ann, 12.1, 49)
	dragRun(world, ann, 11.2, 51)
	same(world:dataFile("leaderboard.json").drag[STRIP].Ann.et, 11.2, "best kept")
end)

World.test("another player's car, a disqualified run, no strip or the same run twice is not reported", function(world)
	local ann = world:join("Ann", 0)
	dragRun(world, ann, 11, 50, {vehId = 4242})
	dragRun(world, ann, 11, 50, {disqualified = true})
	dragRun(world, ann, 11, 50, {strip = false})
	same(world:dataFile("leaderboard.json"), nil, "nothing kept")
	dragRun(world, ann, 11, 50)
	dragRun(world, ann, 11, 50)
	local sent = 0
	for _, m in ipairs(world.serverLog) do if m.name == "mileageDragTime" then sent = sent + 1 end end
	same(sent, 1, "one report for the one run")
end)

World.test("a time outside 3 to 60 s or a bad strip id is ignored", function(world)
	local ann = world:join("Ann", 0)
	sendTime(world, ann, {strip = STRIP, et = 2.9, trap = 50})
	sendTime(world, ann, {strip = STRIP, et = 61, trap = 50})
	sendTime(world, ann, {strip = "bad\nstrip", et = 11, trap = 50})
	sendTime(world, ann, {strip = STRIP, et = "11", trap = 50})
	same(world:dataFile("leaderboard.json"), nil, "nothing kept")
end)

World.test("race wins are counted by the server and survive a restart", function(world)
	local ann, bob = world:join("Ann", 10000), world:join("Bob", 10000)
	ann.car.pos, bob.car.pos = {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}
	for _ = 1, 2 do
		ann.route = {x = 0, y = 2400, z = 0}
		ann.car.pos = {x = 0, y = 0, z = 0}
		world:as(ann, function() mileage_offers.race("Bob", 0) end)
		world:pump()
		local offers = world:ui(bob, "MileageOffer")
		world:as(bob, function() mileage_offers.answer(offers[#offers].id, true) end)
		world:pump()
		world:advance(3)
		-- Quicker than the straight line at 150 m/s would be an impossible time.
		world:advance(30)
		world:drive(ann, 0, 2400)
		world:advance(7)
	end
	world:restart()
	local board = leaderboardFor(world, bob)
	same(board.wins[1].name, "Ann", "Ann leads")
	same(board.wins[1].wins, 2, "two wins")
end)

World.test("the answer holds the top 10 of each, sorted", function(world)
	local players = {}
	for i = 1, 12 do players[i] = world:join("P" .. i, 0) end
	for i, p in ipairs(players) do sendTime(world, p, {strip = STRIP, et = 20 - i, trap = 40}) end
	local board = leaderboardFor(world, players[1])
	same(#board.drag[STRIP], 10, "ten times")
	same(board.drag[STRIP][1].name, "P12", "fastest first")
	same(board.drag[STRIP][10].name, "P3", "tenth")
end)

-- A leaderboard file already holding spot times: city_race_1 for P1 to P12 (P12 fastest),
-- and Ann's at the highway race. The plugin reads it on its next start.
local function storedSpotTimes(world)
	local times = {}
	for i = 1, 12 do times["P" .. i] = {time = 300 - i, at = 1} end
	world.disk["Resources/Server/Mileage/data/leaderboard.json"] = World.encode({wins = {Ann = 3}, drag = {},
		spots = {city_race_1 = times, highway_race = {Ann = {time = 61.25, at = 1}}}})
	world:restart()
end

World.test("each race spot route has its ten fastest players on the board, named as on the map", function(world)
	local ann = world:join("Ann", 0)
	storedSpotTimes(world)
	local board = leaderboardFor(world, ann)
	local city = board.spots.city_race_1
	same(city.name, "City Race 1", "the route's name")
	same(#city.rows, 10, "ten times")
	same(city.rows[1].name, "P12", "fastest first")
	same(city.rows[1].time, 288, "with the time")
	same(city.rows[10].name, "P3", "tenth")
	same(board.spots.highway_race.rows[1].name, "Ann", "another route")
	same(board.wins[1].wins, 3, "the wins are still there")
end)

World.test("the set-up card's status carries the best time at each route and the player's own", function(world)
	local ann = world:join("Ann", 0)
	storedSpotTimes(world)
	local statuses = {}
	for _, m in ipairs(world:received(ann, "rxMileageSpotRace")) do
		if m.phase == "status" then table.insert(statuses, m) end
	end
	local status = statuses[#statuses]
	same(status.best.city_race_1.name, "P12", "the best at City Race 1")
	same(status.best.city_race_1.time, 288, "its time")
	same(status.mine.highway_race, 61.25, "Ann's own at the highway race")
	same(status.mine.city_race_1, nil, "none of Ann's at City Race 1")
end)

World.test("Mileage Leaderboard prints spot times and reset clears them", function(world)
	local ann = world:join("Ann", 0)
	storedSpotTimes(world)
	local lines = world:console("Mileage Leaderboard")
	same(countLines(lines, "best times at City Race 1"), 1, "route heading")
	same(countLines(lines, "P12: 4:48.00"), 1, "the fastest line")
	world:console("Mileage Leaderboard reset")
	world:restart()
	same(next(leaderboardFor(world, ann).spots), nil, "no spot times after reset and restart")
end)

World.test("Mileage Leaderboard prints the lists and reset clears them", function(world)
	local ann = world:join("Ann", 0)
	sendTime(world, ann, {strip = STRIP, et = 10.5, trap = 50})
	local lines = world:console("Mileage Leaderboard")
	same(countLines(lines, "best drag times at alder_dragway"), 1, "strip heading")
	same(countLines(lines, "Ann: 10.500 s, 180 km/h"), 1, "Ann's line")
	same(countLines(world:console("Mileage Leaderboard reset"), "Leaderboard reset"), 1, "reset line")
	world:restart()
	same(next(leaderboardFor(world, ann).drag), nil, "empty after reset and restart")
	same(countLines(world:console("Mileage Leaderboard bogus"), "Usage: Mileage Leaderboard [reset]"), 1, "usage")
end)
