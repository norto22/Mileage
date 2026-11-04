--Mileage :: offers between players (CLIENT)
--
-- Race challenges and money requests are offers the server holds (see the Offers section
-- of the server plugin). This sends the player's offers and answers, keeps the server's
-- switches and limits (rxMileageFeatures) so the player list can say why an action is
-- unavailable, and passes every offer to the Mileage prompts app through guihooks:
--
--   MileageFeatures       the server's switches and limits
--   MileagePlayerActions  {name, race, drag, pay, request}: whether each action is open, and why not
--   MileageOffer          an offer to this player, with its two answers
--   MileageOfferClosed    {id, why, text}: an offer answered, expired or withdrawn
--
-- Called from the UI apps: mileage_offers.request(name, amount), .race(name, stake),
-- .dragRace(name, stake), .answer(id, accept), .actionsFor(name), .sendState().

local M = {}

local logTag = "mileage.offers"

local features = nil   -- the server's switches and limits, once it sent them
local incoming = {}    -- id -> the offer as shown, with secondsLeft
local outgoing = {}    -- id -> the offer this player made

local function toast(kind, title, msg)
	guihooks.trigger("toastrMsg", {type = kind, title = title, msg = msg, config = {timeOut = 4000}})
end

local function nickname()
	return MPConfig.getNickname()
end

-- {name, playerID} of a player in this session, or nil.
local function findPlayer(name)
	if type(name) ~= "string" or name == "" then return nil end
	for _, player in pairs(MPVehicleGE.getPlayers() or {}) do
		if player.name == name then return player end
	end
	return nil
end

local function wholeAmount(amount, allowZero)
	amount = tonumber(amount)
	if not amount or amount ~= amount or amount % 1 ~= 0 or amount < 0 or amount >= 1e12 then return nil end
	if amount == 0 and not allowZero then return nil end
	return amount
end

local function money()
	local attribute = career_modules_playerAttributes and career_modules_playerAttributes.getAttribute("money")
	return attribute and tonumber(attribute.value) or 0
end

local function streetRace()
	local race = extensions.mileage_streetRace
	if type(race) == "table" then return race end
	return nil
end

--== what the player list may offer ===========================================

local function payProblem(name)
	if features and not features.allowTransactions then return "Payments are switched off on this server." end
	if name == nickname() then return "You cannot pay yourself." end
	if not findPlayer(name) then return name .. " is not in this session." end
	return nil
end

local function requestProblem(name)
	if features and not features.allowTransactions then return "Payments are switched off on this server." end
	if features and not features.allowMoneyRequests then return "Requests are switched off on this server." end
	if name == nickname() then return "You cannot ask yourself for money." end
	if not findPlayer(name) then return name .. " is not in this session." end
	return nil
end

-- Why name cannot be challenged to any race by this player, or nil.
local function rivalProblem(name)
	if features and not features.allowRacing then return "Racing is switched off on this server." end
	if name == nickname() then return "You cannot race yourself." end
	if not findPlayer(name) then return name .. " is not in this session." end
	return nil
end

-- {ok, why, distance, start, finish} for a race against name.
local function raceCheck(name)
	local rival = rivalProblem(name)
	if rival then return {ok = false, why = rival} end
	local race = streetRace()
	if not race or type(race.checkStart) ~= "function" then
		return {ok = false, why = "Racing is not available in this game."}
	end
	local check = race.checkStart(features and features.raceMinDistance or 0)
	check.ok = check.why == nil
	return check
end

-- Why this player cannot challenge name to a drag race, or nil: no route is needed, the
-- race is the pair's next run together at the strip.
local function dragProblem(name)
	local rival = rivalProblem(name)
	if rival then return rival end
	local race = streetRace()
	if not race or type(race.eligibility) ~= "function" then return "Racing is not available in this game." end
	return (race.eligibility())
end

--- Tells the player list what can be done with this player, and why not.
function M.actionsFor(name)
	local race = raceCheck(name)
	local drag = dragProblem(name)
	local pay, request = payProblem(name), requestProblem(name)
	guihooks.trigger("MileagePlayerActions", {
		name = name,
		race = {ok = race.ok, why = race.why, distance = race.distance,
			stakeMax = features and features.raceStakeMax or 0, prize = features and features.racePrize or 0,
			cooldown = features and features.racePrizeCooldownMinutes or 0},
		drag = {ok = drag == nil, why = drag, stakeMax = features and features.raceStakeMax or 0,
			prize = features and features.dragRacePrize or 0, minutes = features and features.raceTimeLimitMinutes or 15},
		pay = {ok = pay == nil, why = pay, money = money()},
		request = {ok = request == nil, why = request},
	})
end

--== sending ===================================================================

function M.request(name, amount)
	local why = requestProblem(name)
	amount = wholeAmount(amount, false)
	if not why and not amount then why = "Enter a whole number of dollars above $0." end
	if not why and features and amount > (features.sessionSendingMax or math.huge) then
		why = "That is more than this server lets a player send."
	end
	if why then
		toast("error", "Request not sent", why)
		return false
	end
	TriggerServerEvent("mileageOffer", jsonEncode({kind = "request", to = findPlayer(name).playerID, amount = amount}))
	return true
end

-- Why this stake cannot be offered, or nil.
local function stakeProblem(stake)
	if not stake then return "Enter a stake of $0 or more, in whole dollars." end
	if features and stake > (features.raceStakeMax or 0) then
		return "That stake is above this server's limit of $" .. tostring(features.raceStakeMax) .. "."
	end
	if stake > money() then return "You do not have the money for that stake." end
	return nil
end

function M.race(name, stake)
	stake = wholeAmount(stake == nil and 0 or stake, true)
	local check = raceCheck(name)
	local why = check.why or stakeProblem(stake)
	if why then
		toast("error", "Challenge not sent", why)
		return false
	end
	TriggerServerEvent("mileageOffer", jsonEncode({kind = "race", to = findPlayer(name).playerID, amount = stake,
		finish = check.finish, start = check.start}))
	return true
end

--- Challenges name to a drag race for a stake: their next run together at the strip.
function M.dragRace(name, stake)
	stake = wholeAmount(stake == nil and 0 or stake, true)
	local why = dragProblem(name) or stakeProblem(stake)
	if why then
		toast("error", "Challenge not sent", why)
		return false
	end
	TriggerServerEvent("mileageOffer", jsonEncode({kind = "drag", to = findPlayer(name).playerID, amount = stake}))
	return true
end

function M.answer(id, accept)
	local offer = type(id) == "string" and incoming[id]
	if not offer then return false end
	incoming[id] = nil
	-- A challenge is only accepted from one of the player's own cars, outside a mission and
	-- not in another race; otherwise it is declined here, before any stake is taken.
	if accept == true and (offer.kind == "race" or offer.kind == "drag") then
		local race = streetRace()
		local why = "Racing is not available in this game."
		if race and type(race.eligibility) == "function" then why = race.eligibility() end
		if why then
			toast("error", "Challenge declined", why)
			accept = false
		end
	end
	TriggerServerEvent("mileageOfferAnswer", jsonEncode({id = id, accept = accept == true}))
	return true
end

--- Sends the player list and the prompts app everything they show, after a UI reload.
function M.sendState()
	if features then guihooks.trigger("MileageFeatures", features) end
	for _, offer in pairs(incoming) do guihooks.trigger("MileageOffer", offer) end
end

--== from the server ===========================================================

local function rxMileageFeatures(data)
	local decoded = jsonDecode(data)
	if type(decoded) ~= "table" then return end
	features = decoded
	guihooks.trigger("MileageFeatures", features)
end

local function rxMileageOffer(data)
	local offer = jsonDecode(data)
	if type(offer) ~= "table" or type(offer.id) ~= "string" then return end
	offer.secondsLeft = tonumber(offer.expires) or 60
	incoming[offer.id] = offer
	guihooks.trigger("MileageOffer", offer)
end

local function rxMileageOfferSent(data)
	local offer = jsonDecode(data)
	if type(offer) ~= "table" or type(offer.id) ~= "string" then return end
	outgoing[offer.id] = offer
	local what = (offer.kind == "race" or offer.kind == "drag") and "Challenge sent" or "Request sent"
	toast("info", what, "Waiting for " .. tostring(offer.to) .. " to answer.")
end

local function rxMileageOfferClosed(data)
	local closed = jsonDecode(data)
	if type(closed) ~= "table" then return end
	local text = type(closed.text) == "string" and closed.text or ""
	if closed.id == nil then
		-- The server turned this player's own offer down before showing it.
		toast("error", (closed.kind == "race" or closed.kind == "drag") and "Challenge not sent" or "Request not sent", text)
		return
	end
	incoming[closed.id] = nil
	guihooks.trigger("MileageOfferClosed", {id = closed.id, why = closed.why, text = text})
	local mine = outgoing[closed.id]
	outgoing[closed.id] = nil
	if not mine then return end
	local what = (mine.kind == "race" or mine.kind == "drag") and "your challenge"
		or "your request for $" .. tostring(mine.amount)
	if closed.why == "accepted" then
		toast("success", "Accepted", tostring(mine.to) .. " accepted " .. what .. ".")
	elseif closed.why == "declined" then
		toast("warning", "Declined", tostring(mine.to) .. " declined " .. what .. ".")
	else
		toast("warning", "Offer closed", text)
	end
end

function M.onUpdate(dtReal)
	local dt = math.max(0, math.min(1, tonumber(dtReal) or 0))
	for id, offer in pairs(incoming) do
		offer.secondsLeft = offer.secondsLeft - dt
		-- The server closes it; this only keeps a lost closing message from leaving it up.
		if offer.secondsLeft < -10 then
			incoming[id] = nil
			guihooks.trigger("MileageOfferClosed", {id = id, why = "expired", text = "No answer came in time."})
		end
	end
end

function M.onBeamMPServerLeave()
	features, incoming, outgoing = nil, {}, {}
end

function M.onExtensionLoaded()
	if type(AddEventHandler) ~= "function" then
		log("E", logTag, "AddEventHandler unavailable - BeamMP not loaded")
		return
	end
	AddEventHandler("rxMileageFeatures", rxMileageFeatures)
	AddEventHandler("rxMileageOffer", rxMileageOffer)
	AddEventHandler("rxMileageOfferSent", rxMileageOfferSent)
	AddEventHandler("rxMileageOfferClosed", rxMileageOfferClosed)
	log("I", logTag, "Mileage offers LOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
