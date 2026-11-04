// Mileage prompts: race challenges and money requests to this player, the race
// countdown, race panel and result, race events and the server leaderboard. While the
// race window (Mileage-Race) is on the page, it shows the countdown and the race panel
// instead (moRaceWindowShows). Fed by the game's Mileage extensions through guihooks
// (mileage/offers.lua and the race, event and leaderboard extensions); every answer goes
// back through bngApi.engineLua with ids and names base64-encoded. Every text from the
// server or another player is bound as text.
//
// NOTE: top-level declarations must be `var` or function declarations: the game's UI
// app service evaluates app.js again in the same scope when it refreshes apps, and a
// repeated top-level `let` or `const` would stop the directive from registering.

var mileageOffersApp = angular.module('beamng.apps');
mileageOffersApp.directive('mileageoffers', [function () {
	return {
		templateUrl: '/ui/modules/apps/Mileage-Offers/app.html',
		replace: true,
		restrict: 'EA',
		scope: true
	};
}]);

mileageOffersApp.controller('MileageOffers', ['$scope', function ($scope) {
	$scope.offers = [];

	function view(offer) {
		var from = String(offer.from || "");
		if (offer.kind === "race") {
			var stake = Number(offer.amount) || 0;
			var prize = Number(offer.prize) || 0;
			var wins = stake > 0 ? moDollars(stake * 2) : "";
			if (prize > 0) wins = (wins ? wins + " + " : "") + moDollars(prize) + " server prize";
			var rows = [
				{label: "Finish", value: moKm(offer.distance) + " from them"},
				{label: "Stake", value: stake > 0 ? moDollars(stake) + " each" : "No stake"},
			];
			if (wins) rows.push({label: "Winner gets", value: wins});
			return {
				title: from + " challenges you to a race",
				rows: rows,
				note: stake > 0 ? "Your car moves beside theirs · leaving loses your stake" :
					"Accepting moves your car beside theirs",
				accept: "Accept",
			};
		}
		if (offer.kind === "drag") {
			var dragStake = Number(offer.amount) || 0;
			var dragRows = [
				{label: "Where", value: "The drag strip, within " + (Number(offer.minutes) || 15) + " min"},
				{label: "Stake", value: dragStake > 0 ? moDollars(dragStake) + " each" : "No stake"},
			];
			var dragWins = moWinnerGets(dragStake * 2, Number(offer.prize) || 0, " server prize");
			if (dragWins) dragRows.push({label: "Winner gets", value: dragWins});
			return {
				title: from + " challenges you to a drag race",
				rows: dragRows,
				note: dragStake > 0 ?
					"Your next run together decides it · after the green, leaving or jumping the start loses your stake" :
					"Your next run together decides it",
				accept: "Accept",
			};
		}
		return {
			title: from + " asks you for " + moDollars(offer.amount),
			rows: [],
			note: "Counts towards your sending limits on this server.",
			accept: "Pay " + moDollars(offer.amount),
		};
	}

	function removeOffer(id) {
		$scope.offers = $scope.offers.filter(function (o) { return o.id !== id; });
	}

	$scope.$on('MileageOffer', function (event, data) {
		if (!data || typeof data.id !== "string") return;
		$scope.$evalAsync(function () {
			removeOffer(data.id);
			var seconds = Number(data.secondsLeft || data.expires) || 60;
			$scope.offers.push({
				id: data.id, kind: data.kind, from: data.from, amount: data.amount,
				seconds: seconds, shownAt: Date.now(), view: view(data),
			});
		});
	});

	$scope.$on('MileageOfferClosed', function (event, data) {
		if (!data) return;
		$scope.$evalAsync(function () { removeOffer(data.id); });
	});

	// How much of the offer's time is left, as a CSS width.
	$scope.barWidth = function (offer) {
		var left = 1 - (Date.now() - offer.shownAt) / (offer.seconds * 1000);
		return Math.max(0, Math.min(1, left)) * 100 + "%";
	};

	$scope.answer = function (offer, accept) {
		if (offer.answered) return;
		offer.answered = true;
		removeOffer(offer.id);
		bngApi.engineLua('if mileage_offers then mileage_offers.answer(' + moLuaString(offer.id) + ', ' +
			(accept ? 'true' : 'false') + ') end');
	};

	//== a street race: countdown, race panel, result ============================

	$scope.race = null;

	// A race against a traffic car starts rolling: nobody stops, and it carries the race reward.
	function rollingView(data) {
		var other = String(data.other || "");
		var reward = Number(data.reward) || 0;
		var rewardText = reward > 0 ? " · reward " + moDollars(reward) : "";
		switch (data.phase) {
		case "countdown":
			return {title: "vs " + other, big: String(data.count), note: "Rolling start · keep driving" + rewardText};
		case "go":
			return {title: "vs " + other, big: "GO", note: reward > 0 ? "Race reward " + moDollars(reward) : undefined};
		case "racing":
			return {
				title: "Racing " + other,
				big: moTime(data.elapsed),
				note: (typeof data.distance === "number" ? "Finish " + moKm(data.distance) + " · " : "") +
					"follow your map route" + rewardText,
				giveUp: "Give up",
			};
		case "finished":
			return {title: "Finished in " + moTime(data.elapsed), note: "Waiting for the other racers..."};
		}
		return null;
	}

	function raceView(data) {
		if (data.rolling) return rollingView(data);
		var other = String(data.other || "");
		var stake = Number(data.stake) || 0;
		var stakeText = stake > 0 ? moDollars(stake) + " stake" : "no stake";
		// An event race shows the prize for the racers who started instead.
		var eventPrize = data.event ? Number(data.prize) || 0 : 0;
		if (eventPrize > 0) stakeText = "prize " + moDollars(eventPrize) + " for " + (Number(data.racers) || 0) + " racers";
		switch (data.phase) {
		case "staking":
			return {title: "Race vs " + other, note: stake > 0 ? "Taking both stakes..." : "Getting ready..."};
		case "lining up":
			return {title: "Race vs " + other, note: "Lining up beside each other..."};
		case "countdown":
			return {big: String(data.count), note: "vs " + other + " · " + stakeText};
		case "go":
			return {big: "GO", note: "vs " + other + " · " + stakeText};
		case "racing":
			return {
				title: "Racing " + other,
				big: moTime(data.elapsed),
				note: (typeof data.distance === "number" ? "Finish " + moKm(data.distance) + " · " : "") +
					"follow your map route",
				giveUp: stake > 0 ? "Give up (lose " + moDollars(stake) + ")" : "Give up",
			};
		case "finished":
			return {title: "Finished in " + moTime(data.elapsed), note: "Waiting for " + other + "..."};
		case "calledOff":
			return {title: "Race called off", note: String(data.why || "") + ".", close: true,
				rows: stake > 0 ? [{label: "Stake", value: moDollars(stake) + " back to you"}] : []};
		case "result":
			return resultView(data);
		}
		return null;
	}

	function resultView(data) {
		var you = String(data.you || ""), other = String(data.other || "");
		var times = data.times || {};
		var stake = Number(data.stake) || 0, pot = Number(data.pot) || 0, prize = Number(data.prize) || 0;
		var rows = [];
		var mine = times[you], theirs = times[other];
		if (typeof mine === "number") {
			rows.push({label: "Your time", value: moTime(mine)});
		} else if (data.gaveUp === you) {
			rows.push({label: "Your time", value: data.why === "left" ? "did not finish: you left the race"
				: "did not finish: you gave up"});
		}
		if (typeof theirs === "number") {
			var gap = typeof mine === "number" ? " (" + (theirs >= mine ? "+" : "-") +
				Math.abs(theirs - mine).toFixed(1) + " s)" : "";
			rows.push({label: other, value: moTime(theirs) + gap});
		} else if (data.gaveUp === other) {
			rows.push({label: other, value: data.why === "left" ? "left the race" : "gave up"});
		}
		if (!data.winner) {
			if (stake > 0) rows.push({label: "Stake", value: moDollars(stake) + " back to you"});
			return {title: "No winner", rows: rows, close: true,
				note: data.why === "timeout" ? "Nobody reached the finish in time." : "The race ended without a winner."};
		}
		if (data.winner === you) {
			var parts = [];
			if (pot > 0) parts.push(moDollars(pot) + " stakes");
			if (prize > 0) parts.push(moDollars(prize) + " prize");
			if (parts.length > 0) rows.push({label: "You get", value: parts.join(" + ")});
			return {title: "You won", rows: rows, close: true};
		}
		if (stake > 0) rows.push({label: "You lost", value: "your " + moDollars(stake) + " stake"});
		return {title: String(data.winner) + " won", rows: rows, close: true};
	}

	$scope.$on('MileageRace', function (event, data) {
		if (!data) return;
		$scope.$evalAsync(function () {
			if (moRaceWindowShows(data.phase)) {
				$scope.race = null;
				return;
			}
			var shown = raceView(data);
			$scope.race = shown ? {id: data.race, phase: data.phase, view: shown} : null;
		});
	});

	$scope.giveUp = function () {
		bngApi.engineLua('if mileage_streetRace then mileage_streetRace.giveUp() end');
	};

	$scope.closeRace = function () {
		$scope.race = null;
	};

	//== a drag race for money ===================================================
	// mileage/dragMoney.lua sends MileageDragRace: a staked drag race's "staking", "toStrip"
	// (both stakes held until the pair's next run together; note "lined" once their run is
	// out, "ended" when it ended before the green), "racing" and "calledOff", and the
	// "result" of a staked run or of a plain run that paid the server's prize.

	$scope.drag = null;

	function dragTimeText(seconds) {
		return Number(seconds).toFixed(3) + " s";
	}

	function upperFirst(text) {
		text = String(text || "");
		return text.charAt(0).toUpperCase() + text.slice(1);
	}

	// The time row of one racer: their time, or why they have none.
	function dragTimeRow(data, name, label, against) {
		var times = data.times || {}, outcomes = data.outcomes || {};
		var mine = times[name];
		if (typeof mine === "number") {
			var gap = typeof against === "number" && mine > against ? " (+" + (mine - against).toFixed(3) + " s)" : "";
			return {label: label, value: dragTimeText(mine) + gap};
		}
		var left = data.why === "left" && data.winner && data.winner !== name;
		var self = name === data.you;
		if (left) return {label: label, value: self ? "did not finish: you left the race" : "left the race"};
		if (outcomes[name] === "jumped") return {label: label, value: "jumped the start"};
		return {label: label, value: "did not finish"};
	}

	function dragResultView(data) {
		var you = String(data.you || ""), other = String(data.other || "");
		var stake = Number(data.stake) || 0, pot = Number(data.pot) || 0, prize = Number(data.prize) || 0;
		var times = data.times || {};
		var staked = typeof data.race === "string";
		var rows = [];
		if (!data.winner) {
			if (stake > 0) rows.push({label: "Stake", value: moDollars(stake) + " back to you"});
			var why = data.why === "tie" ? "A dead heat" : "Neither car crossed the finish line";
			return {title: "No winner", rows: rows, close: true,
				note: stake > 0 ? why + " · both stakes go back." : why + "."};
		}
		if (staked) {
			rows.push(dragTimeRow(data, you, "Your time", times[other]));
			rows.push(dragTimeRow(data, other, other, times[you]));
		} else {
			rows.push({label: "vs", value: other});
		}
		if (data.winner === you) {
			var parts = [];
			if (pot > 0) parts.push(moDollars(pot) + " stakes");
			if (prize > 0) parts.push(moDollars(prize) + " prize");
			if (parts.length > 0) rows.push({label: "You get", value: parts.join(" + ")});
			// The same pair earned the server prize within the owner's drag wait.
			var againIn = typeof data.prizeAgainIn === "number" ? data.prizeAgainIn : 0;
			if (prize === 0 && againIn > 0) {
				rows.push({label: "Server prize", value: "again in " + Math.ceil(againIn / 60) + " min"});
			}
			return {title: pot + prize > 0 ? "You won " + moDollars(pot + prize) : "You won", rows: rows, close: true};
		}
		if (stake > 0) rows.push({label: "You lost", value: "your " + moDollars(stake) + " stake"});
		return {title: String(data.winner) + " won the drag race", rows: rows, close: true};
	}

	function dragView(data) {
		var other = String(data.other || "");
		var stake = Number(data.stake) || 0, prize = Number(data.prize) || 0;
		var title = "Drag race vs " + other;
		var held = {label: "Stakes held", value: stake > 0 ? moDollars(stake) + " each" : "No stake"};
		var left = " · " + (Number(data.minutesLeft) || 0) + " min left";
		switch (data.phase) {
		case "staking":
			return {title: title, note: stake > 0 ? "Taking both stakes..." : "Getting ready..."};
		case "toStrip":
			var rows = [held];
			var wins = moWinnerGets(stake * 2, prize, " prize");
			if (data.note !== "lined" && data.note !== "ended" && wins) rows.push({label: "Winner gets", value: wins});
			var note = data.note === "lined" ? "This run decides the stakes" :
				data.note === "ended" ? "That run ended before the green · stakes still held, line up again" :
				"Meet at the drag strip and line up together";
			return {title: title, rows: rows, note: note + left,
				callOff: stake > 0 ? "Call off (stakes back)" : "Call off"};
		case "racing":
			return {title: title, rows: [held], note: "This run decides the stakes"};
		case "calledOff":
			return {title: "Drag race called off", note: upperFirst(data.why) + ".", close: true,
				rows: stake > 0 ? [{label: "Stake", value: moDollars(stake) + " back to you"}] : []};
		case "result":
			return dragResultView(data);
		}
		return null;
	}

	// A staked race's cards go to $scope.drag; a plain run's result has a card of its own
	// ($scope.dragRun), so it never hides the held stakes and their Call off.
	$scope.dragRun = null;

	$scope.$on('MileageDragRace', function (event, data) {
		if (!data) return;
		$scope.$evalAsync(function () {
			var shown = dragView(data);
			if (typeof data.race !== "string") {
				$scope.dragRun = shown ? {phase: data.phase, view: shown} : null;
				return;
			}
			$scope.drag = shown ? {id: data.race, phase: data.phase, view: shown} : null;
		});
	});

	$scope.closeDragRun = function () {
		$scope.dragRun = null;
	};

	$scope.callOffDrag = function () {
		bngApi.engineLua('if mileage_dragMoney then mileage_dragMoney.callOff() end');
	};

	$scope.closeDrag = function () {
		$scope.drag = null;
	};

	//== racing the traffic car beside you =========================================
	// mileage/aiRace.lua sends MileageAiRace: "available" while a traffic car drives beside
	// the player ("none" when none is, "racing" once the race panel takes over), "invite"
	// for a race started near them, "inviteClosed", and the "result". The opponent is named
	// by its model; the money is the race reward.

	$scope.traffic = null;

	// The card beside your own traffic car: the car, the finish range and the reward on one
	// line, one short note, and the key (or where to set one) beside the title.
	function availableView(data) {
		var car = String(data.car || "");
		var view = {title: "Race this car", line: car, race: true, raceOff: true};
		if (data.own !== true) {
			var owner = String(data.owner || "another player");
			view.note = "Only " + owner + "'s game can race it; find your own traffic";
			return view;
		}
		if (data.allowed !== true) {
			view.note = "Racing traffic is off on this server.";
			return view;
		}
		view.raceOff = false;
		if (data.note) {
			view.note = String(data.note);
			return view;
		}
		var prize = Number(data.prize) || 0;
		var again = Number(data.prizeAgainIn) || 0;
		if (prize <= 0) {
			view.line = car + " · 1.5–4 km · no reward";
			view.note = "A win counts on the leaderboard · 300 m invite";
		} else if (again > 0) {
			view.line = car + " · 1.5–4 km · reward in " + Math.ceil(again / 60) + " min";
			view.note = "A win still counts on the leaderboard · 300 m invite";
		} else {
			view.line = car + " · 1.5–4 km · " + moDollars(prize);
			view.note = "+50% per player who joins · 300 m invite";
		}
		if (data.key) view.key = String(data.key);
		else view.keyHint = "Key: Options › Controls";
		return view;
	}

	function inviteView(data) {
		var car = String(data.car || "");
		var prize = Number(data.prize) || 0;
		return {
			title: String(data.host || "") + " started a race near you",
			line: "vs " + car + " · " + moKm(data.distance) + (prize > 0 ? " · " + moDollars(prize) : ""),
			note: data.note ? String(data.note) :
				(prize > 0 ? "First player to beat it wins · rolling start" : "Rolling start from where you are"),
			join: true,
		};
	}

	// Why the server withheld a traffic race reward: the car did not race like a racing car.
	var WITHHELD = {slow: "Not paid: the car was too slow to count", jumped: "Not paid: the car jumped too far"};
	var STILL_COUNTS = "The win counts on the leaderboard.";
	var BACK_IN_TRAFFIC = "No winner, no reward · the car is back in traffic";

	function trafficResultView(data) {
		var you = String(data.you || ""), car = String(data.car || "");
		var prize = Number(data.prize) || 0;
		var nameOf = function (p) { return p.car ? car : (p.name === you ? "You" : String(p.name)); };
		var places = (Array.isArray(data.places) ? data.places : []).map(function (p, i) {
			return {place: i + 1, name: nameOf(p), value: moTime(p.seconds)};
		});
		(Array.isArray(data.notFinished) ? data.notFinished : []).forEach(function (p) {
			if (!p || typeof p !== "object") return;
			places.push({place: "-", name: nameOf(p),
				value: !p.car ? "did not finish" : (p.out ? "out: crashed or stuck" : "still on its way")});
		});
		if (data.out) {
			return {title: "You left the race", rows: [{label: "Your time", value: "did not finish: you gave up"}],
				note: "The others race on; no reward for you this time.", close: true};
		}
		var hostEnded = data.why === "hostGaveUp" || data.why === "hostLeft" || data.why === "failed";
		if (hostEnded) {
			if (data.host === you) {
				return {title: "Race over", rows: [{label: "Your time", value: "did not finish: you gave up"}], close: true,
					note: BACK_IN_TRAFFIC};
			}
			return {title: "Race over", close: true,
				note: String(data.host || "") + (data.why === "hostLeft" ? " left" : " gave up") + ": no winner, no reward"};
		}
		if (data.why === "aiOut") {
			return {title: "Race over", rows: [{label: car, value: "out: crashed or stuck for 15 s"}], close: true,
				note: BACK_IN_TRAFFIC};
		}
		if (data.aiWon) {
			return {title: "The " + car + " won", places: places, close: true, note: "Nobody beat it, so no reward this time."};
		}
		if (!data.winner) {
			return {title: "Race over", places: places.length > 0 ? places : null, close: true,
				note: "Nobody reached the finish in time."};
		}
		if (data.winner === you) {
			// The reward paid goes in the title; one not paid says why in a row.
			if (prize > 0) return {title: "You won · " + moDollars(prize), places: places, rows: [], close: true};
			var rows = [];
			if ((Number(data.reward) || 0) > 0 && Object.prototype.hasOwnProperty.call(WITHHELD, data.rewardWithheld)) {
				rows.push({label: "Race reward", value: WITHHELD[data.rewardWithheld]});
			} else if ((Number(data.reward) || 0) > 0 && (Number(data.prizeAgainIn) || 0) > 0) {
				rows.push({label: "Race reward", value: "Again in " + Math.ceil(Number(data.prizeAgainIn) / 60) + " min"});
			} else if ((Number(data.reward) || 0) > 0) {
				rows.push({label: "Race reward", value: "Not paid for this race"});
			}
			return {title: "You won", places: places, rows: rows, note: rows.length > 0 ? STILL_COUNTS : undefined,
				close: true};
		}
		return {title: String(data.winner) + " won", places: places, close: true};
	}

	$scope.$on('MileageAiRace', function (event, data) {
		if (!data) return;
		$scope.$evalAsync(function () {
			var kind = $scope.traffic ? $scope.traffic.kind : null;
			switch (data.phase) {
			case "available":
				// An invite or a result stays until it is answered or closed.
				if (kind === "invite" || kind === "result") return;
				$scope.traffic = {kind: "available", view: availableView(data)};
				return;
			case "none":
				if (kind === "available") $scope.traffic = null;
				return;
			case "racing":
				// A joined invite goes too once its race counts down; a result stays until closed.
				if (kind === "available" || kind === "invite") $scope.traffic = null;
				return;
			case "invite":
				if (typeof data.race !== "string") return;
				$scope.traffic = {kind: "invite", id: data.race, seconds: Number(data.seconds) || 5,
					shownAt: Date.now(), view: inviteView(data)};
				return;
			case "inviteClosed":
				if (kind === "invite" && $scope.traffic.id === data.race) $scope.traffic = null;
				return;
			case "result":
				$scope.traffic = {kind: "result", id: data.race, view: trafficResultView(data)};
				return;
			}
		});
	});

	$scope.raceTraffic = function () {
		bngApi.engineLua('if mileage_aiRace then mileage_aiRace.press() end');
	};

	$scope.joinTraffic = function () {
		if (!$scope.traffic || $scope.traffic.kind !== "invite") return;
		bngApi.engineLua('if mileage_aiRace then mileage_aiRace.join(' + moLuaString($scope.traffic.id) + ') end');
	};

	$scope.declineTraffic = function () {
		$scope.traffic = null;
		bngApi.engineLua('if mileage_aiRace then mileage_aiRace.decline() end');
	};

	// The card for a car still beside the player comes back.
	$scope.closeTraffic = function () {
		$scope.traffic = null;
		bngApi.engineLua('if mileage_aiRace then mileage_aiRace.sendState() end');
	};

	//== races at race spots =====================================================
	// mileage/spotRace.lua sends MileageSpotRace: "setup" (the card at a spot's start line),
	// "inviting" (the starter's answers so far), "invite" (to an invited player), "grid",
	// "countdown", "go", "racing", "finished", "out", "result", "closed", "inviteClosed" and
	// "clear". Opponents are named by their car model; every card carries "you".

	$scope.spot = null;

	// Why a racer has no time.
	var SPOT_OUT = {gaveUp: "Gave up", left: "Left the route", stuck: "Stuck", gone: "Crashed out",
		quit: "Left the server", notReady: "Not ready", spawn: "Did not start"};
	// Why the first place was not paid, when the server has a prize.
	var SPOT_WITHHELD = {
		alone: "No prize: nobody else raced; your time still counts",
		"car won": "No prize: only a player who finishes first is paid.",
		unseen: "Unranked: not every car was seen; no prize, win or time",
	};

	function spotRouteText(route) {
		var laps = Number(route.laps) || 1;
		return (route.closed ? "Circuit" : "Point to point") + ", " + laps + " lap" + (laps === 1 ? "" : "s") + ", " +
			moKm(route.length);
	}

	function spotTime(seconds) {
		return moClock(seconds, 2);
	}

	// The owner's prize is for a race of two; each racer past two adds half of it again, as
	// the server pays it. racers: the grid as set, every friend picked counted as joining.
	function spotPrizeRow(data, racers) {
		var prize = Number(data.prize) || 0, again = Number(data.againIn) || 0;
		if (prize <= 0) return {label: "Prize", value: "None on this server"};
		if (again > 0) return {label: "Prize for first place", value: "Again in " + Math.ceil(again / 60) + " min"};
		if (racers < 2) return {label: "Prize for first place", value: moDollars(prize) + " with a rival"};
		return {label: "Prize for first place",
			value: moDollars(Math.floor(prize * (1 + 0.5 * (racers - 2)))) + " for " + racers + " racers"};
	}

	function setupView(s) {
		var route = s.routes[s.routeIndex] || {};
		var rows = [{label: "Route", value: spotRouteText(route)}];
		rows.push({label: "Best time here", value: typeof route.best === "number" ?
			spotTime(route.best) + " by " + String(route.bestBy || "") : "No times yet"});
		if (typeof route.mine === "number") rows.push({label: "Your best", value: spotTime(route.mine)});
		var invited = s.players.filter(function (p) { return p.on; }).length;
		rows.push(spotPrizeRow(s, 1 + s.opponents + invited));
		var solo = s.opponents === 0 && invited === 0;
		var note = s.note ? String(s.note) : (solo ? "Solo run: a leaderboard time, no prize" :
			"Friends who join are moved onto the grid beside you.");
		var warn = !s.note && s.untested ? "Untested car: rivals may not match it until it is tested" : undefined;
		if (s.allowed === false) {
			note = "Race spots are off on this server.";
			warn = undefined;
		}
		return {
			warn: warn,
			title: "Race spot: " + String(s.spotName || ""),
			layouts: s.routes.length > 1 ? s.routes.map(function (r, i) {
				return {name: String(r.name || ""), on: i === s.routeIndex, index: i};
			}) : null,
			rows: rows,
			stepper: {value: s.opponents, max: s.opponentsMax},
			players: s.players,
			note: note,
			start: solo ? "Start run" : "Start race",
			startOff: s.pending === true || s.allowed === false,
			cancel: true,
		};
	}

	function spotPlaces(data) {
		var you = String(data.you || "");
		return (Array.isArray(data.places) ? data.places : []).map(function (p, i) {
			var time = typeof p.seconds === "number";
			return {
				place: time ? i + 1 : "-",
				name: !p.car && p.name === you ? "You" : String(p.name || ""),
				value: time ? spotTime(p.seconds) : (SPOT_OUT[p.out] || "Did not finish"),
				me: !p.car && p.name === you,
			};
		});
	}

	function spotResultView(data) {
		var you = String(data.you || ""), routeName = String(data.routeName || "");
		var title;
		if (data.winner === you) title = "You won " + routeName;
		else if (data.winner) title = String(data.winner) + " won " + routeName;
		else if (data.carWon && Array.isArray(data.places) && data.places[0]) title = String(data.places[0].name) + " won " + routeName;
		else title = routeName + ": no winner";
		var rows = [], notes = [];
		var paid = Number(data.prize) || 0;
		if (paid > 0 && data.winner === you) rows.push({label: "Prize", value: moDollars(paid)});
		if (data.withheld === "unseen") {
			notes.push(SPOT_WITHHELD.unseen);
		} else if ((Number(data.prizeOffered) || 0) > 0 && data.withheld) {
			if (data.withheld === "wait") {
				notes.push("No prize: you can win it again in " + Math.ceil((Number(data.againIn) || 0) / 60) + " min.");
			} else if (data.withheld === "car won" || data.winner === you) {
				notes.push(SPOT_WITHHELD[data.withheld] || "No prize this time.");
			}
		}
		if (data.best && typeof data.best === "object" && data.best.improved) {
			notes.push(typeof data.best.old === "number" ? "New personal best; your best here was " + spotTime(data.best.old) + "." :
				"Your first time here is on the leaderboard.");
		}
		if (data.why === "starterLeft") notes.push("The starter left, so the race ended with no winner.");
		else if (data.why === "timeout") notes.push("The time ran out.");
		// One line each.
		return {title: title, places: spotPlaces(data), rows: rows, notes: notes, close: true};
	}

	function spotView(data, current) {
		var routeName = String(data.routeName || "");
		switch (data.phase) {
		case "inviting":
			var answers = Array.isArray(data.answers) ? data.answers : [];
			var opponents = Number(data.opponents) || 0;
			var rows = answers.map(function (a) {
				return {label: String(a.name || ""), value: a.answer === "joined" ? "Joined" :
					(a.answer === "declined" ? "Declined" : "Waiting…")};
			});
			rows.push({label: "Opponents", value: opponents + " car" + (opponents === 1 ? "" : "s") + " on the grid"});
			return {title: "Race spot: " + routeName, rows: rows,
				note: "Starts when everyone has answered, or in " + Math.ceil(Number(data.seconds) || 0) + " s.",
				startNow: true, callOff: true};
		case "invite":
			var route = data.route && typeof data.route === "object" ? data.route : {};
			var n = Number(data.opponents) || 0, prize = Number(data.prize) || 0;
			var inviteRows = [{label: "Race spot", value: String(route.name || "")}, {label: "Route", value: spotRouteText(route)},
				{label: "Opponents", value: n + " car" + (n === 1 ? "" : "s") + ", plus " + String(data.from || "")}];
			if (prize > 0) inviteRows.push({label: "Prize for first place", value: moDollars(prize)});
			return {title: String(data.from || "") + " invites you to a race", rows: inviteRows,
				note: data.note ? String(data.note) : "Joining moves your car to the start grid.", join: true};
		case "grid":
			return {title: routeName, note: "Lining up on the grid..."};
		case "countdown":
			var you = String(data.you || "");
			var names = (Array.isArray(data.racers) ? data.racers : []).filter(function (r) { return !r.car; })
				.map(function (r) { return r.name === you ? "You" : String(r.name); });
			var cars = (Array.isArray(data.racers) ? data.racers : []).filter(function (r) { return r.car; }).length;
			if (cars > 0) names.push(cars + " car" + (cars === 1 ? "" : "s"));
			var countdownRows = [{label: "Grid", value: names.join(", ")}];
			// The prize for first place with everyone on the grid, as the server pays it.
			var gridPrize = Number(data.prize) || 0;
			if (gridPrize > 0) {
				var gridSize = Array.isArray(data.racers) ? data.racers.length : 0;
				countdownRows.push({label: "Prize for first place", value: moDollars(gridPrize) + " for " + gridSize + " racers"});
			}
			return {title: routeName, big: String(data.count), rows: countdownRows};
		case "go":
			return {title: routeName, big: "GO", giveUp: true};
		case "racing":
			var racingRows = [];
			if (typeof data.place === "number") racingRows.push({label: "Place", value: data.place + " / " + data.of});
			racingRows.push({label: "Lap", value: data.lap + " / " + data.laps});
			racingRows.push({label: "Checkpoint", value: data.checkpoint + " / " + data.checkpoints});
			racingRows.push({label: "Time", value: moTime(data.elapsed)});
			if (data.ahead) {
				racingRows.push({label: "Ahead", value: String(data.ahead) +
					(typeof data.gap === "number" ? ", " + data.gap.toFixed(1) + " s" : "")});
			}
			var view = {title: routeName, rows: racingRows, giveUp: true};
			if (typeof data.offRoute === "number") {
				view.warn = "Off the route: back to checkpoint " + data.checkpoint + " within " + data.offRoute + " s";
				if (typeof data.nextMetres === "number") {
					racingRows.push({label: "Next checkpoint", value: moKm(data.nextMetres) + " away"});
				}
			}
			return view;
		case "finished":
			return {title: "Finished in " + moTime(data.elapsed), note: "Waiting for the other racers..."};
		case "out":
			return {title: "Your race is over", note: (data.why === "left" ? "You left the route." : "You gave up.") +
				" The others race on.", close: true};
		case "result":
			return spotResultView(data);
		case "closed":
			return {title: current && current.kind === "invite" ? "Invite over" : "Race called off",
				note: String(data.why || ""), close: true};
		}
		return null;
	}

	function showSetup(data) {
		var before = $scope.spot && $scope.spot.kind === "setup" && $scope.spot.setup.spot === data.spot ? $scope.spot.setup : null;
		var routes = Array.isArray(data.routes) ? data.routes : [];
		var max = Math.max(0, Number(data.opponentsMax) || 0);
		var picks = {};
		if (before) before.players.forEach(function (p) { picks[p.name] = p.on; });
		var s = {
			spot: data.spot, spotName: data.spotName, routes: routes, allowed: data.allowed,
			routeIndex: before ? Math.min(before.routeIndex, Math.max(0, routes.length - 1)) : 0,
			opponents: before ? Math.min(before.opponents, max) : Math.min(3, max), opponentsMax: max,
			prize: data.prize, againIn: data.againIn, note: data.note, pending: data.pending, untested: data.untested === true,
			players: (Array.isArray(data.players) ? data.players : []).map(function (p) {
				var name = String(p.name || "");
				return {name: name, busy: p.busy === true, on: p.busy !== true && picks[name] === true};
			}),
		};
		$scope.spot = {kind: "setup", setup: s, view: setupView(s)};
	}

	$scope.$on('MileageSpotRace', function (event, data) {
		if (!data) return;
		$scope.$evalAsync(function () {
			var current = $scope.spot;
			switch (data.phase) {
			case "setup":
				showSetup(data);
				return;
			case "clear":
				$scope.spot = null;
				return;
			case "inviteClosed":
				if (current && current.kind === "invite" && current.id === data.id) $scope.spot = null;
				return;
			}
			if (moRaceWindowShows(data.phase)) {
				$scope.spot = null;
				return;
			}
			var shown = spotView(data, current);
			if (!shown) return;
			var kind = data.phase === "invite" ? "invite" : data.phase;
			var spot = {kind: kind, id: data.id, view: shown};
			if (kind === "invite") {
				// A new card for the same invite (a note after Join) keeps its time bar.
				var again = current && current.kind === "invite" && current.id === data.id;
				spot.seconds = again ? current.seconds : (Number(data.seconds) || 30);
				spot.shownAt = again ? current.shownAt : Date.now();
			}
			$scope.spot = spot;
		});
	});

	function refreshSetup() {
		if ($scope.spot && $scope.spot.kind === "setup") $scope.spot.view = setupView($scope.spot.setup);
	}

	$scope.spotLayout = function (index) {
		if (!$scope.spot || $scope.spot.kind !== "setup") return;
		$scope.spot.setup.routeIndex = index;
		refreshSetup();
	};

	$scope.spotOpponents = function (step) {
		if (!$scope.spot || $scope.spot.kind !== "setup") return;
		var s = $scope.spot.setup;
		s.opponents = Math.max(0, Math.min(s.opponentsMax, s.opponents + step));
		refreshSetup();
	};

	$scope.spotPick = function (player) {
		if (!$scope.spot || $scope.spot.kind !== "setup" || player.busy) return;
		player.on = !player.on;
		refreshSetup();
	};

	$scope.spotStart = function () {
		if (!$scope.spot || $scope.spot.kind !== "setup" || $scope.spot.view.startOff) return;
		var s = $scope.spot.setup;
		var route = s.routes[s.routeIndex];
		if (!route) return;
		var names = s.players.filter(function (p) { return p.on; }).map(function (p) { return p.name; });
		s.pending = true;
		refreshSetup();
		bngApi.engineLua('if mileage_spotRace then mileage_spotRace.request(' + moLuaString(route.id) + ', ' + s.opponents +
			', ' + moLuaString(JSON.stringify(names)) + ') end');
	};

	$scope.spotCancel = function () {
		$scope.spot = null;
		bngApi.engineLua('if mileage_spotRace then mileage_spotRace.closeSetup() end');
	};

	$scope.spotJoin = function () {
		if (!$scope.spot || $scope.spot.kind !== "invite") return;
		bngApi.engineLua('if mileage_spotRace then mileage_spotRace.join(' + moLuaString($scope.spot.id) + ') end');
	};

	$scope.spotDecline = function () {
		if (!$scope.spot || $scope.spot.kind !== "invite") return;
		var id = $scope.spot.id;
		$scope.spot = null;
		bngApi.engineLua('if mileage_spotRace then mileage_spotRace.decline(' + moLuaString(id) + ') end');
	};

	$scope.spotStartNow = function () {
		bngApi.engineLua('if mileage_spotRace then mileage_spotRace.startNow() end');
	};

	$scope.spotCallOff = function () {
		bngApi.engineLua('if mileage_spotRace then mileage_spotRace.callOff() end');
	};

	$scope.spotGiveUp = function () {
		bngApi.engineLua('if mileage_spotRace then mileage_spotRace.giveUp() end');
	};

	$scope.spotClose = function () {
		$scope.spot = null;
	};

	//== the server leaderboard =================================================

	$scope.leaderboard = null;

	$scope.$on('MileageLeaderboard', function (event, data) {
		if (!data) return;
		$scope.$evalAsync(function () {
			var wins = (Array.isArray(data.wins) ? data.wins : []).map(function (entry, i) {
				return {place: i + 1, name: String(entry.name), value: String(Number(entry.wins) || 0)};
			});
			var strips = Object.keys(data.drag || {}).sort().map(function (stripId) {
				var runs = Array.isArray(data.drag[stripId]) ? data.drag[stripId] : [];
				return {
					name: String(stripId),
					rows: runs.map(function (run, i) {
						return {place: i + 1, name: String(run.name), value: (Number(run.et) || 0).toFixed(2) + " s",
							extra: Math.round((Number(run.trap) || 0) * 3.6) + " km/h"};
					}),
				};
			});
			var spots = Object.keys(data.spots || {}).map(function (routeId) {
				var spot = data.spots[routeId] || {};
				var rows = Array.isArray(spot.rows) ? spot.rows : [];
				return {
					name: String(spot.name || routeId),
					rows: rows.map(function (row, i) {
						return {place: i + 1, name: String(row.name), value: spotTime(row.time)};
					}),
				};
			}).sort(function (a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0); });
			$scope.leaderboard = {tab: $scope.leaderboard ? $scope.leaderboard.tab : "wins", wins: wins, strips: strips,
				spots: spots};
		});
	});

	$scope.showTab = function (tab) {
		if ($scope.leaderboard) $scope.leaderboard.tab = tab;
	};

	$scope.closeLeaderboard = function () {
		$scope.leaderboard = null;
	};

	//== a race event the owner runs ============================================

	$scope.event = null;

	function ordinal(n) {
		var s = ["th", "st", "nd", "rd"], v = n % 100;
		return n + (s[(v - 20) % 10] || s[v] || s[0]);
	}

	function eventView(data) {
		var route = String(data.route || "");
		switch (data.phase) {
		case "announce":
		case "joined":
		case "left":
			var minutes = Math.max(1, Math.ceil((Number(data.seconds) || 0) / 60));
			var prizeText = data.grows === true ? " for two racers, +50% per extra racer" : " to the winner";
			var rows = [{label: "Route", value: route}, {label: "Prize", value: moDollars(data.prize) + prizeText},
				{label: "Joined", value: (Number(data.joined) || 0) + " player" + (data.joined === 1 ? "" : "s")}];
			return {
				title: "Race event in " + minutes + " minute" + (minutes === 1 ? "" : "s"),
				rows: rows,
				note: data.random ? "The finish is picked when it starts." : "",
				joined: data.youJoined === true,
			};
		case "result":
			var places = Array.isArray(data.places) ? data.places : [];
			var racers = Number(data.racers) || places.length;
			var mine = null;
			places.forEach(function (p, i) { if (p.name === data.you) mine = {place: i + 1, seconds: p.seconds}; });
			if (!data.winner) {
				return {title: "Race event over", rows: [{label: "Route", value: route}],
					note: "Nobody reached the finish in time.", close: true};
			}
			if (data.winner === data.you) {
				return {title: "You won the race event", close: true, rows: [
					{label: "Route", value: route},
					{label: "Your time", value: moTime(mine && mine.seconds) + ", 1st of " + racers},
					{label: "Prize", value: moDollars(data.prize) + " paid to you"}]};
			}
			var winnerTime = places.length > 0 ? ", " + moTime(places[0].seconds) : "";
			return {title: "Race event over", close: true, rows: [
				{label: "Winner", value: String(data.winner) + winnerTime},
				{label: "You", value: mine ? ordinal(mine.place) + " of " + racers + ", " + moTime(mine.seconds)
					: "did not finish"}]};
		case "over":
			return {title: "Race event over", note: String(data.why || ""), close: true};
		case "refused":
			return {title: "Could not join the race event", note: String(data.why || ""), close: true};
		case "cancelled":
			return {title: "Race event cancelled", close: true};
		}
		return null;
	}

	$scope.$on('MileageEvent', function (event, data) {
		if (!data) return;
		$scope.$evalAsync(function () {
			var shown = eventView(data);
			$scope.event = shown ? {id: data.id, phase: data.phase, view: shown} : null;
		});
	});

	$scope.joinEvent = function () {
		if (!$scope.event) return;
		bngApi.engineLua('if mileage_raceEvents then mileage_raceEvents.join(' + moLuaString($scope.event.id) + ') end');
	};

	$scope.leaveEvent = function () {
		if (!$scope.event) return;
		bngApi.engineLua('if mileage_raceEvents then mileage_raceEvents.leave(' + moLuaString($scope.event.id) + ') end');
	};

	$scope.closeEvent = function () {
		$scope.event = null;
	};

	// Redraws the time bars.
	var ticker = setInterval(function () {
		if ($scope.offers.length > 0 || ($scope.traffic && $scope.traffic.kind === "invite") ||
				($scope.spot && $scope.spot.kind === "invite")) {
			$scope.$evalAsync(function () {});
		}
	}, 500);
	$scope.$on('$destroy', function () { clearInterval(ticker); });

	bngApi.engineLua('if mileage_offers then mileage_offers.sendState() end');
	bngApi.engineLua('if mileage_streetRace then mileage_streetRace.sendState() end');
	bngApi.engineLua('if mileage_dragMoney then mileage_dragMoney.sendState() end');
	bngApi.engineLua('if mileage_raceEvents then mileage_raceEvents.sendState() end');
	bngApi.engineLua('if mileage_aiRace then mileage_aiRace.sendState() end');
	bngApi.engineLua('if mileage_spotRace then mileage_spotRace.sendState() end');
}]);

// Whether the race window (Mileage-Race) is on the page and shows this phase of a race:
// the countdown, GO, the race and the wait after a finish. The prompts app then leaves
// them to it.
function moRaceWindowShows(phase) {
	var open = typeof mileageRaceWindowsOpen === "number" && mileageRaceWindowsOpen > 0;
	return open && (phase === "countdown" || phase === "go" || phase === "racing" || phase === "finished");
}

// Seconds as m:ss.s.
function moTime(seconds) {
	return moClock(seconds, 1);
}

// Seconds as m:ss with this many decimals, rounded before the minutes are split off so
// 59.996 s reads 1:00.00, never 0:60.00.
function moClock(seconds, decimals) {
	var s = Number(seconds);
	if (!isFinite(s) || s < 0) return "-";
	var scale = Math.pow(10, decimals);
	var units = Math.round(s * scale);
	var minutes = Math.floor(units / (60 * scale));
	var rest = (units - minutes * 60 * scale) / scale;
	return minutes + ":" + (rest < 10 ? "0" : "") + rest.toFixed(decimals);
}

function moDollars(n) {
	return "$" + Number(n || 0).toLocaleString("en-US");
}

// "$4,000 + $500 server prize": the stakes the winner takes and the prize, or "" for neither.
function moWinnerGets(pot, prize, prizeWord) {
	var text = pot > 0 ? moDollars(pot) : "";
	if (prize > 0) text = (text ? text + " + " : "") + moDollars(prize) + prizeWord;
	return text;
}

function moKm(metres) {
	var m = Number(metres);
	if (!isFinite(m)) return "?";
	return (m / 1000).toFixed(1) + " km";
}

// Text from the UI reaches Lua base64-encoded (as UTF-8) and decoded there, so nothing
// in it can end the string and become code.
function moLuaString(text) {
	var bytes = new TextEncoder().encode(String(text));
	var binary = "";
	for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
	return "require('mime').unb64('" + btoa(binary) + "')";
}
