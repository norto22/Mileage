-- Offers between players: money requests shown only to their target, paid through a
-- transfer within the payer's limits, and every way an offer is refused or closes. The
-- race challenges built on the same offers are in street_race_test.lua.

local World = dofile("tests/money_world.lua")

local function three(world)
	return world:join("Ann", 10000), world:join("Bob", 10000), world:join("Cat", 10000)
end

local function request(world, from, to, amount)
	world:as(from, function() mileage_offers.request(to.name, amount) end)
	world:pump()
end

-- The open offer p's game shows, or nil.
local function shownOffer(world, p)
	local closed = {}
	for _, c in ipairs(world:ui(p, "MileageOfferClosed")) do closed[c.id] = true end
	local last = nil
	for _, offer in ipairs(world:ui(p, "MileageOffer")) do
		if not closed[offer.id] then last = offer end
	end
	return last
end

local function answer(world, p, accept)
	local offer = assert(shownOffer(world, p), "no offer shown to " .. p.name)
	world:as(p, function() mileage_offers.answer(offer.id, accept) end)
	world:pump()
	world:advance(2)
end

local function lastToast(p)
	local toasts = {}
	for _, entry in ipairs(p.ui) do if entry.name == "toastrMsg" then table.insert(toasts, entry.data) end end
	return toasts[#toasts]
end

World.test("a request shows only on its target's game, and accepting pays it", function(world)
	local ann, bob, cat = three(world)
	request(world, ann, bob, 3500)
	local offer = shownOffer(world, bob)
	expect(offer, "shown to Bob")
	same(offer.kind, "request", "kind")
	same(offer.from, "Ann", "from")
	same(offer.amount, 3500, "amount")
	same(shownOffer(world, cat), nil, "not shown to Cat")
	same(shownOffer(world, ann), nil, "not shown to Ann")
	answer(world, bob, true)
	same(bob.money, 6500, "Bob paid")
	same(ann.money, 13500, "Ann received")
	same(cat.money, 10000, "Cat unchanged")
	same(world:savedTotal(), 30000, "total across saves")
	local told = false
	for _, entry in ipairs(world:ui(ann, "toastrMsg")) do
		if entry.msg:find("Bob accepted your request for $3500", 1, true) then told = true end
	end
	expect(told, "Ann told")
end)

World.test("declining a request moves nothing and tells the requester", function(world)
	local ann, bob = three(world)
	request(world, ann, bob, 100)
	answer(world, bob, false)
	same(bob.money, 10000, "Bob")
	same(ann.money, 10000, "Ann")
	expect(lastToast(ann).msg:find("Bob declined", 1, true), "Ann told")
end)

World.test("an accepted request counts against the payer's sending limits", function(world)
	local ann, bob = three(world)
	request(world, ann, bob, 900)
	answer(world, bob, true)
	request(world, ann, bob, 900)
	answer(world, bob, true)
	same(bob.money, 9100, "only the first was paid: the short window allows $1000")
	same(#world:ui(bob, "MileageOfferClosed"), 2, "both closed on Bob's game")
	expect(lastToast(ann).msg:find("sending limits", 1, true), "Ann told why")
end)

World.test("a request to yourself, an absent player, for a bad amount or a second one is refused", function(world)
	local ann, bob = three(world)
	local function refused(target, amount)
		world:serverOutput(function()
			mileageOffer(ann.id, World.encode({kind = "request", to = target, amount = amount}))
		end)
		world:pump()
		local closed = world:received(ann, "rxMileageOfferClosed")
		return closed[#closed]
	end
	same(refused(ann.id, 10).why, "self", "to yourself")
	same(refused(42, 10).why, "absent", "absent")
	same(refused(bob.id, 0).why, "amount", "zero")
	same(refused(bob.id, -5).why, "amount", "negative")
	same(refused(bob.id, 2.5).why, "amount", "not whole")
	same(refused(bob.id, 100001).why, "sendingMax", "above the session limit")
	request(world, ann, bob, 10)
	same(refused(bob.id, 10).why, "open", "a second open request")
	same(#world:ui(bob, "MileageOffer"), 1, "Bob saw only the first")
end)

World.test("requests switched off are refused, and an open one closes", function(world)
	local ann, bob = three(world)
	request(world, ann, bob, 100)
	world:setConfig("server", "allowMoneyRequests", "false")
	world:advance(1)
	local closed = world:ui(bob, "MileageOfferClosed")
	same(closed[#closed].why, "requestsOff", "open request closed")
	request(world, ann, bob, 100)
	expect(lastToast(ann).msg:find("Requests are switched off on this server.", 1, true), "refused with the reason")
	same(#world:ui(bob, "MileageOffer"), 1, "nothing new shown")
end)

World.test("a request with payments switched off is refused", function(world)
	local ann, bob = three(world)
	world:setConfig("server", "allowTransactions", "false")
	world:serverOutput(function() mileageOffer(ann.id, World.encode({kind = "request", to = bob.id, amount = 5})) end)
	world:pump()
	local closed = world:received(ann, "rxMileageOfferClosed")
	same(closed[#closed].why, "paymentsOff", "why")
end)

World.test("an offer closes after 60 seconds without an answer", function(world)
	local ann, bob = three(world)
	request(world, ann, bob, 100)
	world:advance(59)
	same(#world:ui(bob, "MileageOfferClosed"), 0, "open at 59 s")
	world:advance(1)
	local closed = world:ui(bob, "MileageOfferClosed")
	same(closed[1].why, "expired", "closed at 60 s")
	world:as(bob, function() expect(not mileage_offers.answer(closed[1].id, true), "answer after expiry") end)
	same(bob.money, 10000, "nothing paid")
end)

World.test("an offer closes on both games when either player leaves", function(world)
	local ann, bob, cat = three(world)
	request(world, ann, bob, 100)
	request(world, cat, ann, 100)
	world:leave(ann)
	local closed = world:ui(bob, "MileageOfferClosed")
	same(closed[1].why, "left", "Bob's offer closed")
	expect(lastToast(cat).msg:find("The other player left.", 1, true), "Cat told")
end)

World.test("only the target can answer, and only once", function(world)
	local ann, bob, cat = three(world)
	request(world, ann, bob, 100)
	local offer = shownOffer(world, bob)
	world:serverOutput(function()
		mileageOfferAnswer(cat.id, World.encode({id = offer.id, accept = true}))
		mileageOfferAnswer(ann.id, World.encode({id = offer.id, accept = true}))
	end)
	world:pump()
	world:advance(2)
	same(cat.money, 10000, "Cat")
	same(bob.money, 10000, "Bob")
	world:serverOutput(function()
		mileageOfferAnswer(bob.id, World.encode({id = offer.id, accept = true}))
		mileageOfferAnswer(bob.id, World.encode({id = offer.id, accept = true}))
	end)
	world:pump()
	world:advance(2)
	same(bob.money, 9900, "paid once")
end)

World.test("the player list is told why each action is unavailable", function(world)
	local ann = three(world)
	world:setConfig("server", "allowMoneyRequests", "false")
	world:setConfig("server", "allowRacing", "false")
	world:as(ann, function() mileage_offers.actionsFor("Bob") end)
	local actions = world:ui(ann, "MileagePlayerActions")
	local last = actions[#actions]
	same(last.request.ok, false, "request")
	same(last.request.why, "Requests are switched off on this server.", "request why")
	same(last.race.why, "Racing is switched off on this server.", "race why")
	same(last.pay.ok, true, "pay")
	same(last.pay.money, 10000, "money shown for Pay")
end)

World.test("a request with an amount the player list should not send says why and sends nothing", function(world)
	local ann, bob = three(world)
	for _, amount in ipairs({"", "abc", 0, -1, 1.5}) do request(world, ann, bob, amount) end
	request(world, ann, ann, 10)
	same(#world:ui(bob, "MileageOffer"), 0, "nothing shown")
	same(#world:ui(ann, "toastrMsg"), 6, "each said why")
end)

World.test("the server's switches reach every game, and again after SetConfig", function(world)
	local ann = world:join("Ann", 0)
	local first = world:received(ann, "rxMileageFeatures")
	same(first[1].allowMoneyRequests, true, "requests on by default")
	same(first[1].raceStakeMax, 10000, "stake limit")
	world:setConfig("server", "raceStakeMax", "2500")
	local after = world:received(ann, "rxMileageFeatures")
	same(after[#after].raceStakeMax, 2500, "after SetConfig")
	world:setConfig("server", "raceStakeMax", "5000000")
	after = world:received(ann, "rxMileageFeatures")
	same(after[#after].raceStakeMax, 1000000, "out of range read as the nearest allowed")
end)

--== drag race challenges ======================================================

local function dragChallenge(world, from, to, stake)
	local sent
	world:as(from, function() sent = mileage_offers.dragRace(to.name, stake) end)
	world:pump()
	return sent
end

World.test("a drag challenge needs no route and shows the stake, the server's drag prize and the time limit",
		function(world)
	local ann, bob, cat = three(world)
	world:setConfig("server", "dragRacePrize", 3000)
	ann.route = nil
	expect(dragChallenge(world, ann, bob, 500), "sent")
	local offer = shownOffer(world, bob)
	same(offer.kind, "drag", "kind")
	same(offer.from, "Ann", "from")
	same(offer.amount, 500, "stake")
	same(offer.prize, 3000, "drag prize")
	same(offer.minutes, 15, "time limit")
	same(offer.distance, nil, "no distance")
	same(shownOffer(world, cat), nil, "not shown to Cat")
	expect(lastToast(ann).title == "Challenge sent", "Ann told it went")
end)

World.test("a drag challenge with racing off, above the limit or the challenger's money, to yourself or nobody, says why",
		function(world)
	local ann, bob = three(world)
	world:setConfig("server", "raceStakeMax", 2000)
	same(dragChallenge(world, ann, bob, 2001), false, "above the limit")
	expect(lastToast(ann).msg:find("above this server's limit", 1, true), "limit why")
	same(dragChallenge(world, ann, bob, 1.5), false, "not whole")
	same(dragChallenge(world, ann, ann, 10), false, "yourself")
	expect(lastToast(ann).msg:find("You cannot race yourself.", 1, true), "self why")
	ann.money = 100
	same(dragChallenge(world, ann, bob, 500), false, "more than Ann has")
	expect(lastToast(ann).msg:find("do not have the money", 1, true), "money why")
	world:setConfig("server", "allowRacing", "false")
	same(dragChallenge(world, ann, bob, 0), false, "racing off")
	world:serverOutput(function() mileageOffer(ann.id, World.encode({kind = "drag", to = bob.id, amount = 0})) end)
	world:pump()
	local closed = world:received(ann, "rxMileageOfferClosed")
	same(closed[#closed].why, "racingOff", "the server refuses it too")
	world:setConfig("server", "allowRacing", "true")
	world:serverOutput(function() mileageOffer(ann.id, World.encode({kind = "drag", to = 42, amount = 0})) end)
	world:pump()
	closed = world:received(ann, "rxMileageOfferClosed")
	same(closed[#closed].why, "absent", "absent")
	world:serverOutput(function() mileageOffer(ann.id, World.encode({kind = "drag", to = bob.id, amount = 2001})) end)
	world:pump()
	closed = world:received(ann, "rxMileageOfferClosed")
	same(closed[#closed].why, "stakeMax", "the server's limit")
	same(#world:ui(bob, "MileageOffer"), 0, "nothing shown to Bob")
end)

World.test("switching racing off closes an open drag challenge", function(world)
	local ann, bob = three(world)
	dragChallenge(world, ann, bob, 0)
	world:setConfig("server", "allowRacing", "false")
	world:advance(1)
	local closed = world:ui(bob, "MileageOfferClosed")
	same(closed[#closed].why, "racingOff", "closed")
end)

World.test("a drag challenge accepted outside the player's own car, or in a mission, is declined", function(world)
	local ann, bob = three(world)
	dragChallenge(world, ann, bob, 100)
	bob.mission = "delivery"
	answer(world, bob, true)
	same(lastToast(bob).title, "Challenge declined", "Bob told why")
	same(world:ui(ann, "toastrMsg")[#world:ui(ann, "toastrMsg")].msg:find("Bob declined", 1, true) ~= nil, true,
		"Ann told it was declined")
	same(world:savedTotal(), 30000, "no stake taken")
end)

World.test("the player list is told whether a drag race is open, its limit, prize and time", function(world)
	local ann = three(world)
	world:setConfig("server", "dragRacePrize", 750)
	world:as(ann, function() mileage_offers.actionsFor("Bob") end)
	local last = world:ui(ann, "MileagePlayerActions")[#world:ui(ann, "MileagePlayerActions")]
	same(last.drag.ok, true, "open")
	same(last.drag.stakeMax, 10000, "limit")
	same(last.drag.prize, 750, "prize")
	same(last.drag.minutes, 15, "time")
	world:setConfig("server", "allowRacing", "false")
	world:as(ann, function() mileage_offers.actionsFor("Bob") end)
	last = world:ui(ann, "MileagePlayerActions")[#world:ui(ann, "MileagePlayerActions")]
	same(last.drag.ok, false, "closed")
	same(last.drag.why, "Racing is switched off on this server.", "why")
end)
