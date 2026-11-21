-- Resources/Server/Mileage/mileage.lua: car states (rxCareerVehSync) go to every player only
-- when they change, grouped. A game reporting a car hidden or shown as it already is sends
-- nothing on; the state of every car that spawned, was rebuilt, hidden or shown since the last
-- send goes out in one {serverVehicleID: state} message on a 250 ms timer. A car deleted, or
-- whose owner left, before that send is left out. The full list goes only to a player who
-- asks for it, as rxCareerVehList.
--
-- Runs the real plugin with its onInit on a stand-in BeamMP server whose event timers fire
-- as BeamMP's do, on the clock.

local SOURCE = "Resources/Server/Mileage/mileage.lua"

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

local function decode(text)
	local chunk = (loadstring or load)("return " .. tostring(text))
	if not chunk then error("does not decode") end
	return chunk()
end

local server

local function newServer(playerIds)
	server = {now = 0, sent = {}, players = {}, events = {}, timers = {}}
	for _, id in ipairs(playerIds or {0, 1, 2}) do server.players[id] = "player" .. id end
	FS = {Exists = function() return false end, CreateDirectory = function() end}
	Util = {JsonEncode = encode, JsonDecode = decode, JsonPrettify = function(text) return text end}
	MP = {
		CreateTimer = function() return {GetCurrent = function() return server.now end, Start = function() end} end,
		GetPlayers = function()
			local copy = {}
			for id, name in pairs(server.players) do copy[id] = name end
			return copy
		end,
		IsPlayerConnected = function(id) return server.players[id] ~= nil end,
		GetPlayerName = function(id) return server.players[id] end,
		GetOSName = function() return "Linux" end,
		TriggerClientEvent = function(target, event, data)
			table.insert(server.sent, {at = server.now, target = target, event = event, data = data})
		end,
		SendNotification = function() end,
		SendChatMessage = function() end,
		DropPlayer = function() end,
		RegisterEvent = function(event, handler) server.events[event] = handler end,
		CreateEventTimer = function(event, ms) server.timers[event] = {every = ms / 1000, due = ms / 1000} end,
	}
	local realPrint = print
	print = function() end
	dofile(SOURCE)
	-- The settings file: auto update off, everything else the plugin's defaults.
	ReadJson = function() return {server = {autoUpdate = false, autoExit = false}, client = {}} end
	WriteJson = function() return true end
	onInit()
	print = realPrint
	for id in pairs(server.players) do onPlayerJoinHandler(id) end
	return server
end

-- Moves the clock on in 10 ms steps, firing each event timer when it is due.
local function run(seconds)
	local stop = server.now + seconds
	while server.now < stop - 1e-9 do
		server.now = server.now + 0.01
		for event, timer in pairs(server.timers) do
			if server.now >= timer.due - 1e-9 then
				timer.due = timer.due + timer.every
				local handler = _G[server.events[event]]
				local realPrint = print
				print = function() end
				handler()
				print = realPrint
			end
		end
	end
end

-- The car-state messages sent so far, each decoded: {at, target, cars = {sid = state}}.
local function carStates()
	local list = {}
	for _, m in ipairs(server.sent) do
		if m.event == "rxCareerVehSync" then
			table.insert(list, {at = m.at, target = m.target, cars = decode(m.data)})
		end
	end
	return list
end

-- The full car-state lists sent so far (rxCareerVehList, the answer to
-- careerVehSyncRequested), each decoded like carStates.
local function lists()
	local list = {}
	for _, m in ipairs(server.sent) do
		if m.event == "rxCareerVehList" then
			table.insert(list, {at = m.at, target = m.target, cars = decode(m.data)})
		end
	end
	return list
end

local function size(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function clear() server.sent = {} end

local function hide(owner, sid, active)
	careerVehicleActiveHandler(owner, encode({serverVehicleID = sid, active = active}))
end

-- The numbers on a feature's row of `Mileage Stats` for the last 60 s.
local function statsRow(feature)
	local printed = {}
	local realPrint = print
	print = function(line) table.insert(printed, tostring(line)) end
	Stats({})
	print = realPrint
	for _, line in ipairs(printed) do
		local name, rest = line:match("^%s*(%S+)%s+(%d.*)$")
		if name == feature then
			local n = {}
			for x in rest:gmatch("%d+") do table.insert(n, tonumber(x)) end
			return {received = n[1], sent = n[2], to = n[3], bytes = n[4]}
		end
	end
	return nil
end

--== A14: nothing changed, nothing sent =========================================

test("A14: a game reporting a hidden car hidden again sends nothing to anyone", function()
	newServer({0, 1, 2})
	onVehicleSpawnHandler(0, 0, "")
	run(0.5)
	hide(0, "0-0", false)
	run(0.5)
	same(#carStates(), 2, "the spawn and the first hide")
	clear()
	hide(0, "0-0", false)
	hide(0, "0-0", false)
	run(1)
	same(#carStates(), 0, "messages for hides that change nothing")
end)

test("A14: a game reporting a shown car shown sends nothing", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	run(0.5)
	clear()
	hide(0, "0-0", true)
	run(1)
	same(#carStates(), 0, "messages")
end)

test("A14: a report that changes nothing still counts as received", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	run(0.5)
	local before = statsRow("carStates").received
	hide(0, "0-0", true)
	same(statsRow("carStates").received, before + 1, "messages received")
end)

--== A15: ten changes, one message ==============================================

test("A15: ten cars hidden within a quarter second reach every player as one message of ten", function()
	newServer({0, 1, 2})
	for vid = 0, 9 do onVehicleSpawnHandler(0, vid, "") end
	run(0.5)
	clear()
	for vid = 0, 9 do
		hide(0, "0-" .. vid, false)
		run(0.02)
	end
	run(0.3)
	local messages = carStates()
	same(#messages, 1, "messages")
	same(messages[1].target, -1, "sent to")
	same(size(messages[1].cars), 10, "cars in the message")
	for vid = 0, 9 do same(messages[1].cars["0-" .. vid].active, false, "car 0-" .. vid .. " hidden") end
end)

test("A15: ten spawns at once go out as one message, counted once per player in Stats", function()
	newServer({0, 1, 2})
	for vid = 0, 9 do onVehicleSpawnHandler(1, vid, "") end
	run(0.3)
	local messages = carStates()
	same(#messages, 1, "messages")
	same(size(messages[1].cars), 10, "cars in it")
	local r = statsRow("carStates")
	same(r.sent, 1, "messages counted")
	same(r.to, 3, "players reached")
	same(r.bytes, #server.sent[#server.sent].data * 3, "bytes counted")
end)

test("A15: a car hidden then shown inside one window is sent once, as it ends", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	run(0.5)
	clear()
	hide(0, "0-0", false)
	hide(0, "0-0", true)
	run(0.3)
	local messages = carStates()
	same(#messages, 1, "messages")
	same(messages[1].cars["0-0"].active, true, "the state sent")
end)

--== A16: a new car is known within half a second ===============================

test("A16: a new car's state reaches the other games within half a second", function()
	newServer({0, 1})
	run(0.13)
	onVehicleSpawnHandler(0, 0, "")
	local spawnedAt = server.now
	run(0.5)
	local messages = carStates()
	same(#messages, 1, "messages")
	expect(messages[1].at - spawnedAt <= 0.5, "sent after " .. (messages[1].at - spawnedAt) .. " s")
	same(messages[1].cars["0-0"].active, true, "the new car is shown")
end)

test("A16: the car-state timer runs every 250 ms beside the one-second tick", function()
	newServer({0})
	local found
	for event, timer in pairs(server.timers) do
		if event ~= "tick" and event ~= "trafficLightTimer" then found = timer end
	end
	expect(found, "no car-state timer")
	expect(math.abs(found.every - 0.25) < 1e-9, "every " .. tostring(found and found.every) .. " s")
end)

test("a rebuilt car is sent shown even when it was shown, so every copy is switched on", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	run(0.5)
	clear()
	onVehicleEditedHandler(0, 0, "")
	run(0.3)
	local messages = carStates()
	same(#messages, 1, "messages")
	same(messages[1].cars["0-0"].active, true, "the rebuilt car")
end)

--== the awkward cases ===========================================================

test("a car spawned and deleted inside one window is never sent", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	onVehicleSpawnHandler(0, 1, "")
	onVehicleDeletedHandler(0, 0)
	run(0.3)
	local messages = carStates()
	same(#messages, 1, "messages")
	same(messages[1].cars["0-0"], nil, "the deleted car")
	expect(messages[1].cars["0-1"], "the other car is sent")
end)

test("a window holding only a deleted car sends nothing", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	run(0.5)
	clear()
	hide(0, "0-0", false)
	onVehicleDeletedHandler(0, 0)
	run(0.5)
	same(#carStates(), 0, "messages")
end)

test("a player who leaves before the send takes their cars out of it", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	onVehicleSpawnHandler(1, 0, "")
	server.players[1] = nil
	onPlayerDisconnectHandler(1)
	run(0.3)
	local messages = carStates()
	same(#messages, 1, "messages")
	same(messages[1].cars["1-0"], nil, "the leaver's car")
	expect(messages[1].cars["0-0"], "the other player's car")
end)

test("a hide of another player's car is ignored and sends nothing", function()
	newServer({0, 1})
	onVehicleSpawnHandler(1, 0, "")
	run(0.5)
	clear()
	hide(0, "1-0", false)
	run(0.5)
	same(#carStates(), 0, "messages")
end)

test("a hide or show of a car of their own that never spawned keeps no state and sends nothing", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	run(0.5)
	clear()
	for n = 1, 500 do hide(0, "0-" .. n, n % 2 == 0) end
	run(0.5)
	same(#carStates(), 0, "messages for cars that never spawned")
	careerVehSyncRequested(1, "")
	local list = lists()
	same(#list, 1, "the full list")
	same(size(list[1].cars), 1, "cars in the full list: only the one that spawned")
	clear()
	hide(0, "0-0", false)
	run(0.5)
	same(#carStates(), 1, "the car that spawned is still hidden as before")
end)

test("a full list asked for still goes to the asker at once", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	run(0.5)
	clear()
	careerVehSyncRequested(1, "")
	local messages = lists()
	same(#messages, 1, "messages")
	same(messages[1].target, 1, "sent to")
end)

-- #166: a joining game ends its wait for traffic marks on the list alone, so the list
-- has its own event and a batch can never be taken for it.
test("#166: the full list goes as rxCareerVehList to the asker only, never as a batch, and counts as a car-state message", function()
	newServer({0, 1, 2})
	onVehicleSpawnHandler(0, 0, "")
	onVehicleSpawnHandler(2, 0, "")
	run(0.5)
	clear()
	local before = statsRow("carStates")
	careerVehSyncRequested(1, "")
	same(#server.sent, 1, "messages sent for the request")
	local messages = lists()
	same(#messages, 1, "lists")
	same(messages[1].target, 1, "sent to")
	same(size(messages[1].cars), 2, "cars in the list")
	same(#carStates(), 0, "batches sent for the request")
	local r = statsRow("carStates")
	same(r.received, before.received + 1, "requests counted")
	same(r.sent, before.sent + 1, "lists counted")
	same(r.bytes, before.bytes + #server.sent[1].data, "list bytes counted")
	-- A change after the request still goes to everyone as a batch.
	hide(0, "0-0", false)
	run(0.3)
	local batches = carStates()
	same(#batches, 1, "batches after a change")
	same(batches[1].target, -1, "batch sent to")
	same(#lists(), 1, "lists after a change")
end)

-- Rejects a delete that leaves a mark behind (or a pending entry the next spawn cannot
-- replace): BeamMP gives a new car the id of one just deleted.
test("a car deleted and spawned again with the same id inside one window is sent shown", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	run(0.5)
	clear()
	hide(0, "0-0", false)
	onVehicleDeletedHandler(0, 0)
	onVehicleSpawnHandler(0, 0, "")
	run(0.3)
	local messages = carStates()
	same(#messages, 1, "messages")
	same(messages[1].cars["0-0"].active, true, "the new car's state")
end)

-- Rejects a handler that makes a state up for a car already gone (the old `or {}`): a
-- hide that crosses the delete on the wire would bring the deleted car back into every
-- game's list.
test("a hide that arrives after its car was deleted keeps no state and sends nothing", function()
	newServer({0, 1})
	onVehicleSpawnHandler(0, 0, "")
	run(0.5)
	onVehicleDeletedHandler(0, 0)
	clear()
	hide(0, "0-0", false)
	run(0.5)
	same(#carStates(), 0, "messages")
	careerVehSyncRequested(1, "")
	local list = lists()
	same(#list, 1, "the full list")
	same(list[1].cars["0-0"], nil, "the deleted car in the full list")
end)

test("nothing changed, nothing sent: the timer alone sends no car states", function()
	newServer({0, 1})
	run(3)
	same(#carStates(), 0, "messages")
end)
