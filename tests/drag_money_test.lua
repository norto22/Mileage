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
			if p ~= opts.unstaged then send(world, p, "mileageDragStaged", {run = id}) end
		end
	end
	if opts.green ~= false then send(world, leader, "mileageDragRun", {phase = "green", run = id}) end
	return id
end

-- p's own game reports its run: finished in winTime (at its end line unless opts.far), or jumped.
local function finish(world, p, id, lane, winTime, opts)
	opts = opts or {}
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

World.test("the result card reaches the prompts app, and again after a UI reload", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob)
	finish(world, ann, id, 1, 11.2)
	finish(world, bob, id, 2, 11.9)
	local shown = world:ui(bob, "MileageDragRace")
	same(#shown, 1, "one card on Bob's screen")
	same(shown[1].winner, "Ann", "who won")
	world:as(bob, function() mileage_dragMoney.sendState() end)
	shown = world:ui(bob, "MileageDragRace")
	same(#shown, 2, "shown again")
	same(shown[2].phase, "result", "the same card")
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
	send(world, ann, "mileageDragRun", {phase = "green", run = id})
	finish(world, cara, id, 2, 5.0)
	finish(world, bob, id, 2, 2.5)
	finish(world, bob, id, 2, 61)
	send(world, bob, "mileageDragResult", {run = id, outcome = "finished", winTime = "9"})
	finish(world, bob, id, 2, 11.9)
	finish(world, bob, id, 2, 9.0)
	finish(world, ann, id, 1, 11.2)
	same(ann.savedMoney, 10000 + PRIZE, "Ann's 11.2 beat Bob's one counted report, 11.9")
	same(cara.savedMoney, 0, "Cara nothing")
end, withPrize)

World.test("a jump start reported before the green still counts against the jumper", function(world)
	local ann, bob = pair(world)
	local id = run(world, ann, ann, bob, {green = false})
	jumped(world, bob, id)
	send(world, ann, "mileageDragRun", {phase = "green", run = id})
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
	world:advance(20)
	finish(world, bob, id, 2, 12.4)
	world:advance(51)
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
