// Court Piece UI controller - talks to backend/court_piece.py over
// WebSocket. The server is authoritative for all rules and deals; this
// file only renders whatever state it's sent and forwards clicks. Unlike
// the earlier client-only version, fog-of-war is enforced by the SERVER
// now (myHands only ever contains this connection's own seat(s) - other
// seats arrive as a bare card count, never real card data).
(function () {
    "use strict";

    const SEATS = ["P1", "P2", "P3", "P4"];
    const SEAT_POSITION_LABEL = { P1: "bottom", P2: "left", P3: "top", P4: "right" };
    const SEAT_TEAM = { P1: "A", P3: "A", P2: "B", P4: "B" };

    let socket = null;
    let mySeats = [];
    let myRole = null; // "player" | "spectator"
    let lastState = null;

    // ------------------------------------------------------------------
    // DOM refs
    // ------------------------------------------------------------------
    const configScreen = document.getElementById("configScreen");
    const tableScreen = document.getElementById("tableScreen");
    const configMessage = document.getElementById("configMessage");
    const commentaryFeed = document.getElementById("commentaryFeed");

    function logEvent(text) {
        if (!text) return;
        const line = document.createElement("div");
        line.textContent = text;
        commentaryFeed.appendChild(line);
        commentaryFeed.scrollTop = commentaryFeed.scrollHeight;
    }

    function suitName(suit) {
        return { "♠": "Spades", "♥": "Hearts", "♦": "Diamonds", "♣": "Clubs" }[suit] || suit;
    }

    function seatLabelText(seat, state) {
        const name = state.seatNames[seat];
        if (!state.occupied.includes(seat)) return "Waiting...";
        return name || seat;
    }

    // ==================================================================
    // Configuration screen
    // ==================================================================
    document.getElementById("startBotBtn").addEventListener("click", () => {
        connect(`/ws/court-piece?intent=bot&team=${document.getElementById("botTeam").value}`);
    });

    document.getElementById("randomBtn").addEventListener("click", () => {
        connect("/ws/court-piece?intent=random");
    });

    const KEY_PATTERN = /^[A-Za-z0-9]{5}$/;

    document.getElementById("createBtn").addEventListener("click", () => {
        const key = document.getElementById("createKey").value.trim();
        if (!KEY_PATTERN.test(key)) {
            showConfigError("Code must be exactly 5 letters/numbers.");
            return;
        }
        connect(`/ws/court-piece?intent=create&key=${encodeURIComponent(key)}`);
    });

    document.getElementById("joinBtn").addEventListener("click", () => {
        const key = document.getElementById("joinKey").value.trim();
        if (!KEY_PATTERN.test(key)) {
            showConfigError("Enter the 5-character code your friend gave you.");
            return;
        }
        connect(`/ws/court-piece?intent=join&key=${encodeURIComponent(key)}`);
    });

    function showConfigError(text) {
        configMessage.textContent = text;
    }

    const closeErrors = {
        4402: "That code is already in use by another game. Try a different one.",
        4403: "Code must be exactly 5 letters/numbers.",
        4404: "No game found with that code.",
        4405: "That random game is already full. Try again to join/create another.",
        4407: "Invalid seat selection.",
    };

    function connect(path) {
        configMessage.textContent = "";
        const protocol = location.protocol === "https:" ? "wss" : "ws";
        socket = new WebSocket(`${protocol}://${location.host}${path}`);

        socket.onclose = (event) => {
            if (event.code === 4401) {
                location.href = "/login.html";
                return;
            }
            if (closeErrors[event.code]) {
                showConfigError(closeErrors[event.code]);
            }
            showConfigScreen();
        };

        socket.onmessage = (event) => {
            const data = JSON.parse(event.data);
            if (data.type === "player") {
                mySeats = data.seats;
                myRole = data.role;
                onEnterTable(data);
            } else if (data.type === "state") {
                onState(data);
            }
        };
    }

    function showConfigScreen() {
        tableScreen.style.display = "none";
        configScreen.style.display = "flex";
        mySeats = [];
        myRole = null;
        lastState = null;
    }

    function onEnterTable(playerMsg) {
        configScreen.style.display = "none";
        tableScreen.style.display = "block";

        const roomCodeDisplay = document.getElementById("roomCodeDisplay");
        if (playerMsg.mode === "private" && playerMsg.key) {
            roomCodeDisplay.style.display = "block";
            roomCodeDisplay.textContent = `Room code: ${playerMsg.key}`;
        } else {
            roomCodeDisplay.style.display = "none";
        }

        if (myRole === "spectator") {
            logEvent("You are spectating.");
        } else {
            logEvent(`You are: ${mySeats.join(" & ")}`);
        }
    }

    document.getElementById("leaveGameBtn").addEventListener("click", () => {
        if (socket) socket.close();
        showConfigScreen();
    });

    // ==================================================================
    // Trump selection
    // ==================================================================
    const trumpModal = document.getElementById("trumpModal");

    document.querySelectorAll(".cp-suit-choice").forEach(btn => {
        btn.addEventListener("click", () => {
            trumpModal.style.display = "none";
            socket.send(JSON.stringify({ type: "choose_trump", suit: btn.dataset.suit }));
        });
    });

    // ==================================================================
    // Round over
    // ==================================================================
    const roundOverModal = document.getElementById("roundOverModal");
    let lastAnnouncedWinner = null;

    document.getElementById("roundOverCloseBtn").addEventListener("click", () => {
        roundOverModal.style.display = "none";
    });

    document.getElementById("newRoundBtn").addEventListener("click", () => {
        socket.send(JSON.stringify({ type: "next_round" }));
    });

    // ==================================================================
    // Leave table / spectator requests
    // ==================================================================
    document.getElementById("leaveTableBtn").addEventListener("click", () => {
        socket.send(JSON.stringify({ type: "leave_table" }));
    });

    const seatRequestModal = document.getElementById("seatRequestModal");
    let shownRequestKey = null;

    document.getElementById("seatRequestAcceptBtn").addEventListener("click", () => {
        seatRequestModal.style.display = "none";
        shownRequestKey = null;
        socket.send(JSON.stringify({ type: "respond_seat_request", accept: true }));
    });
    document.getElementById("seatRequestDeclineBtn").addEventListener("click", () => {
        seatRequestModal.style.display = "none";
        shownRequestKey = null;
        socket.send(JSON.stringify({ type: "respond_seat_request", accept: false }));
    });

    // ==================================================================
    // State handling
    // ==================================================================
    function onState(state) {
        lastState = state;
        logEvent(state.message);
        renderAll(state);

        if (state.phase === "trump-selection" && mySeats.some(s => state.legalForMe[s] === "choose_trump")) {
            const caller = state.trumpCallerSeat;
            document.getElementById("trumpModalTitle").textContent = `${caller}: Choose Trump Suit`;
            trumpModal.style.display = "flex";
        } else {
            trumpModal.style.display = "none";
        }

        if (state.winner && state.winner !== lastAnnouncedWinner) {
            lastAnnouncedWinner = state.winner;
            document.getElementById("roundOverTitle").textContent = `Team ${state.winner} Wins the Round!`;
            document.getElementById("roundOverDetail").textContent =
                `10s captured - Team A: ${state.tensCollected.A}, Team B: ${state.tensCollected.B}. ` +
                `Tricks won - Team A: ${state.trickWins.A}, Team B: ${state.trickWins.B}. ` +
                `Match score - Team A: ${state.matchScore.A}, Team B: ${state.matchScore.B}.`;
            roundOverModal.style.display = "flex";
            document.getElementById("newRoundBtn").style.display = myRole === "player" ? "inline-block" : "none";
        } else if (!state.winner) {
            lastAnnouncedWinner = null;
            document.getElementById("newRoundBtn").style.display = "none";
        }

        handleSeatRequestBanner(state);
    }

    // ==================================================================
    // Rendering
    // ==================================================================
    function makeCardEl(card, faceUp, clickable, mini) {
        const div = document.createElement("div");
        div.className = "cp-card" + (mini ? " cp-mini" : "");
        if (!faceUp) {
            div.classList.add("cp-back");
            return div;
        }
        div.classList.add(card.color === "red" ? "cp-red" : "cp-black");
        div.innerHTML = `<div class="cp-rank">${card.rank}</div><div class="cp-suit">${card.suit}</div>`;
        if (clickable) {
            div.classList.add("cp-legal");
            div.addEventListener("click", clickable);
        }
        return div;
    }

    function cardKey(card) {
        return card.suit + card.rank;
    }

    function renderAll(state) {
        renderSeatLabels(state);
        renderHands(state);
        renderCenterPile(state);
        renderInfoPanel(state);
        renderControls(state);
        renderSpectatorSidebar(state);
    }

    function renderSeatLabels(state) {
        for (const seatEl of document.querySelectorAll(".cp-seat")) {
            const seat = seatEl.dataset.seat;
            const label = document.getElementById("label-" + seat);
            const isMine = mySeats.includes(seat);
            const roleTag = state.occupied.includes(seat) ? (isMine ? "[YOU]" : "[PLAYER]") : "";
            label.innerHTML = `${seatLabelText(seat, state)} <span class="cp-role">${roleTag} ${seat} (${SEAT_POSITION_LABEL[seat]}) - Team ${SEAT_TEAM[seat]}</span>`;
            seatEl.classList.toggle("cp-active-turn", state.currentTurnSeat === seat);
        }
    }

    function renderHands(state) {
        for (const seat of SEATS) {
            const container = document.getElementById("hand-" + seat);
            container.innerHTML = "";

            if (mySeats.includes(seat) && state.myHands[seat]) {
                const hand = state.myHands[seat];
                const legal = Array.isArray(state.legalForMe[seat]) ? state.legalForMe[seat] : [];
                hand.forEach(card => {
                    const isLegal = legal.some(c => cardKey(c) === cardKey(card));
                    const handler = isLegal ? () => playCard(seat, card) : null;
                    container.appendChild(makeCardEl(card, true, handler, false));
                });
            } else {
                const count = state.handCounts[seat] || 0;
                for (let i = 0; i < count; i++) {
                    container.appendChild(makeCardEl(null, false, null, false));
                }
            }
        }
    }

    function playCard(seat, card) {
        if (!mySeats.includes(seat)) return;
        socket.send(JSON.stringify({ type: "play_card", card }));
    }

    function renderCenterPile(state) {
        const pile = document.getElementById("centerPile");
        pile.innerHTML = "";

        if (state.currentTrick && state.currentTrick.length) {
            state.currentTrick.forEach(play => {
                pile.appendChild(makeCardEl(play.card, true, null, true));
            });
        } else {
            for (let i = 0; i < Math.min(state.pendingPileTricks || 0, 6); i++) {
                pile.appendChild(makeCardEl(null, false, null, true));
            }
        }
    }

    function renderInfoPanel(state) {
        document.getElementById("trumpDisplay").textContent = state.trumpSuit
            ? `${state.trumpSuit} ${suitName(state.trumpSuit)}` : "Not yet chosen";

        document.getElementById("lastTrickDisplay").textContent = state.lastTrickWinnerSeat
            ? `${seatLabelText(state.lastTrickWinnerSeat, state)} (${state.lastTrickWinnerSeat})` : "-";

        document.getElementById("pileDisplay").textContent = `${state.pendingPileTricks || 0} trick(s) uncollected`;

        document.getElementById("scoreA").textContent = state.tensCollected.A;
        document.getElementById("scoreB").textContent = state.tensCollected.B;
        document.getElementById("tricksA").textContent = state.trickWins.A;
        document.getElementById("tricksB").textContent = state.trickWins.B;
        document.getElementById("matchScoreDisplay").textContent =
            `Match score - Team A: ${state.matchScore.A}, Team B: ${state.matchScore.B}`;
    }

    function renderControls(state) {
        const leaveTableBtn = document.getElementById("leaveTableBtn");
        leaveTableBtn.style.display = (myRole === "player") ? "inline-block" : "none";
    }

    // ==================================================================
    // Spectator sidebar + seat requests
    // ==================================================================
    const spectatorSidebar = document.getElementById("spectatorSidebar");
    const requestSeatRow = document.getElementById("requestSeatRow");

    function renderSpectatorSidebar(state) {
        if (myRole !== "spectator") {
            spectatorSidebar.style.display = "none";
            return;
        }
        spectatorSidebar.style.display = "block";

        const list = document.getElementById("spectatorList");
        list.innerHTML = `<div class="hint">Spectator count: ${state.spectatorCount}</div>`;

        requestSeatRow.style.display = "block";
        requestSeatRow.innerHTML = "<strong>Request a seat:</strong><br>";
        state.occupied.forEach(seat => {
            const btn = document.createElement("button");
            btn.className = "btn-secondary";
            btn.style.cssText = "width:auto; margin:4px 4px 0 0; padding:5px 10px; font-size:12px;";
            const alreadyRequested = state.seatRequest && state.seatRequest.seat === seat;
            btn.textContent = alreadyRequested ? `${seat} (requested...)` : `Request ${seat}`;
            btn.disabled = !!state.seatRequest;
            btn.addEventListener("click", () => {
                socket.send(JSON.stringify({ type: "request_seat", seat }));
            });
            requestSeatRow.appendChild(btn);
        });
    }

    function handleSeatRequestBanner(state) {
        const req = state.seatRequest;
        if (!req) {
            seatRequestModal.style.display = "none";
            shownRequestKey = null;
            return;
        }
        if (myRole !== "player" || !mySeats.includes(req.seat)) return;

        const key = req.seat + ":" + req.requesterName;
        if (shownRequestKey === key) return;
        shownRequestKey = key;

        document.getElementById("seatRequestText").textContent =
            `${req.requesterName} is requesting your seat (${req.seat}). Give it up?`;
        seatRequestModal.style.display = "flex";
    }
})();
