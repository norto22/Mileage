// Mileage-PlayerList/app.js: the lost-connection banner, and the player rows it keeps
// empty while it shows. Runs the real app script against small stand-ins for the
// game's UI (Angular scope, bngApi, the page), with Node's standard library only.
//
//   node tests/player_list_test.js          (from the repository root)

const fs = require("fs");
const vm = require("vm");
const assert = require("assert");

const SOURCE = "Resources/Client/Mileage/ui/modules/apps/Mileage-PlayerList/app.js";

function element(id) {
	const el = {
		id, rows: [], children: [], cells: [], style: {setProperty() {}}, attributes: {},
		offsetHeight: 0, textContent: "",
		setAttribute(k, v) { el.attributes[k] = v; },
		getAttribute(k) { return el.attributes[k]; },
		appendChild(c) { el.children.push(c); return c; },
		removeChild() {},
		listeners: {},
		addEventListener(type, fn) { el.listeners[type] = fn; },
		insertRow(i) { const r = element(); el.rows.splice(i, 0, r); return r; },
		deleteRow(i) { el.rows.splice(i, 1); },
		insertCell(i) { const c = element(); el.cells.splice(i, 0, c); return c; },
	};
	return el;
}

// A fresh page and controller; returns the controller's scope, the players table and
// the Lua the app sent to the game.
function load() {
	const page = {};
	const byId = (id) => (page[id] = page[id] || element(id));
	const table = byId("players-table");
	table.rows.push(element()); // the header row stays
	const lua = [];
	let controller = null;
	const handlers = {};
	const scope = {
		$on(name, fn) { handlers[name] = fn; },
		$evalAsync(fn) { fn(); },
		emit(name, data) { handlers[name]({}, data); },
	};
	const context = {
		angular: {module: () => ({directive() {}, controller(name, deps) { controller = deps[deps.length - 1]; }})},
		bngApi: {engineLua(cmd) { lua.push(cmd); }},
		document: {getElementById: byId, createElement: () => element(), createTextNode: (t) => ({text: t})},
		localStorage: {getItem() { return null; }, setItem() {}},
		console, JSON, TextEncoder, btoa,
	};
	vm.createContext(context);
	vm.runInContext(fs.readFileSync(SOURCE, "utf8"), context, {filename: SOURCE});
	controller(scope, null, {values: {}});
	return {scope, table, lua, page: byId, context};
}

const PLAYERS = JSON.stringify([
	{id: 0, name: "Ann", formatted_name: "Ann"},
	{id: 1, name: "Bob", formatted_name: "Bob"},
]);

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test("a player list update fills the table", () => {
	const {scope, table} = load();
	scope.emit("onBeamMPPlayerList", PLAYERS);
	assert.strictEqual(table.rows.length, 3, "header and two players");
});

test("#51: the ping button shows each player's ping and does nothing when clicked", () => {
	const {scope, table} = load();
	scope.emit("onBeamMPPlayerPings", JSON.stringify({Ann: 40}));
	scope.emit("onBeamMPPlayerList", PLAYERS);
	const pings = table.rows.slice(1).map((row) => row.cells[2].children[0]);
	assert.deepStrictEqual(pings.map((btn) => btn.children[0].text), ["24ms", "?ms"], "ping texts (#109: 16 ms lower)");
	for (const btn of pings) {
		assert.strictEqual(btn.getAttribute("class"), "tp-button buttons", "button look");
		assert.strictEqual(btn.getAttribute("onclick"), undefined, "click action");
	}
	assert.ok(!/teleportToPlayer/.test(fs.readFileSync(SOURCE, "utf8")), "the app names no teleport");
});

// The ping text of each player row, in order.
function pingTexts(table) {
	return table.rows.slice(1).map((row) => row.cells[2].children[0].children[0].text);
}

const FOUR_PLAYERS = JSON.stringify([
	{id: 0, name: "Ann", formatted_name: "Ann"},
	{id: 1, name: "Bob", formatted_name: "Bob"},
	{id: 2, name: "Cy", formatted_name: "Cy"},
	{id: 3, name: "Dee", formatted_name: "Dee"},
]);

test("#109: each ping reads 16 ms lower, never below 0 or above 999", () => {
	const {scope, table} = load();
	scope.emit("onBeamMPPlayerPings", JSON.stringify({Ann: 66, Bob: 1200, Cy: 10}));
	scope.emit("onBeamMPPlayerList", FOUR_PLAYERS);
	assert.deepStrictEqual(pingTexts(table), ["50ms", "999ms", "0ms", "?ms"], "ping texts");
});

test("#109: a ping that is not a number, or pings that are not a list by name, read ?ms", () => {
	const {scope, table} = load();
	scope.emit("onBeamMPPlayerPings", JSON.stringify({Ann: "fast", Bob: null, Cy: 16}));
	scope.emit("onBeamMPPlayerList", FOUR_PLAYERS);
	assert.deepStrictEqual(pingTexts(table), ["?ms", "?ms", "0ms", "?ms"], "ping texts");
	for (const payload of ["[66, 70]", "42", "null"]) {
		const app = load();
		app.scope.emit("onBeamMPPlayerPings", payload);
		app.scope.emit("onBeamMPPlayerList", FOUR_PLAYERS);
		assert.deepStrictEqual(pingTexts(app.table), ["?ms", "?ms", "?ms", "?ms"], "ping texts for " + payload);
	}
});

test("#109: each ping update replaces the last, so a player who left the pings reads ?ms", () => {
	const {scope, table} = load();
	scope.emit("onBeamMPPlayerPings", JSON.stringify({Ann: 66, Bob: 80}));
	scope.emit("onBeamMPPlayerPings", JSON.stringify({Bob: 100}));
	scope.emit("onBeamMPPlayerList", PLAYERS);
	assert.deepStrictEqual(pingTexts(table), ["?ms", "84ms"], "ping texts after the second update");
});

test("#109: the cap is 999 after taking 16 ms off, and a ping below 0 reads 0ms", () => {
	const {scope, table} = load();
	scope.emit("onBeamMPPlayerPings", JSON.stringify({Ann: 1014, Bob: 1015, Cy: -5, Dee: 17}));
	scope.emit("onBeamMPPlayerList", FOUR_PLAYERS);
	assert.deepStrictEqual(pingTexts(table), ["998ms", "999ms", "0ms", "1ms"], "ping texts");
});

test("#109: a player named like an object property reads ?ms when BeamMP sends no ping for them", () => {
	const {scope, table} = load();
	scope.emit("onBeamMPPlayerPings", JSON.stringify({Ann: 66}));
	scope.emit("onBeamMPPlayerList", JSON.stringify([
		{id: 0, name: "Ann", formatted_name: "Ann"},
		{id: 1, name: "constructor", formatted_name: "constructor"},
		{id: 2, name: "toString", formatted_name: "toString"},
	]));
	assert.deepStrictEqual(pingTexts(table), ["50ms", "?ms", "?ms"], "ping texts");
});

test("losing the connection empties the list and keeps it empty through BeamMP's updates", () => {
	const {scope, table} = load();
	scope.emit("onBeamMPPlayerList", PLAYERS);
	scope.emit("mileageConnectionLost", {message: "Lost connection to the server", saveState: "saved", saved: true});
	assert.strictEqual(table.rows.length, 1, "rows after the loss");
	scope.emit("onBeamMPPlayerList", PLAYERS);
	assert.strictEqual(table.rows.length, 1, "rows after a later update");
	assert.strictEqual(scope.connection.lost, true, "banner shown");
	assert.strictEqual(scope.connection.message, "Lost connection to the server", "banner message");
	assert.strictEqual(scope.saveText(), "Your career was saved.", "save line");
});

test("being heard again shows the players again", () => {
	const {scope, table, lua} = load();
	scope.emit("mileageConnectionLost", {message: "Lost connection to the server", saveState: "saved"});
	scope.emit("mileageConnectionRestored");
	assert.strictEqual(scope.connection.lost, false, "banner hidden");
	assert.ok(lua.some((cmd) => cmd.includes("UI.updatePlayersList()")), "list asked for again");
	scope.emit("onBeamMPPlayerList", PLAYERS);
	assert.strictEqual(table.rows.length, 3, "rows after the update");
});

test("the save line follows the save state and never claims an unconfirmed save", () => {
	const {scope} = load();
	const line = (data) => { scope.emit("mileageConnectionLost", data); return scope.saveText(); };
	assert.strictEqual(line({saveState: "saving", saved: false}), "Saving your career...");
	assert.strictEqual(line({saveState: "failed", saved: false}), "Your career could not be saved.");
	assert.strictEqual(line({saveState: "saved", saved: true}), "Your career was saved.");
	assert.strictEqual(line({}), "Your career could not be saved.", "no state at all");
});

test("the buttons ask the game to try the save again and to return to the menu", () => {
	const {scope, lua} = load();
	scope.retrySave();
	scope.returnToMenu();
	assert.ok(lua.includes("if mileage_connectionWatch then mileage_connectionWatch.retrySave() end"), "retry");
	assert.ok(lua.includes("MPCoreNetwork.leaveServer(true)"), "return to menu");
});

test("the app asks for the current state when it loads", () => {
	const {lua} = load();
	assert.ok(lua.includes("if mileage_connectionWatch then mileage_connectionWatch.sendState() end"));
});

// The banner's template, from the real app.html.
const TEMPLATE = fs.readFileSync("Resources/Client/Mileage/ui/modules/apps/Mileage-PlayerList/app.html", "utf8");

// The markup of the element opened at `start`, up to its matching </div>.
function divBlock(start) {
	const tag = /<\/?div\b/g;
	tag.lastIndex = start;
	let depth = 0, m;
	while ((m = tag.exec(TEMPLATE))) {
		depth += m[0] === "<div" ? 1 : -1;
		if (depth === 0) return TEMPLATE.slice(start, TEMPLATE.indexOf(">", m.index) + 1);
	}
	throw new Error("unclosed div");
}

// Evaluates an Angular expression from the template against the controller's scope.
function evalExpr(expr, scope) {
	return new Function("s", "with (s) { return (" + expr + "); }")(scope);
}

test("an update that arrives after the loss but before the screen redraws is ignored", () => {
	const {scope, table} = load();
	const pending = [];
	scope.$evalAsync = (fn) => pending.push(fn);
	scope.emit("onBeamMPPlayerList", PLAYERS);
	scope.emit("mileageConnectionLost", {message: "Lost connection to the server", saveState: "saving"});
	scope.emit("onBeamMPPlayerList", PLAYERS);
	assert.strictEqual(table.rows.length, 1, "rows before the redraw");
	pending.forEach((fn) => fn());
	assert.strictEqual(scope.connection.lost, true, "banner shown after the redraw");
});

test("the banner sits outside the folding list, so it shows with the list folded away", () => {
	const start = TEMPLATE.indexOf('<div id="connection-banner"');
	assert.ok(start >= 0, "banner in the template");
	const banner = divBlock(start);
	assert.ok(!banner.includes('id="plist-container"') && !banner.includes('id="main-container"'), "banner holds no list");
	const list = TEMPLATE.indexOf('<div id="plist-container"');
	assert.ok(!divBlock(list).includes("connection-banner"), "list holds no banner");
});

test("the banner shows the message and save line as text, never as markup", () => {
	const banner = divBlock(TEMPLATE.indexOf('<div id="connection-banner"'));
	assert.ok(/class="connection-message" ng-bind="connection\.message"/.test(banner), "message bound as text");
	assert.ok(/class="connection-save" ng-bind="saveText\(\)"/.test(banner), "save line bound as text");
	assert.ok(!/ng-bind-html|innerHTML/.test(banner), "no markup binding");
});

test("Try saving again shows only after a failed save; Return to menu always", () => {
	const {scope} = load();
	const banner = divBlock(TEMPLATE.indexOf('<div id="connection-banner"'));
	const retry = banner.match(/<button[^>]*ng-show="([^"]*)"[^>]*ng-click="retrySave\(\)"[^>]*>Try saving again</);
	assert.ok(retry, "Try saving again button with ng-show");
	const shown = (state) => {
		scope.emit("mileageConnectionLost", {message: "Lost connection to the server", saveState: state, saved: state === "saved"});
		return Boolean(evalExpr(retry[1], scope));
	};
	assert.strictEqual(shown("saving"), false, "while saving");
	assert.strictEqual(shown("saved"), false, "after a save");
	assert.strictEqual(shown("failed"), true, "after a failed save");
	assert.ok(/<button(?![^>]*ng-show)[^>]*ng-click="returnToMenu\(\)"[^>]*>Return to menu</.test(banner), "Return to menu always shown");
});

test("folding the list hides it and unfolding shows it again", () => {
	const {page, context} = load();
	context.hideList();
	assert.strictEqual(page("plist-container").style.display, "none", "folded");
	assert.strictEqual(page("show-button").innerHTML, "&lt;", "fold button");
	context.showList();
	assert.strictEqual(page("plist-container").style.display, "block", "unfolded");
	assert.strictEqual(page("show-button").innerHTML, "&gt;", "unfold button");
});

//== the right-click menu ======================================================

const b64 = (name) => "require('mime').unb64('" + Buffer.from(name, "utf8").toString("base64") + "')";

// Right-clicks the name cell of the player at row index (1 is the first player).
function rightClick(app, rowIndex) {
	const nameCell = app.table.rows[rowIndex].cells[1];
	nameCell.listeners.contextmenu({preventDefault() {}, clientX: 10, clientY: 20});
	return app.page("playerlist-contextmenu");
}

function menuApp() {
	const app = load();
	app.scope.emit("onBeamMPPlayerList", PLAYERS);
	return app;
}

function typeAndSend(app, kind, text) {
	app.page("pl-context-" + kind).onclick();
	app.page("pl-context-amount").value = text;
	app.page("pl-context-send").onclick();
}

test("right-clicking a player opens the menu and asks the game what can be done with them", () => {
	const app = menuApp();
	const menu = rightClick(app, 2);
	assert.strictEqual(menu.style.display, "block", "menu shown");
	assert.strictEqual(app.page("pl-context-name").textContent, "Bob", "player named");
	assert.ok(app.lua.includes("if mileage_offers then mileage_offers.actionsFor(" + b64("Bob") + ") end"), "asked");
});

test("Request money sends the typed whole amount with the name encoded", () => {
	const app = menuApp();
	rightClick(app, 2);
	typeAndSend(app, "request", "3500");
	assert.ok(app.lua.includes("mileage_offers.request(" + b64("Bob") + ", 3500)"), "request sent");
	assert.strictEqual(app.page("playerlist-contextmenu").style.display, "none", "menu closed");
});

test("Pay sends the typed amount; $ and thousands commas are accepted", () => {
	const app = menuApp();
	rightClick(app, 2);
	typeAndSend(app, "pay", "$1,250");
	assert.ok(app.lua.includes("mileagePlayerPayments.payPlayer(" + b64("Bob") + ", 1250)"), "payment sent");
});

test("Race sends the stake, and $0 is a race with no stake", () => {
	const app = menuApp();
	rightClick(app, 2);
	app.scope.emit("MileagePlayerActions", {name: "Bob", race: {ok: true, distance: 2400, stakeMax: 10000, prize: 500},
		pay: {ok: true, money: 5000}, request: {ok: true}});
	app.page("pl-context-race").onclick();
	assert.strictEqual(app.page("pl-context-amount").value, "0", "stake starts at $0");
	assert.ok(app.page("pl-context-form-info").textContent.includes("2.4 km away"), "distance shown");
	assert.ok(app.page("pl-context-form-info").textContent.includes("server prize $500"), "prize shown");
	app.page("pl-context-send").onclick();
	assert.ok(app.lua.includes("mileage_offers.race(" + b64("Bob") + ", 0)"), "race sent");
});

test("Drag race sends the stake to mileage_offers.dragRace and says where, the limit and the server prize", () => {
	const app = menuApp();
	rightClick(app, 2);
	app.scope.emit("MileagePlayerActions", {name: "Bob", race: {ok: true, stakeMax: 10000},
		drag: {ok: true, stakeMax: 10000, prize: 500, minutes: 15}, pay: {ok: true}, request: {ok: true}});
	app.page("pl-context-drag").onclick();
	assert.strictEqual(app.page("pl-context-form-title").textContent, "Drag race Bob", "title");
	assert.strictEqual(app.page("pl-context-amount-label").textContent, "Stake (both put in, winner takes all)", "label");
	assert.strictEqual(app.page("pl-context-amount").value, "0", "stake starts at $0");
	assert.strictEqual(app.page("pl-context-form-info").textContent,
		"At the drag strip. Up to $10,000 on this server · server prize $500", "info");
	app.page("pl-context-amount").value = "2000";
	app.page("pl-context-send").onclick();
	assert.ok(app.lua.includes("mileage_offers.dragRace(" + b64("Bob") + ", 2000)"), "drag race sent");
});

test("Drag race with no server prize says so, and a stake above the limit is not sent", () => {
	const app = menuApp();
	rightClick(app, 2);
	app.scope.emit("MileagePlayerActions", {name: "Bob", drag: {ok: true, stakeMax: 1000, prize: 0},
		pay: {ok: true}, request: {ok: true}});
	app.page("pl-context-drag").onclick();
	assert.strictEqual(app.page("pl-context-form-info").textContent,
		"At the drag strip. Up to $1,000 on this server · no server prize", "no prize");
	const before = app.lua.length;
	typeAndSend(app, "drag", "2000");
	assert.strictEqual(app.page("pl-context-error").textContent, "Above this server's limit of $1,000.");
	assert.strictEqual(app.lua.length, before, "nothing sent");
});

test("Drag race unavailable shows its reason and does not open", () => {
	const app = menuApp();
	rightClick(app, 2);
	app.scope.emit("MileagePlayerActions", {name: "Bob", drag: {ok: false, why: "Racing is switched off on this server."},
		pay: {ok: true}, request: {ok: true}});
	assert.strictEqual(app.page("pl-context-drag").disabled, true, "disabled");
	assert.strictEqual(app.page("pl-context-drag-why").textContent, "Racing is switched off on this server.");
	app.page("pl-context-drag").onclick();
	assert.notStrictEqual(app.page("pl-context-form").style.display, "block", "form not opened");
	assert.ok(/id="pl-context-race"[\s\S]*id="pl-context-drag"[\s\S]*id="pl-context-pay"/.test(TEMPLATE),
		"Drag race… between Race… and Pay…");
});

test("Drag race refuses a stake that is not whole dollars, and sends $0 and a stake exactly at the limit", () => {
	const app = menuApp();
	rightClick(app, 2);
	app.scope.emit("MileagePlayerActions", {name: "Bob", drag: {ok: true, stakeMax: 1000, prize: 0},
		pay: {ok: true}, request: {ok: true}});
	const before = app.lua.length;
	for (const text of ["", "abc", "-5", "1.5"]) {
		typeAndSend(app, "drag", text);
		assert.strictEqual(app.page("pl-context-error").textContent, "Enter a stake of $0 or more, in whole dollars.", text);
	}
	assert.strictEqual(app.lua.length, before, "nothing sent");
	typeAndSend(app, "drag", "1000");
	assert.ok(app.lua.includes("mileage_offers.dragRace(" + b64("Bob") + ", 1000)"), "the limit itself is allowed");
	rightClick(app, 2);
	app.scope.emit("MileagePlayerActions", {name: "Bob", drag: {ok: true, stakeMax: 1000, prize: 0},
		pay: {ok: true}, request: {ok: true}});
	typeAndSend(app, "drag", "0");
	assert.ok(app.lua.includes("mileage_offers.dragRace(" + b64("Bob") + ", 0)"), "no stake is allowed");
});

test("disabled menu entries are #bbb in both looks, readable on the menu's background", () => {
	for (const sheet of ["app.css", "redesign.css"]) {
		const css = fs.readFileSync("Resources/Client/Mileage/ui/modules/apps/Mileage-PlayerList/" + sheet, "utf8");
		assert.strictEqual(cssRule(css, "#playerlist-contextmenu button:disabled").color, "#bbb", sheet);
	}
});

test("an empty, zero, negative, fractional or non-numeric amount sends nothing and says why", () => {
	const app = menuApp();
	rightClick(app, 2);
	const before = app.lua.length;
	for (const text of ["", "0", "-5", "2.5", "abc"]) {
		typeAndSend(app, "request", text);
		assert.strictEqual(app.page("pl-context-error").textContent, "Enter a whole number of dollars above $0.", text);
	}
	assert.strictEqual(app.lua.length, before, "nothing sent");
});

test("paying more than the career has, or staking above the limit, says why and sends nothing", () => {
	const app = menuApp();
	rightClick(app, 2);
	app.scope.emit("MileagePlayerActions", {name: "Bob", race: {ok: true, stakeMax: 1000},
		pay: {ok: true, money: 48210}, request: {ok: true}});
	const before = app.lua.length;
	typeAndSend(app, "pay", "50000");
	assert.strictEqual(app.page("pl-context-error").textContent, "More than you have ($48,210). Enter a smaller amount.");
	typeAndSend(app, "race", "2000");
	assert.strictEqual(app.page("pl-context-error").textContent, "Above this server's limit of $1,000.");
	assert.strictEqual(app.lua.length, before, "nothing sent");
});

test("an action the server switched off shows its reason and does not open", () => {
	const app = menuApp();
	rightClick(app, 2);
	app.scope.emit("MileagePlayerActions", {name: "Bob", race: {ok: false, why: "Set a route on the big map first."},
		pay: {ok: true}, request: {ok: false, why: "Requests are switched off on this server."}});
	assert.strictEqual(app.page("pl-context-request").disabled, true, "request disabled");
	assert.strictEqual(app.page("pl-context-request-why").textContent, "Requests are switched off on this server.");
	assert.strictEqual(app.page("pl-context-request-why").style.display, "block", "reason shown");
	assert.strictEqual(app.page("pl-context-race-why").textContent, "Set a route on the big map first.");
	assert.strictEqual(app.page("pl-context-pay").disabled, false, "pay open");
	app.page("pl-context-request").onclick();
	assert.notStrictEqual(app.page("pl-context-form").style.display, "block", "form not opened");
});

test("actions for another player than the menu's are ignored", () => {
	const app = menuApp();
	rightClick(app, 2);
	app.scope.emit("MileagePlayerActions", {name: "Ann", request: {ok: false, why: "x"}});
	assert.strictEqual(app.page("pl-context-request").disabled, false, "still open");
});

test("the Leaderboard button asks the game for the leaderboard", () => {
	const {scope, lua} = load();
	scope.openLeaderboard();
	assert.ok(lua.includes("if mileage_leaderboard then mileage_leaderboard.request() end"));
	assert.ok(/id="leaderboard-button"[^>]*ng-click="openLeaderboard\(\)"/.test(TEMPLATE), "button in the header");
});

test("the menu has no fixed pay buttons and sets every text as text", () => {
	assert.ok(!/Pay \$1000/.test(TEMPLATE), "fixed buttons gone");
	const source = fs.readFileSync(SOURCE, "utf8");
	const menu = source.slice(source.indexOf("//== the right-click menu"), source.indexOf("function setOfflineInPlayerList"));
	assert.ok(menu.includes("function sendActionForm"), "the menu's code");
	assert.ok(!/innerHTML/.test(menu), "no markup from names or reasons");
});

// The declarations of the first rule whose selector list is exactly `selector`.
function cssRule(css, selector) {
	const re = /([^{}]+)\{([^}]*)\}/g;
	let m;
	while ((m = re.exec(css)) !== null) {
		if (m[1].replace(/\/\*[\s\S]*?\*\//g, "").trim() === selector) {
			const props = {};
			m[2].split(";").forEach((d) => {
				const i = d.indexOf(":");
				if (i > 0) props[d.slice(0, i).trim()] = d.slice(i + 1).trim();
			});
			return props;
		}
	}
	throw new Error("no rule " + selector);
}

test("both looks of the player list use the compact rows, cells and buttons", () => {
	for (const sheet of ["app.css", "redesign.css"]) {
		const css = fs.readFileSync("Resources/Client/Mileage/ui/modules/apps/Mileage-PlayerList/" + sheet, "utf8");
		assert.strictEqual(cssRule(css, "#players-table")["font-size"], "0.9em", sheet + ": rows");
		assert.strictEqual(cssRule(css, "#players-table td").padding, "0 4px", sheet + ": cells");
		const direction = cssRule(css, ".direction-buttons");
		assert.strictEqual(direction.width, "26px", sheet + ": direction button width");
		assert.strictEqual(direction.height, "21px", sheet + ": direction button height");
		assert.strictEqual(cssRule(css, ".tp-button").width, "56px !important", sheet + ": ping column");
		assert.strictEqual(cssRule(css, ".playerslist-col-3").width, "56px", sheet + ": its header column");
		assert.strictEqual(cssRule(css, "#playerlist-contextmenu > button").padding, "4px 8px", sheet + ": menu buttons");
	}
});

test("every function in the app script is declared once", () => {
	const source = fs.readFileSync(SOURCE, "utf8");
	const counts = {};
	for (const m of source.matchAll(/^function (\w+)\s*\(/gm)) counts[m[1]] = (counts[m[1]] || 0) + 1;
	const twice = Object.keys(counts).filter((name) => counts[name] > 1);
	assert.deepStrictEqual(twice, [], "functions declared more than once");
});

let failed = 0;
for (const [name, fn] of tests) {
	try {
		fn();
		console.log("ok   " + name);
	} catch (err) {
		failed++;
		console.log("FAIL " + name + "\n     " + err.message);
	}
}
console.log(`${tests.length - failed} passed, ${failed} failed`);
process.exitCode = failed > 0 ? 1 : 0;
