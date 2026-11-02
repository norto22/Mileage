--Mileage (SERVER)
--Based on CareerMP, created by Dudekahedron
--Thanks to Bouboule, and Lion and Luuk from BeamPaint, for http request examples
--
--This file touches no game Lua -- it is pure BeamMP API (MP.*, Util.*, FS.*) -- so it
--does not depend on the BeamNG.drive version. The drag relay carries BeamNG's own
--multiplayer drag protocol between clients without interpreting it.

-- Identifies which Mileage line these files belong to. The updater refuses any remote
-- version file that does not carry this exact value, so another repository's
-- higher-numbered releases are never pulled over this one. Keep it in sync with the
-- `lineage` field in versions/client.json and versions/server.json.
local LINEAGE = "norto22/Mileage"

local HARD_CLIENT_VERSION = {major = 0, minor = 4, revision = 1, lineage = LINEAGE}
local HARD_SERVER_VERSION = {major = 0, minor = 4, revision = 1, lineage = LINEAGE}

local RAW = "https://raw.githubusercontent.com/"
local GITHUB_REPO = "norto22/Mileage/"
local BRANCH = "main/"
local CLIENT_PATH = "Resources/Client/"
local CLIENT_FILE = "Mileage.zip"
local SERVER_PATH = "Resources/Server/Mileage/"
local SERVER_FILE = "mileage.lua"
local CLIENT_VERSION_FILE = "versions/client.json"
local SERVER_VERSION_FILE = "versions/server.json"
local CLIENT_URL = RAW .. GITHUB_REPO .. BRANCH .. CLIENT_PATH .. CLIENT_FILE
local SERVER_URL = RAW .. GITHUB_REPO .. BRANCH .. SERVER_PATH .. SERVER_FILE
local CLIENT_UPDATE_URL = RAW .. GITHUB_REPO .. BRANCH .. SERVER_PATH .. CLIENT_VERSION_FILE
local SERVER_UPDATE_URL = RAW .. GITHUB_REPO .. BRANCH .. SERVER_PATH .. SERVER_VERSION_FILE

local configPath = "Resources/Server/Mileage/config/"

local willExit = false

local defaultConfig = {
	server = {
		autoUpdate = true,
		autoExit = true,
		longWindowMax = 10000,
		shortWindowMax = 1000,
		longWindowSeconds = 300,
		shortWindowSeconds = 30,
		allowTransactions = true,
		sessionSendingMax = 100000,
		sessionReceiveMax = 200000,
		-- Traffic across the whole server, 0 to 400 of each kind; 0 means no limit. Each
		-- player spawns client.roadTrafficAmount and parkedTrafficAmount until the players
		-- together would pass these totals, then the totals are split between them.
		roadTrafficTotal = 18,
		parkedTrafficTotal = 24,
		-- Players may challenge each other to street races, ask each other for money, and
		-- the owner may schedule race events (Mileage Event).
		allowRacing = true,
		allowMoneyRequests = true,
		allowEvents = true,
		-- The largest stake a race challenge may carry, 0 to 1000000; 0 means no stakes.
		raceStakeMax = 10000,
		-- Money the server adds for the winner of a race between players, 0 to 1000000;
		-- 0 is off. The same two players earn it at most once per cooldown (0 to 1440 min).
		racePrize = 0,
		racePrizeCooldownMinutes = 10,
		-- Players may race one of their own traffic cars on the road ("Race this car" in the
		-- prompts app). aiRacePrize is the race reward the server pays the first player who
		-- beats the traffic car, 0 to 1000000 (0 is off), plus half of it for each player who
		-- joined; one player earns it at most once per cooldown (0 to 1440 min).
		allowAiRaces = true,
		aiRacePrize = 0,
		aiRacePrizeCooldownMinutes = 10,
		-- The shortest race allowed, in metres from start to finish (0 to 20000), and the
		-- time after which a race nobody finished ends with both stakes back (1 to 120 min).
		raceMinDistance = 500,
		raceTimeLimitMinutes = 15,
	},
	client = {
		localUnicycleGhost = false,
		remoteUnicycleGhost = true,
		remoteVehicleGhost = false,
		serverSaveName = "",
		serverSaveSuffix = "",
		serverSaveNameEnabled = false,
		-- Traffic each player spawns, shared with every other player: a server with two
		-- players has twice these amounts on the map. 0 to 50 of each kind.
		roadTrafficAmount = 6,
		parkedTrafficAmount = 8,
		roadTrafficEnabled = true,
		parkedTrafficEnabled = true,
		worldEditorEnabled = false,
		consoleEnabled = false,
		simplifyRemoteVehicles = false,
		spawnVehicleIgnitionLevel = 0,
		skipOtherPlayersVehicles = false,
		trafficSmartSelections = true,
		trafficSimpleVehicles = true,
		trafficAllowMods = false,
		-- Head-to-head drag racing. On by default.
		--
		-- This un-stubs BeamNG 0.39's own multiplayer drag racing
		-- (gameplay/drag/core.lua getDragGamemode, which ships hard-wired to nil), so
		-- staging, the tree, timers and the result screen are the game's, driven over
		-- BeamMP. Two players drive to a strip, stage, and race on one synchronised tree.
		--
		-- Verified with two players at one strip on west_coast_usa, including solo runs,
		-- false starts and leaving AI drag missions alone. NOT verified with more than
		-- two, so treat a busy strip as untested.
		--
		-- Set false to go back to stock behaviour: drag racing still works exactly as it
		-- does in single player, just not synchronised between players. Worth doing if a
		-- BeamNG update breaks it - the client logs why on join, and falls back on its
		-- own rather than failing hard.
		nativeDragSyncEnabled = true
	}
}

-- Settings earlier versions wrote that are no longer read. prepareConfig removes them
-- from a config like any unknown setting, with this reason instead of "is invalid".
local retiredConfig = {
	client = {
		extraTrafficAmount = "extra traffic was never used by the game",
		extraTrafficEnabled = "extra traffic was never used by the game",
	},
}

-- Players whose career has not started yet, by player id. A player is dropped with
-- "Mileage failed to load!" when no settings request arrives within activationThreshold
-- seconds of joining, or, for a client that confirms its career start, when the client
-- reports a failure or no confirmation arrives within startConfirmThreshold seconds of
-- the settings request. A client that does not confirm (an older client mod) counts as
-- started at its settings request.
local pendingActivation = {}
local activationThreshold = 90
local startConfirmThreshold = 60
local START_REASON_MAX_LENGTH = 200
local vehicleStates = {}
local loadedPrefabs = {}

local signalTimer = MP.CreateTimer()

-- Every connected player hears rxMileageAlive this often, in ticks of one second. A
-- client that hears nothing for ten seconds tells its player the server is gone.
local ALIVE_EVERY_TICKS = 2
local ticksSinceAlive = 0

local ledger = {
	send = {},
	receive = {}
}

--== Readout =================================================================
-- Every message the server sends goes through send, sendJson or notify, which count it
-- under one feature; every handler counts what it receives. `Mileage Stats` prints the
-- counts for the last STATS_SECONDS and since the server started (or the last reset).
-- Positions are BeamMP's own and are not counted here; the car count stands in for them.

local STATS_SECONDS = 60
local STATS_FEATURES = {"damage", "carStates", "trafficMarks", "trafficShare", "paint", "prefabs", "drag",
	"payments", "transfers", "offers", "races", "leaderboard", "events", "aiRaces", "alive", "trafficLights",
	"notifications", "config"}

-- totals[feature] and slots[second % STATS_SECONDS].counts[feature]:
-- {received, sent, recipients, bytes}.
local stats = nil

local function resetStats()
	stats = {since = signalTimer:GetCurrent(), totals = {}, slots = {}}
end
resetStats()

local function countsIn(group, feature)
	local counts = group[feature]
	if not counts then
		counts = {received = 0, sent = 0, recipients = 0, bytes = 0}
		group[feature] = counts
	end
	return counts
end

local function currentSlot()
	local second = math.floor(signalTimer:GetCurrent())
	local index = second % STATS_SECONDS
	local slot = stats.slots[index]
	if not slot or slot.second ~= second then
		slot = {second = second, counts = {}}
		stats.slots[index] = slot
	end
	return slot.counts
end

local function count(feature, received, sent, recipients, bytes)
	for _, group in ipairs({stats.totals, currentSlot()}) do
		local counts = countsIn(group, feature)
		counts.received = counts.received + received
		counts.sent = counts.sent + sent
		counts.recipients = counts.recipients + recipients
		counts.bytes = counts.bytes + bytes
	end
end

local function playerCount()
	local n = 0
	for _ in pairs(MP.GetPlayers() or {}) do n = n + 1 end
	return n
end

local function recipientsOf(target)
	if target == -1 then return playerCount() end
	return 1
end

-- A message a handler of `feature` received.
local function received(feature)
	count(feature, 1, 0, 0, 0)
end

local function send(feature, target, event, data)
	data = data or ""
	MP.TriggerClientEvent(target, event, data)
	local recipients = recipientsOf(target)
	count(feature, 0, 1, recipients, #data * recipients)
end

-- Encodes once; the counted bytes are the bytes BeamMP sends.
local function sendJson(feature, target, event, value)
	send(feature, target, event, Util.JsonEncode(value))
end

local function notify(feature, target, text, ...)
	MP.SendNotification(target, text, ...)
	local recipients = recipientsOf(target)
	count(feature, 0, 1, recipients, #tostring(text) * recipients)
end

local function decodeTable(data)
	if type(data) ~= "string" or data == "" then return nil end
	local ok, decoded = pcall(Util.JsonDecode, data)
	if ok and type(decoded) == "table" then return decoded end
	return nil
end

-- Console-safe text from a client: control characters removed, length capped.
local function consoleText(text)
	return (tostring(text):gsub("%c", " "):sub(1, START_REASON_MAX_LENGTH))
end

-- true for a car its owner's game marked as traffic or parked. Such a car never answers
-- a request for its damage or paint, so the requests are dropped.
local function isTraffic(serverVehicleID)
	local state = vehicleStates[serverVehicleID]
	return type(state) == "table" and state.traffic == true
end

local trapNames = {
	[1] = "Riverway Plaza",
	[2] = "Plaza Northbound",
	[3] = "Plaza Southbound",
	[4] = "Beach",
	[5] = "Lighthouse",
	[6] = "Island Port Northbound",
	[7] = "Island Port Southbound"
}

-- Runs the platform's downloader. Returns true only when the command reports success.
local function fetchTo(url, path)
	local result
	if MP.GetOSName() == "Windows" then
		result = os.execute('powershell -Command "Invoke-WebRequest -Uri ' .. url .. ' -OutFile ' .. path .. '"')
	else
		result = os.execute("wget -q -O " .. path .. " " .. url)
	end
	return result == true or result == 0
end

local function fileSize(path)
	local file = io.open(path, "rb")
	if not file then return 0 end
	local size = file:seek("end")
	file:close()
	return size or 0
end

local function downloadVersionFile(url, path)
	if not fetchTo(url, path) then
		return nil
	end
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local data = file:read("*all")
	file:close()
	return data
end

-- Downloads url over path without ever leaving path broken. The download lands in a
-- temporary file; only once that is complete and non-empty is the installed file moved
-- aside and the new one swapped in, and a failed swap puts the old file back.
-- Returns true only when the new file is in place.
local function downloadFile(url, path)
	local tempPath = path .. ".download"
	local backupPath = path .. ".bak"
	os.remove(tempPath)

	if not fetchTo(url, tempPath) or fileSize(tempPath) == 0 then
		os.remove(tempPath)
		print("[Mileage] ---------- Mileage Update Download failed: " .. url)
		return false
	end

	local hadInstalled = FS.Exists(path)
	if hadInstalled then
		os.remove(backupPath)
		if not os.rename(path, backupPath) then
			os.remove(tempPath)
			print("[Mileage] ---------- Mileage Update Could not move " .. path .. " aside, nothing was changed")
			return false
		end
	end

	if not os.rename(tempPath, path) then
		if hadInstalled then
			os.rename(backupPath, path)
		end
		os.remove(tempPath)
		print("[Mileage] ---------- Mileage Update Could not replace " .. path .. ", the installed file was kept")
		return false
	end

	if hadInstalled then
		os.remove(backupPath)
	end
	return true
end

local function needsUpdate(installedVersion, latest)
    local components = { "major", "minor", "revision" }
    -- ipairs, not pairs: this must compare major before minor before revision, and
    -- pairs does not guarantee order. Compared revision-first, 0.9.9 -> 1.0.0 would
    -- see 0 < 9, return "no update", and servers would silently never pick it up.
    for _, key in ipairs(components) do
        local i, l = installedVersion[key] or 0, latest[key] or 0
        if l > i then
            return true
        end
        if l < i then
            return false
        end
    end
    return false
end

-- Fetches a remote version file to a scratch path, never over the installed version
-- record: that record is the only evidence of what is actually installed, so it is
-- written only after an update really lands.
local function fetchRemoteVersion(url)
	local tempPath = SERVER_PATH .. "versions/.remote.json"
	local data = downloadVersionFile(url, tempPath)
	if not data then return nil end
	return Util.JsonDecode(data)
end

-- Refuses content from a different lineage.
--
-- Version numbers alone cannot tell "a newer release of this repository" from "an
-- unrelated codebase with a higher number". Without this check, an update source with
-- higher numbers would be pulled over this install and, with autoExit on, shut the
-- server down afterwards.
local function lineageMatches(remote)
	return remote.lineage == LINEAGE
end

local function describeVersion(v)
	if not v then return "unknown" end
	return string.format("%s.%s.%s", tostring(v.major), tostring(v.minor), tostring(v.revision))
end

-- Shared by the client and server updaters, which were duplicates of each other.
local function runUpdate(opts)
	local installedVersion = ReadJson(SERVER_PATH .. opts.versionFile)

	if not FS.Exists(opts.filePath) then
		print("[Mileage] ---------- Mileage Update " .. opts.label .. " not installed, downloading...")
		if not downloadFile(opts.fileUrl, opts.filePath) then
			print("[Mileage] ---------- Mileage Update " .. opts.label .. " could not be downloaded!")
			return false
		end
	end

	if not installedVersion then
		print("[Mileage] ---------- Mileage Update Applying self version!")
		installedVersion = opts.hardVersion
		WriteJson(SERVER_PATH .. opts.versionFile, opts.hardVersion)
	end

	local latest = fetchRemoteVersion(opts.updateUrl)
	if not latest then
		print("[Mileage] ---------- Mileage Update Failed to fetch latest " .. opts.label:lower() .. " version!")
		return false
	end

	if not lineageMatches(latest) then
		print("[Mileage] ---------- Mileage Update REFUSED for " .. opts.label .. ": remote is a different lineage")
		print("[Mileage] ----------   expected lineage: " .. LINEAGE)
		print("[Mileage] ----------   remote lineage:   " .. tostring(latest.lineage or "none (upstream Mileage?)"))
		print("[Mileage] ----------   Nothing was changed. Check that the update repository is correct,")
		print("[Mileage] ----------   or set server.autoUpdate to false while testing local changes.")
		return false
	end

	print("[Mileage] ---------- Mileage Update " .. opts.label .. " installed: " .. describeVersion(installedVersion))
	print("[Mileage] ---------- Mileage Update " .. opts.label .. " latest: " .. describeVersion(latest))

	if needsUpdate(installedVersion, latest) then
		print("[Mileage] ---------- Mileage Update Updating " .. opts.label:lower() .. "...")
		if not downloadFile(opts.fileUrl, opts.filePath) then
			print("[Mileage] ---------- Mileage Update " .. opts.label .. " update failed, staying on " .. describeVersion(installedVersion))
			return false
		end
		-- Record the new version only now that the file behind it is actually in place.
		WriteJson(SERVER_PATH .. opts.versionFile, latest)
		print("[Mileage] ---------- Mileage Update " .. opts.label .. " updated to " .. describeVersion(latest) .. "! Restart the server to apply the update!")
		return true
	end

	-- Same lineage but older: a rollback on the remote, or a stale branch. Never applied
	-- silently, because that would overwrite a working install with an older one.
	if needsUpdate(latest, installedVersion) then
		print("[Mileage] ---------- Mileage Update " .. opts.label .. " remote is OLDER than installed - refusing to downgrade")
		return false
	end

	print("[Mileage] ---------- Mileage Update " .. opts.label .. " up to date!")
	return false
end

local function updateClient()
	return runUpdate({
		label = "Client",
		versionFile = CLIENT_VERSION_FILE,
		filePath = CLIENT_PATH .. CLIENT_FILE,
		fileUrl = CLIENT_URL,
		updateUrl = CLIENT_UPDATE_URL,
		hardVersion = HARD_CLIENT_VERSION,
	})
end

local function updateServer()
	return runUpdate({
		label = "Server",
		versionFile = SERVER_VERSION_FILE,
		filePath = SERVER_PATH .. SERVER_FILE,
		fileUrl = SERVER_URL,
		updateUrl = SERVER_UPDATE_URL,
		hardVersion = HARD_SERVER_VERSION,
	})
end

-- Checks both parts. Either one updating is enough to restart, when autoExit allows it.
local function checkForUpdates()
	if not FS.IsDirectory(SERVER_PATH .. "/versions") then
		FS.CreateDirectory(SERVER_PATH .. "/versions")
	end
	local clientUpdated = updateClient()
	local serverUpdated = updateServer()
	if (clientUpdated or serverUpdated) and Config.server.autoExit then
		willExit = true
	end
end

local function parseQuotedString(input, startIndex)
	local closingQuoteIndex = input:find('"', startIndex + 1)
	if closingQuoteIndex then
		local value = input:sub(startIndex + 1, closingQuoteIndex - 1)
		return value, closingQuoteIndex + 2
	else
		local value = input:sub(startIndex + 1)
		return value, nil
	end
end

local function parseWord(input, startIndex)
	local nextSpaceIndex = input:find(' ', startIndex)
	if nextSpaceIndex then
		local value = input:sub(startIndex, nextSpaceIndex - 1)
		return value, nextSpaceIndex + 1
	else
		return input:sub(startIndex), nil
	end
end

local function parseCommand(message, separator)
	local arguments = {}
	local command = nil
	if separator then
		command = message:sub(1, separator - 1)
		local argumentsString = message:sub(separator + 1)
		local currentIndex = 1
		while currentIndex <= #argumentsString do
			local currentChar = argumentsString:sub(currentIndex, currentIndex)
			if currentChar == '"' then
				local value, nextIndex = parseQuotedString(argumentsString, currentIndex)
				table.insert(arguments, value)
				if not nextIndex then
					break
				end
				currentIndex = nextIndex
			elseif currentChar ~= ' ' then
				local value, nextIndex = parseWord(argumentsString, currentIndex)
				table.insert(arguments, value)
				if not nextIndex then
					break
				end
				currentIndex = nextIndex
			else
				currentIndex = currentIndex + 1
			end
		end
	end
	return command, arguments
end

local function readFile(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local data = file:read("*a")
	file:close()
	return data
end

local function prepareConfig()
	print("[Mileage] ---------- Mileage Config Loading...")
	Config = ReadJson(configPath .. "config.json")
	if not Config then
		print("[Mileage] ---------- Mileage Config Initializing...")
		Config = defaultConfig
		for section, fields in pairs(defaultConfig) do
			for field, value in pairs(fields) do
				print("[Mileage] ---------- Mileage Config " .. section .. " " .. field .. " set to " .. tostring(value))
			end
		end
		WriteJson(configPath .. "config.json", Config)
	else
		local updateFound
		for section, fields in pairs(defaultConfig) do
			print("[Mileage] ---------- Mileage Config Checking " .. section)
			if Config[section] == nil then
				updateFound = true
				print("[Mileage] ---------- Mileage Config Adding: " .. section)
				Config[section] = {}
				for field, value in pairs(fields) do
					print("[Mileage] ---------- Mileage Config " .. section .. " " .. field .. " set to " .. tostring(value))
					Config[section][field] = value
				end
			else
				for field, value in pairs(fields) do
					if Config[section][field] == nil then
						print("[Mileage] ---------- Mileage Config " .. section .. " " .. field .. " not found")
						print("[Mileage] ---------- Mileage Config " .. section .. " " .. field .. " set to " .. tostring(value))
						updateFound = true
						Config[section][field] = value
					end
				end
			end
		end
		for _, section in pairs({"client", "server"}) do
			if Config[section] then
				for field in pairs(Config[section]) do
					if defaultConfig[section][field] == nil then
						local retired = retiredConfig[section] and retiredConfig[section][field]
						if retired then
							print("[Mileage] ---------- Mileage Config " .. section .. " " .. field .. " removed: " .. retired)
						else
							print("[Mileage] ---------- Mileage Config " .. section .. " " .. field .. " is invalid, removing")
						end
						updateFound = true
						Config[section][field] = nil
					end
				end
			end
		end
		if updateFound then
			print("[Mileage] ---------- Mileage Config Updated!")
			WriteJson(configPath .. "config.json", Config)
		end
	end
	print("[Mileage] ---------- Mileage Config Loaded!")
end

-- A whole-number server setting within low..high; anything else is read as the nearest
-- value in range (a non-number as low).
local function serverNumber(key, low, high)
	local n = tonumber(Config and Config.server and Config.server[key])
	if not n or n ~= n then return low end
	return math.floor(math.max(low, math.min(high, n)))
end

local function serverSwitch(key)
	return Config ~= nil and Config.server ~= nil and Config.server[key] == true
end

-- The money, racing, leaderboard and event sections below each sit in their own block and
-- share only what they must through this table, which keeps the plugin's main chunk
-- under Lua's limit of 200 local names. Money.start loads their data on a server start.
local Money = {}

--== Data files ==============================================================
-- What Mileage keeps about players between server starts: unfinished money transfers,
-- races holding stakes, the leaderboard and a scheduled event. Each file is written to
-- <name>.tmp and renamed over <name>, so a crash mid-write never leaves a half-written
-- file in place. A file that does not read is moved aside and never overwritten.

do
local DATA_PATH = SERVER_PATH .. "data/"

-- Names whose file could not be read nor moved aside: never written, so it is kept.
local unwritableData = {}

local function dataLog(text)
	print("[Mileage] ---------- Data: " .. text)
end

-- The decoded table in data/<name>, or nil when there is none (or it did not read).
local function readData(name)
	local path = DATA_PATH .. name
	local from = path
	local text = readFile(path)
	if text == nil then
		-- An interrupted write on a system where the rename needed the old file removed.
		from = path .. ".tmp"
		text = readFile(from)
		if text == nil then return nil end
	end
	local ok, value = pcall(Util.JsonDecode, text)
	if ok and type(value) == "table" then return value end
	local aside = path .. ".unreadable-" .. tostring(os.time())
	if os.rename(from, aside) then
		dataLog(from .. " could not be read; it is kept as " .. aside .. " and Mileage starts without it")
	else
		unwritableData[name] = true
		dataLog(from .. " could not be read nor moved aside; Mileage will not write " .. name
			.. " until it is fixed or removed")
	end
	return nil
end

-- Writes value to data/<name>. Returns true once the new file is in place.
local function writeData(name, value)
	if unwritableData[name] then return false end
	if not FS.Exists(DATA_PATH) then
		FS.CreateDirectory(DATA_PATH)
	end
	local ok, encoded = pcall(Util.JsonEncode, value)
	if not ok or type(encoded) ~= "string" then
		dataLog("could not encode " .. name)
		return false
	end
	local path = DATA_PATH .. name
	local tempPath = path .. ".tmp"
	local file = io.open(tempPath, "w")
	if not file then
		dataLog("could not write " .. tempPath)
		return false
	end
	local written = file:write(encoded)
	file:close()
	if not written then
		os.remove(tempPath)
		dataLog("could not write " .. tempPath)
		return false
	end
	if not os.rename(tempPath, path) then
		-- Windows does not rename over an existing file. Until the rename below, the new
		-- contents are in the .tmp file, which readData falls back to.
		os.remove(path)
		if not os.rename(tempPath, path) then
			dataLog("could not rename " .. tempPath .. " to " .. path)
			return false
		end
	end
	return true
end

Money.readData, Money.writeData = readData, writeData
end

function onInit()

	print("[Mileage] ---------- Mileage Loading...")

	MP.RegisterEvent("perPartPainting","perPartPaintingHandler")
	MP.RegisterEvent("requestPartPaints","requestPartPaintsHandler")

	MP.RegisterEvent("payPlayer","payPlayer")
	MP.RegisterEvent("mileageReceipt","mileageReceipt")
	MP.RegisterEvent("mileageOffer","mileageOffer")
	MP.RegisterEvent("mileageOfferAnswer","mileageOfferAnswer")
	MP.RegisterEvent("mileageRaceReport","mileageRaceReport")
	MP.RegisterEvent("mileageAiRace","mileageAiRace")
	MP.RegisterEvent("mileageDragTime","mileageDragTime")
	MP.RegisterEvent("mileageLeaderboard","mileageLeaderboard")

	MP.RegisterEvent("careerPrefabSync","careerPrefabSync")
	MP.RegisterEvent("careerSyncRequested","careerSyncRequested")
	MP.RegisterEvent("careerStartResult","careerStartResult")
	MP.RegisterEvent("prefabSyncRequested","prefabSyncRequested")
	MP.RegisterEvent("careerVehSyncRequested","careerVehSyncRequested")
	MP.RegisterEvent("careerVehicleActiveHandler","careerVehicleActiveHandler")
	MP.RegisterEvent("careerVehicleTrafficMarks","careerVehicleTrafficMarks")
	MP.RegisterEvent("careerDamage","careerDamage")
	MP.RegisterEvent("careerDamageRequest","careerDamageRequest")

	-- Drag racing. One enveloped relay carries BeamNG 0.39's own multiplayer drag
	-- protocol; the server routes and elects the host but never interprets a message.
	MP.RegisterEvent("dragMP", "dragMP")
	MP.RegisterEvent("dragAuthorityRequest", "dragAuthorityRequest")

	MP.RegisterEvent("speedTrap", "speedTrap")
	MP.RegisterEvent("redLight", "redLight")
	MP.RegisterEvent("trafficLightTimer","trafficLightTimer")
	MP.CreateEventTimer("trafficLightTimer", 10000)

	MP.RegisterEvent("onPlayerJoin","onPlayerJoinHandler")
	MP.RegisterEvent("onVehicleSpawn","onVehicleSpawnHandler")
	MP.RegisterEvent("onVehicleEdited","onVehicleEditedHandler")
	MP.RegisterEvent("onVehicleDeleted","onVehicleDeletedHandler")
	MP.RegisterEvent("onPlayerDisconnect","onPlayerDisconnectHandler")

	MP.RegisterEvent("onConsoleInput","onConsoleInputHandler")

	MP.RegisterEvent("GetConfig","GetConfig")
	MP.RegisterEvent("SetConfig","SetConfig")
	MP.RegisterEvent("Update","Update")
	MP.RegisterEvent("Help","Help")
	MP.RegisterEvent("Stats","Stats")
	MP.RegisterEvent("Transfers","Transfers")
	MP.RegisterEvent("Leaderboard","Leaderboard")
	MP.RegisterEvent("Event","Event")

	MP.RegisterEvent("tick","tick")
	MP.CreateEventTimer("tick", 1000)

	prepareConfig()
	Money.start()

	if Config.server.autoUpdate then
		checkForUpdates()
	end

	print("[Mileage] ---------- Mileage Loaded!")
end

function perPartPaintingHandler(player_id, data)
	received("paint")
	local paintData = Util.JsonDecode(data)
	if not paintData.originID then
		for id in pairs(MP.GetPlayers()) do
			if player_id ~= id then
				send("paint", id, "rxRemotePartPaint", data)
			end
		end
	else
		send("paint", paintData.originID, "rxRemotePartPaint", data)
	end
end

-- A game asks the owner of one car for its part paints: {"serverVehicleID"}. The owner
-- is read from the whole player number of the id.
function requestPartPaintsHandler(player_id, data)
	received("paint")
	local requestData = decodeTable(data)
	local serverVehicleID = requestData and requestData.serverVehicleID
	if type(serverVehicleID) ~= "string" or isTraffic(serverVehicleID) then return end
	local owner = tonumber(serverVehicleID:match("^(%d+)%-%d+$"))
	if not owner or not MP.GetPlayers()[owner] then return end
	requestData.originID = player_id
	sendJson("paint", owner, "rxRequestPartPaints", requestData)
end

local function getOrCreate(ledger, player_id)
	if not ledger[player_id] then
		ledger[player_id] = {
			session_total = 0,
			short_transactions = {},
			long_transactions = {}
		}
	end
	return ledger[player_id]
end

local function getWindowTotal(transactions, now, windowSeconds)
	local window_total = 0
	local cutoff = now - windowSeconds
	local kept = {}
	for _, transaction in ipairs(transactions) do
		if transaction.timestamp > cutoff then
			table.insert(kept, transaction)
			window_total = window_total + transaction.amount
		end
	end
	for i = #transactions, 1, -1 do
		transactions[i] = nil
		end
	for _, t in ipairs(kept) do
		table.insert(transactions, t)
	end
	return window_total
end

local function attemptTransaction(sender_id, receiver_id, amount, now)
	local sender = getOrCreate(ledger.send, sender_id)
	local receiver = getOrCreate(ledger.receive, receiver_id)
	local short_total = getWindowTotal(sender.short_transactions, now, Config.server.shortWindowSeconds)
	local long_total = getWindowTotal(sender.long_transactions, now, Config.server.longWindowSeconds)
	if sender.session_total + amount > Config.server.sessionSendingMax then
		return false
	end
	if short_total > 0 and short_total + amount > Config.server.shortWindowMax then
		return false
	end
	if long_total > 0 and long_total + amount > Config.server.longWindowMax then
		return false
	end
	if receiver.session_total + amount > Config.server.sessionReceiveMax then
		return false
	end
	sender.session_total = sender.session_total + amount
	receiver.session_total = receiver.session_total + amount
	if amount <= Config.server.shortWindowMax then
		table.insert(sender.short_transactions, { amount = amount, timestamp = now })
	end
	if amount <= Config.server.longWindowMax then
		table.insert(sender.long_transactions, { amount = amount, timestamp = now })
	end
	return true
end

-- The client is not trusted with the amount or the target: only a whole number of
-- dollars above zero, no more than a sender may send in a session, going to another
-- connected player, is ever relayed.
local function isValidPayment(sender_id, paymentData)
	local amount = paymentData.money
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount % 1 ~= 0 then
		return false
	end
	if amount > Config.server.sessionSendingMax then
		return false
	end
	local target = paymentData.target_player_id
	return type(target) == "number" and target ~= sender_id and MP.IsPlayerConnected(target) == true
end

--== Transfers ===============================================================
-- Every movement of money between players' careers (a payment, a race stake, its
-- refund, a race pot, a server prize) is one transfer. The server first asks the
-- payer's game to take the amount; that game takes it, records the transfer's id in the
-- same save as its money, and answers with a receipt once the save has finished. Only
-- then does the server ask the receiver's game to give it, the same way. A transfer from
-- the server starts at the giving step; one to the server (a stake) ends after taking.
--
-- data/transfers.json holds every unfinished transfer and is written before each step
-- is sent, so a server restart carries on where it stopped. A step goes to its player
-- only while their career runs: at once, again every TRANSFER_RESEND_SECONDS without a
-- receipt, and again as soon as their career starts on a later join. Nothing expires;
-- `Mileage Transfers` lists what is waiting. A game keeps the ids it applied until it
-- hears the transfer is settled (rxMileageSettled), so a step it already applied is
-- answered again without being applied twice.
--
-- A transfer id is "t<seq>-<server>": a player's save, with the ids it has applied, goes
-- with them to any Mileage server, so every server keeps a random token of its own in
-- transfers.json and no id of one server can match another's (and a server whose data
-- folder is lost starts a new token, so it cannot repeat an id either).
--
-- transferData = {server, seq, transfers = {[id] = transfer}, settled = {[name] = {id, ...}}}
-- transfer = {id, kind, from, to, amount, labels = {take, give}, state, created, race, role}
-- state: "taking" (waiting for the payer's receipt) or "giving" (for the receiver's).

do
local readData, writeData = Money.readData, Money.writeData

local SERVER_PARTY = "server"
local TRANSFER_RESEND_SECONDS = 10
local TRANSFER_SLOW_SECONDS = 60
local TRANSFER_TAGS = {"gameplay"}
local TRANSFERS_FILE = "transfers.json"

-- Eight hex digits from the clock, the process clock and a fresh table's address.
local function newServerToken()
	local seed = tostring(os.time()) .. tostring(os.clock()) .. tostring({}) .. tostring(math.random())
	local h = 5381
	for i = 1, #seed do h = (h * 33 + seed:byte(i)) % 4294967296 end
	return string.format("%08x", h)
end

local transferData = {server = newServerToken(), seq = 0, transfers = {}, settled = {}}
-- Not kept across starts: when each step was last sent, and which waits were logged.
local transferSentAt = {}
local transferSlowLogged = {}
-- True when the transfers changed but could not be written yet; nothing is sent until
-- they are.
local transfersUnsaved = false

-- Who is told when a transfer of theirs is taken, given or refused; set by the payment
-- and race sections below. transferOwners.payment(transfer, event), and so on.
local transferOwners = {}

local function saveTransfers()
	transfersUnsaved = not writeData(TRANSFERS_FILE, transferData)
	return not transfersUnsaved
end

local function playerIdByName(name)
	for id, playerName in pairs(MP.GetPlayers() or {}) do
		if playerName == name and MP.IsPlayerConnected(id) then return id end
	end
	return nil
end

local function careerStarted(player_id)
	local entry = pendingActivation[player_id]
	return entry ~= nil and entry.careerActive == true and not entry.dropped
end

-- The player the transfer waits on: the payer while taking, the receiver while giving.
local function waitingOn(transfer)
	if transfer.state == "taking" then return transfer.from end
	return transfer.to
end

local function sendStep(transfer)
	if transfersUnsaved then return false end
	local id = playerIdByName(waitingOn(transfer))
	if not id or not careerStarted(id) then return false end
	transferSentAt[transfer.id] = signalTimer:GetCurrent()
	local taking = transfer.state == "taking"
	sendJson("transfers", id, taking and "rxMileageTake" or "rxMileageGive", {
		id = transfer.id,
		kind = transfer.kind,
		amount = transfer.amount,
		label = taking and transfer.labels.take or transfer.labels.give,
		tags = TRANSFER_TAGS,
		from = transfer.from,
		to = transfer.to,
	})
	return true
end

-- Tells a player's game it may forget these ids; kept for a later join when it is away.
local function sendSettled(name, ids)
	if name == SERVER_PARTY or #ids == 0 then return end
	local id = playerIdByName(name)
	if id and careerStarted(id) then
		sendJson("transfers", id, "rxMileageSettled", {ids = ids})
		return
	end
	local waiting = transferData.settled[name] or {}
	for _, transferId in ipairs(ids) do table.insert(waiting, transferId) end
	transferData.settled[name] = waiting
end

-- Tells the transfer's owner (a payment, a race) that a step happened. false means the
-- owner could not keep that fact (a race record that would not save): the transfer then
-- stays where it is, and the game's next answer to the resend tries again.
local function tellOwner(transfer, event)
	local owner = transferOwners[transfer.race and "race" or transfer.kind]
	if owner then return owner(transfer, event) ~= false end
	return true
end

local function describeTransfer(transfer)
	return string.format("%s (%s, $%d from %s to %s)", transfer.id, transfer.kind, transfer.amount,
		consoleText(transfer.from), consoleText(transfer.to))
end

-- Starts a transfer and sends its first step. spec: {kind, from, to, amount, takeLabel,
-- giveLabel, race, role}; from or to may be SERVER_PARTY. Returns its id.
local function startTransfer(spec)
	transferData.seq = transferData.seq + 1
	local transfer = {
		id = "t" .. transferData.seq .. "-" .. transferData.server,
		kind = spec.kind,
		from = spec.from,
		to = spec.to,
		amount = spec.amount,
		labels = {take = spec.takeLabel or "", give = spec.giveLabel or ""},
		state = spec.from == SERVER_PARTY and "giving" or "taking",
		created = os.time(),
		race = spec.race,
		role = spec.role,
	}
	transferData.transfers[transfer.id] = transfer
	if saveTransfers() then sendStep(transfer) end
	return transfer.id
end

-- Removes a finished transfer from transfers.json, and only once that is on disk tells the
-- players' games they may forget its id. A game that forgot an id while the server still
-- held the transfer would apply the resend a second time after a restart. When the
-- removal cannot be written the transfer stays, nobody is told, and the game's answer to
-- the next resend tries again.
local function retire(transfer, parties)
	transferData.transfers[transfer.id] = nil
	if not saveTransfers() then
		transferData.transfers[transfer.id] = transfer
		return false
	end
	for _, name in ipairs(parties) do sendSettled(name, {transfer.id}) end
	-- Notices kept for players who are away are written too; losing one is harmless, the
	-- game then keeps an id it no longer needs.
	saveTransfers()
	return true
end

-- The game of the player a transfer waits on answers {id, done = "taken" | "given" |
-- "refused"}. Only that player's receipt for the step under way counts. The owner hears
-- of it before the transfer itself moves on, so a restart in between repeats the step
-- (which the game answers again without applying it) rather than lose it.
function mileageReceipt(player_id, data)
	received("transfers")
	local receipt = decodeTable(data)
	if not receipt or type(receipt.id) ~= "string" then return end
	local transfer = transferData.transfers[receipt.id]
	if not transfer or MP.GetPlayerName(player_id) ~= waitingOn(transfer) then return end
	if transfer.state == "taking" and receipt.done == "taken" then
		if not tellOwner(transfer, "taken") then return end
		if transfer.to == SERVER_PARTY then
			retire(transfer, {transfer.from})
			return
		end
		transfer.state = "giving"
		transferSentAt[transfer.id] = nil
		if saveTransfers() then sendStep(transfer) end
	elseif transfer.state == "taking" and receipt.done == "refused" then
		print("[Mileage] Transfer " .. describeTransfer(transfer) .. " refused: " .. consoleText(transfer.from)
			.. " does not have the money")
		if not tellOwner(transfer, "refused") then return end
		retire(transfer, {transfer.from})
	elseif transfer.state == "giving" and receipt.done == "given" then
		if not tellOwner(transfer, "given") then return end
		local parties = {transfer.to}
		if transfer.from ~= SERVER_PARTY then table.insert(parties, transfer.from) end
		retire(transfer, parties)
	end
end

-- A player's career started: the ids settled while they were away, then every step
-- waiting on them at once.
local function transfersCareerStarted(player_id)
	local name = MP.GetPlayerName(player_id)
	if not name then return end
	local settled = transferData.settled[name]
	if settled then
		transferData.settled[name] = nil
		sendSettled(name, settled)
		saveTransfers()
	end
	for _, transfer in pairs(transferData.transfers) do
		if waitingOn(transfer) == name then
			transferSentAt[transfer.id] = nil
			sendStep(transfer)
		end
	end
end

local function transfersTick()
	if transfersUnsaved and not saveTransfers() then return end
	local now = signalTimer:GetCurrent()
	for id, transfer in pairs(transferData.transfers) do
		if now - (transferSentAt[id] or -math.huge) >= TRANSFER_RESEND_SECONDS then
			sendStep(transfer)
		end
		if not transferSlowLogged[id] and os.time() - (transfer.created or 0) > TRANSFER_SLOW_SECONDS then
			transferSlowLogged[id] = true
			print("[Mileage] Transfer " .. describeTransfer(transfer) .. " has waited more than a minute for "
				.. consoleText(waitingOn(transfer)))
		end
	end
end

local function loadTransfers()
	local stored = readData(TRANSFERS_FILE)
	transferData = {server = newServerToken(), seq = 0, transfers = {}, settled = {}}
	transferSentAt, transferSlowLogged = {}, {}
	if stored then
		if type(stored.server) == "string" and stored.server:match("^%x+$") then transferData.server = stored.server end
		transferData.seq = tonumber(stored.seq) or 0
		transferData.transfers = type(stored.transfers) == "table" and stored.transfers or {}
		transferData.settled = type(stored.settled) == "table" and stored.settled or {}
		-- Ids are made from seq; a damaged seq must not hand out an id still in use.
		for id in pairs(transferData.transfers) do
			local n = tonumber(tostring(id):match("^t(%d+)%-"))
			if n and n > transferData.seq then transferData.seq = n end
		end
	end
	local waiting = 0
	for _ in pairs(transferData.transfers) do waiting = waiting + 1 end
	if waiting > 0 then
		print("[Mileage] ---------- " .. waiting .. " money transfer(s) waiting for players, see Mileage Transfers")
	end
end

local function ageText(seconds)
	seconds = math.max(0, math.floor(seconds))
	if seconds < 120 then return seconds .. " s" end
	if seconds < 7200 then return math.floor(seconds / 60) .. " min" end
	if seconds < 172800 then return math.floor(seconds / 3600) .. " h" end
	return math.floor(seconds / 86400) .. " days"
end

function Transfers(arguments)
	local ids = {}
	for id in pairs(transferData.transfers) do table.insert(ids, id) end
	table.sort(ids, function(a, b)
		return (tonumber(a:match("%d+")) or 0) < (tonumber(b:match("%d+")) or 0)
	end)
	print(string.format("[Mileage] Transfers waiting: %d", #ids))
	for _, id in ipairs(ids) do
		local transfer = transferData.transfers[id]
		print(string.format("  %s, %s ago: %s %s", describeTransfer(transfer),
			ageText(os.time() - (transfer.created or os.time())),
			transfer.state == "taking" and "waiting to take from" or "waiting to give to",
			consoleText(waitingOn(transfer))))
	end
	-- Set by the race section: the races still holding stakes.
	if Money.printRaces then Money.printRaces() end
end

Money.SERVER = SERVER_PARTY
Money.transferOwners = transferOwners
Money.startTransfer = startTransfer
Money.playerIdByName = playerIdByName
Money.careerStarted = careerStarted
Money.transfersCareerStarted = transfersCareerStarted
Money.transfersTick = transfersTick
Money.loadTransfers = loadTransfers
Money.ageText = ageText
-- The unfinished transfers by id, as they stand now.
Money.openTransfers = function() return transferData.transfers end
end

--== Payments ================================================================
-- A player pays another from the player list. The server checks the amount, the target
-- and the sender's limits, then pays it as a transfer. A payment the server turns down
-- bounces (rxBounce) or is denied (rxDeny) before any money moves.

do
local startTransfer, playerIdByName = Money.startTransfer, Money.playerIdByName

-- The sender's game shows why a payment did not go: why is "limit" (the default), or
-- "money" when the sender's game refused to take it.
local function bounce(player_id, paymentData, why)
	paymentData.why = why or "limit"
	sendJson("payments", player_id, "rxBounce", paymentData)
end

function payPlayer(player_id, data)
	received("payments")
	local paymentData = decodeTable(data)
	if not paymentData then return end
	paymentData.sender = MP.GetPlayerName(player_id)
	if not Config.server.allowTransactions then
		sendJson("payments", player_id, "rxDeny", paymentData)
		return
	end
	if not isValidPayment(player_id, paymentData)
			or not attemptTransaction(player_id, paymentData.target_player_id, paymentData.money, signalTimer:GetCurrent()) then
		bounce(player_id, paymentData)
		return
	end
	local from, to = paymentData.sender, MP.GetPlayerName(paymentData.target_player_id)
	startTransfer({
		kind = "payment",
		from = from,
		to = to,
		amount = paymentData.money,
		takeLabel = "Paid player: " .. to,
		giveLabel = "Payment from player: " .. from,
	})
end

function Money.transferOwners.payment(transfer, event)
	if event ~= "refused" then return end
	local id = playerIdByName(transfer.from)
	if id then
		bounce(id, {money = transfer.amount, target_player_name = transfer.to}, "money")
	end
end
end

--== Offers ==================================================================
-- Every "accept or decline" between two players is one offer the server holds: a race
-- challenge or a money request. It is shown on the target's game (rxMileageOffer) and
-- closed (rxMileageOfferClosed, to both) on an answer, after OFFER_SECONDS, when either
-- player leaves, or when the owner switches its feature off. A player has at most one
-- open offer to each other player; offers are not kept across a server start.
--
-- offers[id] = {id, kind, from, to (player ids), fromName, toName, amount, finish, start,
-- expires}

do
local startTransfer, careerStarted = Money.startTransfer, Money.careerStarted

local OFFER_SECONDS = 60
local offers = {}
local offerSeq = 0

-- What the client is told when its offer is turned down or closed.
local OFFER_TEXT = {
	accepted = "accepted",
	declined = "declined",
	expired = "No answer came in time.",
	left = "The other player left.",
	racingOff = "Racing is switched off on this server.",
	requestsOff = "Requests are switched off on this server.",
	paymentsOff = "Payments are switched off on this server.",
	self = "You cannot do that with yourself.",
	absent = "That player is not in this session.",
	open = "You already have an offer open with that player.",
	amount = "Enter a whole number of dollars above $0.",
	stake = "Enter a stake of $0 or more, in whole dollars.",
	stakeMax = "That stake is above this server's limit.",
	sendingMax = "That is more than this server lets a player send.",
	finish = "Set a route on the big map first: its end is the finish line.",
	distance = "The finish is closer than this server's shortest race.",
	busy = "One of you is already in a race.",
	limit = "That would pass this server's sending limits; try again later.",
}

-- The server's switches and limits, for the player list to say why an action is off.
local function features()
	return {
		allowTransactions = serverSwitch("allowTransactions"),
		allowRacing = serverSwitch("allowRacing"),
		allowMoneyRequests = serverSwitch("allowMoneyRequests"),
		allowEvents = serverSwitch("allowEvents"),
		raceStakeMax = serverNumber("raceStakeMax", 0, 1000000),
		racePrize = serverNumber("racePrize", 0, 1000000),
		racePrizeCooldownMinutes = serverNumber("racePrizeCooldownMinutes", 0, 1440),
		allowAiRaces = serverSwitch("allowAiRaces"),
		aiRacePrize = serverNumber("aiRacePrize", 0, 1000000),
		aiRacePrizeCooldownMinutes = serverNumber("aiRacePrizeCooldownMinutes", 0, 1440),
		raceMinDistance = serverNumber("raceMinDistance", 0, 20000),
		raceTimeLimitMinutes = serverNumber("raceTimeLimitMinutes", 1, 120),
		sessionSendingMax = tonumber(Config.server.sessionSendingMax) or 0,
	}
end

local function sendFeatures(target)
	sendJson("offers", target, "rxMileageFeatures", features())
end

local function isWhole(n)
	return type(n) == "number" and n == n and n % 1 == 0 and n >= 0 and n < 1e12
end

local function isPoint(p)
	return type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
		and p.x == p.x and p.y == p.y and p.z == p.z
end

local function distance(a, b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

local function closeOffer(offer, why)
	offers[offer.id] = nil
	local message = {id = offer.id, kind = offer.kind, why = why, text = OFFER_TEXT[why] or why,
		from = offer.fromName, to = offer.toName}
	for _, id in ipairs({offer.from, offer.to}) do
		if MP.IsPlayerConnected(id) then sendJson("offers", id, "rxMileageOfferClosed", message) end
	end
end

local function refuseOffer(player_id, offer, why)
	sendJson("offers", player_id, "rxMileageOfferClosed", {kind = type(offer) == "table" and offer.kind or nil,
		why = why, text = OFFER_TEXT[why] or why})
end

-- Money.inRace(name) and Money.startRace(offer) are set by the race section: whether a
-- player is in a race, and how a race starts from an accepted challenge.

-- Why player_id may not make this offer, or nil. exceptId: an open offer not to count,
-- the one being accepted when it is checked again.
local function offerProblem(player_id, offer, exceptId)
	if offer.kind == "race" then
		if not serverSwitch("allowRacing") then return "racingOff" end
	elseif offer.kind == "request" then
		if not serverSwitch("allowTransactions") then return "paymentsOff" end
		if not serverSwitch("allowMoneyRequests") then return "requestsOff" end
	else
		return "unknown"
	end
	local target = offer.to
	if type(target) ~= "number" then return "absent" end
	if target == player_id then return "self" end
	if not MP.IsPlayerConnected(target) or not careerStarted(target) then return "absent" end
	for _, open in pairs(offers) do
		if open.id ~= exceptId and open.from == player_id and open.to == target then return "open" end
	end
	if offer.kind == "request" then
		if not isWhole(offer.amount) or offer.amount <= 0 then return "amount" end
		if offer.amount > (tonumber(Config.server.sessionSendingMax) or 0) then return "sendingMax" end
		return nil
	end
	if not isWhole(offer.amount) then return "stake" end
	if offer.amount > serverNumber("raceStakeMax", 0, 1000000) then return "stakeMax" end
	if not isPoint(offer.finish) or not isPoint(offer.start) then return "finish" end
	if distance(offer.start, offer.finish) < serverNumber("raceMinDistance", 0, 20000) then return "distance" end
	-- Money.busy is set by the race and event sections: in a street race or a running event.
	local busy = Money.busy
	if busy and (busy(MP.GetPlayerName(player_id)) or busy(MP.GetPlayerName(target))) then return "busy" end
	return nil
end

-- A player makes an offer: {kind = "race" | "request", to = playerId, amount, finish,
-- start}. Only the target sees it.
function mileageOffer(player_id, data)
	received("offers")
	local offer = decodeTable(data)
	if not offer then return end
	local why = offerProblem(player_id, offer)
	if why then
		refuseOffer(player_id, offer, why)
		return
	end
	offerSeq = offerSeq + 1
	local open = {
		id = "o" .. offerSeq,
		kind = offer.kind,
		from = player_id,
		to = offer.to,
		fromName = MP.GetPlayerName(player_id),
		toName = MP.GetPlayerName(offer.to),
		amount = offer.amount,
		expires = signalTimer:GetCurrent() + OFFER_SECONDS,
	}
	local shown = {id = open.id, kind = open.kind, from = open.fromName, amount = open.amount, expires = OFFER_SECONDS}
	if offer.kind == "race" then
		open.finish = {x = offer.finish.x, y = offer.finish.y, z = offer.finish.z}
		open.start = {x = offer.start.x, y = offer.start.y, z = offer.start.z}
		shown.distance = math.floor(distance(open.start, open.finish))
		shown.prize = serverNumber("racePrize", 0, 1000000)
	end
	offers[open.id] = open
	sendJson("offers", open.to, "rxMileageOffer", shown)
	sendJson("offers", player_id, "rxMileageOfferSent", {id = open.id, kind = open.kind, to = open.toName,
		amount = open.amount, expires = OFFER_SECONDS})
end

-- The target answers {id, accept}. Money.answerEvent, set by the events section, takes
-- the answers to an event invitation, which carry the event id. A request accepted is paid by the answering player
-- through a transfer, within their sending limits; a challenge accepted starts the race.
function mileageOfferAnswer(player_id, data)
	received("offers")
	local answer = decodeTable(data)
	if not answer or type(answer.id) ~= "string" then return end
	if Money.answerEvent and Money.answerEvent(player_id, answer) then return end
	local offer = offers[answer.id]
	if not offer or offer.to ~= player_id then return end
	if answer.accept ~= true then
		closeOffer(offer, "declined")
		return
	end
	if offer.kind == "request" then
		if not attemptTransaction(player_id, offer.from, offer.amount, signalTimer:GetCurrent()) then
			closeOffer(offer, "limit")
			return
		end
		closeOffer(offer, "accepted")
		startTransfer({
			kind = "payment",
			from = offer.toName,
			to = offer.fromName,
			amount = offer.amount,
			takeLabel = "Paid player: " .. offer.fromName,
			giveLabel = "Payment from player: " .. offer.toName,
		})
		return
	end
	-- Everything is checked again now: either racer may have joined another race or an
	-- event since the challenge was made, and a setting may have changed.
	local why = offerProblem(offer.from, {kind = "race", to = offer.to, amount = offer.amount, finish = offer.finish,
		start = offer.start}, offer.id)
	if why then
		closeOffer(offer, why)
		return
	end
	closeOffer(offer, "accepted")
	if Money.startRace then Money.startRace(offer) end
end

-- Offers past their time, and offers of a feature the owner switched off.
local function offersTick()
	local now = signalTimer:GetCurrent()
	for _, offer in pairs(offers) do
		if now >= offer.expires then
			closeOffer(offer, "expired")
		elseif offer.kind == "race" and not serverSwitch("allowRacing") then
			closeOffer(offer, "racingOff")
		elseif offer.kind == "request" and not serverSwitch("allowMoneyRequests") then
			closeOffer(offer, "requestsOff")
		elseif offer.kind == "request" and not serverSwitch("allowTransactions") then
			closeOffer(offer, "paymentsOff")
		end
	end
end

local function offersPlayerLeft(player_id)
	for _, offer in pairs(offers) do
		if offer.from == player_id or offer.to == player_id then closeOffer(offer, "left") end
	end
end

Money.sendFeatures = sendFeatures
Money.isPoint = isPoint
Money.offersTick = offersTick
Money.offersPlayerLeft = offersPlayerLeft
Money.clearOffers = function() offers = {} end
end

--== Races ===================================================================
-- A street race between two players, from an accepted challenge to its payout.
--
--   staking    both stakes are taken as transfers to the server; STAKE_SECONDS at most
--   pose       the challenger's game reports where its car stands
--   teleport   the challenged game moves its car beside it, frozen, and says it is ready
--   countdown  both games count down COUNTDOWN_SECONDS and release their car on green,
--              each timing itself from its own green
--   racing     each game reports its time once its car reaches the finish; the server
--              waits DECIDE_SECONDS after the first report for a faster one
--
-- data/races.json keeps every race whose stakes are not yet paid out or returned:
-- race = {id, a, b, stake, held = {[name] = amount}, decision, pot, prize, paid = {[role]
-- = true}, created}. decision is "none", "refund" or "winner:<name>" and is written
-- before any payout is made; the payouts (roles "pot", "prize", "refund:<name>") are
-- transfers carrying the race id and role, so a restart makes only the ones still
-- missing. A race undecided at a restart is refunded. A stake taken after the race was
-- called off is refunded too. The record goes once every payout has been given.
--
-- Leaving or giving up before the countdown calls the race off (stakes back); from the
-- countdown on it loses the stake to the other racer, and both leaving returns both.

do
local readData, writeData, startTransfer = Money.readData, Money.writeData, Money.startTransfer
local playerIdByName, ageText, isPoint = Money.playerIdByName, Money.ageText, Money.isPoint
local SERVER_PARTY = Money.SERVER

local RACES_FILE = "races.json"
local STAKE_SECONDS = 15
local START_SECONDS = 15
local COUNTDOWN_SECONDS = 3
local DECIDE_SECONDS = 5
local FINISH_RADIUS = 20

local racesData = {seq = 0, races = {}}
-- The phase and timing of each race under way; not kept across a start.
local liveRaces = {}
-- When each pair of players last earned the server prize, by "a|b" in name order.
local prizeEarnedAt = {}

local function saveRaces()
	return writeData(RACES_FILE, racesData)
end

local function pairKey(a, b)
	if a > b then a, b = b, a end
	return a .. "|" .. b
end

local function otherRacer(race, name)
	if name == race.a then return race.b end
	if name == race.b then return race.a end
	return nil
end

local function sendRace(name, message)
	local id = playerIdByName(name)
	if id then sendJson("races", id, "rxMileageRace", message) end
end

local function sendBothRace(race, message)
	sendRace(race.a, message)
	sendRace(race.b, message)
end

local function heldTotal(race)
	local total = 0
	for _, amount in pairs(race.held) do total = total + amount end
	return total
end

-- {role = {to, amount, label}} for the race's decision.
local function payoutsFor(race)
	local payouts = {}
	if race.decision == "refund" then
		for name, amount in pairs(race.held) do
			payouts["refund:" .. name] = {to = name, amount = amount,
				label = "Race stake back vs " .. (otherRacer(race, name) or "?")}
		end
	else
		local winner = race.decision:match("^winner:(.+)$")
		if winner then
			local loser = otherRacer(race, winner) or "?"
			if (race.pot or 0) > 0 then
				payouts.pot = {to = winner, amount = race.pot, label = "Race win vs " .. loser}
			end
			if (race.prize or 0) > 0 then
				payouts.prize = {to = winner, amount = race.prize, label = "Race prize vs " .. loser}
			end
		end
	end
	return payouts
end

-- Transfers still open for this race, by role (stakes as "stake:<name>"); skip is a
-- transfer being finished right now.
local function openRaceTransfers(race, skip)
	local open = {}
	for id, transfer in pairs(Money.openTransfers()) do
		if transfer.race == race.id and id ~= skip then open[transfer.role or id] = transfer end
	end
	return open
end

-- Makes the payouts of a decided race that are neither given nor under way, and drops
-- the race once everything is paid. skip: a transfer being finished right now.
local function settleRace(race, skip)
	if race.decision == "none" then return end
	-- Nothing is paid for a decision that is not on disk: a restart would not know it and
	-- would return the stakes as well.
	if race.unsaved then
		if not saveRaces() then return end
		race.unsaved = nil
	end
	local open = openRaceTransfers(race, skip)
	local waiting = false
	for role, payout in pairs(payoutsFor(race)) do
		if not race.paid[role] then
			waiting = true
			if not open[role] then
				startTransfer({kind = role == "prize" and "prize" or (role == "pot" and "pot" or "refund"),
					from = SERVER_PARTY, to = payout.to, amount = payout.amount, giveLabel = payout.label,
					race = race.id, role = role})
			end
		end
	end
	for role in pairs(open) do
		if role:sub(1, 6) == "stake:" then waiting = true end
	end
	if not waiting then
		racesData.races[race.id] = nil
		saveRaces()
	end
end

-- Records a decision before anything is paid for it.
local function decide(race, decision)
	if race.decision ~= "none" then return end
	race.decision = decision
	race.pot = heldTotal(race)
	race.unsaved = not saveRaces() or nil
end

local function endLive(race)
	liveRaces[race.id] = nil
end

-- The race ends before its countdown: both stakes go back.
local function callOff(race, why)
	local live = liveRaces[race.id]
	endLive(race)
	decide(race, "refund")
	sendBothRace(race, {race = race.id, phase = "calledOff", why = why, stake = race.stake})
	settleRace(race)
	if live then print("[Mileage] Race " .. race.id .. " between " .. consoleText(race.a) .. " and "
		.. consoleText(race.b) .. " called off: " .. why) end
end

-- The race ends with a result. winner may be nil (both stakes back); finished: the
-- winner reached the finish, which the server prize needs (a win by the other racer
-- leaving still counts on the leaderboard).
local function finishRace(race, winner, why, finished)
	local live = liveRaces[race.id] or {reports = {}}
	endLive(race)
	local prize = 0
	if winner and finished then
		local key = pairKey(race.a, race.b)
		local cooldown = serverNumber("racePrizeCooldownMinutes", 0, 1440) * 60
		local amount = serverNumber("racePrize", 0, 1000000)
		if amount > 0 and (not prizeEarnedAt[key] or os.time() - prizeEarnedAt[key] >= cooldown) then
			prize = amount
			prizeEarnedAt[key] = os.time()
		end
	end
	race.prize = prize
	decide(race, winner and ("winner:" .. winner) or "refund")
	-- Set by the leaderboard section: counts a race win.
	if winner and Money.leaderboardWin then Money.leaderboardWin(winner) end
	for _, name in ipairs({race.a, race.b}) do
		sendRace(name, {race = race.id, phase = "result", winner = winner, why = why, times = live.reports,
			stake = race.stake, pot = race.pot, prize = prize, you = name, other = otherRacer(race, name),
			gaveUp = live.gaveUp})
	end
	settleRace(race)
end

-- Whether name is in a race that has not ended.
Money.inRace = function(name)
	for id, live in pairs(liveRaces) do
		local race = racesData.races[id]
		if race and (race.a == name or race.b == name) then return true end
	end
	return false
end

local function beginStart(race)
	local live = liveRaces[race.id]
	if not live or live.phase ~= "staking" then return end
	if (race.held[race.a] or 0) < race.stake or (race.held[race.b] or 0) < race.stake then return end
	live.phase = "pose"
	live.deadline = signalTimer:GetCurrent() + START_SECONDS
	sendRace(race.a, {race = race.id, phase = "pose", other = race.b})
end

Money.startRace = function(offer)
	racesData.seq = racesData.seq + 1
	local race = {
		id = "r" .. racesData.seq,
		a = offer.fromName,
		b = offer.toName,
		stake = offer.amount,
		held = {},
		decision = "none",
		paid = {},
		created = os.time(),
	}
	racesData.races[race.id] = race
	liveRaces[race.id] = {phase = "staking", finish = offer.finish, reports = {},
		deadline = signalTimer:GetCurrent() + STAKE_SECONDS}
	if not saveRaces() then
		callOff(race, "the server could not keep the race")
		return
	end
	sendBothRace(race, {race = race.id, phase = "staking", stake = race.stake, a = race.a, b = race.b})
	if race.stake > 0 then
		for _, name in ipairs({race.a, race.b}) do
			startTransfer({kind = "stake", from = name, to = SERVER_PARTY, amount = race.stake,
				takeLabel = "Race stake vs " .. otherRacer(race, name), race = race.id, role = "stake:" .. name})
		end
	else
		beginStart(race)
	end
end

-- Stakes and payouts of a race report here, before the transfer itself moves on.
function Money.transferOwners.race(transfer, event)
	local race = racesData.races[transfer.race]
	if not race then return end
	if transfer.kind == "stake" then
		if event == "taken" then
			-- The stake is kept on disk before the transfer ends; if it cannot be, the
			-- transfer stays and the game's answer to the next resend tries again.
			race.held[transfer.from] = race.held[transfer.from] or transfer.amount
			if not saveRaces() then return false end
			if race.decision ~= "none" then
				settleRace(race)
			else
				beginStart(race)
			end
		elseif event == "refused" then
			if race.decision == "none" then
				callOff(race, consoleText(transfer.from) .. " did not have the stake")
			else
				settleRace(race, transfer.id)
			end
		end
	elseif event == "given" and transfer.role then
		race.paid[transfer.role] = true
		if not saveRaces() then
			race.paid[transfer.role] = nil
			return false
		end
		settleRace(race, transfer.id)
	end
end

-- Each game times its own race, so a time is only taken from a game that the server can
-- also see at the finish: the server needs the racer's own car, as BeamMP's position data
-- shows it, within FINISH_CHECK_METRES of the finish (a game that merely reports a time
-- cannot win), and the time must be one that could have been driven: not quicker than the
-- straight line to the finish at MAX_SPEED_MPS, and not longer than the time since green
-- (plus REPORT_SLACK_SECONDS for the delay between the two games' greens). A time before
-- green, or a few hundredths of a second, is ignored.
--
-- A game reports its time at the moment its car arrives, so the time also has to match the
-- server's own clock: it cannot be more than REPORT_SLACK_SECONDS above the time since
-- green, nor more than REPORT_EARLY_SECONDS below it (the delay of the two messages). A
-- game can therefore not claim a quicker time than the server saw pass, and only has the gap
-- between two arrivals to play with.
--
-- When the server cannot read cars' positions at all (BeamMP's MP.GetPlayerVehicles or
-- MP.GetPositionRaw missing, or no car of any player has ever been read in a form
-- understood) the car is not checked and the time stands on the game's word; that is logged
-- once. Once any car has been read, a player whose car cannot be read is refused.
local MAX_SPEED_MPS = 100
local REPORT_SLACK_SECONDS = 3
local REPORT_EARLY_SECONDS = 5
local positionsEverRead = false
-- The game reports within FINISH_RADIUS of the finish; the server's last position of the
-- car can be a moment old, so it is allowed a wider circle.
local FINISH_CHECK_METRES = 150
local positionsUnreadableLogged = false

local function metresBetween(a, b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

local function plausibleTime(seconds, metres, sinceGreen)
	if type(seconds) ~= "number" or seconds ~= seconds or seconds <= 0 then return false end
	if seconds < math.max(0, metres - FINISH_RADIUS) / MAX_SPEED_MPS then return false end
	return seconds <= sinceGreen + REPORT_SLACK_SECONDS and seconds >= sinceGreen - REPORT_EARLY_SECONDS
end

-- A position as {x, y, z} from BeamMP's position data, which may carry it as x, y, z or
-- as a list of three.
local function positionOf(raw)
	local pos = type(raw) == "table" and raw.pos
	if type(pos) ~= "table" then return nil end
	local x, y, z = pos.x or pos[1], pos.y or pos[2], pos.z or pos[3]
	if type(x) == "number" and type(y) == "number" and type(z) == "number" then return {x = x, y = y, z = z} end
	return nil
end

-- true when one of the player's own cars (not traffic) is within metres of point as the
-- server sees it, false when none is, and nil when the server cannot see the player's cars.
local function carNear(player_id, point, metres)
	if type(MP.GetPlayerVehicles) ~= "function" or type(MP.GetPositionRaw) ~= "function" then return nil end
	local ok, vehicles = pcall(MP.GetPlayerVehicles, player_id)
	if not ok then return nil end
	-- BeamMP answers nothing for a player with no car: handled as a car that cannot be read.
	if type(vehicles) ~= "table" then vehicles = {} end
	local seen = false
	for vehicleId in pairs(vehicles) do
		if not isTraffic(tostring(player_id) .. "-" .. tostring(vehicleId)) then
			local readOk, raw = pcall(MP.GetPositionRaw, player_id, vehicleId)
			local at = readOk and positionOf(raw) or nil
			if at then
				seen = true
				positionsEverRead = true
				if metresBetween(at, point) <= metres then return true end
			end
		end
	end
	if seen then return false end
	-- The calls work but this player has no readable car of their own: refused, unless no
	-- car has ever been readable here, which means the format is not understood.
	if positionsEverRead then return false end
	return nil
end

-- Where the server sees the player's own car (not traffic) nearest to point, {x, y, z}, or
-- nil when it cannot read one: where a race against a traffic car starts, and who is near
-- it. A player may own a parked car far away; the one they drive is the one near the race.
local function carPosition(player_id, point)
	if type(MP.GetPlayerVehicles) ~= "function" or type(MP.GetPositionRaw) ~= "function" then return nil end
	local ok, vehicles = pcall(MP.GetPlayerVehicles, player_id)
	if not ok or type(vehicles) ~= "table" then return nil end
	local best, bestMetres = nil, nil
	for vehicleId in pairs(vehicles) do
		if not isTraffic(tostring(player_id) .. "-" .. tostring(vehicleId)) then
			local readOk, raw = pcall(MP.GetPositionRaw, player_id, vehicleId)
			local at = readOk and positionOf(raw) or nil
			if at then
				positionsEverRead = true
				local metres = metresBetween(at, point)
				if not bestMetres or metres < bestMetres then best, bestMetres = at, metres end
			end
		end
	end
	return best
end

-- Whether a finish report from player_id counts: a time that could have been driven, from
-- a game whose car the server sees at the finish.
local function finishCounts(player_id, seconds, start, finish, sinceGreen)
	if not plausibleTime(seconds, metresBetween(start, finish), sinceGreen) then return false end
	local near = carNear(player_id, finish, FINISH_CHECK_METRES)
	if near == nil then
		if not positionsUnreadableLogged then
			positionsUnreadableLogged = true
			print("[Mileage] ---------- Races: the server cannot read cars' positions here, so finish times are taken on the players' games' word")
		end
		return true
	end
	return near
end

-- Reads the cars of the named racers once, when their race or event starts, so the server
-- has found out whether it can read positions before the first finish report arrives.
local function readCars(names, point)
	for _, name in ipairs(names) do
		local id = playerIdByName(name)
		if id then carNear(id, point, math.huge) end
	end
end

Money.finishCounts, Money.metresBetween, Money.readCars = finishCounts, metresBetween, readCars
-- Where the server sees one car by its server vehicle id ("<player_id>-<vehicle_id>"),
-- traffic included, {x, y, z}, or nil when it cannot read it: a race against a traffic car
-- watches that car itself rather than taking the host's game's word for it.
local function vehiclePosition(serverVehicleID)
	if type(MP.GetPositionRaw) ~= "function" or type(serverVehicleID) ~= "string" then return nil end
	local owner, vehicle = serverVehicleID:match("^(%d+)%-(%d+)$")
	if not owner then return nil end
	local ok, raw = pcall(MP.GetPositionRaw, tonumber(owner), tonumber(vehicle))
	return ok and positionOf(raw) or nil
end

Money.carPosition, Money.plausibleTime, Money.vehiclePosition = carPosition, plausibleTime, vehiclePosition

-- A racer's game reports: {race, pose = {pos, dir, up}} (the challenger, for the start),
-- {race, ready = true} (the challenged, beside it), {race, failed = why},
-- {race, finished = seconds} or {race, gaveUp = true}.
function mileageRaceReport(player_id, data)
	received("races")
	local report = decodeTable(data)
	if not report or type(report.race) ~= "string" then return end
	-- Set by the events section: reports about an event's race.
	if Money.eventRaceReport and Money.eventRaceReport(player_id, report) then return end
	-- Set by the AI races section: reports about a race against a traffic car.
	if Money.aiRaceReport and Money.aiRaceReport(player_id, report) then return end
	local race = racesData.races[report.race]
	local live = liveRaces[report.race]
	local name = MP.GetPlayerName(player_id)
	if not race or not live or not otherRacer(race, name) then return end
	local before = live.phase == "staking" or live.phase == "pose" or live.phase == "teleport"
	if report.gaveUp == true or report.failed then
		if before then
			callOff(race, report.failed and consoleText(report.failed) or (consoleText(name) .. " gave up"))
		elseif race.decision == "none" and not live.reports[name] then
			live.gaveUp = name
			-- The other racer has the prize if they really reached the finish.
			finishRace(race, otherRacer(race, name), "gaveUp", live.reports[otherRacer(race, name)] ~= nil)
		end
		return
	end
	if live.phase == "pose" and name == race.a and type(report.pose) == "table" and isPoint(report.pose.pos)
			and isPoint(report.pose.dir) and isPoint(report.pose.up) then
		-- The challenge was checked from where the car stood then; the car may have been
		-- driven to the finish line since.
		live.start = report.pose.pos
		live.metres = metresBetween(report.pose.pos, live.finish)
		if live.metres < serverNumber("raceMinDistance", 0, 20000) then
			callOff(race, "the start was too close to the finish")
			return
		end
		live.phase = "teleport"
		live.deadline = signalTimer:GetCurrent() + START_SECONDS
		sendRace(race.b, {race = race.id, phase = "teleport", pose = report.pose, other = race.a})
	elseif live.phase == "teleport" and name == race.b and report.ready == true then
		live.phase = "countdown"
		readCars({race.a, race.b}, live.finish)
		live.goAt = signalTimer:GetCurrent() + COUNTDOWN_SECONDS
		live.deadline = live.goAt + serverNumber("raceTimeLimitMinutes", 1, 120) * 60
		sendBothRace(race, {race = race.id, phase = "countdown", seconds = COUNTDOWN_SECONDS, finish = live.finish,
			radius = FINISH_RADIUS, stake = race.stake, a = race.a, b = race.b,
			timeLimit = serverNumber("raceTimeLimitMinutes", 1, 120) * 60})
	elseif (live.phase == "countdown" or live.phase == "racing") and not live.reports[name]
			and finishCounts(player_id, report.finished, live.start, live.finish,
				signalTimer:GetCurrent() - live.goAt) then
		live.reports[name] = report.finished
		live.firstReportAt = live.firstReportAt or signalTimer:GetCurrent()
		if live.reports[race.a] and live.reports[race.b] then
			local winner = live.reports[race.a] <= live.reports[race.b] and race.a or race.b
			finishRace(race, winner, "finished", true)
		end
	end
end

local function racesTick()
	local now = signalTimer:GetCurrent()
	for _, race in pairs(racesData.races) do
		if race.unsaved then settleRace(race) end
	end
	for id, live in pairs(liveRaces) do
		local race = racesData.races[id]
		if not race then
			liveRaces[id] = nil
		elseif live.phase == "countdown" and now >= live.goAt then
			live.phase = "racing"
		end
		if race and liveRaces[id] then
			if live.firstReportAt and now - live.firstReportAt >= DECIDE_SECONDS then
				local winner, best = nil, nil
				for name, seconds in pairs(live.reports) do
					if not best or seconds < best then winner, best = name, seconds end
				end
				finishRace(race, winner, "finished", true)
			elseif now >= live.deadline then
				if live.phase == "staking" or live.phase == "pose" or live.phase == "teleport" then
					callOff(race, live.phase == "staking" and "the stakes did not arrive in time"
						or "the racers could not line up in time")
				else
					finishRace(race, nil, "timeout", false)
				end
			end
		end
	end
end

local function racesPlayerLeft(name)
	for id, live in pairs(liveRaces) do
		local race = racesData.races[id]
		local other = race and otherRacer(race, name)
		if other then
			if live.phase == "staking" or live.phase == "pose" or live.phase == "teleport" then
				callOff(race, consoleText(name) .. " left")
			elseif live.reports[name] then
				-- Already at the finish: the race is theirs to win in the wait that is running,
				-- whether or not they are still here; what they are owed waits for them.
			elseif live.reports[other] then
				-- The other racer reached the finish: theirs, here or not.
				live.gaveUp = name
				finishRace(race, other, "left", true)
			elseif playerIdByName(other) then
				live.gaveUp = name
				finishRace(race, other, "left", false)
			else
				finishRace(race, nil, "bothLeft", false)
			end
		end
	end
end

local function loadRaces()
	local stored = readData(RACES_FILE)
	racesData = {seq = 0, races = {}}
	liveRaces = {}
	if stored then
		racesData.seq = tonumber(stored.seq) or 0
		racesData.races = type(stored.races) == "table" and stored.races or {}
	end
	for id, race in pairs(racesData.races) do
		local n = tonumber(tostring(id):match("^r(%d+)$"))
		if n and n > racesData.seq then racesData.seq = n end
		race.held = type(race.held) == "table" and race.held or {}
		race.paid = type(race.paid) == "table" and race.paid or {}
		if race.decision == nil or race.decision == "none" then
			print("[Mileage] ---------- Race " .. id .. " was under way when the server stopped; its stakes go back")
			decide(race, "refund")
		end
	end
	for _, race in pairs(racesData.races) do settleRace(race) end
end

Money.printRaces = function()
	local ids = {}
	for id in pairs(racesData.races) do table.insert(ids, id) end
	table.sort(ids)
	print(string.format("[Mileage] Races holding stakes: %d", #ids))
	for _, id in ipairs(ids) do
		local race = racesData.races[id]
		print(string.format("  %s: %s vs %s, $%d stake, $%d held, %s, %s ago", id, consoleText(race.a),
			consoleText(race.b), race.stake or 0, heldTotal(race), race.decision,
			ageText(os.time() - (race.created or os.time()))))
	end
end

Money.racesTick = racesTick
Money.racesPlayerLeft = racesPlayerLeft
Money.loadRaces = loadRaces
end

--== Leaderboard =============================================================
-- Race wins counted by the server, and each player's best drag run per strip, reported
-- by the racer's own game once the game's drag result is in. Kept in
-- data/leaderboard.json: {wins = {[name] = count}, drag = {[stripId] = {[name] = {et,
-- trap, at}}}}. Any player can ask for the top LEADERBOARD_TOP of each.

do
local readData, writeData = Money.readData, Money.writeData

local LEADERBOARD_FILE = "leaderboard.json"
local LEADERBOARD_TOP = 10
local LEADERBOARD_STRIPS_MAX = 50
local DRAG_ET_MIN, DRAG_ET_MAX = 3, 60
local DRAG_TRAP_MAX = 200

local leaderboard = {wins = {}, drag = {}}

local function saveLeaderboard()
	return writeData(LEADERBOARD_FILE, leaderboard)
end

Money.leaderboardWin = function(name)
	leaderboard.wins[name] = (tonumber(leaderboard.wins[name]) or 0) + 1
	saveLeaderboard()
end

local function validStripId(strip)
	return type(strip) == "string" and #strip >= 1 and #strip <= 64 and strip:match("^[%w_%-%. ]+$") ~= nil
end

-- A racer's game reports its own finished drag run: {strip, et, trap}. Only a faster
-- run than the player's best on that strip is kept.
function mileageDragTime(player_id, data)
	received("leaderboard")
	local run = decodeTable(data)
	if not run or not validStripId(run.strip) then return end
	local et, trap = run.et, run.trap
	if type(et) ~= "number" or et ~= et or et < DRAG_ET_MIN or et > DRAG_ET_MAX then return end
	if type(trap) ~= "number" or trap ~= trap or trap < 0 or trap > DRAG_TRAP_MAX then trap = 0 end
	local name = MP.GetPlayerName(player_id)
	if not name then return end
	local strip = leaderboard.drag[run.strip]
	if not strip then
		local count = 0
		for _ in pairs(leaderboard.drag) do count = count + 1 end
		if count >= LEADERBOARD_STRIPS_MAX then return end
		strip = {}
		leaderboard.drag[run.strip] = strip
	end
	local best = strip[name]
	if best and tonumber(best.et) and best.et <= et then return end
	strip[name] = {et = et, trap = trap, at = os.time()}
	saveLeaderboard()
end

-- {wins = {{name, wins}...}, drag = {[stripId] = {{name, et, trap}...}}}, each sorted and
-- cut to LEADERBOARD_TOP.
local function leaderboardTop()
	local wins = {}
	for name, count in pairs(leaderboard.wins) do table.insert(wins, {name = name, wins = tonumber(count) or 0}) end
	table.sort(wins, function(a, b)
		if a.wins ~= b.wins then return a.wins > b.wins end
		return a.name < b.name
	end)
	for i = #wins, LEADERBOARD_TOP + 1, -1 do wins[i] = nil end
	local drag = {}
	for stripId, runs in pairs(leaderboard.drag) do
		local list = {}
		for name, run in pairs(runs) do
			if tonumber(run.et) then table.insert(list, {name = name, et = run.et, trap = tonumber(run.trap) or 0}) end
		end
		table.sort(list, function(a, b)
			if a.et ~= b.et then return a.et < b.et end
			return a.name < b.name
		end)
		for i = #list, LEADERBOARD_TOP + 1, -1 do list[i] = nil end
		if #list > 0 then drag[stripId] = list end
	end
	return {wins = wins, drag = drag}
end

function mileageLeaderboard(player_id)
	received("leaderboard")
	sendJson("leaderboard", player_id, "rxMileageLeaderboard", leaderboardTop())
end

local function loadLeaderboard()
	local stored = readData(LEADERBOARD_FILE)
	leaderboard = {wins = {}, drag = {}}
	if stored then
		leaderboard.wins = type(stored.wins) == "table" and stored.wins or {}
		leaderboard.drag = type(stored.drag) == "table" and stored.drag or {}
	end
end

function Leaderboard(arguments)
	local argument = arguments and arguments[1]
	if argument == "reset" then
		leaderboard = {wins = {}, drag = {}}
		saveLeaderboard()
		print("[Mileage] Leaderboard reset")
		return
	elseif argument ~= nil then
		print("Usage: Mileage Leaderboard [reset]")
		return
	end
	local top = leaderboardTop()
	print("[Mileage] Leaderboard - race wins")
	for i, entry in ipairs(top.wins) do
		print(string.format("  %2d. %s: %d", i, consoleText(entry.name), entry.wins))
	end
	local strips = {}
	for stripId in pairs(top.drag) do table.insert(strips, stripId) end
	table.sort(strips)
	for _, stripId in ipairs(strips) do
		print("[Mileage] Leaderboard - best drag times at " .. consoleText(stripId))
		for i, entry in ipairs(top.drag[stripId]) do
			print(string.format("  %2d. %s: %.3f s, %.0f km/h", i, consoleText(entry.name), entry.et, entry.trap * 3.6))
		end
	end
end

Money.loadLeaderboard = loadLeaderboard
end

--== Events ==================================================================
-- A race event the owner schedules: `Mileage Event <minutes> <prize> <route|random>`.
-- Every player is told 10, 5 and 1 minutes ahead in chat and in the prompts app
-- (rxMileageEvent "announce") and may join until the start with the same answer as an
-- offer (mileageOfferAnswer carrying the event id). At the start each joined player is
-- moved to a grid behind the start facing the finish; the race then runs as a street race
-- without stakes, timed by each game from its own green, and the fastest finish within
-- DECIDE_SECONDS of the first is paid the prize as a transfer from the server.
--
-- A named route runs between two of the game's West Coast parking spots. `random`
-- starts at a random route's start and asks the first joined player's game for a road
-- point 1.5 to 4 km away from the game's road map; with no answer in PICK_SECONDS it
-- uses the next route's finish. One event at a time; the schedule is kept in
-- data/events.json until it starts.

do
local readData, writeData, startTransfer = Money.readData, Money.writeData, Money.startTransfer
local playerIdByName, isPoint = Money.playerIdByName, Money.isPoint
local SERVER_PARTY = Money.SERVER

local EVENTS_FILE = "events.json"
local ANNOUNCE_MINUTES = {10, 5, 1}
local PICK_SECONDS = 10
local EVENT_COUNTDOWN_SECONDS = 5
local EVENT_DECIDE_SECONDS = 5
local EVENT_FINISH_RADIUS = 20
local GRID_ROW_METRES, GRID_SIDE_METRES = 6, 4
local RANDOM_MIN, RANDOM_MAX = 1500, 4000
local PRIZE_MAX = 1000000

-- Parking spots from BeamNG.drive 0.40.4.0's levels/west_coast_usa/facilities.sites.json
-- (the spot each name gives in parentheses), positions in metres.
local SPOTS = {
	serviceStation = {name = "Service station garage", pos = {x = 904.49, y = -546.27, z = 163.8}}, -- serviceStationParking1
	commercialGarage = {name = "Commercial garage", pos = {x = -284.25, y = -69.43, z = 119.44}}, -- commercialGarageParkingOutside1
	alderDragway = {name = "Alder Dragway", pos = {x = -203.27, y = -203.98, z = 118.82}}, -- alderDragwayGarageParking1
	belascoAuto = {name = "Belasco Auto", pos = {x = -698.6, y = 808.69, z = 74.86}}, -- belascoAuto1
	jerryRigs = {name = "Jerry Rigs", pos = {x = -68.03, y = 2.58, z = 119.83}}, -- jerryRigs1
	dealership = {name = "Garage dealership", pos = {x = 836.36, y = -535.39, z = 165.15}}, -- garageDealership1
	richs = {name = "Rich's parking", pos = {x = -820.68, y = 905.03, z = 74.87}}, -- richsparking1
	jefferson = {name = "Jefferson parking", pos = {x = -393.43, y = 178.1, z = 100.74}}, -- jeffersonparking1
}

local ROUTES = {
	{id = "service-dragway", from = "serviceStation", to = "alderDragway"},
	{id = "service-belasco", from = "serviceStation", to = "belascoAuto"},
	{id = "commercial-belasco", from = "commercialGarage", to = "belascoAuto"},
	{id = "jerryrigs-service", from = "jerryRigs", to = "serviceStation"},
	{id = "jefferson-dealership", from = "jefferson", to = "dealership"},
	{id = "richs-dragway", from = "richs", to = "alderDragway"},
	{id = "belasco-jerryrigs", from = "belascoAuto", to = "jerryRigs"},
	{id = "dealership-commercial", from = "dealership", to = "commercialGarage"},
}

-- The scheduled event, kept in events.json: {id, at (os.time of the start), prize,
-- route (a route id or "random"), announced = {["10"] = true, ...}, joined = {[name] =
-- true}}; nil when none.
local event = nil
-- The event under way, not kept: {id, phase = "picking" | "racing", start, finish,
-- pickDeadline, goAt, deadline, reports, firstReportAt, joined}.
local live = nil
local eventSeq = 0

local function routeName(route)
	return SPOTS[route.from].name .. " to " .. SPOTS[route.to].name
end

-- The route a console argument names: its id, its number in the list, or nil.
local function findRoute(text)
	local n = tonumber(text)
	if n and ROUTES[n] then return ROUTES[n] end
	for _, route in ipairs(ROUTES) do
		if route.id == text then return route end
	end
	return nil
end

local function saveEvent()
	return writeData(EVENTS_FILE, event or {})
end

local function chatAll(text)
	if MP.SendChatMessage then
		MP.SendChatMessage(-1, text)
		count("events", 0, 1, playerCount(), #text * playerCount())
	end
end

local function joinedCount(joined)
	local n = 0
	for _ in pairs(joined or {}) do n = n + 1 end
	return n
end

local function eventRouteText(e)
	if e.route == "random" then return "random finish" end
	local route = findRoute(e.route)
	return route and routeName(route) or tostring(e.route)
end

-- The event as each player's prompts app shows it.
local function announcement(e, phase)
	local secondsLeft = math.max(0, e.at - os.time())
	return {id = e.id, phase = phase, route = eventRouteText(e), random = e.route == "random", prize = e.prize,
		seconds = secondsLeft, joined = joinedCount(e.joined)}
end

local function announce(minutes)
	local text = string.format("Race event in %d minute%s: %s, $%d to the winner. Join from the Mileage prompts.",
		minutes, minutes == 1 and "" or "s", eventRouteText(event), event.prize)
	chatAll(text)
	local message = announcement(event, "announce")
	for id, name in pairs(MP.GetPlayers() or {}) do
		message.youJoined = event.joined[name] == true
		sendJson("events", id, "rxMileageEvent", message)
	end
end

local function sendEvent(name, message)
	local id = playerIdByName(name)
	if id then sendJson("events", id, "rxMileageEvent", message) end
end

-- Grid poses behind start, facing finish: pairs side by side, rows GRID_ROW_METRES apart.
local function gridPoses(start, finish, count)
	local dx, dy = finish.x - start.x, finish.y - start.y
	local length = math.sqrt(dx * dx + dy * dy)
	if length < 1 then dx, dy, length = 0, 1, 1 end
	local fx, fy = dx / length, dy / length
	local rx, ry = fy, -fx
	local poses = {}
	for i = 1, count do
		local row = math.floor((i - 1) / 2)
		local side = ((i - 1) % 2 == 0) and -GRID_SIDE_METRES / 2 or GRID_SIDE_METRES / 2
		poses[i] = {
			pos = {x = start.x - fx * row * GRID_ROW_METRES + rx * side, y = start.y - fy * row * GRID_ROW_METRES + ry * side,
				z = start.z},
			dir = {x = fx, y = fy, z = 0},
			up = {x = 0, y = 0, z = 1},
		}
	end
	return poses
end

local function endEvent(why)
	if live then
		for name in pairs(live.joined) do sendEvent(name, {id = live.id, phase = "over", why = why}) end
	end
	live = nil
end

-- Moves every joined player to the grid and starts the countdown.
local function startEventRace()
	local names = {}
	for name in pairs(live.joined) do
		if not playerIdByName(name) then
			live.joined[name] = nil
		elseif Money.inRace and Money.inRace(name) then
			-- A street race that was already under way goes first; the player is told.
			live.joined[name] = nil
			sendEvent(name, {id = live.id, phase = "over", why = "You were in a race when the event started."})
		else
			table.insert(names, name)
		end
	end
	table.sort(names)
	if #names == 0 then
		endEvent("nobody joined")
		return
	end
	live.racers = #names
	-- The cars are still where the players left them; reading them tells the server whether
	-- it can see cars before any finish arrives.
	Money.readCars(names, live.finish)
	local poses = gridPoses(live.start, live.finish, #names)
	live.phase = "racing"
	live.goAt = signalTimer:GetCurrent() + EVENT_COUNTDOWN_SECONDS
	live.deadline = live.goAt + serverNumber("raceTimeLimitMinutes", 1, 120) * 60
	live.reports = {}
	for i, name in ipairs(names) do
		sendEvent(name, {id = live.id, phase = "start", pose = poses[i], finish = live.finish,
			radius = EVENT_FINISH_RADIUS, seconds = EVENT_COUNTDOWN_SECONDS, route = live.routeText, prize = live.prize,
			racers = #names, timeLimit = serverNumber("raceTimeLimitMinutes", 1, 120) * 60})
	end
end

-- The scheduled time came: the event leaves events.json and starts.
local function beginEvent()
	local e = event
	event = nil
	saveEvent()
	local route = e.route ~= "random" and findRoute(e.route) or ROUTES[math.random(#ROUTES)]
	live = {id = e.id, prize = e.prize, joined = e.joined, start = SPOTS[route.from].pos,
		finish = SPOTS[route.to].pos, routeText = eventRouteText(e), fallback = nil}
	-- The invitation closes for everyone who did not join.
	for id, name in pairs(MP.GetPlayers() or {}) do
		if not e.joined[name] then sendJson("events", id, "rxMileageEvent", {id = e.id, phase = "begun"}) end
	end
	if joinedCount(e.joined) == 0 then
		chatAll("The race event did not start: nobody joined.")
		live = nil
		return
	end
	if e.route ~= "random" then
		startEventRace()
		return
	end
	-- The fallback finish: the next route's.
	local index = 1
	for i, r in ipairs(ROUTES) do if r == route then index = i end end
	live.fallback = SPOTS[ROUTES[index % #ROUTES + 1].to].pos
	local names = {}
	for name in pairs(live.joined) do if playerIdByName(name) then table.insert(names, name) end end
	table.sort(names)
	live.phase = "picking"
	live.pickDeadline = signalTimer:GetCurrent() + PICK_SECONDS
	live.picker = names[1]
	if live.picker then
		sendEvent(live.picker, {id = live.id, phase = "pickFinish", start = live.start, min = RANDOM_MIN,
			max = RANDOM_MAX})
	end
end

local function decideEvent()
	local winner, best = nil, nil
	for name, seconds in pairs(live.reports) do
		if not best or seconds < best then winner, best = name, seconds end
	end
	local places = {}
	for name, seconds in pairs(live.reports) do table.insert(places, {name = name, seconds = seconds}) end
	table.sort(places, function(a, b) return a.seconds < b.seconds end)
	if winner and live.prize > 0 then
		startTransfer({kind = "prize", from = SERVER_PARTY, to = winner, amount = live.prize,
			giveLabel = "Race event prize"})
	end
	if winner and Money.leaderboardWin then Money.leaderboardWin(winner) end
	for name in pairs(live.joined) do
		sendEvent(name, {id = live.id, phase = "result", winner = winner, places = places, prize = live.prize,
			route = live.routeText, racers = live.racers, you = name})
	end
	live = nil
end

-- An answer to the event invitation: {id = the event id, accept}. Returns true when the
-- answer was about the event.
Money.answerEvent = function(player_id, answer)
	if not event or answer.id ~= event.id then
		return live ~= nil and answer.id == live.id
	end
	local name = MP.GetPlayerName(player_id)
	if not name then return true end
	if answer.accept == true and Money.inRace and Money.inRace(name) then
		sendJson("events", player_id, "rxMileageEvent", {id = event.id, phase = "refused",
			why = "Finish your race first, then join."})
		return true
	end
	if answer.accept == true then event.joined[name] = true else event.joined[name] = nil end
	saveEvent()
	local message = announcement(event, answer.accept == true and "joined" or "left")
	message.youJoined = answer.accept == true
	sendJson("events", player_id, "rxMileageEvent", message)
	return true
end

-- Reports from a joined player's game: {race = event id, finish = {x, y, z}} (the random
-- finish), {race, finished = seconds} or {race, gaveUp = true}. Returns true when the
-- report was about the event.
Money.eventRaceReport = function(player_id, report)
	if not live or report.race ~= live.id then return false end
	local name = MP.GetPlayerName(player_id)
	if live.phase == "picking" and name == live.picker and isPoint(report.finish) then
		local dx, dy = report.finish.x - live.start.x, report.finish.y - live.start.y
		local metres = math.sqrt(dx * dx + dy * dy)
		if metres >= RANDOM_MIN and metres <= RANDOM_MAX then
			live.finish = {x = report.finish.x, y = report.finish.y, z = report.finish.z}
			startEventRace()
		end
	elseif live.phase == "racing" and live.joined[name] and report.gaveUp == true and not live.reports[name] then
		-- The racer is out: told so, and no finish of theirs counts.
		live.joined[name] = nil
		sendEvent(name, {id = live.id, phase = "over", why = "You gave up."})
		if next(live.joined) == nil then live = nil end
	elseif live.phase == "racing" and live.joined[name] and not live.reports[name]
			and Money.finishCounts(player_id, report.finished, live.start, live.finish,
				signalTimer:GetCurrent() - live.goAt) then
		live.reports[name] = report.finished
		live.firstReportAt = live.firstReportAt or signalTimer:GetCurrent()
	end
	return true
end

local function eventsTick()
	if event and not serverSwitch("allowEvents") then
		local id = event.id
		event = nil
		saveEvent()
		sendJson("events", -1, "rxMileageEvent", {id = id, phase = "cancelled"})
		chatAll("The race event was cancelled: race events were switched off.")
	end
	if event then
		local minutesLeft = (event.at - os.time()) / 60
		if minutesLeft <= 0 then
			beginEvent()
		else
			for _, minutes in ipairs(ANNOUNCE_MINUTES) do
				local key = tostring(minutes)
				if minutesLeft <= minutes and not event.announced[key] then
					-- Every mark already passed counts as announced, so an event scheduled 3
					-- minutes ahead is announced now and at 1 minute, not again at 5.
					for _, other in ipairs(ANNOUNCE_MINUTES) do
						if other >= minutesLeft then event.announced[tostring(other)] = true end
					end
					saveEvent()
					announce(math.max(1, math.ceil(minutesLeft - 0.001)))
					break
				end
			end
		end
	end
	if not live then return end
	local now = signalTimer:GetCurrent()
	if live.phase == "picking" and now >= live.pickDeadline then
		live.finish = live.fallback
		startEventRace()
	elseif live.phase == "racing" then
		if live.firstReportAt and now - live.firstReportAt >= EVENT_DECIDE_SECONDS then
			decideEvent()
		elseif now >= live.deadline then
			for name in pairs(live.joined) do
				sendEvent(name, {id = live.id, phase = "result", winner = nil, places = {}, prize = live.prize,
					route = live.routeText, why = "timeout", you = name})
			end
			live = nil
		end
	end
end

-- A player whose career just started hears of the event scheduled now.
local function eventsCareerStarted(player_id)
	if not event then return end
	local message = announcement(event, "announce")
	message.youJoined = event.joined[MP.GetPlayerName(player_id)] == true
	sendJson("events", player_id, "rxMileageEvent", message)
end

local function eventsPlayerLeft(name)
	if event and event.joined[name] then
		event.joined[name] = nil
		saveEvent()
	end
	if live then live.joined[name] = nil end
end

local function loadEvent()
	local stored = readData(EVENTS_FILE)
	event, live = nil, nil
	if stored and type(stored.id) == "string" and tonumber(stored.at) then
		event = {id = stored.id, at = tonumber(stored.at), prize = tonumber(stored.prize) or 0,
			route = tostring(stored.route), announced = type(stored.announced) == "table" and stored.announced or {},
			joined = type(stored.joined) == "table" and stored.joined or {}}
		local n = tonumber(stored.id:match("^e(%d+)$"))
		if n and n > eventSeq then eventSeq = n end
	end
end

local function printRoutes()
	print("[Mileage] Race event routes:")
	for i, route in ipairs(ROUTES) do
		print(string.format("  %d. %s: %s", i, route.id, routeName(route)))
	end
	print("  random: from a random route's start to a road point 1.5 to 4 km away")
end

local EVENT_USAGE = "Usage: Mileage Event <minutes 1-120> <prize 0-1000000> <route|random> | cancel | list"

function Event(arguments)
	local first = arguments and arguments[1]
	if first == "list" then
		printRoutes()
		return
	end
	if first == "cancel" then
		if not event and not live then
			print("[Mileage] No race event is scheduled")
			return
		end
		local id = event and event.id or live.id
		if event then
			event = nil
			saveEvent()
		end
		endEvent("cancelled")
		sendJson("events", -1, "rxMileageEvent", {id = id, phase = "cancelled"})
		chatAll("The race event was cancelled.")
		print("[Mileage] Race event " .. id .. " cancelled")
		return
	end
	if not first or #arguments < 3 then
		print(EVENT_USAGE)
		return
	end
	if not serverSwitch("allowEvents") then
		print("[Mileage] Race events are switched off on this server (server allowEvents)")
		return
	end
	if event or live then
		print("[Mileage] A race event is already scheduled; Mileage Event cancel first")
		return
	end
	local minutes, prize = tonumber(arguments[1]), tonumber(arguments[2])
	if not minutes or minutes % 1 ~= 0 or minutes < 1 or minutes > 120 then
		print("[Mileage] Minutes must be a whole number from 1 to 120")
		return
	end
	if not prize or prize % 1 ~= 0 or prize < 0 or prize > PRIZE_MAX then
		print("[Mileage] The prize must be a whole number of dollars from 0 to " .. PRIZE_MAX)
		return
	end
	local routeArg = arguments[3]
	local route = routeArg ~= "random" and findRoute(routeArg) or nil
	if routeArg ~= "random" and not route then
		print("[Mileage] Unknown route " .. consoleText(routeArg) .. "; Mileage Event list shows them")
		return
	end
	eventSeq = eventSeq + 1
	event = {id = "e" .. eventSeq .. "-" .. os.time(), at = os.time() + minutes * 60, prize = prize,
		route = route and route.id or "random", announced = {}, joined = {}}
	if not saveEvent() then
		event = nil
		print("[Mileage] The event could not be kept in " .. EVENTS_FILE .. "; nothing was scheduled")
		return
	end
	print(string.format("[Mileage] Race event %s in %d min: %s, $%d prize", event.id, minutes, eventRouteText(event),
		prize))
	eventsTick()
end

Money.eventsCareerStarted = eventsCareerStarted
-- In a running event race, and so not free for a street race.
Money.inEvent = function(name) return live ~= nil and live.joined[name] == true end
-- In a street race or a running event race.
Money.busy = function(name)
	return (Money.inRace ~= nil and Money.inRace(name)) or Money.inEvent(name)
end
Money.eventsTick = eventsTick
Money.eventsPlayerLeft = eventsPlayerLeft
Money.loadEvent = loadEvent
end

--== AI races ================================================================
-- A player races one of their own traffic cars on the road ("Race this car" in the
-- Mileage prompts app). Only the game that spawned a traffic car can drive it, so the
-- host's game picks a random road finish 1.5 to 4 km away that the car can reach and asks
-- for the race (mileageAiRace {request}). The server checks it and starts a ROLL_SECONDS
-- rolling countdown in which nobody stops; the host's game takes the car off traffic duty,
-- sends it a race route at zero and reports its time (mileageRaceReport {race, aiFinished}
-- or {race, aiOut}). Players whose car the server sees within INVITE_METRES of the host
-- are invited for the same countdown ({join = id}) and race from where they are, timed from
-- the same zero. The fastest counted time AI_DECIDE_SECONDS after the first wins: a player
-- who beats the traffic car gets a leaderboard win and, when the owner set
-- server.aiRacePrize and that player's own cooldown has passed, the race reward from the
-- server, plus half of it for each player who joined. The race belongs to its host: their
-- Give up or leaving, or the traffic car dropping out, ends it for everyone with no winner.
-- Nothing is kept across a server start. The games' window never calls this AI; only the
-- owner's settings and this console do.
--
-- aiRaces[id] = {id, host, car, model, start, finish, phase = "countdown" | "racing",
-- goAt, deadline, racers = {[name] = {start}}, invited = {[name] = true}, reward,
-- reports = {[name] = seconds}, aiSeconds, firstReportAt}

do
local startTransfer, careerStarted, playerIdByName, isPoint = Money.startTransfer, Money.careerStarted,
	Money.playerIdByName, Money.isPoint
local SERVER_PARTY = Money.SERVER

local ROLL_SECONDS = 5
local AI_DECIDE_SECONDS = 5
local AI_FINISH_RADIUS = 20
local INVITE_METRES = 300
-- The game picks a finish 1.5 to 4 km from its car; the car has moved a little by the time
-- the server reads it.
local FINISH_MIN, FINISH_MAX, FINISH_SLACK = 1500, 4000, 150
local MODEL_MAX_LENGTH = 40
local PRIZE_HIGH = 1000000
-- The server reads the traffic car itself wherever BeamMP lets it: the car's time is when
-- the server sees it within AI_SEEN_METRES of the finish, a time the host's game reports
-- counts only with the car within AI_CHECK_METRES of it, and a car that moves less than
-- AI_STILL_METRES in AI_STILL_SECONDS of racing is out. A modified host game can then not
-- hide the car's time, nor stop it, to collect the reward.
local AI_SEEN_METRES, AI_CHECK_METRES = 40, 150
local AI_STILL_METRES, AI_STILL_SECONDS = 15, 20

local aiRaces = {}
local aiSeq = 0
-- When each player last earned the race reward (os.time); not kept across starts, as the
-- player race prize's cooldown is not.
local aiPrizeEarnedAt = {}

local REFUSED = {
	off = "Racing traffic is off on this server.",
	career = "Your career has not started on this server yet.",
	busy = "You are already in a race.",
	car = "Only your own traffic can race you.",
	traffic = "That car is not traffic.",
	carBusy = "That car is already racing.",
	finish = "No finish was set for the race.",
	distance = "The finish must be 1.5 to 4 km away. Try again.",
}

local function rewardFor(joined)
	return math.floor(serverNumber("aiRacePrize", 0, PRIZE_HIGH) * (1 + 0.5 * joined))
end

-- Seconds until name may earn the race reward again; 0 when they may now.
local function prizeAgainIn(name)
	local earned = aiPrizeEarnedAt[name]
	if not earned then return 0 end
	return math.max(0, serverNumber("aiRacePrizeCooldownMinutes", 0, 1440) * 60 - (os.time() - earned))
end

local function sendStatus(player_id)
	local name = MP.GetPlayerName(player_id)
	sendJson("aiRaces", player_id, "rxMileageAiRace", {phase = "status", allowed = serverSwitch("allowAiRaces"),
		prize = serverNumber("aiRacePrize", 0, PRIZE_HIGH), prizeAgainIn = name and prizeAgainIn(name) or 0})
end

local function sendTo(name, message)
	local id = playerIdByName(name)
	if id then sendJson("aiRaces", id, "rxMileageAiRace", message) end
end

local function racerNames(race)
	local names = {}
	for name in pairs(race.racers) do table.insert(names, name) end
	table.sort(names)
	return names
end

-- Players who joined the host's race.
local function joinedCount(race)
	return #racerNames(race) - (race.racers[race.host] and 1 or 0)
end

local function raceOf(name)
	for _, race in pairs(aiRaces) do
		if race.racers[name] then return race end
	end
	return nil
end

-- A player in a race against a traffic car is racing for street race challenges and event
-- joins and starts too (Money.busy reads this).
local streetInRace = Money.inRace
Money.inRace = function(name)
	return raceOf(name) ~= nil or (streetInRace ~= nil and streetInRace(name))
end

local function modelText(model)
	local text = type(model) == "string" and model:gsub("%c", " "):match("^%s*(.-)%s*$"):sub(1, MODEL_MAX_LENGTH) or ""
	if text == "" then return "traffic car" end
	return text
end

local function flatMetres(a, b)
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx * dx + dy * dy)
end

-- Invited players who did not join hear that the invitation is over.
local function closeInvites(race)
	for name in pairs(race.invited) do
		if not race.racers[name] then sendTo(name, {phase = "inviteClosed", race = race.id}) end
	end
	race.invited = {}
end

-- Zero: the reward counts the players in the race now, and the invitation closes.
local function goIfDue(race, now)
	if race.phase ~= "countdown" or now < race.goAt then return end
	race.phase = "racing"
	race.reward = rewardFor(joinedCount(race))
	closeInvites(race)
end

local function placesText(places)
	local parts = {}
	for i, place in ipairs(places) do
		table.insert(parts, string.format("%d. %s %.1f s", i, consoleText(place.name), place.seconds))
	end
	return #parts > 0 and table.concat(parts, ", ") or "no times"
end

-- Ends the race: the winner's win and reward, then every racer hears the result and their
-- new status.
local function endAiRace(race, winner, aiWon, why, places)
	aiRaces[race.id] = nil
	closeInvites(race)
	places = places or {}
	local paid = 0
	if winner then
		if Money.leaderboardWin then Money.leaderboardWin(winner) end
		if (race.reward or 0) > 0 and prizeAgainIn(winner) == 0 then
			paid = race.reward
			aiPrizeEarnedAt[winner] = os.time()
			startTransfer({kind = "prize", from = SERVER_PARTY, to = winner, amount = paid, giveLabel = "Race reward"})
		end
	end
	for _, name in ipairs(racerNames(race)) do
		local id = playerIdByName(name)
		if id then
			sendJson("aiRaces", id, "rxMileageAiRace", {phase = "result", race = race.id, host = race.host,
				car = race.model, winner = winner, aiWon = aiWon == true, places = places, prize = paid,
				reward = race.reward or 0, prizeAgainIn = prizeAgainIn(name), why = why, you = name})
			sendStatus(id)
		end
	end
	local outcome
	if winner then
		outcome = consoleText(winner) .. " wins" .. (paid > 0 and string.format(", $%d race reward", paid) or ", no reward")
	elseif aiWon then
		outcome = "the traffic car wins, no reward"
	else
		outcome = "no winner (" .. why .. ")"
	end
	print(string.format("[Mileage] AI race %s (%s's %s): %s; %s", race.id, consoleText(race.host),
		consoleText(race.model), placesText(places), outcome))
end

-- The fastest time wins; a player's time equal to the traffic car's does not beat it.
local function decideAiRace(race, why)
	local places = {}
	for name, seconds in pairs(race.reports) do table.insert(places, {name = name, seconds = seconds}) end
	if race.aiSeconds then table.insert(places, {name = race.model, seconds = race.aiSeconds, car = true}) end
	table.sort(places, function(a, b)
		if a.seconds ~= b.seconds then return a.seconds < b.seconds end
		if (a.car == true) ~= (b.car == true) then return a.car == true end
		return a.name < b.name
	end)
	local first = places[1]
	local aiWon = first ~= nil and first.car == true
	endAiRace(race, (first and not aiWon) and first.name or nil, aiWon, why or "finished", places)
end

-- Every racer and the traffic car have a time.
local function allIn(race)
	if not race.aiSeconds then return false end
	for name in pairs(race.racers) do
		if not race.reports[name] then return false end
	end
	return true
end

local function refuse(player_id, why)
	sendJson("aiRaces", player_id, "rxMileageAiRace", {phase = "refused", why = REFUSED[why] or why})
end

local function requestProblem(player_id, name, request)
	if not serverSwitch("allowAiRaces") then return "off" end
	if not careerStarted(player_id) then return "career" end
	if Money.busy and Money.busy(name) then return "busy" end
	if not Money.ownsVehicle or not Money.ownsVehicle(player_id, request.car) then return "car" end
	if not isTraffic(request.car) then return "traffic" end
	for _, race in pairs(aiRaces) do
		if race.car == request.car then return "carBusy" end
	end
	if not isPoint(request.start) or not isPoint(request.finish) then return "finish" end
	return nil
end

local function invite(race)
	for id, name in pairs(MP.GetPlayers() or {}) do
		if name ~= race.host and MP.IsPlayerConnected(id) and careerStarted(id)
				and not (Money.busy and Money.busy(name)) then
			local at = Money.carPosition(id, race.start)
			if at and Money.metresBetween(at, race.start) <= INVITE_METRES then
				race.invited[name] = true
				sendJson("aiRaces", id, "rxMileageAiRace", {phase = "invite", race = race.id, host = race.host,
					car = race.model, finish = race.finish, seconds = ROLL_SECONDS, prize = rewardFor(joinedCount(race) + 1),
					distance = math.floor(flatMetres(at, race.finish))})
			end
		end
	end
end

local function startAiRace(player_id, name, request)
	-- Where the server sees the host's car, when it can: of the host's own cars, the one
	-- nearest where their game says it is.
	local start = Money.carPosition(player_id, request.start)
		or {x = request.start.x, y = request.start.y, z = request.start.z}
	local metres = flatMetres(start, request.finish)
	if metres < FINISH_MIN - FINISH_SLACK or metres > FINISH_MAX + FINISH_SLACK then
		refuse(player_id, "distance")
		return
	end
	aiSeq = aiSeq + 1
	local now = signalTimer:GetCurrent()
	local race = {id = "ai" .. aiSeq .. "-" .. os.time(), host = name, car = request.car, model = modelText(request.model),
		start = start, finish = {x = request.finish.x, y = request.finish.y, z = request.finish.z}, phase = "countdown",
		goAt = now + ROLL_SECONDS, racers = {[name] = {start = start}}, invited = {}, reports = {}}
	race.deadline = race.goAt + serverNumber("raceTimeLimitMinutes", 1, 120) * 60
	race.reward = rewardFor(0)
	aiRaces[race.id] = race
	sendJson("aiRaces", player_id, "rxMileageAiRace", {phase = "countdown", race = race.id, host = name, car = race.model,
		finish = race.finish, radius = AI_FINISH_RADIUS, seconds = ROLL_SECONDS, prize = race.reward, racers = {name}})
	invite(race)
	local invited = 0
	for _ in pairs(race.invited) do invited = invited + 1 end
	print(string.format("[Mileage] AI race %s: %s races their %s to a finish %d m away, %d invited", race.id,
		consoleText(name), consoleText(race.model), math.floor(metres), invited))
end

local function joinAiRace(player_id, name, id)
	local race = aiRaces[id]
	local now = signalTimer:GetCurrent()
	if race then goIfDue(race, now) end
	if not race or race.phase ~= "countdown" or not race.invited[name] or race.racers[name]
			or not careerStarted(player_id) or (Money.busy and Money.busy(name)) then
		sendJson("aiRaces", player_id, "rxMileageAiRace", {phase = "inviteClosed", race = id})
		return
	end
	race.racers[name] = {start = Money.carPosition(player_id, race.start)}
	local reward = rewardFor(joinedCount(race))
	local racers = racerNames(race)
	sendJson("aiRaces", player_id, "rxMileageAiRace", {phase = "countdown", race = race.id, host = race.host,
		car = race.model, finish = race.finish, radius = AI_FINISH_RADIUS, seconds = race.goAt - now, prize = reward,
		racers = racers})
	for _, racer in ipairs(racers) do
		sendTo(racer, {phase = "joined", race = race.id, racers = racers, prize = reward})
	end
end

-- A player's game asks for a race, {request = {car = "<player_id>-<vehicle_id>", start,
-- finish, model}}, or joins one it was invited to, {join = race id}.
function mileageAiRace(player_id, data)
	received("aiRaces")
	local message = decodeTable(data)
	local name = MP.GetPlayerName(player_id)
	if not message or not name then return end
	if type(message.join) == "string" then
		joinAiRace(player_id, name, message.join)
		return
	end
	if type(message.request) ~= "table" then return end
	local why = requestProblem(player_id, name, message.request)
	if why then
		refuse(player_id, why)
		return
	end
	startAiRace(player_id, name, message.request)
end

-- Reports about a race against a traffic car, from mileageRaceReport: a racer's
-- {race, finished = seconds} or {race, gaveUp = true}, and from the host alone
-- {race, aiFinished = seconds}, {race, aiOut = why} or {race, failed = why}. Returns true
-- when the report was about such a race, ended or not.
Money.aiRaceReport = function(player_id, report)
	local race = aiRaces[report.race]
	if not race then return report.race:match("^ai%d") ~= nil end
	local name = MP.GetPlayerName(player_id)
	if not name or not race.racers[name] then return true end
	local now = signalTimer:GetCurrent()
	goIfDue(race, now)
	local isHost = name == race.host
	if report.gaveUp == true or report.failed ~= nil then
		if isHost then
			endAiRace(race, nil, false, report.failed ~= nil and "failed" or "hostGaveUp")
		elseif not race.reports[name] then
			-- An invited racer drops out; the others race on.
			race.racers[name] = nil
			sendTo(name, {phase = "result", race = race.id, host = race.host, car = race.model, out = true,
				why = "gaveUp", places = {}, prize = 0, reward = race.reward or 0, you = name})
			if allIn(race) then decideAiRace(race) end
		end
		return true
	end
	if isHost and report.aiOut ~= nil then
		if not race.aiSeconds then endAiRace(race, nil, false, "aiOut") end
		return true
	end
	if race.phase ~= "racing" then return true end
	local sinceGo = now - race.goAt
	if isHost and report.aiFinished ~= nil then
		local seen = Money.vehiclePosition(race.car)
		if not race.aiSeconds
				and (not seen or Money.metresBetween(seen, race.finish) <= AI_CHECK_METRES)
				and Money.plausibleTime(report.aiFinished, Money.metresBetween(race.start, race.finish), sinceGo) then
			race.aiSeconds = report.aiFinished
			race.firstReportAt = race.firstReportAt or now
		end
	elseif report.finished ~= nil and not race.reports[name]
			and Money.finishCounts(player_id, report.finished, race.racers[name].start or race.start, race.finish,
				sinceGo) then
		race.reports[name] = report.finished
		race.firstReportAt = race.firstReportAt or now
	end
	if allIn(race) then decideAiRace(race) end
	return true
end

-- The server's own reading of the racing traffic car: its time at the finish, or out when
-- it stands still. Returns true when that ended the race.
local function watchTrafficCar(race, now)
	if race.phase ~= "racing" or race.aiSeconds then return false end
	local at = Money.vehiclePosition(race.car)
	if not at then return false end
	if Money.metresBetween(at, race.finish) <= AI_SEEN_METRES then
		race.aiSeconds = now - race.goAt
		race.firstReportAt = race.firstReportAt or now
		return false
	end
	if not race.stillAt or Money.metresBetween(at, race.stillAt) >= AI_STILL_METRES then
		race.stillAt, race.stillSince = at, now
	elseif now - race.stillSince >= AI_STILL_SECONDS then
		endAiRace(race, nil, false, "aiOut")
		return true
	end
	return false
end

local function aiRacesTick()
	local now = signalTimer:GetCurrent()
	for _, race in pairs(aiRaces) do
		goIfDue(race, now)
		if watchTrafficCar(race, now) then
			-- Ended: the traffic car stopped.
		elseif race.firstReportAt and now - race.firstReportAt >= AI_DECIDE_SECONDS then
			decideAiRace(race)
		elseif race.phase == "racing" and now >= race.deadline then
			if race.firstReportAt then decideAiRace(race, "timeout") else endAiRace(race, nil, false, "timeout") end
		end
	end
end

-- The host leaving ends their race; another racer who leaves before finishing drops out,
-- and one who already finished keeps their time.
local function aiRacesPlayerLeft(name)
	for _, race in pairs(aiRaces) do
		race.invited[name] = nil
		if race.host == name then
			endAiRace(race, nil, false, "hostLeft")
		elseif race.racers[name] and not race.reports[name] then
			race.racers[name] = nil
			if allIn(race) then decideAiRace(race) end
		end
	end
end

Money.aiRacesCareerStarted = sendStatus
-- Every player whose career runs hears the owner's settings again.
Money.sendAiRaceStatus = function()
	for id in pairs(MP.GetPlayers() or {}) do
		if careerStarted(id) then sendStatus(id) end
	end
end
Money.aiRacesTick = aiRacesTick
Money.aiRacesPlayerLeft = aiRacesPlayerLeft
end

-- Loads what the money, racing, leaderboard and event sections keep between starts.
Money.start = function()
	Money.loadTransfers()
	Money.clearOffers()
	Money.loadRaces()
	Money.loadLeaderboard()
	Money.loadEvent()
end

--== Drag racing relay =======================================================
-- BeamNG 0.39 ships a complete multiplayer drag protocol (16 message types, see
-- gameplay/drag/mpDragHandlers.lua) but no transport. This carries it.
--
-- The server deliberately does not understand any of it: every message is an opaque
-- envelope { msg, to, data } that gets routed and forwarded. That keeps the protocol
-- entirely client-side, so a BeamNG update that changes it needs no server change.
--
-- Routing targets:
--   "all"   every player except the sender
--   "host"  the player holding the strip the message concerns
--   {ids}   a specific set of player ids (bridge.sendToClientIds)

-- Drag authority, elected per strip rather than per session.
--
-- Election lives here rather than on the clients: working out who arrived first needs
-- everyone's presence, which only a neutral party has, and the server is what notices
-- disconnects. Doing it client-side would mean every client agreeing independently, and
-- re-agreeing whenever anyone joins or leaves.
--
-- The first design made one player -- lowest connected id -- authoritative for all drag
-- racing. That is wrong in a way that stops racing outright: the authority decides when
-- everyone is staged by reading its OWN local drag state, so a player who is off doing
-- deliveries has no drag data and the countdown never fires for anybody.
--
-- The authority must therefore be someone standing at the strip. It is elected here
-- rather than by the clients because working out who arrived first needs everyone's
-- presence, which only a neutral party has, and because the server notices disconnects.
--
-- dragPresence[stripId][playerId] = arrival sequence number
local dragPresence = {}
local dragAuthority = {}
local dragArrivalSeq = 0

local function electAuthority(stripId)
	local best, bestSeq = nil, nil
	for playerId, seq in pairs(dragPresence[stripId] or {}) do
		if MP.IsPlayerConnected(playerId) and (bestSeq == nil or seq < bestSeq) then
			best, bestSeq = playerId, seq
		end
	end
	return best
end

local function updateAuthority(stripId)
	local elected = electAuthority(stripId)
	if elected ~= dragAuthority[stripId] then
		dragAuthority[stripId] = elected
		if elected then
			print("[Mileage] ---------- Drag authority for '" .. stripId .. "' is player " .. tostring(elected))
		else
			print("[Mileage] ---------- Drag strip '" .. stripId .. "' is empty")
		end
		sendJson("drag", -1, "rxDragAuthority", { stripId = stripId, playerId = elected })
	end
end

local function noteArrival(playerId, stripId)
	if not stripId then return end
	dragPresence[stripId] = dragPresence[stripId] or {}
	if not dragPresence[stripId][playerId] then
		dragArrivalSeq = dragArrivalSeq + 1
		dragPresence[stripId][playerId] = dragArrivalSeq
		updateAuthority(stripId)
	end
end

local function noteDeparture(playerId, stripId)
	if stripId then
		if dragPresence[stripId] then
			dragPresence[stripId][playerId] = nil
			updateAuthority(stripId)
		end
		return
	end
	-- No strip given: the player is gone entirely, so drop them everywhere.
	for id, players in pairs(dragPresence) do
		if players[playerId] then
			players[playerId] = nil
			updateAuthority(id)
		end
	end
end

--- Called when a player leaves the server.
function releaseDragPresence(player_id)
	noteDeparture(player_id, nil)
end

--- Which player should a "to host" message go to?
---
--- Most messages name their strip. Finish times do not: phaseHandlers.lua:875 sends
--- dragRaceFinishTime with nothing but a raceId, and that is the one message that must
--- not be misrouted, because the authority attributes the win from it.
---
--- Race ids are built as "<stripId>-<number>" by the lobby, so the strip is recoverable
--- from the id itself. Matching the longest one guards against a strip whose id is a
--- prefix of another's.
---
--- When the message itself names neither, the sender's own strip decides: Mileage clients
--- put it on the envelope (envelopeStripId) of every message for a leader. It is only
--- ever used to look up a strip that already has a leader.
local function resolveAuthorityFor(d, envelopeStripId)
	if type(d) == "table" then
		local named = d.stripId or d.lobbyId
		if named and dragAuthority[named] then return dragAuthority[named] end

		local raceId = d.raceId
		if type(raceId) == "string" then
			local best
			for stripId, holder in pairs(dragAuthority) do
				if holder and raceId:sub(1, #stripId + 1) == stripId .. "-" then
					if not best or #stripId > #best then best = stripId end
				end
			end
			if best then return dragAuthority[best] end
		end
	end

	if type(envelopeStripId) == "string" and dragAuthority[envelopeStripId] then
		return dragAuthority[envelopeStripId]
	end
	if type(d) ~= "table" then return nil end

	-- Nothing matched. If exactly one strip is in play the answer is unambiguous anyway;
	-- with several, guessing would hand a finish time to the wrong race, so send nothing.
	local only, count = nil, 0
	for _, holder in pairs(dragAuthority) do
		if holder then only, count = holder, count + 1 end
	end
	if count == 1 then return only end
	return nil
end

-- A leader message that reaches nobody is logged, by name and sender, at most once per
-- 10 s for each pair, so a client sending one every frame cannot flood the console. The
-- name comes from the client, so it is cut short and kept to one line.
-- One top-level name: the main chunk is close to Lua's limit of 200 locals.
local logUnsentDrag
do
	local LOG_SECONDS = 10
	local KEYS_MAX = 256
	local loggedAt, keys = {}, 0

	function logUnsentDrag(msgName, player_id)
		local name = tostring(msgName):gsub("%c", "?"):sub(1, 64)
		local key = name .. "|" .. tostring(player_id)
		local now = signalTimer:GetCurrent()
		local last = loggedAt[key]
		if last and now - last < LOG_SECONDS then return end
		if not last then
			if keys >= KEYS_MAX then loggedAt, keys = {}, 0 end
			keys = keys + 1
		end
		loggedAt[key] = now
		print(string.format("[Mileage] drag: no strip leader for %s from %s; not sent", name, tostring(player_id)))
	end
end

--- A client asking who holds a strip (on join, or after reconnecting).
function dragAuthorityRequest(player_id, data)
	received("drag")
	local req = Util.JsonDecode(data)
	local stripId = req and req.stripId
	if stripId then
		sendJson("drag", player_id, "rxDragAuthority",
			{ stripId = stripId, playerId = dragAuthority[stripId] })
		return
	end
	for id, holder in pairs(dragAuthority) do
		sendJson("drag", player_id, "rxDragAuthority", { stripId = id, playerId = holder })
	end
end

function dragMP(player_id, data)
	received("drag")
	local envelope = Util.JsonDecode(data)
	if not envelope or not envelope.msg then return end

	-- Stamp the sender server-side; a client must not be able to claim to be someone
	-- else, since finish times are attributed by sender id.
	envelope.from = player_id

	local to = envelope.to
	local payload = Util.JsonEncode(envelope)

	-- Our own lobby messages carry strip presence; the server reads those (and only
	-- those) so it can elect the per-strip authority. BeamNG's protocol stays opaque.
	local d = envelope.data
	if envelope.msg == "mileageDragJoin" and d then
		noteArrival(player_id, d.stripId)
	elseif envelope.msg == "mileageDragLeave" and d then
		noteDeparture(player_id, d.stripId)
	end

	if to == "host" then
		-- To whoever holds the strip this message concerns.
		local target = resolveAuthorityFor(d, envelope.stripId)
		if target and MP.IsPlayerConnected(target) then
			send("drag", target, "rxDragMP", payload)
		elseif envelope.msg ~= "mileageDragJoin" and envelope.msg ~= "mileageDragLeave" then
			-- The presence messages have done their work above; anything else is lost.
			logUnsentDrag(envelope.msg, player_id)
		end
		return
	end

	if type(to) == "table" then
		for _, id in pairs(to) do
			local pid = tonumber(id)
			if pid and pid ~= player_id and MP.IsPlayerConnected(pid) then
				send("drag", pid, "rxDragMP", payload)
			end
		end
		return
	end

	-- default: everyone but the sender
	for id in pairs(MP.GetPlayers()) do
		if id ~= player_id then
			send("drag", id, "rxDragMP", payload)
		end
	end
end

function speedTrap(player_id, data)
	received("notifications")
	local speedTrapData = Util.JsonDecode(data)
	local triggerName = speedTrapData.triggerName
	local triggerNumber = tonumber(string.match(triggerName, "%d+"))
	local triggerPlace = trapNames[triggerNumber] or "Unknown"
	local player_name = MP.GetPlayerName(player_id)
	notify("notifications", -1, "Speed Violation by " .. player_name .. "!", "survellianceCamera", "survellianceCamera")
	notify("notifications", -1, "Speed: " .. string.format( "%.1f", speedTrapData.playerSpeed * 2.23694 ) .. " in " .. string.format( "%.0f", speedTrapData.speedLimit * 2.23694 ) .. " MPH Zone", "powerGauge05", "powerGauge05")
	notify("notifications", -1, "Location: " .. triggerPlace, "location1", "location1")
	notify("notifications", -1, "Vehicle: " .. speedTrapData.vehicleModel, "car", "car")
	notify("notifications", -1, "Plate: " .. speedTrapData.licensePlate, "code", "code")
end

function redLight(player_id, data)
	received("notifications")
	local redLightData = Util.JsonDecode(data)
	local triggerName = redLightData.triggerName
	local triggerNumber = tonumber(string.match(triggerName, "%d+"))
	local triggerPlace = trapNames[triggerNumber] or "Unknown"
	local player_name = MP.GetPlayerName(player_id)
	notify("notifications", -1, "Failure to stop at Red Light by " .. player_name .. "!", "trafficLight", "trafficLight")
	notify("notifications", -1, "Speed: " .. string.format( "%.1f", redLightData.playerSpeed * 2.23694 ) .. " MPH", "powerGauge05", "powerGauge05")
	notify("notifications", -1, "Location: " .. triggerPlace, "location1", "location1")
	notify("notifications", -1, "Vehicle: " .. redLightData.vehicleModel, "car", "car")
	notify("notifications", -1, "Plate: " .. redLightData.licensePlate, "code", "code")
end

function trafficLightTimer()
	for id in pairs(MP.GetPlayers()) do
		if MP.IsPlayerConnected(id) then
			send("trafficLights", id, "rxTrafficSignalTimer", tostring(signalTimer:GetCurrent()))
		end
	end
end

-- The whole car-state list goes to a player at most once every LIST_EVERY_SECONDS; a
-- request inside that time is answered once, from the first tick after it.
local LIST_EVERY_SECONDS = 1
local listAnsweredAt = {}
local listWanted = {}

local function sendVehicleList(player_id)
	listAnsweredAt[player_id] = signalTimer:GetCurrent()
	listWanted[player_id] = nil
	sendJson("carStates", player_id, "rxCareerVehSync", vehicleStates)
end

local function sendWantedVehicleLists()
	local now = signalTimer:GetCurrent()
	for player_id in pairs(listWanted) do
		if not MP.IsPlayerConnected(player_id) then
			listWanted[player_id] = nil
		elseif now - (listAnsweredAt[player_id] or -math.huge) >= LIST_EVERY_SECONDS then
			sendVehicleList(player_id)
		end
	end
end

function careerVehSyncRequested(player_id)
	received("carStates")
	local last = listAnsweredAt[player_id]
	if last and signalTimer:GetCurrent() - last < LIST_EVERY_SECONDS then
		listWanted[player_id] = true
		return
	end
	sendVehicleList(player_id)
end

function careerPrefabSync(player_id, data)
	received("prefabs")
	local prefab = Util.JsonDecode(data)
	if not prefab then return end
	-- Guard: a player disconnecting mid-sync clears their loadedPrefabs entry.
	loadedPrefabs[player_id] = loadedPrefabs[player_id] or {}
	if prefab.pLoad == true then
		loadedPrefabs[player_id][prefab.pName] = prefab
	elseif prefab.pLoad == false then
		loadedPrefabs[player_id][prefab.pName] = nil
	end
	for id in pairs(MP.GetPlayers()) do
		if player_id ~= id then
			send("prefabs", id, "rxPrefabSync", data)
		end
	end
end

-- true when serverVehicleID ("<player_id>-<vehicle_id>") names one of player_id's own
-- vehicles, written exactly as onVehicleSpawnHandler writes it. A player's game may only
-- change its own cars.
local function ownsVehicle(player_id, serverVehicleID)
	if type(serverVehicleID) ~= "string" then return false end
	local owner, vehicle = serverVehicleID:match("^(%d+)%-(%d+)$")
	return owner ~= nil and owner == tostring(tonumber(player_id))
		and vehicle == tostring(tonumber(vehicle))
end
Money.ownsVehicle = ownsVehicle

-- Sends every player the state of one vehicle; the full map goes only to a player who
-- asks for it (careerVehSyncRequested).
local function sendVehicleState(serverVehicleID)
	sendJson("carStates", -1, "rxCareerVehSync", {[serverVehicleID] = vehicleStates[serverVehicleID]})
end

local function describePlayer(player_id)
	return string.format("%s (%s)", consoleText(MP.GetPlayerName(player_id) or "?"), tostring(player_id))
end

local function dropUnstartedPlayer(player_id, why)
	local entry = pendingActivation[player_id]
	if not entry or entry.dropped then return end
	entry.dropped = true
	print("[Mileage] Dropping " .. describePlayer(player_id) .. ": " .. why)
	MP.DropPlayer(player_id, "Mileage failed to load!")
end

--Traffic shares
--
-- Every player's traffic is shared with everyone, so a server-wide total keeps the map
-- from filling as players join. Each player counted (from its settings request, before
-- its career spawns traffic) keeps the per-player amount until the players together
-- would pass server.roadTrafficTotal / parkedTrafficTotal; then the total is split
-- evenly, one spare car each to the lowest player ids. A total of 0 means no limit. A
-- joiner's share goes in its own settings, and players already in get their smaller
-- share (rxCareerTrafficShare) at once, so the total is never passed; a share that grows
-- (a player left) goes SHARE_SETTLE_SECONDS after the last join or leave. Only changed
-- shares are sent.

local SHARE_MAX = 50
local TOTAL_MAX = 400
local SHARE_SETTLE_SECONDS = 3
local sharesSent = {}        -- player_id -> {road, parked}, the share that player has
local sharesChangedAt = nil  -- when players last joined, left or the settings changed

local function wholeIn(value, high)
	local n = tonumber(value)
	if not n or n ~= n then return 0 end
	return math.floor(math.max(0, math.min(high, n)))
end

local function perPlayerAmount(enabledKey, amountKey)
	if Config.client[enabledKey] ~= true then return 0 end
	return wholeIn(Config.client[amountKey], SHARE_MAX)
end

-- perPlayer each for ids (sorted), split from total once they would pass it.
local function split(shares, kind, perPlayer, total, ids)
	local n = #ids
	local each, spare = perPlayer, 0
	if total > 0 and perPlayer * n > total then
		each = math.floor(total / n)
		spare = total - each * n
	end
	for i, id in ipairs(ids) do
		shares[id][kind] = math.min(perPlayer, each + (i <= spare and 1 or 0))
	end
end

-- {[player_id] = {road, parked}} for every player counted.
local function trafficShares()
	local ids = {}
	for id, entry in pairs(pendingActivation) do
		if entry.counted and not entry.dropped then table.insert(ids, id) end
	end
	table.sort(ids)
	local shares = {}
	for _, id in ipairs(ids) do shares[id] = {} end
	split(shares, "road", perPlayerAmount("roadTrafficEnabled", "roadTrafficAmount"),
		wholeIn(Config.server.roadTrafficTotal, TOTAL_MAX), ids)
	split(shares, "parked", perPlayerAmount("parkedTrafficEnabled", "parkedTrafficAmount"),
		wholeIn(Config.server.parkedTrafficTotal, TOTAL_MAX), ids)
	return shares
end

local function sharesChanged()
	sharesChangedAt = signalTimer:GetCurrent()
end

-- Sends each player already in its share when it changed. With onlyDecreases (a join),
-- only shares that went down go now, so the players together never pass the total; the
-- rest wait for sendChangedShares.
local function sendShares(onlyDecreases)
	for id, share in pairs(trafficShares()) do
		local last = sharesSent[id]
		if last and MP.IsPlayerConnected(id) and (last.road ~= share.road or last.parked ~= share.parked)
				and (not onlyDecreases or (share.road <= last.road and share.parked <= last.parked)) then
			sharesSent[id] = share
			sendJson("trafficShare", id, "rxCareerTrafficShare", share)
		end
	end
end

local function sendChangedShares()
	if not sharesChangedAt or signalTimer:GetCurrent() - sharesChangedAt < SHARE_SETTLE_SECONDS then return end
	sharesChangedAt = nil
	sendShares(false)
end

-- The client settings with this player's share added; Config.client itself never gets one.
local function settingsFor(player_id)
	local settings = {}
	for key, value in pairs(Config.client) do settings[key] = value end
	local share = trafficShares()[player_id] or {
		road = perPlayerAmount("roadTrafficEnabled", "roadTrafficAmount"),
		parked = perPlayerAmount("parkedTrafficEnabled", "parkedTrafficAmount"),
	}
	sharesSent[player_id] = share
	settings.trafficShare = share
	return settings
end

function careerSyncRequested(player_id, data)
	received("config")
	local counted = pendingActivation[player_id]
	local joined = counted and not counted.counted
	if joined then counted.counted = true end
	sendJson("config", player_id, "rxCareerSync", settingsFor(player_id))
	Money.sendFeatures(player_id)
	if joined then
		sendShares(true)
		sharesChanged()
	end
	-- Guard: the entry is gone if the player disconnected between join and sync.
	local entry = pendingActivation[player_id]
	if not entry or entry.careerActive then return end
	local request = decodeTable(data)
	if request and request.confirmsStart == true then
		entry.confirmsStart = true
		entry.settingsRequestedAt = signalTimer:GetCurrent()
	else
		entry.careerActive = true
		Money.transfersCareerStarted(player_id)
		Money.eventsCareerStarted(player_id)
		Money.aiRacesCareerStarted(player_id)
	end
end

-- The client's own report of its career start: {"started": true} or
-- {"started": false, "reason": "..."}. Only accepted from a client that said it
-- confirms its start, after its settings request; the reason is printed, never used.
function careerStartResult(player_id, data)
	received("config")
	local entry = pendingActivation[player_id]
	if not entry or not entry.confirmsStart or entry.careerActive or entry.dropped then return end
	local result = decodeTable(data)
	if not result then return end
	if result.started == true then
		entry.careerActive = true
		print("[Mileage] " .. describePlayer(player_id) .. " started their career")
		Money.transfersCareerStarted(player_id)
		Money.eventsCareerStarted(player_id)
		Money.aiRacesCareerStarted(player_id)
	elseif result.started == false then
		dropUnstartedPlayer(player_id, "career start failed: " .. consoleText(result.reason or "no reason given"))
	end
end

function prefabSyncRequested(player_id)
	received("prefabs")
	for id in pairs(MP.GetPlayers()) do
		if player_id ~= id then
			if loadedPrefabs[id] then
				for k,v in pairs(loadedPrefabs[id]) do
					sendJson("prefabs", player_id, "rxPrefabSync", loadedPrefabs[id][k])
				end
			end
		end
	end
end

-- A player's game hid or showed one of its own cars: {"serverVehicleID", "active"}.
function careerVehicleActiveHandler(player_id, data)
	received("carStates")
	local vehicleData = decodeTable(data)
	if not vehicleData or type(vehicleData.active) ~= "boolean" then return end
	local serverVehicleID = vehicleData.serverVehicleID
	if not ownsVehicle(player_id, serverVehicleID) then return end
	local state = vehicleStates[serverVehicleID] or {}
	state.active = vehicleData.active
	vehicleStates[serverVehicleID] = state
	sendVehicleState(serverVehicleID)
end

-- The owner's game marks which of its cars are traffic or parked:
-- {"<player_id>-<vehicle_id>": true | false, ...}. Other games hide the nametag on a
-- marked car. Marks for another player's car, an unknown car or a non-boolean are ignored.
function careerVehicleTrafficMarks(player_id, data)
	received("trafficMarks")
	local marks = decodeTable(data)
	if not marks then return end
	-- Marks that changed together go out together, holding only those cars.
	local changed = {}
	for serverVehicleID, mark in pairs(marks) do
		local state = vehicleStates[serverVehicleID]
		if type(mark) == "boolean" and state and ownsVehicle(player_id, serverVehicleID) then
			state.traffic = mark
			changed[serverVehicleID] = state
		end
	end
	if next(changed) then sendJson("trafficMarks", -1, "rxCareerVehSync", changed) end
end

--Damage between players
--
-- Each player's game sends the dents of its own cars ({"v": "<player>-<vehicle>", "c",
-- "b", "n"}); the server passes a message on, unchanged, to every other player, but only
-- from the car's owner, under DAMAGE_MAX_BYTES and at most DAMAGE_PER_SECOND a second per
-- player. A game that builds a copy of someone's car asks for its full damage
-- ({"v": ...}), which goes to the owner alone. The owner's answer is flagged ("f":1 right
-- after the car id) and goes only to the players who asked for that car, until no chunk
-- of it has come for FULL_WANTED_SECONDS; with nobody waiting it goes to everyone. The games check every
-- value themselves.
--
-- The server reads the car id from the message's fixed start instead of decoding it, and
-- drops a message that could name a second car to a receiver's decoder (another "v", or
-- any escape), so the id checked here is the only one.

local DAMAGE_MAX_BYTES = 32768
local DAMAGE_PER_SECOND = 4
local DAMAGE_REQUEST_MAX_BYTES = 256
local FULL_WANTED_SECONDS = 5
local damageRate = {send = {}, request = {}}
-- fullWanted[serverVehicleID][player_id] = when that player asked for the car's full damage
local fullWanted = {}

-- The car id of a damage message and whether it is a flagged answer; nil for a message
-- not in the form the games send.
local function readDamageMessage(data)
	local serverVehicleID = data:match('^{"v":"(%d+%-%d+)",')
	if not serverVehicleID or data:sub(-1) ~= "}" then return nil end
	if data:find('"v"', 3, true) or data:find("\\", 1, true) then return nil end
	local after = #serverVehicleID + 9
	return serverVehicleID, data:sub(after, after + 5) == '"f":1,'
end

-- The players still waiting for a car's full damage, or nil when none is.
local function playersWaitingFor(serverVehicleID)
	local askers = fullWanted[serverVehicleID]
	if not askers then return nil end
	local now = signalTimer:GetCurrent()
	for id, at in pairs(askers) do
		if now - at > FULL_WANTED_SECONDS or not MP.IsPlayerConnected(id) then askers[id] = nil end
	end
	if next(askers) then return askers end
	fullWanted[serverVehicleID] = nil
	return nil
end

-- true while player_id is within the per-second limit of this kind of message.
local function withinDamageRate(kind, player_id)
	local now = signalTimer:GetCurrent()
	local rate = damageRate[kind][player_id]
	if not rate or now - rate.since >= 1 then
		rate = {since = now, count = 0}
		damageRate[kind][player_id] = rate
	end
	rate.count = rate.count + 1
	return rate.count <= DAMAGE_PER_SECOND
end

function careerDamage(player_id, data)
	received("damage")
	if type(data) ~= "string" or #data > DAMAGE_MAX_BYTES then return end
	if not withinDamageRate("send", player_id) then return end
	local serverVehicleID, answer = readDamageMessage(data)
	if not serverVehicleID or not ownsVehicle(player_id, serverVehicleID) then return end
	local askers = answer and playersWaitingFor(serverVehicleID)
	if askers then
		-- An answer under way keeps its players: one asked later restarts it, and the
		-- first must still get the chunks it has not had yet.
		local now = signalTimer:GetCurrent()
		for id in pairs(askers) do askers[id] = now end
	end
	local targets = askers or MP.GetPlayers()
	for id in pairs(targets) do
		if id ~= player_id then
			send("damage", id, "rxCareerDamage", data)
		end
	end
end

function careerDamageRequest(player_id, data)
	received("damage")
	if type(data) ~= "string" or #data > DAMAGE_REQUEST_MAX_BYTES then return end
	local request = decodeTable(data)
	local serverVehicleID = request and request.v
	if type(serverVehicleID) ~= "string" or isTraffic(serverVehicleID) then return end
	if not withinDamageRate("request", player_id) then return end
	local owner = serverVehicleID:match("^(%d+)%-%d+$")
	owner = tonumber(owner)
	if not owner or owner == player_id or not MP.GetPlayers()[owner] then return end
	if not ownsVehicle(owner, serverVehicleID) then return end
	fullWanted[serverVehicleID] = fullWanted[serverVehicleID] or {}
	fullWanted[serverVehicleID][player_id] = signalTimer:GetCurrent()
	send("damage", owner, "rxCareerDamageRequest", '{"v":"' .. serverVehicleID .. '"}')
end

function validateMileageActivation()
	local now = signalTimer:GetCurrent()
	for id in pairs(MP.GetPlayers()) do
		local entry = pendingActivation[id]
		if entry and not entry.careerActive and not entry.dropped and MP.IsPlayerConnected(id) then
			if entry.settingsRequestedAt then
				if now - entry.settingsRequestedAt >= startConfirmThreshold then
					dropUnstartedPlayer(id, string.format("no career start confirmed within %d s of the settings request",
						startConfirmThreshold))
				end
			elseif entry.joinTimestamp and now - entry.joinTimestamp >= activationThreshold then
				dropUnstartedPlayer(id, string.format("no settings request within %d s of joining", activationThreshold))
			end
		end
	end
end

local function sendAlive()
	for id in pairs(MP.GetPlayers()) do
		if MP.IsPlayerConnected(id) then
			send("alive", id, "rxMileageAlive", "")
		end
	end
end

function tick()
	if willExit then
		exit()
	end
	validateMileageActivation()
	sendWantedVehicleLists()
	sendChangedShares()
	Money.transfersTick()
	Money.offersTick()
	Money.racesTick()
	Money.eventsTick()
	Money.aiRacesTick()
	ticksSinceAlive = ticksSinceAlive + 1
	if ticksSinceAlive >= ALIVE_EVERY_TICKS then
		ticksSinceAlive = 0
		sendAlive()
	end
end

function onPlayerJoinHandler(player_id)
	loadedPrefabs[player_id] = {}
	pendingActivation[player_id] = {
		joinTimestamp = signalTimer:GetCurrent(),
		careerActive = false,
		-- BeamMP may drop a leaving player from its list before the plugin hears of the
		-- leave, so the name their races and transfers know them by is kept here.
		name = MP.GetPlayerName(player_id),
	}
end

function onVehicleSpawnHandler(player_id, vehicle_id,  data)
	local serverVehicleID = player_id .. "-" .. vehicle_id
	vehicleStates[serverVehicleID] = {active = true}
	sendVehicleState(serverVehicleID)
end

-- A rebuilt car is switched on, and every player is told: their copy is rebuilt too and
-- must not take the hidden state they last kept for it.
function onVehicleEditedHandler(player_id, vehicle_id,  data)
	local serverVehicleID = player_id .. "-" .. vehicle_id
	local state = vehicleStates[serverVehicleID] or {}
	state.active = true
	vehicleStates[serverVehicleID] = state
	sendVehicleState(serverVehicleID)
end

function onVehicleDeletedHandler(player_id, vehicle_id)
	if vehicleStates[player_id .. "-" .. vehicle_id] then
		vehicleStates[player_id .. "-" .. vehicle_id] = nil
	end
end

function onPlayerDisconnectHandler(player_id)
	-- Release their strip presence first: if they held a strip, someone still standing
	-- there has to inherit it or an in-progress race loses its authority.
	releaseDragPresence(player_id)
	Money.offersPlayerLeft(player_id)
	local entry = pendingActivation[player_id]
	local name = entry and entry.name or MP.GetPlayerName(player_id)
	if name then
		Money.racesPlayerLeft(name)
		Money.eventsPlayerLeft(name)
		Money.aiRacesPlayerLeft(name)
	end
	loadedPrefabs[player_id] = nil
	ledger.send[player_id] = nil
	ledger.receive[player_id] = nil
	pendingActivation[player_id] = nil
	damageRate.send[player_id] = nil
	damageRate.request[player_id] = nil
	listAnsweredAt[player_id] = nil
	listWanted[player_id] = nil
	if sharesSent[player_id] then
		sharesSent[player_id] = nil
		sharesChanged()
	end
	-- BeamMP removes a leaving player's cars; their states go with them.
	local prefix = tostring(player_id) .. "-"
	for serverVehicleID in pairs(vehicleStates) do
		if serverVehicleID:sub(1, #prefix) == prefix then vehicleStates[serverVehicleID] = nil end
	end
	for serverVehicleID, askers in pairs(fullWanted) do
		askers[player_id] = nil
		if serverVehicleID:sub(1, #prefix) == prefix or not next(askers) then fullWanted[serverVehicleID] = nil end
	end
end

function onConsoleInputHandler(message)
	local space = message:find(" ")
	if not space then
		return ""
	end
	local commandPrefix = message:sub(1, space)
	if commandPrefix == "Mileage " then
		local prefixLen = commandPrefix:len()
		message = message:sub(prefixLen + 1)
		local command = message
		local arguments = {}
		local separator = message:find(' ')
		if separator then
			command, arguments = parseCommand(message, separator)
		end
		MP.TriggerLocalEvent(command, arguments)
	end
	return ""
end

local function checkValue(value)
	if tonumber(value) then
		return tonumber(value)
	elseif value == "true" then
		return true
	elseif value == "false" then
		return false
	end
	return value
end

function GetConfig(arguments)
	Config = ReadJson(configPath .. "config.json")
	if #arguments == 0 then
		print(Config)
	elseif #arguments == 1 then
		print(Config[arguments[1]])
	else
		print(Config[arguments[1]][arguments[2]])
	end
end

function SetConfig(arguments)
	if #arguments < 3 then
		print("Usage: Mileage SetConfig <section> <key> <value>")
		return
	end
	Config = ReadJson(configPath .. "config.json")
	local section = arguments[1]
	local key = arguments[2]
	local value = arguments[3]
	if not Config[section] then
		print("[Mileage] ---------- Unknown section: " .. section)
		return
	end
	if Config[section][key] == nil then
		print("[Mileage] ---------- Unknown key: " .. section .. " " .. key)
		return
	end
	Config[section][key] = checkValue(value)
	print("[Mileage] ---------- Config:    " .. section .. " " .. tostring(key) .. " set to " .. tostring(Config[section][key]))
	WriteJson(configPath .. "config.json", Config)
	sendJson("config", -1, "rxClientConfigUpdate", Config.client)
	Money.sendFeatures(-1)
	Money.sendAiRaceStatus()
	-- Offers of a feature switched off close on the next tick.
	-- An amount, a switch or a total may have changed everyone's share.
	sharesChanged()
end

function Update(arguments)
	checkForUpdates()
end

function Help(arguments)
	print("Mileage GetConfig <section> <key>            - Displays Config, or section, or key")
	print("Mileage SetConfig <section*> <key*> <value*> - Sets Config section key to value, * = REQUIRED")
	print("Mileage Update                               - Checks for Mileage update")
	print("Mileage Stats [reset]                        - Shows what each part of Mileage sends, reset starts it again")
	print("Mileage Transfers                            - Lists money still waiting on a player, and races holding stakes")
	print("Mileage Leaderboard [reset]                  - Shows the leaderboard, reset clears it")
	print("Mileage Event <minutes> <prize> <route|random> | cancel | list - Schedules, cancels or lists race events")
	print("Mileage Help                                 - Displays Commands Usage")
end

-- The counts of the last STATS_SECONDS, summed from the slots still inside the window.
local function windowCounts()
	local cutoff = math.floor(signalTimer:GetCurrent()) - STATS_SECONDS
	local sums = {}
	for _, slot in pairs(stats.slots) do
		if slot.second > cutoff then
			for feature, counts in pairs(slot.counts) do
				local sum = countsIn(sums, feature)
				for key, n in pairs(counts) do sum[key] = sum[key] + n end
			end
		end
	end
	return sums
end

local function printStats()
	local window = windowCounts()
	print(string.format("[Mileage] Stats - last %d s | since start (%d s ago)", STATS_SECONDS,
		math.floor(signalTimer:GetCurrent() - stats.since)))
	print(string.format("%-14s %8s %8s %8s %10s | %8s %8s %8s %12s", "feature", "received", "sent", "to",
		"bytes", "received", "sent", "to", "bytes"))
	for _, feature in ipairs(STATS_FEATURES) do
		local w, t = countsIn(window, feature), countsIn(stats.totals, feature)
		print(string.format("%-14s %8d %8d %8d %10d | %8d %8d %8d %12d", feature, w.received, w.sent,
			w.recipients, w.bytes, t.received, t.sent, t.recipients, t.bytes))
	end

	local players, cars = {}, {}
	local function newCarCounts() return {all = 0, shown = 0, traffic = 0, trafficShown = 0} end
	for id in pairs(MP.GetPlayers() or {}) do
		table.insert(players, id)
		cars[id] = newCarCounts()
	end
	table.sort(players)
	-- Hidden cars are counted apart: a player who joined before the server filled keeps
	-- the traffic above its new share, hidden, so the shown count is what the total holds.
	local server = newCarCounts()
	for serverVehicleID, state in pairs(vehicleStates) do
		local owner = tonumber(serverVehicleID:match("^(%d+)%-"))
		for _, counts in ipairs({server, owner and cars[owner] or nil}) do
			counts.all = counts.all + 1
			if state.active ~= false then counts.shown = counts.shown + 1 end
			if state.traffic == true then
				counts.traffic = counts.traffic + 1
				if state.active ~= false then counts.trafficShown = counts.trafficShown + 1 end
			end
		end
	end
	print(string.format("Players: %d", #players))
	print(string.format("Cars: %d (%d shown), %d of them traffic or parked (%d shown)", server.all, server.shown,
		server.traffic, server.trafficShown))
	local function total(key)
		local n = wholeIn(Config.server[key], TOTAL_MAX)
		return n > 0 and tostring(n) or "no limit"
	end
	print(string.format("Traffic total: %s driving, %s parked", total("roadTrafficTotal"), total("parkedTrafficTotal")))
	for _, id in ipairs(players) do
		local c = cars[id]
		local line = string.format("  %s: %d cars (%d shown), %d traffic or parked (%d shown)", describePlayer(id), c.all,
			c.shown, c.traffic, c.trafficShown)
		local share = sharesSent[id]
		if share then line = line .. string.format(", share %d driving %d parked", share.road, share.parked) end
		print(line)
	end
end

function Stats(arguments)
	local argument = arguments and arguments[1]
	if argument == nil then
		printStats()
	elseif argument == "reset" then
		resetStats()
		print("[Mileage] Stats reset")
	else
		print("Usage: Mileage Stats [reset]")
	end
end

function ReadJson(path)
	if not path then
		print("[Mileage] ---------- ReadJson:  path is nil!")
		return
	end
	if not FS.Exists(path) then
		print("[Mileage] ---------- ReadJson:  " .. path .. " does not exist!")
		return
	end
	local jsonFile, err = io.open(path, "r")
	if not jsonFile then
		print("[Mileage] ---------- ReadJson:  failed to open " .. path .. ": " .. tostring(err))
		return
	end
	local jsonText = jsonFile:read("*a")
	jsonFile:close()
	if not jsonText or jsonText == "" then
		print("[Mileage] ---------- ReadJson:  " .. path .. " is empty!")
		return
	end
	local data = Util.JsonDecode(jsonText)
	if data == nil then
		print("[Mileage] ---------- ReadJson:  failed to decode " .. path)
		return
	end
	return data
end

function WriteJson(path, data)
	if not path then
		print("[Mileage] ---------- WriteJson: path is nil!")
		return
	end
	if data == nil then
		print("[Mileage] ---------- WriteJson: data is nil, aborting!")
		return
	end
	local checkDirectory = path:match("(.+)/[^/]+$")
	if checkDirectory and not FS.Exists(checkDirectory) then
		FS.CreateDirectory(checkDirectory)
		print("[Mileage] ---------- WriteJson: created directory " .. checkDirectory)
	end
	local encoded = Util.JsonEncode(data)
	if not encoded then
		print("[Mileage] ---------- WriteJson: failed to encode data!")
		return
	end
	local jsonFile, err = io.open(path, "w")
	if not jsonFile then
		print("[Mileage] ---------- WriteJson: failed to open " .. path .. ": " .. tostring(err))
		return
	end
	print("[Mileage] ---------- WriteJson: writing " .. path)
	jsonFile:write(Util.JsonPrettify(encoded))
	jsonFile:close()
	return true
end
