// Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
// Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
// SPDX-License-Identifier: AGPL-3.0-or-later

var connected = false;
var connectionLost = false;
var players = [];
// NOTE: must be `var`, not `let`. 0.39's UI app service re-evaluates app.js in the
// same scope on refresh (see the ?uiAppRefresh= query it appends). A top-level `let`
// throws "Identifier 'pingList' has already been declared" on the second evaluation,
// which aborts the script before angular.module(...).directive() runs, so the
// mileageplayerlist directive never registers and the app silently fails to load.
var pingList = {};
var nickname = "";
var app = angular.module('beamng.apps');
app.directive('mileageplayerlist', [function () {
	return {
		templateUrl: '/ui/modules/apps/Mileage-PlayerList/app.html',
		replace: true,
		restrict: 'EA',
		scope: true,
		controllerAs: 'ctrl'
	}
}]);
app.controller("PlayerList", ['$scope', '$filter', 'Settings', function ($scope, $filter, Settings) {
	$scope.warnVis = false;
	$scope.timer = null;
	$scope.showPlayerIDs = true
	$scope.playerlistLeftclick = 0;

	const applyPlayerListStyle = function(useNewDesign) {
		const stylesheet = document.getElementById('playerlist-style');
		if (!stylesheet) return;

		let newStylePath;
		if (useNewDesign) {
			newStylePath = '/ui/modules/apps/Mileage-PlayerList/redesign.css';
		} else {
			newStylePath = '/ui/modules/apps/Mileage-PlayerList/app.css';
		}
		
		if (stylesheet.getAttribute('href') !== newStylePath) {
			stylesheet.setAttribute('href', newStylePath);
		}
	};

	$scope.init = function() {
		// Set players list direction
		setPLDirection(localStorage.getItem('plHorizontal'));
		setPLDirection(localStorage.getItem('plVertical'));
		if (localStorage.getItem('plShown') == 1) showList();
		bngApi.engineLua("guihooks.trigger('onBeamMPUpdateCustomButtons', UI.getCustomButtonNames())")
		
		// Apply style on init
		applyPlayerListStyle(Settings.values.useUiAppRedesign);
      	bngApi.engineLua('settings.getValue("showPlayerIDs")', (data) => {
      		$scope.showPlayerIDs = data
    	})
		bngApi.engineLua('settings.getValue("playerlistLeftclick")', (data) => {
			$scope.playerlistLeftclick = data
	  	})
	};

	$scope.$on('SettingsChanged', function (event, data) {
		Settings.values = data.values;
		applyPlayerListStyle(Settings.values.useUiAppRedesign);
		$scope.showPlayerIDs = Settings.values.showPlayerIDs;
		$scope.playerlistLeftclick = Settings.values.playerlistLeftclick;
	});

	$scope.reset = function() {
		connected = false;
		players = [];
		$scope.init();
	};

	$scope.select = function() {
		bngApi.engineLua('setCEFFocus(true)');
	};

	$scope.disconnect = function() {
		players = [];
		connected = false;
	};

	function setPLDirection(direction) {
		const mainContainer = document.getElementById("main-container");
		const plistContainer = document.getElementById("plist-container");
		const showButton = document.getElementById("show-button");
		if (direction == "left") {
			mainContainer.style.flexDirection = "row-reverse";
			localStorage.setItem('plHorizontal', "left");
		}
		else if (direction == "right") {
			mainContainer.style.flexDirection = "row";
			localStorage.setItem('plHorizontal', "right");
		}
		else if (direction == "top") {
			plistContainer.style.marginTop = "0";
			showButton.style.marginTop = "0";
			localStorage.setItem('plVertical', "top");
		}
		else if (direction == "bottom") {
			plistContainer.style.marginTop = "auto";
			showButton.style.marginTop = "auto";
			localStorage.setItem('plVertical', "bottom");
		}
	}

	$scope.plSwapHorizontal = function() {
		const plHorizontal = localStorage.getItem('plHorizontal');
		console.log(plHorizontal);
		if (plHorizontal != "left") setPLDirection("left");
		else setPLDirection("right");
	}

	$scope.plSwapVertical = function() {
		const plVertical = localStorage.getItem('plVertical');
		if (plVertical != "bottom") setPLDirection("bottom");
		else setPLDirection("top");
	}

	$scope.$on('onBeamMPPlayerPings', function(event, data) {
		// BeamMP sends the pings keyed by player name. Each reads 16 ms lower, never below 0
		// or above 999. A ping that is not a number is left out, so its row reads ?ms.
		const parsed = JSON.parse(data);
		const pings = {};
		if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
			for (const name of Object.keys(parsed)) {
				const ping = parsed[name];
				if (typeof ping === "number" && isFinite(ping)) pings[name] = Math.min(999, Math.max(0, ping - 16));
			}
		}
		pingList = pings;
	})

	var customButtons = []

	$scope.$on('onBeamMPUpdateCustomButtons', function(event, data) {
		if (Array.isArray(data)) {
			customButtons = data;
		}
	})

	$scope.$on('onBeamMPPlayerList', function(event, data) {
		if (connectionLost) return;
		let playersList = document.getElementById("players-table");
		let parsedList = JSON.parse(data);
		
		if(players != null && playersList != null){
			//get differences between playernames and send them as messages
			var left = players.filter((item) => { return !parsedList.includes(item) });
			var joined = parsedList.filter((item) => { return !players.includes(item) });
	
			// Clear the player list
			clearPlayerList();
	
			parsedList.sort(function(a, b) {
				var keyA = a.id,
					  keyB = b.id;
				// Compare the 2 dates
				if (keyA < keyB) return -1;
				if (keyA > keyB) return 1;
				return 0;
			});

			// And fill it with the updated players
			for (let i = 0; i < parsedList.length; i++) {
				// Insert a row at the end of the players list
				var row = playersList.insertRow(playersList.rows.length);
	
				row.setAttribute("id", "playerlist-row-" + parsedList[i].id);
				// Click handlers close over the name instead of pasting it into markup.
				const playerName = parsedList[i].name;

				// Insert a cell containing the player server id
				var idCell = row.insertCell(0);
				idCell.textContent = parsedList[i].id;
				idCell.onclick = function() { restorePlayerVehicle(playerName) };
				if ($scope.showPlayerIDs) {
					idCell.setAttribute("class", "player-id");
				} else {
					idCell.setAttribute("class", "player-id ng-hide");
				}
				


				// Insert a cell containing the player name
				var nameCell = row.insertCell(1);
				nameCell.textContent = parsedList[i].formatted_name;
				//var c = parsedList[i].color
				//nameCell.style = `color:rgba(${c[0]},${c[1]},${c[2]},255)`;

				switch ($scope.playerlistLeftclick) {
					case 0:
						nameCell.setAttribute("onclick", "applyQueuesForPlayer('"+parsedList[i].id+"')");
						break;
					case 1:
						nameCell.onclick = function() { showPlayerInfo(playerName) };
						break;
					case 2:
						break;
					case 3:
						break;
					case 4:
						break;
					case 5:
						nameCell.onclick = function() { bngApi.engineLua('setClipboard(' + luaString(playerName) + ')') };
						break;
				}

				nameCell.addEventListener("contextmenu", function(e) {
					e.preventDefault();
				
					const playerlistContextmenu = document.getElementById("playerlist-contextmenu");

					playerlistContextmenu.style.display = "block";
					playerlistContextmenu.style.top = e.clientY + "px";
					playerlistContextmenu.style.left = e.clientX + "px";
					playerlistContextmenu.style.position = "fixed";

					// Leaving the menu closes it, unless an amount is being typed.
					playerlistContextmenu.onmouseleave = function () {
						if (!playerMenu.mode) closePlayerMenu();
					};

					openPlayerMenu(playerName);

					for (let child of playerlistContextmenu.children) {
						if (child.id === "pl-context-custom") {
							playerlistContextmenu.removeChild(child);
						}
					}

					customButtons.forEach(element => {
						let customButton = document.createElement("button");
						customButton.id = "pl-context-custom"
						customButton.textContent = element;
						customButton.onclick = function() {
							bngApi.engineLua(
								'UI.getCustomPlayerlistButtons()[' + luaString(element) + '](' + luaString(parsedList[i].name) + ', ' + Number(parsedList[i].id) + ')'
							)
						}

						playerlistContextmenu.appendChild(customButton);
					});
				});
				nameCell.setAttribute("class", "player-button");

				// Insert a cell containing the link to forum
				//var infoCell = row.insertCell(2);
				//infoCell.setAttribute("class", "view-button");

				// Insert the button inside the link to forum
				//var btn = document.createElement("BUTTON");
				//var pingText = "?";
				//btn.appendChild(document.createTextNode(pingText));
				//btn.setAttribute("onclick","viewPlayer('"+parsedList[i].name+"')");
				//btn.setAttribute("class", "view-button buttons");
				//infoCell.appendChild(btn);
	
				// Insert a cell containing the player ping
				var pingCell = row.insertCell(2);
	
				// Insert the button inside the cell. It only shows the ping; clicking it
				// does nothing.
				var btn = document.createElement("BUTTON");
				var ping = Object.prototype.hasOwnProperty.call(pingList, parsedList[i].name) ? pingList[parsedList[i].name] : undefined;
				var pingText = typeof ping === "number" ? String(ping) : "?";
				btn.appendChild(document.createTextNode(pingText+='ms'));
				btn.setAttribute("class", "tp-button buttons");
				pingCell.appendChild(btn);

				if ($scope.queuedPlayers[parsedList[i].id] == true) {
					row.style.setProperty('background-color', 'var(--bng-orange-shade1)');
				}
			}
			if(document.getElementById("plist-container").style.display == "block")
				document.getElementById("show-button").style.height = playersList.offsetHeight + "px"; 
		}
		players = parsedList; //store player list as an array for the next update
	})

	$scope.$on('onBeamMPSetNickname', function(event, data) {
		nickname = data
	})

	$scope.queuedPlayers = []

	$scope.$on('onBeamMPSetQueue', function(event, data) {
		$scope.queuedPlayers = []

		if (!data.queuedPlayers) {
			var rows = document.querySelectorAll('[id^="playerlist-row-"]');
			for (let i = 0; i < rows.length; i++) {
				rows[i].style.setProperty('background-color', 'transparent');
			}
			return
		}

		for (var key in data.queuedPlayers) {
			$scope.queuedPlayers[key] = data.queuedPlayers[key]
			var playerrow = document.getElementById("playerlist-row-" + key)
			if (playerrow) {
				playerrow.style.setProperty('background-color', data.queuedPlayers[key] ? 'var(--bng-orange-shade1)' : 'transparent')
			}
		}
	})

	// Lost server connection, from mileage/connectionWatch. The banner sits outside the
	// folding list so it shows either way; its text is bound as text, never as markup.
	// While it shows, BeamMP's player list updates are ignored so the dead session's
	// players do not come back underneath it (connectionLost is set at once, not on the
	// next digest).
	$scope.connection = {lost: false, message: "", saveState: ""};

	var SAVE_TEXT = {
		saving: "Saving your career...",
		saved: "Your career was saved.",
		failed: "Your career could not be saved."
	};

	$scope.saveText = function() {
		return SAVE_TEXT[$scope.connection.saveState] || "";
	};

	$scope.$on('mileageConnectionLost', function(event, data) {
		data = data || {};
		connectionLost = true;
		$scope.$evalAsync(function() {
			$scope.connection = {
				lost: true,
				message: String(data.message || "Lost connection to the server"),
				saveState: SAVE_TEXT[data.saveState] ? data.saveState : (data.saved === true ? "saved" : "failed")
			};
		});
		players = [];
		connected = false;
		clearPlayerList();
	})

	$scope.$on('mileageConnectionRestored', function() {
		connectionLost = false;
		$scope.$evalAsync(function() {
			$scope.connection = {lost: false, message: "", saveState: ""};
		});
		bngApi.engineLua('if UI and UI.updatePlayersList then UI.updatePlayersList() end');
	})

	$scope.retrySave = function() {
		bngApi.engineLua('if mileage_connectionWatch then mileage_connectionWatch.retrySave() end');
	};

	$scope.returnToMenu = function() {
		bngApi.engineLua('MPCoreNetwork.leaveServer(true)');
	};

	// What the game says can be done with the player whose menu is open (mileage/offers).
	$scope.$on('MileagePlayerActions', function(event, data) {
		onPlayerActions(data);
	})

	$scope.openLeaderboard = function() {
		bngApi.engineLua('if mileage_leaderboard then mileage_leaderboard.request() end');
	};

	bngApi.engineLua('UI.updatePlayersList(); UI.sendQueue()'); // instantly populate the playerlist and their queues
	// A UI reload while the connection is lost must bring the banner back.
	bngApi.engineLua('if mileage_connectionWatch then mileage_connectionWatch.sendState() end');
}]);

function clearPlayerList() {
	let playersList = document.getElementById("players-table");
	var rowCount = playersList.rows.length - 1;
	for(rowCount; rowCount > 0; rowCount--) playersList.deleteRow(1);
}

// Player names are chosen by other players, so they reach Lua base64-encoded (as UTF-8)
// and are decoded there: no character of a name can end the string and become code.
function luaString(text) {
	var bytes = new TextEncoder().encode(String(text));
	var binary = "";
	for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
	return "require('mime').unb64('" + btoa(binary) + "')";
}

//== the right-click menu: Race, Pay and Request money ==========================
// The menu asks the game what can be done with the player (mileage_offers.actionsFor),
// shows why an action is unavailable, and opens a small form for a typed amount. Every
// text from the game or another player is set as text, never as markup.

var playerMenu = {name: null, actions: null, mode: null};

var ACTION_FORMS = {
	race: {title: "Race ", label: "Stake (both put in, winner takes all)", send: "Send challenge",
		call: "mileage_offers.race", allowZero: true},
	pay: {title: "Pay ", label: "Amount", send: "Pay", call: "mileagePlayerPayments.payPlayer", allowZero: false},
	request: {title: "Ask for money from ", label: "Amount", send: "Send request", call: "mileage_offers.request",
		allowZero: false},
};

function plDollars(n) {
	return "$" + Number(n || 0).toLocaleString("en-US");
}

function plSetText(id, text) {
	var el = document.getElementById(id);
	if (el) el.textContent = text == null ? "" : String(text);
}

function plShow(id, shown) {
	var el = document.getElementById(id);
	if (el) el.style.display = shown ? "block" : "none";
}

function openPlayerMenu(name) {
	playerMenu = {name: name, actions: null, mode: null};
	plSetText("pl-context-name", name);
	plShow("pl-context-form", false);
	renderPlayerActions();
	bngApi.engineLua('if mileage_offers then mileage_offers.actionsFor(' + luaString(name) + ') end');
}

function closePlayerMenu() {
	playerMenu.mode = null;
	plShow("pl-context-form", false);
	plShow("playerlist-contextmenu", false);
}

function renderPlayerActions() {
	var actions = playerMenu.actions;
	Object.keys(ACTION_FORMS).forEach(function(kind) {
		var button = document.getElementById("pl-context-" + kind);
		var action = actions && actions[kind];
		var off = Boolean(action && action.ok === false);
		button.disabled = off;
		plSetText("pl-context-" + kind + "-why", off ? action.why : "");
		plShow("pl-context-" + kind + "-why", off);
		button.onclick = function() { if (!button.disabled) openActionForm(kind); };
	});
}

function onPlayerActions(data) {
	if (!data || data.name !== playerMenu.name) return;
	playerMenu.actions = data;
	renderPlayerActions();
}

function actionInfo(kind) {
	var action = playerMenu.actions && playerMenu.actions[kind];
	if (!action) return "";
	if (kind === "race") {
		var km = typeof action.distance === "number" ? " · " + (action.distance / 1000).toFixed(1) + " km away" : "";
		var prize = action.prize > 0 ? " · server prize " + plDollars(action.prize) : "";
		return "Finish: your map route" + km + ". Up to " + plDollars(action.stakeMax) + " on this server" + prize;
	}
	if (kind === "pay" && typeof action.money === "number") return "You have " + plDollars(action.money) + ".";
	return "";
}

function openActionForm(kind) {
	var form = ACTION_FORMS[kind];
	playerMenu.mode = kind;
	plSetText("pl-context-form-title", form.title + playerMenu.name);
	plSetText("pl-context-form-info", actionInfo(kind));
	plSetText("pl-context-amount-label", form.label);
	plSetText("pl-context-send", form.send);
	plSetText("pl-context-error", "");
	var input = document.getElementById("pl-context-amount");
	input.value = kind === "race" ? "0" : "";
	// Typing needs the game's keyboard focus on the UI.
	input.onfocus = function() { bngApi.engineLua('setCEFFocus(true)'); };
	document.getElementById("pl-context-send").onclick = sendActionForm;
	document.getElementById("pl-context-cancel").onclick = closePlayerMenu;
	plShow("pl-context-form", true);
}

// A whole number of dollars typed by the player, or null.
function parseAmount(text, allowZero) {
	var typed = String(text == null ? "" : text).trim().replace(/[$,]/g, "");
	if (!/^\d{1,12}$/.test(typed)) return null;
	var amount = parseInt(typed, 10);
	if (amount === 0 && !allowZero) return null;
	return amount;
}

function sendActionForm() {
	var kind = playerMenu.mode;
	var form = ACTION_FORMS[kind];
	if (!form) return;
	var amount = parseAmount(document.getElementById("pl-context-amount").value, form.allowZero);
	if (amount === null) {
		plSetText("pl-context-error", form.allowZero ? "Enter a stake of $0 or more, in whole dollars."
			: "Enter a whole number of dollars above $0.");
		return;
	}
	var action = playerMenu.actions && playerMenu.actions[kind];
	if (kind === "pay" && action && typeof action.money === "number" && amount > action.money) {
		plSetText("pl-context-error", "More than you have (" + plDollars(action.money) + "). Enter a smaller amount.");
		return;
	}
	if (kind === "race" && action && typeof action.stakeMax === "number" && amount > action.stakeMax) {
		plSetText("pl-context-error", "Above this server's limit of " + plDollars(action.stakeMax) + ".");
		return;
	}
	bngApi.engineLua(form.call + '(' + luaString(playerMenu.name) + ', ' + amount + ')');
	closePlayerMenu();
}

function setOfflineInPlayerList() {
	let playersList = document.getElementById("players");
	if(playersList != null) playersList.textContent = "OFFLINE"; //added this cause it was throwing console errors
}

function showList() {
	var shownText = "&gt;";
	var hiddenText = "&lt;";
	if (localStorage.getItem('plHorizontal') == "right") { shownText = "&lt;"; hiddenText = "&gt;"; }
	var plContainer = document.getElementById("plist-container");
	var btn = document.getElementById("show-button");
	plContainer.style.display = "block";
	btn.innerHTML = shownText;
}

function hideList() {
	var hiddenText = "&lt;";
	if (localStorage.getItem('plHorizontal') == "right") { hiddenText = "&gt;"; }
	var plContainer = document.getElementById("plist-container");
	var btn = document.getElementById("show-button");
	plContainer.style.display = "none";
	btn.innerHTML = hiddenText;
	btn.style.height = "75px";
}

function toggleList() {
	if(localStorage.getItem('plShown') != 1) {
		showList();
		localStorage.setItem('plShown', 1);
	}
	else {
		hideList();
		localStorage.setItem('plShown', 0);
	}
}
