const COLORS = ["R", "G", "Y", "B"];
const COLOR_NAMES = { R: "Red", G: "Green", Y: "Yellow", B: "Blue" };

// Verified board geometry (52-cell closed loop, 4 home stretches, yard slots).
const PATH = [
    [6, 1], [6, 2], [6, 3], [6, 4], [6, 5],
    [5, 6], [4, 6], [3, 6], [2, 6], [1, 6], [0, 6],
    [0, 7],
    [0, 8], [1, 8], [2, 8], [3, 8], [4, 8], [5, 8],
    [6, 9], [6, 10], [6, 11], [6, 12], [6, 13], [6, 14],
    [7, 14],
    [8, 14], [8, 13], [8, 12], [8, 11], [8, 10], [8, 9],
    [9, 8], [10, 8], [11, 8], [12, 8], [13, 8], [14, 8],
    [14, 7],
    [14, 6], [13, 6], [12, 6], [11, 6], [10, 6], [9, 6],
    [8, 5], [8, 4], [8, 3], [8, 2], [8, 1], [8, 0],
    [7, 0],
    [6, 0],
];
const START_INDEX = { R: 0, G: 13, Y: 26, B: 39 };
const STAR_INDICES = [8, 21, 34, 47]; // extra "rest stop" safe cells, 8 steps into each arm
const HOME = {
    R: [[7, 1], [7, 2], [7, 3], [7, 4], [7, 5], [7, 6]],
    G: [[1, 7], [2, 7], [3, 7], [4, 7], [5, 7], [6, 7]],
    Y: [[7, 13], [7, 12], [7, 11], [7, 10], [7, 9], [7, 8]],
    B: [[13, 7], [12, 7], [11, 7], [10, 7], [9, 7], [8, 7]],
};
const YARD_SLOTS = {
    R: [[1, 1], [1, 4], [4, 1], [4, 4]],
    G: [[1, 10], [1, 13], [4, 10], [4, 13]],
    Y: [[10, 10], [10, 13], [13, 10], [13, 13]],
    B: [[10, 1], [10, 4], [13, 1], [13, 4]],
};

function cellsInRect(r0, r1, c0, c1) {
    const out = [];
    for (let r = r0; r <= r1; r++) for (let c = c0; c <= c1; c++) out.push([r, c]);
    return out;
}
const YARD_CELLS = {
    R: cellsInRect(0, 5, 0, 5),
    G: cellsInRect(0, 5, 9, 14),
    Y: cellsInRect(9, 14, 9, 14),
    B: cellsInRect(9, 14, 0, 5),
};

function cellKey(r, c) { return r + "," + c; }
function globalCellFor(color, pos) {
    if (pos <= 50) return PATH[(START_INDEX[color] + pos) % 52];
    return HOME[color][pos - 51];
}

// ---------------------------------------------------------------------
// DOM refs
// ---------------------------------------------------------------------
const pregameWrapperDiv = document.getElementById("pregameWrapper");
const gameWrapperDiv = document.getElementById("gameWrapper");
const lobbyMessageDiv = document.getElementById("lobbyMessage");
const keyDisplayDiv = document.getElementById("keyDisplay");
const statusDiv = document.getElementById("status");
const playerDiv = document.getElementById("player");
const messageDiv = document.getElementById("message");
const diceValueDiv = document.getElementById("diceValue");
const rollBtn = document.getElementById("rollBtn");
const boardDiv = document.getElementById("board");
const playersConnectedSpan = document.getElementById("playersConnected");
const spectatorCountSpan = document.getElementById("spectatorCount");
const seatRequestBanner = document.getElementById("seatRequestBanner");
const spectatorPanel = document.getElementById("spectatorPanel");

let socket = null;
let myColors = [];
let myRole = null; // "player" | "spectator"

const socketProtocol = location.protocol === "https:" ? "wss" : "ws";

const closeErrors = {
    4402: "That code is already in use by another game. Try a different one.",
    4403: "Code must be exactly 5 letters/numbers.",
    4404: "No game found with that code.",
    4405: "That random game is already full (4 players). Try again to join/create another.",
    4406: "Invalid bot difficulty."
};

// ---------------------------------------------------------------------
// Build the static 15x15 board once.
// ---------------------------------------------------------------------
const cellLookup = {};
for (const color of COLORS) for (const [r, c] of YARD_CELLS[color]) cellLookup[cellKey(r, c)] = { kind: "yard", color };
for (const color of COLORS) {
    const [sr, sc] = PATH[START_INDEX[color]];
    cellLookup[cellKey(sr, sc)] = { kind: "start", color };
}
for (const idx of STAR_INDICES) {
    const [r, c] = PATH[idx];
    cellLookup[cellKey(r, c)] = { kind: "safe" };
}
for (const color of COLORS) {
    for (const [r, c] of HOME[color]) {
        if (!cellLookup[cellKey(r, c)]) cellLookup[cellKey(r, c)] = { kind: "home", color };
    }
}

const centerPiece = document.createElement("div");
centerPiece.id = "centerPiece";
centerPiece.innerHTML = "<span>🏆</span>";
boardDiv.appendChild(centerPiece);

for (let r = 0; r < 15; r++) {
    for (let c = 0; c < 15; c++) {
        if (r >= 6 && r <= 8 && c >= 6 && c <= 8) continue; // covered by #centerPiece
        const div = document.createElement("div");
        div.style.gridRow = (r + 1) + " / " + (r + 2);
        div.style.gridColumn = (c + 1) + " / " + (c + 2);
        div.className = "cell";

        const info = cellLookup[cellKey(r, c)];
        if (info) {
            if (info.kind === "yard") {
                const insideNest = r % 6 >= 1 && r % 6 <= 4 && c % 6 >= 1 && c % 6 <= 4;
                div.classList.add(insideNest ? "yard-nest" : "yard-" + info.color.toLowerCase());
            } else if (info.kind === "start") {
                div.classList.add("start-" + info.color.toLowerCase());
            } else if (info.kind === "home") {
                div.classList.add("home-" + info.color.toLowerCase());
            } else if (info.kind === "safe") {
                div.classList.add("safe-cell");
                div.innerHTML = "⭐";
            }
        }

        for (const color of COLORS) {
            for (const [yr, yc] of YARD_SLOTS[color]) {
                if (yr === r && yc === c) {
                    const slot = document.createElement("div");
                    slot.className = "yard-slot";
                    div.appendChild(slot);
                }
            }
        }

        boardDiv.appendChild(div);
    }
}

const tokenEls = { R: [], G: [], Y: [], B: [] };
for (const color of COLORS) {
    for (let i = 0; i < 4; i++) {
        const el = document.createElement("div");
        el.className = "token color-" + color.toLowerCase();
        el.textContent = String(i + 1);
        el.addEventListener("click", () => makeMove(color, i));
        boardDiv.appendChild(el);
        tokenEls[color].push(el);
    }
}

function positionToken(el, r, c, stackIndex) {
    el.style.gridRow = (r + 1) + " / " + (r + 2);
    el.style.gridColumn = (c + 1) + " / " + (c + 2);
    el.classList.remove("stacked-2", "stacked-3", "stacked-4");
    if (stackIndex > 0) el.classList.add("stacked-" + (stackIndex + 1));
}

// ---------------------------------------------------------------------
// Lobby / connection
// ---------------------------------------------------------------------
function showLobbyError(text) {
    lobbyMessageDiv.innerText = text;
    lobbyMessageDiv.classList.add("error");
}

function showLobby() {
    gameWrapperDiv.style.display = "none";
    pregameWrapperDiv.style.display = "flex";
    keyDisplayDiv.style.display = "none";
    myColors = [];
    myRole = null;
}

function connect(wsUrl) {
    lobbyMessageDiv.innerText = "";
    lobbyMessageDiv.classList.remove("error");

    socket = new WebSocket(wsUrl);

    socket.onclose = function (event) {
        if (event.code === 4401) {
            location.href = "/login";
            return;
        }
        if (closeErrors[event.code]) showLobbyError(closeErrors[event.code]);
        showLobby();
    };

    socket.onmessage = function (event) {
        const data = JSON.parse(event.data);

        if (data.type === "player") {
            myColors = data.colors;
            myRole = data.role;

            playerDiv.innerText = myRole === "spectator"
                ? "You are spectating"
                : `You are: ${myColors.map(c => COLOR_NAMES[c]).join(" & ")}`;

            pregameWrapperDiv.style.display = "none";
            gameWrapperDiv.style.display = "flex";

            if (data.mode === "private" && data.key) {
                keyDisplayDiv.innerText = `Share this code with friends: "${data.key}"`;
                keyDisplayDiv.style.display = "block";
            } else if (data.mode === "bot" && data.difficulty) {
                const label = data.difficulty.charAt(0).toUpperCase() + data.difficulty.slice(1);
                keyDisplayDiv.innerText = `Playing vs bots (${label})`;
                keyDisplayDiv.style.display = "block";
            } else {
                keyDisplayDiv.style.display = "none";
            }
        }

        if (data.type === "state") {
            renderState(data);
        }
    };
}

document.getElementById("botBtn").addEventListener("click", () => {
    const difficulty = document.getElementById("botDifficulty").value;
    const seats = document.getElementById("seatCount").value;
    connect(`${socketProtocol}://${location.host}/ws/ludo?intent=bot&difficulty=${difficulty}&seats=${seats}`);
});

document.getElementById("randomBtn").addEventListener("click", () => {
    connect(`${socketProtocol}://${location.host}/ws/ludo?intent=random`);
});

const KEY_PATTERN = /^[A-Za-z0-9]{5}$/;

document.getElementById("createBtn").addEventListener("click", () => {
    const key = document.getElementById("createKey").value.trim();
    if (!KEY_PATTERN.test(key)) {
        showLobbyError("Code must be exactly 5 letters/numbers.");
        return;
    }
    connect(`${socketProtocol}://${location.host}/ws/ludo?intent=create&key=${encodeURIComponent(key)}`);
});

document.getElementById("joinBtn").addEventListener("click", () => {
    const key = document.getElementById("joinKey").value.trim();
    if (!KEY_PATTERN.test(key)) {
        showLobbyError("Enter the 5-character code your friend gave you.");
        return;
    }
    connect(`${socketProtocol}://${location.host}/ws/ludo?intent=join&key=${encodeURIComponent(key)}`);
});

// ---------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------
function clearBoard() {
    for (const color of COLORS) {
        tokenEls[color].forEach(el => {
            el.classList.remove("stacked-2", "stacked-3", "stacked-4", "clickable");
        });
    }
}

function renderState(state) {
    clearBoard();

    const myTurn = myRole === "player" && myColors.includes(state.currentColor);
    const canAct = myTurn && state.dice !== null;

    const seenAtCell = {};
    for (const color of COLORS) {
        state.tokens[color].forEach((pos, tokenIndex) => {
            const el = tokenEls[color][tokenIndex];
            const [r, c] = pos === -1 ? YARD_SLOTS[color][tokenIndex] : globalCellFor(color, pos);
            const key = cellKey(r, c);
            const stackIndex = seenAtCell[key] || 0;
            seenAtCell[key] = stackIndex + 1;
            positionToken(el, r, c, stackIndex);

            const clickable = canAct && color === state.currentColor && state.legalTokens.includes(tokenIndex);
            el.classList.toggle("clickable", clickable);
        });
    }

    diceValueDiv.innerText = state.dice !== null ? state.dice : "-";
    rollBtn.disabled = !(myTurn && state.dice === null);
    rollBtn.style.display = myRole === "spectator" ? "none" : "inline-block";

    document.getElementById("scoreR").innerText = state.scores.R;
    document.getElementById("scoreG").innerText = state.scores.G;
    document.getElementById("scoreY").innerText = state.scores.Y;
    document.getElementById("scoreB").innerText = state.scores.B;
    playersConnectedSpan.innerText = state.playersConnected;
    spectatorCountSpan.innerText = state.spectatorCount;

    statusDiv.classList.toggle("your-turn", myTurn);

    if (state.winner) {
        statusDiv.classList.remove("your-turn");
        statusDiv.innerText = `${COLOR_NAMES[state.winner]} wins the round!`;
    } else if (!state.currentColor) {
        statusDiv.innerText = "Waiting for players...";
    } else if (myTurn) {
        statusDiv.innerText = state.dice === null ? `Your turn (${COLOR_NAMES[state.currentColor]}) - roll the dice` : "Your turn - pick a token to move";
    } else {
        statusDiv.innerText = `Current turn: ${COLOR_NAMES[state.currentColor]}`;
    }

    if (state.message) messageDiv.innerText = state.message;

    renderSeatRequestBanner(state);
    renderSpectatorPanel(state);
}

function renderSeatRequestBanner(state) {
    const req = state.seatRequest;

    if (req && myRole === "player" && myColors.includes(req.color)) {
        seatRequestBanner.style.display = "block";
        seatRequestBanner.innerHTML = "";
        const text = document.createElement("div");
        text.innerText = `${req.requesterName} is requesting your ${COLOR_NAMES[req.color]} seat.`;
        seatRequestBanner.appendChild(text);

        const acceptBtn = document.createElement("button");
        acceptBtn.className = "btn-primary";
        acceptBtn.innerText = "Give up seat";
        acceptBtn.onclick = () => respondSeatRequest(true);

        const declineBtn = document.createElement("button");
        declineBtn.className = "btn-secondary";
        declineBtn.innerText = "Keep playing";
        declineBtn.onclick = () => respondSeatRequest(false);

        seatRequestBanner.appendChild(acceptBtn);
        seatRequestBanner.appendChild(declineBtn);
    } else if (req) {
        seatRequestBanner.style.display = "block";
        seatRequestBanner.innerHTML = `<div>${req.requesterName} is requesting ${COLOR_NAMES[req.color]}'s seat...</div>`;
    } else {
        seatRequestBanner.style.display = "none";
        seatRequestBanner.innerHTML = "";
    }
}

function renderSpectatorPanel(state) {
    if (myRole !== "spectator") {
        spectatorPanel.style.display = "none";
        spectatorPanel.innerHTML = "";
        return;
    }

    spectatorPanel.style.display = "block";
    spectatorPanel.innerHTML = "<strong>Request a seat:</strong>";

    state.occupied.forEach(color => {
        const row = document.createElement("div");
        row.className = "seat-request-row";

        const label = document.createElement("span");
        label.innerText = `${COLOR_NAMES[color]}`;
        row.appendChild(label);

        const btn = document.createElement("button");
        btn.className = "btn-primary";
        const alreadyRequested = state.seatRequest && state.seatRequest.color === color;
        btn.innerText = alreadyRequested ? "Requested..." : "Request to Play";
        btn.disabled = !!state.seatRequest;
        btn.onclick = () => requestSeat(color);
        row.appendChild(btn);

        spectatorPanel.appendChild(row);
    });
}

// ---------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------
rollBtn.addEventListener("click", () => {
    socket.send(JSON.stringify({ type: "roll" }));
});

function makeMove(color, tokenIndex) {
    if (myRole !== "player" || !myColors.includes(color)) return;
    socket.send(JSON.stringify({ type: "move", token: tokenIndex }));
}

function requestSeat(color) {
    socket.send(JSON.stringify({ type: "request_seat", color }));
}

function respondSeatRequest(accept) {
    socket.send(JSON.stringify({ type: "respond_seat_request", accept }));
}

function resetGame() {
    socket.send(JSON.stringify({ type: "reset" }));
}

function leaveGame() {
    if (socket) socket.close();
    showLobby();
}

// ---------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------
let statsData = null;

function emptyBucket() { return { games: 0, wins: 0, losses: 0, draws: 0 }; }

function renderStats(selection) {
    let bucket = emptyBucket();
    if (statsData) {
        if (selection === "overall") bucket = statsData.overall;
        else if (selection === "random") bucket = statsData.random;
        else if (selection.startsWith("opponent:")) {
            const index = parseInt(selection.split(":")[1], 10);
            bucket = statsData.opponents[index] || emptyBucket();
        }
    }
    document.getElementById("statGames").innerText = bucket.games;
    document.getElementById("statWins").innerText = bucket.wins;
    document.getElementById("statLosses").innerText = bucket.losses;
    document.getElementById("statDraws").innerText = bucket.draws;
}

async function loadStats() {
    const res = await fetch("/api/ludo/stats");
    if (!res.ok) return;

    statsData = await res.json();

    const select = document.getElementById("statsFilter");
    select.innerHTML = '<option value="overall">All Games</option><option value="random">Random Games</option>';

    statsData.opponents.forEach((opponent, index) => {
        const option = document.createElement("option");
        option.value = `opponent:${index}`;
        option.innerText = opponent.nickname;
        select.appendChild(option);
    });

    renderStats("overall");
}

document.getElementById("statsFilter").addEventListener("change", (event) => {
    renderStats(event.target.value);
});

loadStats();
