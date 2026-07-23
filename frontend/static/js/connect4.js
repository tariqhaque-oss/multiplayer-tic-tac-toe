const ROWS = 6;
const COLS = 7;

const pregameWrapperDiv = document.getElementById("pregameWrapper");
const gameWrapperDiv = document.getElementById("gameWrapper");
const lobbyMessageDiv = document.getElementById("lobbyMessage");
const keyDisplayDiv = document.getElementById("keyDisplay");

const boardDiv = document.getElementById("board");
const statusDiv = document.getElementById("status");
const playerDiv = document.getElementById("player");
const messageDiv = document.getElementById("message");

const scoreR = document.getElementById("scoreR");
const scoreY = document.getElementById("scoreY");
const scoreDraw = document.getElementById("scoreDraw");
const playersConnected = document.getElementById("playersConnected");

let socket = null;
let myPlayer = null;
let currentPlayer = null;
let winner = null;
let previousBoard = [];

const socketProtocol = location.protocol === "https:" ? "wss" : "ws";

const closeErrors = {
    4402: "That code is already in use by another game. Try a different one.",
    4403: "Code must be exactly 5 letters/numbers.",
    4404: "No game found with that code.",
    4405: "That game already has two players.",
    4406: "Invalid bot difficulty."
};

function showLobbyError(text) {
    lobbyMessageDiv.innerText = text;
    lobbyMessageDiv.classList.add("error");
}

function showLobby() {
    gameWrapperDiv.style.display = "none";
    pregameWrapperDiv.style.display = "flex";
    keyDisplayDiv.style.display = "none";
    myPlayer = null;
    previousBoard = [];
}

function connect(wsUrl) {
    lobbyMessageDiv.innerText = "";
    lobbyMessageDiv.classList.remove("error");

    socket = new WebSocket(wsUrl);

    socket.onclose = function(event) {
        if (event.code === 4401) {
            location.href = "/login";
            return;
        }

        if (closeErrors[event.code]) {
            showLobbyError(closeErrors[event.code]);
        }

        showLobby();
    };

    socket.onmessage = function(event) {
        const data = JSON.parse(event.data);

        if (data.type === "player") {
            myPlayer = data.player;
            playerDiv.innerText = `You are: ${myPlayer === "R" ? "Red" : "Yellow"}`;

            pregameWrapperDiv.style.display = "none";
            gameWrapperDiv.style.display = "flex";

            if (data.mode === "private" && data.key) {
                keyDisplayDiv.innerText = `Share this code with your friend: "${data.key}"`;
                keyDisplayDiv.style.display = "block";
            } else if (data.mode === "bot" && data.difficulty) {
                const label = data.difficulty.charAt(0).toUpperCase() + data.difficulty.slice(1);
                keyDisplayDiv.innerText = `Playing vs Bot (${label})`;
                keyDisplayDiv.style.display = "block";
            } else {
                keyDisplayDiv.style.display = "none";
            }
        }

        if (data.type === "state") {
            currentPlayer = data.currentPlayer;
            winner = data.winner;

            renderBoard(data.board);
            renderScores(data.scores, data.playersConnected);

            if (data.message) {
                messageDiv.innerText = data.message;
            }
        }
    };
}

document.getElementById("botBtn").addEventListener("click", () => {
    const difficulty = document.getElementById("botDifficulty").value;
    connect(`${socketProtocol}://${location.host}/ws/connect4?intent=bot&difficulty=${difficulty}`);
});

document.getElementById("randomBtn").addEventListener("click", () => {
    connect(`${socketProtocol}://${location.host}/ws/connect4?intent=random`);
});

const KEY_PATTERN = /^[A-Za-z0-9]{5}$/;

document.getElementById("createBtn").addEventListener("click", () => {
    const key = document.getElementById("createKey").value.trim();

    if (!KEY_PATTERN.test(key)) {
        showLobbyError("Code must be exactly 5 letters/numbers.");
        return;
    }

    connect(`${socketProtocol}://${location.host}/ws/connect4?intent=create&key=${encodeURIComponent(key)}`);
});

document.getElementById("joinBtn").addEventListener("click", () => {
    const key = document.getElementById("joinKey").value.trim();

    if (!KEY_PATTERN.test(key)) {
        showLobbyError("Enter the 5-character code your friend gave you.");
        return;
    }

    connect(`${socketProtocol}://${location.host}/ws/connect4?intent=join&key=${encodeURIComponent(key)}`);
});

function findWinningLine(board) {
    for (let r = 0; r < ROWS; r++) {
        for (let c = 0; c < COLS; c++) {
            const symbol = board[r * COLS + c];
            if (!symbol) continue;

            if (c + 3 < COLS && [0, 1, 2, 3].every(i => board[r * COLS + (c + i)] === symbol)) {
                return [0, 1, 2, 3].map(i => r * COLS + (c + i));
            }
            if (r + 3 < ROWS && [0, 1, 2, 3].every(i => board[(r + i) * COLS + c] === symbol)) {
                return [0, 1, 2, 3].map(i => (r + i) * COLS + c);
            }
            if (r + 3 < ROWS && c + 3 < COLS && [0, 1, 2, 3].every(i => board[(r + i) * COLS + (c + i)] === symbol)) {
                return [0, 1, 2, 3].map(i => (r + i) * COLS + (c + i));
            }
            if (r + 3 < ROWS && c - 3 >= 0 && [0, 1, 2, 3].every(i => board[(r + i) * COLS + (c - i)] === symbol)) {
                return [0, 1, 2, 3].map(i => (r + i) * COLS + (c - i));
            }
        }
    }
    return [];
}

function columnIsFull(board, col) {
    return board[col] !== "";
}

function renderBoard(board) {
    boardDiv.innerHTML = "";

    const winningLine = winner && winner !== "Draw" ? findWinningLine(board) : [];
    const canPlay = myPlayer === currentPlayer && !winner;

    board.forEach((cell, index) => {
        const col = index % COLS;
        const btn = document.createElement("button");

        btn.className = "cell";
        btn.disabled = !canPlay || columnIsFull(board, col);

        if (cell) {
            btn.dataset.value = cell;

            if (previousBoard[index] !== cell) {
                btn.classList.add("mark-in");
            }
        }

        if (winningLine.includes(index)) {
            btn.classList.add("win");
        }

        btn.setAttribute("aria-label", cell ? `Column ${col + 1}: ${cell === "R" ? "Red" : "Yellow"}` : `Column ${col + 1}: empty`);
        btn.onclick = () => makeMove(col);

        boardDiv.appendChild(btn);
    });

    previousBoard = board.slice();

    statusDiv.classList.toggle("your-turn", canPlay);

    if (winner) {
        statusDiv.classList.remove("your-turn");
        if (winner === "Draw") {
            statusDiv.innerText = "Round draw!";
        } else {
            statusDiv.innerText = `${winner === "R" ? "Red" : "Yellow"} wins round!`;
        }
    } else {
        statusDiv.innerText = `Current turn: ${currentPlayer === "R" ? "Red" : "Yellow"}`;
    }
}

function renderScores(scores, count) {
    scoreR.innerText = scores.R;
    scoreY.innerText = scores.Y;
    scoreDraw.innerText = scores.Draw;
    playersConnected.innerText = count;
}

function makeMove(column) {
    if (myPlayer !== currentPlayer) {
        messageDiv.innerText = "Not your turn";
        return;
    }

    socket.send(JSON.stringify({
        type: "move",
        column: column
    }));
}

function resetGame() {
    socket.send(JSON.stringify({
        type: "reset"
    }));
}

function leaveGame() {
    if (socket) {
        socket.close();
    }
    showLobby();
}

let statsData = null;

function emptyBucket() {
    return { games: 0, wins: 0, losses: 0, draws: 0 };
}

function renderStats(selection) {
    let bucket = emptyBucket();

    if (statsData) {
        if (selection === "overall") {
            bucket = statsData.overall;
        } else if (selection === "random") {
            bucket = statsData.random;
        } else if (selection.startsWith("opponent:")) {
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
    const res = await fetch("/api/connect4/stats");
    if (!res.ok) {
        return;
    }

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
