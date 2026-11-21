-- mileage/editHold.lua: while the Parts or Tuning screen is open for a car, BeamMP's edits of
-- that car (its 'Oc' packets) are held instead of sent to every other game; when the screen
-- closes, BeamMP's sendVehicleEdit sends the finished car once. Edits of other cars, paint
-- and every other packet pass; Painting and Repair are not held. Career stop or a failure in
-- the hold sends the held edit; leaving the server drops it. Either way BeamMP's send is put
-- back.
--
-- BeamMP is a stand-in that follows MPVehicleGE.lua at v4.23.1: a garage rebuild reaches
-- onVehicleSpawned, which calls its own local sendVehicleEdit (an upvalue, never the module
-- field), which builds the packet in one reused buffer (MPNetworkHelpers.generatePacketBuffer)
-- and hands it to MPGameNetwork.send, looked up at call time. The game's partShopping.lua and
-- tuning.lua are stand-ins that follow their session start, apply, cancel and close.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileage/editHold.lua"
local COMPAT = "Resources/Client/Mileage/lua/ge/extensions/mileage/compat.lua"
local PAINT = "Resources/Client/Mileage/lua/ge/extensions/mileagePerPartPaint.lua"

local CAR, OTHER = 11, 12 -- game vehicle ids of two of this player's cars
local INV = 1             -- the garage's inventory id of CAR

local game, logs, hold

-- BeamMP's packet buffer: one buffer reused for every packet, as MPNetworkHelpers has it,
-- so a packet must be read when it is sent, never kept. raises: the next read fails once.
local function newBuffer()
	local buf = {text = ""}
	setmetatable(buf, {__tostring = function(self)
		if self.raises then self.raises = false; error("buffer broke") end
		return self.text
	end, __len = function(self) return #self.text end})
	return buf
end

-- What reached the network: the text of each packet, in order.
local function sentOf(code, sid)
	local n = 0
	for _, text in ipairs(game.wire) do
		local c, id = text:match("^(%a%a):([^:]*)")
		if c == code and (sid == nil or id == sid) then n = n + 1 end
	end
	return n
end

local function edits(sid) return sentOf("Oc", sid) end

local function setup(opts)
	opts = opts or {}
	logs = {}
	game = {wire = {}, objects = {}, hooks = {}, autosave = opts.autosave == true}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. tostring(msg)) end
	function setExtensionUnloadMode() end
	-- Messages to the server travel as the tables themselves.
	function jsonEncode(t) return t end
	function jsonDecode(t) return t end
	for _, gid in ipairs({CAR, OTHER}) do
		game.objects[gid] = {id = gid, own = true, sid = "0-" .. gid, config = "stock"}
	end
	be = {getObjectByID = function(_, gid) return game.objects[gid] end}
	function getObjectByID(gid) return game.objects[gid] end
	MPCoreNetwork = {isMPSession = function() return opts.mp ~= false end}

	-- MPNetworkHelpers.generatePacketBuffer: one reused buffer.
	local buffer = newBuffer()
	game.buffer = buffer
	MPNetworkHelpers = {generatePacketBuffer = function(code, sid, data)
		buffer.text = code
		if sid then buffer.text = buffer.text .. ":" .. sid end
		if data then buffer.text = buffer.text .. ":" .. data end
		return buffer
	end}
	-- MPGameNetwork.send: what reaches the launcher.
	game.realSend = function(data)
		table.insert(game.wire, type(data) == "string" and data or tostring(data))
	end
	MPGameNetwork = {send = game.realSend}

	-- MPVehicleGE: the module's sendVehicleEdit is the same local function its own callers
	-- use, so wrapping the field would catch nothing.
	local function getServerVehicleID(gid)
		local o = game.objects[gid]
		return o and o.sid
	end
	local function sendVehicleEdit(gid)
		local veh = getObjectByID(gid)
		local c = veh.color -- BeamMP reads the car before it checks anything
		if not veh.own then return end
		MPGameNetwork.send(MPNetworkHelpers.generatePacketBuffer('Oc', getServerVehicleID(gid),
			"{cfg=" .. veh.config .. "}"))
	end
	game.sendVehicleEdit = sendVehicleEdit
	MPVehicleGE = {
		sendVehicleEdit = sendVehicleEdit,
		getServerVehicleID = getServerVehicleID,
		getGameVehicleID = function(sid)
			for gid, o in pairs(game.objects) do if o.sid == sid then return gid end end
			return -1
		end,
		isOwn = function(gid) local o = game.objects[gid]; return o ~= nil and o.own end,
		-- onVehicleSpawned after a garage rebuild (replaceRequest set jbeam to '-'): an edit.
		onVehicleSpawned = function(gid) sendVehicleEdit(gid) end,
	}

	-- core_vehicles.replaceVehicle through BeamMP: the car is rebuilt in place and BeamMP
	-- sends it at once; its vehicle Lua then says it is ready (mileageEnabler's vehicle side
	-- calls mileagePerPartPaint.onVehicleReady).
	local function rebuild(gid, config)
		game.objects[gid].config = config
		MPVehicleGE.onVehicleSpawned(gid)
		if game.paint then game.paint.onVehicleReady(gid) end
	end
	game.rebuild = rebuild

	-- The extensions that hear each hook, in order. opts.paintFirst puts the paint sync first.
	game.listeners = {}
	extensions = {
		mileage_compat = dofile(COMPAT),
		hook = function(name, ...)
			table.insert(game.hooks, name)
			for _, module in ipairs(game.listeners) do
				local fn = module[name]
				if type(fn) == "function" then fn(...) end
			end
		end,
	}

	-- The garage's saved cars. The open Parts screen works on a copy (the game's
	-- previewVehicle): each part fitted adds a painted part to it, and only Buy writes it to
	-- the saved car. The car starts with three painted parts.
	local function paintOf(n) return {{baseColor = {n / 10, 0, 0, 1}, metallic = 0, roughness = 0.5,
		clearcoat = 0, clearcoatRoughness = 0}} end
	game.paintOf = paintOf
	local saved = {partConditions = {}}
	for i = 1, 3 do
		saved.partConditions["/body/panel" .. i] = {visualState = {paint = {originalPaints = paintOf(i)}}}
	end
	game.saved = {[INV] = saved}
	local function copyCar(car)
		local c = {partConditions = {}}
		for path, cond in pairs(car.partConditions) do c.partConditions[path] = cond end
		return c
	end
	career_modules_inventory = {
		getVehicles = function() return game.saved end,
		getInventoryIdFromVehicleId = function(gid) if gid == CAR then return INV end return nil end,
		getVehicleIdFromInventoryId = function(inv) if inv == INV then return CAR end return nil end,
	}

	-- mileagePerPartPaint's game and BeamMP: what it sends to the server, by event.
	game.toServer, game.handlers = {}, {}
	function AddEventHandler(name, fn) game.handlers[name] = fn end
	function TriggerServerEvent(name, data) table.insert(game.toServer, {name = name, data = data}) end
	function clamp(v, lo, hi) return math.min(math.max(v, lo), hi) end
	function validateVehiclePaint() end
	function tableIsEmpty(t) return next(t) == nil end
	os.clockhp = function() return 0 end
	worldReadyState = 2
	mileageEnabler = {}
	MPVehicleGE.getVehicles = function()
		local list = {}
		for gid, o in pairs(game.objects) do if o.sid then list[o.sid] = {gameVehicleID = gid} end end
		return list
	end

	-- The garage computer: close and cancel reopen its menu, which fires the stock hook.
	career_modules_computer = {openMenu = function() extensions.hook("onComputerMenuOpened") end}
	career_career = {isAutosaveEnabled = function() return game.autosave end, closeAllMenus = function() end}
	career_saveSystem = {saveCurrent = function() game.saving = true end}

	-- partShopping.lua: a session is open from startShoppingActual to endShopping. Fitting or
	-- removing a part rebuilds the car; cancel fires its hook, rebuilds the car from its saved
	-- entry and ends; Buy ends (closing the menu at once, or once the save finishes) and fires
	-- its hook. Mileage's patches turn the stock start hook into onPartShoppingStartedMP.
	local shoppingActive, closeAfterSave = false, false
	local tries = 0
	local function closeMenu() career_modules_computer.openMenu({}) end
	local function endShopping(afterSave)
		closeAfterSave = career_career.isAutosaveEnabled() and afterSave
		shoppingActive = false
		if not closeAfterSave then closeMenu() end
	end
	career_modules_partShopping = {
		startShopping = function()
			shoppingActive = true
			game.preview = copyCar(game.saved[INV])
			extensions.hook("onPartShoppingStarted")
			extensions.hook("onPartShoppingStartedMP", CAR, INV)
		end,
		-- Mileage's patches fire onPartShoppingPartInstalledMP after the game's installPart.
		installPart = function()
			if not shoppingActive then return end
			tries = tries + 1
			game.preview.partConditions["/body/new" .. tries] =
				{visualState = {paint = {originalPaints = paintOf(tries + 3)}}}
			rebuild(CAR, "try" .. tries)
			extensions.hook("onPartShoppingPartInstalledMP", {part = {}, inventoryId = INV})
		end,
		removePart = function()
			if not shoppingActive then return end
			game.preview.partConditions["/body/new" .. tries] = nil
			tries = tries + 1
			rebuild(CAR, "try" .. tries)
		end,
		-- The cancel puts the car back from its saved entry through inventory.spawnVehicle,
		-- which Mileage's patches follow with onInventorySpawnVehicleMP.
		cancelShopping = function()
			if not shoppingActive then return end
			extensions.hook("onPartShoppingCancelled")
			rebuild(CAR, "stock")
			extensions.hook("onInventorySpawnVehicleMP", INV, CAR)
			endShopping()
		end,
		-- Buy writes the copy to the saved car; Mileage's patches fire
		-- onPartShoppingTransactionCompleteMP once the game's applyShopping returns.
		applyShopping = function()
			game.saved[INV] = game.preview
			endShopping(true)
			if game.autosave then career_saveSystem.saveCurrent({INV}) end
			extensions.hook("onPartShoppingTransactionComplete")
			extensions.hook("onPartShoppingTransactionCompleteMP", INV)
		end,
		onVehicleSaveFinished = function()
			if closeAfterSave then closeMenu(); closeAfterSave = false end
		end,
		isShoppingSessionActive = function() return shoppingActive end,
	}

	-- tuning.lua: Apply rebuilds the car (inventory.spawnVehicle, replaceOption 2); cancel
	-- applies the old values and closes from the rebuild's callback; Buy closes at once or
	-- once the save finishes. The session has no flag of its own: close reopens the computer.
	local tuningVars = 0
	career_modules_tuning = {
		start = function()
			extensions.hook("onCareerTuningStarted")
			extensions.hook("onCareerTuningStartedMP", CAR, INV)
		end,
		apply = function(callback)
			tuningVars = tuningVars + 1
			rebuild(CAR, "tune" .. tuningVars)
			extensions.hook("onCareerTuningApplied")
			if callback then callback() end
		end,
		close = function() career_modules_computer.openMenu({}) end,
		cancelShopping = function() career_modules_tuning.apply(career_modules_tuning.close) end,
		applyShopping = function()
			if game.autosave then game.tuningCloseAfterSave = true else career_modules_tuning.close() end
		end,
	}

	-- painting.lua: closing Painting rebuilds the car; colour changes send paint packets.
	career_modules_painting = {
		start = function() extensions.hook("onVehiclePaintingUiOpenedMP", CAR, INV) end,
		paint = function() MPGameNetwork.send(MPNetworkHelpers.generatePacketBuffer('Op', "0-" .. CAR, "{paint}")) end,
		close = function() rebuild(CAR, "painted") end,
	}
	-- The repair: rebuilds the car.
	career_modules_insurance_insurance = {startRepair = function() rebuild(CAR, "repaired") end}

	hold = dofile(SOURCE)
	extensions.mileage_editHold = hold
	game.listeners = {hold}
	if opts.paint then
		game.paint = dofile(PAINT)
		extensions.mileagePerPartPaint = game.paint
		game.paint.onExtensionLoaded()
		game.listeners = opts.paintFirst and {game.paint, hold} or {hold, game.paint}
	end
	if hold.onExtensionLoaded then hold.onExtensionLoaded() end
	if opts.career ~= false and hold.onCareerActive then hold.onCareerActive(true) end
	return hold
end

local function frames(n)
	for _ = 1, n or 1 do
		for _, module in ipairs(game.listeners) do
			if module.onUpdate then module.onUpdate(1 / 60) end
		end
	end
end

local function lastEditConfig()
	for i = #game.wire, 1, -1 do
		local cfg = game.wire[i]:match("^Oc:[^:]*:{cfg=([^}]*)}")
		if cfg then return cfg end
	end
	return nil
end

local function sendIsBeamMPs() return MPGameNetwork.send == game.realSend end

--== A10: Parts sends one edit, on close =======================================

test("A10: Parts, 5 parts tried and 1 removed, then Buy: one edit, sent when the screen closes", function()
	setup()
	local parts = career_modules_partShopping
	parts.startShopping()
	frames()
	for _ = 1, 5 do parts.installPart(); frames() end
	parts.removePart()
	frames(3)
	same(edits("0-" .. CAR), 0, "edits sent while the screen is open")
	parts.applyShopping()
	same(edits("0-" .. CAR), 1, "edits sent when the screen closes")
	same(lastEditConfig(), "try6", "the edit sent is the finished car")
	frames(10)
	same(edits("0-" .. CAR), 1, "edits sent after the screen closed")
	expect(sendIsBeamMPs(), "BeamMP's send is put back")
end)

test("A10: Parts cancelled after 6 rebuilds: one edit, the car as it was", function()
	setup()
	local parts = career_modules_partShopping
	parts.startShopping()
	for _ = 1, 5 do parts.installPart(); frames() end
	parts.removePart()
	parts.cancelShopping()
	same(edits("0-" .. CAR), 1, "edits sent")
	same(lastEditConfig(), "stock", "the edit sent is the car put back")
	frames(10)
	same(edits("0-" .. CAR), 1, "edits sent later")
	expect(sendIsBeamMPs(), "BeamMP's send is put back")
end)

test("A10: Parts Buy with autosave on: one edit at Buy, none when the menu closes after the save", function()
	setup({autosave = true})
	local parts = career_modules_partShopping
	parts.startShopping()
	for _ = 1, 3 do parts.installPart() end
	parts.applyShopping()
	same(edits("0-" .. CAR), 1, "edits sent at Buy")
	frames(5)
	parts.onVehicleSaveFinished()
	frames(5)
	same(edits("0-" .. CAR), 1, "edits sent after the save")
end)

test("a Parts session that ends without a hook Mileage hears is still ended on the next frame", function()
	setup()
	local parts = career_modules_partShopping
	parts.startShopping()
	parts.installPart()
	-- The game's session flag drops without Buy, cancel or the computer menu.
	career_modules_computer.openMenu = function() end
	parts.cancelShopping()
	same(edits("0-" .. CAR), 0, "edits sent before the frame")
	frames()
	same(edits("0-" .. CAR), 1, "edits sent on the next frame")
	expect(sendIsBeamMPs(), "BeamMP's send is put back")
end)

test("a Parts session with nothing rebuilt sends no edit on close", function()
	setup()
	career_modules_partShopping.startShopping()
	frames(3)
	career_modules_partShopping.applyShopping()
	frames(3)
	same(edits(), 0, "edits sent")
	expect(sendIsBeamMPs(), "BeamMP's send is put back")
end)

--== A11: Tuning sends one edit, on close ======================================

test("A11: Tuning, 3 applies then Buy: one edit, sent on close", function()
	setup()
	local tuning = career_modules_tuning
	tuning.start()
	for _ = 1, 3 do tuning.apply(); frames(2) end
	same(edits("0-" .. CAR), 0, "edits sent while Tuning is open")
	tuning.applyShopping()
	same(edits("0-" .. CAR), 1, "edits sent on close")
	same(lastEditConfig(), "tune3", "the edit sent is the tuned car")
	frames(10)
	same(edits("0-" .. CAR), 1, "edits sent after close")
	expect(sendIsBeamMPs(), "BeamMP's send is put back")
end)

test("A11: Tuning cancelled after 3 applies: one edit, sent after the car is put back", function()
	setup()
	local tuning = career_modules_tuning
	tuning.start()
	for _ = 1, 3 do tuning.apply() end
	tuning.cancelShopping()
	same(edits("0-" .. CAR), 1, "edits sent")
	same(lastEditConfig(), "tune4", "the edit sent is the car after the cancel's rebuild")
end)

test("A11: Tuning Buy with autosave on: the edit goes when the menu closes after the save", function()
	setup({autosave = true})
	local tuning = career_modules_tuning
	tuning.start()
	tuning.apply()
	tuning.apply()
	tuning.applyShopping()
	frames(5)
	same(edits("0-" .. CAR), 0, "edits sent while the save runs")
	tuning.close()
	same(edits("0-" .. CAR), 1, "edits sent once the menu closes")
end)

--== the awkward cases =========================================================

test("an edit of another car during the session goes out at once", function()
	setup()
	career_modules_partShopping.startShopping()
	career_modules_partShopping.installPart()
	game.rebuild(OTHER, "theirs")
	same(edits("0-" .. OTHER), 1, "edits of the other car")
	same(edits("0-" .. CAR), 0, "edits of the session's car")
end)

-- Rejects a match on the server id without its closing colon: car 0-110 starts with 0-11.
test("an edit of a car whose server id starts with the session car's id goes out at once", function()
	setup()
	game.objects[110] = {id = 110, own = true, sid = "0-110", config = "stock"}
	career_modules_partShopping.startShopping()
	career_modules_partShopping.installPart()
	game.rebuild(110, "theirs")
	same(edits("0-110"), 1, "edits of car 0-110")
	same(edits("0-11"), 0, "edits of the session's car 0-11")
end)

-- Rejects a hold that stays on after its session: a Parts visit closed, the next rebuild
-- of the same car (a repair) goes out at once.
test("after Parts closes, the next rebuild of the same car goes out at once", function()
	setup()
	local parts = career_modules_partShopping
	parts.startShopping()
	parts.installPart()
	parts.applyShopping()
	frames()
	same(edits("0-" .. CAR), 1, "edits once Parts closed")
	career_modules_insurance_insurance.startRepair()
	same(edits("0-" .. CAR), 2, "edits after the repair")
	expect(sendIsBeamMPs(), "BeamMP's send is its own again")
end)

test("every other packet passes during the session, paint and spawns included", function()
	setup()
	career_modules_partShopping.startShopping()
	MPGameNetwork.send(MPNetworkHelpers.generatePacketBuffer('Zp', "0-" .. CAR, "{pos}"))
	MPGameNetwork.send(MPNetworkHelpers.generatePacketBuffer('Op', "0-" .. CAR, "{paint}"))
	MPGameNetwork.send(MPNetworkHelpers.generatePacketBuffer('Os', 0, "{spawn}"))
	MPGameNetwork.send('A')
	same(sentOf("Zp", "0-" .. CAR), 1, "positions")
	same(sentOf("Op", "0-" .. CAR), 1, "paint")
	same(sentOf("Os"), 1, "spawns")
	same(game.wire[#game.wire], "A", "a plain text packet")
end)

test("A12: career stop mid-session sends the held edit once and edits flow again", function()
	setup()
	local parts = career_modules_partShopping
	parts.startShopping()
	parts.installPart()
	parts.installPart()
	hold.onCareerActive(false)
	same(edits("0-" .. CAR), 1, "edits sent at career stop")
	same(lastEditConfig(), "try2", "the edit sent")
	expect(sendIsBeamMPs(), "BeamMP's send is put back")
	game.rebuild(CAR, "later")
	same(edits("0-" .. CAR), 2, "a later edit goes out at once")
	parts.cancelShopping()
	same(edits("0-" .. CAR), 3, "the cancel's rebuild goes out, and nothing more")
end)

test("A12: leaving the server mid-session sends nothing and puts BeamMP's send back", function()
	setup()
	career_modules_partShopping.startShopping()
	career_modules_partShopping.installPart()
	hold.onBeamMPServerLeave()
	same(edits(), 0, "edits sent")
	expect(sendIsBeamMPs(), "BeamMP's send is put back")
	frames(5)
	same(edits(), 0, "edits sent after leaving")
end)

test("A12: a failure inside the hold sends the held edit once and edits flow again", function()
	setup()
	local parts = career_modules_partShopping
	parts.startShopping()
	parts.installPart()
	parts.installPart()
	-- A packet that cannot be read breaks the check; it still reaches BeamMP's send.
	local broken = newBuffer()
	broken.raises = true
	MPGameNetwork.send(broken)
	same(edits("0-" .. CAR), 1, "the held edit, sent")
	expect(sendIsBeamMPs(), "BeamMP's send is put back")
	same(countLines(logs, "E mileage.editHold"), 1, "the failure is logged")
	parts.installPart()
	same(edits("0-" .. CAR), 2, "the next edit goes out at once")
end)

test("A12: a held car gone before the close sends nothing and does not fail", function()
	setup()
	career_modules_partShopping.startShopping()
	career_modules_partShopping.installPart()
	game.objects[CAR] = nil
	career_modules_partShopping.applyShopping()
	same(edits(), 0, "edits sent")
	expect(sendIsBeamMPs(), "BeamMP's send is put back")
end)

test("A13: Painting and Repair are not held, and paint goes out live", function()
	setup()
	career_modules_painting.start()
	career_modules_painting.paint()
	career_modules_painting.paint()
	same(sentOf("Op", "0-" .. CAR), 2, "paint packets")
	career_modules_painting.close()
	same(edits("0-" .. CAR), 1, "Painting's rebuild")
	career_modules_insurance_insurance.startRepair()
	same(edits("0-" .. CAR), 2, "the repair's rebuild")
	expect(sendIsBeamMPs(), "BeamMP's send untouched")
end)

test("A13: Painting opened while a Tuning session is still held sends the held edit first", function()
	setup()
	career_modules_tuning.start()
	career_modules_tuning.apply()
	career_modules_painting.start()
	same(edits("0-" .. CAR), 1, "the held tuning edit")
	career_modules_painting.close()
	same(edits("0-" .. CAR), 2, "Painting's rebuild goes out at once")
end)

test("a second session on another car ends the first, which sends its edit", function()
	setup()
	career_modules_tuning.start()
	career_modules_tuning.apply()
	hold.onPartShoppingStartedMP(OTHER, 2)
	same(edits("0-" .. CAR), 1, "the first car's held edit")
	game.rebuild(OTHER, "parts")
	game.rebuild(CAR, "again")
	same(edits("0-" .. OTHER), 0, "the second car's edit is held")
	same(edits("0-" .. CAR), 2, "the first car's edits flow again")
end)

test("outside a server session nothing is held and BeamMP's send is untouched", function()
	setup({mp = false})
	career_modules_partShopping.startShopping()
	expect(sendIsBeamMPs(), "BeamMP's send untouched")
end)

test("a BeamMP without sendVehicleEdit is reported and nothing is held", function()
	setup()
	MPVehicleGE.sendVehicleEdit = nil
	career_modules_partShopping.startShopping()
	career_modules_partShopping.installPart()
	same(edits("0-" .. CAR), 1, "edits sent as BeamMP sends them")
	expect(sendIsBeamMPs(), "BeamMP's send untouched")
	expect(countLines(logs, "sendVehicleEdit") >= 1, "the missing function is logged")
end)

test("a session's car with no server id yet holds nothing", function()
	setup()
	game.objects[CAR].sid = nil
	career_modules_partShopping.startShopping()
	expect(sendIsBeamMPs(), "BeamMP's send untouched")
end)

test("a send wrapped again over the hold is left in place when the session ends", function()
	setup()
	career_modules_partShopping.startShopping()
	local ours = MPGameNetwork.send
	local outer = function(data) return ours(data) end
	MPGameNetwork.send = outer
	career_modules_partShopping.installPart()
	career_modules_partShopping.applyShopping()
	same(MPGameNetwork.send, outer, "the later wrapper stays")
	same(edits("0-" .. CAR), 1, "edits sent")
end)

--== part paint while the edits are held ========================================
-- mileagePerPartPaint sends each painted part of a car to every other game. While the
-- car's edits are held the other games still have the car as it was, so nothing is sent;
-- once the finished car reaches them they ask for its paints, as after any rebuild.

-- The part paints this game sent for others since the last clear: {partPath = paints} and
-- how many messages.
local function paintsSent()
	local byPart, n = {}, 0
	for _, m in ipairs(game.toServer) do
		if m.name == "perPartPainting" then
			n = n + 1
			byPart[m.data.partPath] = m.data.paints
		end
	end
	return byPart, n
end

-- Another game built the car and asks its owner for the part paints.
local function otherGameAsks()
	game.toServer = {}
	game.handlers.rxRequestPartPaints({serverVehicleID = "0-" .. CAR})
	return paintsSent()
end

-- Every painted part of the saved car was sent, with its paint, and nothing else.
local function sentAllOf(car, byPart, n)
	local parts = 0
	for path, cond in pairs(car.partConditions) do
		parts = parts + 1
		expect(byPart[path] == cond.visualState.paint.originalPaints, "paint of " .. path)
	end
	same(n, parts, "paints sent")
end

for _, paintFirst in ipairs({false, true}) do
	local order = paintFirst and " (paint sync hears the hooks first)" or ""
	test("Parts with 5 parts fitted sends no part paint while open; after Buy the other game's request " ..
			"gets the finished car's paints" .. order, function()
		setup({paint = true, paintFirst = paintFirst})
		local parts = career_modules_partShopping
		parts.startShopping()
		frames()
		for _ = 1, 5 do parts.installPart(); frames() end
		local _, during = paintsSent()
		same(during, 0, "part paints sent while Parts is open")
		parts.applyShopping()
		same(edits("0-" .. CAR), 1, "edits sent on close")
		frames(3)
		local byPart, n = otherGameAsks()
		same(n, 8, "painted parts of the finished car")
		sentAllOf(game.saved[INV], byPart, n)
		expect(byPart["/body/new5"] ~= nil, "a part fitted in the session is in the answer")
	end)
end

test("Buy still sends the finished car's paints once, as before", function()
	setup({paint = true})
	local parts = career_modules_partShopping
	parts.startShopping()
	for _ = 1, 2 do parts.installPart() end
	game.toServer = {}
	parts.applyShopping()
	local byPart, n = paintsSent()
	sentAllOf(game.saved[INV], byPart, n)
end)

test("a car with 3 painted parts: career stop mid-Parts still leaves others with the right paint", function()
	setup({paint = true})
	local parts = career_modules_partShopping
	parts.startShopping()
	frames()
	parts.installPart()
	parts.installPart()
	frames()
	local _, during = paintsSent()
	same(during, 0, "part paints sent while Parts is open")
	hold.onCareerActive(false)
	same(edits("0-" .. CAR), 1, "the held edit, sent at career stop")
	local byPart, n = otherGameAsks()
	same(n, 3, "painted parts sent")
	sentAllOf(game.saved[INV], byPart, n)
	-- Paint flows again for the car.
	game.toServer = {}
	game.rebuild(CAR, "later")
	local _, after = paintsSent()
	same(after, 3, "part paints after a later rebuild")
end)

test("Parts cancelled: nothing sent while open, then the other game's request gets the car as it was", function()
	setup({paint = true})
	local parts = career_modules_partShopping
	parts.startShopping()
	for _ = 1, 3 do parts.installPart() end
	parts.cancelShopping()
	local _, during = paintsSent()
	same(during, 0, "part paints sent up to the close")
	same(edits("0-" .. CAR), 1, "edits sent")
	local byPart, n = otherGameAsks()
	sentAllOf(game.saved[INV], byPart, n)
	same(n, 3, "painted parts of the car put back")
end)

test("Tuning applies send no part paint while Tuning is open", function()
	setup({paint = true})
	career_modules_tuning.start()
	for _ = 1, 3 do career_modules_tuning.apply(); frames() end
	local _, during = paintsSent()
	same(during, 0, "part paints sent while Tuning is open")
	career_modules_tuning.applyShopping()
	local byPart, n = otherGameAsks()
	sentAllOf(game.saved[INV], byPart, n)
end)

test("Painting is unchanged: its rebuild sends the car's part paints at once", function()
	setup({paint = true})
	career_modules_painting.start()
	career_modules_painting.close()
	local byPart, n = paintsSent()
	sentAllOf(game.saved[INV], byPart, n)
end)

test("Parts on a car whose edits are not held sends its paints as before, at start and on each part", function()
	setup({paint = true})
	MPVehicleGE.sendVehicleEdit = nil
	local parts = career_modules_partShopping
	parts.startShopping()
	frames()
	local _, atStart = paintsSent()
	same(atStart, 3, "part paints at Parts start")
	game.toServer = {}
	parts.installPart()
	local _, onPart = paintsSent()
	same(onPart, 6, "part paints for a part fitted (its rebuild and the part)")
end)
