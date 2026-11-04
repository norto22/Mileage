-- The Plan's oracle, run as one session of three players on the real server and client
-- files: with the server prize off, a $1,000-stake race between two of them ends with the
-- winner exactly $1,000 up, the loser $1,000 down and the third player unchanged, the
-- total across all three saves unchanged, and the win on the leaderboard after a server
-- restart; and the same when the loser's game disconnects mid-race and rejoins later.
-- Then several races, payments and requests at once between four players, which must not
-- mix.

local World = dofile("tests/money_world.lua")

local FINISH = {x = 0, y = 2400, z = 0}

local function players(world, names)
	local list = {}
	for i, name in ipairs(names) do
		list[i] = world:join(name, 10000)
		list[i].car.pos = {x = i * 200, y = 0, z = 0}
	end
	return (table.unpack or unpack)(list)
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

-- a challenges b to FINISH (from a's own position) for stake; b accepts.
local function race(world, a, b, stake)
	a.route = {x = a.car.pos.x, y = a.car.pos.y + 2400, z = 0}
	world:as(a, function() assert(mileage_offers.race(b.name, stake), "challenge not sent") end)
	world:pump()
	local offer = assert(shownOffer(world, b), "challenge not shown")
	world:as(b, function() mileage_offers.answer(offer.id, true) end)
	world:pump()
	return a.route
end

local function arrive(world, p, finish)
	assert(world:drive(p, finish.x, finish.y), p.name .. " still frozen")
end

local function winsFor(world, p, name)
	world:as(p, function() mileage_leaderboard.request() end)
	world:pump()
	local boards = world:ui(p, "MileageLeaderboard")
	for _, entry in ipairs(boards[#boards].wins) do
		if entry.name == name then return entry.wins end
	end
	return 0
end

World.test("oracle: a $1,000 race between two of three players, checked after a restart", function(world)
	local ann, bob, cat = players(world, {"Ann", "Bob", "Cat"})
	local finish = race(world, ann, bob, 1000)
	same(bob.teleports[1].pos.x, ann.car.pos.x + 4, "Bob moved beside Ann")
	world:advance(3)
	world:advance(90)
	arrive(world, ann, finish)
	world:advance(4)
	arrive(world, bob, finish)
	world:advance(6)
	world:restart()
	world:advance(2)
	same(ann.savedMoney, 11000, "Ann exactly $1,000 up")
	same(bob.savedMoney, 9000, "Bob exactly $1,000 down")
	same(cat.savedMoney, 10000, "Cat unchanged")
	same(world:savedTotal(), 30000, "total across the three saves")
	same(winsFor(world, cat, "Ann"), 1, "Ann's win on the leaderboard after the restart")
end)

World.test("oracle: the same when the loser's game disconnects mid-race and rejoins later", function(world)
	local ann, bob, cat = players(world, {"Ann", "Bob", "Cat"})
	race(world, ann, bob, 1000)
	world:advance(3)
	world:advance(40)
	world:leave(bob, {crash = true})
	world:advance(30)
	same(ann.savedMoney, 11000, "Ann paid while Bob is away")
	world:advance(600)
	world:rejoin(bob)
	world:advance(12)
	world:restart()
	world:advance(2)
	same(ann.savedMoney, 11000, "Ann exactly $1,000 up")
	same(bob.savedMoney, 9000, "Bob exactly $1,000 down")
	same(cat.savedMoney, 10000, "Cat unchanged")
	same(world:savedTotal(), 30000, "total across the three saves")
	same(winsFor(world, cat, "Ann"), 1, "Ann's win on the leaderboard after the restart")
end)

--== a staked drag race ========================================================

local STRIP = "alderStrip"
-- The server's copy of the West Coast strip's lines, lane 1 and lane 2.
local STAGE = {{x = -189.67, y = -157.72, z = 119.38}, {x = -194.83, y = -150.53, z = 119.38}}
local END_LINE = {{x = 134.17, y = 77.52, z = 119.38}, {x = 129.19, y = 84.24, z = 119.38}}
local STAKE, PRIZE = 1000, 2500

local function sendAs(world, p, event, message)
	world:queue({way = "toServer", from = p.id, name = event, data = World.encode(message)})
	world:pump()
end

local function toLine(world, p, lane)
	world:serverOutput(function()
		dragMP(p.id, World.encode({msg = "mileageDragJoin", to = "host", data = {stripId = STRIP, lane = lane}}))
	end)
	world:drive(p, STAGE[lane].x, STAGE[lane].y, STAGE[lane].z)
end

-- a challenges b for STAKE, b accepts; at the strip a leads, a run goes green, b jumps the
-- start and reports the faster time, a finishes cleanly. opts.restart: the server restarts
-- once the pot is given and before the prize is.
local function dragOracle(world, opts)
	local ann, bob, cat = players(world, {"Ann", "Bob", "Cat"})
	local before = {ann = ann.savedMoney, bob = bob.savedMoney, total = world:savedTotal()}
	world:as(ann, function() assert(mileage_offers.dragRace("Bob", STAKE), "challenge not sent") end)
	world:pump()
	local offer = assert(shownOffer(world, bob), "challenge not shown")
	world:as(bob, function() mileage_offers.answer(offer.id, true) end)
	world:pump()
	toLine(world, ann, 1)
	toLine(world, bob, 2)
	local run = STRIP .. "-42"
	sendAs(world, ann, "mileageDragRun", {phase = "start", strip = STRIP, run = run, dragType = "headsUpRace",
		racers = {{id = ann.id, lane = 1}, {id = bob.id, lane = 2}}})
	sendAs(world, ann, "mileageDragStaged", {run = run})
	sendAs(world, bob, "mileageDragStaged", {run = run})
	sendAs(world, ann, "mileageDragRun", {phase = "green", run = run})
	sendAs(world, bob, "mileageDragResult", {run = run, outcome = "jumped"})
	world:drive(bob, END_LINE[2].x, END_LINE[2].y, END_LINE[2].z)
	sendAs(world, bob, "mileageDragResult", {run = run, outcome = "finished", winTime = 9.6, dial = 0})
	if opts.restart then
		world.filter = function(m)
			if m.event == "rxMileageGive" and m.data:find("Drag race prize", 1, true) then return "drop" end
		end
	end
	world:drive(ann, END_LINE[1].x, END_LINE[1].y, END_LINE[1].z)
	sendAs(world, ann, "mileageDragResult", {run = run, outcome = "finished", winTime = 11.9, dial = 0})
	if opts.restart then
		same(ann.savedMoney, before.ann + STAKE, "the pot given, the prize not yet")
		world.filter = nil
		world:restart()
	end
	world:advance(12)
	same(ann.savedMoney - before.ann, STAKE + PRIZE, "A exactly the stake plus the prize better off")
	same(bob.savedMoney - before.bob, -STAKE, "B exactly the stake worse off")
	same(world:savedTotal() - before.total, PRIZE, "the players together exactly the prize better off")
	same(cat.savedMoney, 10000, "the third player unchanged")
	same(next(world:dataFile("transfers.json").transfers), nil, "nothing left waiting")
	same(next(world:dataFile("races.json").races), nil, "no race left holding stakes")
end

World.test("oracle: B jumps the start with the faster time, A finishes; a restart mid-payout changes nothing",
		function(world)
	dragOracle(world, {restart = true})
end, {server = {dragRacePrize = PRIZE}})

World.test("oracle: the same staked drag race without a restart gives the same three numbers", function(world)
	dragOracle(world, {})
end, {server = {dragRacePrize = PRIZE}})

World.test("several races, payments and requests at once between four players do not mix", function(world)
	local ann, bob, cat, dan = players(world, {"Ann", "Bob", "Cat", "Dan"})
	local finishAB = race(world, ann, bob, 1000)
	local finishCD = race(world, cat, dan, 300)
	-- While both races line up: Dan pays Bob, Cat asks Ann for money and Ann pays.
	world:as(dan, function() mileagePlayerPayments.onUpdate(3); mileagePlayerPayments.payPlayer("Bob", 50) end)
	world:as(cat, function() mileage_offers.request("Ann", 200) end)
	world:pump()
	local request = assert(shownOffer(world, ann), "request shown to Ann")
	world:as(ann, function() mileage_offers.answer(request.id, true) end)
	world:pump()
	world:advance(3)
	world:advance(60)
	arrive(world, bob, finishAB)
	arrive(world, cat, finishCD)
	world:advance(2)
	arrive(world, ann, finishAB)
	arrive(world, dan, finishCD)
	world:advance(10)
	same(ann.money, 10000 - 1000 - 200, "Ann lost her race and paid Cat's request")
	same(bob.money, 10000 + 1000 + 50, "Bob won and was paid by Dan")
	same(cat.money, 10000 + 300 + 200, "Cat won her race and got Ann's payment")
	same(dan.money, 10000 - 300 - 50, "Dan lost his race and paid Bob")
	same(world:savedTotal(), 40000, "total across the four saves")
	local data = world:dataFile("transfers.json")
	same(next(data.transfers), nil, "nothing left waiting")
	same(next(world:dataFile("races.json").races), nil, "no race left holding stakes")
end)
