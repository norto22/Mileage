-- A Mileage server and several players' games, for the money, offer, race and event
-- tests. The server runs the real plugin from onInit; each game runs the real client
-- files Mileage loads for these features, on a stand-in career: money and its history,
-- a save system that calls the game's save hooks, and the player's own save folder.
-- The server's disk is in memory and outlives the plugin, so restart() reloads the
-- plugin over the same data files, as a server restart does.
--
--   local World = dofile("tests/money_world.lua")
--   local world = World.new()
--   local ann = world:join("Ann", 5000)
--   world:pump()
--
-- Messages queue both ways until pump() delivers them. world.filter(message) may return
-- "drop" or "twice" to lose or repeat one; message.way is "toServer" or "toClient".

local SERVER = "Resources/Server/Mileage/mileage.lua"
local CLIENT = "Resources/Client/Mileage/lua/ge/extensions/"

local World = {}
World.__index = World

-- The game gives each road node's position as its own vector, an FFI struct of three
-- doubles. Under LuaJIT the road map hands out positions that way; Lua 5.4 cannot make
-- one, so there they stay plain tables. Anything not a plain point is passed on as is.
local hasFfi, ffi = pcall(require, "ffi")
local GameVec = hasFfi and ffi.typeof("struct { double x, y, z; }") or nil

local function gameVec(pos)
	if not GameVec or type(pos) ~= "table" then return pos end
	if type(pos.x) ~= "number" or type(pos.y) ~= "number" or type(pos.z) ~= "number" then return pos end
	return GameVec(pos.x, pos.y, pos.z)
end

--== JSON =====================================================================

local function isArray(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	if n == 0 then return false end
	for i = 1, n do if t[i] == nil then return false end end
	return true
end

local function encode(value)
	local t = type(value)
	if t == "table" then
		if isArray(value) then
			local parts = {}
			for i = 1, #value do parts[i] = encode(value[i]) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for k in pairs(value) do table.insert(keys, tostring(k)) end
		table.sort(keys)
		local parts = {}
		for _, k in ipairs(keys) do
			local v = value[k]
			if v == nil then v = value[tonumber(k)] end
			table.insert(parts, encode(k) .. ":" .. encode(v))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif t == "string" then
		return '"' .. value:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
	elseif t == "number" then
		if value == math.floor(value) and math.abs(value) < 1e15 then return string.format("%d", value) end
		return string.format("%.6f", value)
	elseif value == nil then
		return "null"
	end
	return tostring(value)
end

local function decode(text)
	if type(text) ~= "string" then error("not text") end
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
	local result = value()
	space()
	if pos <= #text then error("text after the value") end
	return result
end

local function tryDecode(text)
	local ok, value = pcall(decode, text)
	if ok then return value end
	return nil
end

World.encode, World.decode = encode, decode

local function copy(v)
	if type(v) ~= "table" then return v end
	local r = {}
	for k, x in pairs(v) do r[k] = copy(x) end
	return r
end
World.copy = copy

--== the server's disk ========================================================

-- io.open, os.rename, os.remove and FS on an in-memory disk of path -> text.
local function installDisk(world)
	local disk = world.disk
	io.open = function(path, mode)
		mode = mode or "r"
		if world.failWrites and mode:sub(1, 1) == "w" and path:find(world.failWrites, 1, true) then
			return nil, "write refused"
		end
		if mode:sub(1, 1) == "r" then
			local text = disk[path]
			if text == nil then return nil, path .. ": No such file or directory" end
			local file = {}
			function file:read() return text end
			function file:close() end
			function file:seek() return #text end
			return file
		end
		local parts = {}
		local file = {}
		function file:write(data) table.insert(parts, tostring(data)); return self end
		function file:close() disk[path] = table.concat(parts) end
		disk[path] = ""
		return file
	end
	os.rename = function(from, to)
		if disk[from] == nil then return nil, "no such file" end
		if world.renameFailsOverExisting and disk[to] ~= nil then return nil, "file exists" end
		disk[to] = disk[from]
		disk[from] = nil
		return true
	end
	os.remove = function(path)
		if disk[path] == nil then return nil, "no such file" end
		disk[path] = nil
		return true
	end
	FS = {
		Exists = function(path)
			if disk[path] ~= nil then return true end
			local prefix = path:gsub("/$", "") .. "/"
			for p in pairs(disk) do
				if p:sub(1, #prefix) == prefix then return true end
			end
			return world.dirs[path:gsub("/$", "")] == true
		end,
		IsDirectory = function(path) return world.dirs[path:gsub("/$", "")] == true end,
		CreateDirectory = function(path) world.dirs[path:gsub("/$", "")] = true end,
	}
end

--== the server ===============================================================

function World:serverOutput(fn)
	local lines = {}
	local realPrint = print
	print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
		table.insert(lines, table.concat(parts, " "))
	end
	local ok, err = pcall(fn)
	print = realPrint
	if not ok then error(err, 0) end
	for _, line in ipairs(lines) do table.insert(self.printed, line) end
	return lines
end

-- Loads the plugin and runs onInit, as BeamMP does on a start.
function World:startServer()
	local world = self
	self.events, self.timers = {}, {}
	Util = {JsonEncode = encode, JsonDecode = decode, JsonPrettify = function(text) return text end}
	MP = {
		CreateTimer = function() return {GetCurrent = function() return world.now end, Start = function() end} end,
		GetPlayers = function()
			local names = {}
			for id, p in pairs(world.players) do if p.connected then names[id] = p.name end end
			return names
		end,
		IsPlayerConnected = function(id) local p = world.players[id]; return p ~= nil and p.connected end,
		GetPlayerName = function(id) local p = world.players[id]; return p and p.name end,
		GetOSName = function() return "Linux" end,
		-- The server's view of each player's car: where their game last said it was.
		-- world.hidePositions makes it unreadable, as on a BeamMP without these calls.
		GetPlayerVehicles = function(id)
			local p = world.players[id]
			if world.hidePositions or p.hideCar or not p or not p.car then return nil end
			local list = {[0] = {name = p.car.JBeam}}
			-- p.parkedCar = {pos}: a second car of theirs, parked somewhere else (vehicle 9).
			if p.parkedCar then list[9] = {name = "parked"} end
			-- Cars p's game spawned (a race spot's opponents).
			for _, s in pairs(world.spawned) do
				if s.owner == p and not s.gone then list[s.vid] = {name = s.car.JBeam} end
			end
			return list
		end,
		GetPositionRaw = function(id, vid)
			local p = world.players[id]
			local s = world.spawned[tostring(id) .. "-" .. tostring(vid)]
			if s and not s.gone and not world.hidePositions and not s.hidden then
				return {pos = {s.car.pos.x, s.car.pos.y, s.car.pos.z}}
			end
			-- A traffic car, by its server vehicle id.
			local t = world.traffic[tostring(id) .. "-" .. tostring(vid)]
			-- world.hideTraffic: the server cannot read traffic cars, only players' own.
			if t and not world.hidePositions and not world.hideTraffic and not t.gone then
				-- World:holdTraffic: the server keeps reading where the car was, as BeamMP does
				-- while a far car's positions arrive late.
				local at = t.held and t.held.pos or t.car.pos
				return {pos = {at.x, at.y, at.z}}
			end
			if not world.hidePositions and p and p.parkedCar and vid == 9 then
				local at = p.parkedCar.pos
				return {pos = {at.x, at.y, at.z}}
			end
			if world.hidePositions or not p or not p.car or vid ~= 0 then return nil end
			return {pos = {p.car.pos.x, p.car.pos.y, p.car.pos.z}}
		end,
		TriggerClientEvent = function(target, event, data)
			world:queue({way = "toClient", target = target, event = event, data = data})
		end,
		SendNotification = function(target, text)
			table.insert(world.notifications, {target = target, text = text})
		end,
		SendChatMessage = function(target, text)
			world.chat = world.chat or {}
			table.insert(world.chat, {target = target, text = text})
		end,
		DropPlayer = function(id, why) world.dropped[id] = why end,
		RegisterEvent = function(event, handler) world.events[event] = handler end,
		CreateEventTimer = function(event, ms) world.timers[event] = ms end,
		TriggerLocalEvent = function(command, arguments)
			local handler = world.events[command]
			if handler and _G[handler] then _G[handler](arguments) end
		end,
	}
	exit = function() world.exited = true end
	self:serverOutput(function()
		dofile(SERVER)
		onInit()
	end)
end

function World:restart()
	self.toServer = {}
	self:startServer()
	-- BeamMP drops everyone with the server: each game comes back from its last save.
	for id, p in pairs(self.players) do
		if p.connected then
			self:loadGame(p)
			self:serverOutput(function() onPlayerJoinHandler(id) end)
			self:startCareer(p)
		end
	end
	self:pump()
end

-- A console line, as the owner types it. Returns the lines printed.
function World:console(line)
	local lines = self:serverOutput(function() onConsoleInputHandler(line) end)
	self:pump()
	return lines
end

function World:setConfig(section, key, value)
	return self:console("Mileage SetConfig " .. section .. " " .. key .. " " .. tostring(value))
end

--== a player's game ==========================================================

-- Runs fn with the globals of p's game.
function World:as(p, fn, ...)
	local world = self
	worldReadyState = 2
	extensions = p.extensions
	career_modules_playerAttributes = p.attributes
	career_saveSystem = p.saveSystem
	MPConfig = {getNickname = function() return p.name end}
	MPVehicleGE = p.MPVehicleGE
	be = p.be
	guihooks = {trigger = function(name, data) table.insert(p.ui, {name = name, data = copy(data)}) end}
	jsonEncode, jsonDecode = encode, tryDecode
	jsonReadFile = function(path)
		local text = p.files[path]
		return text and tryDecode(text) or nil
	end
	FS = p.fs
	function TriggerServerEvent(name, data)
		world:queue({way = "toServer", from = p.id, name = name, data = data})
	end
	function AddEventHandler(name, handler) p.handlers[name] = handler end
	-- Each game's own extensions answer to their global names.
	for name, ext in pairs(p.extensions) do _G[name] = ext end
	for name, value in pairs(p.globals) do _G[name] = value end
	local results = {fn(...)}
	FS = world.serverFS
	return (table.unpack or unpack)(results)
end

-- The game's save: every extension's onSaveCurrentProfile writes into the save folder,
-- then onSaveFinished fires for a finished save. p.saveMode "fail" writes nothing and
-- never finishes; "later" holds onSaveFinished until finishSaves.
local function newSaveSystem(world, p)
	local saveSystem = {}
	function saveSystem.getCurrentProfile() return "profile", p.savePath end
	function saveSystem.jsonWriteFileSafe(path, value)
		if p.saveMode == "fail" then return false end
		p.staged[path] = encode(value)
		return true
	end
	function saveSystem.saveCurrent()
		p.saves = p.saves + 1
		p.staged = {}
		p.stagedMoney = p.money
		for _, name in ipairs(p.extensionOrder) do
			local ext = p.extensions[name]
			if type(ext) == "table" and type(ext.onSaveCurrentProfile) == "function" then
				ext.onSaveCurrentProfile(p.savePath)
			end
		end
		if p.saveMode == "fail" then return end
		local function finish()
			for path, text in pairs(p.staged) do p.files[path] = text end
			p.savedMoney = p.stagedMoney
			for _, name in ipairs(p.extensionOrder) do
				local ext = p.extensions[name]
				if type(ext) == "table" and type(ext.onSaveFinished) == "function" then ext.onSaveFinished() end
			end
		end
		if p.saveMode == "later" then table.insert(p.heldSaves, finish) else finish() end
	end
	return saveSystem
end

function World:finishSaves(p)
	local held = p.heldSaves
	p.heldSaves = {}
	for _, finish in ipairs(held) do self:as(p, finish) end
	self:pump()
end

-- The client files each game loads, in modScript's order, as extension name -> file.
World.CLIENT_FILES = {
	{"mileage_compat", CLIENT .. "mileage/compat.lua"},
	{"mileage_transfers", CLIENT .. "mileage/transfers.lua"},
	{"mileagePlayerPayments", CLIENT .. "mileagePlayerPayments.lua"},
	{"mileage_offers", CLIENT .. "mileage/offers.lua"},
	{"mileage_streetRace", CLIENT .. "mileage/streetRace.lua"},
	{"mileage_leaderboard", CLIENT .. "mileage/leaderboard.lua"},
	{"mileage_raceEvents", CLIENT .. "mileage/raceEvents.lua"},
	{"mileage_aiRace", CLIENT .. "mileage/aiRace.lua"},
	{"mileage_spotRoutes", CLIENT .. "mileage/spotRoutes.lua"},
	{"mileage_spotRace", CLIENT .. "mileage/spotRace.lua"},
	{"mileage_raceSpots", CLIENT .. "mileage/raceSpots.lua"},
}

local function fileExists(path)
	local realOpen = World.realOpen
	local f = realOpen(path, "r")
	if f then f:close(); return true end
	return false
end

-- p's car, standing at the origin facing north unless placed: its position, direction and
-- up vectors, and whether the vehicle controller holds it frozen.
function World:giveCar(p)
	if p.car then return p.car end
	local car = {id = 1000 + p.id, JBeam = "pickup", pos = {x = p.id * 50, y = 0, z = 0}, dir = {x = 0, y = 1, z = 0},
		up = {x = 0, y = 0, z = 1}, frozen = false, freezes = 0}
	function car:getPosition() return self.pos end
	function car:getDirectionVector() return self.dir end
	function car:getDirectionVectorUp() return self.up end
	function car:queueLuaCommand(cmd)
		local on = cmd:match("^controller%.setFreeze%((%d)%)$")
		if on then
			self.frozen = on == "1"
			if self.frozen then self.freezes = self.freezes + 1 end
		end
	end
	p.car = car
	return car
end

-- One of p's game's traffic cars at x, y (z 0), heading dir (north unless given), a
-- traffic car the game's traffic system drives (gameplay_traffic) and the server marks as
-- traffic. opts: {x, y, dir, jbeam}. Returns {car, sid, entry}; car.commands lists what was
-- queued on it, and once it is sent a race route it drives there at car.speed m/s.
function World:giveTraffic(p, opts)
	opts = opts or {}
	self.trafficCount = (self.trafficCount or 0) + 1
	local n = self.trafficCount
	local car = {id = 5000 + n, JBeam = opts.jbeam or "pessima", pos = {x = opts.x or 0, y = opts.y or 0, z = 0},
		dir = opts.dir or {x = 0, y = 1, z = 0}, up = {x = 0, y = 0, z = 1}, commands = {}, speed = 0}
	function car:getPosition() return self.pos end
	function car:getDirectionVector() return self.dir end
	function car:getDirectionVectorUp() return self.up end
	local world = self
	function car:queueLuaCommand(cmd)
		table.insert(self.commands, cmd)
		local first = cmd:match('^ai%.driveUsingPath%({wpTargetList = {"([^"]+)"')
		if first then
			self.racing = true
			self.target = (world.roadNodes or {})[first] and world.roadNodes[first].pos
		end
		if cmd == "ai.setRacing(false)" then self.racing = false end
	end
	local entry = {isAi = true, roleName = "standard", autoRole = "standard", enableRespawn = true,
		enableAutoPooling = true, roles = {}}
	function entry:setRole(name)
		self.roleName = name
		table.insert(self.roles, name)
	end
	p.trafficData[car.id] = entry
	local sid = p.id .. "-" .. n
	local t = {car = car, sid = sid, entry = entry, owner = p}
	self.traffic[sid] = t
	self:serverOutput(function()
		onVehicleSpawnHandler(p.id, n)
		careerVehicleTrafficMarks(p.id, encode({[sid] = true}))
	end)
	self:pump()
	return t
end

-- A car p's game spawns with core_vehicles.spawnNewVehicle (a race spot's opponent). It
-- reaches the server at once unless world.spawnRefused (no car) or world.noServerIds (BeamMP
-- never gives it a server id). Sent a race path, it drives straight from road node to road
-- node at car.speed metres a second, lap after lap. Returns the car.
function World:spawnCar(p, model, opts)
	if self.spawnRefused then return nil end
	self.spawnCount = (self.spawnCount or 0) + 1
	local n = self.spawnCount
	local world = self
	local rot = opts.rot or {}
	local car = {id = 7000 + n, JBeam = model, config = opts.config, pos = {x = opts.pos.x, y = opts.pos.y, z = opts.pos.z},
		dir = copy(rot.dir) or {x = 0, y = 1, z = 0}, up = copy(rot.up) or {x = 0, y = 0, z = 1}, commands = {},
		speed = self.opponentSpeed or 30, frozen = false, deleted = false}
	local s = {car = car, owner = p, vid = 100 + n, sid = p.id .. "-" .. (100 + n)}
	function car:getPosition() return self.pos end
	function car:getDirectionVector() return self.dir end
	function car:getDirectionVectorUp() return self.up end
	function car:getID() return self.id end
	function car:setDynDataFieldbyName(name, _, value) self[name] = value end
	function car:delete()
		self.deleted = true
		s.gone = true
		world:serverOutput(function() onVehicleDeletedHandler(p.id, s.vid) end)
	end
	function car:queueLuaCommand(cmd)
		table.insert(self.commands, cmd)
		local on = cmd:match("^controller%.setFreeze%((%d)%)$")
		if on then self.frozen = on == "1" end
		local list = cmd:match("^ai%.driveUsingPath%({wpTargetList = {(.-)}")
		if list then
			self.path = {}
			for name in list:gmatch('"([^"]+)"') do table.insert(self.path, name) end
			self.laps = tonumber(cmd:match("noOfLaps = (%d+)")) or 1
			self.aggression = tonumber(cmd:match("aggression = ([%d%.]+)"))
			self.pathIndex, self.lap, self.racing = 1, 1, true
		end
	end
	self.spawned[s.sid] = s
	self:serverOutput(function() onVehicleSpawnHandler(p.id, s.vid) end)
	return car
end

-- Spawned cars sent a race path drive it; a frozen one, or one at speed 0, stands.
function World:moveSpawned()
	for _, s in pairs(self.spawned) do
		local car = s.car
		local left = car.speed
		while car.racing and not s.gone and not car.frozen and left > 0 do
			local node = (self.roadNodes or {})[car.path[car.pathIndex]]
			if not node then car.racing = false break end
			local dx, dy, dz = node.pos.x - car.pos.x, node.pos.y - car.pos.y, node.pos.z - car.pos.z
			local d = math.sqrt(dx * dx + dy * dy + dz * dz)
			local step = math.min(d, left)
			if d > 0 then
				car.pos = {x = car.pos.x + dx / d * step, y = car.pos.y + dy / d * step, z = car.pos.z + dz / d * step}
			end
			left = left - step
			if step >= d then
				car.pathIndex = car.pathIndex + 1
				if car.pathIndex > #car.path then
					-- As the game's ai.lua: laps repeat only on a path that ends on its first node,
					-- and the next lap goes on from the second.
					local loops = car.laps > 1 and #car.path > 1 and car.path[1] == car.path[#car.path]
					car.lap, car.pathIndex = car.lap + 1, 2
					if not loops or car.lap > car.laps then car.racing = false end
				end
			end
		end
	end
end

-- Traffic cars sent a race route drive straight at their target, car.speed metres a second.
function World:moveTraffic()
	for _, t in pairs(self.traffic) do
		local car = t.car
		if car.racing and car.target and car.speed > 0 and not t.gone then
			local dx, dy = car.target.x - car.pos.x, car.target.y - car.pos.y
			local left = math.sqrt(dx * dx + dy * dy)
			local step = math.min(left, car.speed)
			if left > 0 then
				car.pos = {x = car.pos.x + dx / left * step, y = car.pos.y + dy / left * step, z = car.pos.z}
			end
		end
	end
end

-- The server reads traffic car t where it is now for the next ticks server ticks, while the
-- car drives on, then sees where it has got to.
function World:holdTraffic(t, ticks)
	t.held = {pos = {x = t.car.pos.x, y = t.car.pos.y, z = t.car.pos.z}, ticks = ticks}
end

-- Moves p's car to x, y, z (z 0 unless given); a frozen car does not move.
function World:drive(p, x, y, z)
	if p.car.frozen then return false end
	p.car.pos = {x = x, y = y, z = z or 0}
	return true
end

-- Loads p's game from its save: money is the saved money, extensions start fresh.
function World:loadGame(p)
	p.money = p.savedMoney
	p.handlers, p.ui, p.extensions, p.extensionOrder = {}, {}, {}, {}
	p.heldSaves = {}
	p.careerActive = false
	local world = self
	p.attributes = {
		getAttribute = function(name)
			if name == "money" then return {value = p.money} end
			return nil
		end,
		addAttributes = function(change, reason)
			if change.money then
				p.money = p.money + change.money
				table.insert(p.history, {amount = change.money, label = reason and reason.label})
			end
		end,
	}
	p.saveSystem = newSaveSystem(world, p)
	p.MPVehicleGE = {
		getPlayers = function()
			local list = {}
			for id, other in pairs(world.players) do
				if other.connected then list[id] = {name = other.name, playerID = id} end
			end
			return list
		end,
		isOwn = function(gid)
			if p.trafficData[gid] then return true end
			for _, s in pairs(world.spawned) do
				if s.car.id == gid then return s.owner == p end
			end
			return p.car ~= nil and p.car.id == gid and p.car.own ~= false
		end,
		getServerVehicleID = function(gid)
			if p.car and p.car.id == gid then return p.id .. "-0" end
			for sid, t in pairs(world.traffic) do
				if t.car.id == gid then return sid end
			end
			if not world.noServerIds then
				for sid, s in pairs(world.spawned) do
					if s.car.id == gid then return sid end
				end
			end
			return nil
		end,
		-- Other players' traffic cars, as BeamMP lists them on this game.
		getVehicles = function()
			local list = {}
			for sid, t in pairs(world.traffic) do
				if t.owner ~= p and t.owner.connected then
					list[sid] = {gameVehicleID = t.car.id, ownerName = t.owner.name, jbeam = t.car.JBeam}
				end
			end
			return list
		end,
	}
	p.trafficData = p.trafficData or {}
	self:giveCar(p)
	p.teleports = p.teleports or {}
	p.be = {
		getPlayerVehicleID = function() return p.inCar ~= false and p.car and p.car.id or -1 end,
		getObjectByID = function(_, gid)
			if p.car and p.car.id == gid then return p.car end
			for _, t in pairs(world.traffic) do
				if t.car.id == gid and not t.gone then return t.car end
			end
			for _, s in pairs(world.spawned) do
				if s.car.id == gid and not s.gone and s.owner == p then return s.car end
			end
			return nil
		end,
	}
	p.globals.vec3 = function(x, y, z) return {x = x, y = y, z = z} end
	p.globals.quatFromDir = function(dir, up) return {dir = dir, up = up} end
	p.globals.core_groundMarkers = {getTargetPos = function() return p.route end,
		setPath = function(pos) p.route = pos end}
	p.globals.gameplay_missions_missionManager = {getForegroundMissionId = function() return p.mission end}
	p.globals.MPCoreNetwork = {isMPSession = function() return true end}
	p.globals.gameplay_drag_core = {getData = function() return p.dragData end}
	p.globals.map = {
		-- Positions as the game gives them: its own vectors under LuaJIT, plain tables elsewhere.
		getMap = function()
			local nodes = {}
			for name, node in pairs(world.roadNodes or {}) do
				local copy = {}
				for k, v in pairs(node) do copy[k] = v end
				copy.pos = gameVec(node.pos)
				nodes[name] = copy
			end
			return {nodes = nodes}
		end,
		-- A road route from a point to a node: none to a node the test marks unreachable.
		getPointNodePath = function(pos, node)
			if (world.unreachable or {})[node] or not (world.roadNodes or {})[node] then return {} end
			return {"from", node}
		end,
		getGraphpath = function()
			return {getRandomPathG = function(_, node) return {node, node .. "+1", node .. "+2"} end}
		end,
	}
	p.globals.gameplay_traffic = {getTrafficData = function() return p.trafficData end}
	-- The game's place list and marker caches, and its prompt at a marker.
	p.poiClears, p.markerClears, p.promptCloses = p.poiClears or 0, p.markerClears or 0, p.promptCloses or 0
	p.globals.gameplay_rawPois = {clear = function() p.poiClears = p.poiClears + 1 end}
	p.globals.gameplay_markerInteraction = {clearCache = function() p.markerClears = p.markerClears + 1 end}
	p.globals.ui_missionInfo = {closeDialogue = function() p.promptCloses = p.promptCloses + 1 end}
	p.globals.mileageEnabler = {isRemoteTraffic = function(sid) return world.traffic[sid] ~= nil end}
	p.globals.core_vehicles = {getModel = function(jbeam)
		local models = {pessima = {Brand = "Ibishu", Name = "Pessima"}, pickup = {Brand = "Gavril", Name = "D-Series"},
			etk800 = {Brand = "ETK", Name = "800 Series"}}
		return models[jbeam] and {model = models[jbeam]} or {}
	end, spawnNewVehicle = function(model, opts)
		table.insert(world.spawnRequests, {owner = p, model = model, opts = opts})
		return world:spawnCar(p, model, opts)
	end}
	p.globals.core_input_bindings = {getControlForAction = function(action)
		return (world.boundKeys or {})[action]
	end}
	p.globals.core_input_actions = {
		onFileChanged = function(path) world.actionReloads = (world.actionReloads or 0) + 1; world.actionFile = path end,
		getActiveActions = function() return world.listedActions or {} end,
	}
	p.globals.spawn = {safeTeleport = function(veh, pos, rot)
		table.insert(p.teleports, {pos = copy(pos), rot = copy(rot)})
		veh.pos = {x = pos.x, y = pos.y, z = pos.z}
		veh.dir, veh.up = copy(rot.dir), copy(rot.up)
	end}
	self:as(p, function()
		for _, entry in ipairs(World.CLIENT_FILES) do
			if fileExists(entry[2]) then
				local loaded = dofile(entry[2])
				p.extensions[entry[1]] = loaded
				_G[entry[1]] = loaded
				table.insert(p.extensionOrder, entry[1])
			end
		end
		for _, name in ipairs(p.extensionOrder) do
			local ext = p.extensions[name]
			if type(ext.onExtensionLoaded) == "function" then ext.onExtensionLoaded() end
		end
	end)
end

-- Fires a game hook on every extension of p's game.
function World:hook(p, name, ...)
	local args = {...}
	self:as(p, function()
		for _, ext in ipairs(p.extensionOrder) do
			local e = p.extensions[ext]
			if type(e[name]) == "function" then e[name]((table.unpack or unpack)(args)) end
		end
	end)
end

-- What the client and server do for a career start on a server.
function World:startCareer(p)
	p.careerActive = true
	self:hook(p, "onCareerActive", true)
	self:serverOutput(function()
		careerSyncRequested(p.id, encode({confirmsStart = true}))
		careerStartResult(p.id, encode({started = true}))
	end)
end

-- A player joins with money in their save, and starts their career.
function World:join(name, money, id)
	id = id or self.nextPlayerId
	self.nextPlayerId = math.max(self.nextPlayerId, id + 1)
	local p = self.players[id]
	if not p then
		p = {id = id, name = name, savedMoney = money or 0, history = {}, files = {}, saves = 0,
			savePath = "/saves/" .. name .. "/autosave1", globals = {}, staged = {}}
		p.fs = {}
		self.players[id] = p
	end
	p.connected = true
	self:loadGame(p)
	self:serverOutput(function() onPlayerJoinHandler(id) end)
	self:startCareer(p)
	self:pump()
	return p
end

-- A player leaves (or their game drops). opts.crash loses what their game has not saved.
function World:leave(p, opts)
	opts = opts or {}
	p.connected = false
	if opts.crash then p.money = p.savedMoney end
	self:serverOutput(function() onPlayerDisconnectHandler(p.id) end)
	self:pump()
end

-- The player's game comes back from its save and joins again.
function World:rejoin(p)
	return self:join(p.name, p.savedMoney, p.id)
end

--== messages =================================================================

function World:queue(message)
	local verdict = self.filter and self.filter(message)
	if verdict == "drop" then table.insert(self.dropped, message); return end
	local list = message.way == "toServer" and self.toServer or self.toClients
	table.insert(list, message)
	if verdict == "twice" then table.insert(list, copy(message)) end
end

-- Delivers queued messages both ways until none are left.
function World:pump()
	for _ = 1, 1000 do
		if #self.toServer == 0 and #self.toClients == 0 then return end
		local toServer, toClients = self.toServer, self.toClients
		self.toServer, self.toClients = {}, {}
		for _, m in ipairs(toServer) do
			local p = self.players[m.from]
			if p and p.connected then
				table.insert(self.serverLog, m)
				local registered = self.events[m.name]
				local handler = registered and _G[registered]
				if handler then self:serverOutput(function() handler(m.from, m.data) end) end
			end
		end
		for _, m in ipairs(toClients) do
			table.insert(self.clientLog, m)
			for id, p in pairs(self.players) do
				if p.connected and (m.target == -1 or m.target == id) then
					local handler = p.handlers[m.event]
					if handler then self:as(p, handler, m.data) end
				end
			end
		end
	end
	error("messages never stopped")
end

-- Moves the clock on in one-second ticks, delivering messages and running each game's
-- frame update.
function World:advance(seconds)
	for _ = 1, math.floor(seconds + 0.5) do
		self.now = self.now + 1
		self:moveTraffic()
		self:moveSpawned()
		self:serverOutput(function() if _G.tick then tick() end end)
		self:pump()
		for _, t in pairs(self.traffic) do
			if t.held then
				t.held.ticks = t.held.ticks - 1
				if t.held.ticks <= 0 then t.held = nil end
			end
		end
		for _, p in pairs(self.players) do
			if p.connected then
				self:as(p, function()
					for _, name in ipairs(p.extensionOrder) do
						local ext = p.extensions[name]
						if type(ext.onUpdate) == "function" then ext.onUpdate(1, 1, 1) end
					end
				end)
			end
		end
		self:pump()
	end
end

--== reading the results ======================================================

-- Messages the server sent to p (or to everyone) with this event name, decoded.
function World:received(p, event)
	local found = {}
	for _, m in ipairs(self.clientLog) do
		if m.event == event and (m.target == -1 or m.target == p.id) then
			table.insert(found, tryDecode(m.data) or m.data)
		end
	end
	return found
end

-- guihooks p's game triggered with this name.
function World:ui(p, name)
	local found = {}
	for _, entry in ipairs(p.ui) do
		if entry.name == name then table.insert(found, entry.data) end
	end
	return found
end

function World:dataFile(name)
	local text = self.disk["Resources/Server/Mileage/data/" .. name]
	return text and decode(text) or nil
end

-- Money in every player's last save.
function World:savedTotal()
	local total = 0
	for _, p in pairs(self.players) do total = total + p.savedMoney end
	return total
end

function World:printedMatching(text)
	local n = 0
	for _, line in ipairs(self.printed) do
		if line:find(text, 1, true) then n = n + 1 end
	end
	return n
end

--== a new world ==============================================================

-- The real functions, kept once however many test files load this one.
REAL_IO = REAL_IO or {open = io.open, rename = os.rename, remove = os.remove, time = os.time}
World.realOpen = REAL_IO.open

-- opts.config: server settings to start with (merged into a config with autoUpdate off).
function World.new(opts)
	opts = opts or {}
	local self = setmetatable({players = {}, toServer = {}, toClients = {}, serverLog = {}, clientLog = {},
		dropped = {}, notifications = {}, printed = {}, disk = {}, dirs = {}, now = 0, nextPlayerId = 0, traffic = {},
		spawned = {}, spawnRequests = {}},
		World)
	-- Every test starts from the real io and os functions.
	World.restoreIo()
	function log() end
	function setExtensionUnloadMode() end
	settings = {getValue = function() return nil end, setValue = function() end}
	installDisk(self)
	self.serverFS = FS
	-- The wall clock moves with the world's clock, so schedules follow advance().
	self.epoch = 1793500000
	os.time = function(t)
		if t then return REAL_IO.time(t) end
		return self.epoch + math.floor(self.now)
	end
	local server = {autoUpdate = false, autoExit = false}
	for k, v in pairs(opts.server or {}) do server[k] = v end
	self.disk["Resources/Server/Mileage/config/config.json"] = encode({server = server, client = opts.client or {}})
	self:startServer()
	return self
end

-- Puts io and os back for the next test.
function World.restoreIo()
	io.open, os.rename, os.remove, os.time = REAL_IO.open, REAL_IO.rename, REAL_IO.remove, REAL_IO.time
end

-- test(name, fn) with a new world, putting io and os back however fn ends.
function World.test(name, fn, opts)
	test(name, function()
		local world = World.new(opts)
		local ok, err = pcall(fn, world)
		World.restoreIo()
		if not ok then error(err, 0) end
	end)
end

return World
