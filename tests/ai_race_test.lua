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

-- Advances until the server sent p a result (the race is decided about 5 s after the first
-- counted time, or at the time limit), at most limit seconds.
local function untilResult(world, p, limit)
	local before = #heard(world, p, "result")
	for _ = 1, limit or 200 do
		world:advance(1)
		if #heard(world, p, "result") > before then return end
	end
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
	untilResult(world, ann)
	world:advance(2)
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

-- The game gives each road node's position as its own vector (an FFI struct under LuaJIT),
-- not a plain table. Lua 5.4 cannot make one, so there only the broken nodes are checked.
local hasFfi, ffi = pcall(require, "ffi")
local GameVec = hasFfi and ffi.typeof("struct { double x, y, z; }") or nil

World.test("pickRoadPoint picks from road positions given as game vectors and skips broken ones", function(world)
	roads(world)
	local ann = world:join("Ann", 1000, 0)
	world:as(ann, function()
		local from = {x = 0, y = 0, z = 0}
		local broken = {
			none = {},
			text = {pos = {x = 0, y = "2500", z = 0}},
			short = {pos = {x = 0, y = 2500}},
			flat = {pos = 2500},
		}
		world.roadNodes = broken
		same(mileage_raceEvents.pickRoadPoint(from, 1500, 4000), nil, "a node with a missing or broken position is skipped")
		if not GameVec then return end
		local nodes = {}
		for name, node in pairs(broken) do nodes[name] = node end
		for i = 1, 20 do nodes["n" .. i] = {pos = GameVec(i * 10, 2000 + i * 50, 3)} end
		world.roadNodes = nodes
		local picked = mileage_raceEvents.pickRoadPoint(from, 1500, 4000)
		expect(picked, "a road node picked from game vectors")
		expect(picked.node:match("^n%d+$"), "a game vector node, not a broken one")
		same(type(picked.pos), "table", "the finish is sent on as a plain table")
		same(picked.pos.x, nodes[picked.node].pos.x, "its x")
		same(picked.pos.y, nodes[picked.node].pos.y, "its y")
		same(picked.pos.z, 3, "its z")
	end)
end)

-- The race tests only catch this fault if the test world's road map hands out game vectors.
World.test("the test world's road map gives positions as game vectors under LuaJIT and leaves the test's nodes as tables", function(world)
	roads(world)
	local ann = world:join("Ann", 1000, 0)
	world:as(ann, function()
		local given = map.getMap().nodes
		same(type(given.finish.pos), GameVec and "cdata" or "table", "the road map's position type")
		same(given.finish.pos.y, FINISH.y, "the same position")
		same(type(world.roadNodes.finish.pos), "table", "the test's own node is still a table")
	end)
end)

-- A game value whose x, y or z cannot be read raises when indexed; that node is skipped.
World.test("pickRoadPoint skips a game vector whose fields cannot be read, without raising", function(world)
	if not GameVec then return end
	roads(world)
	local ann = world:join("Ann", 1000, 0)
	local Flat = ffi.typeof("struct { double x, y; }")
	world.roadNodes = {
		flat = {pos = Flat(0, 2500)},
		good = {pos = GameVec(0, 3000, 7)},
	}
	world:as(ann, function()
		for _ = 1, 10 do
			local ok, picked = pcall(mileage_raceEvents.pickRoadPoint, {x = 0, y = 0, z = 0}, 1500, 4000)
			expect(ok, "no error: " .. tostring(picked))
			same(picked and picked.node, "good", "only the readable node")
		end
	end)
end)

-- Some game builds hand positions as userdata with x, y and z.
World.test("pickRoadPoint reads a userdata road position with number x, y and z", function(world)
	if type(newproxy) ~= "function" then return end
	roads(world)
	local ann = world:join("Ann", 1000, 0)
	local pos = newproxy(true)
	getmetatable(pos).__index = {x = 0, y = 2500, z = 4}
	world.roadNodes = {u = {pos = pos}}
	world:as(ann, function()
		local picked = mileage_raceEvents.pickRoadPoint({x = 0, y = 0, z = 0}, 1500, 4000)
		same(picked and picked.node, "u", "the userdata node")
		same(type(picked.pos), "table", "sent on as a plain table")
		same(picked.pos.z, 4, "its z")
	end)
end)

-- 1.5 and 4 km are in range, flat distance only, with the game's vectors.
World.test("pickRoadPoint keeps game vectors at exactly 1.5 and 4 km flat and drops ones just outside", function(world)
	if not GameVec then return end
	roads(world)
	local ann = world:join("Ann", 1000, 0)
	world:as(ann, function()
		local function only(y, z)
			world.roadNodes = {one = {pos = GameVec(0, y, z)}}
			local picked = mileage_raceEvents.pickRoadPoint({x = 0, y = 0, z = 0}, 1500, 4000)
			return picked and picked.node
		end
		same(only(1500, 0), "one", "exactly 1500 m")
		same(only(4000, 0), "one", "exactly 4000 m")
		same(only(1499.5, 0), nil, "1499.5 m")
		same(only(4000.5, 0), nil, "4000.5 m")
		same(only(4000, 900), "one", "height does not count")
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
	untilResult(world, ann)
	same(card(world, ann, "result").winner, "Ann", "the impossible time did not win")
	same(ann.money, 3000, "paid")
end)

--== every ending hands the car back (T8, T9) =====================================

local function givenBack(t)
	return t.entry.roleName == "standard" and t.entry.enableRespawn == true and t.entry.enableAutoPooling == true
end

World.test("a result hands the traffic car back to traffic", function(world)
	local ann, t = annAndCar(world, 2000)
	t.entry.enableAutoPooling = "kept"
	raceAnn(world, ann, t, 40, 40)
	same(card(world, ann, "result").winner, "Ann", "a result")
	same(t.entry.roleName, "standard", "its own role")
	same(t.entry.enableRespawn, true, "respawning again")
	same(t.entry.enableAutoPooling, "kept", "its own pooling")
	same(t.car.commands[#t.car.commands], "ai.setRacing(false)", "no longer racing")
	same(#t.entry.roles, 2, "taken once and given back once")
	world:as(ann, function() same(mileage_streetRace.current(), nil, "the race panel is gone") end)
	world:advance(3)
	same(card(world, ann, "available").own, true, "the card is offered again")
end)

World.test("the host giving up or leaving ends the race with no winner and hands the car back", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	world:advance(2)
	world:as(ann, function() mileage_streetRace.giveUp() end)
	world:pump()
	local result = card(world, ann, "result")
	same(result.winner, nil, "no winner")
	same(result.why, "hostGaveUp", "she gave up")
	expect(givenBack(t), "given back after giving up in the countdown")
	same(#t.car.commands, 0, "never sent a route")
	world:advance(1)
	press(world, ann)
	t.car.speed = 30
	world:advance(10)
	world:as(ann, function() mileage_streetRace.giveUp() end)
	world:pump()
	same(card(world, ann, "result").why, "hostGaveUp", "gave up while racing")
	expect(givenBack(t), "given back after giving up in the race")
	same(ann.money, 1000, "no reward")
	same(world:printedMatching("no winner (hostGaveUp)"), 2, "the console says so")
	-- Leaving the server: her game gives the car back, and the server ends the race.
	t.car.pos, t.car.racing = {x = 4, y = 3, z = 0}, false
	world:drive(ann, 0, 0)
	world:advance(2)
	press(world, ann)
	world:advance(7)
	same(t.entry.roleName, "empty", "racing again")
	world:hook(ann, "onBeamMPServerLeave")
	expect(givenBack(t), "given back on leaving")
	world:leave(ann)
	same(world:printedMatching("no winner (hostLeft)"), 1, "the race ended on the server")
end)

World.test("a stuck traffic car ends the race with no winner", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	t.car.speed = 0.5
	world:advance(5)
	world:advance(14)
	same(card(world, ann, "result"), nil, "still racing after 14 s")
	world:advance(2)
	local result = card(world, ann, "result")
	same(result.why, "aiOut", "the car dropped out")
	same(result.winner, nil, "no winner")
	expect(givenBack(t), "given back")
	same(ann.money, 1000, "nobody paid")
	-- A player ahead of it when it drops out still wins.
	t.car.pos, t.car.racing = {x = 4, y = 3, z = 0}, false
	world:advance(2)
	press(world, ann)
	t.car.speed = 30
	world:advance(30)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(1)
	t.gone = true
	world:advance(5)
	same(#heard(world, ann, "result"), 2, "the second race decided")
	local second = card(world, ann, "result")
	same(second.why, "finished", "decided on her finish, not ended by the car")
	same(second.winner, "Ann", "she won")
	same(ann.money, 3000, "paid")
end)

World.test("a race nobody finishes ends at the time limit and hands the car back", function(world)
	local ann, t = annAndCar(world, 2000)
	world:setConfig("server", "raceTimeLimitMinutes", "1")
	press(world, ann)
	t.car.speed = 1.5
	world:advance(66)
	local result = card(world, ann, "result")
	same(result.why, "timeout", "the time limit")
	same(result.winner, nil, "no winner")
	expect(givenBack(t), "given back")
end)

World.test("a car taken out of traffic during the race is left alone at the end", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	ann.trafficData[t.car.id] = nil
	world:advance(6)
	same(card(world, ann, "result").why, "aiOut", "the race ended")
	same(t.entry.roleName, "empty", "the old entry is not touched")
end)

World.test("a player in a traffic race is busy for challenges and events, and a street racer cannot start one", function(world)
	roads(world)
	local ann = world:join("Ann", 1000, 0)
	local bob = world:join("Bob", 1000, 1)
	world:giveTraffic(ann, {x = 4, y = 3})
	world:advance(1)
	press(world, ann)
	world:serverOutput(function()
		mileageOffer(bob.id, World.encode({kind = "race", to = ann.id, amount = 0, start = {x = 50, y = 0, z = 0},
			finish = FINISH}))
	end)
	world:pump()
	local closed = world:received(bob, "rxMileageOfferClosed")
	same(closed[#closed].why, "busy", "a challenge to her is refused")
	world:console("Mileage Event 5 100 random")
	local announced = nil
	for _, m in ipairs(world:received(ann, "rxMileageEvent")) do announced = m end
	world:as(ann, function() mileage_raceEvents.join(announced.id) end)
	world:pump()
	local refused = nil
	for _, m in ipairs(world:received(ann, "rxMileageEvent")) do if m.phase == "refused" then refused = m end end
	same(refused.why, "Finish your race first, then join.", "an event join is refused")
	world:as(ann, function() mileage_streetRace.giveUp() end)
	world:pump()
	-- Bob in a street race cannot start a traffic race.
	local bobs = world:giveTraffic(bob, {x = 54, y = 3})
	world:serverOutput(function()
		mileageOffer(ann.id, World.encode({kind = "race", to = bob.id, amount = 0, start = {x = 0, y = 0, z = 0},
			finish = FINISH}))
	end)
	world:pump()
	local offer = world:received(bob, "rxMileageOffer")[1]
	world:serverOutput(function() mileageOfferAnswer(bob.id, World.encode({id = offer.id, accept = true})) end)
	world:pump()
	world:serverOutput(function()
		mileageAiRace(bob.id, World.encode({request = {car = bobs.sid, start = {x = 50, y = 0, z = 0}, finish = FINISH}}))
	end)
	world:pump()
	same(heard(world, bob, "refused")[1].why, "You are already in a race.", "busy in a street race")
end)

World.test("a report about an ended race changes nothing", function(world)
	local ann, t = annAndCar(world, 2000)
	local id = raceAnn(world, ann, t, 40, 40)
	same(ann.money, 3000, "paid once")
	world:serverOutput(function()
		mileageRaceReport(ann.id, World.encode({race = id, finished = 41}))
		mileageRaceReport(ann.id, World.encode({race = id, aiOut = "stuck"}))
		mileageRaceReport(ann.id, World.encode({race = id, gaveUp = true}))
	end)
	world:advance(8)
	same(ann.money, 3000, "nothing more")
	same(#heard(world, ann, "result"), 1, "one result")
end)

--== a host's game that lies about the traffic car (security S1) ===================

-- Drops the host's own reports about the traffic car, as a modified game would.
local function silenceTrafficCar(world)
	world.filter = function(m)
		if m.way == "toServer" and m.name == "mileageRaceReport" and (m.data:find("aiFinished", 1, true)
				or m.data:find("aiOut", 1, true)) then
			return "drop"
		end
	end
end

World.test("a host's game that hides the traffic car's time cannot win when the server sees the car finish first", function(world)
	local ann, t = annAndCar(world, 2000)
	silenceTrafficCar(world)
	raceAnn(world, ann, t, 70, 37)
	local result = card(world, ann, "result")
	same(result.aiWon, true, "the server saw the car finish first")
	same(result.places[1].car, true, "the car first")
	local carSeconds = result.places[1].seconds
	expect(carSeconds > 35 and carSeconds < 36,
		"on the server's clock, where it crossed the line between its readings at 35 and 36 s: " .. carSeconds)
	same(ann.money, 1000, "not paid")
	same(wins(world, "Ann"), 0, "no win")
end)

World.test("a traffic car that stops ends the race with no winner even when the host's game says nothing", function(world)
	local ann, t = annAndCar(world, 2000)
	silenceTrafficCar(world)
	press(world, ann)
	world:advance(5)
	world:advance(19)
	same(card(world, ann, "result"), nil, "still racing after 19 s")
	world:advance(2)
	same(card(world, ann, "result").why, "aiOut", "the server saw it stand still")
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(8)
	same(ann.money, 1000, "nobody paid")
	expect(t, "the car")
end)

World.test("a traffic car time is ignored while the server sees the car far from the finish", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	local id = heard(world, ann, "countdown")[1].race
	t.car.speed = 30
	world:advance(30)
	world:serverOutput(function() mileageRaceReport(ann.id, World.encode({race = id, aiFinished = 25})) end)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	untilResult(world, ann)
	same(card(world, ann, "result").winner, "Ann", "the claimed time did not count")
	same(ann.money, 3000, "paid")
end)

World.test("where the server cannot read cars the host's game reports the traffic car", function(world)
	local ann, t = annAndCar(world, 2000)
	world.hidePositions = true
	raceAnn(world, ann, t, 70, 37)
	same(card(world, ann, "result").aiWon, true, "the reported time counts")
	same(ann.money, 1000, "not paid")
end)

--== second opinion: the clock after a finish, and the car being driven ==========

World.test("a traffic car that arrives after the host is timed after the host, on the running clock", function(world)
	local ann, t = annAndCar(world, 2000)
	-- Only the host's game can time the car here.
	world.hideTraffic = true
	press(world, ann)
	t.car.speed = 66
	world:advance(5)
	world:advance(35)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(8)
	local result = card(world, ann, "result")
	same(result.places[1].name, "Ann", "Ann first")
	same(result.places[1].seconds, 36, "her time")
	same(result.places[2].car, true, "the car second")
	same(result.places[2].seconds, 38, "the car's own time, not hers")
	same(result.winner, "Ann", "she beat it")
	same(wins(world, "Ann"), 1, "the win counts")
	same(ann.money, 1000, "no reward for a car the server never saw")
	same(result.prize, 0, "and the result says none was paid")
end)

World.test("a player ahead of a creeping traffic car is decided the winner without waiting for it", function(world)
	local ann, t = annAndCar(world, 2000)
	world:setConfig("server", "raceTimeLimitMinutes", "1")
	-- A modified host game that says nothing of its car, creeping along so the server never
	-- sees it stand still.
	silenceTrafficCar(world)
	press(world, ann)
	t.car.speed = 1
	world:advance(5)
	world:advance(30)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(6)
	local result = card(world, ann, "result")
	expect(result ~= nil, "decided while the car is still on its way")
	same(result.why, "finished", "on her finish, not the time limit")
	same(result.winner, "Ann", "she beat it")
	same(wins(world, "Ann"), 1, "the win counts")
	-- About 31 m driven in 31 s, far under a racing pace.
	same(result.rewardWithheld, "slow", "the result says why")
	same(result.prize, 0, "no reward for a car that did not race")
	same(result.prizeAgainIn, 0, "and no wait")
	same(ann.money, 1000, "not paid")
	same(world:printedMatching("reward withheld: the car was too slow"), 1, "the console says why")
end)

World.test("a parked car far away does not move the race's start or who is invited", function(world)
	roads(world)
	world:setConfig("server", "aiRacePrize", "2000")
	local ann = world:join("Ann", 1000, 0)
	local bob = world:join("Bob", 1000, 1)
	ann.parkedCar = {pos = {x = 0, y = 7000, z = 0}}
	bob.parkedCar = {pos = {x = 3000, y = -3000, z = 0}}
	world:giveTraffic(ann, {x = 4, y = 3})
	world:advance(1)
	expect(press(world, ann), "the press sent a request")
	same(#heard(world, ann, "refused"), 0, "not refused for the parked car")
	same(world:printedMatching("Ann races their Ibishu Pessima to a finish 2500 m away, 1 invited"), 1,
		"the start is the car she drives, and Bob is invited")
	same(#heard(world, bob, "invite"), 1, "Bob's driven car is near")
end)

--== the key and the load order (T13) =========================================

World.test("the key action file names mileageAiRace under Gameplay with no default key and calls press", function(world)
	local file = World.realOpen("Resources/Client/Mileage/lua/ge/extensions/core/input/actions/mileage.json", "r")
	expect(file, "the action file exists")
	local actions = World.decode(file:read("*a"))
	file:close()
	local action = actions.mileageAiRace
	same(action.cat, "gameplay", "under Gameplay")
	same(action.title, "Race the car beside you (Mileage)", "its title")
	same(action.onDown, "if mileage_aiRace then mileage_aiRace.press() end", "presses the button")
	same(action.ctx, "tlua", "game Lua")
	local keys = 0
	for _ in pairs(actions) do keys = keys + 1 end
	same(keys, 1, "one action")
	expect(not action.binding and not action.default, "no default key")
	-- Each game asks the game to read the file again when Mileage loads.
	world:join("Ann", 1000, 0)
	same(world.actionReloads, 1, "read again once")
	same(world.actionFile, "/lua/ge/extensions/core/input/actions/mileage.json", "this file")
end)

World.test("the mod loads the traffic race after the street race and race events", function()
	local file = World.realOpen("Resources/Client/Mileage/scripts/Mileage/modScript.lua", "r")
	local text = file:read("*a")
	file:close()
	local street = text:find("loadPersistent('mileage/streetRace')", 1, true)
	local events = text:find("loadPersistent('mileage/raceEvents')", 1, true)
	local traffic = text:find("loadPersistent('mileage/aiRace')", 1, true)
	expect(traffic, "aiRace is loaded")
	expect(traffic > street and traffic > events, "after both")
end)

--== players near you (T10, T11) =============================================

-- Ann and her traffic car, Bob 50 m away and Cat 900 m away.
local function threeNear(world, prize)
	local ann, t = annAndCar(world, prize)
	local bob = world:join("Bob", 1000, 1)
	local cat = world:join("Cat", 1000, 2)
	world:drive(cat, 900, 0)
	world:advance(1)
	return ann, t, bob, cat
end

World.test("players within 300 m are invited and a far player is not", function(world)
	local ann, _, bob, cat = threeNear(world, 2000)
	press(world, ann)
	local invite = card(world, bob, "invite")
	same(invite.host, "Ann", "who started it")
	same(invite.car, "Ibishu Pessima", "the car")
	same(invite.prize, 3000, "the reward if Bob joins")
	same(invite.seconds, 5, "5 seconds to join")
	same(invite.distance, 2500, "the finish from Bob")
	same(card(world, cat, "invite"), nil, "Cat is 900 m away")
	same(#heard(world, cat, "invite"), 0, "nothing sent to Cat")
	world:advance(6)
	same(#heard(world, bob, "inviteClosed"), 1, "Bob's invite closes at zero")
	same(cards(world, bob, "inviteClosed"), 1, "his card goes")
end)

World.test("where the server cannot read cars nobody is invited", function(world)
	local ann, _, bob = threeNear(world, 2000)
	world.hidePositions = true
	press(world, ann)
	same(#heard(world, ann, "countdown"), 1, "Ann races alone")
	same(#heard(world, bob, "invite"), 0, "Bob is not invited")
end)

World.test("an invited player joins rolling before zero and a late join is closed", function(world)
	local ann, t, bob, cat = threeNear(world, 2000)
	press(world, ann)
	world:advance(2)
	expect(world:as(bob, function() return mileage_aiRace.press() end), "Bob's press joins")
	world:pump()
	local countdown = heard(world, bob, "countdown")[1]
	same(countdown.seconds, 3, "the seconds left")
	same(countdown.prize, 3000, "150% with Bob")
	same(lastRace(world, bob, "countdown").count, 3, "Bob counts down from where Ann is")
	same(lastRace(world, bob, "countdown").rolling, true, "rolling")
	same(lastRace(world, ann, "countdown").reward, 3000, "Ann's reward grows")
	same(lastRace(world, ann, "countdown").other, "the Ibishu Pessima and Bob", "Ann races both")
	same(heard(world, ann, "joined")[1].prize, 3000, "everyone hears the reward")
	same(bob.trafficData[t.car.id], nil, "Bob's game drives no traffic")
	world:serverOutput(function() mileageAiRace(cat.id, World.encode({join = countdown.race})) end)
	world:pump()
	same(#heard(world, cat, "inviteClosed"), 1, "Cat was not invited")
	world:advance(3)
	same(lastRace(world, bob, "go").rolling, true, "Bob's green with Ann's")
	same(bob.car.freezes, 0, "never held")
	same(#bob.teleports, 0, "never moved")
	world:serverOutput(function() mileageAiRace(bob.id, World.encode({join = countdown.race})) end)
	world:pump()
	same(#heard(world, bob, "inviteClosed"), 1, "a join after zero is closed")
end)

World.test("a joined player who beats the traffic car first gets 150%", function(world)
	local ann, t, bob = threeNear(world, 2000)
	press(world, ann)
	world:as(bob, function() mileage_aiRace.press() end)
	world:pump()
	t.car.speed = 75
	world:advance(5)
	world:advance(30)
	world:drive(bob, FINISH.x, FINISH.y, FINISH.z)
	world:advance(10)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(10)
	same(bob.money, 4000, "Bob gets 150% of $2,000")
	same(ann.money, 1000, "Ann nothing")
	same(wins(world, "Bob"), 1, "Bob's win")
	local result = card(world, ann, "result")
	same(result.winner, "Bob", "Bob won")
	same(result.places[1].name, "Bob", "Bob first")
	same(result.places[2].car, true, "the car second")
	same(card(world, bob, "result").prize, 3000, "Bob is told")
	expect(t.entry.roleName == "standard" and t.entry.enableRespawn, "the car is back in traffic")
end)

World.test("an invited player who gives up drops out and the others race on", function(world)
	local ann, t, bob = threeNear(world, 2000)
	press(world, ann)
	world:as(bob, function() mileage_aiRace.press() end)
	world:pump()
	t.car.speed = 30
	world:advance(10)
	world:as(bob, function() mileage_streetRace.giveUp() end)
	world:pump()
	local out = card(world, bob, "result")
	same(out.out, true, "Bob is out")
	same(out.why, "gaveUp", "he gave up")
	world:as(bob, function() same(mileage_streetRace.current(), nil, "Bob's panel is gone") end)
	world:advance(25)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	untilResult(world, ann)
	same(card(world, ann, "result").winner, "Ann", "Ann raced on and won")
	same(ann.money, 4000, "the reward counted Bob at zero: 150%")
	same(bob.money, 1000, "Bob nothing")
end)

World.test("declining sends nothing and clears the invite", function(world)
	local ann, _, bob = threeNear(world, 2000)
	press(world, ann)
	world:as(bob, function() expect(mileage_aiRace.decline(), "declined") end)
	world:pump()
	same(cards(world, bob, "inviteClosed"), 1, "the card goes")
	same(sentToServer(world, bob, "mileageAiRace"), 0, "nothing sent")
	world:as(bob, function() same(mileage_aiRace.press(), false, "no invite left to join") end)
end)

--== amounts, limits and endings the cards name ===============================

World.test("two joined players make the race reward 200%, paid to the winner alone", function(world)
	local ann, t, bob = threeNear(world, 2000)
	-- Dan drives 150 m from Ann, inside the 300 m invite circle.
	local dan = world:join("Dan", 1000, 3)
	world:advance(1)
	press(world, ann)
	world:as(bob, function() mileage_aiRace.press() end)
	world:as(dan, function() mileage_aiRace.press() end)
	world:pump()
	same(heard(world, dan, "countdown")[1].prize, 4000, "200% with two joined players")
	same(lastRace(world, ann, "countdown").reward, 4000, "the host sees 200% too")
	t.car.speed = 75
	world:advance(5)
	world:advance(30)
	world:drive(dan, FINISH.x, FINISH.y, FINISH.z)
	untilResult(world, dan)
	same(card(world, dan, "result").winner, "Dan", "Dan beat the car")
	same(dan.money, 5000, "Dan gets 200% of $2,000")
	same(bob.money, 1000, "Bob nothing")
	same(ann.money, 1000, "Ann nothing")
	same(card(world, ann, "result").reward, 4000, "the result names the 200% reward")
end)

World.test("the race reward with one joined player is rounded down to whole dollars", function(world)
	local ann, t, bob = threeNear(world, 1001)
	press(world, ann)
	same(card(world, bob, "invite").prize, 1501, "150% of $1,001 rounded down")
	world:as(bob, function() mileage_aiRace.press() end)
	world:pump()
	t.car.speed = 75
	world:advance(5)
	world:advance(30)
	world:drive(bob, FINISH.x, FINISH.y, FINISH.z)
	untilResult(world, bob)
	same(card(world, bob, "result").prize, 1501, "paid rounded down")
	same(bob.money, 2501, "Bob's career gains $1,501")
	same(ann.money, 1000, "Ann nothing")
end)

World.test("a player's time equal to the traffic car's does not beat it", function(world)
	local ann = annAndCar(world, 2000)
	-- The server cannot read the traffic car, and both times arrive straight from the host.
	world.hideTraffic = true
	press(world, ann)
	local id = heard(world, ann, "countdown")[1].race
	world.filter = function(m)
		if m.way == "toServer" and m.name == "mileageRaceReport" then return "drop" end
	end
	world:advance(5)
	world:advance(40)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:serverOutput(function()
		mileageRaceReport(ann.id, World.encode({race = id, finished = 40}))
		mileageRaceReport(ann.id, World.encode({race = id, aiFinished = 40}))
	end)
	world:pump()
	world:advance(6)
	local result = card(world, ann, "result")
	same(result.aiWon, true, "the car keeps the tie")
	same(result.winner, nil, "no player won")
	same(result.places[1].car, true, "the car listed first")
	same(wins(world, "Ann"), 0, "no leaderboard win for a tie")
	same(ann.money, 1000, "nothing paid")
end)

World.test("the server takes a finish 1350 to 4150 m from the host's car and refuses one just outside", function(world)
	roads(world)
	local ann = world:join("Ann", 1000, 0)
	local mine = world:giveTraffic(ann, {x = 4, y = 3})
	-- Ann's own car stands at the origin, where the server reads it.
	local function request(y)
		local before = #heard(world, ann, "countdown")
		world:serverOutput(function()
			mileageAiRace(ann.id, World.encode({request = {car = mine.sid, start = {x = 0, y = 0, z = 0},
				finish = {x = 0, y = y, z = 0}, model = "Ibishu Pessima"}}))
		end)
		world:pump()
		local started = heard(world, ann, "countdown")[before + 1]
		if started then
			world:serverOutput(function() mileageRaceReport(ann.id, World.encode({race = started.race, gaveUp = true})) end)
			world:pump()
			return "started"
		end
		local refused = heard(world, ann, "refused")
		return refused[#refused] and refused[#refused].why
	end
	local tooFar = "The finish must be 1.5 to 4 km away. Try again."
	same(request(1350), "started", "1350 m: the picker's 1.5 km less the 150 m the car moved")
	same(request(1349), tooFar, "1349 m is too close")
	same(request(4150), "started", "4150 m: 4 km plus 150 m")
	same(request(4151), tooFar, "4151 m is too far")
end)

World.test("the car's model name is cut to 40 characters without control characters, and none is the traffic car", function(world)
	roads(world)
	local ann = world:join("Ann", 1000, 0)
	local mine = world:giveTraffic(ann, {x = 4, y = 3})
	local function start(model)
		local before = #heard(world, ann, "countdown")
		world:serverOutput(function()
			mileageAiRace(ann.id, World.encode({request = {car = mine.sid, start = {x = 0, y = 0, z = 0}, finish = FINISH,
				model = model}}))
		end)
		world:pump()
		local countdown = heard(world, ann, "countdown")[before + 1]
		world:serverOutput(function() mileageRaceReport(ann.id, World.encode({race = countdown.race, gaveUp = true})) end)
		world:pump()
		return countdown.car
	end
	local long = start("Ibishu\nPessima " .. string.rep("x", 60))
	expect(#long <= 40, "at most 40 characters: " .. #long)
	expect(not long:find("%c"), "no control characters")
	same(long:sub(1, 14), "Ibishu Pessima", "the name kept")
	same(start(nil), "traffic car", "no model sent")
	same(start("   "), "traffic car", "only spaces")
end)

World.test("when the host leaves, a joined player's race ends with no winner and their panel goes", function(world)
	local ann, t, bob = threeNear(world, 2000)
	press(world, ann)
	world:as(bob, function() mileage_aiRace.press() end)
	world:pump()
	t.car.speed = 30
	world:advance(10)
	world:hook(ann, "onBeamMPServerLeave")
	world:leave(ann)
	local result = card(world, bob, "result")
	same(result.why, "hostLeft", "Ann left")
	same(result.winner, nil, "no winner")
	world:as(bob, function() same(mileage_streetRace.current(), nil, "Bob's race panel is gone") end)
	world:drive(bob, FINISH.x, FINISH.y, FINISH.z)
	world:advance(8)
	same(bob.money, 1000, "Bob is not paid for finishing alone")
	same(wins(world, "Bob"), 0, "no win")
end)

World.test("with no wait set, every win against the traffic car is paid", function(world)
	local ann, t = annAndCar(world, 2000)
	world:setConfig("server", "aiRacePrizeCooldownMinutes", "0")
	raceAnn(world, ann, t, 30, 40)
	same(ann.money, 3000, "the first win paid")
	world:drive(ann, 0, 0)
	t.car.pos, t.car.racing = {x = 4, y = 3, z = 0}, false
	world:advance(2)
	raceAnn(world, ann, t, 30, 40)
	same(ann.money, 5000, "the next win paid at once")
	same(card(world, ann, "result").prizeAgainIn, 0, "no wait shown")
end)

World.test("the owner's race reward is held to 0 to 1,000,000", function(world)
	local ann = world:join("Ann", 1000, 0)
	world:setConfig("server", "aiRacePrize", "5000000")
	local status = heard(world, ann, "status")
	same(status[#status].prize, 1000000, "capped at 1,000,000")
	world:setConfig("server", "aiRacePrize", "-50")
	status = heard(world, ann, "status")
	same(status[#status].prize, 0, "never below 0")
end)

World.test("a press the server never answers can be made again later", function(world)
	local ann = annAndCar(world, 2000)
	world.filter = function(m)
		if m.way == "toServer" and m.name == "mileageAiRace" then return "drop" end
	end
	expect(press(world, ann), "the press sent a request")
	same(press(world, ann), false, "not sent twice while it waits")
	world:advance(11)
	world.filter = nil
	expect(press(world, ann), "sent again once the request was lost")
	same(#heard(world, ann, "countdown"), 1, "the race starts")
end)

World.test("a win the server could not pay says so and starts no wait, so the next seen win is paid", function(world)
	local ann, t = annAndCar(world, 2000)
	-- Only the host's game can time the car here, so the win counts but is never paid.
	world.hideTraffic = true
	raceAnn(world, ann, t, 66, 35)
	local result = card(world, ann, "result")
	same(result.winner, "Ann", "she beat it")
	same(result.prize, 0, "nothing paid")
	same(result.reward, 2000, "the result still names the reward on this server")
	same(result.prizeAgainIn, 0, "an unpaid win starts no wait")
	same(ann.money, 1000, "not paid")
	world.hideTraffic = false
	world:drive(ann, 0, 0)
	t.car.pos, t.car.racing = {x = 4, y = 3, z = 0}, false
	world:advance(2)
	raceAnn(world, ann, t, 40, 35)
	local results = heard(world, ann, "result")
	same(results[#results].prize, 2000, "the next win, with the car seen, is paid at once")
	same(ann.money, 3000, "Ann's career gains $2,000")
	same(wins(world, "Ann"), 2, "both wins count")
end)

--== decided at the first player's finish (#122, #123, #116) ===================

-- The entry of a result's notFinished list named name, or the car's when name is nil.
local function notFinished(result, name)
	for _, entry in ipairs(result and result.notFinished or {}) do
		if (name == nil and entry.car == true) or (name ~= nil and entry.name == name and not entry.car) then
			return entry
		end
	end
	return nil
end

World.test("a player who beats the traffic car gets the result within 6 s of finishing", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	-- About 83 s to the finish: still more than 1 km out when Ann arrives.
	t.car.speed = 30
	world:advance(5)
	world:advance(40)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(6)
	local result = card(world, ann, "result")
	expect(result ~= nil, "no result 6 s after Ann finished")
	same(result.winner, "Ann", "she won")
	same(result.why, "finished", "decided on her finish")
	same(ann.money, 3000, "the race reward")
	same(wins(world, "Ann"), 1, "a leaderboard win")
	same(#result.places, 1, "only Ann has a time")
	local car = notFinished(result)
	expect(car ~= nil, "the car is listed as not finished")
	same(car.name, "Ibishu Pessima", "by its model")
	same(car.out, nil, "still on its way")
	expect(givenBack(t), "the car is back in traffic")
end)

World.test("the traffic car gone after the player finished still leaves her the winner, paid", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	t.car.speed = 30
	world:advance(5)
	world:advance(30)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(1)
	t.gone = true
	world:advance(5)
	local result = card(world, ann, "result")
	expect(result ~= nil, "a result")
	same(result.winner, "Ann", "she won")
	same(result.why, "finished", "not ended by the car")
	same(ann.money, 3000, "paid")
	same(wins(world, "Ann"), 1, "the win counts")
	same(notFinished(result).out, "gone", "the car is listed as out")
	same(#heard(world, ann, "result"), 1, "one result")
end)

World.test("the traffic car stalling after the player finished still leaves her the winner", function(world)
	local ann, t = annAndCar(world, 2000)
	-- The host's game says nothing; the server's own stand-still check sees the car stop.
	silenceTrafficCar(world)
	press(world, ann)
	t.car.speed = 30
	world:advance(5)
	world:advance(30)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(1)
	t.car.speed = 0
	world:advance(25)
	local result = card(world, ann, "result")
	same(result and result.winner, "Ann", "she won")
	same(ann.money, 3000, "paid")
	same(#heard(world, ann, "result"), 1, "one result")
end)

World.test("a player who finished is free for a race event once the result is in", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	t.car.speed = 20
	world:advance(5)
	world:advance(40)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(10)
	world:console("Mileage Event 5 100 random")
	local announced = nil
	for _, m in ipairs(world:received(ann, "rxMileageEvent")) do announced = m end
	world:as(ann, function() mileage_raceEvents.join(announced.id) end)
	world:pump()
	local refused = nil
	for _, m in ipairs(world:received(ann, "rxMileageEvent")) do if m.phase == "refused" then refused = m end end
	same(refused and refused.why, nil, "the event join is taken")
end)

World.test("a joined player still driving when the race is decided is listed as not finished", function(world)
	local ann, t, bob = threeNear(world, 2000)
	press(world, ann)
	world:as(bob, function() mileage_aiRace.press() end)
	world:pump()
	t.car.speed = 30
	world:advance(5)
	world:advance(30)
	world:drive(bob, FINISH.x, FINISH.y, FINISH.z)
	world:advance(6)
	local result = card(world, ann, "result")
	expect(result ~= nil, "decided about 5 s after Bob's finish")
	same(result.winner, "Bob", "Bob won")
	same(bob.money, 4000, "Bob gets 150%")
	same(#result.places, 1, "only Bob has a time")
	expect(notFinished(result, "Ann") ~= nil, "Ann is listed as not finished")
	expect(notFinished(result) ~= nil, "and the car")
	world:as(ann, function() same(mileage_streetRace.current(), nil, "Ann's race panel is gone") end)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(5)
	same(#heard(world, ann, "result"), 1, "her later arrival changes nothing")
	same(ann.money, 1000, "Ann nothing")
end)

World.test("the host giving up after her own finish keeps her time", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	local id = heard(world, ann, "countdown")[1].race
	t.car.speed = 30
	world:advance(5)
	world:advance(30)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(1)
	world:serverOutput(function() mileageRaceReport(ann.id, World.encode({race = id, gaveUp = true})) end)
	world:pump()
	world:advance(5)
	local result = card(world, ann, "result")
	same(result and result.why, "finished", "the race was not ended by her Give up")
	same(result.winner, "Ann", "she won")
	same(ann.money, 3000, "paid")
end)

--== the car timed at the line, and checked before the reward (#115, #114) =======

-- Where the server reads traffic car t now, as {x, y}.
local function serverSees(t)
	local owner, vehicle = t.sid:match("^(%d+)%-(%d+)$")
	local raw = MP.GetPositionRaw(tonumber(owner), tonumber(vehicle))
	return raw and {x = raw.pos[1], y = raw.pos[2]}
end

World.test("the test world can hold the server's view of a traffic car while it drives on", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	t.car.speed = 50
	world:advance(8)
	local before = serverSees(t).y
	world:holdTraffic(t, 2)
	world:advance(1)
	same(serverSees(t).y, before, "held")
	expect(t.car.pos.y > before, "the car drove on")
	world:advance(1)
	same(serverSees(t).y, t.car.pos.y, "caught up after 2 ticks")
end)

World.test("an honest 90 m/s traffic car seen through late and bunched-up positions keeps the reward", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	t.car.speed = 90
	world:advance(5)
	world:advance(8)
	-- Three ticks with no new position, then 360 m at once; then a single late one.
	world:holdTraffic(t, 3)
	world:advance(8)
	world:holdTraffic(t, 1)
	world:advance(9)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	untilResult(world, ann, 10)
	local result = card(world, ann, "result")
	same(result.winner, "Ann", "she beat it")
	same(result.rewardWithheld, nil, "the car raced")
	same(result.prize, 2000, "paid")
	same(ann.money, 3000, "her career gains it")
end)

World.test("a traffic car driving 20 m/s on a road leading away from the finish keeps the reward", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	t.car.speed = 20
	world:advance(5)
	-- Its route first leads south, away from the finish.
	t.car.target = {x = 0, y = -5000, z = 0}
	world:advance(30)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	untilResult(world, ann, 10)
	local result = card(world, ann, "result")
	same(result.winner, "Ann", "she beat it")
	same(result.rewardWithheld, nil, "a detour still counts as driving")
	same(ann.money, 3000, "paid")
end)

-- The car at 20 m/s is read at y = 20 s + 3 after s seconds of racing, so it crosses the
-- 20 m line (y = 2480) at 123.85 s, and is first seen within 40 m at 123 s.
World.test("a close finish times the traffic car where it crossed the 20 m line", function(world)
	local function race(annAt)
		local w = World.new()
		local ann, t = annAndCar(w, 2000)
		press(w, ann)
		t.car.speed = 20
		w:advance(5)
		w:advance(annAt)
		w:drive(ann, FINISH.x, FINISH.y, FINISH.z)
		untilResult(w, ann, 10)
		return card(w, ann, "result"), ann
	end
	-- Ann's game reports the second after she arrives: 123 s, ahead of the car.
	local result, ann = race(122)
	same(result.winner, "Ann", "Ann reached the line before the car")
	same(result.places[1].name, "Ann", "Ann first")
	same(result.places[1].seconds, 123, "her time")
	same(result.places[2].car, true, "the car second")
	expect(math.abs(result.places[2].seconds - 123.85) < 0.01,
		"the car's time where it crossed the line: " .. tostring(result.places[2].seconds))
	same(ann.money, 3000, "paid")
	-- 124 s: the car crossed first and still wins.
	result, ann = race(123)
	same(result.aiWon, true, "the car wins a close finish it led")
	expect(math.abs(result.places[1].seconds - 123.85) < 0.01, "the car first at 123.85 s")
	same(ann.money, 1000, "nobody paid")
end)

World.test("a traffic car moved 2.4 km in one second pays no reward and starts no wait", function(world)
	local ann, t = annAndCar(world, 2000)
	-- A modified host game: says nothing of its car, creeps it, then puts it near the finish.
	silenceTrafficCar(world)
	press(world, ann)
	t.car.speed = 1
	world:advance(5)
	world:advance(20)
	t.car.pos, t.car.speed = {x = 0, y = 2400, z = 0}, 0
	world:advance(10)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	untilResult(world, ann, 10)
	local result = card(world, ann, "result")
	same(result.winner, "Ann", "the win stands")
	same(wins(world, "Ann"), 1, "on the leaderboard")
	same(result.rewardWithheld, "jumped", "the result says why")
	same(result.prize, 0, "no reward")
	same(result.prizeAgainIn, 0, "no wait")
	same(ann.money, 1000, "not paid")
	same(world:printedMatching("reward withheld: the car jumped"), 1, "the console says why")
end)

--== edges of the line, the pace bar, the late window and the host's out report ==

-- The car at 90 m/s on a road past the finish is read at y = 2433 (67 m out) and y = 2523
-- (23 m beyond): neither reading is within 20 m, but the path between them crosses the
-- line, at y = 2480, 27.52 s after zero.
World.test("a fast traffic car that drives through the finish between two readings is timed at the line", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	t.car.speed = 90
	world:advance(5)
	t.car.target = {x = 0, y = 9000, z = 0}
	world:advance(28)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	untilResult(world, ann, 10)
	local result = card(world, ann, "result")
	same(result.aiWon, true, "the car crossed the line before Ann")
	same(result.places[1].car, true, "the car first")
	expect(math.abs(result.places[1].seconds - 27.52) < 0.05,
		"timed where its path crossed the 20 m line: " .. tostring(result.places[1].seconds))
	same(ann.money, 1000, "nobody paid")
	same(wins(world, "Ann"), 0, "no win")
end)

-- A car that passes about 30 m beside the finish never came within the players' 20 m line.
World.test("a traffic car that passes 30 m beside the finish is not timed, and the player who arrives wins", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	t.car.speed = 90
	world:advance(5)
	t.car.target = {x = 100, y = 9000, z = 0}
	world:advance(35)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	untilResult(world, ann, 10)
	local result = card(world, ann, "result")
	same(result.winner, "Ann", "the car never crossed the line")
	same(#result.places, 1, "only Ann has a time")
	same(ann.money, 3000, "paid: the car raced")
end)

-- Ann's time is 41 s; the bar is 8 m/s x 41 s = 328 m of driving.
World.test("a traffic car at 9 m/s keeps the reward and one at 7 m/s does not", function(world)
	local function race(speed)
		local w = World.new()
		local ann, t = annAndCar(w, 2000)
		silenceTrafficCar(w)
		press(w, ann)
		t.car.speed = speed
		w:advance(5)
		w:advance(40)
		w:drive(ann, FINISH.x, FINISH.y, FINISH.z)
		untilResult(w, ann, 10)
		return card(w, ann, "result"), ann, w
	end
	local result, ann = race(9)
	same(result.winner, "Ann", "Ann won at 9 m/s")
	same(result.places[1].seconds, 41, "her time")
	same(result.rewardWithheld, nil, "above the bar")
	same(ann.money, 3000, "paid")
	local w
	result, ann, w = race(7)
	same(result.winner, "Ann", "Ann won at 7 m/s")
	same(wins(w, "Ann"), 1, "the win counts")
	same(result.rewardWithheld, "slow", "under the bar")
	same(ann.money, 1000, "not paid")
end)

-- A crash or reset well after the winner's finish is not the car's race.
World.test("the traffic car thrown 3 km 4 s after the winner's finish does not cost her the reward", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	t.car.speed = 30
	world:advance(5)
	world:advance(40)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(4)
	same(card(world, ann, "result"), nil, "not decided yet when the car is thrown")
	t.car.pos = {x = 0, y = -3000, z = 0}
	untilResult(world, ann, 10)
	local result = card(world, ann, "result")
	same(result.winner, "Ann", "she won")
	same(result.rewardWithheld, nil, "not marked jumped")
	same(ann.money, 3000, "paid")
end)

-- The host's game says why its car is out; anything but gone or stuck is shown as out.
World.test("a host's out report with an unknown reason after the player's finish is noted as out", function(world)
	local ann, t = annAndCar(world, 2000)
	press(world, ann)
	local id = heard(world, ann, "countdown")[1].race
	t.car.speed = 30
	world:advance(5)
	world:advance(30)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(1)
	world:serverOutput(function() mileageRaceReport(ann.id, World.encode({race = id, aiOut = "<b>made up</b>"})) end)
	world:pump()
	world:advance(5)
	local result = card(world, ann, "result")
	same(result and result.why, "finished", "decided on her finish")
	same(result.winner, "Ann", "she won")
	same(notFinished(result).out, "out", "the host's text is not passed on")
	same(ann.money, 3000, "paid")
end)

--== second opinion: a stop before the line, height, a reset after the finish =====

-- Bob's game clock runs 3 s ahead of the server's, which the server allows; the host's
-- game then throws the traffic car through the finish in one tick.
World.test("a traffic car thrown through the finish after a joined player's finish does not take the win", function(world)
	local ann, t, bob = threeNear(world, 2000)
	press(world, ann)
	local id = heard(world, ann, "countdown")[1].race
	world:as(bob, function() mileage_aiRace.press() end)
	world:pump()
	world.filter = function(m)
		if m.way == "toServer" and m.name == "mileageRaceReport" and (m.data:find("finished", 1, true)
				or m.data:find("aiOut", 1, true)) then
			return "drop"
		end
	end
	t.car.speed = 30
	world:advance(5)
	world:advance(35)
	world:drive(bob, FINISH.x, FINISH.y, FINISH.z)
	world:serverOutput(function() mileageRaceReport(bob.id, World.encode({race = id, finished = 38})) end)
	world:pump()
	-- From about 1 km out to 100 m past the finish in one tick.
	t.car.pos, t.car.speed = {x = 0, y = 2600, z = 0}, 0
	untilResult(world, bob, 10)
	local result = card(world, bob, "result")
	same(result.winner, "Bob", "the throw gives the car no time")
	same(result.aiWon, false, "the car did not win")
	same(bob.money, 4000, "Bob gets 150%")
end)

-- Ann reaches the line while the car stands 37 m from the finish; it drives on after her
-- time is in and crosses on its first reading after the stop.
World.test("a traffic car that stood still before the line is timed from its last reading, not before the stop", function(world)
	local ann, t = annAndCar(world, 2000)
	-- Only the server's reading times the car here.
	silenceTrafficCar(world)
	press(world, ann)
	t.car.speed = 20
	world:advance(5)
	world:advance(123)
	t.car.speed = 0
	world:advance(8)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(1)
	t.car.speed = 20
	untilResult(world, ann, 10)
	local result = card(world, ann, "result")
	same(result.places[1].name, "Ann", "Ann reached the line first, at 132 s")
	same(result.places[1].seconds, 132, "her time")
	same(result.places[2].car, true, "the car second")
	expect(result.places[2].seconds > 132, "the car's time after hers: " .. tostring(result.places[2].seconds))
	same(result.winner, "Ann", "she won")
end)

World.test("a traffic car passing 50 m below the finish is not timed at it", function(world)
	local ann, t = annAndCar(world, 2000)
	silenceTrafficCar(world)
	press(world, ann)
	t.car.speed = 70
	world:advance(5)
	-- An underpass: its road runs 50 m below the finish.
	t.car.pos = {x = t.car.pos.x, y = t.car.pos.y, z = -50}
	t.car.target = {x = 0, y = 9000, z = -50}
	world:advance(40)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	untilResult(world, ann, 10)
	local result = card(world, ann, "result")
	same(result.winner, "Ann", "the car never reached the finish")
	same(#result.places, 1, "only Ann has a time")
end)

World.test("a traffic car reset within 2 s after the winner's finish does not cost her the reward", function(world)
	local ann, t = annAndCar(world, 2000)
	silenceTrafficCar(world)
	press(world, ann)
	t.car.speed = 30
	world:advance(5)
	world:advance(30)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(1)
	-- Reset to where it started, the tick after her finish is in.
	t.car.pos, t.car.speed = {x = 4, y = 3, z = 0}, 0
	untilResult(world, ann, 10)
	local result = card(world, ann, "result")
	same(result.winner, "Ann", "she won")
	same(result.rewardWithheld, nil, "the reset is not a jump in the race")
	same(ann.money, 3000, "paid")
end)

World.test("a creeping traffic car thrown ahead just after the winner's finish still pays nothing", function(world)
	local ann, t = annAndCar(world, 2000)
	silenceTrafficCar(world)
	press(world, ann)
	t.car.speed = 1
	world:advance(5)
	world:advance(30)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(1)
	-- 2.4 km in one tick after her finish: neither a jump in the race nor distance driven.
	t.car.pos, t.car.speed = {x = 0, y = 2400, z = 0}, 0
	untilResult(world, ann, 10)
	local result = card(world, ann, "result")
	same(result.winner, "Ann", "she won")
	same(result.rewardWithheld, "slow", "the throw adds no distance")
	same(ann.money, 1000, "not paid")
end)

--== review: the line in height, the jump allowance, the late window, an unseen car ======

-- The car drives at 20 m/s on a road 15 m below the finish, from y = 3 at zero. It comes
-- within 20 m of the finish when it is sqrt(20^2 - 15^2) = 13.23 m short of it on the flat,
-- at y = 2486.77: 124.19 s. On the flat alone it would be 123.85 s, before Ann's 124 s.
World.test("a traffic car 15 m below the finish is timed where it comes within 20 m of it", function(world)
	local ann, t = annAndCar(world, 2000)
	silenceTrafficCar(world)
	press(world, ann)
	t.car.speed = 20
	world:advance(5)
	t.car.pos = {x = 0, y = t.car.pos.y, z = -15}
	t.car.target = {x = 0, y = 9000, z = -15}
	world:advance(123)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	untilResult(world, ann, 10)
	local result = card(world, ann, "result")
	same(result.places[1].name, "Ann", "Ann first, at 124 s")
	same(result.places[1].seconds, 124, "her time")
	same(result.places[2] and result.places[2].car, true, "the car second")
	expect(math.abs(result.places[2].seconds - 124.19) < 0.02,
		"timed at the 20 m sphere: " .. tostring(result.places[2].seconds))
	same(result.winner, "Ann", "she won")
end)

-- A step may be at most 100 m/s x (1 s since the last new reading + 2 s) = 300 m before the
-- winner's finish. The car drives 20 m/s and is moved on once; Ann's time is 41 s.
World.test("a traffic car step of 290 m in one second keeps the reward and one of 310 m does not", function(world)
	local function race(extra)
		local w = World.new()
		local ann, t = annAndCar(w, 2000)
		silenceTrafficCar(w)
		press(w, ann)
		t.car.speed = 20
		w:advance(5)
		w:advance(20)
		-- With the tick's own 20 m, the server sees a step of 20 + extra metres.
		t.car.pos = {x = t.car.pos.x, y = t.car.pos.y + extra, z = 0}
		w:advance(20)
		w:drive(ann, FINISH.x, FINISH.y, FINISH.z)
		untilResult(w, ann, 10)
		return card(w, ann, "result"), ann, w
	end
	local result, ann = race(270)
	same(result.winner, "Ann", "Ann won after a 290 m step")
	same(result.rewardWithheld, nil, "inside the 300 m allowance")
	same(ann.money, 3000, "paid")
	local w
	result, ann, w = race(290)
	same(result.winner, "Ann", "Ann won after a 310 m step")
	same(wins(w, "Ann"), 1, "the win counts")
	same(result.rewardWithheld, "jumped", "past the 300 m allowance")
	same(result.prizeAgainIn, 0, "no wait")
	same(ann.money, 1000, "not paid")
end)

-- Ann's time is 41 s, so the bar is 328 m. The car drives 8.5 m/s, 348.5 m by her time, but
-- the server's view of it is held for the 4 ticks before her finish (314.5 m seen) and
-- catches up on the first reading after it.
World.test("an honest traffic car whose positions catch up just after the winner's finish keeps the reward", function(world)
	local ann, t = annAndCar(world, 2000)
	silenceTrafficCar(world)
	press(world, ann)
	t.car.speed = 8.5
	world:advance(5)
	world:advance(37)
	world:holdTraffic(t, 4)
	world:advance(3)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	untilResult(world, ann, 10)
	local result = card(world, ann, "result")
	same(result.winner, "Ann", "she won")
	same(result.places[1].seconds, 41, "her time")
	same(result.rewardWithheld, nil, "the late readings count")
	same(ann.money, 3000, "paid")
end)

-- Ann's time is 31 s, so the bar is 248 m. The car crept 1 m/s, then drives a drivable
-- 90 m/s once her time is in: the 2 readings in the late window add 180 m (about 211 m in
-- all), the 3 after it before the decision would add 270 m more.
World.test("a creeping traffic car sped up after the winner's finish gains only the late window's distance", function(world)
	local ann, t = annAndCar(world, 2000)
	silenceTrafficCar(world)
	press(world, ann)
	t.car.speed = 1
	world:advance(5)
	world:advance(30)
	world:drive(ann, FINISH.x, FINISH.y, FINISH.z)
	world:advance(1)
	t.car.speed = 90
	untilResult(world, ann, 10)
	local result = card(world, ann, "result")
	same(result.winner, "Ann", "she won")
	same(result.places[1].seconds, 31, "her time")
	same(result.rewardWithheld, "slow", "distance after the late window does not count")
	same(ann.money, 1000, "not paid")
end)

-- The server cannot read the car from 120 s to 126 s; it crossed the 20 m line (y = 2480)
-- at 123.85 s on its straight 20 m/s path past the finish, between the readings at 119 s
-- and 127 s.
World.test("a traffic car the server could not read for a while is timed between its last reading and the next", function(world)
	local ann, t = annAndCar(world, 2000)
	silenceTrafficCar(world)
	press(world, ann)
	t.car.speed = 20
	world:advance(5)
	t.car.pos = {x = 0, y = t.car.pos.y, z = 0}
	t.car.target = {x = 0, y = 9000, z = 0}
	world:advance(119)
	world.hideTraffic = true
	world:advance(7)
	world.hideTraffic = false
	untilResult(world, ann, 10)
	local result = card(world, ann, "result")
	same(result.aiWon, true, "the car won")
	same(result.places[1].car, true, "the car first")
	expect(math.abs(result.places[1].seconds - 123.85) < 0.02,
		"timed where its path crossed the line: " .. tostring(result.places[1].seconds))
	same(ann.money, 1000, "nobody paid")
end)

--== no card while you are in a race, and back when your part is over ==========

-- One frame of p's traffic race module only, dt seconds long.
local function frame(world, p, dt)
	world:as(p, function() mileage_aiRace.onUpdate(dt) end)
end

-- Ann and her traffic car, and Bob, who Ann challenges to a street race with no stake.
local function annChallengesBob(world)
	local ann, t = annAndCar(world, 2000)
	local bob = world:join("Bob", 1000, 1)
	bob.car.pos = {x = 300, y = 900, z = 0}
	ann.route = {x = 0, y = 2400, z = 0}
	world:as(ann, function() expect(mileage_offers.race("Bob", 0), "challenge sent") end)
	world:pump()
	return ann, t, bob
end

World.test("a challenge waiting for an answer leaves the card; the race against a player hides it until you cross the line", function(world)
	local ann, t, bob = annChallengesBob(world)
	world:advance(1)
	same(card(world, ann).phase, "available", "an unanswered challenge does not hide it")
	local offer
	for _, o in ipairs(world:ui(bob, "MileageOffer")) do offer = o end
	world:as(bob, function() mileage_offers.answer(offer.id, true) end)
	world:pump()
	world:advance(1)
	same(card(world, ann).phase, "none", "lining up and counting down")
	world:advance(3)
	world:as(ann, function() same(mileage_streetRace.current().phase, "racing", "racing") end)
	t.car.pos = {x = ann.car.pos.x + 4, y = ann.car.pos.y + 3, z = 0}
	world:advance(2)
	same(card(world, ann).phase, "none", "racing beside her own traffic car")
	world:advance(30)
	world:drive(ann, 0, 2400)
	t.car.pos = {x = 4, y = 2403, z = 0}
	world:advance(1)
	world:as(ann, function() expect(mileage_streetRace.current().finished, "her finish is reported") end)
	world:as(bob, function() expect(mileage_streetRace.current() ~= nil, "Bob still races") end)
	same(card(world, ann).phase, "available", "back within one scan of her finish while Bob races")
end)

World.test("each race module answering busy hides the card, and it comes back within one scan of not busy", function(world)
	local ann = annAndCar(world, 2000)
	local answers = {
		{"mileage_spotRace", "busy"},
		{"mileage_raceEvents", "signedUp"},
		{"mileage_dragLobby", "busy"},
	}
	for _, a in ipairs(answers) do
		local name, fn = a[1], a[2]
		local ext = ann.extensions[name] or {}
		ann.extensions[name] = ext
		local before = ext[fn]
		local busy = true
		ext[fn] = function() return busy end
		world:advance(1)
		same(card(world, ann).phase, "none", name .. "." .. fn .. " busy")
		busy = false
		frame(world, ann, 0.25)
		same(card(world, ann).phase, "available", name .. "." .. fn .. " no longer busy, after one 0.25 s scan")
		ext[fn] = before
	end
	ann.mission = "aMission"
	world:advance(1)
	same(card(world, ann).phase, "none", "in a mission")
	ann.mission = nil
	world:advance(1)
	same(card(world, ann).phase, "available", "mission over")
end)

World.test("a missing, broken or raising race module reads as not busy", function(world)
	local ann = annAndCar(world, 2000)
	local cases = {
		{"no drag lobby", nil},
		{"a drag lobby that is not a table", "lobby"},
		{"a drag lobby with no busy", {}},
		{"a busy that is not a function", {busy = true}},
		{"a busy that raises", {busy = function() error("boom") end}},
	}
	for _, c in ipairs(cases) do
		ann.extensions.mileage_dragLobby = c[2]
		frame(world, ann, 0.25)
		same(card(world, ann).phase, "available", c[1])
	end
	ann.extensions.mileage_dragLobby = nil
	ann.extensions.mileage_spotRace.busy = function() error("boom") end
	frame(world, ann, 0.25)
	same(card(world, ann).phase, "available", "a spot race busy that raises")
end)

World.test("an invite reaching a busy player shows nothing, and an open invite closes when its player becomes busy", function(world)
	local ann, _, bob = threeNear(world, 2000)
	local lobby = {answer = true}
	function lobby.busy() return lobby.answer end
	bob.extensions.mileage_dragLobby = lobby
	press(world, ann)
	same(#heard(world, bob, "invite"), 1, "the server still sends it")
	same(card(world, bob, "invite"), nil, "no invite card while at a drag strip")
	world:as(bob, function() same(mileage_aiRace.press(), false, "nothing to join") end)
	world:advance(10)
	world:as(ann, function() mileage_streetRace.giveUp() end)
	world:pump()
	untilResult(world, ann, 10)
	world:advance(30)

	lobby.answer = false
	press(world, ann)
	same(card(world, bob, "invite") ~= nil, true, "the next invite shows once Bob is free")
	local sentBefore = sentToServer(world, bob, "mileageAiRace")
	lobby.answer = true
	frame(world, bob, 0.25)
	same(card(world, bob).phase, "inviteClosed", "the invite closes on the scan Bob becomes busy")
	same(sentToServer(world, bob, "mileageAiRace"), sentBefore, "nothing sent to the server")
	world:as(bob, function() same(mileage_aiRace.press(), false, "no invite left to join") end)
end)

World.test("a race spot's set-up hides the card and closing it brings the card back", function(world)
	local ann = annAndCar(world, 2000)
	world:as(ann, function() expect(mileage_spotRace.openSetup("city_race_1"), "set-up opened") end)
	world:advance(1)
	same(card(world, ann).phase, "none", "the set-up is open")
	world:as(ann, function() mileage_spotRace.closeSetup() end)
	world:advance(1)
	same(card(world, ann).phase, "available", "set-up closed")
end)

World.test("signing up to a race event hides the card and the event being cancelled brings it back", function(world)
	local ann = annAndCar(world, 2000)
	world:console("Mileage Event 5 100 1")
	world:advance(1)
	same(card(world, ann).phase, "available", "an event she has not joined")
	local announced
	for _, m in ipairs(world:ui(ann, "MileageEvent")) do announced = m end
	world:as(ann, function() mileage_raceEvents.join(announced.id) end)
	world:pump()
	world:advance(1)
	same(card(world, ann).phase, "none", "signed up")
	world:console("Mileage Event cancel")
	world:advance(1)
	same(card(world, ann).phase, "available", "the event was cancelled")
end)

World.test("the card is checked every 0.25 s and sent on change only", function(world)
	local ann = annAndCar(world, 2000)
	local sent = #world:ui(ann, "MileageAiRace")
	for _ = 1, 16 do frame(world, ann, 0.25) end
	same(#world:ui(ann, "MileageAiRace"), sent, "no new card over 4 s with nothing changed")
	ann.extensions.mileage_dragLobby = {busy = function() return true end}
	frame(world, ann, 0.1)
	same(card(world, ann).phase, "available", "not yet: the next scan is due")
	frame(world, ann, 0.15)
	same(card(world, ann).phase, "none", "hidden on the next 0.25 s scan")
	ann.extensions.mileage_dragLobby = nil
end)
