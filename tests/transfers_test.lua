-- Money between players' careers: the server's data files, transfers taken first and
-- given second with a receipt from each game's finished save, payments through them, and
-- every failure the Plan names (replays, drops, a failed save, a restart, a long absence,
-- 600 newer transfers), each checked against the total money across saves.

local World = dofile("tests/money_world.lua")

-- The plugin's local helpers are upvalues of the global functions that use them.
local function upvalue(fn, name)
	for i = 1, 200 do
		local n, v = debug.getupvalue(fn, i)
		if n == nil then return nil end
		if n == name then return v end
	end
end

-- The table the plugin's money sections share their helpers through.
local function money()
	local Money = upvalue(onInit, "Money")
	assert(type(Money) == "table", "Money not found in onInit")
	return Money
end

local function dataHelpers()
	local Money = money()
	assert(type(Money.readData) == "function" and type(Money.writeData) == "function", "data helpers not found")
	return Money.readData, Money.writeData
end

local DATA = "Resources/Server/Mileage/data/"

-- The id of the n-th transfer the server made: "t<n>-<the server's token>". The token is
-- kept in transfers.json, so there is one once a transfer has been written.
local function tid(world, n)
	return "t" .. n .. "-" .. world:dataFile("transfers.json").server
end

-- A transfer of amount from one player to another, started on the server as payments do.
local function pay(world, from, to, amount)
	-- Past the game's own two-second cooldown between payments.
	world:as(from, function() mileagePlayerPayments.onUpdate(3) end)
	world:as(from, function() mileagePlayerPayments.payPlayer(to.name, amount) end)
	world:pump()
end

local function startTransfer(world, spec)
	local start = money().startTransfer
	local id
	world:serverOutput(function() id = start(spec) end)
	world:pump()
	return id
end

local function waiting(world)
	local data = world:dataFile("transfers.json")
	local n = 0
	for _ in pairs(data and data.transfers or {}) do n = n + 1 end
	return n
end

local function lastLabel(p)
	local entry = p.history[#p.history]
	return entry and entry.label
end

--== data files ===============================================================

World.test("a data file written by the plugin reads back the same after a restart", function(world)
	local readData, writeData = dataHelpers()
	world:serverOutput(function() assert(writeData("sample.json", {count = 3, names = {"Ann", "Bob"}})) end)
	expect(world.disk[DATA .. "sample.json"] ~= nil, "file written")
	same(world.disk[DATA .. "sample.json.tmp"], nil, "temporary file left behind")
	world:restart()
	readData = dataHelpers()
	local value
	world:serverOutput(function() value = readData("sample.json") end)
	same(value.count, 3, "count")
	same(value.names[2], "Bob", "second name")
end)

World.test("a data file is written to a temporary file and renamed into place", function(world)
	local _, writeData = dataHelpers()
	local renamed = {}
	local rename = os.rename
	os.rename = function(from, to) table.insert(renamed, {from, to}); return rename(from, to) end
	world:serverOutput(function() writeData("sample.json", {a = 1}) end)
	same(#renamed, 1, "renames")
	same(renamed[1][1], DATA .. "sample.json.tmp", "renamed from")
	same(renamed[1][2], DATA .. "sample.json", "renamed to")
end)

World.test("a data file is replaced where a rename cannot go over an existing file", function(world)
	local readData, writeData = dataHelpers()
	world.renameFailsOverExisting = true
	world:serverOutput(function()
		writeData("sample.json", {a = 1})
		writeData("sample.json", {a = 2})
	end)
	local value
	world:serverOutput(function() value = readData("sample.json") end)
	same(value.a, 2, "value after the second write")
end)

World.test("a missing data file reads as nothing, and an interrupted write is read from its .tmp", function(world)
	local readData = dataHelpers()
	local value = true
	world:serverOutput(function() value = readData("missing.json") end)
	same(value, nil, "missing file")
	world.disk[DATA .. "half.json.tmp"] = World.encode({kept = true})
	world:serverOutput(function() value = readData("half.json") end)
	same(value and value.kept, true, "value from the temporary file")
end)

World.test("a data file that does not read is kept aside, logged, and never overwritten", function(world)
	world.disk[DATA .. "transfers.json"] = "{not json"
	world:restart()
	local aside = nil
	for path, text in pairs(world.disk) do
		if path:find(DATA .. "transfers.json.unreadable-", 1, true) then aside = text end
	end
	same(aside, "{not json", "the unreadable file, moved aside")
	expect(world:printedMatching("transfers.json could not be read") >= 1, "logged")
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	pay(world, ann, bob, 100)
	same(bob.money, 100, "payments still work")
	expect(world.disk[DATA .. "transfers.json"] ~= "{not json", "a new file in its place")
end)

World.test("a data file that cannot be moved aside is never written over", function(world)
	world.disk[DATA .. "transfers.json"] = "{not json"
	local rename = os.rename
	os.rename = function(from, to)
		if from == DATA .. "transfers.json" then return nil, "denied" end
		return rename(from, to)
	end
	world:restart()
	os.rename = rename
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	pay(world, ann, bob, 100)
	same(world.disk[DATA .. "transfers.json"], "{not json", "the unreadable file")
	same(ann.money, 1000, "nothing taken while transfers cannot be kept")
	expect(world:printedMatching("will not write transfers.json") >= 1, "logged")
end)

--== transfers on the server =================================================

World.test("a transfer takes from the payer first and gives only after the payer's receipt", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	local holdReceipts = true
	world.filter = function(m)
		if holdReceipts and m.name == "mileageReceipt" then return "drop" end
	end
	startTransfer(world, {kind = "payment", from = "Ann", to = "Bob", amount = 300,
		takeLabel = "Paid player: Bob", giveLabel = "Payment from player: Ann"})
	same(#world:received(ann, "rxMileageTake"), 1, "take sent to Ann")
	same(#world:received(bob, "rxMileageGive"), 0, "nothing given before Ann's receipt")
	same(waiting(world), 1, "transfer on disk")
	same(world:dataFile("transfers.json").transfers[tid(world, 1)].state, "taking", "state on disk")
	holdReceipts = false
	world:advance(10)
	same(ann.money, 700, "Ann's money")
	same(bob.money, 300, "Bob's money")
	same(waiting(world), 0, "transfer settled")
	same(#world:received(ann, "rxMileageSettled"), 1, "Ann told it settled")
	same(#world:received(bob, "rxMileageSettled"), 1, "Bob told it settled")
end)

World.test("a receipt from the wrong player, for the wrong step or an unknown id changes nothing", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	world.filter = function(m) if m.name == "mileageReceipt" then return "drop" end end
	startTransfer(world, {kind = "payment", from = "Ann", to = "Bob", amount = 300})
	world.filter = nil
	world:serverOutput(function()
		mileageReceipt(bob.id, World.encode({id = tid(world, 1), done = "taken"}))
		mileageReceipt(ann.id, World.encode({id = tid(world, 1), done = "given"}))
		mileageReceipt(ann.id, World.encode({id = "t99", done = "taken"}))
		mileageReceipt(ann.id, "not json")
	end)
	same(world:dataFile("transfers.json").transfers[tid(world, 1)].state, "taking", "still taking")
	same(#world:received(bob, "rxMileageGive"), 0, "nothing given")
end)

World.test("a transfer from the server gives at once; one to the server ends once taken", function(world)
	local ann = world:join("Ann", 1000)
	startTransfer(world, {kind = "prize", from = "server", to = "Ann", amount = 500, giveLabel = "Prize"})
	same(ann.money, 1500, "prize given")
	startTransfer(world, {kind = "stake", from = "Ann", to = "server", amount = 200, takeLabel = "Stake"})
	same(ann.money, 1300, "stake taken")
	same(waiting(world), 0, "both settled")
end)

World.test("a step waiting on an absent player goes when their career starts, even after a restart", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	world:leave(bob)
	startTransfer(world, {kind = "payment", from = "Ann", to = "Bob", amount = 400})
	same(ann.money, 600, "taken from Ann")
	same(world:dataFile("transfers.json").transfers[tid(world, 1)].state, "giving", "waiting to give")
	world:advance(30)
	world:restart()
	world:advance(30)
	same(bob.savedMoney, 0, "Bob has nothing while away")
	world:rejoin(bob)
	same(bob.money, 400, "given on Bob's career start")
	same(waiting(world), 0, "settled")
end)

World.test("a step with no receipt is sent again every 10 seconds while the player is on", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	world.filter = function(m) if m.event == "rxMileageTake" then return "drop" end end
	startTransfer(world, {kind = "payment", from = "Ann", to = "Bob", amount = 50})
	world:advance(9)
	same(#world.dropped, 1, "one take before 10 s")
	world:advance(1)
	same(#world.dropped, 2, "sent again at 10 s")
	world.filter = nil
	world:advance(10)
	same(bob.money, 50, "given after the resend")
end)

World.test("Mileage Transfers lists what waits, with its age, amount and player", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	world:leave(bob)
	startTransfer(world, {kind = "payment", from = "Ann", to = "Bob", amount = 400})
	local lines = world:console("Mileage Transfers")
	same(countLines(lines, "Transfers waiting: 1"), 1, "count line")
	same(countLines(lines, tid(world, 1) .. " (payment, $400 from Ann to Bob)"), 1, "transfer line")
	same(countLines(lines, "waiting to give to Bob"), 1, "who it waits on")
end)

World.test("a transfer waiting more than a minute is logged once", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	world:leave(bob)
	local clock = os.time
	local now = clock()
	os.time = function() return now end
	startTransfer(world, {kind = "payment", from = "Ann", to = "Bob", amount = 400})
	now = now + 61
	world:advance(3)
	os.time = clock
	same(world:printedMatching("has waited more than a minute for Bob"), 1, "logged once")
end)

--== the game's receipts ======================================================

World.test("a game sends its receipt only after the save holding the change finished", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	ann.saveMode = "later"
	startTransfer(world, {kind = "payment", from = "Ann", to = "Bob", amount = 100})
	same(ann.money, 900, "taken in memory")
	same(#world:received(bob, "rxMileageGive"), 0, "no give before Ann's save finished")
	local receipts = World.decode(ann.staged[ann.savePath .. "/career/mileage_receipts.json"])
	same(receipts.applied[tid(world, 1)], "taken", "id written into the same save")
	world:finishSaves(ann)
	same(bob.money, 100, "given once Ann's save finished")
end)

World.test("a resent step the game already applied is answered again without applying it", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	world.filter = function(m) if m.name == "mileageReceipt" and m.from == ann.id then return "drop" end end
	startTransfer(world, {kind = "payment", from = "Ann", to = "Bob", amount = 100})
	world:advance(25)
	same(ann.money, 900, "taken once over three sends")
	world.filter = nil
	world:advance(10)
	same(ann.money, 900, "still taken once")
	same(bob.money, 100, "given once")
end)

World.test("a take the career cannot afford is refused and nothing moves", function(world)
	local ann, bob = world:join("Ann", 50), world:join("Bob", 0)
	startTransfer(world, {kind = "payment", from = "Ann", to = "Bob", amount = 100})
	same(ann.money, 50, "Ann unchanged")
	same(bob.money, 0, "Bob unchanged")
	same(waiting(world), 0, "transfer ended")
	expect(world:printedMatching("refused: Ann does not have the money") == 1, "refusal logged")
end)

World.test("a step that arrives while no career runs is ignored until it does", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	world:hook(bob, "onCareerActive", false)
	startTransfer(world, {kind = "prize", from = "server", to = "Bob", amount = 10})
	same(bob.money, 0, "nothing applied outside a career")
	world:hook(bob, "onCareerActive", true)
	world:advance(10)
	same(bob.money, 10, "applied on the resend")
end)

World.test("a game reads its receipts back from the save and forgets them only once settled", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	world.filter = function(m) if m.event == "rxMileageSettled" then return "drop" end end
	startTransfer(world, {kind = "payment", from = "Ann", to = "Bob", amount = 100})
	world.filter = nil
	world:leave(ann)
	world:rejoin(ann)
	-- The same take again: the save still holds its id, so it is answered, not applied.
	world:as(ann, ann.handlers.rxMileageTake, World.encode({id = tid(world, 1), amount = 100, label = "x"}))
	same(ann.money, 900, "not taken again")
	world:as(ann, ann.handlers.rxMileageSettled, World.encode({ids = {tid(world, 1)}}))
	world:as(ann, function() career_saveSystem.saveCurrent() end)
	local receipts = World.decode(ann.files[ann.savePath .. "/career/mileage_receipts.json"])
	same(receipts.applied[tid(world, 1)], nil, "forgotten after settled")
end)

--== payments =================================================================

World.test("a payment moves exactly the amount typed, labelled on both sides", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	pay(world, ann, bob, 250)
	same(ann.money, 750, "Ann's money")
	same(bob.money, 250, "Bob's money")
	same(lastLabel(ann), "Paid player: Bob", "Ann's history")
	same(lastLabel(bob), "Payment from player: Ann", "Bob's history")
	same(ann.savedMoney + bob.savedMoney, 1000, "total across saves")
end)

World.test("a payment over the limits, not whole, to yourself or an absent player moves nothing", function(world)
	local ann, bob = world:join("Ann", 1000000), world:join("Bob", 0)
	local function tries(target, amount)
		world:serverOutput(function()
			payPlayer(ann.id, World.encode({money = amount, target_player_id = target, target_player_name = "x"}))
		end)
		world:pump()
	end
	tries(bob.id, 200001)
	tries(bob.id, 10.5)
	tries(bob.id, -5)
	tries(ann.id, 10)
	tries(42, 10)
	same(ann.money, 1000000, "Ann unchanged")
	same(#world:received(ann, "rxBounce"), 5, "each bounced")
	same(waiting(world), 0, "no transfer")
end)

World.test("payments switched off are denied with the existing message", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	world:setConfig("server", "allowTransactions", "false")
	pay(world, ann, bob, 10)
	same(#world:received(ann, "rxDeny"), 1, "denied")
	same(ann.money, 1000, "nothing taken")
end)

World.test("a payer who no longer has the money is told and nothing moves", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	-- The game checks the balance before sending; the money goes before the take arrives.
	world.filter = function(m)
		if m.event == "rxMileageTake" then ann.money = 10 end
	end
	pay(world, ann, bob, 500)
	same(bob.money, 0, "nothing given")
	same(ann.money, 10, "nothing taken")
	local bounced = world:received(ann, "rxBounce")
	same(#bounced, 1, "bounced")
	same(bounced[1].why, "money", "why")
	local toasts = world:ui(ann, "toastrMsg")
	expect(toasts[#toasts].msg:find("no longer had the money", 1, true), "message shown")
end)

World.test("the payment UI refuses an amount that is not a whole number above zero", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	for _, amount in ipairs({"abc", 0, -10, 2.5}) do pay(world, ann, bob, amount) end
	same(#world:received(ann, "rxMileageTake"), 0, "nothing sent")
	same(#world:ui(ann, "toastrMsg"), 4, "each said why")
end)

--== failures =================================================================

local function threeWithPayments(world)
	local ann, bob, cat = world:join("Ann", 10000), world:join("Bob", 10000), world:join("Cat", 10000)
	return ann, bob, cat
end

local function payAround(world, ann, bob, cat)
	pay(world, ann, bob, 1000)
	pay(world, bob, cat, 700)
	pay(world, cat, ann, 300)
end

local function expectSettled(world, ann, bob, cat)
	world:advance(40)
	same(ann.money, 9300, "Ann")
	same(bob.money, 10300, "Bob")
	same(cat.money, 10400, "Cat")
	same(world:savedTotal(), 30000, "total across saves")
	same(waiting(world), 0, "nothing waiting")
end

World.test("every message delivered twice still moves each payment once", function(world)
	local ann, bob, cat = threeWithPayments(world)
	world.filter = function(m)
		if m.name == "mileageReceipt" or m.event == "rxMileageTake" or m.event == "rxMileageGive"
				or m.event == "rxMileageSettled" then return "twice" end
	end
	payAround(world, ann, bob, cat)
	expectSettled(world, ann, bob, cat)
end)

World.test("every message lost once still moves each payment once", function(world)
	local ann, bob, cat = threeWithPayments(world)
	local seen = {}
	world.filter = function(m)
		if m.name == "mileageReceipt" or m.event == "rxMileageTake" or m.event == "rxMileageGive" then
			local key = (m.name or m.event) .. (m.data or "") .. tostring(m.from or m.target)
			if not seen[key] then seen[key] = true; return "drop" end
		end
	end
	payAround(world, ann, bob, cat)
	expectSettled(world, ann, bob, cat)
end)

World.test("a failed save sends no receipt; the resend saves again and moves it once", function(world)
	local ann, bob, cat = threeWithPayments(world)
	ann.saveMode = "fail"
	payAround(world, ann, bob, cat)
	world:advance(15)
	same(bob.money, 9300, "Bob not yet paid by Ann")
	ann.saveMode = nil
	expectSettled(world, ann, bob, cat)
end)

World.test("a crash before the save finished loses the change and its id together; it is redone once", function(world)
	local ann, bob, cat = threeWithPayments(world)
	ann.saveMode = "later"
	pay(world, ann, bob, 1000)
	same(ann.money, 9000, "taken in memory")
	world:leave(ann, {crash = true})
	ann.saveMode = nil
	world:rejoin(ann)
	same(ann.money, 9000, "taken again from the save, once")
	pay(world, bob, cat, 700)
	pay(world, cat, ann, 300)
	expectSettled(world, ann, bob, cat)
end)

World.test("a server restart between take and give finishes the payment once", function(world)
	local ann, bob, cat = threeWithPayments(world)
	world.filter = function(m) if m.event == "rxMileageGive" then return "drop" end end
	payAround(world, ann, bob, cat)
	world.filter = nil
	world:restart()
	expectSettled(world, ann, bob, cat)
end)

World.test("a receiver away for a long time is paid once when they come back", function(world)
	local ann, bob, cat = threeWithPayments(world)
	-- Bob's game drops just as the payment is under way.
	world.filter = function(m) if m.event == "rxMileageGive" and m.target == bob.id then return "drop" end end
	pay(world, ann, bob, 1000)
	world.filter = nil
	world:leave(bob)
	world:restart()
	world:advance(3600)
	world:rejoin(bob)
	pay(world, bob, cat, 700)
	pay(world, cat, ann, 300)
	expectSettled(world, ann, bob, cat)
end)

--== ids that cannot meet across servers, and writes that fail ====================

World.test("two servers never make the same transfer id, and a server keeps its token across restarts", function(world)
	local ann = world:join("Ann", 1000)
	startTransfer(world, {kind = "prize", from = "server", to = "Ann", amount = 5})
	local first = world:dataFile("transfers.json").server
	expect(first:match("^%x+$"), "a hex token")
	world:restart()
	startTransfer(world, {kind = "prize", from = "server", to = "Ann", amount = 5})
	same(world:dataFile("transfers.json").server, first, "same token after a restart")
	same(world:dataFile("transfers.json").seq, 2, "the count goes on")
	local other = World.new()
	other:join("Ann", 1000)
	startTransfer(other, {kind = "prize", from = "server", to = "Ann", amount = 5})
	expect(other:dataFile("transfers.json").server ~= first, "another server, another token")
end)

World.test("an id another server applied, kept in the player's save, does not hide this server's transfer",
		function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	-- Ann's save, played on another server first, already holds that server's "t1".
	ann.files[ann.savePath .. "/career/mileage_receipts.json"] = World.encode({applied = {["t1-0badcafe"] = "taken"}})
	world:leave(ann)
	world:rejoin(ann)
	pay(world, ann, bob, 250)
	same(ann.money, 750, "Ann's $250 was taken")
	same(bob.money, 250, "Bob's $250 was given")
	same(world:savedTotal(), 1000, "total across saves")
end)

World.test("a transfer whose removal cannot be written is not announced as settled, and is not applied twice",
		function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	world.filter = function(m)
		if m.name == "mileageReceipt" and m.data:find("given", 1, true) then world.failWrites = "transfers.json" end
	end
	pay(world, ann, bob, 100)
	same(bob.money, 100, "given")
	same(#world:received(bob, "rxMileageSettled"), 0, "Bob not told to forget the id")
	same(#world:received(ann, "rxMileageSettled"), 0, "Ann not told to forget the id")
	same(world:dataFile("transfers.json").transfers[tid(world, 1)].state, "giving", "still on disk as giving")
	world.filter = nil
	world.failWrites = nil
	world:restart()
	world:advance(15)
	same(bob.money, 100, "applied once, not again after the restart")
	same(ann.money, 900, "Ann")
	same(waiting(world), 0, "settled now")
	same(#world:received(bob, "rxMileageSettled") > 0, true, "told once it is on disk")
end)

World.test("the same failed write, with no restart, is retried and settled", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 0)
	world.filter = function(m)
		if m.name == "mileageReceipt" and m.data:find("given", 1, true) then world.failWrites = "transfers.json" end
	end
	pay(world, ann, bob, 100)
	world.filter = nil
	world:advance(12)
	same(waiting(world), 1, "still waiting while writes fail")
	world.failWrites = nil
	world:advance(25)
	same(waiting(world), 0, "settled once it can be written")
	same(bob.money, 100, "Bob paid once")
	same(world:savedTotal(), 1000, "total across saves")
end)

World.test("an unreadable race record keeps stakes on the server instead of losing them", function(world)
	local ann, bob = world:join("Ann", 10000), world:join("Bob", 10000)
	ann.car.pos, bob.car.pos = {x = 0, y = 0, z = 0}, {x = 300, y = 900, z = 0}
	ann.route = {x = 0, y = 2400, z = 0}
	world:as(ann, function() mileage_offers.race("Bob", 1000) end)
	world:pump()
	local offers = world:ui(bob, "MileageOffer")
	-- The race record cannot be written from the moment the stake receipts arrive.
	world.filter = function(m)
		if m.name == "mileageReceipt" then world.failWrites = "races.json" end
		if m.name == "mileageRaceReport" then return "drop" end
	end
	world:as(bob, function() mileage_offers.answer(offers[1].id, true) end)
	world:pump()
	same(ann.savedMoney + bob.savedMoney, 18000, "both stakes taken from the games")
	same(world:dataFile("races.json").races.r1.held.Ann, nil, "no stake recorded as held")
	world.filter = nil
	world.failWrites = nil
	world:restart()
	world:advance(30)
	same(ann.money, 10000, "Ann's stake came back")
	same(bob.money, 10000, "Bob's stake came back")
	same(world:savedTotal(), 20000, "total across saves")
	same(next(world:dataFile("races.json").races), nil, "race record gone")
end)

World.test("a decision that cannot be written is not paid out, and a restart then returns the stakes",
		function(world)
	local ann, bob = world:join("Ann", 10000), world:join("Bob", 10000)
	ann.car.pos, bob.car.pos = {x = 0, y = 0, z = 0}, {x = 300, y = 900, z = 0}
	ann.route = {x = 0, y = 2400, z = 0}
	world:as(ann, function() mileage_offers.race("Bob", 1000) end)
	world:pump()
	local offers = world:ui(bob, "MileageOffer")
	world:as(bob, function() mileage_offers.answer(offers[1].id, true) end)
	world:pump()
	world:advance(30)
	world.failWrites = "races.json"
	world:drive(ann, 0, 2400)
	world:advance(10)
	same(ann.money, 9000, "no payout while the decision is not on disk")
	same(bob.money, 9000, "Bob")
	world:restart()
	world.failWrites = nil
	world:advance(30)
	same(ann.money, 10000, "after the restart the undecided race returned the stakes")
	same(bob.money, 10000, "Bob")
	same(world:savedTotal(), 20000, "total across saves")
end)

World.test("a decision that fails to write once is paid when it can be written", function(world)
	local ann, bob = world:join("Ann", 10000), world:join("Bob", 10000)
	ann.car.pos, bob.car.pos = {x = 0, y = 0, z = 0}, {x = 300, y = 900, z = 0}
	ann.route = {x = 0, y = 2400, z = 0}
	world:as(ann, function() mileage_offers.race("Bob", 1000) end)
	world:pump()
	local offers = world:ui(bob, "MileageOffer")
	world:as(bob, function() mileage_offers.answer(offers[1].id, true) end)
	world:pump()
	world:advance(30)
	world.failWrites = "races.json"
	world:drive(ann, 0, 2400)
	world:advance(8)
	same(ann.money, 9000, "not paid yet")
	world.failWrites = nil
	world:advance(15)
	same(ann.money, 11000, "paid once it is on disk")
	same(bob.money, 9000, "Bob")
	same(world:savedTotal(), 20000, "total across saves")
end)

World.test("an unacknowledged transfer resent after 600 newer ones is still applied once", function(world)
	local ann, bob = world:join("Ann", 100000), world:join("Bob", 0)
	local holding = true
	world.filter = function(m)
		if holding and m.name == "mileageReceipt" and m.data:find('"t1-', 1, true) then return "drop" end
	end
	startTransfer(world, {kind = "payment", from = "Ann", to = "Bob", amount = 7})
	for _ = 1, 600 do
		startTransfer(world, {kind = "prize", from = "server", to = "Ann", amount = 1})
	end
	holding = false
	world:advance(10)
	same(ann.money, 100000 - 7 + 600, "Ann")
	same(bob.money, 7, "Bob")
	same(waiting(world), 0, "nothing waiting")
end)
