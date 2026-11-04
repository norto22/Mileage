-- Street races between players: a challenge to the end of the challenger's map route,
-- both stakes taken before anything else and held in data/races.json, the challenged car
-- moved beside the challenger's and both held for one countdown, then the result: the
-- faster finish within 5 s of the first wins both stakes (and the server prize when it
-- applies), a racer who leaves or gives up loses their stake, and nobody finishing in time
-- gets both back. Every case checks the money across saves.

local World = dofile("tests/money_world.lua")

local KM = {x = 0, y = 2400, z = 0}

local function pair(world, annMoney, bobMoney)
	local ann = world:join("Ann", annMoney or 10000)
	local bob = world:join("Bob", bobMoney or 10000)
	ann.car.pos = {x = 0, y = 0, z = 0}
	bob.car.pos = {x = 300, y = 900, z = 0}
	return ann, bob
end

-- finish false: no route set on the big map.
local function challenge(world, a, b, stake, finish)
	if finish == false then a.route = nil else a.route = finish or KM end
	local sent
	world:as(a, function() sent = mileage_offers.race(b.name, stake) end)
	world:pump()
	return sent
end

local function shownOffer(world, p)
	local closed = {}
	for _, c in ipairs(world:ui(p, "MileageOfferClosed")) do closed[c.id] = true end
	local last = nil
	for _, offer in ipairs(world:ui(p, "MileageOffer")) do
		if not closed[offer.id] then last = offer end
	end
	return last
end

local function accept(world, p)
	local offer = assert(shownOffer(world, p), "no challenge shown to " .. p.name)
	world:as(p, function() mileage_offers.answer(offer.id, true) end)
	world:pump()
end

-- A challenge accepted, through to the green on both games.
local function startRace(world, a, b, stake)
	challenge(world, a, b, stake)
	accept(world, b)
	world:advance(3)
	world.greenAt = world.now
end

local function races(world)
	local data = world:dataFile("races.json")
	local n, only = 0, nil
	for _, race in pairs(data and data.races or {}) do n, only = n + 1, race end
	return n, only
end

local function lastRaceMessage(world, p, phase)
	local found = nil
	for _, m in ipairs(world:received(p, "rxMileageRace")) do
		if m.phase == phase then found = m end
	end
	return found
end

-- Drives p to the finish, 2.4 km away, once they have been racing at least 30 s (the
-- server does not accept a quicker time: 2.4 km at 100 m/s is 24 s); their game reports on
-- its next frame.
local function arrive(world, p)
	local wait = 30 - (world.now - (world.greenAt or world.now))
	if wait > 0 then world:advance(wait) end
	assert(world:drive(p, KM.x + 5, KM.y), p.name .. "'s car is frozen")
	world:advance(1)
end

--== challenges and stakes =====================================================

World.test("accepting a challenge takes both stakes before anything else and keeps them in races.json",
		function(world)
	local ann, bob = pair(world)
	expect(challenge(world, ann, bob, 1000), "challenge sent")
	local offer = shownOffer(world, bob)
	same(offer.kind, "race", "kind")
	same(offer.distance, 2400, "distance shown to Bob")
	same(offer.amount, 1000, "stake shown to Bob")
	world.filter = function(m) if m.name == "mileageRaceReport" then return "drop" end end
	accept(world, bob)
	same(ann.money, 9000, "Ann's stake taken")
	same(bob.money, 9000, "Bob's stake taken")
	local n, race = races(world)
	same(n, 1, "one race kept")
	same(race.held.Ann, 1000, "Ann's stake held")
	same(race.held.Bob, 1000, "Bob's stake held")
	same(race.decision, "none", "no decision yet")
	same(lastRaceMessage(world, ann, "pose") ~= nil, true, "the start begins only after both stakes")
end)

World.test("a race with no stake takes nothing and goes straight to the start", function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 0)
	same(ann.money, 10000, "Ann")
	same(bob.money, 10000, "Bob")
	expect(lastRaceMessage(world, bob, "countdown"), "countdown sent")
end)

World.test("a racer without the stake calls the race off and the other stake comes back", function(world)
	local ann, bob = pair(world, 10000, 500)
	challenge(world, ann, bob, 1000)
	accept(world, bob)
	world:advance(2)
	same(ann.money, 10000, "Ann's stake back")
	same(bob.money, 500, "nothing taken from Bob")
	expect(lastRaceMessage(world, ann, "calledOff"), "Ann told")
	expect(lastRaceMessage(world, bob, "calledOff"), "Bob told")
	same(races(world), 0, "race record gone")
	same(world:savedTotal(), 10500, "total across saves")
end)

World.test("stakes that do not arrive in 15 s call the race off; one that arrives later is refunded", function(world)
	local ann, bob = pair(world)
	local holding = true
	world.filter = function(m)
		if holding and m.name == "mileageReceipt" and m.from == bob.id then return "drop" end
	end
	challenge(world, ann, bob, 1000)
	accept(world, bob)
	world:advance(9)
	same(lastRaceMessage(world, ann, "calledOff"), nil, "still staking at 9 s")
	world:advance(6)
	expect(lastRaceMessage(world, ann, "calledOff"), "called off at 15 s")
	same(ann.money, 10000, "Ann's stake back")
	same(bob.money, 9000, "Bob's stake taken, its receipt lost")
	holding = false
	world:advance(12)
	same(bob.money, 10000, "Bob's late stake refunded")
	same(races(world), 0, "race record gone")
	same(world:savedTotal(), 20000, "total across saves")
end)

World.test("a server restart with stakes held and no decision gives both stakes back", function(world)
	local ann, bob = pair(world)
	world.filter = function(m) if m.name == "mileageRaceReport" then return "drop" end end
	challenge(world, ann, bob, 1000)
	accept(world, bob)
	same(ann.savedMoney + bob.savedMoney, 18000, "both stakes held")
	world.filter = nil
	world:restart()
	world:advance(2)
	same(ann.money, 10000, "Ann")
	same(bob.money, 10000, "Bob")
	same(races(world), 0, "race record gone")
	expect(world:printedMatching("was under way when the server stopped") == 1, "logged")
end)

World.test("a server restart after the decision pays the winner once", function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	world.filter = function(m) if m.event == "rxMileageGive" then return "drop" end end
	arrive(world, ann)
	world:advance(6)
	local _, race = races(world)
	same(race.decision, "winner:Ann", "decision written before the payout")
	world.filter = nil
	world:restart()
	world:advance(2)
	same(ann.money, 11000, "Ann won Bob's stake")
	same(bob.money, 9000, "Bob")
	same(races(world), 0, "race record gone")
	same(world:savedTotal(), 20000, "total across saves")
end)

World.test("a challenge over the stake limit, too short, or with racing off is refused with a reason", function(world)
	local ann, bob = pair(world)
	local function refusedWhy(stake, finish)
		world:serverOutput(function()
			mileageOffer(ann.id, World.encode({kind = "race", to = bob.id, amount = stake, start = {x = 0, y = 0, z = 0},
				finish = finish or KM}))
		end)
		world:pump()
		local closed = world:received(ann, "rxMileageOfferClosed")
		return closed[#closed] and closed[#closed].why
	end
	same(refusedWhy(10001), "stakeMax", "over the limit")
	same(refusedWhy(-1), "stake", "negative")
	same(refusedWhy(10, {x = 0, y = 499, z = 0}), "distance", "shorter than 500 m")
	same(refusedWhy(10, {x = 0}), "finish", "no finish")
	world:setConfig("server", "allowRacing", "false")
	same(refusedWhy(10), "racingOff", "racing off")
	same(#world:ui(bob, "MileageOffer"), 0, "nothing shown to Bob")
end)

--== lining up =================================================================

World.test("the challenged car is moved 4 m right of the challenger's, both frozen until their own green",
		function(world)
	local ann, bob = pair(world)
	ann.car.pos = {x = 100, y = 200, z = 0}
	challenge(world, ann, bob, 0, {x = 100, y = 2600, z = 0})
	accept(world, bob)
	same(#bob.teleports, 1, "Bob moved once")
	local to = bob.teleports[1]
	same(to.pos.x, 104, "4 m to Ann's right")
	same(to.pos.y, 200, "level with Ann")
	same(to.rot.dir.y, 1, "facing the same way")
	same(#ann.teleports, 0, "Ann not moved")
	same(ann.car.frozen, true, "Ann held")
	same(bob.car.frozen, true, "Bob held")
	local countdown = lastRaceMessage(world, ann, "countdown")
	same(countdown.seconds, 3, "one 3-second countdown")
	world:advance(2)
	same(ann.car.frozen, true, "still held at 2 s")
	world:advance(1)
	same(ann.car.frozen, false, "Ann released on green")
	same(bob.car.frozen, false, "Bob released on green")
	local shown = world:ui(bob, "MileageRace")
	local phases = {}
	for _, m in ipairs(shown) do phases[m.phase] = true end
	expect(phases.countdown and phases.go, "countdown and green shown")
end)

World.test("Race is unavailable without a route, too close, on foot, in a mission or another's car", function(world)
	local ann, bob = pair(world)
	local function why(setup)
		ann.route, ann.inCar, ann.mission, ann.car.own = KM, nil, nil, nil
		setup()
		world:as(ann, function() mileage_offers.actionsFor("Bob") end)
		local actions = world:ui(ann, "MileagePlayerActions")
		return actions[#actions].race.why
	end
	same(why(function() ann.route = nil end), "Set a route on the big map first: its end is the finish line.", "no route")
	same(why(function() ann.route = {x = 0, y = 100, z = 0} end),
		"The finish is closer than this server's shortest race (500 m).", "too close")
	same(why(function() ann.inCar = false end), "Get in one of your own cars first.", "on foot")
	same(why(function() ann.mission = "delivery" end), "Finish or leave your mission first.", "in a mission")
	same(why(function() ann.car.own = false end), "Get in one of your own cars first.", "someone else's car")
	same(why(function() end), nil, "available")
	ann.route = nil
	same(challenge(world, ann, bob, 0, false), false, "nothing sent without a route")
	same(#world:ui(bob, "MileageOffer"), 0, "Bob saw nothing")
end)

World.test("racers who cannot line up in 15 s get their stakes back", function(world)
	local ann, bob = pair(world)
	world.filter = function(m)
		if m.name == "mileageRaceReport" and m.from == ann.id then return "drop" end
	end
	challenge(world, ann, bob, 1000)
	accept(world, bob)
	world:advance(16)
	expect(lastRaceMessage(world, bob, "calledOff"), "called off")
	world:advance(2)
	same(ann.money, 10000, "Ann")
	same(bob.money, 10000, "Bob")
	same(ann.car.frozen, false, "Ann released")
end)

World.test("a challenge accepted from outside a car, or in a mission, is declined and costs nothing", function(world)
	local ann, bob = pair(world)
	for _, setup in ipairs({function() bob.inCar = false end, function() bob.inCar, bob.mission = nil, "delivery" end,
			function() bob.mission, bob.car.JBeam = nil, "unicycle" end}) do
		bob.inCar, bob.mission, bob.car.JBeam = nil, nil, "pickup"
		setup()
		challenge(world, ann, bob, 1000)
		accept(world, bob)
		world:advance(2)
		same(ann.money + bob.money, 20000, "no stake taken")
		same(races(world), 0, "no race started")
		local toasts = world:ui(bob, "toastrMsg")
		same(toasts[#toasts].title, "Challenge declined", "Bob told why")
		local closed = world:received(ann, "rxMileageOfferClosed")
		same(closed[#closed].why, "declined", "Ann told it was declined")
	end
end)

World.test("a racer who is moved into a mission or out of their car before the start calls the race off",
		function(world)
	local ann, bob = pair(world)
	world.filter = function(m)
		if m.event == "rxMileageRace" and m.data:find('"teleport"', 1, true) then bob.mission = "delivery" end
	end
	challenge(world, ann, bob, 1000)
	accept(world, bob)
	world:advance(2)
	expect(lastRaceMessage(world, ann, "calledOff"), "called off")
	same(#bob.teleports, 0, "Bob's car was not moved")
	same(ann.money + bob.money, 20000, "stakes back")
	same(ann.car.frozen, false, "Ann released")
end)

World.test("an accepted challenge is checked again: a racer who joined another race meanwhile is busy",
		function(world)
	local ann, bob = pair(world)
	local cat = world:join("Cat", 10000)
	-- Cat and Ann both challenge Bob; Bob accepts Cat's, then Ann's.
	cat.car.pos = {x = 50, y = 0, z = 0}
	challenge(world, ann, bob, 1000)
	challenge(world, cat, bob, 500)
	local offers = world:ui(bob, "MileageOffer")
	same(#offers, 2, "two challenges shown")
	world:as(bob, function() mileage_offers.answer(offers[2].id, true) end)
	world:pump()
	-- Bob's game would decline this itself; a game that does not is answered by the server.
	world:serverOutput(function()
		mileageOfferAnswer(bob.id, World.encode({id = offers[1].id, accept = true}))
	end)
	world:pump()
	world:advance(2)
	local n, _ = races(world)
	same(n, 1, "one race only")
	local closed = world:received(ann, "rxMileageOfferClosed")
	same(closed[#closed].why, "busy", "Ann's challenge closed as busy")
	same(ann.money, 10000, "Ann paid nothing")
end)

--== the result ================================================================

World.test("the first racer to the finish wins both stakes; both see the result", function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	world:advance(120)
	arrive(world, ann)
	world:advance(2)
	arrive(world, bob)
	world:advance(2)
	same(ann.money, 11000, "Ann +$1,000")
	same(bob.money, 9000, "Bob -$1,000")
	same(world:savedTotal(), 20000, "total across saves")
	local result = lastRaceMessage(world, bob, "result")
	same(result.winner, "Ann", "winner on Bob's screen")
	same(result.times.Ann, 121, "Ann's time")
	same(result.times.Bob, 124, "Bob's time")
	same(ann.history[#ann.history].label, "Race win vs Bob", "Ann's money history")
	same(bob.history[#bob.history].label, "Race stake vs Ann", "Bob's money history")
	same(races(world), 0, "race record gone once paid")
end)

World.test("a game reports its finish once, timed from its own green, and shows the result", function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	arrive(world, ann)
	world:advance(5)
	local reports = 0
	for _, m in ipairs(world.serverLog) do
		if m.name == "mileageRaceReport" and m.from == ann.id and m.data:find("finished", 1, true) then
			reports = reports + 1
		end
	end
	same(reports, 1, "finish reported once while the car stays at the finish")
	same(lastRaceMessage(world, ann, "result").times.Ann, 31, "timed from the green: 30 s driving, 1 s frame")
	local shown = world:ui(ann, "MileageRace")
	same(shown[#shown].phase, "result", "result shown in the prompts app")
	world:as(ann, function() expect(not mileage_streetRace.giveUp(), "no race left to give up") end)
end)

World.test("a faster time reported within 5 s of the first wins, and a later one changes nothing", function(world)
	local ann, bob, cat = pair(world)
	startRace(world, ann, bob, 1000)
	local _, race = races(world)
	world:advance(130)
	-- Each car reaches the finish, and the report is sent before the game's own frame does.
	world:drive(ann, KM.x + 5, KM.y)
	world:serverOutput(function() mileageRaceReport(ann.id, World.encode({race = race.id, finished = 130})) end)
	world:advance(3)
	world:drive(bob, KM.x + 5, KM.y)
	world:serverOutput(function() mileageRaceReport(bob.id, World.encode({race = race.id, finished = 128})) end)
	world:advance(3)
	same(bob.money, 11000, "Bob won with the faster time reported second")
	same(ann.money, 9000, "Ann")
	world:serverOutput(function() mileageRaceReport(ann.id, World.encode({race = race.id, finished = 1})) end)
	world:advance(3)
	same(ann.money, 9000, "a report after the result changes nothing")
end)

World.test("with one report, the server decides 5 s after it", function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	arrive(world, ann)
	world:advance(4)
	same(lastRaceMessage(world, ann, "result"), nil, "no result before 5 s")
	world:advance(1)
	same(lastRaceMessage(world, ann, "result").winner, "Ann", "result at 5 s")
end)

World.test("a racer who leaves after the countdown loses their stake, paid once they are back", function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	world:advance(30)
	world:leave(bob, {crash = true})
	world:advance(2)
	same(ann.money, 11000, "Ann takes both stakes")
	same(lastRaceMessage(world, ann, "result").why, "left", "why")
	world:advance(120)
	world:rejoin(bob)
	world:advance(2)
	same(bob.money, 9000, "Bob's stake stays lost")
	same(world:savedTotal(), 20000, "total across saves")
end)

World.test("a racer who reached the finish first and then leaves still wins the stakes", function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	arrive(world, ann)
	-- Ann's game reported her finish; she quits before the server's 5 s wait is over.
	world:leave(ann)
	world:advance(10)
	world:rejoin(ann)
	world:advance(3)
	same(lastRaceMessage(world, bob, "result").winner, "Ann", "winner on Bob's screen")
	same(ann.money, 11000, "Ann, first to the finish")
	same(bob.money, 9000, "Bob, who never finished")
	same(world:savedTotal(), 20000, "total across saves")
end)

World.test("a winner who reached the finish keeps the server prize when the other racer then gives up or leaves",
		function(world)
	for _, how in ipairs({"gives up", "leaves"}) do
		local ann, bob = pair(world)
		world:setConfig("server", "racePrize", "500")
		startRace(world, ann, bob, 1000)
		arrive(world, ann)
		if how == "gives up" then
			world:as(bob, function() mileage_streetRace.giveUp() end)
			world:pump()
		else
			world:leave(bob)
		end
		world:advance(3)
		same(lastRaceMessage(world, ann, "result").winner, "Ann", "winner when the other racer " .. how)
		same(ann.money, 11500, "Ann: both stakes and the prize she finished for, when the other " .. how)
		world = World.new()
	end
end)

World.test("a racer who finished and went offline wins when the other racer then leaves too", function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	arrive(world, ann)
	world:leave(ann)
	world:leave(bob)
	world:advance(10)
	world:rejoin(ann)
	world:rejoin(bob)
	world:advance(5)
	same(ann.money, 11000, "Ann, who finished, is paid both stakes")
	same(bob.money, 9000, "Bob")
end)

-- Rejects a leave by a racer who already reported that ends the race for them at once:
-- the 5 s wait still runs, and a faster time reported in it wins.
World.test("a racer who reached the finish and left is still beaten by a faster time reported in the 5 s wait",
		function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	local _, race = races(world)
	world:advance(130)
	world:drive(ann, KM.x + 5, KM.y)
	world:serverOutput(function() mileageRaceReport(ann.id, World.encode({race = race.id, finished = 130})) end)
	world:leave(ann)
	world:advance(1)
	world:drive(bob, KM.x + 5, KM.y)
	world:serverOutput(function() mileageRaceReport(bob.id, World.encode({race = race.id, finished = 128})) end)
	world:advance(6)
	world:rejoin(ann)
	world:advance(3)
	same(lastRaceMessage(world, bob, "result").winner, "Bob", "the faster time wins")
	same(bob.money, 11000, "Bob")
	same(ann.money, 9000, "Ann")
	same(world:savedTotal(), 20000, "total across saves")
end)

-- Rejects a leaderboard that only counts a win for a racer still connected.
World.test("the win of a racer who finished and then left counts on the leaderboard for them", function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	arrive(world, ann)
	world:leave(ann)
	world:advance(10)
	local wins = world:dataFile("leaderboard.json").wins
	same(wins.Ann, 1, "Ann's win")
	same(wins.Bob, nil, "no win for Bob")
end)

World.test("from a settings file before the $2000 prizes, a finisher gets $2000 and the pair waits 5 minutes",
		function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	arrive(world, ann)
	world:advance(6)
	same(ann.money, 13000, "both stakes and the $2000 default")
	same(lastRaceMessage(world, ann, "result").prize, 2000, "result says $2000")
	ann.car.pos = {x = 0, y = 0, z = 0}
	world:advance(60)
	startRace(world, ann, bob, 1000)
	arrive(world, ann)
	world:advance(6)
	same(ann.money, 14000, "only the pot within the 5-minute wait")
	world:advance(300)
	ann.car.pos = {x = 0, y = 0, z = 0}
	startRace(world, ann, bob, 1000)
	arrive(world, ann)
	world:advance(6)
	same(ann.money, 17000, "the prize again after the wait")
end, {settingsFile = "old"})

-- Rejects a start that only fills missing settings (an owner's file still holding the old $0
-- prize would pay nothing) and a move that runs again on every start.
World.test("a settings file still holding the old $0 prize and 10-minute wait moves on start and pays $2000; a $0 set afterwards survives a restart",
		function(world)
	same(world:printedMatching("racePrize moved from 0 to 2000"), 1, "the console names the moved prize")
	same(world:printedMatching("racePrizeCooldownMinutes moved from 10 to 5"), 1, "and the moved wait")
	local saved = World.decode(world.disk["Resources/Server/Mileage/config/config.json"]).server
	same(saved.racePrize, 2000, "the prize saved at the new default")
	same(saved.racePrizeCooldownMinutes, 5, "the wait saved at the new default")
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	arrive(world, ann)
	world:advance(6)
	same(ann.money, 13000, "both stakes and the $2000 prize")
	world:setConfig("server", "racePrize", 0)
	world:restart()
	same(world:printedMatching("racePrize moved from 0 to 2000"), 1, "nothing moves on the second start")
	ann.car.pos = {x = 0, y = 0, z = 0}
	bob.car.pos = {x = 300, y = 900, z = 0}
	startRace(world, ann, bob, 1000)
	arrive(world, ann)
	world:advance(6)
	same(ann.money, 14000, "only the pot: the owner's $0 stayed after the restart")
end, {settingsFile = "old", server = {racePrize = 0, racePrizeCooldownMinutes = 10}})

-- Rejects a give-up path that always pays the prize: it needs the winner's own finish.
World.test("a racer who gives up before the other reached the finish earns them no server prize", function(world)
	local ann, bob = pair(world)
	world:setConfig("server", "racePrize", "500")
	startRace(world, ann, bob, 1000)
	world:advance(30)
	world:as(bob, function() mileage_streetRace.giveUp() end)
	world:pump()
	world:advance(2)
	same(ann.money, 11000, "Ann: both stakes, no prize")
	same(lastRaceMessage(world, ann, "result").prize, 0, "result says no prize")
end)

-- Rejects a forfeit path that pays the prize itself and skips the per-pair cooldown.
World.test("a winner who finished and whose opponent then gives up gets no second prize within the cooldown",
		function(world)
	local ann, bob = pair(world)
	world:setConfig("server", "racePrize", "500")
	startRace(world, ann, bob, 0)
	arrive(world, ann)
	world:advance(6)
	same(ann.money, 10500, "the first prize")
	ann.car.pos = {x = 0, y = 0, z = 0}
	startRace(world, ann, bob, 0)
	arrive(world, ann)
	world:as(bob, function() mileage_streetRace.giveUp() end)
	world:pump()
	world:advance(2)
	same(lastRaceMessage(world, ann, "result").winner, "Ann", "Ann won the second race")
	same(ann.money, 10500, "no second prize within the cooldown")
end)

World.test("a racer who gives up loses their stake to the other", function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	world:as(bob, function() mileage_streetRace.giveUp() end)
	world:pump()
	world:advance(2)
	same(ann.money, 11000, "Ann")
	same(bob.money, 9000, "Bob")
	same(lastRaceMessage(world, ann, "result").why, "gaveUp", "why")
end)

World.test("giving up or leaving before the countdown calls the race off", function(world)
	local ann, bob = pair(world)
	world.filter = function(m) if m.name == "mileageRaceReport" and m.from == ann.id and m.data:find("pose") then
		return "drop" end end
	challenge(world, ann, bob, 1000)
	accept(world, bob)
	world.filter = nil
	world:as(bob, function() mileage_streetRace.giveUp() end)
	world:pump()
	world:advance(2)
	same(ann.money + bob.money, 20000, "stakes back")
	expect(lastRaceMessage(world, ann, "calledOff"), "called off")
end)

World.test("both racers leaving gives both stakes back", function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	world:leave(ann)
	-- Ann's leave already gave Bob the race; this checks a race where both are gone first.
	local cat, dan = world:join("Cat", 5000), world:join("Dan", 5000)
	cat.car.pos, dan.car.pos = {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}
	startRace(world, cat, dan, 500)
	local catId, danId = cat.id, dan.id
	cat.connected, dan.connected = false, false
	world:serverOutput(function()
		onPlayerDisconnectHandler(catId)
		onPlayerDisconnectHandler(danId)
	end)
	world:pump()
	world:rejoin(cat)
	world:rejoin(dan)
	world:advance(2)
	same(cat.money, 5000, "Cat's stake back")
	same(dan.money, 5000, "Dan's stake back")
end)

World.test("nobody finishing within the time limit gives both stakes back", function(world)
	local ann, bob = pair(world)
	world:setConfig("server", "raceTimeLimitMinutes", "1")
	startRace(world, ann, bob, 1000)
	world:advance(58)
	same(lastRaceMessage(world, ann, "result"), nil, "running at 58 s")
	world:advance(3)
	same(lastRaceMessage(world, ann, "result").why, "timeout", "ended at the limit")
	world:advance(2)
	same(ann.money, 10000, "Ann")
	same(bob.money, 10000, "Bob")
end)

World.test("the server prize goes to a winner who finished, once per pair per cooldown", function(world)
	local ann, bob = pair(world)
	world:setConfig("server", "racePrize", "500")
	startRace(world, ann, bob, 1000)
	arrive(world, ann)
	world:advance(6)
	same(ann.money, 11500, "stakes and prize")
	same(bob.money, 9000, "Bob")
	ann.car.pos = {x = 0, y = 0, z = 0}
	startRace(world, ann, bob, 0)
	arrive(world, ann)
	world:advance(6)
	same(ann.money, 11500, "no prize again within the cooldown")
	same(lastRaceMessage(world, ann, "result").prize, 0, "result says no prize")
end)

World.test("a race win by the other leaving earns no prize", function(world)
	local ann, bob = pair(world)
	world:setConfig("server", "racePrize", "500")
	startRace(world, ann, bob, 0)
	world:leave(bob)
	world:advance(2)
	same(ann.money, 10000, "no prize")
end)

World.test("a player already racing cannot be challenged", function(world)
	local ann, bob = pair(world)
	local cat = world:join("Cat", 1000)
	startRace(world, ann, bob, 0)
	cat.route = KM
	world:serverOutput(function()
		mileageOffer(cat.id, World.encode({kind = "race", to = bob.id, amount = 0, start = {x = 0, y = 0, z = 0},
			finish = KM}))
	end)
	world:pump()
	local closed = world:received(cat, "rxMileageOfferClosed")
	same(closed[#closed].why, "busy", "refused")
end)

--== times a game could not have driven ========================================

World.test("a finish time that could not have been driven is ignored: too quick, or before green", function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	local _, race = races(world)
	local function report(p, seconds)
		world:serverOutput(function() mileageRaceReport(p.id, World.encode({race = race.id, finished = seconds})) end)
	end
	-- 2.4 km in a few hundredths of a second, in 5 s (480 m/s), or 100 s into a 3-second-old race.
	report(ann, 0.01)
	report(ann, 5)
	report(ann, 100)
	report(ann, -3)
	world:advance(8)
	same(lastRaceMessage(world, ann, "result"), nil, "no result from impossible times")
	same(ann.money, 9000, "Ann")
	same(bob.money, 9000, "Bob")
	-- A time that fits the 8 s since green and the 2.4 km is not one either (2.4 km in 8 s is 300 m/s).
	report(ann, 8)
	world:advance(6)
	same(lastRaceMessage(world, ann, "result"), nil, "300 m/s is too fast")
	-- A time a car could have driven, from a game whose car the server sees still at the start.
	world:advance(15)
	report(ann, 28)
	world:advance(6)
	same(lastRaceMessage(world, ann, "result"), nil, "a game that only says so does not win")
	same(ann.money, 9000, "Ann")
	-- Bob's car is at the finish and the time could have been driven.
	world:drive(bob, KM.x + 5, KM.y)
	report(bob, 28)
	world:advance(6)
	same(lastRaceMessage(world, ann, "result").winner, "Bob", "a time that could have been driven counts")
	same(bob.money, 11000, "Bob won the stakes")
end)

World.test("a time quicker than the server's own clock allows is ignored, even from a car at the finish", function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	local _, race = races(world)
	world:advance(60)
	world:drive(ann, KM.x + 5, KM.y)
	-- 60 s have passed since green; a game cannot have arrived with a time of 26 s.
	world:serverOutput(function() mileageRaceReport(ann.id, World.encode({race = race.id, finished = 26})) end)
	same(next(lastRaceMessage(world, ann, "result") or {}), nil, "no result from the quick time")
	-- The game's own report, taken at the finish, matches the server's clock and counts.
	world:advance(6)
	local time = lastRaceMessage(world, ann, "result").times.Ann
	expect(time >= 60 and time <= 63, "Ann's time matches the clock: " .. tostring(time))
end)

World.test("once car positions have been read, a racer whose car cannot be read is refused", function(world)
	local ann, bob = pair(world)
	startRace(world, ann, bob, 1000)
	local _, race = races(world)
	world:advance(40)
	ann.hideCar = true
	world:drive(ann, KM.x + 5, KM.y)
	world:drive(bob, KM.x + 5, KM.y)
	local function report(p, seconds)
		world:serverOutput(function() mileageRaceReport(p.id, World.encode({race = race.id, finished = seconds})) end)
	end
	-- Bob's car is read, so the server can see cars; Ann has no car it can read.
	report(bob, 41)
	report(ann, 41)
	world:advance(6)
	local result = lastRaceMessage(world, bob, "result")
	same(result.winner, "Bob", "Bob wins")
	same(result.times.Ann, nil, "Ann's time was not taken")
	same(world:printedMatching("cannot read cars' positions"), 0, "positions are readable here")
end)

World.test("a racer with no readable car is refused even when theirs is the first report on a freshly started server",
		function(world)
	local ann, bob = pair(world)
	ann.hideCar = true
	startRace(world, ann, bob, 1000)
	local _, race = races(world)
	world:advance(40)
	world:drive(ann, KM.x + 5, KM.y)
	world:serverOutput(function() mileageRaceReport(ann.id, World.encode({race = race.id, finished = 40})) end)
	world:advance(2)
	same(lastRaceMessage(world, ann, "result"), nil, "Ann's report was not taken")
	world:advance(10)
	arrive(world, bob)
	world:advance(6)
	local result = lastRaceMessage(world, bob, "result")
	same(result.winner, "Bob", "Bob, whose car the server sees, wins")
	same(result.times.Ann, nil, "Ann's time was never taken")
end)

World.test("with no car positions readable, a plausible finish time stands on the game's word and is logged once",
		function(world)
	local ann, bob = pair(world)
	-- This server never answers for a car's position (an older BeamMP, say).
	world.hidePositions = true
	startRace(world, ann, bob, 1000)
	local _, race = races(world)
	world:advance(40)
	world:drive(ann, KM.x + 5, KM.y)
	-- The server cannot see cars here: the report stands, and the console says so once.
	world:serverOutput(function() mileageRaceReport(ann.id, World.encode({race = race.id, finished = 40})) end)
	world:advance(6)
	same(lastRaceMessage(world, ann, "result").winner, "Ann", "the time stands")
	same(world:printedMatching("cannot read cars' positions"), 1, "logged once")
end)

World.test("a challenger who drove to the finish before lining up calls the race off", function(world)
	local ann, bob = pair(world)
	world.filter = function(m)
		if m.event == "rxMileageRace" and m.data:find('"pose"', 1, true) then ann.car.pos = {x = 0, y = 2390, z = 0} end
	end
	challenge(world, ann, bob, 1000)
	accept(world, bob)
	world:advance(2)
	expect(lastRaceMessage(world, ann, "calledOff"), "called off")
	same(#bob.teleports, 0, "Bob not moved")
	same(ann.money + bob.money, 20000, "stakes back")
end)

World.test("the challenged player is shown the finish on their map, with no route of their own", function(world)
	local ann, bob = pair(world)
	bob.route = nil
	startRace(world, ann, bob, 0)
	expect(bob.route, "a route set for Bob")
	same(bob.route.y, 2400, "to the finish")
end)

World.test("Mileage Transfers lists races still holding stakes", function(world)
	local ann, bob = pair(world)
	world.filter = function(m) if m.name == "mileageRaceReport" then return "drop" end end
	challenge(world, ann, bob, 1000)
	accept(world, bob)
	local lines = world:console("Mileage Transfers")
	same(countLines(lines, "Races holding stakes: 1"), 1, "count line")
	same(countLines(lines, "Ann vs Bob, $1000 stake, $2000 held, none"), 1, "race line")
end)
