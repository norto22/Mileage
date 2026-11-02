-- Resources/Server/Mileage/mileage.lua: every message the server sends is counted by
-- feature, and `Mileage Stats` prints what each part of Mileage received and sent in
-- the last 60 seconds and since the server started.

local SOURCE = "Resources/Server/Mileage/mileage.lua"

--== a stand-in BeamMP server ================================================

-- Payloads travel as Lua table text, read back with load, like BeamMP's JSON.
local function encode(v)
	if type(v) == "table" then
		local parts = {}
		for k, val in pairs(v) do table.insert(parts, "[" .. encode(k) .. "]=" .. encode(val)) end
		table.sort(parts)
		return "{" .. table.concat(parts, ",") .. "}"
	elseif type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

-- Reads that text back, and the flat JSON the damage messages use.
local function decode(text)
	text = tostring(text)
	if text:sub(1, 2) == '{"' then
		text = text:gsub("%[", "{"):gsub("%]", "}"):gsub('"([%w_]+)"%s*:', '["%1"]=')
	end
	local chunk = (loadstring or load)("return " .. text)
	if not chunk then error("does not decode") end
	return chunk()
end

local server

-- The plugin's data files (Resources/Server/Mileage/data/) are kept in memory; every
-- other path is the real file system.
local realOpen, realRename = io.open, os.rename
local function isData(path) return type(path) == "string" and path:find("/data/", 1, true) ~= nil end
io.open = function(path, mode)
	if not isData(path) then return realOpen(path, mode) end
	if (mode or "r"):sub(1, 1) == "r" then
		local text = server.files[path]
		if not text then return nil end
		return {read = function() return text end, close = function() end}
	end
	local parts = {}
	return {write = function(self, data) table.insert(parts, data); return self end,
		close = function() server.files[path] = table.concat(parts) end}
end
os.rename = function(from, to)
	if not isData(from) then return realRename(from, to) end
	server.files[to], server.files[from] = server.files[from], nil
	return true
end

local function newServer(playerIds)
	server = {now = 0, sent = {}, notes = {}, printed = {}, players = {}, files = {}}
	FS = {Exists = function() return true end, CreateDirectory = function() end}
	for _, id in ipairs(playerIds or {0, 1, 2}) do server.players[id] = "player" .. id end
	Util = {JsonEncode = encode, JsonDecode = decode}
	MP = {
		CreateTimer = function() return {GetCurrent = function() return server.now end, Start = function() end} end,
		GetPlayers = function()
			local copy = {}
			for id, name in pairs(server.players) do copy[id] = name end
			return copy
		end,
		IsPlayerConnected = function(id) return server.players[id] ~= nil end,
		GetPlayerName = function(id) return server.players[id] end,
		TriggerClientEvent = function(target, event, data)
			table.insert(server.sent, {target = target, event = event, data = data})
		end,
		SendNotification = function(target, text) table.insert(server.notes, {target = target, text = text}) end,
		DropPlayer = function() end,
	}
	local realPrint = print
	print = function() end
	dofile(SOURCE)
	print = realPrint
	Config = {server = {allowTransactions = true, sessionSendingMax = 100000, sessionReceiveMax = 200000,
		shortWindowMax = 1000, longWindowMax = 10000, shortWindowSeconds = 30, longWindowSeconds = 300},
		client = {roadTrafficEnabled = true, roadTrafficAmount = 6, parkedTrafficEnabled = true,
			parkedTrafficAmount = 8}}
	for id in pairs(server.players) do onPlayerJoinHandler(id) end
	return server
end

-- What Stats prints, one string per line.
local function statsLines(arguments)
	server.printed = {}
	local realPrint = print
	print = function(line) table.insert(server.printed, tostring(line)) end
	local ok, err = pcall(Stats, arguments or {})
	print = realPrint
	if not ok then error(err, 0) end
	return server.printed
end

-- The numbers on a feature's row of the Stats table: the last 60 s (received, sent,
-- recipients, bytes) then the same since start.
local function row(lines, feature)
	for _, line in ipairs(lines) do
		local name, rest = line:match("^%s*(%S+)%s+(%d.*)$")
		if name == feature then
			local numbers = {}
			for n in rest:gmatch("%d+") do table.insert(numbers, tonumber(n)) end
			return {
				window = {received = numbers[1], sent = numbers[2], to = numbers[3], bytes = numbers[4]},
				total = {received = numbers[5], sent = numbers[6], to = numbers[7], bytes = numbers[8]},
			}
		end
	end
	return nil
end

local function bytesSent(event)
	local n = 0
	for _, m in ipairs(server.sent) do
		if m.event == event then
			local recipients = 1
			if m.target == -1 then
				recipients = 0
				for _ in pairs(server.players) do recipients = recipients + 1 end
			end
			n = n + #m.data * recipients
		end
	end
	return n
end

--== counting ================================================================

test("a car spawn is one car-state message to every player, its bytes counted once per player", function()
	newServer({0, 1, 2})
	onVehicleSpawnHandler(0, 0, "")
	local r = row(statsLines(), "carStates")
	expect(r, "no carStates row")
	same(r.window.sent, 1, "messages sent")
	same(r.window.to, 3, "players reached")
	same(r.window.bytes, bytesSent("rxCareerVehSync"), "bytes")
	same(bytesSent("rxCareerVehSync"), #server.sent[1].data * 3, "a broadcast's bytes")
	same(r.total.sent, 1, "messages since start")
end)

test("a damage message from its owner is counted as received once and sent to each other player", function()
	newServer({0, 1, 2})
	local message = '{"v":"0-0","c":0,"b":[1,1.0000,0,0.000],"n":[]}'
	careerDamage(0, message)
	local r = row(statsLines(), "damage")
	same(r.window.received, 1, "messages received")
	same(r.window.sent, 2, "messages sent")
	same(r.window.to, 2, "players reached")
	same(r.window.bytes, 2 * #message, "bytes sent")
end)

test("a payment, a traffic light tick, an alive message and notifications land in their own rows", function()
	newServer({0, 1})
	careerSyncRequested(0, "")
	payPlayer(0, encode({money = 10, target_player_id = 1}))
	trafficLightTimer()
	tick()
	tick()
	speedTrap(0, encode({triggerName = "speedTrap1", playerSpeed = 30, speedLimit = 20, vehicleModel = "Covet",
		licensePlate = "ABC"}))
	local lines = statsLines()
	same(row(lines, "payments").window.received, 1, "payments received")
	same(row(lines, "payments").window.sent, 0, "nothing sent for the payment itself")
	same(row(lines, "transfers").window.sent, 1, "the payer asked to take it")
	same(row(lines, "trafficLights").window.sent, 2, "traffic light messages, one per player")
	same(row(lines, "alive").window.sent, 2, "alive messages, one per player")
	same(row(lines, "notifications").window.received, 1, "speed traps received")
	same(row(lines, "notifications").window.sent, 5, "notification lines")
	same(row(lines, "notifications").window.to, 10, "notification lines times players")
end)

test("every feature of the readout has a row, even with nothing sent", function()
	newServer({0})
	local lines = statsLines()
	for _, feature in ipairs({"damage", "carStates", "trafficMarks", "trafficShare", "paint", "prefabs", "drag",
			"payments", "transfers", "offers", "alive", "trafficLights", "notifications", "config"}) do
		local r = row(lines, feature)
		expect(r, "no row for " .. feature)
		same(r.total.sent, 0, feature .. " messages")
	end
end)

test("the server plugin sends nothing except through its counting helpers", function()
	local file = assert(io.open(SOURCE, "r"))
	local text = file:read("*a")
	file:close()
	local direct = 0
	for line in text:gmatch("[^\n]+") do
		if (line:find("MP.TriggerClientEvent", 1, true) or line:find("MP.SendNotification", 1, true))
				and not line:find("^%s*%-%-") then
			direct = direct + 1
		end
	end
	-- One TriggerClientEvent in send and one SendNotification in notify.
	same(direct, 2, "direct sends in the plugin")
end)

-- Lua allows 200 local names in a function at once, the plugin's main chunk included,
-- and the plugin must stay one file for the updater. Its sections keep their names in
-- blocks; this keeps room for more.
test("the server plugin's main chunk leaves room for 40 more local names", function()
	local file = assert(io.open(SOURCE, "r"))
	local text = file:read("*a")
	file:close()
	local names = {}
	for i = 1, 40 do names[i] = "spare" .. i end
	local chunk, err = (loadstring or load)("local " .. table.concat(names, ", ") .. "\n" .. text)
	expect(chunk ~= nil, "plugin with 40 more locals does not load: " .. tostring(err))
end)

--== the readout =============================================================

test("Stats prints the 60 s window and the since-start totals, and older counts leave the window only", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	server.now = 30
	onVehicleSpawnHandler(1, 0, "")
	server.now = 75
	local r = row(statsLines(), "carStates")
	same(r.window.sent, 1, "messages in the last 60 s")
	same(r.total.sent, 2, "messages since start")
	server.now = 200
	r = row(statsLines(), "carStates")
	same(r.window.sent, 0, "messages in the last 60 s much later")
	same(r.total.sent, 2, "messages since start much later")
end)

test("Stats lists the players and their cars, traffic and parked counted", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	onVehicleSpawnHandler(0, 1, "")
	onVehicleSpawnHandler(1, 0, "")
	careerVehicleTrafficMarks(0, encode({["0-1"] = true}))
	local lines = statsLines()
	local players, cars = nil, nil
	for _, line in ipairs(lines) do
		players = players or line:match("^Players: (%d+)")
		cars = cars or line:match("^Cars: (%d+)")
	end
	same(tonumber(players), 2, "players line")
	same(tonumber(cars), 3, "cars line")
	same(countLines(lines, "player0 (0): 2 cars (2 shown), 1 traffic or parked (1 shown)"), 1, "player 0's line")
	same(countLines(lines, "player1 (1): 1 cars (1 shown), 0 traffic or parked (0 shown)"), 1, "player 1's line")
end)

-- Players who were on before the server filled keep their extra traffic, hidden; the
-- shown count is what the total holds.
test("Stats counts hidden cars apart from shown ones", function()
	newServer({0})
	for vid = 0, 2 do onVehicleSpawnHandler(0, vid, "") end
	careerVehicleTrafficMarks(0, encode({["0-1"] = true, ["0-2"] = true}))
	careerVehicleActiveHandler(0, encode({serverVehicleID = "0-2", active = false}))
	local lines = statsLines()
	same(countLines(lines, "Cars: 3 (2 shown), 2 of them traffic or parked (1 shown)"), 1, "cars line")
	same(countLines(lines, "player0 (0): 3 cars (2 shown), 2 traffic or parked (1 shown)"), 1, "player 0's line")
end)

test("Stats reset starts the since-start counts again", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	local lines = statsLines({"reset"})
	same(countLines(lines, "[Mileage] Stats reset"), 1, "reset line")
	local r = row(statsLines(), "carStates")
	same(r.total.sent, 0, "messages since the reset")
	same(r.window.sent, 0, "messages in the window after the reset")
end)

test("Stats with an unknown argument prints its usage", function()
	newServer({0})
	same(countLines(statsLines({"bogus"}), "Usage: Mileage Stats [reset]"), 1, "usage line")
end)

test("Help lists the Stats command", function()
	newServer({0})
	server.printed = {}
	local realPrint = print
	print = function(line) table.insert(server.printed, tostring(line)) end
	Help({})
	print = realPrint
	same(countLines(server.printed, "Mileage Stats"), 1, "Stats in the help")
	for _, command in ipairs({"Mileage Transfers", "Mileage Leaderboard [reset]", "Mileage Event <minutes>"}) do
		same(countLines(server.printed, command), 1, command .. " in the help")
	end
end)

-- What one console line prints, with BeamMP's local event calling the named handler.
local function consoleLines(line)
	server.printed = {}
	MP.TriggerLocalEvent = function(command, arguments) _G[command](arguments) end
	local realPrint = print
	print = function(text) table.insert(server.printed, tostring(text)) end
	local ok, err = pcall(onConsoleInputHandler, line)
	print = realPrint
	if not ok then error(err, 0) end
	return server.printed
end

test("the console command Mileage Help prints Mileage's help", function()
	newServer({0})
	local lines = consoleLines("Mileage Help")
	same(countLines(lines, "Mileage Help "), 1, "Help line")
	same(countLines(lines, "Mileage SetConfig "), 1, "SetConfig line")
end)

test("a console line with another prefix runs no Mileage command", function()
	newServer({0})
	same(#consoleLines("Foo Help"), 0, "lines printed")
	same(#consoleLines("Mileagex Help"), 0, "lines printed for a near miss")
end)

-- BeamMP drops a leaving player from its list before the plugin hears of the leave.
test("Stats prints while a car's owner is no longer in the player list", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	onVehicleSpawnHandler(1, 0, "")
	server.players[1] = nil
	local lines = statsLines()
	same(countLines(lines, "Players: 1"), 1, "players line")
	same(countLines(lines, "player0 (0): 1 cars (1 shown), 0 traffic or parked (0 shown)"), 1, "player 0's line")
end)
