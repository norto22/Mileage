-- Drag money: the server decides a two-player drag run from the strip leader's start and
-- green and each racer's own reports, by the game's heads-up or bracket rule, and pays the
-- owner's drag prize to the winner of every decided run. Only a run both racers' games
-- confirmed, at the server's own copy of the strip, counts. Every case checks the money in
-- the players' saves.

local World = dofile("tests/money_world.lua")

local STRIP = "alderStrip"
-- The server's copy of the West Coast strip's lines, lane 1 and lane 2.
local STAGE = {{x = -189.67, y = -157.72, z = 119.38}, {x = -194.83, y = -150.53, z = 119.38}}
local FINISH = {{x = 134.17, y = 77.52, z = 119.38}, {x = 129.19, y = 84.24, z = 119.38}}
local PRIZE = 2500

local function send(world, p, event, message)
	world:queue({way = "toServer", from = p.id, name = event, data = World.encode(message)})
	world:pump()
end

local function atStrip(world, p, lane)
	world:serverOutput(function()
		dragMP(p.id, World.encode({msg = "mileageDragJoin", to = "host", data = {stripId = STRIP, lane = lane}}))
	end)
	world:pump()
	world:drive(p, STAGE[lane].x, STAGE[lane].y, STAGE[lane].z)
end

-- Ann (lane 1, the strip's leader, first there) and Bob (lane 2), both at the line.
local function pair(world, annMoney, bobMoney)
	local ann = world:join("Ann", annMoney or 10000)
	local bob = world:join("Bob", bobMoney or 10000)
	atStrip(world, ann, 1)
	atStrip(world, bob, 2)
	return ann, bob
end

local runSeq = 0

-- The strip leader's green for run id, at the server's clock now.
local function green(world, leader, id)
	send(world, leader, "mileageDragRun", {phase = "green", run = id})
	world.greenAt = world.now
end

-- The leader starts a run of a (lane 1) and b (lane 2). opts.staged = false: nobody stages;
-- opts.unstaged = p: that racer does not; opts.green = false: no green.
local function run(world, leader, a, b, opts)
	opts = opts or {}
	runSeq = runSeq + 1
	local id = opts.id or (STRIP .. "-" .. runSeq)
	send(world, leader, "mileageDragRun", {phase = "start", strip = opts.strip or STRIP, run = id,
		racers = opts.racers or {{id = a.id, lane = 1}, {id = b.id, lane = 2}}, dragType = opts.dragType or "headsUpRace"})
	if opts.staged ~= false then
		for _, p in ipairs({a, b}) do
			if p ~= opts.unstaged then
				send(world, p, "mileageDragStaged", {run = id,
					dragType = (opts.stagedTypes and opts.stagedTypes[p]) or opts.dragType or "headsUpRace"})
			end
		end
	end
	world.greenAt = nil
	if opts.green ~= false then green(world, leader, id) end
	return id
end

-- p's own game reports its run: finished in winTime (at its end line unless opts.far), or jumped.
-- The game reports as its car crosses the line, so the clock first runs to winTime after the
-- green (opts.now: report at once, whatever the clock says).
local function finish(world, p, id, lane, winTime, opts)
	opts = opts or {}
	local wait = world.greenAt and math.ceil(winTime) - (world.now - world.greenAt) or 0
	if wait > 0 and not opts.now then world:advance(wait) end
	if not opts.far then world:drive(p, FINISH[lane].x, FINISH[lane].y, FINISH[lane].z) end
	send(world, p, "mileageDragResult", {run = id, outcome = "finished", winTime = winTime, dial = opts.dial})
end

local function jumped(world, p, id)
	send(world, p, "mileageDragResult", {run = id, outcome = "jumped"})
end

local function lastCard(world, p)
	local cards = world:received(p, "rxMileageDragRace")
	return cards[#cards]
end

local function prizeLines(p)
	local n = 0
	for _, entry in ipairs(p.history) do
		if entry.label and entry.label:find("Drag race prize", 1, true) then n = n + 1 end
	end
	return n
end

local withPrize = {server = {dragRacePrize = PRIZE}}

--== the owner's setting =======================================================

World.test("the games are told the drag prize, held within 0 to 1,000,000", function(world)
	local ann = world:join("Ann", 0)
	world:setConfig("server", "dragRacePrize", 2000000)
	local features = world:received(ann, "rxMileageFeatures")
	same(features[#features].dragRacePrize, 1000000, "clamped to the top")
	world:setConfig("server", "dragRacePrize", "lots")
	features = world:received(ann, "rxMileageFeatures")
	same(features[#features].dragRacePrize, 0, "text reads as 0")
end)

--== a run that counts =========================================================

World.test("a counted two-player run pays the owner's prize to the faster racer", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob)
	finish(world, ann, id, 1, 11.2)
	finish(world, bob, id, 2, 11.9)
	same(ann.savedMoney, 10000 + PRIZE, "Ann's prize in her save")
	same(bob.savedMoney, 10000, "Bob's money unchanged")
	same(ann.history[#ann.history].label, "Drag race prize vs Bob", "Ann's history")
	local card = lastCard(world, bob)
	same(card.phase, "result", "Bob's card")
	same(card.winner, "Ann", "winner shown to Bob")
	same(card.prize, PRIZE, "prize shown")
	same(lastCard(world, ann).you, "Ann", "Ann's own card")
	expect(world:printedMatching("Ann beat Bob, prize $2500") == 1, "console logs the prize")
end, withPrize)

World.test("the result card reaches the prompts app once; a UI reload does not bring it back", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob)
	finish(world, ann, id, 1, 11.2)
	finish(world, bob, id, 2, 11.9)
	local shown = world:ui(bob, "MileageDragRace")
	same(#shown, 1, "one card on Bob's screen")
	same(shown[1].winner, "Ann", "who won")
	world:as(bob, function() mileage_dragMoney.sendState() end)
	same(#world:ui(bob, "MileageDragRace"), 1, "not shown again")
end, withPrize)

World.test("every win pays the prize again, with no wait", function(world)
	local ann, bob = pair(world)
	for _ = 1, 2 do
		local id = run(world, ann, ann, bob)
		finish(world, ann, id, 1, 11.2)
		finish(world, bob, id, 2, 11.9)
		atStrip(world, ann, 1)
		atStrip(world, bob, 2)
	end
	same(ann.savedMoney, 10000 + 2 * PRIZE, "two prizes")
	same(prizeLines(ann), 2, "two history lines")
end, withPrize)

World.test("with the prize at 0 a run pays nothing and shows no card", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob)
	finish(world, ann, id, 1, 11.2)
	finish(world, bob, id, 2, 11.9)
	same(world:savedTotal(), 20000, "nothing paid")
	same(#world:received(ann, "rxMileageDragRace"), 0, "no card")
end)

--== what the server refuses to count ==========================================

World.test("a run the other racer's game never confirmed staged pays nothing", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob, {unstaged = bob})
	finish(world, ann, id, 1, 11.2)
	finish(world, bob, id, 2, 11.9)
	world:advance(80)
	same(world:savedTotal(), 20000, "nothing paid")
	expect(world:printedMatching("Bob's game never said it was staged") == 1, "logged why")
end, withPrize)

World.test("a car away from its start line at the green makes the run count for nothing", function(world)
	local ann, bob = pair(world)
	world:drive(bob, 0, 0, 0)
	local id = run(world, ann, ann, bob)
	finish(world, ann, id, 1, 11.2)
	finish(world, bob, id, 2, 11.9)
	world:advance(80)
	same(world:savedTotal(), 20000, "nothing paid with Bob away")
	expect(world:printedMatching("Bob's car is not at the start line") == 1, "logged why")
end, withPrize)

World.test("where the server cannot read positions the run and its finishes stand on the games' word", function(world)
	world.hidePositions = true
	local ann, bob = pair(world)
	world:drive(bob, 0, 0, 0)
	local id = run(world, ann, ann, bob)
	finish(world, ann, id, 1, 11.2, {far = true})
	finish(world, bob, id, 2, 11.9, {far = true})
	same(ann.savedMoney, 10000 + PRIZE, "paid")
end, withPrize)

World.test("a start from anyone but the strip's leader, at an unknown strip, or not two players in two lanes at it, is ignored",
		function(world)
	local ann, bob = pair(world)
	local cara = world:join("Cara", 0)
	local cases = {
		{leader = bob},
		{strip = "otherStrip", id = "otherStrip-1"},
		{id = "wrongStrip-7"},
		{racers = {{id = ann.id, lane = 1}, {id = bob.id, lane = 1}}},
		{racers = {{id = ann.id, lane = 1}, {id = ann.id, lane = 2}}},
		{racers = {{id = ann.id, lane = 1}, {id = cara.id, lane = 2}}},
		{racers = {{id = ann.id, lane = 1}, {id = bob.id, lane = 3}}},
		{racers = {{id = ann.id, lane = 1}}},
		{dragType = "sprint"},
	}
	for _, case in ipairs(cases) do
		local id = run(world, case.leader or ann, ann, bob, case)
		finish(world, ann, id, 1, 11.2)
		finish(world, bob, id, 2, 11.9)
	end
	world:advance(80)
	same(world:savedTotal(), 20000, "nothing paid")
end, withPrize)

World.test("a report from someone not in the run, a second report, a finish before the green or a time out of range is ignored",
		function(world)
	local ann, bob = pair(world)
	local cara = world:join("Cara", 0)
	local id = run(world, ann, ann, bob, {green = false})
	finish(world, bob, id, 2, 10.0, {far = true})
	green(world, ann, id)
	finish(world, cara, id, 2, 5.0)
	finish(world, bob, id, 2, 2.5, {now = true})
	finish(world, bob, id, 2, 61, {now = true})
	send(world, bob, "mileageDragResult", {run = id, outcome = "finished", winTime = "9"})
	finish(world, bob, id, 2, 11.9)
	finish(world, bob, id, 2, 9.0)
	finish(world, ann, id, 1, 11.2)
	same(ann.savedMoney, 10000 + PRIZE, "Ann's 11.2 beat Bob's one counted report, 11.9")
	same(cara.savedMoney, 0, "Cara nothing")
end, withPrize)

World.test("a time quicker than the server's own clock since the green, or than the strip can be driven, is refused",
		function(world)
	world.hidePositions = true
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob)
	world:advance(3)
	finish(world, bob, id, 2, 3.5, {now = true, far = true})
	world:advance(9)
	finish(world, bob, id, 2, 4.0, {now = true, far = true})
	finish(world, ann, id, 1, 11.8, {far = true})
	world:advance(70)
	same(ann.savedMoney, 10000 + PRIZE, "Ann's real time wins, even where positions cannot be read")
	same(bob.savedMoney, 10000, "Bob's made-up times paid nothing")
	expect(world:printedMatching("Bob's time does not match the server's clock") == 2, "both refusals logged")
end, withPrize)

World.test("a racer whose game runs another race type than the leader named makes the run count for nothing",
		function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob, {dragType = "bracketRace", stagedTypes = {[bob] = "headsUpRace"}})
	finish(world, ann, id, 1, 12.30, {dial = 12.29})
	finish(world, bob, id, 2, 12.50)
	world:advance(80)
	same(world:savedTotal(), 20000, "nothing paid")
	expect(world:printedMatching("Bob's game runs another race type than the leader named") == 1, "logged why")
end, withPrize)

World.test("a jump start reported before the green still counts against the jumper", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob, {green = false})
	jumped(world, bob, id)
	green(world, ann, id)
	finish(world, ann, id, 1, 12.5)
	same(ann.savedMoney, 10000 + PRIZE, "Ann wins")
	same(lastCard(world, ann).why, "jumped", "Bob jumped")
end, withPrize)

World.test("a run that never goes green is forgotten after 120 s, and an ended run before the green at once", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob, {green = false})
	world:advance(121)
	send(world, ann, "mileageDragRun", {phase = "green", run = id})
	finish(world, ann, id, 1, 11.2)
	finish(world, bob, id, 2, 11.9)
	atStrip(world, ann, 1)
	atStrip(world, bob, 2)
	id = run(world, ann, ann, bob, {green = false})
	send(world, ann, "mileageDragRun", {phase = "ended", run = id})
	send(world, ann, "mileageDragRun", {phase = "green", run = id})
	finish(world, ann, id, 1, 11.2)
	finish(world, bob, id, 2, 11.9)
	world:advance(80)
	same(world:savedTotal(), 20000, "nothing paid")
end, withPrize)

--== the winner rule ===========================================================

World.test("a jumper who reports the faster time loses: the clean finisher gets the prize", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob)
	jumped(world, bob, id)
	finish(world, bob, id, 2, 9.5)
	finish(world, ann, id, 1, 11.8)
	same(ann.savedMoney, 10000 + PRIZE, "Ann's prize")
	same(bob.savedMoney, 10000, "Bob unchanged")
	local card = lastCard(world, bob)
	same(card.outcomes.Bob, "jumped", "Bob shown as jumped")
	same(card.outcomes.Ann, "finished", "Ann finished")
end, withPrize)

World.test("bracket: closest above the dial wins, then the smallest break-out, and no dial ranks last", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob, {dragType = "bracketRace"})
	finish(world, ann, id, 1, 12.30, {dial = 12.20})
	finish(world, bob, id, 2, 10.05, {dial = 10.00})
	same(bob.savedMoney, 10000 + PRIZE, "Bob 0.05 over his dial beats Ann 0.10 over, though slower to the line")
	atStrip(world, ann, 1)
	atStrip(world, bob, 2)
	id = run(world, ann, ann, bob, {dragType = "bracketRace"})
	finish(world, ann, id, 1, 12.30, {dial = 12.20})
	finish(world, bob, id, 2, 9.99, {dial = 10.00})
	same(ann.savedMoney, 10000 + PRIZE, "Bob broke out: Ann over her dial wins")
	atStrip(world, ann, 1)
	atStrip(world, bob, 2)
	id = run(world, ann, ann, bob, {dragType = "bracketRace"})
	finish(world, ann, id, 1, 14.0, {dial = 12.0})
	finish(world, bob, id, 2, 10.0)
	same(ann.savedMoney, 10000 + 2 * PRIZE, "Bob with no dial ranks last")
end, withPrize)

World.test("an exact tie, both jumping, or nobody finishing pays nothing", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob)
	finish(world, ann, id, 1, 11.5)
	finish(world, bob, id, 2, 11.5)
	atStrip(world, ann, 1)
	atStrip(world, bob, 2)
	id = run(world, ann, ann, bob)
	jumped(world, ann, id)
	jumped(world, bob, id)
	run(world, ann, ann, bob)
	world:advance(71)
	same(world:savedTotal(), 20000, "nothing paid")
	expect(world:printedMatching("no winner (tie)") == 1, "tie logged")
	expect(world:printedMatching("no winner (noFinish)") == 2, "both jumped, and nobody finished")
end, withPrize)

World.test("a finish the server sees far from the end line is not a finish", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob)
	world:drive(ann, 0, 0, 0)
	finish(world, ann, id, 1, 10.9, {far = true})
	finish(world, bob, id, 2, 11.9)
	same(bob.savedMoney, 10000 + PRIZE, "Bob's real finish wins")
	same(ann.savedMoney, 10000, "Ann nothing")
end, withPrize)

--== leaving, and the leader's end ============================================

World.test("the leader's end after the green does not decide: the other racer's finish still wins", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob)
	send(world, ann, "mileageDragRun", {phase = "ended", run = id})
	world:advance(5)
	finish(world, bob, id, 2, 12.4)
	world:advance(60)
	same(bob.savedMoney, 10000 + PRIZE, "Bob wins at the 70 s wait, Ann never finished")
end, withPrize)

World.test("the leader-racer leaves after the green: the other racer finishes and wins", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob)
	world:leave(ann)
	same(bob.savedMoney, 10000, "nothing decided by the leave")
	finish(world, bob, id, 2, 12.4)
	same(bob.savedMoney, 10000 + PRIZE, "Bob's finish decides it at once")
	same(lastCard(world, bob).why, "left", "Ann left")
end, withPrize)

World.test("the other racer leaves after the green: the leader finishes and wins", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob)
	world:leave(bob)
	finish(world, ann, id, 1, 12.0)
	same(ann.savedMoney, 10000 + PRIZE, "Ann wins")
end, withPrize)

World.test("a racer leaving before the green ends the run with nothing paid", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob, {green = false})
	world:leave(bob)
	send(world, ann, "mileageDragRun", {phase = "green", run = id})
	finish(world, ann, id, 1, 12.0)
	world:advance(80)
	same(ann.savedMoney, 10000, "nothing paid")
end, withPrize)

--== a staked drag challenge ==================================================

local function shownOffer(world, p)
	local closed = {}
	for _, c in ipairs(world:ui(p, "MileageOfferClosed")) do closed[c.id] = true end
	local last = nil
	for _, offer in ipairs(world:ui(p, "MileageOffer")) do
		if not closed[offer.id] then last = offer end
	end
	return last
end

-- a challenges b to a drag race for stake, and b accepts.
local function staked(world, a, b, stake)
	world:as(a, function() mileage_offers.dragRace(b.name, stake) end)
	world:pump()
	local offer = assert(shownOffer(world, b), "no drag challenge shown to " .. b.name)
	world:as(b, function() mileage_offers.answer(offer.id, true) end)
	world:pump()
end

local function races(world)
	local data = world:dataFile("races.json")
	local n, only = 0, nil
	for _, race in pairs(data and data.races or {}) do n, only = n + 1, race end
	return n, only
end

local function cards(world, p, phase)
	local found = {}
	for _, card in ipairs(world:received(p, "rxMileageDragRace")) do
		if card.phase == phase then table.insert(found, card) end
	end
	return found
end

local function lastLabel(p)
	return p.history[#p.history] and p.history[#p.history].label
end

World.test("accepting a drag challenge takes both stakes and holds them for the pair's next run together", function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	same(ann.savedMoney, 9000, "Ann's stake taken")
	same(bob.savedMoney, 9000, "Bob's stake taken")
	same(lastLabel(ann), "Drag race stake vs Bob", "Ann's history")
	local n, race = races(world)
	same(n, 1, "one race kept")
	same(race.kind, "drag", "a drag race")
	same(race.held.Ann, 1000, "Ann's stake held")
	same(race.held.Bob, 1000, "Bob's stake held")
	local card = cards(world, bob, "toStrip")[1]
	expect(card, "Bob told the stakes are held")
	same(card.other, "Ann", "against Ann")
	same(card.stake, 1000, "stake")
	same(card.minutesLeft, 15, "the race time limit")
	same(card.prize, PRIZE, "the drag prize")
	same(#world:received(ann, "rxMileageRace"), 0, "no street race panel")
end, withPrize)

World.test("Call off from either racer before the run gives both stakes back once", function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	local _, race = races(world)
	send(world, bob, "mileageDragCallOff", {race = race.id})
	send(world, ann, "mileageDragCallOff", {race = race.id})
	same(ann.savedMoney, 10000, "Ann's stake back")
	same(bob.savedMoney, 10000, "Bob's stake back")
	same(lastLabel(ann), "Drag race stake back vs Bob", "Ann's history")
	same(races(world), 0, "race record gone")
	same(cards(world, ann, "calledOff")[1].why, "Bob called it off", "Ann told why")
	same(world:savedTotal(), 20000, "total")
end)

World.test("the prompts app's Call off calls off the held race from the player's game", function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	local called
	world:as(bob, function() called = mileage_dragMoney.callOff() end)
	world:pump()
	same(called, true, "sent")
	same(bob.savedMoney, 10000, "Bob's stake back")
	same(ann.savedMoney, 10000, "Ann's stake back")
end)

World.test("a plain run's result against someone else does not stop Call off of the held race", function(world)
	local ann, bob = pair(world)
	local cat = world:join("Cat", 10000)
	staked(world, ann, bob, 1000)
	atStrip(world, cat, 2)
	world:serverOutput(function()
		dragMP(bob.id, World.encode({msg = "mileageDragLeave", to = "host", data = {stripId = STRIP}}))
	end)
	local id = run(world, ann, ann, cat)
	finish(world, ann, id, 1, 11.2)
	finish(world, cat, id, 2, 11.9)
	same(lastCard(world, ann).race, nil, "Ann's last card was the plain run's")
	local called
	world:as(ann, function() called = mileage_dragMoney.callOff() end)
	world:pump()
	same(called, true, "Call off still sent")
	same(ann.savedMoney, 10000 + PRIZE, "Ann's stake back, with her plain-run prize")
	same(bob.savedMoney, 10000, "Bob's stake back")
	local before = #world:ui(ann, "MileageDragRace")
	world:as(ann, function() mileage_dragMoney.sendState() end)
	same(#world:ui(ann, "MileageDragRace"), before, "nothing under way to show after a reload")
end, withPrize)

World.test("a call off from a player not in the race, or for no race, changes nothing", function(world)
	local ann, bob = pair(world)
	local cat = world:join("Cat", 0)
	staked(world, ann, bob, 1000)
	local _, race = races(world)
	send(world, cat, "mileageDragCallOff", {race = race.id})
	send(world, ann, "mileageDragCallOff", {race = "r999"})
	same(races(world), 1, "still held")
	same(world:savedTotal(), 18000, "stakes still held")
end)

World.test("either racer leaving before the run gives both stakes back", function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	world:leave(bob)
	same(ann.savedMoney, 10000, "Ann's stake back")
	world:rejoin(bob)
	same(bob.savedMoney, 10000, "Bob's stake back when he returns")
	same(races(world), 0, "race record gone")
end)

World.test("no run together before the time limit gives both stakes back; the time left is re-sent each minute",
		function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	world:advance(14 * 60 + 50)
	same(races(world), 1, "held at 14:50")
	expect(#cards(world, ann, "toStrip") >= 14, "the time left told each minute")
	same(cards(world, ann, "toStrip")[3].minutesLeft, 13, "counting down")
	world:advance(11)
	same(ann.savedMoney, 10000, "Ann's stake back")
	same(bob.savedMoney, 10000, "Bob's stake back")
	same(cards(world, bob, "calledOff")[1].why, "no run together in 15 min", "why")
end)

World.test("a server restart with a held drag race gives both stakes back once", function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	world:restart()
	world:advance(12)
	world:restart()
	world:advance(12)
	same(ann.savedMoney, 10000, "Ann's stake back")
	same(bob.savedMoney, 10000, "Bob's stake back")
	local backs = 0
	for _, entry in ipairs(ann.history) do if entry.label == "Drag race stake back vs Bob" then backs = backs + 1 end end
	same(backs, 1, "once")
end)

World.test("an older races.json without a kind settles as a street race", function(world)
	local ann, bob = pair(world)
	world.disk["Resources/Server/Mileage/data/races.json"] = World.encode({seq = 4, races = {r4 = {id = "r4", a = "Ann",
		b = "Bob", stake = 500, held = {Ann = 500, Bob = 500}, decision = "winner:Ann", pot = 1000, prize = 0, paid = {},
		created = 1}}})
	world:restart()
	world:advance(12)
	same(ann.savedMoney, 11000, "Ann's pot")
	same(lastLabel(ann), "Race win vs Bob", "a street race's label")
end)

World.test("while a drag race is held both racers are busy for other challenges, but plain runs still pay", function(world)
	local ann, bob = pair(world)
	local cat = world:join("Cat", 10000)
	staked(world, ann, bob, 1000)
	world:as(cat, function() mileage_offers.dragRace("Ann", 0) end)
	world:pump()
	local closed = world:received(cat, "rxMileageOfferClosed")
	same(closed[#closed].why, "busy", "Cat cannot challenge Ann")
	cat.route = {x = 0, y = 2400, z = 0}
	world:as(cat, function() mileage_offers.race("Bob", 0) end)
	world:pump()
	closed = world:received(cat, "rxMileageOfferClosed")
	same(closed[#closed].why, "busy", "nor race Bob")
	atStrip(world, cat, 2)
	world:serverOutput(function()
		dragMP(bob.id, World.encode({msg = "mileageDragLeave", to = "host", data = {stripId = STRIP}}))
	end)
	local id = run(world, ann, ann, cat)
	finish(world, ann, id, 1, 11.2)
	finish(world, cat, id, 2, 11.9)
	same(ann.savedMoney, 9000 + PRIZE, "Ann's plain win against Cat pays the prize")
	same(races(world), 1, "the drag race with Bob still held")
end, withPrize)

World.test("a street race report for a drag race changes nothing", function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	local _, race = races(world)
	send(world, ann, "mileageRaceReport", {race = race.id, gaveUp = true})
	send(world, bob, "mileageRaceReport", {race = race.id, finished = 30})
	same(races(world), 1, "still held")
	same(world:savedTotal(), 18000, "nothing moved")
end)

--== the staked run ===========================================================

-- Both back on their lines for another run.
local function again(world, a, b)
	atStrip(world, a, 1)
	atStrip(world, b, 2)
end

World.test("a staked run: the jumper's faster time loses, the clean finisher takes both stakes and the prize",
		function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	local id = run(world, ann, ann, bob)
	same(cards(world, ann, "racing")[1].run, id, "the race is this run's")
	same(races(world) and select(2, races(world)).run, id, "the run kept in races.json")
	jumped(world, bob, id)
	finish(world, bob, id, 2, 9.4)
	finish(world, ann, id, 1, 11.6)
	same(ann.savedMoney, 10000 + 1000 + PRIZE, "Ann: the stake plus the prize better off")
	same(bob.savedMoney, 10000 - 1000, "Bob: the stake worse off")
	same(world:savedTotal(), 20000 + PRIZE, "the pair: the prize better off")
	local labels = {}
	for _, entry in ipairs(ann.history) do labels[entry.label] = entry.amount end
	same(labels["Drag race win vs Bob"], 2000, "the pot")
	same(labels["Drag race prize vs Bob"], PRIZE, "the prize")
	local card = lastCard(world, bob)
	same(card.phase, "result", "result")
	same(card.winner, "Ann", "winner")
	same(card.pot, 2000, "pot")
	same(card.prize, PRIZE, "prize")
	same(card.stake, 1000, "stake")
	same(card.outcomes.Bob, "jumped", "Bob jumped")
	same(card.times.Ann, 11.6, "Ann's time")
	same(races(world), 0, "race record gone once paid")
end, withPrize)

World.test("the held card says when the pair's run is out, when it ended before the green, and again after a UI reload",
		function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	local id = run(world, ann, ann, bob, {green = false})
	local held = cards(world, bob, "toStrip")
	same(held[#held].note, "lined", "the run is out")
	send(world, ann, "mileageDragRun", {phase = "ended", run = id})
	held = cards(world, bob, "toStrip")
	same(held[#held].note, "ended", "ended before the green")
	same(held[#held].minutesLeft, 15, "time left")
	local before = #world:ui(bob, "MileageDragRace")
	world:as(bob, function() mileage_dragMoney.sendState() end)
	local shown = world:ui(bob, "MileageDragRace")
	same(#shown, before + 1, "shown again after a reload")
	same(shown[#shown].note, "ended", "the same card")
end)

World.test("a run ended before its green, a green that does not count, or a run with someone else leaves the stakes held",
		function(world)
	local ann, bob = pair(world)
	local cat = world:join("Cat", 10000)
	staked(world, ann, bob, 1000)
	local id = run(world, ann, ann, bob, {green = false})
	send(world, ann, "mileageDragRun", {phase = "ended", run = id})
	id = run(world, ann, ann, bob, {unstaged = bob})
	finish(world, ann, id, 1, 11.2)
	again(world, ann, bob)
	atStrip(world, cat, 2)
	id = run(world, ann, ann, cat)
	finish(world, ann, id, 1, 11.2)
	finish(world, cat, id, 2, 11.9)
	same(races(world), 1, "still held")
	same(#cards(world, ann, "racing"), 0, "never racing")
	again(world, ann, bob)
	id = run(world, ann, ann, bob)
	finish(world, ann, id, 1, 11.2)
	finish(world, bob, id, 2, 11.9)
	same(ann.savedMoney, 11000, "the pair's own run settles it")
	same(bob.savedMoney, 9000, "Bob lost his stake")
end)

World.test("from the green on, a racer who leaves loses the stake to a racer who finishes", function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	local id = run(world, ann, ann, bob)
	world:leave(bob)
	same(races(world), 1, "the leave alone decides nothing")
	finish(world, ann, id, 1, 12.0)
	same(ann.savedMoney, 11000, "Ann takes both stakes")
	world:rejoin(bob)
	same(bob.savedMoney, 9000, "Bob lost his")
	same(lastCard(world, ann).why, "left", "Ann told Bob left")
end)

World.test("from the green on, neither racer finishing gives both stakes back", function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	run(world, ann, ann, bob)
	world:advance(71)
	same(ann.savedMoney, 10000, "Ann's back")
	same(bob.savedMoney, 10000, "Bob's back")
	same(lastLabel(bob), "Drag race stake back vs Ann", "Bob's history")
	local card = lastCard(world, ann)
	same(card.phase, "result", "result card")
	same(card.winner, nil, "no winner")
end, withPrize)

World.test("a staked run without a prize pays only the pot, and a tie gives both stakes back", function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 500)
	local id = run(world, ann, ann, bob)
	finish(world, ann, id, 1, 11.5)
	finish(world, bob, id, 2, 11.5)
	same(world:savedTotal(), 20000, "tie: both back")
	again(world, ann, bob)
	staked(world, ann, bob, 500)
	id = run(world, ann, ann, bob)
	finish(world, ann, id, 1, 11.9)
	finish(world, bob, id, 2, 11.5)
	same(bob.savedMoney, 10500, "Bob's pot, no prize")
	same(ann.savedMoney, 9500, "Ann's stake lost")
end)

World.test("a call off once the run went green changes nothing", function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	local id = run(world, ann, ann, bob)
	local _, race = races(world)
	send(world, bob, "mileageDragCallOff", {race = race.id})
	finish(world, ann, id, 1, 11.2)
	finish(world, bob, id, 2, 11.9)
	same(ann.savedMoney, 11000, "the run still settles it")
end)

World.test("a restart after the decision pays only the payouts still missing", function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	local id = run(world, ann, ann, bob)
	world.filter = function(m)
		if m.event == "rxMileageGive" and m.data:find("Drag race prize", 1, true) then return "drop" end
	end
	finish(world, ann, id, 1, 11.2)
	finish(world, bob, id, 2, 11.9)
	same(ann.savedMoney, 11000, "the pot given, the prize not yet")
	world.filter = nil
	world:restart()
	world:advance(12)
	same(ann.savedMoney, 11000 + PRIZE, "the prize after the restart")
	same(prizeLines(ann), 1, "once")
	local pots = 0
	for _, entry in ipairs(ann.history) do if entry.label == "Drag race win vs Bob" then pots = pots + 1 end end
	same(pots, 1, "the pot once")
	same(races(world), 0, "record gone")
end, withPrize)

World.test("a prize under way when the server restarts is paid once", function(world)
	local ann, bob = pair(world)
	world.filter = function(m) if m.event == "rxMileageGive" then return "drop" end end
	local id = run(world, ann, ann, bob)
	finish(world, ann, id, 1, 11.2)
	finish(world, bob, id, 2, 11.9)
	same(ann.savedMoney, 10000, "not given yet")
	world.filter = nil
	world:restart()
	world:advance(12)
	same(ann.savedMoney, 10000 + PRIZE, "given once after the restart")
	same(prizeLines(ann), 1, "one history line")
end, withPrize)

--== more edges of a run and a staked race ====================================

World.test("a held pair racing in swapped lanes, Bob in lane 1, still settles their stakes", function(world)
	local ann = world:join("Ann", 10000)
	local bob = world:join("Bob", 10000)
	atStrip(world, ann, 2)
	atStrip(world, bob, 1)
	staked(world, ann, bob, 1000)
	local id = run(world, ann, bob, ann)
	finish(world, ann, id, 2, 11.2)
	finish(world, bob, id, 1, 11.9)
	same(ann.savedMoney, 10000 + 1000 + PRIZE, "Ann takes both stakes and the prize")
	same(bob.savedMoney, 9000, "Bob loses his stake")
	same(prizeLines(ann), 1, "the prize once")
	same(races(world), 0, "race settled")
end, withPrize)

World.test("a restart after the green, before the result, gives both stakes back once; a finish after it pays nothing",
		function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	local id = run(world, ann, ann, bob)
	world:restart()
	world:advance(12)
	same(ann.savedMoney, 10000, "Ann's stake back")
	same(bob.savedMoney, 10000, "Bob's stake back")
	finish(world, ann, id, 1, 11.2, {now = true})
	finish(world, bob, id, 2, 11.9, {now = true})
	world:advance(80)
	same(world:savedTotal(), 20000, "nothing more moved")
	local backs = 0
	for _, entry in ipairs(ann.history) do if entry.label == "Drag race stake back vs Bob" then backs = backs + 1 end end
	same(backs, 1, "Ann's stake back once")
	same(prizeLines(ann), 0, "no prize")
end, withPrize)

World.test("a staked race with a $0 stake pays the prize once, through the race record", function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 0)
	local id = run(world, ann, ann, bob)
	finish(world, ann, id, 1, 11.2)
	finish(world, bob, id, 2, 11.9)
	world:advance(80)
	same(ann.savedMoney, 10000 + PRIZE, "the prize, not twice")
	same(prizeLines(ann), 1, "one prize line")
	same(bob.savedMoney, 10000, "Bob unchanged")
	local card = lastCard(world, ann)
	same(card.phase, "result", "result card")
	same(type(card.race), "string", "the staked race's card")
end, withPrize)

World.test("from the green on, a leaver or a jumper against a racer who never finishes gives both stakes back",
		function(world)
	local ann, bob = pair(world)
	staked(world, ann, bob, 1000)
	run(world, ann, ann, bob)
	world:leave(bob)
	world:advance(71)
	world:rejoin(bob)
	world:advance(12)
	same(ann.savedMoney, 10000, "Ann did not finish: her stake back, not Bob's")
	same(bob.savedMoney, 10000, "Bob left, but Ann never finished: his stake back")
	again(world, ann, bob)
	staked(world, ann, bob, 1000)
	local id = run(world, ann, ann, bob)
	jumped(world, bob, id)
	world:advance(71)
	same(ann.savedMoney, 10000, "Ann did not finish")
	same(bob.savedMoney, 10000, "Bob jumped, but Ann never finished")
	same(prizeLines(ann) + prizeLines(bob), 0, "no prize")
end, withPrize)

World.test("bracket: two racers exactly level on the same side of their dials have no winner", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob, {dragType = "bracketRace"})
	finish(world, ann, id, 1, 12.5, {dial = 12.0})
	finish(world, bob, id, 2, 11.75, {dial = 11.25})
	world:advance(80)
	same(world:savedTotal(), 20000, "nothing paid")
	expect(world:printedMatching("no winner (tie)") == 1, "a tie")
end, withPrize)

World.test("the prize paid is the setting when the run is decided, not when it started", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob)
	finish(world, ann, id, 1, 11.2)
	world:setConfig("server", "dragRacePrize", 4000)
	finish(world, bob, id, 2, 11.9)
	same(ann.savedMoney, 10000 + 4000, "the prize at the decision")
end, withPrize)

World.test("malformed drag messages, a green from the other racer and a negative dial change nothing", function(world)
	local ann, bob = pair(world)
	local cara = world:join("Cara", 0)
	local function raw(p, event, data)
		world:queue({way = "toServer", from = p.id, name = event, data = data})
		world:pump()
	end
	for _, event in ipairs({"mileageDragRun", "mileageDragStaged", "mileageDragResult"}) do
		raw(ann, event, "not json")
		raw(ann, event, "[]")
		raw(ann, event, "")
	end
	local bad = {
		{phase = "start", strip = STRIP, run = 5},
		{phase = "start", strip = {}, run = STRIP .. "-x"},
		{phase = "start", strip = STRIP, run = STRIP .. "-" .. string.rep("9", 100),
			racers = {{id = ann.id, lane = 1}, {id = bob.id, lane = 2}}, dragType = "headsUpRace"},
		{phase = "start", strip = STRIP, run = STRIP .. "-y", racers = "two", dragType = "headsUpRace"},
		{phase = "start", strip = STRIP, run = STRIP .. "-z", racers = {{id = "abc", lane = 1}, {id = bob.id, lane = 2}},
			dragType = "headsUpRace"},
		{phase = "start", strip = STRIP, run = STRIP .. "-w", racers = {{id = ann.id, lane = 1.5}, {id = bob.id, lane = 2}},
			dragType = "headsUpRace"},
		{phase = "green", run = {}},
		{phase = "fly", run = STRIP .. "-y"},
	}
	for _, message in ipairs(bad) do send(world, ann, "mileageDragRun", message) end
	send(world, ann, "mileageDragResult", {run = 7, outcome = "finished", winTime = 11})
	-- A started run the other racer greens: not the leader's green, so it never counts.
	local id = run(world, ann, ann, bob, {green = false})
	send(world, bob, "mileageDragRun", {phase = "green", run = id})
	send(world, cara, "mileageDragStaged", {run = id, dragType = "headsUpRace"})
	world:advance(12)
	finish(world, ann, id, 1, 11.2, {now = true})
	world:advance(121)
	same(world:savedTotal(), 20000, "nothing paid")
	-- A valid run after all that: Bob's faster report with a negative dial is refused.
	again(world, ann, bob)
	id = run(world, ann, ann, bob)
	world:advance(12)
	send(world, bob, "mileageDragResult", {run = id, outcome = "finished", winTime = 11.0, dial = -1})
	send(world, bob, "mileageDragResult", {run = id, outcome = "won", winTime = 11.0})
	world:drive(ann, FINISH[1].x, FINISH[1].y, FINISH[1].z)
	send(world, ann, "mileageDragResult", {run = id, outcome = "finished", winTime = 11.2, dial = 0})
	world:drive(bob, FINISH[2].x, FINISH[2].y, FINISH[2].z)
	send(world, bob, "mileageDragResult", {run = id, outcome = "finished", winTime = 11.9, dial = 0})
	same(ann.savedMoney, 10000 + PRIZE, "Ann's 11.2 beats Bob's one valid report")
	same(bob.savedMoney, 10000, "Bob unchanged")
	same(cara.savedMoney, 0, "Cara unchanged")
end, withPrize)

World.test("stakes that do not arrive in time call the drag race off, with both stakes back", function(world)
	local ann, bob = pair(world)
	world.filter = function(m)
		if m.event == "rxMileageTake" and m.target == bob.id then return "drop" end
	end
	staked(world, ann, bob, 1000)
	world:advance(16)
	world.filter = nil
	world:advance(30)
	local off = cards(world, ann, "calledOff")
	expect(off[1], "called off")
	same(off[1].why, "the stakes did not arrive in time", "why")
	same(ann.savedMoney, 10000, "Ann's stake back")
	same(bob.savedMoney, 10000, "Bob's stake not kept")
	same(races(world), 0, "race record gone")
end, withPrize)

-- A Call off without a race id, or with one that is not text, changes nothing and raises
-- no error in the server's handler; a held race stays held.
for _, data in ipairs({"not json", "[]", "{}", World.encode({race = 5}), World.encode({race = true})}) do
	World.test("a Call off with a malformed body changes nothing: " .. data, function(world)
		local ann, bob = pair(world)
		staked(world, ann, bob, 1000)
		world:queue({way = "toServer", from = ann.id, name = "mileageDragCallOff", data = data})
		local lines = world:serverOutput(function() world:pump() end)
		same(countLines(lines, "error"), 0, "no error")
		same(races(world), 1, "still held")
		same(world:savedTotal(), 18000, "nothing moved")
	end)
end

-- A drag Call off names a race the server holds, but it is a street race still taking its
-- stakes: only a drag race can be called off this way, so the street race goes on.
World.test("a drag Call off naming a street race still taking its stakes changes nothing", function(world)
	local ann, bob = pair(world)
	world.filter = function(m)
		if m.event == "rxMileageTake" and m.target == bob.id then return "drop" end
	end
	ann.route = {x = 0, y = 2400, z = 0}
	world:as(ann, function() mileage_offers.race("Bob", 1000) end)
	world:pump()
	local offer = assert(shownOffer(world, bob), "no street race challenge shown to Bob")
	world:as(bob, function() mileage_offers.answer(offer.id, true) end)
	world:pump()
	local n, race = races(world)
	same(n, 1, "the street race is held")
	same(race.kind, nil, "a street race, not a drag race")
	send(world, ann, "mileageDragCallOff", {race = race.id})
	send(world, bob, "mileageDragCallOff", {race = race.id})
	same(races(world), 1, "the street race is still held")
	local off = 0
	for _, m in ipairs(world:received(ann, "rxMileageRace")) do
		if m.phase == "calledOff" then off = off + 1 end
	end
	same(off, 0, "not called off")
	same(#world:received(ann, "rxMileageDragRace"), 0, "no drag card for a street race")
end)
