// Mileage prompts: race challenges and money requests to this player, the race
// countdown, race panel and result, race events and the server leaderboard. Fed by the
// game's Mileage extensions through guihooks (mileage/offers.lua and the race, event and
// leaderboard extensions); every answer goes back through bngApi.engineLua with ids and
// names base64-encoded. Every text from the server or another player is bound as text.
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
				note: "Accepting moves your car next to " + from + "'s." +
					(stake > 0 ? " Leaving mid-race loses your stake." : ""),
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
		var rewardText = reward > 0 ? " · race reward " + moDollars(reward) : "";
		switch (data.phase) {
		case "countdown":
			return {big: String(data.count), note: "Rolling start · keep driving · vs " + other + rewardText};
		case "go":
			return {big: "GO", note: "vs " + other + rewardText};
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
			return {title: "Race called off", note: String(data.why || "") +
				(stake > 0 ? ". Your " + moDollars(stake) + " stake is back." : "."), close: true};
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
			return {title: "No winner", rows: rows, close: true,
				note: (data.why === "timeout" ? "Nobody reached the finish in time." : "The race ended without a winner.") +
					(stake > 0 ? " Your " + moDollars(stake) + " stake is back." : "")};
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

	//== racing the traffic car beside you =========================================
	// mileage/aiRace.lua sends MileageAiRace: "available" while a traffic car drives beside
	// the player ("none" when none is, "racing" once the race panel takes over), "invite"
	// for a race started near them, "inviteClosed", and the "result". The opponent is named
	// by its model; the money is the race reward.

	$scope.traffic = null;

	function rewardRow(data) {
		var prize = Number(data.prize) || 0;
		var again = Number(data.prizeAgainIn) || 0;
		if (prize <= 0) return {label: "Race reward", value: "None on this server; a win counts on the leaderboard"};
		if (again > 0) {
			return {label: "Race reward", value: "Again in " + Math.ceil(again / 60) +
				" min; a win still counts on the leaderboard"};
		}
		return {label: "Race reward", value: moDollars(prize) + ", +50% for each player who joins"};
	}

	function availableView(data) {
		var car = String(data.car || "");
		var view = {title: "Race this car", rows: [{label: "Car", value: car}], race: true, raceOff: true};
		if (data.own !== true) {
			var owner = String(data.owner || "another player");
			view.note = "This is " + owner + "'s traffic, so only " + owner + "'s game can race it. " +
				"Pull alongside one of your own traffic cars.";
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
		view.rows.push({label: "Finish", value: "Random, 1.5 to 4 km"});
		view.rows.push(rewardRow(data));
		view.note = "Players within 300 m are invited." +
			(data.key ? "" : " You can also set a key for this in Options › Controls.");
		if (data.key) view.key = String(data.key);
		return view;
	}

	function inviteView(data) {
		var car = String(data.car || "");
		var prize = Number(data.prize) || 0;
		var rows = [{label: "Against", value: car}, {label: "Finish", value: moKm(data.distance) + " from you"}];
		if (prize > 0) {
			rows.push({label: "Race reward", value: moDollars(prize) + " if you join, to the first player to beat the " + car});
		}
		return {
			title: String(data.host || "") + " started a race near you",
			rows: rows,
			note: data.note ? String(data.note) : "Join to race from where you are, rolling, from the same start.",
			join: true,
		};
	}

	// Why the server withheld a traffic race reward: the car did not race like a racing car.
	var WITHHELD = {slow: "was too slow to count as racing", jumped: "jumped farther than a car can drive"};

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
				note: "The others race on. No race reward for you this time.", close: true};
		}
		var hostEnded = data.why === "hostGaveUp" || data.why === "hostLeft" || data.why === "failed";
		if (hostEnded) {
			if (data.host === you) {
				return {title: "Race over", rows: [{label: "Your time", value: "did not finish: you gave up"}], close: true,
					note: "Your race ended for everyone, with no winner and no race reward. The " + car + " is back in traffic."};
			}
			return {title: "Race over", close: true,
				note: String(data.host || "") + (data.why === "hostLeft" ? " left" : " gave up") +
					", so the race ended with no winner and no race reward."};
		}
		if (data.why === "aiOut") {
			return {title: "Race over", rows: [{label: car, value: "out: crashed or stuck for 15 s"}], close: true,
				note: "The " + car + " dropped out before anyone finished, so the race ended with no winner and no " +
					"race reward. The car is back in traffic."};
		}
		if (data.aiWon) {
			return {title: "The " + car + " won", places: places, close: true,
				note: "Nobody beat the " + car + ", so no race reward this time."};
		}
		if (!data.winner) {
			return {title: "Race over", places: places.length > 0 ? places : null, close: true,
				note: "Nobody reached the finish in time."};
		}
		if (data.winner === you) {
			var rows = [];
			if (prize > 0) {
				rows.push({label: "You get", value: moDollars(prize) + " race reward"});
			} else if ((Number(data.reward) || 0) > 0 && Object.prototype.hasOwnProperty.call(WITHHELD, data.rewardWithheld)) {
				rows.push({label: "Race reward", value: "Not paid: the " + car + " " + WITHHELD[data.rewardWithheld] +
					"; the win counts on the leaderboard"});
			} else if ((Number(data.reward) || 0) > 0 && (Number(data.prizeAgainIn) || 0) > 0) {
				rows.push({label: "Race reward", value: "Again in " + Math.ceil(Number(data.prizeAgainIn) / 60) +
					" min; the win counts on the leaderboard"});
			} else if ((Number(data.reward) || 0) > 0) {
				rows.push({label: "Race reward", value: "Not paid for this race; the win counts on the leaderboard"});
			}
			return {title: "You won", places: places, rows: rows, close: true};
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
			case "racing":
				if (kind === "available") $scope.traffic = null;
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
			$scope.leaderboard = {tab: $scope.leaderboard ? $scope.leaderboard.tab : "wins", wins: wins, strips: strips};
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
			var rows = [{label: "Route", value: route}, {label: "Prize", value: moDollars(data.prize) + " to the winner"},
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
		if ($scope.offers.length > 0 || ($scope.traffic && $scope.traffic.kind === "invite")) {
			$scope.$evalAsync(function () {});
		}
	}, 500);
	$scope.$on('$destroy', function () { clearInterval(ticker); });

	bngApi.engineLua('if mileage_offers then mileage_offers.sendState() end');
	bngApi.engineLua('if mileage_streetRace then mileage_streetRace.sendState() end');
	bngApi.engineLua('if mileage_raceEvents then mileage_raceEvents.sendState() end');
	bngApi.engineLua('if mileage_aiRace then mileage_aiRace.sendState() end');
}]);

// Seconds as m:ss.s.
function moTime(seconds) {
	var s = Number(seconds);
	if (!isFinite(s) || s < 0) return "-";
	var minutes = Math.floor(s / 60);
	var rest = s - minutes * 60;
	return minutes + ":" + (rest < 10 ? "0" : "") + rest.toFixed(1);
}

function moDollars(n) {
	return "$" + Number(n || 0).toLocaleString("en-US");
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
