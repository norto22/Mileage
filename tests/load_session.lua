-- A scripted session of 8 players on one Mileage server, played against the Mileage
-- files of any checkout, to compare what the server passes on before and after a change.
--
--   local runSession = dofile("tests/load_session.lua")
--   local counts = runSession("<checkout root>")
--
--   luajit tests/load_session.lua <checkout root>     (prints the counts)
--
-- Each player's game runs the real enabler, traffic meter, damage sync and paint sync
-- (and the position check, when the checkout has one) on a stand-in game; the server runs
-- the real plugin. The stand-ins use only what the files of the base commit and of the
-- new code both call, so the same script measures both. The game's own parts are
-- modelled simply: a career start spawns the road and parked cars its traffic setup is
-- given and hides the cars above its active amounts; BeamMP sends each own car's
-- position POSITIONS_PER_SECOND times a second through positionGE.sendVehiclePosRot; a
-- car's vehicle Lua answers damage requests with its dents.
--
-- The script: player 0 starts alone; players 1 to 7 join 10 seconds apart; players 0 to
-- 3 drive near each other, 4 to 7 far apart; everyone crashes every 15 seconds; player 7
-- leaves at 100 seconds; the session ends at 120 seconds.

local FRAME = 0.1
local POSITIONS_PER_SECOND = 50
local SESSION_SECONDS = 120
local PLAYERS = 8
local JOIN_EVERY = 10
local LEAVER, LEAVE_AT = 7, 100
local CRASH_EVERY = 15
local BEAMS_PER_CRASH = 40

local unpack = table.unpack or unpack

--== JSON =====================================================================

local function encode(value)
	local t = type(value)
	if t == "table" then
		local n = #value
		if n > 0 then
			local parts = {}
			for i = 1, n do parts[i] = encode(value[i]) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for k in pairs(value) do table.insert(keys, tostring(k)) end
		table.sort(keys)
		local parts = {}
		for _, k in ipairs(keys) do
			local v = value[k]
			if v == nil then v = value[tonumber(k)] end
			table.insert(parts, string.format("%q", k) .. ":" .. encode(v))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif t == "string" then
		return '"' .. value:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
	elseif t == "number" then
		if value == math.floor(value) and math.abs(value) < 1e15 then return string.format("%d", value) end
		return string.format("%.4f", value)
	elseif value == nil then
		return "null"
	end
	return tostring(value)
end

local function decode(text)
	local pos = 1
	local function space() pos = text:find("[^ \t\r\n]", pos) or #text + 1 end
	local value
	local function str()
		local out, i = {}, pos + 1
		while true do
			local c = text:sub(i, i)
			if c == "" then error("open string") end
			if c == '"' then pos = i + 1; return table.concat(out) end
			if c == "\\" then
				local e = text:sub(i + 1, i + 1)
				if e == "u" then
					table.insert(out, string.char(tonumber(text:sub(i + 2, i + 5), 16) % 256))
					i = i + 6
				else
					table.insert(out, ({n = "\n", t = "\t", r = "\r"})[e] or e)
					i = i + 2
				end
			else
				table.insert(out, c)
				i = i + 1
			end
		end
	end
	function value()
		space()
		local c = text:sub(pos, pos)
		if c == "{" then
			local obj = {}
			pos = pos + 1
			space()
			if text:sub(pos, pos) == "}" then pos = pos + 1; return obj end
			while true do
				space()
				if text:sub(pos, pos) ~= '"' then error("key expected") end
				local k = str()
				space()
				if text:sub(pos, pos) ~= ":" then error("colon expected") end
				pos = pos + 1
				obj[k] = value()
				space()
				local d = text:sub(pos, pos)
				pos = pos + 1
				if d == "}" then return obj end
				if d ~= "," then error("comma expected") end
			end
		elseif c == "[" then
			local arr = {}
			pos = pos + 1
			space()
			if text:sub(pos, pos) == "]" then pos = pos + 1; return arr end
			while true do
				table.insert(arr, value())
				space()
				local d = text:sub(pos, pos)
				pos = pos + 1
				if d == "]" then return arr end
				if d ~= "," then error("comma expected") end
			end
		elseif c == '"' then
			return str()
		elseif text:sub(pos, pos + 3) == "true" then
			pos = pos + 4; return true
		elseif text:sub(pos, pos + 4) == "false" then
			pos = pos + 5; return false
		elseif text:sub(pos, pos + 3) == "null" then
			pos = pos + 4; return nil
		end
		local num = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
		if not num or num == "" then error("unexpected text at " .. pos) end
		pos = pos + #num
		return tonumber(num)
	end
	if type(text) ~= "string" then error("not text") end
	local result = value()
	space()
	if pos <= #text then error("trailing text") end
	return result
end

--== vectors ==================================================================

local function vec(x, y, z)
	local v = {x = x, y = y, z = z or 0}
	function v:length() return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end
	return v
end

--== the session ==============================================================

local FEATURES = {
	rxCareerDamage = "damage", rxCareerDamageRequest = "damage",
	rxCareerVehSync = "carStates", rxCareerTrafficShare = "trafficShare",
	rxRemotePartPaint = "paint", rxRequestPartPaints = "paint", rxPrefabSync = "prefabs",
	rxDragMP = "drag", rxDragAuthority = "drag", rxMileageAlive = "alive",
	rxTrafficSignalTimer = "trafficLights", rxCareerSync = "config", rxClientConfigUpdate = "config",
	rxPayment = "payments", rxConfirmation = "payments", rxBounce = "payments", rxDeny = "payments",
}

-- Server events whose handler has another name (mileage.lua onInit).
local HANDLERS = {
	perPartPainting = "perPartPaintingHandler", requestPartPaints = "requestPartPaintsHandler",
}

local function exists(path)
	local f = io.open(path, "r")
	if f then f:close() return true end
	return false
end

local function upvalue(fn, name)
	local i = 1
	while true do
		local n, v = debug.getupvalue(fn, i)
		if n == nil then return nil end
		if n == name then return v end
		i = i + 1
	end
end

local function runSession(root)
	root = root or "."
	local SERVER = root .. "/Resources/Server/Mileage/mileage.lua"
	local GE = root .. "/Resources/Client/Mileage/lua/ge/extensions/"
	local POSITION_RATE = GE .. "mileage/positionRate.lua"
	local hasPositionRate = exists(POSITION_RATE)

	local world = {now = 0, players = {}, joined = {}, toServer = {}, toClients = {}, later = {},
		counts = {positions = 0, positionsBy = {}, bytes = 0, messages = 0, byFeature = {}, toServerBytes = 0,
			toServerBy = {}, maxRoad = 0, maxParked = 0, maxCars = 0, errors = 0}}
	local counts = world.counts
	local realPrint, realClock = print, os.clockhp

	-- Runs fn with player p's game as the globals the game files see, then puts back the
	-- game that was current (a spawn on one game builds copies on the others).
	local current = nil
	local function enter(p)
		current = p
		MPVehicleGE, be, gameplay_traffic, gameplay_parking = p.MPVehicleGE, p.be, p.traffic, p.parking
		positionGE, mileageEnabler, mileage_damageSync, extensions = p.positionGE, p.enabler, p.damage, p.extensions
		career_modules_inventory = p.inventory
		worldReadyState = 2
		TriggerServerEvent = p.triggerServerEvent
		AddEventHandler = p.addEventHandler
	end
	local function as(p, fn, ...)
		local previous = current
		enter(p)
		local results = {pcall(fn, ...)}
		if previous then enter(previous) else current = nil end
		if not results[1] then error(results[2], 0) end
		return unpack(results, 2)
	end

	function log(level) if level == "E" then counts.errors = counts.errors + 1 end end
	function setExtensionUnloadMode() end
	os.clockhp = function() return world.now end
	jsonEncode, jsonDecode = encode, decode
	settings = {getValue = function() return nil end, setValue = function() end}
	MPConfig = {getNickname = function() return "player" end}
	core_trafficSignals = {setTimer = function() end}
	Util = {JsonEncode = encode, JsonDecode = decode}

	local function record(target, event, data)
		local recipients = 1
		if target == -1 then
			recipients = 0
			for _ in pairs(world.joined) do recipients = recipients + 1 end
		end
		local feature = FEATURES[event] or event
		local bytes = #data * recipients
		counts.bytes = counts.bytes + bytes
		counts.messages = counts.messages + recipients
		counts.byFeature[feature] = (counts.byFeature[feature] or 0) + bytes
		table.insert(world.toClients, {target = target, event = event, data = data})
	end

	MP = {
		CreateTimer = function() return {GetCurrent = function() return world.now end, Start = function() end} end,
		RegisterEvent = function() end, CreateEventTimer = function() end,
		GetPlayers = function()
			local names = {}
			for id in pairs(world.joined) do names[id] = "player" .. id end
			return names
		end,
		IsPlayerConnected = function(id) return world.joined[id] ~= nil end,
		GetPlayerName = function(id) return "player" .. tostring(id) end,
		GetOSName = function() return "Linux" end,
		DropPlayer = function() end,
		SendNotification = function(target, text) record(target, "notification", text) end,
		TriggerClientEvent = function(target, event, data) record(target, event, data or "") end,
		TriggerClientEventJson = function(target, event, data) record(target, event, encode(data)) end,
	}
	-- The server's console lines are not part of the count.
	print = function() end
	dofile(SERVER)
	ReadJson = function() return nil end
	WriteJson = function() return true end
	upvalue(onInit, "prepareConfig")()

	--== cars =================================================================

	local function gameId(owner, vid) return owner * 1000 + vid + 1 end

	-- The vehicle Lua of an owner's car answering a damage command: its dents as
	-- messages of at most 400 beams, flagged when it answers a request.
	local function sendDents(p, car, flagged)
		local rows = car.dents
		local first = 1
		repeat
			local beams, nodes = {}, {}
			for i = first, math.min(#rows, first + 399) do
				table.insert(beams, string.format("%d,%.4f,0,%.3f", rows[i], 0.8, 0.3))
				table.insert(nodes, string.format("%d,%.3f,%.3f,%.3f", rows[i], 0.1, 0.2, 0.3))
			end
			local message = (flagged and '{"f":1,' or '{') .. '"c":0,"b":[' .. table.concat(beams, ",") ..
				'],"n":[' .. table.concat(nodes, ",") .. ']}'
			table.insert(world.later, function() as(p, p.damage.onLocalDamage, car.gid, message) end)
			first = first + 400
		until first > #rows
	end

	local function newVeh(p, car)
		local veh = {id = car.gid, JBeam = car.jbeam, active = true, car = car}
		if p.id == car.owner then
			veh.isTraffic = car.kind == "road" and "true" or nil
			veh.isParked = car.kind == "parked" and "true" or nil
		end
		function veh:getID() return self.id end
		function veh:getActive() return self.active end
		function veh:setActive(on)
			local now = on == 1
			if now == self.active then return end
			self.active = now
			as(p, p.enabler.onVehicleActiveChanged, self.id, now)
		end
		function veh:getPosition() return car.pos end
		function veh:getVelocity() return car.vel end
		function veh:setField() end
		function veh:setDynDataFieldbyName(name, _, value) self[name] = value end
		function veh:queueLuaCommand(cmd)
			if p.id ~= car.owner then return end
			local role = cmd:match('^mileageDamage%.setRole%("(%w+)"%)')
			if role then
				car.role = role
				if role == "owner" then sendDents(p, car, false) end
			elseif cmd:find("^mileageDamage%.sendFull%(") then
				sendDents(p, car, false)
			elseif cmd == "mileageDamage.answerFull()" then
				sendDents(p, car, true)
			end
		end
		function veh:delete() end
		return veh
	end

	local function addCopy(p, car)
		local veh = newVeh(p, car)
		p.objects[car.gid] = veh
		p.vehicles[car.sid] = {gameVehicleID = car.gid, jbeam = car.jbeam, isLocal = p.id == car.owner,
			ownerID = car.owner}
		if p.id ~= car.owner then
			as(p, p.enabler.onVehicleSpawned, car.gid)
			as(p, p.enabler.onVehicleReady, car.gid)
			as(p, p.damage.onVehicleSpawned, car.gid)
			as(p, p.paint.onVehicleReady, car.gid)
		end
	end

	-- Player p spawns a car of `kind` ("player", "road", "parked") at pos.
	local function spawn(p, kind, pos)
		local vid = p.nextVid
		p.nextVid = vid + 1
		local car = {owner = p.id, vid = vid, gid = gameId(p.id, vid), sid = p.id .. "-" .. vid, kind = kind,
			jbeam = "covet", pos = pos, vel = vec(0, 0, 0), dents = {}}
		if kind ~= "parked" then car.vel = vec(0, kind == "player" and 15 or 12, 0) end
		p.own[car.gid] = car
		if kind == "road" then p.trafficData[car.gid] = {isAi = true} end
		if kind == "parked" then table.insert(p.parkedList, car.gid) end
		world.cars[car.sid] = car
		addCopy(p, car)
		onVehicleSpawnHandler(p.id, vid, "")
		for _, q in pairs(world.joined) do
			if q ~= p then addCopy(q, car) end
		end
		return car
	end

	local function removeCar(car)
		world.cars[car.sid] = nil
		for _, q in pairs(world.joined) do
			q.objects[car.gid], q.vehicles[car.sid] = nil, nil
			as(q, q.damage.onVehicleDestroyed, car.gid)
		end
		onVehicleDeletedHandler(car.owner, car.vid)
	end

	-- The cars of one kind above the game's active amount are hidden, the rest shown.
	local function applyActive(p, kind, amount)
		local ids = {}
		for gid, car in pairs(p.own) do if car.kind == kind then table.insert(ids, gid) end end
		table.sort(ids)
		for i, gid in ipairs(ids) do
			as(p, function() p.objects[gid]:setActive(i <= amount and 1 or 0) end)
		end
		p.active[kind] = amount
	end

	--== a player's game ======================================================

	local function newPlayer(id)
		local p = {id = id, objects = {}, vehicles = {}, handlers = {}, own = {}, trafficData = {}, parkedList = {},
			nextVid = 0, playerVehicle = -1, active = {road = 0, parked = 0}}
		function p.triggerServerEvent(name, data)
			table.insert(world.toServer, {from = id, name = name, data = data})
			counts.toServerBytes = counts.toServerBytes + #(data or "")
			counts.toServerBy[name] = (counts.toServerBy[name] or 0) + #(data or "")
		end
		function p.addEventHandler(name, handler) p.handlers[name] = handler end
		p.home = id < 4 and vec(id * 200, 0, 0) or vec(3000 * (id - 3), 3000, 0)
		p.MPVehicleGE = {
			getVehicles = function() return p.vehicles end,
			isOwn = function(gid) local v = p.objects[gid]; return v ~= nil and v.car.owner == id end,
			getServerVehicleID = function(gid) local v = p.objects[gid]; return v and v.car.sid end,
			getGameVehicleID = function(sid) local e = p.vehicles[sid]; return e and e.gameVehicleID end,
		}
		p.be = {
			getObjectByID = function(_, gid) return p.objects[gid] end,
			getPlayerVehicleID = function() return p.playerVehicle end,
		}
		p.positionGE = {sendVehiclePosRot = function(_, gid)
			counts.positions = counts.positions + 1
			local car = world.cars and p.objects[gid] and p.objects[gid].car
			local kind = car and car.kind or "?"
			counts.positionsBy[kind] = (counts.positionsBy[kind] or 0) + 1
		end}
		p.inventory = {getInventoryIdFromVehicleId = function() return nil end, getVehicles = function() return {} end}
		local traffic, parking = {}, {}
		function traffic.getTrafficData() return p.trafficData end
		function traffic.setupTrafficHelper(road, _, parked)
			p.asked = {road = road, parked = parked}
			for i = 1, road do
				spawn(p, "road", vec(p.home.x + (i % 5) * 30, p.home.y + i * 20, 0))
			end
			for i = 1, parked do
				spawn(p, "parked", vec(p.home.x - 100 - (i % 4) * 10, p.home.y + i * 15, 0))
			end
		end
		function traffic.setActiveAmount(n) applyActive(p, "road", n) end
		function traffic.getTrafficAmount() return p.active.road end
		function traffic.getState() return "on" end
		function traffic.toggle() end
		function parking.setActiveAmount(n) applyActive(p, "parked", n) end
		function parking.getParkedCarsList() return p.parkedList end
		function parking.getParkingAmount() return p.active.parked end
		p.traffic, p.parking = traffic, parking

		local compat = {
			report = function() end, targetGameVersion = "test", defaultStartMode = "freshStart",
			isMPSession = function() return true end,
			pickOrWarn = function(module, _, name)
				if type(module) == "table" and type(module[name]) == "function" then return module[name] end
				return nil
			end,
			sanitizeProfileName = function(name) return name end,
			getLoadingStatus = function() return false end,
			isCareerActive = function() return true end,
			requestEnterLoadingScreen = function() return false end,
			requestExitLoadingScreen = function() end,
			navigateToPlay = function() end,
			releaseCareerTrafficScreen = function() end,
			reportJoin = function() return true end,
		}
		-- The career's start: the traffic meter is armed, the career sets up traffic with
		-- the player's own amounts (6 and 8) and their active amounts, and is active.
		compat.createOrLoadCareerAndStart = function()
			table.insert(world.later, function()
				as(p, function()
					p.meter.onBeforeCareerActivate()
					gameplay_traffic.setupTrafficHelper(6, {}, 8, nil)
					gameplay_traffic.setActiveAmount(6)
					gameplay_parking.setActiveAmount(8)
					p.meter.onCareerActive(true)
					if p.positionRate then p.positionRate.onCareerActive(true) end
					p.meter.onTrafficOrParkingReady()
				end)
				local car = spawn(p, "player", vec(p.home.x, p.home.y, 0))
				p.playerVehicle = car.gid
				p.started = true
			end)
			return true
		end
		p.extensions = {
			mileage_compat = compat,
			core_input_actionFilter = {setGroup = function() end, addAction = function() end},
			mileage_careerPatches = {ensure = function() return true end,
				withRemoteVehiclesProtected = function(fn) return pcall(fn) end},
			mileage_insuranceRestore = {ensureLoaded = function() end},
		}
		as(p, function()
			p.meter = dofile(GE .. "mileage/traffic.lua")
			p.extensions.mileage_traffic = p.meter
			p.enabler = dofile(GE .. "mileageEnabler.lua")
			p.damage = dofile(GE .. "mileage/damageSync.lua")
			p.paint = dofile(GE .. "mileagePerPartPaint.lua")
			if hasPositionRate then p.positionRate = dofile(POSITION_RATE) end
			p.enabler.onExtensionLoaded()
			p.damage.onExtensionLoaded()
			p.paint.onExtensionLoaded()
		end)
		return p
	end

	--== delivery and time ====================================================

	local function pump()
		for _ = 1, 100 do
			if #world.toServer == 0 and #world.toClients == 0 and #world.later == 0 then return end
			local later, toServer, toClients = world.later, world.toServer, world.toClients
			world.later, world.toServer, world.toClients = {}, {}, {}
			for _, fn in ipairs(later) do fn() end
			for _, m in ipairs(toServer) do
				local handler = world.joined[m.from] and rawget(_G, HANDLERS[m.name] or m.name)
				if handler then handler(m.from, m.data) end
			end
			for _, m in ipairs(toClients) do
				for id, p in pairs(world.joined) do
					if m.target == -1 or m.target == id then
						local handler = p.handlers[m.event]
						if handler then as(p, handler, m.data) end
					end
				end
			end
		end
		error("messages never stopped")
	end

	local function join(p)
		world.joined[p.id] = p
		onPlayerJoinHandler(p.id)
		local existing = {}
		for _, car in pairs(world.cars) do table.insert(existing, car) end
		table.sort(existing, function(a, b) return a.gid < b.gid end)
		for _, car in ipairs(existing) do addCopy(p, car) end
		as(p, p.enabler.onWorldReadyState, 1)
		as(p, p.enabler.onWorldReadyState, 2)
		pump()
	end

	local function leave(p)
		local cars = {}
		for _, car in pairs(p.own) do table.insert(cars, car) end
		for _, car in ipairs(cars) do removeCar(car) end
		world.joined[p.id] = nil
		onPlayerDisconnectHandler(p.id)
		pump()
	end

	local function crash(p)
		local car = p.own[p.playerVehicle]
		if not car or car.role ~= "owner" then return end
		local first = #car.dents
		local rows = {}
		for i = 1, BEAMS_PER_CRASH do
			table.insert(car.dents, first + i)
			table.insert(rows, first + i)
		end
		local beams, nodes = {}, {}
		for _, cid in ipairs(rows) do
			table.insert(beams, string.format("%d,%.4f,0,%.3f", cid, 0.8, 0.3))
			table.insert(nodes, string.format("%d,%.3f,%.3f,%.3f", cid, 0.1, 0.2, 0.3))
		end
		local message = '{"c":0,"b":[' .. table.concat(beams, ",") .. '],"n":[' .. table.concat(nodes, ",") .. ']}'
		as(p, p.damage.onLocalDamage, car.gid, message)
	end

	local function sampleTraffic()
		local road, parked, cars = 0, 0, 0
		for _, p in pairs(world.joined) do
			if p.started then road, parked = road + p.active.road, parked + p.active.parked end
		end
		for _ in pairs(world.cars) do cars = cars + 1 end
		counts.maxRoad = math.max(counts.maxRoad, road)
		counts.maxParked = math.max(counts.maxParked, parked)
		counts.maxCars = math.max(counts.maxCars, cars)
	end

	world.cars = {}
	for id = 0, PLAYERS - 1 do world.players[id] = newPlayer(id) end

	local frames = math.floor(SESSION_SECONDS / FRAME + 0.5)
	local perFrame = math.floor(POSITIONS_PER_SECOND * FRAME + 0.5)
	local nextSecond = 1
	for frame = 1, frames do
		world.now = frame * FRAME
		local t = world.now
		for id = 0, PLAYERS - 1 do
			if math.abs(t - id * JOIN_EVERY - FRAME) < FRAME / 2 then join(world.players[id]) end
		end
		if math.abs(t - LEAVE_AT) < FRAME / 2 and world.joined[LEAVER] then leave(world.players[LEAVER]) end

		for id = 0, PLAYERS - 1 do
			local p = world.joined[id]
			if p then
				as(p, p.enabler.onUpdate, FRAME, FRAME, FRAME)
				as(p, p.meter.onUpdate)
				as(p, p.damage.onUpdate, FRAME)
				if p.positionRate then as(p, p.positionRate.onUpdate, FRAME) end
				for _, car in pairs(p.own) do
					car.pos = vec(car.pos.x + car.vel.x * FRAME, car.pos.y + car.vel.y * FRAME, 0)
				end
				local gids = {}
				for gid in pairs(p.own) do table.insert(gids, gid) end
				table.sort(gids)
				as(p, function()
					for _, gid in ipairs(gids) do
						for _ = 1, perFrame do positionGE.sendVehiclePosRot('{"pos":[0,0,0]}', gid) end
					end
				end)
				local since = t - id * JOIN_EVERY
				if since > 0 and math.abs(since % CRASH_EVERY) < FRAME / 2 then crash(p) end
			end
		end
		if t + FRAME / 2 >= nextSecond then
			nextSecond = nextSecond + 1
			tick()
			if math.floor(t + 0.5) % 10 == 0 then trafficLightTimer() end
			sampleTraffic()
		end
		pump()
	end

	os.clockhp, print = realClock, realPrint
	return counts
end

if arg and arg[0] and arg[0]:match("load_session%.lua$") then
	local counts = runSession(arg[1] or ".")
	local features = {}
	for feature in pairs(counts.byFeature) do table.insert(features, feature) end
	table.sort(features)
	print(string.format("positions passed to BeamMP: %d", counts.positions))
	for _, kind in ipairs({"player", "road", "parked"}) do
		print(string.format("  %-7s %d", kind, counts.positionsBy[kind] or 0))
	end
	print(string.format("Mileage bytes sent by the server: %d (%d messages)", counts.bytes, counts.messages))
	for _, feature in ipairs(features) do print(string.format("  %-14s %d", feature, counts.byFeature[feature])) end
	print(string.format("Mileage bytes sent by the games: %d", counts.toServerBytes))
	local names = {}
	for name in pairs(counts.toServerBy) do table.insert(names, name) end
	table.sort(names)
	for _, name in ipairs(names) do print(string.format("  %-28s %d", name, counts.toServerBy[name])) end
	print(string.format("most traffic asked of the games at once: %d driving, %d parked", counts.maxRoad, counts.maxParked))
	print(string.format("most cars on the server at once: %d", counts.maxCars))
	print(string.format("errors logged by the game files: %d", counts.errors))
end

return runSession
