-- Racing your own traffic cars on the road: the card beside a traffic car, the press, the
-- random reachable finish, the rolling countdown in which nobody is held or moved, the
-- traffic car taken off traffic duty and sent a race route at zero, the race reward and its
-- wait, every ending handing the car back, and the players near you who join.

local World = dofile("tests/money_world.lua")

local FINISH = {x = 0, y = 2500, z = 0}

local function roads(world)
	world.roadNodes = {
		near = {pos = {x = 0, y = 600, z = 0}},
		finish = {pos = {x = FINISH.x, y = FINISH.y, z = FINISH.z}},
		far = {pos = {x = 0, y = 9000, z = 0}},
	}
end

-- The MileageAiRace messages p's game sent to its prompts app, the last one of phase.
local function card(world, p, phase)
	local found = nil
	for _, m in ipairs(world:ui(p, "MileageAiRace")) do
		if not phase or m.phase == phase then found = m end
	end
	return found
end

local function cards(world, p, phase)
	local n = 0
	for _, m in ipairs(world:ui(p, "MileageAiRace")) do
		if m.phase == phase then n = n + 1 end
	end
	return n
end

local function lastRace(world, p, phase)
	local found = nil
	for _, m in ipairs(world:ui(p, "MileageRace")) do
		if not phase or m.phase == phase then found = m end
	end
	return found
end

-- The rxMileageAiRace messages the server sent p, of phase.
local function heard(world, p, phase)
	local found = {}
	for _, m in ipairs(world:received(p, "rxMileageAiRace")) do
		if m.phase == phase then table.insert(found, m) end
	end
	return found
end

local function sentToServer(world, p, name)
	local n = 0
	for _, m in ipairs(world.serverLog) do
		if m.from == p.id and m.name == name then n = n + 1 end
	end
	return n
end

-- Ann with one of her traffic cars 4 m to her right, both heading north, and the road map.
local function annAndCar(world, prize)
	roads(world)
	if prize then world:setConfig("server", "aiRacePrize", tostring(prize)) end
	local ann = world:join("Ann", 1000, 0)
	local t = world:giveTraffic(ann, {x = 4, y = 3})
	world:advance(1)
	return ann, t
end

local function press(world, p)
	local sent
	world:as(p, function() sent = mileage_aiRace.press() end)
	world:pump()
	return sent
end

local function wins(world, name)
	local board = world:dataFile("leaderboard.json")
	return board and board.wins and board.wins[name] or 0
end

-- Ann presses, the countdown runs out, the traffic car races at speed m/s, and Ann reaches
-- the finish after annAfter seconds of racing. Returns the race id.
local function raceAnn(world, ann, t, speed, annAfter)
	expect(press(world, ann), "the press sent a request")
	local id = heard(world, ann, "countdown")[1].race
	t.car.speed = speed
	world:advance(5)
	world:advance(annAfter)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(8)
	return id
end

--== the shared road-point picker (T1) =========================================

World.test("pickRoadPoint gives a road node in range that accept takes, and nil after 10 refusals", function(world)
	roads(world)
	local ann = world:join("Ann", 1000, 0)
	world:as(ann, function()
		local picked = mileage_raceEvents.pickRoadPoint({x = 0, y = 0, z = 0}, 1500, 4000)
		same(picked.node, "finish", "the one node in range")
		same(picked.pos.y, 2500, "its position")
		local asked = 0
		world.roadNodes = {}
		for i = 1, 30 do world.roadNodes["n" .. i] = {pos = {x = 0, y = 2000 + i, z = 0}} end
		local none = mileage_raceEvents.pickRoadPoint({x = 0, y = 0, z = 0}, 1500, 4000, function()
			asked = asked + 1
			return false
		end)
		same(none, nil, "nothing accepted")
		same(asked, 10, "ten candidates asked")
		same(mileage_raceEvents.pickRoadPoint({x = 0, y = 0, z = 0}, 5000, 6000), nil, "nothing in range")
	end)
end)

World.test("the finish is a reachable road point 1.5 to 4 km away and changes between races", function(world)
	roads(world)
	local ann = world:join("Ann", 1000, 0)
	world.roadNodes = {}
	for i = 1, 20 do world.roadNodes["ok" .. i] = {pos = {x = i * 10, y = 1600 + i * 100, z = 0}} end
	for i = 1, 20 do world.roadNodes["cut" .. i] = {pos = {x = -i * 10, y = 1600 + i * 100, z = 0}} end
	world.unreachable = {}
	for i = 1, 20 do world.unreachable["cut" .. i] = true end
	world:giveTraffic(ann, {x = 4, y = 3})
	world:advance(1)
	expect(press(world, ann), "the press sent a request")
	local request = nil
	for _, m in ipairs(world.serverLog) do
		if m.name == "mileageAiRace" then request = World.decode(m.data).request end
	end
	local f = request.finish
	local metres = math.sqrt(f.x * f.x + f.y * f.y)
	expect(metres >= 1500 and metres <= 4000, "finish " .. metres .. " m away")
	expect(f.x > 0, "a reachable node, not one across the water")
	same(heard(world, ann, "countdown")[1].finish.y, f.y, "the server's finish is the picked one")
	same(lastRace(world, ann, "countdown").rolling, true, "the rolling countdown shows it")
	local seen = {}
	world:as(ann, function()
		for _ = 1, 20 do
			local picked = mileage_raceEvents.pickRoadPoint({x = 0, y = 0, z = 0}, 1500, 4000, function(c)
				return extensions.mileage_compat.getPointNodePath({x = 4, y = 3, z = 0}, c.node) ~= nil
			end)
			expect(picked.node:sub(1, 2) == "ok", "only reachable nodes")
			seen[picked.node] = true
		end
	end)
	local distinct = 0
	for _ in pairs(seen) do distinct = distinct + 1 end
	expect(distinct > 1, "the finish changes from race to race")
end)

World.test("with no reachable finish the card says so and nothing is sent", function(world)
	local ann = annAndCar(world)
	world.unreachable = {finish = true}
	same(press(world, ann), false, "nothing sent")
	same(sentToServer(world, ann, "mileageAiRace"), 0, "no request")
	same(card(world, ann, "available").note, "No reachable finish from here, try another road.", "the card says why")
end)

--== the rolling start (T2) ====================================================

World.test("a rolling race counts down without holding the car and carries the reward", function(world)
	local ann = world:join("Ann", 1000, 0)
	world:as(ann, function()
		expect(mileage_streetRace.startRollingRace({id = "x1", finish = FINISH, radius = 20, seconds = 5,
			other = "the Ibishu Pessima", reward = 2000}), "started")
		same(mileage_streetRace.setRaceInfo("other", {reward = 1}), false, "another race id changes nothing")
	end)
	local first = lastRace(world, ann, "countdown")
	same(first.count, 5, "counts from 5")
	same(first.rolling, true, "rolling")
	same(first.reward, 2000, "the reward")
	same(first.other, "the Ibishu Pessima", "who you race")
	same(ann.route.y, FINISH.y, "the finish is on the map")
	expect(world:drive(ann, 0, 30), "the car keeps driving in the countdown")
	world:as(ann, function() mileage_streetRace.setRaceInfo("x1", {reward = 3000, other = "the Ibishu Pessima and Sam"}) end)
	same(lastRace(world, ann, "countdown").reward, 3000, "the new reward")
	world:advance(5)
	same(lastRace(world, ann, "go").rolling, true, "go")
	same(ann.car.freezes, 0, "never held")
	same(#ann.teleports, 0, "never moved")
	world:as(ann, function() same(mileage_streetRace.current().phase, "racing", "racing") end)
end)

--== the owner's settings and status (T3) =======================================

World.test("a status tells each game whether racing traffic is on, the reward and its wait", function(world)
	local ann = world:join("Ann", 1000)
	local status = heard(world, ann, "status")
	same(#status, 1, "one status at the career start")
	same(status[1].allowed, true, "on by default")
	same(status[1].prize, 0, "no reward until set")
	same(status[1].prizeAgainIn, 0, "no wait")
	world:setConfig("server", "aiRacePrize", "2000")
	same(heard(world, ann, "status")[2].prize, 2000, "the new reward")
	world:setConfig("server", "allowAiRaces", "false")
	same(heard(world, ann, "status")[3].allowed, false, "switched off")
	same(world:received(ann, "rxMileageFeatures")[3].aiRacePrize, 2000, "in the race settings too")
end)

--== the server's checks (T4) =================================================

World.test("the server refuses another player's car, a car that is not traffic, a finish out of range and racing traffic switched off", function(world)
	roads(world)
	local ann = world:join("Ann", 1000, 0)
	local bob = world:join("Bob", 1000, 1)
	local bobs = world:giveTraffic(bob, {x = 54, y = 3})
	local mine = world:giveTraffic(ann, {x = 4, y = 3})
	local function request(fields)
		local r = {car = mine.sid, start = {x = 0, y = 0, z = 0}, finish = FINISH, model = "Ibishu Pessima"}
		for k, v in pairs(fields) do r[k] = v end
		world:serverOutput(function() mileageAiRace(ann.id, World.encode({request = r})) end)
		world:pump()
		local refused = heard(world, ann, "refused")
		return refused[#refused] and refused[#refused].why
	end
	same(request({car = bobs.sid}), "Only your own traffic can race you.", "another player's car")
	same(request({car = "0-0"}), "That car is not traffic.", "her own car")
	same(request({finish = {x = 0, y = 900, z = 0}}), "The finish must be 1.5 to 4 km away. Try again.", "too close")
	same(request({finish = {x = 0, y = 5000, z = 0}}), "The finish must be 1.5 to 4 km away. Try again.", "too far")
	same(request({finish = "north"}), "No finish was set for the race.", "no finish")
	world:setConfig("server", "allowAiRaces", "false")
	same(request({}), "Racing traffic is off on this server.", "switched off")
	same(#heard(world, ann, "countdown"), 0, "no race started")
	for _, m in ipairs(heard(world, ann, "refused")) do
		expect(not m.why:find("AI", 1, true), "no reason says AI: " .. m.why)
	end
	world:setConfig("server", "allowAiRaces", "true")
	world:drive(ann, 10, 20)
	same(request({}), "Racing traffic is off on this server.", "no new refusal")
	local countdown = heard(world, ann, "countdown")[1]
	same(countdown.seconds, 5, "a 5 second countdown")
	same(countdown.car, "Ibishu Pessima", "the model")
	same(countdown.host, "Ann", "her race")
	same(world:printedMatching("Ann races their Ibishu Pessima to a finish 2480 m away"), 1,
		"the start is where the server sees her car")
end)

--== the card and the press (T5) =================================================

World.test("the card offers a traffic car beside you, not one far away or heading the other way", function(world)
	local ann, t = annAndCar(world, 2000)
	local shown = card(world, ann, "available")
	same(shown.own, true, "her own traffic")
	same(shown.car, "Ibishu Pessima", "named by its model")
	same(shown.allowed, true, "racing allowed")
	same(shown.prize, 2000, "the reward")
	same(shown.key, nil, "no key bound")
	t.car.pos = {x = 40, y = 3, z = 0}
	world:advance(1)
	same(card(world, ann).phase, "none", "40 m away")
	t.car.pos = {x = 4, y = 3, z = 0}
	t.car.dir = {x = 0, y = -1, z = 0}
	world:advance(1)
	same(card(world, ann).phase, "none", "heading the other way")
	t.car.dir = {x = 0, y = 1, z = 0}
	world.boundKeys = {mileageAiRace = "j"}
	world:advance(1)
	same(card(world, ann).key, "j", "the bound key")
	local before = cards(world, ann, "available")
	world:advance(3)
	same(cards(world, ann, "available"), before, "sent on change only")
end)

World.test("next to another player's traffic the card is off, names the owner and press sends nothing", function(world)
	roads(world)
	local ann = world:join("Ann", 1000, 0)
	local bob = world:join("Bob", 1000, 1)
	world:giveTraffic(bob, {x = 4, y = 3, jbeam = "pickup"})
	world:advance(1)
	local shown = card(world, ann, "available")
	same(shown.own, false, "not hers")
	same(shown.owner, "Bob", "whose it is")
	same(shown.car, "Gavril D-Series", "its model")
	same(press(world, ann), false, "press does nothing")
	same(sentToServer(world, ann, "mileageAiRace"), 0, "no request")
end)

--== the countdown and zero (T6) ==================================================

World.test("a press beside your own traffic car takes it off duty and starts a 5 second rolling countdown", function(world)
	local ann, t = annAndCar(world, 2000)
	expect(press(world, ann), "the press sent a request")
	same(t.entry.roleName, "empty", "the game's empty role")
	same(t.entry.enableRespawn, false, "not respawned")
	same(t.entry.enableAutoPooling, false, "not pooled")
	same(#t.car.commands, 0, "no race route yet")
	same(card(world, ann).phase, "racing", "the card gives way to the race panel")
	local countdown = lastRace(world, ann, "countdown")
	same(countdown.count, 5, "5 seconds")
	same(countdown.rolling, true, "rolling")
	same(countdown.other, "the Ibishu Pessima", "against the car")
	same(countdown.reward, 2000, "the reward")
	world:advance(4)
	same(#t.car.commands, 0, "still no race route at 1")
	expect(world:drive(ann, 0, 40), "driving through the countdown")
	world:advance(1)
	same(ann.car.freezes, 0, "never held")
	same(#ann.teleports, 0, "never moved")
end)

World.test("at zero the traffic car gets a race route to the finish at full push", function(world)
	local ann, t = annAndCar(world)
	press(world, ann)
	world:advance(5)
	same(#t.car.commands, 2, "two commands at zero")
	same(t.car.commands[1], 'ai.driveUsingPath({wpTargetList = {"finish", "finish+1", "finish+2"}, ' ..
		"aggression = 1, avoidCars = 'on'})", "the route to the finish and on past it")
	same(t.car.commands[2], "ai.setRacing(true)", "racing")
	same(t.entry.roleName, "empty", "still off duty")
	world:advance(3)
	same(#t.car.commands, 2, "sent once")
end)

--== the result and the reward (T7) ===============================================

World.test("beating the traffic car alone pays 100% of the race reward once", function(world)
	local ann, t = annAndCar(world, 2000)
	raceAnn(world, ann, t, 40, 40)
	same(ann.money, 3000, "the race reward, once")
	same(ann.history[#ann.history].label, "Race reward", "money history")
	same(wins(world, "Ann"), 1, "a leaderboard win")
	local result = card(world, ann, "result")
	same(result.winner, "Ann", "she won")
	same(result.aiWon, false, "the car did not")
	same(result.prize, 2000, "paid")
	same(result.places[1].name, "Ann", "first")
	same(result.places[1].seconds, 41, "her time, reported the second after she arrived")
	same(result.prizeAgainIn, 600, "the wait starts")
	same(world:printedMatching("$2000 race reward"), 1, "the console line")
	world:advance(60)
	same(ann.money, 3000, "paid once")
end)

World.test("when the traffic car is faster nobody is paid and nobody gets a win", function(world)
	local ann, t = annAndCar(world, 2000)
	raceAnn(world, ann, t, 70, 37)
	same(ann.money, 1000, "not paid")
	same(wins(world, "Ann"), 0, "no win")
	local result = card(world, ann, "result")
	same(result.winner, nil, "no player won")
	same(result.aiWon, true, "the car won")
	same(result.places[1].car, true, "the car first")
	same(result.places[1].name, "Ibishu Pessima", "named by its model")
	same(result.places[2].name, "Ann", "Ann second")
	same(result.prize, 0, "nothing paid")
	same(world:printedMatching("the traffic car wins, no reward"), 1, "the console line")
end)

World.test("the race reward is off until set, and waits per winner", function(world)
	local ann, t = annAndCar(world)
	raceAnn(world, ann, t, 30, 40)
	same(card(world, ann, "result").winner, "Ann", "she won")
	same(ann.money, 1000, "no reward with none set")
	same(wins(world, "Ann"), 1, "the win counts")
	world:setConfig("server", "aiRacePrize", "2000")
	world:drive(ann, 0, 0)
	t.car.pos, t.car.racing = {x = 4, y = 3, z = 0}, false
	world:advance(2)
	raceAnn(world, ann, t, 30, 40)
	same(ann.money, 3000, "paid once set")
	world:drive(ann, 0, 0)
	t.car.pos, t.car.racing = {x = 4, y = 3, z = 0}, false
	world:advance(2)
	raceAnn(world, ann, t, 30, 40)
	same(ann.money, 3000, "not again inside the wait")
	same(wins(world, "Ann"), 3, "every win counts")
	local again = card(world, ann, "result").prizeAgainIn
	expect(again > 0 and again < 600, "the wait left: " .. tostring(again))
	same(card(world, ann, "available").prizeAgainIn > 0, true, "the card shows the wait")
end)

World.test("a traffic car time that could not have been driven is ignored", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	local id = heard(world, ann, "countdown")[1].race
	t.car.speed = 30
	world:advance(5)
	world:serverOutput(function() mileageRaceReport(ann.id, World.encode({race = id, aiFinished = 3})) end)
	world:advance(30)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(8)
	same(card(world, ann, "result").winner, "Ann", "the impossible time did not win")
	same(ann.money, 3000, "paid")
end)
