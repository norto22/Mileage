// Mileage race window: the live race in a small strip at the top right, below the top bar,
// so the prompts window does not cover the road while racing. It shows the countdown, GO,
// the race and the wait after a finish for race spots (guihook MileageSpotRace, from
// mileage/spotRace.lua), street races and races against traffic cars (MileageRace, from
// mileage/streetRace.lua). Set-up, invites, the grid and results stay in the prompts app,
// which leaves these phases to this window while it is on the page. Every text from the
// server or another player is bound as text.
//
// NOTE: top-level declarations must be `var` or function declarations: the game's UI
// app service evaluates app.js again in the same scope when it refreshes apps.

// How many race windows are on the page; the prompts app reads it.
var mileageRaceWindowsOpen = typeof mileageRaceWindowsOpen === "number" ? mileageRaceWindowsOpen : 0;

var mileageRaceApp = angular.module('beamng.apps');
mileageRaceApp.directive('mileagerace', [function () {
	return {
		templateUrl: '/ui/modules/apps/Mileage-Race/app.html',
		replace: true,
		restrict: 'EA',
		scope: true
	};
}]);

mileageRaceApp.controller('MileageRace', ['$scope', function ($scope) {
	// The race shown: {kind: "spot" | "street", view}, or null.
	$scope.live = null;
	mileageRaceWindowsOpen = mileageRaceWindowsOpen + 1;
	$scope.$on('$destroy', function () { mileageRaceWindowsOpen = Math.max(0, mileageRaceWindowsOpen - 1); });

	function spotView(data) {
		var routeName = String(data.routeName || "");
		switch (data.phase) {
		case "countdown":
			var you = String(data.you || "");
			var racers = Array.isArray(data.racers) ? data.racers : [];
			var names = racers.filter(function (r) { return r && !r.car; })
				.map(function (r) { return r.name === you ? "You" : String(r.name); });
			var cars = racers.filter(function (r) { return r && r.car; }).length;
			if (cars > 0) names.push(cars + " car" + (cars === 1 ? "" : "s"));
			var gridLine = names.length > 0 ? [names.join(", ")] : [];
			// The prize for first place with everyone on the grid, as the server pays it.
			var gridPrize = Number(data.prize) || 0;
			if (gridPrize > 0) gridLine.push("prize " + mrDollars(gridPrize) + " for " + racers.length + " racers");
			return {big: String(data.count), label: routeName, line: gridLine, countdown: true};
		case "go":
			return {big: "GO", label: routeName, line: [], countdown: true, giveUp: "Give up"};
		case "racing":
			var line = ["Lap " + data.lap + "/" + data.laps, "CP " + data.checkpoint + "/" + data.checkpoints];
			var warn = null;
			if (typeof data.offRoute === "number") {
				warn = "Back to checkpoint " + data.checkpoint + " within " + data.offRoute + " s";
				if (typeof data.nextMetres === "number") line.push(mrKm(data.nextMetres) + " away");
			} else if (data.ahead) {
				line.push("Ahead: " + String(data.ahead) + (typeof data.gap === "number" ? " +" + data.gap.toFixed(1) + " s" : ""));
			}
			return {big: typeof data.place === "number" ? "P" + data.place + "/" + data.of : "", label: routeName,
				time: mrTime(data.elapsed), line: line, warn: warn, giveUp: "Give up"};
		case "finished":
			return {big: "Finished", label: "", time: mrTime(data.elapsed), line: ["Waiting for the other racers…"]};
		}
		return null;
	}

	function streetView(data) {
		var other = String(data.other || "");
		var stake = Number(data.stake) || 0, reward = Number(data.reward) || 0;
		// An event race shows the prize for the racers who started in place of the stake.
		var eventPrize = data.event ? Number(data.prize) || 0 : 0;
		var money = data.rolling ? (reward > 0 ? ["race reward " + mrDollars(reward)] : []) :
			eventPrize > 0 ? ["prize " + mrDollars(eventPrize) + " for " + (Number(data.racers) || 0) + " racers"] :
			[stake > 0 ? mrDollars(stake) + " stake" : "no stake"];
		switch (data.phase) {
		case "countdown":
		case "go":
			var start = data.rolling ? ["Rolling start · keep driving"] : [];
			return {big: data.phase === "go" ? "GO" : String(data.count), label: "",
				line: start.concat(["vs " + other], money), countdown: true,
				giveUp: data.phase === "go" ? (stake > 0 ? "Give up (lose " + mrDollars(stake) + ")" : "Give up") : null};
		case "racing":
			var finish = typeof data.distance === "number" ? ["Finish " + mrKm(data.distance)] : [];
			return {big: "vs " + other, label: "", time: mrTime(data.elapsed),
				line: finish.concat(["follow your map route"], money), warn: null,
				giveUp: stake > 0 ? "Give up (lose " + mrDollars(stake) + ")" : "Give up"};
		case "finished":
			return {big: "Finished", label: "", time: mrTime(data.elapsed),
				line: [data.rolling ? "Waiting for the other racers…" : "Waiting for " + other + "…"]};
		}
		return null;
	}

	function show(kind, view) {
		$scope.$evalAsync(function () {
			if (view) {
				view.time = view.time || null;
				view.warn = view.warn || null;
				view.giveUp = view.giveUp || null;
				$scope.live = {kind: kind, view: view};
			} else if ($scope.live && $scope.live.kind === kind) {
				$scope.live = null;
			}
		});
	}

	$scope.$on('MileageSpotRace', function (event, data) {
		if (data) show("spot", spotView(data));
	});

	$scope.$on('MileageRace', function (event, data) {
		if (data) show("street", streetView(data));
	});

	$scope.giveUp = function () {
		if (!$scope.live) return;
		if ($scope.live.kind === "spot") bngApi.engineLua('if mileage_spotRace then mileage_spotRace.giveUp() end');
		else bngApi.engineLua('if mileage_streetRace then mileage_streetRace.giveUp() end');
	};

	bngApi.engineLua('if mileage_streetRace then mileage_streetRace.sendState() end');
	bngApi.engineLua('if mileage_spotRace then mileage_spotRace.sendState() end');
}]);

// Seconds as m:ss.s, rounded before the minutes are split off so 59.96 s reads 1:00.0.
function mrTime(seconds) {
	var s = Number(seconds);
	if (!isFinite(s) || s < 0) return "-";
	var tenths = Math.round(s * 10);
	var minutes = Math.floor(tenths / 600);
	var rest = (tenths - minutes * 600) / 10;
	return minutes + ":" + (rest < 10 ? "0" : "") + rest.toFixed(1);
}

function mrDollars(n) {
	return "$" + Number(n || 0).toLocaleString("en-US");
}

function mrKm(metres) {
	var m = Number(metres);
	if (!isFinite(m)) return "?";
	return (m / 1000).toFixed(1) + " km";
}
