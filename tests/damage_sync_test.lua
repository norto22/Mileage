-- Damage between players: each player's game sends the dents of the cars it owns
-- (lua/vehicle/extensions/auto/mileageDamage.lua and mileage/damageSync.lua), the
-- server relays them from the car's owner only (mileage.lua), and every other game
-- applies them to its copy of the car.
--
-- Two stand-in games and the real server plugin. Commands one side of a game queues for
-- the other (queueGameEngineLua, queueLuaCommand) run as Lua text, as the game runs them.

local VEHICLE = "Resources/Client/Mileage/lua/vehicle/extensions/auto/mileageDamage.lua"
local GE = "Resources/Client/Mileage/lua/ge/extensions/mileage/damageSync.lua"
local SERVER = "Resources/Server/Mileage/mileage.lua"

--== text, vectors and JSON ==================================================

local compile = loadstring or load

-- The JSON this feature sends is flat: string keys, numbers, strings and arrays.
local function jsonToLua(text)
	if type(text) ~= "string" then return nil end
	local luaText = text:gsub("%[", "{"):gsub("%]", "}"):gsub('"([%w_]+)"%s*:', '["%1"]=')
	local chunk = compile("return " .. luaText)
	if not chunk then return nil end
	local ok, value = pcall(chunk)
	if ok and type(value) == "table" then return value end
	return nil
end

local function luaToJson(value)
	if type(value) == "table" then
		local parts = {}
		if #value > 0 then
			for _, item in ipairs(value) do table.insert(parts, luaToJson(item)) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		for k, item in pairs(value) do table.insert(parts, '"' .. tostring(k) .. '":' .. luaToJson(item)) end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif type(value) == "string" then
		return '"' .. value .. '"'
	end
	return tostring(value)
end

local vecMeta = {}
function vec3(x, y, z)
	if type(x) == "table" then x, y, z = x.x, x.y, x.z end
	return setmetatable({x = x or 0, y = y or 0, z = z or 0}, vecMeta)
end
vecMeta.__unm = function(a) return vec3(-a.x, -a.y, -a.z) end

-- Rotations only travel from the car to its reset here, so a stand-in quaternion is
-- enough: products and quatFromDir keep their parts.
local quatMeta = {}
function quat(x, y, z, w) return setmetatable({x = x, y = y, z = z, w = w}, quatMeta) end
quatMeta.__mul = function(a, b) return quat(a.x + b.x, a.y + b.y, a.z + b.z, a.w * b.w) end
function quatFromDir(dir, up) return quat(dir.x, dir.y, up.z, 1) end

local function cross(a, b)
	return {x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x}
end

-- A point given in the car's own frame (right, forward, up from node 0), as a position
-- relative to the car in world directions, which is what obj:getNodePosition returns.
local function fromCarFrame(car, lx, ly, lz)
	local f, u = car.fwd, car.up
	local r = cross(f, u)
	local o = car.nodePos[0]
	return {x = o.x + r.x * lx + f.x * ly + u.x * lz, y = o.y + r.y * lx + f.y * ly + u.y * lz,
		z = o.z + r.z * lx + f.z * ly + u.z * lz}
end

local function toCarFrame(car, p)
	local f, u = car.fwd, car.up
	local r = cross(f, u)
	local o = car.nodePos[0]
	local d = {x = p.x - o.x, y = p.y - o.y, z = p.z - o.z}
	return d.x * r.x + d.y * r.y + d.z * r.z, d.x * f.x + d.y * f.y + d.z * f.z, d.x * u.x + d.y * u.y + d.z * u.z
end

--== a stand-in world ========================================================

local world, logs

-- Runs fn inside a car's vehicle Lua: obj, v, beamstate and the extension are its own.
local function inVehicle(car, fn, ...)
	obj, v, beamstate, mileageDamage = car.obj, car.v, car.beamstate, car.ext
	return fn(...)
end

-- The enabler's traffic test, from the real enabler (loaded once per world).
local ENABLER = "Resources/Client/Mileage/lua/ge/extensions/mileageEnabler.lua"
local enabler

-- Runs fn with the globals of a game's game-engine Lua.
local function as(game, fn, ...)
	MPVehicleGE, be, gameplay_traffic = game.MPVehicleGE, game.be, game.traffic
	mileage_damageSync, mileageEnabler = game.ge, enabler
	function TriggerServerEvent(name, data)
		table.insert(world.toServer, {from = game.id, name = name, data = data})
	end
	function AddEventHandler(name, fn) game.handlers[name] = fn end
	return fn(...)
end

local function newWorld()
	world = {games = {}, toServer = {}, toClients = {}, serverSent = {}, received = {}}
	logs = {}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	jsonEncode, jsonDecode = luaToJson, jsonToLua
	Util = {JsonDecode = function(text)
		local value = jsonToLua(text)
		if value == nil then error("does not decode") end
		return value
	end, JsonEncode = luaToJson}
	MP = {
		CreateTimer = function() return {GetCurrent = function() return world.now or 0 end, Start = function() end} end,
		GetPlayers = function()
			local names = {}
			for id, g in pairs(world.games) do names[id] = "player" .. id end
			return names
		end,
		IsPlayerConnected = function() return true end,
		GetPlayerName = function(id) return "player" .. id end,
		TriggerClientEvent = function(target, event, data)
			table.insert(world.toClients, {target = target, event = event, data = data})
			table.insert(world.serverSent, {target = target, event = event, data = data})
		end,
		TriggerClientEventJson = function(target, event, data)
			table.insert(world.toClients, {target = target, event = event, data = luaToJson(data)})
		end,
	}
	local realPrint = print
	print = function() end
	dofile(SERVER)
	print = realPrint
	enabler = dofile(ENABLER)
	return world
end

local function addGame(id)
	local game = {id = id, cars = {}, objects = {}, vehicles = {}, handlers = {}, trafficData = {},
		geQueue = {}, playerVehicle = -1}
	game.MPVehicleGE = {
		getVehicles = function() return game.vehicles end,
		isOwn = function(gid) local c = game.cars[gid]; return c ~= nil and c.owner == id end,
		getServerVehicleID = function(gid) local c = game.cars[gid]; return c and c.sid end,
		getGameVehicleID = function(sid)
			for gid, c in pairs(game.cars) do if c.sid == sid then return gid end end
			return nil
		end,
	}
	game.be = {
		getObjectByID = function(_, gid) return game.objects[gid] end,
		getPlayerVehicleID = function() return game.playerVehicle end,
	}
	game.traffic = {getTrafficData = function() return game.trafficData end}
	world.games[id] = game
	as(game, function()
		game.ge = dofile(GE)
		mileage_damageSync = game.ge
		if game.ge.onExtensionLoaded then game.ge.onExtensionLoaded() end
	end)
	return game
end

-- A car of `owner` ("<owner>-<vid>") on game: opts.beams beams between opts.nodes nodes,
-- every rest length 1, facing opts.fwd (default +y) with up +z.
local function addCar(game, owner, vid, opts)
	opts = opts or {}
	local gid = owner * 100 + vid + 1
	local nodeCount, beamCount = opts.nodes or 50, opts.beams or 60
	local car = {game = game, gid = gid, owner = owner, sid = owner .. "-" .. vid,
		restLen = {}, broken = {}, nodePos = {}, breakCalls = 0, deformCalls = 0, vehicleQueue = {},
		fwd = opts.fwd or {x = 0, y = 1, z = 0}, up = {x = 0, y = 0, z = 1}}
	local nodes, beams = {}, {}
	car.nodePos[0] = {x = 0.3, y = -0.2, z = 0.4}
	for cid = 0, nodeCount - 1 do
		nodes[cid] = {cid = cid}
		if cid > 0 then
			-- Rows of five, folded every 40 rows so a car of thousands of points stays the
			-- size of a real one (within the 20 m a copy accepts).
			car.nodePos[cid] = fromCarFrame(car, (cid % 5) * 0.4 - 0.8, (math.floor(cid / 5) % 40) * 0.4 - 2,
				(cid % 3) * 0.3 + math.floor(cid / 200) * 0.01)
		end
	end
	for cid = 0, beamCount - 1 do
		-- opts.separate gives every beam two points of its own.
		if opts.separate then
			beams[cid] = {cid = cid, id1 = (2 * cid) % nodeCount, id2 = (2 * cid + 1) % nodeCount}
		else
			beams[cid] = {cid = cid, id1 = cid % nodeCount, id2 = (cid + 1) % nodeCount}
		end
		car.restLen[cid] = 1
	end
	-- opts.hydros: steering hydraulics' beams; opts.settling: beams that settle after spawn.
	local hydros = {}
	for _, cid in ipairs(opts.hydros or {}) do table.insert(hydros, {beamCID = cid}) end
	for _, cid in ipairs(opts.settling or {}) do beams[cid].beamPrecompressionTime = 0.5 end
	-- opts.beamNames / opts.beamTags: {cid = name or tag}; opts.controllers: the car's
	-- jbeam controllers; opts.data: more of v.data.
	for cid, name in pairs(opts.beamNames or {}) do beams[cid].name = name end
	for cid, tag in pairs(opts.beamTags or {}) do beams[cid].tag = tag end
	car.v = {data = {beams = beams, nodes = nodes, refNodes = {[0] = {ref = 0}}, hydros = hydros,
		controller = opts.controllers}}
	for k, value in pairs(opts.data or {}) do car.v.data[k] = value end
	car.beamstate = {damage = 0, deformedBeams = {}}
	function car.beamstate.onBeamDeformed(cid, ratio)
		car.deformCalls = car.deformCalls + 1
		car.beamstate.deformedBeams[cid] = ratio
	end
	car.obj = {}
	-- What the copy's vehicle Lua did to the car, in order: {"node", cid}, {"beam", cid},
	-- {"commit"}.
	car.applyLog, car.commits = {}, 0
	function car.obj:getID() return gid end
	function car.obj:getBeamRestLength(cid) return car.restLen[cid] end
	function car.obj:setBeamLength(cid, len)
		table.insert(car.applyLog, {"beam", cid})
		car.restLen[cid] = len
	end
	function car.obj:commitLoad()
		table.insert(car.applyLog, {"commit"})
		car.commits = car.commits + 1
	end
	function car.obj:beamIsBroken(cid) return car.broken[cid] == true end
	function car.obj:breakBeam(cid)
		car.breakCalls = car.breakCalls + 1
		car.broken[cid] = true
		car.beamstate.deformedBeams[cid] = 1
	end
	function car.obj:getNodePosition(cid) return vec3(car.nodePos[cid]) end
	function car.obj:setNodePosition(cid, p)
		table.insert(car.applyLog, {"node", cid})
		car.nodePos[cid] = vec3(p)
	end
	function car.obj:getDirectionVector() return vec3(car.fwd) end
	function car.obj:getDirectionVectorUp() return vec3(car.up) end
	function car.obj:queueGameEngineLua(cmd) table.insert(game.geQueue, cmd) end

	-- The game-engine side of the same car.
	local veh = {JBeam = opts.jbeam or "pickup", isTraffic = opts.isTraffic, isParked = opts.isParked,
		resets = 0, pos = {x = 10, y = 20, z = 0.5}}
	function veh:queueLuaCommand(cmd) table.insert(car.vehicleQueue, cmd) end
	function veh:getID() return gid end
	function veh:getPosition() return vec3(self.pos) end
	function veh:getDirectionVector() return vec3(car.fwd) end
	function veh:getDirectionVectorUp() return vec3(car.up) end
	function veh:setPositionRotation(x, y, z, rx, ry, rz, rw)
		for _, n in ipairs({x, y, z, rx, ry, rz, rw}) do assert(type(n) == "number", "setPositionRotation takes numbers") end
		same(x, self.pos.x, "reset in place: x")
		same(y, self.pos.y, "reset in place: y")
		self.resets = self.resets + 1
		car.reset()
	end
	function veh:resetBrokenFlexMesh() end
	car.veh = veh

	-- What the game does to the car on a reset: pristine beams, no damage.
	function car.reset()
		for cid in pairs(car.restLen) do car.restLen[cid] = 1 end
		car.broken = {}
		car.beamstate.damage = 0
		car.beamstate.deformedBeams = {}
		if car.ext and car.ext.onReset then inVehicle(car, car.ext.onReset) end
	end

	game.cars[gid], game.objects[gid] = car, veh
	game.vehicles[car.sid] = {gameVehicleID = gid, jbeam = veh.JBeam, ownerID = owner}
	car.ext = inVehicle(car, dofile, VEHICLE)
	inVehicle(car, function()
		if car.ext.onExtensionLoaded then car.ext.onExtensionLoaded() end
	end)
	return car
end

-- Delivers everything queued: vehicle Lua to game-engine Lua, game to server, server to
-- games, game-engine Lua to vehicle Lua, until nothing is left.
local function pump()
	for _ = 1, 500 do
		local busy = false
		for _, game in pairs(world.games) do
			local queue = game.geQueue
			game.geQueue = {}
			for _, cmd in ipairs(queue) do
				busy = true
				as(game, function() assert(compile(cmd))() end)
			end
			for _, car in pairs(game.cars) do
				local vq = car.vehicleQueue
				car.vehicleQueue = {}
				for _, cmd in ipairs(vq) do
					busy = true
					inVehicle(car, function() assert(compile(cmd))() end)
				end
			end
		end
		local toServer, toClients = world.toServer, world.toClients
		world.toServer, world.toClients = {}, {}
		for _, m in ipairs(toServer) do
			busy = true
			table.insert(world.received, m)
			local handler = _G[m.name]
			if handler then handler(m.from, m.data) end
		end
		for _, m in ipairs(toClients) do
			busy = true
			for id, game in pairs(world.games) do
				if m.target == -1 or m.target == id then
					local handler = game.handlers[m.event]
					if handler then as(game, handler, m.data) end
				end
			end
		end
		if not busy then return end
	end
	error("messages never stopped")
end

-- Runs every game and car for `seconds`, in quarter-second frames.
local function step(seconds)
	local frames = math.floor(seconds / 0.25 + 0.5)
	for _ = 1, frames do
		world.now = (world.now or 0) + 0.25
		for _, game in pairs(world.games) do
			if game.ge.onUpdate then as(game, game.ge.onUpdate, 0.25, 0.25, 0.25) end
			for _, car in pairs(game.cars) do
				if car.ext.updateGFX then inVehicle(car, car.ext.updateGFX, 0.25) end
			end
		end
		pump()
	end
end

-- Player 0 owns car "0-0"; player 1's game has its copy, facing another way.
local function twoGames(opts)
	opts = opts or {}
	newWorld()
	local owners, copies = addGame(0), addGame(1)
	local owner = addCar(owners, 0, 0, opts)
	local copy = addCar(copies, 0, 0, {nodes = opts.nodes, beams = opts.beams, hydros = opts.hydros,
		settling = opts.settling, fwd = {x = 1, y = 0, z = 0}})
	owners.playerVehicle = owner.gid
	return owner, copy, owners, copies
end

-- A dent on the owner's car: beam cid shortened to len, its first node moved by `shift`
-- in the car's own frame, and the game's damage total raised.
local function dent(car, cid, len, shift)
	car.restLen[cid] = len
	car.beamstate.deformedBeams[cid] = 0.3
	car.beamstate.damage = car.beamstate.damage + 100
	if shift then
		local node = car.v.data.beams[cid].id1
		local lx, ly, lz = toCarFrame(car, car.nodePos[node])
		car.nodePos[node] = fromCarFrame(car, lx + shift[1], ly + shift[2], lz + shift[3])
	end
end

--== a dent reaches the copy ================================================

test("a dent on the owner's car reaches the other player's copy", function()
	local owner, copy = twoGames()
	step(2.5)
	dent(owner, 7, 0.8)
	step(1.5)
	same(copy.restLen[7], 0.8, "the copy's beam 7")
end)

--== the vehicle side on its own ============================================

-- A car on a game with no game-engine module: what its vehicle Lua queues stays in
-- game.geQueue.
local function soloCar(opts)
	newWorld()
	local game = {id = 0, cars = {}, objects = {}, vehicles = {}, geQueue = {}}
	world.games[0] = game
	return addCar(game, 0, 0, opts), game
end

-- The damage messages a car's vehicle Lua queued for the game-engine Lua, decoded.
local function takeMessages(car)
	local messages = {}
	local queue = car.game.geQueue
	car.game.geQueue = {}
	for _, cmd in ipairs(queue) do
		mileage_damageSync = {onLocalDamage = function(id, json)
			same(id, car.gid, "vehicle id in the command")
			table.insert(messages, jsonToLua(json))
		end}
		assert(compile(cmd))()
	end
	return messages
end

local function tick(car, seconds)
	for _ = 1, math.floor((seconds or 0.5) / 0.25 + 0.5) do inVehicle(car, car.ext.updateGFX, 0.25) end
end

local function beamIds(message)
	local ids = {}
	for i = 1, #message.b, 4 do table.insert(ids, message.b[i]) end
	return ids
end

local function ownerCar(opts)
	local car = soloCar(opts)
	inVehicle(car, car.ext.setRole, "owner")
	return car
end

local function copyCar(opts)
	local car = soloCar(opts)
	inVehicle(car, car.ext.setRole, "copy")
	return car
end

test("a new owner announces itself once, then sends nothing while its damage does not move", function()
	local car = ownerCar()
	tick(car)
	local first = takeMessages(car)
	same(#first, 1, "announcements")
	same(#first[1].b, 0, "beams in an undamaged car's announcement")
	same(first[1].c, 0, "not cleared")
	tick(car, 2)
	same(#takeMessages(car), 0, "messages afterwards")
end)

test("each message carries only the beams changed since the one before", function()
	local car = ownerCar()
	dent(car, 7, 0.8)
	dent(car, 9, 0.9)
	tick(car)
	local first = takeMessages(car)
	same(#first, 1, "first messages")
	same(table.concat(beamIds(first[1]), ","), "7,9", "beams in the first message")
	same(first[1].b[2], 0.8, "beam 7 rest length")
	same(first[1].b[3], 0, "beam 7 not broken")
	same(first[1].b[4], 0.3, "beam 7 deformation")
	same(first[1].c, 0, "not cleared")
	dent(car, 12, 0.7)
	tick(car)
	local second = takeMessages(car)
	same(table.concat(beamIds(second[1]), ","), "12", "beams in the second message")
end)

test("a broken beam is sent as broken", function()
	local car = ownerCar()
	car.broken[5] = true
	car.beamstate.damage = 50
	tick(car)
	local m = takeMessages(car)[1]
	same(table.concat(beamIds(m), ","), "5", "beams")
	same(m.b[3], 1, "broken")
end)

test("a car with no role, or a copy, never sends its damage", function()
	for _, role in ipairs({"none", "copy"}) do
		local car = soloCar()
		inVehicle(car, car.ext.setRole, role)
		dent(car, 7, 0.8)
		tick(car, 2)
		same(#takeMessages(car), 0, role .. ": messages")
	end
end)

test("a wreck of 1000 beams goes out as 400, 400 and 200 over three ticks", function()
	local car = ownerCar({beams = 1000})
	car.beamstate.damage = 1000
	for cid = 0, 999 do car.restLen[cid] = 0.9 end
	local counts = {}
	for _ = 1, 4 do
		tick(car)
		for _, m in ipairs(takeMessages(car)) do table.insert(counts, math.floor(#m.b / 4)) end
	end
	same(table.concat(counts, ","), "400,400,200", "beams per message")
end)

test("a message of ordinary dents holds at most 500 points", function()
	local car = ownerCar({beams = 300, nodes = 600, separate = true})
	tick(car)
	takeMessages(car)
	car.beamstate.damage = 1000
	for cid = 0, 299 do car.restLen[cid] = 0.9 end
	tick(car)
	local m = takeMessages(car)[1]
	same(math.floor(#m.n / 4), 500, "points in the message")
	same(math.floor(#m.b / 4), 250, "beams, cut short by the point limit")
	tick(car)
	same(math.floor(#takeMessages(car)[1].b / 4), 50, "beams in the next message")
end)

test("a dent applied to a copy facing another way lands in the same place on the car", function()
	local owner = ownerCar()
	dent(owner, 7, 0.8, {0.05, -0.12, 0.03})
	tick(owner)
	local m = takeMessages(owner)[1]
	local copy = copyCar({fwd = {x = 1, y = 0, z = 0}})
	inVehicle(copy, copy.ext.applyDamage, 0, m.b, m.n)
	local node = owner.v.data.beams[7].id1
	local ox, oy, oz = toCarFrame(owner, owner.nodePos[node])
	local cx, cy, cz = toCarFrame(copy, copy.nodePos[node])
	expect(math.abs(ox - cx) < 0.002 and math.abs(oy - cy) < 0.002 and math.abs(oz - cz) < 0.002,
		string.format("point %d: owner (%.3f, %.3f, %.3f), copy (%.3f, %.3f, %.3f)", node, ox, oy, oz, cx, cy, cz))
	expect(math.abs(copy.nodePos[node].x - owner.nodePos[node].x) > 0.1, "the copy's frame was used")
	same(copy.restLen[7], 0.8, "rest length")
	same(copy.beamstate.deformedBeams[7], 0.3, "deformation recorded")
end)

test("a copy refuses unknown beams and points and values out of range, and applies the rest", function()
	local copy = copyCar()
	local before = vec3(copy.nodePos[3])
	inVehicle(copy, copy.ext.applyDamage, 0,
		{7, 0.8, 0, 0.2,      -- applied
		 999, 0.8, 0, 0.2,    -- unknown beam
		 8, 150, 0, 0.2,      -- rest length out of range
		 9, -1, 0, 0.2,       -- negative rest length
		 10, 0.9, 2, 0.2,     -- broken flag not 0 or 1
		 11, 0.9, 0, 50,      -- deformation out of range
		 12, 0.5, 1, 1},      -- applied, broken
		{3, 25, 0, 0,         -- offset out of range
		 999, 0, 0, 0,        -- unknown point
		 4, 0.1, 0.2, 0.3})   -- applied
	same(copy.restLen[7], 0.8, "beam 7")
	same(copy.restLen[8], 1, "beam 8")
	same(copy.restLen[9], 1, "beam 9")
	same(copy.restLen[10], 1, "beam 10")
	same(copy.restLen[11], 1, "beam 11")
	same(copy.restLen[12], 0.5, "beam 12")
	same(copy.broken[12], true, "beam 12 broken")
	same(copy.nodePos[3].x, before.x, "point 3 left alone")
	local x, y, z = toCarFrame(copy, copy.nodePos[4])
	expect(math.abs(x - 0.1) < 1e-6 and math.abs(y - 0.2) < 1e-6 and math.abs(z - 0.3) < 1e-6, "point 4 placed")
	same(countLines(logs, "refused part of another player's damage message"), 1, "logged once")
end)

test("a copy refuses text where numbers belong", function()
	local copy = copyCar()
	inVehicle(copy, copy.ext.applyDamage, 0, {"7", 0.8, 0, 0.2, 8, "0.8", 0, 0.2}, {"3", 0, 0, 0})
	same(copy.restLen[7], 1, "beam 7")
	same(copy.restLen[8], 1, "beam 8")
end)

test("a beam already deformed or broken on the copy is not deformed or broken again", function()
	local copy = copyCar()
	inVehicle(copy, copy.ext.applyDamage, 0, {7, 0.8, 1, 0.3}, {})
	inVehicle(copy, copy.ext.applyDamage, 0, {7, 0.8, 1, 0.3}, {})
	same(copy.breakCalls, 1, "breakBeam calls")
	inVehicle(copy, copy.ext.applyDamage, 0, {9, 0.8, 0, 0.3}, {})
	inVehicle(copy, copy.ext.applyDamage, 0, {9, 0.7, 0, 0.4}, {})
	same(copy.deformCalls, 1, "onBeamDeformed calls")
	same(copy.restLen[9], 0.7, "the newer rest length")
end)

test("an owner car ignores damage messages meant for copies", function()
	local car = ownerCar()
	inVehicle(car, car.ext.applyDamage, 0, {7, 0.5, 0, 0.3}, {})
	same(car.restLen[7], 1, "beam 7")
end)

--== roles ===================================================================

local function roleCommands(car)
	local roles = {}
	for _, cmd in ipairs(car.roleLog or {}) do table.insert(roles, cmd) end
	return roles
end

-- Records every role a car's vehicle Lua is given.
local function watchRoles(car)
	car.roleLog = {}
	local setRole = car.ext.setRole
	car.ext.setRole = function(role)
		table.insert(car.roleLog, role)
		return setRole(role)
	end
end

local function sentToServer(name, from)
	local list = {}
	for _, m in ipairs(world.received) do
		if m.name == name and (from == nil or m.from == from) then table.insert(list, m) end
	end
	return list
end

test("an own car becomes the owner only after two checks as a car the player drives", function()
	newWorld()
	local game = addGame(0)
	local car = addCar(game, 0, 0)
	watchRoles(car)
	step(1)
	same(#roleCommands(car), 0, "roles after one check")
	step(1)
	same(table.concat(roleCommands(car), ","), "owner", "roles after two checks")
	step(3)
	same(#roleCommands(car), 1, "role sent once")
end)

test("traffic, parked cars and the walking unicycle never send damage", function()
	newWorld()
	local game = addGame(0)
	local traffic = addCar(game, 0, 1, {isTraffic = "true"})
	local parked = addCar(game, 0, 2, {isParked = "true"})
	local ai = addCar(game, 0, 3)
	game.trafficData[ai.gid] = {isAi = true}
	local walker = addCar(game, 0, 4, {jbeam = "unicycle"})
	local other = addGame(1)
	addCar(other, 0, 4, {jbeam = "unicycle"})
	for _, car in ipairs({traffic, parked, ai, walker}) do watchRoles(car) end
	step(5)
	for _, car in ipairs({traffic, parked, ai, walker}) do
		same(#roleCommands(car), 0, "roles for car " .. car.sid)
	end
	same(#sentToServer("careerDamageRequest"), 0, "full-damage requests for a unicycle")
end)

test("without the enabler's traffic test no car sends damage, and that is logged once", function()
	newWorld()
	local game = addGame(0)
	local car = addCar(game, 0, 0)
	game.playerVehicle = car.gid
	watchRoles(car)
	enabler = nil
	step(3)
	same(#roleCommands(car), 0, "roles")
	same(countLines(logs, "mileageEnabler.isTrafficCar missing"), 1, "warnings")
end)

test("the car the player drives sends its damage even when it came from traffic", function()
	newWorld()
	local game = addGame(0)
	local car = addCar(game, 0, 0, {isTraffic = "true"})
	game.playerVehicle = car.gid
	watchRoles(car)
	step(2)
	same(table.concat(roleCommands(car), ","), "owner", "roles")
end)

test("another player's car becomes a copy at once and asks its owner for full damage once", function()
	local owner, copy, owners, copies = twoGames()
	step(4)
	local requests = sentToServer("careerDamageRequest", 1)
	same(#requests, 1, "requests from the copy's game")
	same(requests[1].data, '{"v":"0-0"}', "request")
	same(#sentToServer("careerDamageRequest", 0), 0, "requests from the owner's game")
end)

--== the game-engine module ==================================================

test("a game sends at most 3 damage messages to the server a second", function()
	local owner, copy, owners = twoGames()
	step(2)
	for _ = 1, 10 do
		as(owners, owners.ge.onLocalDamage, owner.gid, '{"c":0,"b":[],"n":[]}')
	end
	local before = #sentToServer("careerDamage", 0)
	for _ = 1, 20 do
		as(owners, owners.ge.onUpdate, 0.05)
		pump()
	end
	local sent = #sentToServer("careerDamage", 0) - before
	expect(sent >= 2 and sent <= 3, "messages in one second: " .. sent)
end)

test("a message from a car that is not this game's owner car is not sent", function()
	local owner, copy, owners, copies = twoGames()
	step(3)
	local before = #sentToServer("careerDamage")
	as(copies, copies.ge.onLocalDamage, copy.gid, '{"c":0,"b":[],"n":[]}')
	as(owners, owners.ge.onLocalDamage, 999, '{"c":0,"b":[],"n":[]}')
	step(1)
	same(#sentToServer("careerDamage") - before, 0, "messages sent")
end)

local function deliver(game, text)
	as(game, game.handlers.rxCareerDamage, text)
	pump()
end

test("a received message for this game's own car, an unknown car or a malformed id is dropped", function()
	local owner, copy, owners, copies = twoGames()
	step(2)
	deliver(owners, '{"v":"0-0","c":0,"b":[7,0.5,0,0.3],"n":[]}')
	same(owner.restLen[7], 1, "own car")
	deliver(copies, '{"v":"0-9","c":0,"b":[7,0.5,0,0.3],"n":[]}')
	deliver(copies, '{"v":"0-0x","c":0,"b":[7,0.5,0,0.3],"n":[]}')
	deliver(copies, '{"v":0,"c":0,"b":[7,0.5,0,0.3],"n":[]}')
	same(copy.restLen[7], 1, "copy")
	deliver(copies, '{"v":"0-0","c":0,"b":[7,0.5,0,0.3],"n":[]}')
	same(copy.restLen[7], 0.5, "a well-formed message still applies")
end)

test("text in a received message never reaches a vehicle command", function()
	local owner, copy, owners, copies = twoGames()
	step(2)
	local ran = false
	_G.injected = function() ran = true end
	deliver(copies, '{"v":"0-0","c":0,"b":[7,"1});injected();({",0,0.3],"n":[]}')
	deliver(copies, '{"v":"0-0","c":0,"b":[7,0.5,0,0.3],"n":["3);injected();(",0,0,0]}')
	deliver(copies, '{"v":"0-0","c":"1);injected();(","b":[],"n":[]}')
	_G.injected = nil
	same(ran, false, "injected code ran")
	same(copy.restLen[7], 1, "nothing applied from a malformed message")
	same(#copy.vehicleQueue, 0, "vehicle commands left")
end)

test("a received message the game cannot decode is dropped without an error", function()
	local owner, copy, owners, copies = twoGames()
	step(2)
	local decode = jsonDecode
	jsonDecode = function() error("bad json") end
	deliver(copies, '{"v":"0-0",')
	jsonDecode = decode
	same(copy.restLen[7], 1, "copy")
end)

test("a received message with a wrong row length or too many rows is dropped", function()
	local owner, copy, owners, copies = twoGames()
	step(2)
	deliver(copies, '{"v":"0-0","c":0,"b":[7,0.5,0],"n":[]}')
	same(copy.restLen[7], 1, "three numbers in a row")
	local rows = {}
	for cid = 0, 400 do table.insert(rows, cid .. ",0.5,0,0.3") end
	deliver(copies, '{"v":"0-0","c":0,"b":[' .. table.concat(rows, ",") .. '],"n":[]}')
	same(copy.restLen[7], 1, "401 beams")
end)

--== the server relay ========================================================

local function serverSends(event)
	local list = {}
	for _, m in ipairs(world.serverSent) do
		if m.event == event then table.insert(list, m) end
	end
	return list
end

local function threeGames()
	newWorld()
	local games = {addGame(0), addGame(1), addGame(2)}
	world.serverSent = {}
	return games
end

test("the server passes a damage message from the car's owner to every other player, unchanged", function()
	threeGames()
	local text = '{"v":"0-3","c":0,"b":[7,0.5,0,0.3],"n":[]}'
	careerDamage(0, text)
	local sends = serverSends("rxCareerDamage")
	same(#sends, 2, "messages sent")
	local to = {}
	for _, s in ipairs(sends) do
		to[s.target] = true
		same(s.data, text, "message")
	end
	expect(to[1] and to[2] and not to[0], "sent to players 1 and 2 only")
end)

test("the server drops damage for a car the sender does not own", function()
	threeGames()
	careerDamage(1, '{"v":"0-3","c":0,"b":[],"n":[]}')
	careerDamage(1, '{"v":"10-3","c":0,"b":[],"n":[]}')
	careerDamage(1, '{"v":"1-3x","c":0,"b":[],"n":[]}')
	careerDamage(1, '{"c":0,"b":[],"n":[]}')
	same(#serverSends("rxCareerDamage"), 0, "messages sent")
end)

test("the server drops an oversize message and one that does not decode", function()
	threeGames()
	careerDamage(0, '{"v":"0-3","c":0,"b":[' .. string.rep("1,", 17000) .. '1],"n":[]}')
	careerDamage(0, '{"v":"0-3",')
	careerDamage(0, nil)
	same(#serverSends("rxCareerDamage"), 0, "messages sent")
end)

test("the server passes at most 4 damage messages a second from one player", function()
	threeGames()
	for _ = 1, 6 do careerDamage(0, '{"v":"0-3","c":0,"b":[],"n":[]}') end
	same(#serverSends("rxCareerDamage"), 8, "messages sent to two players")
	careerDamage(1, '{"v":"1-0","c":0,"b":[],"n":[]}')
	same(#serverSends("rxCareerDamage"), 10, "another player has their own limit")
	world.now = (world.now or 0) + 1
	careerDamage(0, '{"v":"0-3","c":0,"b":[],"n":[]}')
	same(#serverSends("rxCareerDamage"), 12, "a second later")
end)

test("a full-damage request reaches the car's owner only", function()
	threeGames()
	careerDamageRequest(1, '{"v":"2-5"}')
	local sends = serverSends("rxCareerDamageRequest")
	same(#sends, 1, "requests passed on")
	same(sends[1].target, 2, "to the owner")
	same(sends[1].data, '{"v":"2-5"}', "request")
	careerDamageRequest(2, '{"v":"2-5"}')
	careerDamageRequest(1, '{"v":"7-5"}')
	careerDamageRequest(1, '{"v":"2-5);x"}')
	careerDamageRequest(1, '{"v":5}')
	same(#serverSends("rxCareerDamageRequest"), 1, "requests passed on after bad ones")
end)

--== full-damage answers go to who asked =====================================

local function targetsOf(sends)
	local to = {}
	for _, s in ipairs(sends) do table.insert(to, s.target) end
	table.sort(to)
	return table.concat(to, ",")
end

test("a flagged full-damage chunk goes only to the players who asked for that car", function()
	threeGames()
	careerDamageRequest(2, '{"v":"0-3"}')
	world.serverSent = {}
	careerDamage(0, '{"v":"0-3","f":1,"c":0,"b":[7,0.5,0,0.3],"n":[]}')
	same(targetsOf(serverSends("rxCareerDamage")), "2", "a flagged chunk")
	world.serverSent = {}
	careerDamage(0, '{"v":"0-3","c":0,"b":[7,0.5,0,0.3],"n":[]}')
	same(targetsOf(serverSends("rxCareerDamage")), "1,2", "an ordinary message")
end)

test("a flagged chunk with nobody asking in the last 5 seconds goes to every other player", function()
	threeGames()
	world.now = 0
	careerDamageRequest(2, '{"v":"0-3"}')
	world.now = 6
	world.serverSent = {}
	careerDamage(0, '{"v":"0-3","f":1,"c":0,"b":[],"n":[]}')
	same(targetsOf(serverSends("rxCareerDamage")), "1,2", "a flagged chunk after the ask expired")
	world.serverSent = {}
	careerDamage(0, '{"v":"0-4","f":1,"c":0,"b":[],"n":[]}')
	same(targetsOf(serverSends("rxCareerDamage")), "1,2", "a flagged chunk nobody asked for")
end)

test("two players asking for one car both get its flagged chunks", function()
	threeGames()
	addGame(3)
	careerDamageRequest(2, '{"v":"0-3"}')
	careerDamageRequest(3, '{"v":"0-3"}')
	world.serverSent = {}
	careerDamage(0, '{"v":"0-3","f":1,"c":0,"b":[],"n":[]}')
	same(targetsOf(serverSends("rxCareerDamage")), "2,3", "a flagged chunk")
end)

test("the server drops a damage message that names a car twice or holds an escape", function()
	threeGames()
	careerDamage(0, '{"v":"0-3","c":0,"v":"1-0","b":[7,0.5,0,0.3],"n":[]}')
	careerDamage(0, '{"v":"0-3","c":0,"v" :"1-0","b":[],"n":[]}')
	careerDamage(0, '{"v":"0-3","c":0,"\\u0076":"1-0","b":[],"n":[]}')
	careerDamage(0, '{ "v":"0-3","c":0,"b":[],"n":[]}')
	same(#serverSends("rxCareerDamage"), 0, "messages sent")
end)

test("an answer still under way keeps reaching a player who asked more than 5 seconds ago", function()
	threeGames()
	world.now = 0
	careerDamageRequest(1, '{"v":"0-3"}')
	for t = 1, 8 do
		world.now = t
		if t == 4 then careerDamageRequest(2, '{"v":"0-3"}') end
		world.serverSent = {}
		careerDamage(0, '{"v":"0-3","f":1,"c":0,"b":[],"n":[]}')
		same(targetsOf(serverSends("rxCareerDamage")), t < 4 and "1" or "1,2", "a flagged chunk at " .. t .. " s")
	end
	-- Once the answer stops for 5 seconds, the asks are over.
	world.now = 14
	world.serverSent = {}
	careerDamage(0, '{"v":"0-3","f":1,"c":0,"b":[],"n":[]}')
	same(targetsOf(serverSends("rxCareerDamage")), "1,2", "a flagged chunk after the answer stopped")
end)

test("a leaving player's asks are forgotten", function()
	local games = threeGames()
	careerDamageRequest(2, '{"v":"0-3"}')
	world.games[2] = nil
	onPlayerDisconnectHandler(2)
	world.serverSent = {}
	careerDamage(0, '{"v":"0-3","f":1,"c":0,"b":[],"n":[]}')
	same(targetsOf(serverSends("rxCareerDamage")), "1", "a flagged chunk after the asker left")
end)

-- What a car's vehicle Lua queued for the game-engine Lua, as raw message text.
local function rawMessages(car)
	local messages = {}
	local queue = car.game.geQueue
	car.game.geQueue = {}
	for _, cmd in ipairs(queue) do
		mileage_damageSync = {onLocalDamage = function(_, json) table.insert(messages, json) end}
		assert(compile(cmd))()
	end
	return messages
end

test("an owner asked for its full damage answers with flagged chunks, a new owner's full send is not flagged", function()
	local car = soloCar({beams = 900, nodes = 50})
	for cid = 0, 849 do dent(car, cid, 0.8) end
	inVehicle(car, car.ext.setRole, "owner")
	tick(car, 3)
	local announce = rawMessages(car)
	expect(#announce >= 3, "chunks of the new owner's full send: " .. #announce)
	for _, m in ipairs(announce) do same(m:sub(1, 6), '{"c":0', "an unflagged chunk") end
	inVehicle(car, car.ext.answerFull)
	tick(car, 3)
	local answer = rawMessages(car)
	expect(#answer >= 3, "chunks of the answer: " .. #answer)
	for _, m in ipairs(answer) do same(m:sub(1, 13), '{"f":1,"c":0,', "a flagged chunk") end
end)

test("an undamaged owner answers a request with one flagged empty message", function()
	local car = ownerCar()
	tick(car)
	rawMessages(car)
	inVehicle(car, car.ext.answerFull)
	tick(car)
	local answer = rawMessages(car)
	same(#answer, 1, "messages")
	same(answer[1], '{"f":1,"c":0,"b":[],"n":[]}', "the answer")
end)

test("a full send for everyone replaces a flagged answer still being sent", function()
	local car = soloCar({beams = 900, nodes = 50})
	for cid = 0, 849 do dent(car, cid, 0.8) end
	inVehicle(car, car.ext.setRole, "owner")
	tick(car, 3)
	rawMessages(car)
	inVehicle(car, car.ext.answerFull)
	tick(car, 0.5)
	inVehicle(car, car.ext.sendFull, 1)
	tick(car, 3)
	local after = rawMessages(car)
	local flagged, cleared = 0, 0
	for _, m in ipairs(after) do
		if m:sub(1, 7) == '{"f":1,' then flagged = flagged + 1 end
		if m:sub(1, 6) == '{"c":1' then cleared = cleared + 1 end
	end
	same(cleared, 1, "cleared notices")
	same(flagged, 1, "flagged chunks: only the one sent before the full send for everyone")
end)

test("a dent made while an answer is being sent goes to everyone within a second, before the answer ends", function()
	local car = soloCar({beams = 1700, nodes = 50})
	for cid = 0, 1599 do dent(car, cid, 0.8) end
	inVehicle(car, car.ext.setRole, "owner")
	tick(car, 3)
	rawMessages(car)
	inVehicle(car, car.ext.answerFull)
	tick(car, 0.5)
	same(#rawMessages(car), 1, "answer chunks in the first half second")
	dent(car, 1650, 0.7)
	tick(car, 1)
	local ordinary, flagged = nil, 0
	for _, m in ipairs(rawMessages(car)) do
		if m:sub(1, 7) == '{"f":1,' then
			flagged = flagged + 1
		elseif m:find('"b":%[1650,') then
			ordinary = m
		end
	end
	expect(ordinary ~= nil, "an ordinary message with the new dent within a second")
	expect(flagged >= 1, "the answer goes on beside it")
end)

test("a dent made while a full answer goes to one player still reaches every other player", function()
	local games = threeGames()
	local owners = games[1]
	local owner = addCar(owners, 0, 0, {beams = 900, nodes = 50})
	owners.playerVehicle = owner.gid
	for cid = 0, 849 do dent(owner, cid, 0.8) end
	local seen = addCar(games[2], 0, 0, {beams = 900, nodes = 50})
	step(6)
	same(seen.restLen[849], 0.8, "the first copy has the owner's dents")
	-- Player 2 builds a copy late and asks for the car's full damage. Once the first
	-- chunk of the answer is out, the owner dents a beam of a later chunk and a new one.
	local late = addCar(games[3], 0, 0, {beams = 900, nodes = 50})
	local before = #sentToServer("careerDamage", 0)
	local answering = false
	for _ = 1, 40 do
		step(0.25)
		for i = before + 1, #sentToServer("careerDamage", 0) do
			if sentToServer("careerDamage", 0)[i].data:find('"f":1,', 1, true) then answering = true end
		end
		if answering then break end
	end
	expect(answering, "the owner started its answer")
	dent(owner, 849, 0.75)
	dent(owner, 880, 0.7)
	step(6)
	same(late.restLen[100], 0.8, "the late copy has the owner's earlier dents")
	same(seen.restLen[849], 0.75, "the first copy has the change to a beam of the answer")
	same(seen.restLen[880], 0.7, "the first copy has the new dent")
	same(late.restLen[849], 0.75, "the late copy has the change to a beam of the answer")
	same(late.restLen[880], 0.7, "the late copy has the new dent")
end)

--== phantom damage, resets and late joiners ================================

-- Two games where the copy has heard from its owner: the owner dented beam 7.
local function syncedGames()
	local owner, copy, owners, copies = twoGames()
	step(2.5)
	dent(owner, 7, 0.8)
	step(1.5)
	same(copy.restLen[7], 0.8, "the owner's dent on the copy")
	return owner, copy, owners, copies
end

-- Damage only the copy's game simulated: n beams from `first` broken on the copy.
local function phantomBreaks(copy, first, n)
	for cid = first, first + n - 1 do
		copy.broken[cid] = true
		copy.beamstate.deformedBeams[cid] = 1
	end
	copy.beamstate.damage = copy.beamstate.damage + 1000
end

test("a copy with 25 beams of damage its owner never reported is reset and given the owner's damage", function()
	local owner, copy, owners, copies = syncedGames()
	local requestsBefore = #sentToServer("careerDamageRequest", 1)
	phantomBreaks(copy, 20, 25)
	step(4)
	expect(copy.veh.resets >= 1, "the copy was reset in place")
	same(#sentToServer("careerDamageRequest", 1) - requestsBefore, 1, "full-damage requests")
	same(copy.broken[30], nil, "a phantom break undone")
	same(copy.restLen[7], 0.8, "the owner's dent applied again")
end)

test("an owner's reset clears the dents and breaks on every copy", function()
	local owner, copy = syncedGames()
	owner.broken[9] = true
	owner.beamstate.damage = owner.beamstate.damage + 100
	step(1.5)
	same(copy.broken[9], true, "the owner's break on the copy")
	owner.reset()
	step(1.5)
	same(copy.restLen[7], 1, "the copy's beam 7")
	same(copy.broken[9], nil, "the copy's beam 9 whole again")
end)

test("a player who joins after a crash sees the car's dents", function()
	local owner, copy, owners, copies = syncedGames()
	local late = addGame(2)
	local lateCopy = addCar(late, 0, 0, {fwd = {x = 0, y = -1, z = 0}})
	step(3)
	same(lateCopy.restLen[7], 0.8, "the late joiner's beam 7")
end)

--== owner wins, on the copy's vehicle side =================================

-- The resets a copy's vehicle Lua asked for: {resync = n, cleared = n}.
local function resetRequests(car)
	local counts = {resync = 0, cleared = 0}
	for _, cmd in ipairs(car.game.geQueue) do
		local id, wantFull = cmd:match("^mileage_damageSync%.resetCopy%((%d+),(%d)%)$")
		if id then
			same(tonumber(id), car.gid, "car in the reset request")
			if wantFull == "1" then counts.resync = counts.resync + 1 else counts.cleared = counts.cleared + 1 end
		end
	end
	return counts
end

-- A copy that has heard from its owner: beams 0 to n-1 reported dented to 0.9.
local function heardCopy(n)
	local copy = copyCar({beams = 100})
	local rows = {}
	for cid = 0, (n or 30) - 1 do
		for _, x in ipairs({cid, 0.9, 0, 0.2}) do table.insert(rows, x) end
	end
	inVehicle(copy, copy.ext.applyDamage, 0, rows, {})
	return copy
end

test("applying the owner's own dents never starts a resync", function()
	local copy = heardCopy(30)
	tick(copy, 5)
	same(resetRequests(copy).resync, 0, "resyncs")
end)

test("21 beams broken on the copy while reported whole start a resync after two checks", function()
	local copy = heardCopy(30)
	for cid = 0, 20 do copy.broken[cid] = true end
	tick(copy, 1)
	same(resetRequests(copy).resync, 0, "resyncs after one check")
	tick(copy, 1)
	same(resetRequests(copy).resync, 1, "resyncs after two checks")
end)

test("21 beams more than 2 cm off the owner's rest length start a resync", function()
	local copy = heardCopy(30)
	for cid = 0, 20 do copy.restLen[cid] = 0.9 - 0.025 end
	tick(copy, 2)
	same(resetRequests(copy).resync, 1, "resyncs")
end)

-- Dents only the copy's game simulated, on beams first..last: plain dents, which the
-- game's damage tracker does not list.
local function phantomDents(copy, first, last, len)
	for cid = first, last do copy.restLen[cid] = len or 0.7 end
	copy.beamstate.damage = copy.beamstate.damage + 1000
end

test("one beam more than 5 mm off the owner's report starts a resync, one under 5 mm does not", function()
	local copy = heardCopy(30)
	for cid = 0, 29 do copy.restLen[cid] = 0.9 - 0.004 end
	copy.restLen[50] = 1.004
	copy.beamstate.damage = copy.beamstate.damage + 10
	tick(copy, 5)
	same(resetRequests(copy).resync, 0, "resyncs with every beam within 5 mm")
	copy.restLen[60] = 1 - 0.006
	copy.beamstate.damage = copy.beamstate.damage + 10
	tick(copy, 1)
	same(resetRequests(copy).resync, 0, "resyncs after one check")
	tick(copy, 1)
	same(resetRequests(copy).resync, 1, "resyncs after two checks")
end)

test("one beam broken on the copy while reported whole starts a resync after two checks", function()
	local copy = heardCopy(30)
	copy.broken[55] = true
	copy.beamstate.damage = copy.beamstate.damage + 10
	tick(copy, 1)
	same(resetRequests(copy).resync, 0, "resyncs after one check")
	tick(copy, 1)
	same(resetRequests(copy).resync, 1, "resyncs after two checks")
end)

test("25 plain dents the owner never reported start a resync", function()
	local copy = heardCopy(30)
	phantomDents(copy, 50, 74)
	tick(copy, 2)
	same(resetRequests(copy).resync, 1, "resyncs")
end)

test("25 beams broken by the copy's physics, outside the game's tracker, start a resync", function()
	local copy = heardCopy(30)
	for cid = 50, 74 do copy.broken[cid] = true end
	copy.beamstate.damage = copy.beamstate.damage + 1000
	tick(copy, 2)
	same(resetRequests(copy).resync, 1, "resyncs")
end)

test("damage that settles within one check starts no resync", function()
	local copy = heardCopy(30)
	phantomDents(copy, 50, 74)
	tick(copy, 1)
	inVehicle(copy, copy.ext.applyDamage, 0, (function()
		local rows = {}
		for cid = 50, 74 do for _, x in ipairs({cid, 0.7, 0, 0.5}) do table.insert(rows, x) end end
		return rows
	end)(), {})
	tick(copy, 3)
	same(resetRequests(copy).resync, 0, "resyncs once the owner reported the same damage")
end)

test("a second resync for the same car waits 10 seconds", function()
	local copy = heardCopy(30)
	phantomDents(copy, 50, 74)
	tick(copy, 2)
	same(resetRequests(copy).resync, 1, "first resync")
	tick(copy, 9.5)
	same(resetRequests(copy).resync, 1, "resyncs within 10 seconds of the first")
	tick(copy, 0.5)
	same(resetRequests(copy).resync, 2, "resyncs 10 seconds after the first")
end)

test("a copy that never heard from its owner never resyncs", function()
	local copy = copyCar({beams = 100})
	phantomDents(copy, 50, 99)
	for cid = 50, 99 do copy.broken[cid] = true end
	tick(copy, 5)
	same(resetRequests(copy).resync, 0, "resyncs")
end)

test("a cleared message resets a damaged copy and forgets its reports, and leaves an undamaged one alone", function()
	local copy = heardCopy(30)
	inVehicle(copy, copy.ext.applyDamage, 1, {}, {})
	same(resetRequests(copy).cleared, 1, "resets for a damaged copy")
	copy.game.geQueue = {}
	copy.reset()
	tick(copy, 3)
	same(resetRequests(copy).resync, 0, "resyncs once the reports are forgotten")
	inVehicle(copy, copy.ext.applyDamage, 1, {}, {})
	same(resetRequests(copy).cleared, 0, "resets for an undamaged copy")
end)

--== the owner's full damage ================================================

test("a full-damage answer covers every beam changed since the car was built, 400 a message", function()
	local car = ownerCar({beams = 1000})
	tick(car)
	takeMessages(car)
	for cid = 0, 999 do car.restLen[cid] = 0.9 end
	car.beamstate.damage = 1000
	for _ = 1, 3 do tick(car) end
	takeMessages(car)
	inVehicle(car, car.ext.sendFull)
	local counts = {}
	for _ = 1, 4 do
		tick(car)
		for _, m in ipairs(takeMessages(car)) do table.insert(counts, math.floor(#m.b / 4)) end
	end
	same(table.concat(counts, ","), "400,400,200", "beams per message")
end)

test("a repair that empties the damage total sends a cleared message", function()
	local car = ownerCar()
	tick(car)
	takeMessages(car)
	dent(car, 7, 0.8)
	tick(car)
	takeMessages(car)
	car.restLen[7] = 1
	car.beamstate.damage = 0
	tick(car)
	local m = takeMessages(car)
	same(#m, 1, "messages")
	same(m[1].c, 1, "cleared")
end)

test("a copy only answers requests for this game's own owner cars", function()
	local owner, copy, owners, copies = twoGames()
	step(3)
	local before = #sentToServer("careerDamage", 1)
	as(copies, copies.handlers.rxCareerDamageRequest, '{"v":"0-0"}')
	step(1)
	same(#sentToServer("careerDamage", 1) - before, 0, "messages from the copy's game")
end)

--== limits, bad input and lifecycle =======================================

test("the server passes at most 4 full-damage requests a second from one player", function()
	threeGames()
	for _ = 1, 6 do careerDamageRequest(1, '{"v":"2-5"}') end
	same(#serverSends("rxCareerDamageRequest"), 4, "requests passed on")
	world.now = (world.now or 0) + 1
	careerDamageRequest(1, '{"v":"2-5"}')
	same(#serverSends("rxCareerDamageRequest"), 5, "a second later")
end)

test("the server drops a full-damage request over 256 bytes", function()
	threeGames()
	careerDamageRequest(1, '{"v":"2-5","x":"' .. string.rep("a", 260) .. '"}')
	same(#serverSends("rxCareerDamageRequest"), 0, "requests passed on")
end)

test("a damage message over 32 KB is not sent, and that is logged once", function()
	local owner, copy, owners = twoGames()
	step(4)
	local before = #sentToServer("careerDamage", 0)
	local big = '{"c":0,"b":[' .. string.rep("1,", 17000) .. '1],"n":[]}'
	as(owners, owners.ge.onLocalDamage, owner.gid, big)
	as(owners, owners.ge.onLocalDamage, owner.gid, big)
	step(2)
	same(#sentToServer("careerDamage", 0) - before, 0, "messages sent")
	same(countLines(logs, "was not sent (limit 32768)"), 1, "warnings")
end)

test("more than 30 queued messages are dropped and the owner car sends its full damage again", function()
	local owner, copy, owners = twoGames()
	step(2.5)
	local before = #sentToServer("careerDamage", 0)
	for _ = 1, 31 do as(owners, owners.ge.onLocalDamage, owner.gid, '{"c":0,"b":[],"n":[]}') end
	same(countLines(owner.vehicleQueue, "mileageDamage.sendFull(1)"), 1, "cleared-then-full requests to the owner car")
	same(countLines(logs, "full damage sent again"), 1, "warnings")
	step(15)
	local all = sentToServer("careerDamage", 0)
	local sent = #all - before
	-- At most: the owner's announcement still leaving, the message that overflowed, a
	-- cleared notice and the (empty) full damage.
	expect(sent >= 1 and sent <= 4, "messages sent after the queue was dropped: " .. sent)
	local cleared = 0
	for i = before + 1, #all do
		if string.find(all[i].data, '"c":1', 1, true) then cleared = cleared + 1 end
	end
	same(cleared, 1, "cleared notices sent after the drop")
end)

test("a reset request for a car that is not a copy changes nothing", function()
	local owner, copy, owners = twoGames()
	step(2.5)
	as(owners, owners.ge.resetCopy, owner.gid, 1)
	as(owners, owners.ge.resetCopy, 999, 1)
	same(owner.veh.resets, 0, "resets of the player's own car")
end)

test("a respawned copy asks its owner for full damage again", function()
	local owner, copy, owners, copies = twoGames()
	step(3)
	same(#sentToServer("careerDamageRequest", 1), 1, "requests before the respawn")
	as(copies, copies.ge.onVehicleSpawned, copy.gid)
	step(1.5)
	same(#sentToServer("careerDamageRequest", 1), 2, "requests after the respawn")
end)

test("leaving the server drops the damage messages still queued", function()
	local owner, copy, owners = twoGames()
	step(2.5)
	local before = #sentToServer("careerDamage", 0)
	for _ = 1, 5 do as(owners, owners.ge.onLocalDamage, owner.gid, '{"c":0,"b":[],"n":[]}') end
	as(owners, owners.ge.onBeamMPServerLeave)
	for _ = 1, 4 do as(owners, owners.ge.onUpdate, 0.2); pump() end
	same(#sentToServer("careerDamage", 0) - before, 0, "messages sent after leaving")
end)

test("a full-damage request for this game's own traffic car is not answered", function()
	newWorld()
	local game = addGame(0)
	local traffic = addCar(game, 0, 1, {isTraffic = "true"})
	step(3)
	as(game, game.handlers.rxCareerDamageRequest, '{"v":"' .. traffic.sid .. '"}')
	same(countLines(traffic.vehicleQueue, "sendFull"), 0, "full-damage answers queued")
end)

test("a copy applies a rest length of 100 m and offsets of 20 m, and refuses 0 m and just past 20 m", function()
	local copy = copyCar()
	inVehicle(copy, copy.ext.applyDamage, 0, {7, 100, 0, 0, 8, 0, 0, 0}, {4, 20, -20, 20, 5, 20.01, 0, 0})
	same(copy.restLen[7], 100, "beam 7 at 100 m")
	same(copy.restLen[8], 1, "beam 8 left alone")
	local x, y, z = toCarFrame(copy, copy.nodePos[4])
	expect(math.abs(x - 20) < 1e-6 and math.abs(y + 20) < 1e-6 and math.abs(z - 20) < 1e-6, "point 4 placed at the limit")
	local fx = toCarFrame(copy, copy.nodePos[5])
	expect(math.abs(fx - 20.01) > 1e-3, "point 5 left alone")
end)

test("a copy given no beam or point lists changes nothing and does not raise", function()
	local copy = copyCar()
	inVehicle(copy, copy.ext.applyDamage, 0, nil, nil)
	inVehicle(copy, copy.ext.applyDamage, 0, {7, 0.5, 0, 0}, nil)
	same(copy.restLen[7], 1, "beam 7")
end)

test("an owner whose direction cannot be read keeps its changes and sends them once it can", function()
	local car = ownerCar()
	tick(car)
	takeMessages(car)
	local fwd = car.fwd
	car.fwd = {x = 0, y = 0, z = 0}
	dent(car, 7, 0.8)
	tick(car)
	same(#takeMessages(car), 0, "messages without a frame")
	car.fwd = fwd
	tick(car)
	local m = takeMessages(car)
	same(#m, 1, "messages once the frame is back")
	same(table.concat(beamIds(m[1]), ","), "7", "beams")
end)

--== found in review =========================================================

test("a cleared message resets a copy that carries the owner's plain dents and breaks", function()
	local copy = copyCar({beams = 100})
	-- The game's breakBeam does not write beamstate's tracker.
	function copy.obj:breakBeam(cid) copy.breakCalls = copy.breakCalls + 1; copy.broken[cid] = true end
	inVehicle(copy, copy.ext.applyDamage, 0, {7, 0.8, 0, 0, 9, 1, 1, 0}, {})
	same(copy.restLen[7], 0.8, "the owner's dent applied")
	same(copy.broken[9], true, "the owner's break applied")
	copy.game.geQueue = {}
	inVehicle(copy, copy.ext.applyDamage, 1, {}, {})
	same(resetRequests(copy).cleared, 1, "resets for a copy still dented and broken")
end)

test("a player who joins a server with default traffic still gets the owner's dents", function()
	local owner, copy, owners, copies = syncedGames()
	-- The owner's game runs its share of traffic: 6 road and 8 parked cars by default.
	for vid = 1, 14 do
		addCar(owners, 0, vid, {isTraffic = "true"})
		addCar(copies, 0, vid)
	end
	step(3)
	local late = addGame(2)
	for vid = 1, 14 do addCar(late, 0, vid) end
	local lateCopy = addCar(late, 0, 0, {fwd = {x = 0, y = -1, z = 0}})
	local before = #sentToServer("careerDamageRequest", 2)
	step(1)
	local firstSecond = #sentToServer("careerDamageRequest", 2) - before
	expect(firstSecond <= 4, "requests sent in the first second: " .. firstSecond)
	step(15)
	same(lateCopy.restLen[7], 0.8, "the late joiner's beam 7")
end)

test("a full-damage request with no answer is asked again, at most four times", function()
	newWorld()
	local owners, copies = addGame(0), addGame(1)
	-- An owner on an older Mileage: its game has no damage module answering.
	owners.handlers.rxCareerDamageRequest = nil
	addCar(owners, 0, 0)
	addCar(copies, 0, 0)
	owners.ge.onUpdate = nil
	step(30)
	same(#sentToServer("careerDamageRequest", 1), 4, "requests from the copy's game")
end)

test("a beam that changes during a full transfer is sent again afterwards", function()
	local car = ownerCar({beams = 1000})
	tick(car)
	takeMessages(car)
	for cid = 0, 999 do car.restLen[cid] = 0.9 end
	car.beamstate.damage = 1000
	inVehicle(car, car.ext.sendFull)
	tick(car)
	takeMessages(car)
	-- Beam 5 went out in the first chunk; it changes while the rest is still going.
	car.restLen[5] = 0.6
	local resent = false
	for _ = 1, 4 do
		tick(car)
		for _, m in ipairs(takeMessages(car)) do
			for i = 1, #m.b, 4 do
				if m.b[i] == 5 and m.b[i + 1] == 0.6 then resent = true end
			end
		end
	end
	same(resent, true, "beam 5 sent again with its new length")
end)

test("a copy reset in place keeps the rotation BeamMP's own reset gives it", function()
	local owner, copy, owners, copies = twoGames()
	step(2)
	-- Real quaternion maths: Hamilton product, and a rotation from the car's axes.
	local Q = {}
	Q.__index = Q
	local function rq(x, y, z, w) return setmetatable({x = x, y = y, z = z, w = w}, Q) end
	Q.__mul = function(a, b)
		return rq(a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
			a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
			a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
			a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
	end
	local function fromDir(d, u)
		local fl = math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
		local f = {x = d.x / fl, y = d.y / fl, z = d.z / fl}
		local r = {x = f.y * u.z - f.z * u.y, y = f.z * u.x - f.x * u.z, z = f.x * u.y - f.y * u.x}
		local rl = math.sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
		r = {x = r.x / rl, y = r.y / rl, z = r.z / rl}
		local up = {x = r.y * f.z - r.z * f.y, y = r.z * f.x - r.x * f.z, z = r.x * f.y - r.y * f.x}
		local m00, m01, m02 = r.x, f.x, up.x
		local m10, m11, m12 = r.y, f.y, up.y
		local m20, m21, m22 = r.z, f.z, up.z
		local w = math.sqrt(math.max(0, 1 + m00 + m11 + m22)) / 2
		local x = math.sqrt(math.max(0, 1 + m00 - m11 - m22)) / 2
		local y = math.sqrt(math.max(0, 1 - m00 + m11 - m22)) / 2
		local z = math.sqrt(math.max(0, 1 - m00 - m11 + m22)) / 2
		if m21 - m12 < 0 then x = -x end
		if m02 - m20 < 0 then y = -y end
		if m10 - m01 < 0 then z = -z end
		return rq(x, y, z, w)
	end
	local saveQuat, saveFromDir = quat, quatFromDir
	quat, quatFromDir = rq, fromDir
	local got
	copy.veh.setPositionRotation = function(self, x, y, z, rx, ry, rz, rw) got = {rx, ry, rz, rw} end
	-- BeamMP's own reset of another player's car (MPVehicleGE onVehicleResetted sends it).
	local want = fromDir(-vec3(copy.fwd), vec3(copy.up))
	local ok, err = pcall(as, copies, copies.ge.resetCopy, copy.gid, 0)
	quat, quatFromDir = saveQuat, saveFromDir
	assert(ok, err)
	expect(got ~= nil, "setPositionRotation was called")
	local dot = got[1] * want.x + got[2] * want.y + got[3] * want.z + got[4] * want.w
	expect(math.abs(math.abs(dot) - 1) < 1e-6, string.format("rotation differs from BeamMP's reset; |dot| = %.3f", math.abs(dot)))
end)

--== no requests for another player's traffic ================================

-- Player 0's cars 0-0 to 0-(n-1) on both games, their owner answering nothing (as
-- traffic never does), and the server's traffic marks as `traffic` says.
local function trafficOwner(n, traffic)
	newWorld()
	local owners, copies = addGame(0), addGame(1)
	owners.handlers.rxCareerDamageRequest = nil
	owners.ge.onUpdate = nil
	for vid = 0, n - 1 do
		addCar(owners, 0, vid)
		addCar(copies, 0, vid)
	end
	enabler.isRemoteTraffic = function(sid) return traffic[sid] == true end
	return copies
end

local function requestsFrom1(sid)
	local n = 0
	for _, m in ipairs(sentToServer("careerDamageRequest", 1)) do
		if m.data == '{"v":"' .. sid .. '"}' then n = n + 1 end
	end
	return n
end

test("a copy of another player's traffic is never asked for its full damage, a real car's copy is", function()
	trafficOwner(2, {["0-1"] = true})
	step(30)
	same(requestsFrom1("0-1"), 0, "requests for the traffic car")
	same(requestsFrom1("0-0"), 4, "requests for the real car, retried as today")
end)

test("a copy marked as traffic after it was first asked for is not asked again", function()
	local traffic = {}
	trafficOwner(1, traffic)
	step(2)
	same(requestsFrom1("0-0"), 1, "requests before the mark")
	traffic["0-0"] = true
	step(30)
	same(requestsFrom1("0-0"), 1, "requests after the mark")
end)

test("requests still queued for cars the server then marks as traffic are dropped", function()
	local traffic = {}
	trafficOwner(9, traffic)
	step(1)
	local before = #sentToServer("careerDamageRequest", 1)
	expect(before < 9, "requests already sent: " .. before)
	for vid = 0, 8 do traffic["0-" .. vid] = true end
	step(30)
	same(#sentToServer("careerDamageRequest", 1), before, "requests sent after the marks")
end)

test("with an enabler that cannot tell traffic, copies are asked for as today", function()
	trafficOwner(1, {})
	enabler.isRemoteTraffic = nil
	step(30)
	same(requestsFrom1("0-0"), 4, "requests for the car")
end)

--== full-damage requests and the copy's check, second review ===============

-- Requests the copy's game (player 1) sent for one car.
local function requestsFor(sid)
	local n = 0
	for _, m in ipairs(sentToServer("careerDamageRequest", 1)) do
		if m.data == '{"v":"' .. sid .. '"}' then n = n + 1 end
	end
	return n
end

-- Player 0 on an older Mileage (nothing answers a request), and player 1's copies of
-- player 0's cars 0-0 to 0-(n-1).
local function silentOwner(n)
	newWorld()
	local owners, copies = addGame(0), addGame(1)
	owners.handlers.rxCareerDamageRequest = nil
	owners.ge.onUpdate = nil
	local cars = {}
	for vid = 0, n - 1 do
		addCar(owners, 0, vid)
		cars[vid] = addCar(copies, 0, vid)
	end
	return copies, cars
end

test("a full-damage request the owner answers is not asked again", function()
	local owner, copy, owners, copies = twoGames()
	step(30)
	same(#sentToServer("careerDamageRequest", 1), 1, "requests from the copy's game")
end)

test("a copy removed before its owner answers is not asked for again", function()
	local copies, cars = silentOwner(1)
	step(2)
	same(requestsFor("0-0"), 1, "requests before the copy is removed")
	local copy = cars[0]
	copies.cars[copy.gid], copies.objects[copy.gid], copies.vehicles[copy.sid] = nil, nil, nil
	as(copies, copies.ge.onVehicleDestroyed, copy.gid)
	step(30)
	same(requestsFor("0-0"), 1, "requests after the copy is removed")
end)

test("leaving the server drops the full-damage requests still waiting", function()
	local copies = silentOwner(10)
	step(1)
	local before = #sentToServer("careerDamageRequest", 1)
	expect(before < 10, "requests already sent when leaving: " .. before)
	as(copies, copies.ge.onBeamMPServerLeave)
	-- Off the server BeamMP lists no cars.
	copies.vehicles = {}
	step(30)
	same(#sentToServer("careerDamageRequest", 1) - before, 0, "requests sent after leaving")
end)

test("a car asked for twice while its first request still waits is asked for once", function()
	local copies, cars = silentOwner(6)
	step(1)
	local waiting
	for vid = 0, 5 do
		if requestsFor("0-" .. vid) == 0 then waiting = vid end
	end
	expect(waiting ~= nil, "a request still queued")
	-- That copy drifts from its owner and asks again before its first request went out.
	as(copies, copies.ge.resetCopy, cars[waiting].gid, 1)
	pump()
	step(3)
	same(requestsFor("0-" .. waiting), 1, "requests for 0-" .. waiting)
end)

test("phantom damage after quiet checks is still counted", function()
	local copy = heardCopy(30)
	tick(copy, 3)
	phantomDents(copy, 50, 74)
	tick(copy, 2)
	same(resetRequests(copy).resync, 1, "resyncs")
end)

test("a copy whose damage and reports have not moved does not read its beams again", function()
	local copy = heardCopy(30)
	tick(copy, 1)
	local reads = 0
	local read = copy.obj.getBeamRestLength
	function copy.obj:getBeamRestLength(cid) reads = reads + 1; return read(self, cid) end
	tick(copy, 5)
	same(reads, 0, "beam reads over five quiet checks")
end)

test("an owner's repair after a light scrape shows on the copy", function()
	local owner, copy = twoGames({beams = 100})
	step(2.5)
	-- A scrape: 30 beams each 1.5 cm shorter, under the phantom check's 2 cm.
	for cid = 0, 29 do dent(owner, cid, 0.985) end
	step(1.5)
	same(copy.restLen[3], 0.985, "the owner's scrape on the copy")
	-- The repair: every beam as built and the damage total back to nothing.
	for cid = 0, 29 do owner.restLen[cid] = 1 end
	owner.beamstate.damage = 0
	step(2)
	same(copy.restLen[3], 1, "the copy's beam 3 after the owner's repair")
end)

test("a flag that does not follow the car id at once is no answer, and goes to every other player", function()
	threeGames()
	careerDamageRequest(2, '{"v":"0-3"}')
	world.serverSent = {}
	careerDamage(0, '{"v":"0-3","c":0,"f":1,"b":[],"n":[]}')
	same(targetsOf(serverSends("rxCareerDamage")), "1,2", "a message with the flag further on")
end)

test("askers kept by an answer's chunks are dropped 5 seconds after its last chunk, and the next flagged chunk goes to everyone", function()
	threeGames()
	addGame(3)
	world.now = 0
	careerDamageRequest(1, '{"v":"0-3"}')
	careerDamageRequest(2, '{"v":"0-3"}')
	for t = 1, 8 do
		world.now = t
		world.serverSent = {}
		careerDamage(0, '{"v":"0-3","f":1,"c":0,"b":[],"n":[]}')
		same(targetsOf(serverSends("rxCareerDamage")), "1,2", "a flagged chunk at " .. t .. " s")
	end
	world.now = 12.5
	world.serverSent = {}
	careerDamage(0, '{"v":"0-3","f":1,"c":0,"b":[],"n":[]}')
	same(targetsOf(serverSends("rxCareerDamage")), "1,2", "a flagged chunk 4.5 s after the last one")
	world.now = 18
	world.serverSent = {}
	careerDamage(0, '{"v":"0-3","f":1,"c":0,"b":[],"n":[]}')
	same(targetsOf(serverSends("rxCareerDamage")), "1,2,3", "a flagged chunk 5.5 s after that, nobody waiting")
end)

test("an answer with no new dents sends a chunk every half second and nothing for everyone", function()
	local car = soloCar({beams = 1700, nodes = 50})
	for cid = 0, 1599 do dent(car, cid, 0.8) end
	inVehicle(car, car.ext.setRole, "owner")
	tick(car, 3)
	rawMessages(car)
	inVehicle(car, car.ext.answerFull)
	tick(car, 2)
	local messages = rawMessages(car)
	local flagged = 0
	for _, m in ipairs(messages) do
		if m:sub(1, 7) == '{"f":1,' then flagged = flagged + 1 end
	end
	same(flagged, 4, "answer chunks of 1600 beams in four half-second ticks")
	same(#messages, 4, "messages in those ticks")
	tick(car, 1)
	same(#rawMessages(car), 0, "messages once the answer is done, with nothing changed")
end)

test("an answer still finishes while the car is dented every half second", function()
	local car = soloCar({beams = 1700, nodes = 50})
	for cid = 0, 1599 do dent(car, cid, 0.8) end
	inVehicle(car, car.ext.setRole, "owner")
	tick(car, 3)
	rawMessages(car)
	inVehicle(car, car.ext.answerFull)
	local answered, dentsSent = {}, {}
	for k = 0, 9 do
		dent(car, 1600 + k, 0.7)
		tick(car, 0.5)
		for _, m in ipairs(rawMessages(car)) do
			local message = jsonToLua(m)
			for i = 1, #message.b, 4 do
				if m:sub(1, 7) == '{"f":1,' then
					answered[message.b[i]] = true
				else
					dentsSent[message.b[i]] = true
				end
			end
		end
	end
	local missing = 0
	for cid = 0, 1599 do if not answered[cid] then missing = missing + 1 end end
	same(missing, 0, "beams of the answer not sent after 5 s of dents")
	for k = 0, 9 do expect(dentsSent[1600 + k], "dent on beam " .. (1600 + k) .. " sent for everyone") end
end)

--== a still car's copy is put right, whatever it differs by =================

test("a wheel lost on the copy of a still car (8 beams broken) is put right", function()
	local owner, copy = syncedGames()
	phantomBreaks(copy, 30, 8)
	step(30)
	same(copy.broken[30], nil, "the lost wheel's beam 30 on the copy after 30 s")
	same(copy.restLen[7], 0.8, "the owner's dent on the copy again")
end)

test("a single 3 cm dent only the copy has is put right", function()
	local owner, copy = syncedGames()
	copy.restLen[40] = 0.97
	copy.beamstate.damage = copy.beamstate.damage + 50
	step(30)
	same(copy.restLen[40], 1, "the copy's beam 40 after 30 s")
	same(copy.restLen[7], 0.8, "the owner's dent on the copy again")
end)

--== beams the game lengthens on its own =====================================

-- A copy that heard from its owner, with beam 70 a steering hydraulic and 71 a beam
-- that settles after spawn.
local function heardCopyWithHydros()
	local copy = copyCar({beams = 100, hydros = {70}, settling = {71}})
	inVehicle(copy, copy.ext.applyDamage, 0, {7, 0.9, 0, 0.2}, {})
	return copy
end

test("a steering hydraulic's length, or a settling beam's, never starts a resync", function()
	local copy = heardCopyWithHydros()
	copy.restLen[70] = 1.03
	copy.restLen[71] = 0.96
	copy.beamstate.damage = copy.beamstate.damage + 10
	tick(copy, 5)
	same(resetRequests(copy).resync, 0, "resyncs")
end)

test("a hydraulic beam broken on the copy while whole on the owner starts a resync", function()
	local copy = heardCopyWithHydros()
	copy.broken[70] = true
	copy.beamstate.damage = copy.beamstate.damage + 10
	tick(copy, 2)
	same(resetRequests(copy).resync, 1, "resyncs")
end)

test("an owner never sends a hydraulic's or settling beam's length, and sends their breaks", function()
	local car = ownerCar({hydros = {5}, settling = {6}})
	tick(car)
	takeMessages(car)
	car.restLen[5] = 1.05
	car.restLen[6] = 0.9
	dent(car, 7, 0.8)
	tick(car)
	same(table.concat(beamIds(takeMessages(car)[1]), ","), "7", "beams sent for a dent while steering")
	car.broken[5], car.broken[6] = true, true
	car.beamstate.damage = car.beamstate.damage + 50
	tick(car)
	local m = takeMessages(car)[1]
	same(table.concat(beamIds(m), ","), "5,6", "beams sent once they break")
	same(m.b[3], 1, "beam 5 broken")
	same(m.b[7], 1, "beam 6 broken")
end)

test("a hydraulic beam broken on the owner reaches the copy broken, its length left to the copy", function()
	local owner, copy = twoGames({hydros = {5}})
	step(2.5)
	owner.restLen[5] = 1.04
	owner.broken[5] = true
	owner.beamstate.damage = owner.beamstate.damage + 100
	step(1.5)
	same(copy.broken[5], true, "the copy's hydraulic beam 5 broken")
	same(copy.restLen[5], 1, "the copy's hydraulic beam 5 length")
end)

--== the owner's full damage as one whole shape =============================

-- Points of `car` more than 2 mm from where they are on `owner`, each in its car's own frame.
local function pointsOff(owner, car)
	local off = {}
	for cid in pairs(owner.v.data.nodes) do
		local ox, oy, oz = toCarFrame(owner, owner.nodePos[cid])
		local cx, cy, cz = toCarFrame(car, car.nodePos[cid])
		if math.abs(ox - cx) > 0.002 or math.abs(oy - cy) > 0.002 or math.abs(oz - cz) > 0.002 then
			table.insert(off, cid)
		end
	end
	return off
end

-- Nudges every point of a car but its reference point by dz metres up, in its own frame:
-- a copy whose physics rests at another suspension height.
local function nudgePoints(car, dz)
	for cid in pairs(car.v.data.nodes) do
		if cid ~= 0 then
			local x, y, z = toCarFrame(car, car.nodePos[cid])
			car.nodePos[cid] = fromCarFrame(car, x, y, z + dz)
		end
	end
end

test("a damaged still car's copy, reset, gets every point of his car", function()
	local owner, copy = syncedGames()
	nudgePoints(copy, 0.05)
	copy.applyLog, copy.commits = {}, 0
	phantomBreaks(copy, 30, 1)
	step(10)
	expect(copy.veh.resets >= 1, "the copy was reset in place")
	same(#pointsOff(owner, copy), 0, "points of the copy away from the owner's car")
	same(copy.commits, 1, "commits of the owner's damage")
	same(copy.restLen[7], 0.8, "the owner's dent on the copy")
end)

-- An owner of 600 points and 300 beams, each beam with points of its own, beams 0-9 dented.
local function bigDentedOwner()
	local car = soloCar({beams = 300, nodes = 600, separate = true})
	for cid = 0, 9 do dent(car, cid, 0.8) end
	return car
end

-- The point ids in a decoded message.
local function pointIds(message)
	local ids = {}
	for i = 1, #message.n, 4 do table.insert(ids, message.n[i]) end
	return ids
end

test("a full send carries every point of the car in numbered parts", function()
	local car = bigDentedOwner()
	inVehicle(car, car.ext.setRole, "owner")
	tick(car, 2)
	local sent = rawMessages(car)
	same(#sent, 2, "parts of the full send for everyone")
	same(sent[1]:sub(1, 20), '{"c":0,"p":1,"t":2,"', "the first part")
	same(sent[2]:sub(1, 20), '{"c":0,"p":2,"t":2,"', "the second part")
	local points, beams = {}, {}
	for _, m in ipairs(sent) do
		local message = jsonToLua(m)
		expect(#message.n / 4 <= 500, "points in a part: " .. #message.n / 4)
		for _, id in ipairs(pointIds(message)) do points[id] = true end
		for _, id in ipairs(beamIds(message)) do beams[#beams + 1] = id end
	end
	local count = 0
	for _ in pairs(points) do count = count + 1 end
	same(count, 600, "points of the car in the full send")
	same(table.concat(beams, ","), "0,1,2,3,4,5,6,7,8,9", "beams in the full send")
	inVehicle(car, car.ext.answerFull)
	tick(car, 2)
	local answer = rawMessages(car)
	same(#answer, 2, "parts of the answer")
	same(answer[1]:sub(1, 26), '{"f":1,"c":0,"p":1,"t":2,"', "the answer's first part, flagged first")
	same(answer[2]:sub(1, 26), '{"f":1,"c":0,"p":2,"t":2,"', "the answer's second part")
end)

--== the copy applies a whole set at once ====================================

-- The two parts of bigDentedOwner's answer, decoded, and a copy of the same car.
local function wholeAnswerAndCopy()
	local owner = bigDentedOwner()
	inVehicle(owner, owner.ext.setRole, "owner")
	tick(owner, 2)
	takeMessages(owner)
	inVehicle(owner, owner.ext.answerFull)
	tick(owner, 2)
	local parts = takeMessages(owner)
	same(#parts, 2, "parts of the answer")
	local copy = copyCar({beams = 300, nodes = 600, separate = true})
	return parts, copy
end

local function applyPart(copy, m)
	inVehicle(copy, copy.ext.applyDamage, m.c, m.b, m.n, m.p, m.t)
end

test("a whole-shape answer moves every point and commits once, after its last part", function()
	local parts, copy = wholeAnswerAndCopy()
	applyPart(copy, parts[1])
	same(#copy.applyLog, 0, "changes to the copy after the first of two parts")
	applyPart(copy, parts[2])
	local points, lastPoint, firstBeam = {}, 0, nil
	for i, entry in ipairs(copy.applyLog) do
		if entry[1] == "node" then
			points[entry[2]] = true
			lastPoint = i
		elseif entry[1] == "beam" and not firstBeam then
			firstBeam = i
		end
	end
	local count = 0
	for _ in pairs(points) do count = count + 1 end
	same(count, 600, "points of the copy set")
	expect(firstBeam and firstBeam > lastPoint, "every point is set before any beam")
	same(copy.commits, 1, "commits")
	same(copy.applyLog[#copy.applyLog][1], "commit", "the commit comes last")
	same(copy.restLen[3], 0.8, "the owner's dent on the copy")
	same(countLines(copy.game.geQueue, "mileage_damageSync.shapeApplied(" .. copy.gid .. ")"), 1, "the copy's wait ended")
end)

test("a part that does not follow the one before applies nothing", function()
	local parts, copy = wholeAnswerAndCopy()
	applyPart(copy, parts[2])
	applyPart(copy, parts[1])
	applyPart(copy, parts[1])
	same(#copy.applyLog, 0, "changes to the copy")
	same(countLines(copy.game.geQueue, "shapeApplied"), 0, "waits ended")
end)

test("an incomplete set is dropped 5 s after its latest part, or by a cleared notice", function()
	local parts, copy = wholeAnswerAndCopy()
	applyPart(copy, parts[1])
	tick(copy, 4.5)
	applyPart(copy, parts[1])
	tick(copy, 5)
	applyPart(copy, parts[2])
	same(#copy.applyLog, 0, "changes to the copy after 5 s without a part")
	applyPart(copy, parts[1])
	inVehicle(copy, copy.ext.applyDamage, 1, {}, {})
	applyPart(copy, parts[2])
	same(#copy.applyLog, 0, "changes to the copy after a cleared notice")
	same(countLines(copy.game.geQueue, "shapeApplied"), 0, "waits ended")
end)

test("a set still arriving 4.5 s after its first part is applied", function()
	local parts, copy = wholeAnswerAndCopy()
	applyPart(copy, parts[1])
	tick(copy, 4.5)
	applyPart(copy, parts[2])
	same(copy.commits, 1, "commits")
end)

test("ordinary dents that arrive while a set is incomplete are applied after it", function()
	local parts, copy = wholeAnswerAndCopy()
	applyPart(copy, parts[1])
	inVehicle(copy, copy.ext.applyDamage, 0, {3, 0.75, 0, 0.3}, {})
	same(copy.restLen[3], 1, "the dent held while the set is incomplete")
	applyPart(copy, parts[2])
	same(copy.commits, 1, "commits")
	same(copy.restLen[3], 0.75, "the newer dent on top of the set")
end)

test("a part number that is not a whole number from 1 to 64, or past its set, is dropped", function()
	local owner, copy, owners, copies = twoGames()
	step(2)
	for _, pt in ipairs({'"p":0,"t":1', '"p":65,"t":65', '"p":2,"t":1', '"p":1.5,"t":2', '"p":"1","t":1',
			'"p":1', '"t":1', '"p":1,"t":"1);injected();("'}) do
		deliver(copies, '{"v":"0-0","c":0,' .. pt .. ',"b":[7,0.5,0,0.3],"n":[]}')
	end
	same(#copy.applyLog, 0, "changes to the copy")
	deliver(copies, '{"v":"0-0","c":0,"p":1,"t":1,"b":[7,0.5,0,0.3],"n":[]}')
	same(copy.restLen[7], 0.5, "a well-numbered part applies")
	same(copy.commits, 1, "commits")
end)

test("a set whose middle part is lost, though its last part arrives, is asked for again", function()
	local owner, copy, owners, copies = twoGames({beams = 300, nodes = 1200, separate = true})
	for cid = 0, 9 do dent(owner, cid, 0.8) end
	nudgePoints(copy, 0.05)
	local rx, dropped = copies.handlers.rxCareerDamage, 0
	copies.handlers.rxCareerDamage = function(data)
		if dropped == 0 and data:find('"p":2,', 1, true) then dropped = 1; return end
		return rx(data)
	end
	step(4)
	same(dropped, 1, "middle parts lost")
	same(copy.commits, 0, "commits of a set missing its middle part")
	-- A dent while he drives does not end the wait for his full damage.
	dent(owner, 20, 0.7)
	step(26)
	same(requestsFor("0-0"), 2, "requests from the copy's game")
	same(copy.commits, 1, "commits")
	same(#pointsOff(owner, copy), 0, "points of the copy away from the owner's car")
	same(copy.restLen[20], 0.7, "the dent while he drove")
end)

test("a set longer than 5 s is not asked for again while its parts still arrive", function()
	local owner, copy = twoGames({beams = 300, nodes = 5000, separate = true})
	for cid = 0, 9 do dent(owner, cid, 0.8) end
	step(30)
	same(requestsFor("0-0"), 1, "requests from the copy's game")
	same(copy.commits, 1, "commits")
end)

--== whole-shape edges ========================================================

-- The full send for everyone of a new owner `car`, raw, after `seconds` of ticks.
local function newOwnerFullSend(car, seconds)
	inVehicle(car, car.ext.setRole, "owner")
	tick(car, seconds or 2)
	return rawMessages(car)
end

test("a full send of exactly 500 points is one part, of 501 points two parts with every point once", function()
	for _, count in ipairs({500, 501}) do
		local car = soloCar({nodes = count})
		dent(car, 7, 0.8)
		local sent = newOwnerFullSend(car)
		local wanted = count == 500 and 1 or 2
		same(#sent, wanted, count .. " points: parts")
		same(sent[1]:sub(1, 20), '{"c":0,"p":1,"t":' .. wanted .. ',"', count .. " points: the first part")
		local seen, total = {}, 0
		for _, m in ipairs(sent) do
			for _, id in ipairs(pointIds(jsonToLua(m))) do
				expect(not seen[id], count .. " points: point " .. id .. " sent twice")
				seen[id], total = true, total + 1
			end
		end
		same(total, count, count .. " points: points in the full send")
	end
end)

test("a full send of 401 changed beams on a car of 100 points is two parts, and the copy applies every beam once", function()
	local owner = soloCar({beams = 401, nodes = 100})
	for cid = 0, 400 do dent(owner, cid, 0.8) end
	inVehicle(owner, owner.ext.setRole, "owner")
	tick(owner, 2)
	local parts = takeMessages(owner)
	same(#parts, 2, "parts")
	same(#parts[1].b / 4, 400, "beams in the first part")
	same(#parts[2].b / 4, 1, "beams in the second part")
	same(#parts[1].n / 4 + #parts[2].n / 4, 100, "points in the two parts")
	same(parts[2].p .. "/" .. parts[2].t, "2/2", "the second part's number")
	local copy = copyCar({beams = 401, nodes = 100})
	applyPart(copy, parts[1])
	same(copy.commits, 0, "commits after the first part")
	applyPart(copy, parts[2])
	same(copy.commits, 1, "commits")
	same(copy.restLen[0], 0.8, "the copy's beam 0")
	same(copy.restLen[400], 0.8, "the copy's beam 400, alone in the second part")
end)

test("a car whose whole shape needs more than 64 parts sends no part, logs it once, and still sends its dents", function()
	local car = soloCar({nodes = 32001})
	dent(car, 7, 0.8)
	local sent = newOwnerFullSend(car)
	inVehicle(car, car.ext.answerFull)
	tick(car, 2)
	for _, m in ipairs(rawMessages(car)) do table.insert(sent, m) end
	local numbered, dents = 0, 0
	for _, m in ipairs(sent) do
		if m:find('"p":', 1, true) then numbered = numbered + 1 end
		local ids = beamIds(jsonToLua(m))
		if ids[1] == 7 then dents = dents + 1 end
	end
	same(numbered, 0, "numbered parts sent")
	same(countLines(logs, "and is not sent whole"), 1, "warnings")
	same(dents, 1, "messages with the dent on beam 7")
end)

test("a part that names another number of parts than the set it follows applies nothing", function()
	local parts, copy = wholeAnswerAndCopy()
	applyPart(copy, parts[1])
	inVehicle(copy, copy.ext.applyDamage, 0, parts[2].b, parts[2].n, 2, 3)
	applyPart(copy, parts[2])
	same(#copy.applyLog, 0, "changes to the copy")
	same(countLines(copy.game.geQueue, "shapeApplied"), 0, "waits ended")
end)

test("a whole set completed while the copy's direction cannot be read applies nothing and keeps the copy waiting", function()
	local parts, copy = wholeAnswerAndCopy()
	applyPart(copy, parts[1])
	copy.fwd = {x = 0, y = 0, z = 0}
	applyPart(copy, parts[2])
	same(#copy.applyLog, 0, "changes to the copy")
	same(copy.commits, 0, "commits")
	same(countLines(copy.game.geQueue, "shapeApplied"), 0, "waits ended")
end)

test("a cleared notice also drops the dents held for an incomplete set", function()
	local parts, copy = wholeAnswerAndCopy()
	applyPart(copy, parts[1])
	inVehicle(copy, copy.ext.applyDamage, 0, {3, 0.75, 0, 0.3}, {})
	inVehicle(copy, copy.ext.applyDamage, 1, {}, {})
	applyPart(copy, parts[2])
	same(copy.restLen[3], 1, "the copy's beam 3 after the owner's reset")
	same(#copy.applyLog, 0, "changes to the copy")
end)

test("a hydraulic beam in a whole shape reaches the copy broken, its length left to the copy", function()
	local owner = soloCar({beams = 100, hydros = {70}})
	dent(owner, 7, 0.8)
	owner.restLen[70], owner.broken[70] = 1.04, true
	inVehicle(owner, owner.ext.setRole, "owner")
	tick(owner, 2)
	local parts = takeMessages(owner)
	same(#parts, 1, "parts")
	same(table.concat(beamIds(parts[1]), ","), "7,70", "beams in the whole shape")
	local copy = copyCar({beams = 100, hydros = {70}})
	applyPart(copy, parts[1])
	same(copy.commits, 1, "commits")
	same(copy.broken[70], true, "the copy's hydraulic beam 70 broken")
	same(copy.restLen[70], 1, "the copy's hydraulic beam 70 length")
	same(copy.restLen[7], 0.8, "the copy's beam 7")
end)

test("every part of the biggest whole shape fits a 32 KB message", function()
	-- 5-digit point and beam ids, every coordinate at the 20 m a copy accepts, every beam
	-- at the longest length a copy accepts, broken, at the largest deformation.
	local car = soloCar({nodes = 20500, beams = 20500})
	for cid = 1, 20499 do car.nodePos[cid] = fromCarFrame(car, -19.999, -19.999, -19.999) end
	for cid = 0, 20499 do
		car.restLen[cid], car.broken[cid] = 99.9999, true
		car.beamstate.deformedBeams[cid] = 9.999
	end
	car.beamstate.damage = 1e6
	local sent = newOwnerFullSend(car, 30)
	same(#sent, 52, "parts")
	local longest = 0
	for _, m in ipairs(sent) do
		longest = math.max(longest, #('{"v":"999-999",' .. m:sub(2)))
	end
	expect(longest <= 32768, "the longest part with its car id: " .. longest .. " bytes")
end)

--== found in verification ===================================================

-- A copy whose car has the game's other controllers that lengthen beams on their own:
-- hydraulic suspension (beams by name, from the default and a named list), a beam chain
-- and beam segments (beams by tag) and googly eyes (their default tags).
local function copyWithControllers()
	local copy = copyCar({beams = 100,
		controllers = {
			{fileName = "hydraulicSuspension"},
			{fileName = "hydraulicSuspension", name = "front", hydraulicBeams = "frontHydros"},
			{fileName = "mechanics/beamChain", beamTag = "chain"},
			{fileName = "mechanics/beamSegments", segmentBeamTag = "seg", sensorBeamTag = "sensor"},
			{fileName = "propAnimation/googlyEyes"},
		},
		data = {hydraulicsData = {{beamName = "susp", groupName = "g"}}, frontHydros = {{beamName = "fh", groupName = "f"}}},
		beamNames = {[72] = "susp", [80] = "fh"},
		beamTags = {[73] = "chain", [74] = "chain", [75] = "seg", [76] = {"other", "seg"}, [77] = "sensor",
			[78] = "eyeBeam", [79] = "eyeLimiterBeam"}})
	inVehicle(copy, copy.ext.applyDamage, 0, {7, 0.9, 0, 0.2}, {})
	return copy
end

test("beams the car's controllers lengthen on their own never start a resync, their breaks still do", function()
	local copy = copyWithControllers()
	for cid = 72, 80 do copy.restLen[cid] = 1.03 end
	copy.beamstate.damage = copy.beamstate.damage + 10
	tick(copy, 5)
	same(resetRequests(copy).resync, 0, "resyncs for the controllers' lengths")
	copy.broken[73] = true
	copy.beamstate.damage = copy.beamstate.damage + 10
	tick(copy, 2)
	same(resetRequests(copy).resync, 1, "resyncs once a chain beam breaks")
end)

test("a whole shape sent to everyone, with a part lost, is asked for by a copy that was not waiting", function()
	local owner, copy, owners, copies = twoGames({beams = 300, nodes = 1200, separate = true})
	for cid = 0, 9 do dent(owner, cid, 0.8) end
	step(10)
	same(copy.commits, 1, "commits of the owner's first full send")
	local requestsBefore = requestsFor("0-0")
	-- The owner's game dropped queued messages: a cleared notice, then its whole shape
	-- for everyone. The copy loses that shape's middle part.
	dent(owner, 20, 0.7)
	nudgePoints(copy, 0.05)
	local rx, dropped = copies.handlers.rxCareerDamage, 0
	copies.handlers.rxCareerDamage = function(data)
		if dropped == 0 and data:find('"p":2,', 1, true) then dropped = 1; return end
		return rx(data)
	end
	inVehicle(owner, owner.ext.sendFull, 1)
	step(30)
	same(dropped, 1, "middle parts lost")
	same(requestsFor("0-0") - requestsBefore, 1, "requests after the lost part")
	same(copy.commits, 2, "commits")
	same(#pointsOff(owner, copy), 0, "points of the copy away from the owner's car")
	same(copy.restLen[20], 0.7, "the owner's latest dent")
end)

test("a whole set with a row the copy cannot use applies nothing and keeps the copy waiting", function()
	for _, bad in ipairs({
		{beams = {7, 0.8, 0, 0.3}, nodes = {1, 0, 0, 0, 999, 0, 0, 0}},   -- unknown point
		{beams = {7, 0.8, 0, 0.3}, nodes = {4, 1001, 0, 0}},               -- past 1000 m
		{beams = {7, 0.8, 0, 0.3, 8, 150, 0, 0}, nodes = {1, 0, 0, 0}},    -- rest length out of range
		{beams = {7, 0.8, 0, 0.3, 999, 0.8, 0, 0}, nodes = {1, 0, 0, 0}},  -- unknown beam
	}) do
		local copy = copyCar()
		inVehicle(copy, copy.ext.applyDamage, 0, bad.beams, bad.nodes, 1, 1)
		same(#copy.applyLog, 0, "changes to the copy")
		same(countLines(copy.game.geQueue, "shapeApplied"), 0, "waits ended")
	end
end)

test("a point of a whole shape up to 1000 m away, a part torn off and flung, is placed", function()
	local copy = copyCar()
	inVehicle(copy, copy.ext.applyDamage, 0, {7, 0.8, 0, 0.3}, {4, 25, 0, 0, 5, 0, -999, 0}, 1, 1)
	same(copy.commits, 1, "commits")
	local x = toCarFrame(copy, copy.nodePos[4])
	local _, y = toCarFrame(copy, copy.nodePos[5])
	expect(math.abs(x - 25) < 1e-6, "point 4 placed 25 m away")
	expect(math.abs(y + 999) < 1e-6, "point 5 placed 999 m away")
	same(countLines(copy.game.geQueue, "shapeApplied"), 1, "waits ended")
end)

--== found in the independent review ==========================================

test("a whole set with a deformation, broken flag or rest length the copy cannot use applies nothing", function()
	for _, beams in ipairs({
		{7, 0.8, 0, 0.3, 8, 0.8, 0, 11},   -- deformation past 10
		{7, 0.8, 0, 0.3, 8, 0.8, 2, 0.3},  -- broken flag neither 0 nor 1
		{7, 0.8, 0, 0.3, 8, 0, 0, 0.3},    -- rest length 0
	}) do
		local copy = copyCar()
		inVehicle(copy, copy.ext.applyDamage, 0, beams, {1, 0, 0, 0}, 1, 1)
		same(#copy.applyLog, 0, "changes to the copy")
		same(copy.commits, 0, "commits")
		same(countLines(copy.game.geQueue, "shapeApplied"), 0, "waits ended")
	end
end)

test("a point of a whole shape exactly 1000 m away is placed, and the set applied", function()
	local copy = copyCar()
	inVehicle(copy, copy.ext.applyDamage, 0, {7, 0.8, 0, 0.3}, {4, 1000, 0, -1000}, 1, 1)
	same(copy.commits, 1, "commits")
	local x, _, z = toCarFrame(copy, copy.nodePos[4])
	expect(math.abs(x - 1000) < 1e-6 and math.abs(z + 1000) < 1e-6, "point 4 placed 1000 m away")
end)

test("dents held for an incomplete set go on when the set is dropped after 5 s", function()
	local parts, copy = wholeAnswerAndCopy()
	applyPart(copy, parts[1])
	inVehicle(copy, copy.ext.applyDamage, 0, {3, 0.75, 0, 0.3}, {})
	same(copy.restLen[3], 1, "the dent held while the set is incomplete")
	tick(copy, 5)
	same(copy.restLen[3], 0.75, "the held dent once the set is dropped")
	same(copy.commits, 0, "commits of the dropped set")
	same(countLines(copy.game.geQueue, "shapeApplied"), 0, "waits ended")
end)

test("a new owner whose direction cannot be read sends its whole shape once it can", function()
	local car = bigDentedOwner()
	local fwd = car.fwd
	car.fwd = {x = 0, y = 0, z = 0}
	inVehicle(car, car.ext.setRole, "owner")
	tick(car, 2)
	same(#rawMessages(car), 0, "messages without a frame")
	car.fwd = fwd
	tick(car, 2)
	local sent = rawMessages(car)
	same(#sent, 2, "parts of the full send once the frame is back")
	same(sent[1]:sub(1, 20), '{"c":0,"p":1,"t":2,"', "the first part")
	same(sent[2]:sub(1, 20), '{"c":0,"p":2,"t":2,"', "the second part")
end)

test("a numbered part for this game's own car is dropped and opens no wait", function()
	local owner, copy, owners, copies = twoGames()
	step(2)
	local before = #sentToServer("careerDamageRequest", 0)
	deliver(owners, '{"v":"0-0","c":0,"p":1,"t":2,"b":[7,0.5,0,0.3],"n":[]}')
	step(12)
	same(owner.restLen[7], 1, "the owner's own beam 7")
	same(#sentToServer("careerDamageRequest", 0) - before, 0, "requests from the owner's game")
end)
