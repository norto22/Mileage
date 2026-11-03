-- #49: mileagePerPartPaint.lua holds a part paint received for another player's car that
-- is not ready on this game yet -- not in BeamMP's list, or listed but not built -- and
-- applies it when the car becomes ready. A held paint is dropped after 60 seconds.

local PAINT = "Resources/Client/Mileage/lua/ge/extensions/mileagePerPartPaint.lua"

local game, handlers

-- This game with no cars. game.listed[serverVehicleID] = gameVehicleID puts a car in
-- BeamMP's list; game.built[gameVehicleID] = true gives it an engine object.
local function setup()
	game = {now = 0, listed = {}, built = {}, commands = {}, sent = {}}
	handlers = {}
	function log() end
	function setExtensionUnloadMode() end
	function AddEventHandler(name, fn) handlers[name] = fn end
	function TriggerServerEvent(name, data) table.insert(game.sent, {name = name, data = data}) end
	function jsonEncode(t) return t end
	function jsonDecode(t) return t end
	function clamp(v, lo, hi) return math.min(math.max(v, lo), hi) end
	function validateVehiclePaint() end
	function tableIsEmpty(t) return next(t) == nil end
	os.clockhp = function() return game.now end
	worldReadyState = 2
	mileageEnabler = {}
	MPVehicleGE = {
		getVehicles = function()
			local list = {}
			for sid, gid in pairs(game.listed) do list[sid] = {gameVehicleID = gid} end
			return list
		end,
		getGameVehicleID = function(sid) return game.listed[sid] end,
		getServerVehicleID = function(gid)
			for sid, id in pairs(game.listed) do if id == gid then return sid end end
			return nil
		end,
		isOwn = function() return false end,
	}
	be = {getObjectByID = function(_, gid)
		if not game.built[gid] then return nil end
		return {
			getID = function() return gid end,
			queueLuaCommand = function(_, cmd) table.insert(game.commands, {gid = gid, cmd = cmd}) end,
		}
	end}
	local paint = dofile(PAINT)
	paint.onExtensionLoaded()
	return paint
end

local RED = {{baseColor = {1, 0, 0, 1}, metallic = 0, roughness = 0.5, clearcoat = 0, clearcoatRoughness = 0}}
local GREEN = {{baseColor = {0, 1, 0, 1}, metallic = 0, roughness = 0.5, clearcoat = 0, clearcoatRoughness = 0}}

local function receive(sid, part, paints)
	handlers.rxRemotePartPaint({serverVehicleID = sid, partPath = part, paints = paints or RED})
end

-- The part paint commands that reached car gid, as "<part>:<colour>".
local function painted(gid)
	local out = {}
	for _, c in ipairs(game.commands) do
		if c.gid == gid and c.cmd:find("setPartPaints", 1, true) then
			local part = c.cmd:match('local identifiers = {"([^"]+)"')
			local colour = c.cmd:find("baseColor = {0.000000, 1.000000", 1, true) and "green" or "red"
			table.insert(out, tostring(part) .. ":" .. colour)
		end
	end
	table.sort(out)
	return table.concat(out, ",")
end

local function paintRequests()
	local n = 0
	for _, m in ipairs(game.sent) do if m.name == "requestPartPaints" then n = n + 1 end end
	return n
end

test("#49: a paint for a car not listed yet is applied when the car becomes ready", function()
	local paint = setup()
	receive("1-0", "vehicle/hood")
	same(painted(10), "", "paint before the car exists")
	game.listed["1-0"] = 10
	game.built[10] = true
	paint.onVehicleReady(10)
	same(painted(10), "vehicle/hood:red", "paint once the car is ready")
	same(paintRequests(), 1, "the owner is still asked for the paints")
	paint.onVehicleReady(10)
	same(painted(10), "vehicle/hood:red", "a held paint is applied once")
end)

test("#49: a paint for a car listed but not built yet is applied when it becomes ready", function()
	local paint = setup()
	game.listed["1-0"] = 10
	receive("1-0", "vehicle/hood")
	same(painted(10), "", "paint before the car is built")
	game.built[10] = true
	paint.onVehicleReady(10)
	same(painted(10), "vehicle/hood:red", "paint once the car is ready")
end)

test("#49: every held part is applied, and a later paint of the same part replaces the earlier", function()
	local paint = setup()
	receive("1-0", "vehicle/hood")
	receive("1-0", "vehicle/door_L")
	receive("1-0", "vehicle/hood", GREEN)
	game.listed["1-0"] = 10
	game.built[10] = true
	paint.onVehicleReady(10)
	same(painted(10), "vehicle/door_L:red,vehicle/hood:green", "parts painted")
end)

test("#49: a paint held for more than 60 seconds is dropped and never applied", function()
	local paint = setup()
	receive("1-0", "vehicle/hood")
	game.now = 59
	paint.onUpdate()
	game.now = 61
	paint.onUpdate()
	game.listed["1-0"] = 10
	game.built[10] = true
	paint.onVehicleReady(10)
	same(painted(10), "", "paint after 61 s")
end)

test("#49: leaving the server drops held paints", function()
	local paint = setup()
	receive("1-0", "vehicle/hood")
	paint.onBeamMPServerLeave()
	game.listed["1-0"] = 10
	game.built[10] = true
	paint.onVehicleReady(10)
	same(painted(10), "", "paint after leaving")
end)

test("#49: a paint for a car that is ready is applied at once, as before", function()
	setup()
	game.listed["1-0"] = 10
	game.built[10] = true
	receive("1-0", "vehicle/hood")
	same(painted(10), "vehicle/hood:red", "paint")
end)

test("#49: a car that is ready but still not built keeps its paint until a later ready", function()
	local paint = setup()
	receive("1-0", "vehicle/hood")
	game.listed["1-0"] = 10
	paint.onVehicleReady(10)
	same(painted(10), "", "paint while the car has no engine object")
	game.built[10] = true
	paint.onVehicleReady(10)
	same(painted(10), "vehicle/hood:red", "paint once it is built")
end)

test("#49: the 60 s count starts at a car's first held paint, not its latest", function()
	local paint = setup()
	receive("1-0", "vehicle/hood")
	game.now = 50
	receive("1-0", "vehicle/door_L")
	game.now = 61
	paint.onUpdate()
	game.listed["1-0"] = 10
	game.built[10] = true
	paint.onVehicleReady(10)
	same(painted(10), "", "paint 61 s after the first held paint")
end)

test("#49: paints are held for at most 64 cars, and a car whose paint applied frees its place", function()
	local paint = setup()
	for n = 0, 64 do receive("1-" .. n, "vehicle/hood") end
	game.listed["1-64"] = 74
	game.built[74] = true
	paint.onVehicleReady(74)
	same(painted(74), "", "paint of the 65th car")
	game.listed["1-0"] = 10
	game.built[10] = true
	paint.onVehicleReady(10)
	same(painted(10), "vehicle/hood:red", "paint of the first car")
	receive("1-65", "vehicle/hood")
	game.listed["1-65"] = 75
	game.built[75] = true
	paint.onVehicleReady(75)
	same(painted(75), "vehicle/hood:red", "paint of a car held after a place was freed")
end)

test("#49: a malformed paint message is ignored and nothing is held", function()
	local paint = setup()
	handlers.rxRemotePartPaint(nil)
	handlers.rxRemotePartPaint("text")
	handlers.rxRemotePartPaint({serverVehicleID = 5, partPath = "vehicle/hood", paints = RED})
	game.listed[5] = 10
	game.built[10] = true
	paint.onVehicleReady(10)
	same(painted(10), "", "paint from a malformed message")
end)

test("#49: a paint for another car is not applied to the one that became ready", function()
	local paint = setup()
	receive("1-1", "vehicle/hood")
	game.listed["1-0"] = 10
	game.built[10] = true
	paint.onVehicleReady(10)
	same(painted(10), "", "paint on the wrong car")
end)

test("#49: a newer paint applied at once replaces an older held paint of the same part", function()
	local paint = setup()
	receive("1-0", "vehicle/hood", RED)
	game.listed["1-0"] = 10
	game.built[10] = true
	receive("1-0", "vehicle/hood", GREEN)
	paint.onVehicleReady(10)
	same(painted(10), "vehicle/hood:green", "paints applied to the hood")
end)

--== a paint applied at once and the paints still held for the same car ========

test("#49: a newer paint applied at once for one part keeps the car's other held parts", function()
	local paint = setup()
	receive("1-0", "vehicle/hood", RED)
	receive("1-0", "vehicle/door_L", RED)
	game.listed["1-0"] = 10
	game.built[10] = true
	receive("1-0", "vehicle/hood", GREEN)
	paint.onVehicleReady(10)
	same(painted(10), "vehicle/door_L:red,vehicle/hood:green", "paints applied to the car")
end)

test("#49: a car whose only held paint is replaced by one applied at once frees its hold place", function()
	local paint = setup()
	for n = 0, 63 do receive("1-" .. n, "vehicle/hood") end
	game.listed["1-0"] = 10
	game.built[10] = true
	receive("1-0", "vehicle/hood", GREEN)
	receive("1-64", "vehicle/hood")
	game.listed["1-64"] = 74
	game.built[74] = true
	paint.onVehicleReady(74)
	same(painted(74), "vehicle/hood:red", "paint of a car held after the place was freed")
	same(painted(10), "vehicle/hood:green", "paint of the car that was painted at once")
end)

--== #87: a paint request waits for the server's state of the car ============

-- The enabler as it is today: game.states[serverVehicleID] is the server's state of
-- another player's car, once it has arrived.
local function withStates()
	game.states = {}
	mileageEnabler = {
		hasRemoteState = function(sid) return game.states[sid] ~= nil end,
		isRemoteTraffic = function(sid) return game.states[sid] ~= nil and game.states[sid].traffic == true end,
	}
end

-- The cars a paint request went out for, sorted, as "a,b".
local function requestedFor()
	local out = {}
	for _, m in ipairs(game.sent) do
		if m.name == "requestPartPaints" then table.insert(out, m.data.serverVehicleID) end
	end
	table.sort(out)
	return table.concat(out, ",")
end

-- Another player's car listed, built and ready on this game.
local function ready(paint, sid, gid)
	game.listed[sid] = gid
	game.built[gid] = true
	paint.onVehicleReady(gid)
end

test("#87: a car that becomes ready before its mark is asked for paint only once it is known not to be traffic", function()
	local paint = setup()
	withStates()
	ready(paint, "2-5", 25) -- the other player's traffic car
	ready(paint, "2-1", 21) -- their own car
	paint.onUpdate()
	same(requestedFor(), "", "requests before the server's states")
	game.states["2-5"] = {traffic = true}
	game.states["2-1"] = {traffic = false}
	game.now = 0.5
	paint.onUpdate()
	same(requestedFor(), "2-1", "requests once the states arrived")
	game.now = 10
	paint.onUpdate()
	same(requestedFor(), "2-1", "requests later on")
end)

test("#87: a car whose state is already known is asked at once, or not at all for traffic", function()
	local paint = setup()
	withStates()
	game.states["2-5"] = {traffic = true}
	game.states["2-1"] = {active = true}
	ready(paint, "2-5", 25)
	ready(paint, "2-1", 21)
	same(requestedFor(), "2-1", "requests on the frame the cars became ready")
end)

test("#87: a car with no state after 5 s is asked anyway, once; at 4.9 s it is not", function()
	local paint = setup()
	withStates()
	ready(paint, "2-1", 21)
	game.now = 4.9
	paint.onUpdate()
	same(requestedFor(), "", "requests at 4.9 s")
	game.now = 5
	paint.onUpdate()
	same(requestedFor(), "2-1", "requests at 5 s")
	game.now = 20
	paint.onUpdate()
	same(requestedFor(), "2-1", "requests later on")
end)

test("#87: the 5 s wait counts from the first ready, and a car ready twice is asked once", function()
	local paint = setup()
	withStates()
	ready(paint, "2-1", 21)
	game.now = 3
	paint.onVehicleReady(21)
	game.now = 5
	paint.onUpdate()
	same(requestedFor(), "2-1", "requests 5 s after the first ready")
end)

test("#87: a car removed while its request waits is never asked", function()
	local paint = setup()
	withStates()
	ready(paint, "2-1", 21)
	ready(paint, "2-2", 22)
	game.listed["2-1"] = nil -- gone from BeamMP's list
	paint.onVehicleDestroyed(22) -- destroyed on this game
	game.states["2-1"] = {active = true}
	game.states["2-2"] = {active = true}
	game.now = 10
	paint.onUpdate()
	same(requestedFor(), "", "requests for removed cars")
end)

test("#87: leaving the server forgets every waiting request", function()
	local paint = setup()
	withStates()
	ready(paint, "2-1", 21)
	paint.onBeamMPServerLeave()
	game.states["2-1"] = {active = true}
	game.now = 10
	paint.onUpdate()
	same(requestedFor(), "", "requests after leaving")
end)

test("#87: a waiting request goes out while the world is still loading", function()
	local paint = setup()
	withStates()
	worldReadyState = 1
	ready(paint, "2-1", 21)
	game.states["2-1"] = {active = true}
	paint.onUpdate()
	same(requestedFor(), "2-1", "requests while joining")
	worldReadyState = 2
end)
