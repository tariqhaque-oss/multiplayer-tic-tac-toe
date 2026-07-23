// Court Piece UI controller - wires CourtPieceEngine (rules/AI) and
// CourtPieceRoom (mock online lobby) to the DOM. No game rules live here;
// this file only renders state and dispatches user actions.
(function () {
    "use strict";

    const SEATS = ["P1", "P2", "P3", "P4"];
    const SEAT_POSITION_LABEL = { P1: "bottom", P2: "left", P3: "top", P4: "right" };

    let mode = null;           // "local" | "online"
    let room = null;           // CourtPieceRoom state, online mode only
    let seatMeta = {};         // seat -> {type:'human'|'bot'|'guest', isYou, name}
    let roundState = null;     // CourtPieceEngine round state
    let trumpCallerSeat = "P1";
    let matchScore = { A: 0, B: 0 };

    // ------------------------------------------------------------------
    // DOM refs
    // ------------------------------------------------------------------
    const configScreen = document.getElementById("configScreen");
    const tableScreen = document.getElementById("tableScreen");
    const configMessage = document.getElementById("configMessage");
    const commentaryFeed = document.getElementById("commentaryFeed");

    function logEvent(text) {
        const line = document.createElement("div");
        line.textContent = text;
        commentaryFeed.appendChild(line);
        commentaryFeed.scrollTop = commentaryFeed.scrollHeight;
    }

    function seatLabel(seat) {
        const meta = seatMeta[seat];
        const name = meta ? meta.name : seat;
        return `${name} (${seat})`;
    }

    function cardText(card) {
        return `${card.rank} of ${suitName(card.suit)}`;
    }

    function suitName(suit) {
        return { "♠": "Spades", "♥": "Hearts", "♦": "Diamonds", "♣": "Clubs" }[suit] || suit;
    }

    // ==================================================================
    // Configuration screen
    // ==================================================================
    const modeLocalBtn = document.getElementById("modeLocalBtn");
    const modeOnlineBtn = document.getElementById("modeOnlineBtn");
    const localConfig = document.getElementById("localConfig");
    const onlineConfig = document.getElementById("onlineConfig");

    modeLocalBtn.addEventListener("click", () => setConfigMode("local"));
    modeOnlineBtn.addEventListener("click", () => setConfigMode("online"));

    function setConfigMode(m) {
        mode = m;
        modeLocalBtn.classList.toggle("active", m === "local");
        modeOnlineBtn.classList.toggle("active", m === "online");
        localConfig.style.display = m === "local" ? "block" : "none";
        onlineConfig.style.display = m === "online" ? "block" : "none";
        configMessage.textContent = "";
    }
    setConfigMode("local");

    // --- Local seat presets ---
    const onePresetSeat = document.getElementById("onePresetSeat");
    const partnershipPresetTeam = document.getElementById("partnershipPresetTeam");
    const seatPreview = document.getElementById("seatPreview");

    function currentPresetSeats() {
        const preset = document.querySelector('input[name="seatPreset"]:checked').value;
        if (preset === "one") return [onePresetSeat.value];
        if (preset === "partnership") return partnershipPresetTeam.value === "A" ? ["P1", "P3"] : ["P2", "P4"];
        return [];
    }

    function renderSeatPreview() {
        const humanSeatsPreview = currentPresetSeats();
        seatPreview.innerHTML = "";
        for (const seat of SEATS) {
            const div = document.createElement("div");
            const isHuman = humanSeatsPreview.includes(seat);
            div.textContent = `${seat} (${SEAT_POSITION_LABEL[seat]}): ${isHuman ? "HUMAN (you)" : "BOT"}`;
            if (isHuman) div.classList.add("is-human");
            seatPreview.appendChild(div);
        }
    }

    document.querySelectorAll('input[name="seatPreset"]').forEach(r => r.addEventListener("change", renderSeatPreview));
    onePresetSeat.addEventListener("change", renderSeatPreview);
    partnershipPresetTeam.addEventListener("change", renderSeatPreview);
    renderSeatPreview();

    document.getElementById("startLocalBtn").addEventListener("click", () => {
        const humanSeatsList = currentPresetSeats();
        seatMeta = {};
        for (const seat of SEATS) {
            seatMeta[seat] = humanSeatsList.includes(seat)
                ? { type: "human", isYou: true, name: "You" }
                : { type: "bot", isYou: false, name: "Bot" };
        }
        beginTableSession();
    });

    // --- Online room ---
    document.getElementById("createRoomBtn").addEventListener("click", () => {
        const seat = "P1"; // human always seated first in a freshly created room
        room = CourtPieceRoom.createRoom(seat);
        room.onChange = onRoomChange;
        syncSeatMetaFromRoom();
        beginTableSession();
        logEvent(`Room created. Code: ${room.code}. Share it so others can join.`);
    });

    document.getElementById("joinRoomBtn").addEventListener("click", () => {
        const code = document.getElementById("joinRoomCode").value.trim();
        if (!/^\d{4}$/.test(code)) {
            configMessage.textContent = "Enter the 4-digit room code.";
            return;
        }
        const { room: joinedRoom } = CourtPieceRoom.joinRoom(code);
        room = joinedRoom;
        room.onChange = onRoomChange;
        syncSeatMetaFromRoom();
        beginTableSession();
        logEvent(`Joined room ${room.code}.`);
    });

    function syncSeatMetaFromRoom() {
        seatMeta = {};
        for (const seat of SEATS) {
            const s = room.seats[seat];
            seatMeta[seat] = s ? { type: s.type, isYou: s.isYou, name: s.name } : null;
        }
    }

    function onRoomChange(reason) {
        syncSeatMetaFromRoom();
        describeRoomEvent(reason);
        renderSeatLabels();
        renderSpectatorSidebar();
        renderControls();
        maybeStartRoundWhenTableFull();
        maybeShowIncomingSeatRequest();
    }

    function describeRoomEvent(reason) {
        const [kind, ...rest] = reason.split(":");
        if (kind === "guest-joined-seat") {
            logEvent(`Room Update: ${rest[1]} joined the table as ${rest[0]}.`);
        } else if (kind === "guest-joined-spectator") {
            logEvent(`Room Update: ${rest[0]} joined as a spectator.`);
        } else if (kind === "seat-requested") {
            logEvent(`Room Update: Spectator '${rest[1]}' has requested to take ${rest[0]}'s seat.`);
        } else if (kind === "request-declined") {
            logEvent(`Room Update: ${rest[1]}'s request for ${rest[0]} was declined.`);
        } else if (kind === "seat-transferred") {
            logEvent(`Room Update: ${rest[1]} took over ${rest[0]}'s seat from ${rest[2]}.`);
        } else if (kind === "left-table") {
            logEvent(`Room Update: ${rest[1]} left ${rest[0]}` + (rest[2] === "promoted" ? ` - ${rest[3]} promoted from the spectator queue.` : "."));
        }
    }

    function maybeStartRoundWhenTableFull() {
        if (roundState) return; // already playing
        if (SEATS.every(s => seatMeta[s])) {
            beginRound();
        }
    }

    // ==================================================================
    // Starting a session
    // ==================================================================
    function beginTableSession() {
        configScreen.style.display = "none";
        tableScreen.style.display = "block";
        commentaryFeed.innerHTML = "";
        matchScore = { A: 0, B: 0 };
        trumpCallerSeat = "P1";

        const roomCodeDisplay = document.getElementById("roomCodeDisplay");
        if (mode === "online") {
            roomCodeDisplay.style.display = "inline-block";
            roomCodeDisplay.textContent = `Room: ${room.code}`;
        } else {
            roomCodeDisplay.style.display = "none";
        }

        renderSeatLabels();
        renderSpectatorSidebar();
        renderControls();

        if (mode === "local" || SEATS.every(s => seatMeta[s])) {
            beginRound();
        } else {
            logEvent("Waiting for the table to fill...");
            renderHands();
        }
    }

    function beginRound() {
        roundState = CourtPieceEngine.createRound(trumpCallerSeat);
        CourtPieceEngine.dealFirstFive(roundState);
        logEvent(`New round dealt. ${seatLabel(trumpCallerSeat)} is Eldest Hand and must call trump.`);
        renderAll();
        startTrumpSelection();
    }

    // ==================================================================
    // Trump selection
    // ==================================================================
    const trumpModal = document.getElementById("trumpModal");

    function startTrumpSelection() {
        const caller = roundState.trumpCallerSeat;
        if (isLocalHumanSeat(caller)) {
            document.getElementById("trumpModalTitle").textContent = `${seatLabel(caller)}: Choose Trump Suit`;
            trumpModal.style.display = "flex";
        } else {
            setTimeout(() => {
                const suit = CourtPieceEngine.chooseBotTrump(roundState.hands[caller]);
                finalizeTrump(suit);
            }, 700);
        }
    }

    document.querySelectorAll(".cp-suit-choice").forEach(btn => {
        btn.addEventListener("click", () => {
            trumpModal.style.display = "none";
            finalizeTrump(btn.dataset.suit);
        });
    });

    function finalizeTrump(suit) {
        CourtPieceEngine.dealRemaining(roundState, suit);
        logEvent(`${seatLabel(roundState.trumpCallerSeat)} called ${suitName(suit)} (${suit}) as trump. Remaining cards dealt - 13 each.`);
        renderAll();
        advanceTurn();
    }

    // ==================================================================
    // Turn loop
    // ==================================================================
    function advanceTurn() {
        if (roundState.phase === "round-over") {
            finishRound();
            return;
        }
        const seat = CourtPieceEngine.currentTurnSeat(roundState);
        renderAll();

        if (isLocalHumanSeat(seat)) {
            return; // wait for a manual card click
        }

        setTimeout(() => {
            const hand = roundState.hands[seat];
            const card = CourtPieceEngine.chooseBotCard(hand, roundState);
            playCardFlow(seat, card);
        }, 550 + Math.random() * 450);
    }

    function playCardFlow(seat, card) {
        const result = CourtPieceEngine.playCard(roundState, seat, card);
        logEvent(`${seatLabel(seat)} played ${cardText(card)}.`);

        if (result.trickCompleted) {
            const winner = result.trickWinnerSeat;
            logEvent(`${seatLabel(winner)} won the trick.` + (result.collected
                ? " Back-to-back win - the team collects the pile!"
                : " Pile stays face-down (no back-to-back win yet)."));
        }

        renderAll();

        if (result.roundCompleted) {
            setTimeout(finishRound, 900);
            return;
        }

        setTimeout(advanceTurn, result.trickCompleted ? 750 : 150);
    }

    function onCardClick(seat, card) {
        if (roundState.phase !== "playing") return;
        if (!isLocalHumanSeat(seat)) return;
        if (CourtPieceEngine.currentTurnSeat(roundState) !== seat) return;
        if (!CourtPieceEngine.isLegalMove(roundState.hands[seat], roundState.ledSuit, card)) return;
        playCardFlow(seat, card);
    }

    // ==================================================================
    // Round over
    // ==================================================================
    const roundOverModal = document.getElementById("roundOverModal");

    function finishRound() {
        const winnerTeam = roundState.winner;
        matchScore[winnerTeam]++;
        const tensA = CourtPieceEngine.countTens(roundState.collected.A);
        const tensB = CourtPieceEngine.countTens(roundState.collected.B);

        document.getElementById("roundOverTitle").textContent = `Team ${winnerTeam} Wins the Round!`;
        document.getElementById("roundOverDetail").textContent =
            `10s captured - Team A: ${tensA}, Team B: ${tensB}. Tricks won - Team A: ${roundState.trickWins.A}, Team B: ${roundState.trickWins.B}. ` +
            `Match score - Team A: ${matchScore.A}, Team B: ${matchScore.B}.`;
        roundOverModal.style.display = "flex";

        logEvent(`Round over: Team ${winnerTeam} wins (10s ${tensA}-${tensB}, tricks ${roundState.trickWins.A}-${roundState.trickWins.B}).`);

        document.getElementById("newRoundBtn").style.display = "inline-block";
        trumpCallerSeat = CourtPieceEngine.nextSeat(trumpCallerSeat);
        renderAll();
    }

    document.getElementById("roundOverCloseBtn").addEventListener("click", () => {
        roundOverModal.style.display = "none";
    });

    document.getElementById("newRoundBtn").addEventListener("click", () => {
        document.getElementById("newRoundBtn").style.display = "none";
        beginRound();
    });

    // ==================================================================
    // Fog-of-war / seat control helpers
    // ==================================================================
    function isLocalHumanSeat(seat) {
        return !!(seatMeta[seat] && seatMeta[seat].isYou);
    }

    function countLocalHumanSeats() {
        return SEATS.filter(isLocalHumanSeat).length;
    }

    function activeSeatForVisibility() {
        if (!roundState) return null;
        if (roundState.phase === "trump-selection") return roundState.trumpCallerSeat;
        if (roundState.phase === "playing") return CourtPieceEngine.currentTurnSeat(roundState);
        return null;
    }

    function isHandVisible(seat) {
        if (!isLocalHumanSeat(seat)) return false;
        if (countLocalHumanSeats() <= 1) return true;
        return activeSeatForVisibility() === seat;
    }

    // ==================================================================
    // Rendering
    // ==================================================================
    function renderAll() {
        renderSeatLabels();
        renderHands();
        renderCenterPile();
        renderInfoPanel();
        renderControls();
    }

    function renderSeatLabels() {
        const activeSeat = activeSeatForVisibility();
        for (const seat of SEATS) {
            const el = document.getElementById("label-" + seat);
            const meta = seatMeta[seat];
            const seatEl = document.querySelector(`.cp-seat[data-seat="${seat}"]`);
            if (!meta) {
                const text = roundState ? "Unmanned - auto-playing" : "Waiting...";
                el.innerHTML = `${text} <span class="cp-role">[BOT] - ${SEAT_POSITION_LABEL[seat]}</span>`;
                seatEl.classList.toggle("cp-active-turn", roundState && seat === activeSeat);
                continue;
            }
            const roleTag = meta.type === "human" ? "[HUMAN]" : "[BOT]";
            el.innerHTML = `${meta.name} <span class="cp-role">${roleTag} - ${SEAT_POSITION_LABEL[seat]}</span>`;
            seatEl.classList.toggle("cp-active-turn", roundState && seat === activeSeat);
        }
    }

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

    function renderHands() {
        if (!roundState) {
            for (const seat of SEATS) document.getElementById("hand-" + seat).innerHTML = "";
            return;
        }

        const turnSeat = roundState.phase === "playing" ? CourtPieceEngine.currentTurnSeat(roundState) : null;

        for (const seat of SEATS) {
            const container = document.getElementById("hand-" + seat);
            container.innerHTML = "";
            const hand = roundState.hands[seat];
            const visible = isHandVisible(seat);
            const legal = visible && turnSeat === seat
                ? CourtPieceEngine.legalMoves(hand, roundState.ledSuit)
                : [];

            hand.forEach(card => {
                const isLegal = legal.some(c => CourtPieceEngine.cardKey(c) === CourtPieceEngine.cardKey(card));
                const clickHandler = isLegal ? () => onCardClick(seat, card) : null;
                container.appendChild(makeCardEl(card, visible, clickHandler, false));
            });
        }
    }

    function renderCenterPile() {
        const pile = document.getElementById("centerPile");
        pile.innerHTML = "";
        if (!roundState) return;

        if (roundState.currentTrick.length) {
            roundState.currentTrick.forEach(play => {
                const el = makeCardEl(play.card, true, null, true);
                pile.appendChild(el);
            });
        } else {
            const stacked = roundState.pendingPile.length / 4;
            for (let i = 0; i < Math.min(stacked, 6); i++) {
                pile.appendChild(makeCardEl(null, false, null, true));
            }
        }
    }

    function renderInfoPanel() {
        document.getElementById("trumpDisplay").textContent = roundState && roundState.trumpSuit
            ? `${roundState.trumpSuit} ${suitName(roundState.trumpSuit)}`
            : "Not yet chosen";

        document.getElementById("lastTrickDisplay").textContent = roundState && roundState.lastTrickInfo
            ? `${seatLabel(roundState.lastTrickInfo.winnerSeat)}`
            : "-";

        const pileTricks = roundState ? roundState.pendingPile.length / 4 : 0;
        document.getElementById("pileDisplay").textContent = `${pileTricks} trick(s) uncollected`;

        const tensA = roundState ? CourtPieceEngine.countTens(roundState.collected.A) : 0;
        const tensB = roundState ? CourtPieceEngine.countTens(roundState.collected.B) : 0;
        document.getElementById("scoreA").textContent = tensA;
        document.getElementById("scoreB").textContent = tensB;
        document.getElementById("tricksA").textContent = roundState ? roundState.trickWins.A : 0;
        document.getElementById("tricksB").textContent = roundState ? roundState.trickWins.B : 0;
    }

    function renderControls() {
        const leaveTableBtn = document.getElementById("leaveTableBtn");
        if (mode !== "online" || !room) {
            leaveTableBtn.style.display = "none";
            return;
        }
        const yourSeat = SEATS.find(s => seatMeta[s] && seatMeta[s].isYou);
        leaveTableBtn.style.display = yourSeat ? "inline-block" : "none";
    }

    document.getElementById("leaveTableBtn").addEventListener("click", () => {
        const yourSeat = SEATS.find(s => seatMeta[s] && seatMeta[s].isYou);
        if (!yourSeat || !room) return;
        CourtPieceRoom.leaveTable(room, yourSeat);
    });

    document.getElementById("leaveGameBtn").addEventListener("click", () => {
        if (room) CourtPieceRoom.teardown(room);
        room = null;
        roundState = null;
        seatMeta = {};
        tableScreen.style.display = "none";
        configScreen.style.display = "flex";
        configMessage.textContent = "";
    });

    // ==================================================================
    // Spectator sidebar (online mode)
    // ==================================================================
    const spectatorSidebar = document.getElementById("spectatorSidebar");
    const spectatorList = document.getElementById("spectatorList");
    const requestAnySeatBtn = document.getElementById("requestAnySeatBtn");

    function renderSpectatorSidebar() {
        if (mode !== "online" || !room) {
            spectatorSidebar.style.display = "none";
            return;
        }
        spectatorSidebar.style.display = "block";
        spectatorList.innerHTML = "";

        if (room.spectators.length === 0) {
            spectatorList.innerHTML = '<div class="hint">No spectators yet.</div>';
        }

        room.spectators.forEach(spec => {
            const row = document.createElement("div");
            row.className = "cp-spectator-row";
            row.innerHTML = `<span>${spec.name}${spec.isYou ? " (you)" : ""}</span>`;
            spectatorList.appendChild(row);
        });

        const youAreSpectating = room.spectators.some(s => s.isYou);
        if (youAreSpectating) {
            requestAnySeatBtn.style.display = "block";
            renderRequestSeatChoices();
        } else {
            requestAnySeatBtn.style.display = "none";
        }
    }

    function renderRequestSeatChoices() {
        requestAnySeatBtn.innerHTML = "Request: ";
        SEATS.forEach(seat => {
            if (!room.seats[seat]) return;
            const btn = document.createElement("button");
            btn.className = "btn-secondary";
            btn.style.cssText = "width:auto; margin:2px; padding:4px 8px; font-size:11px;";
            btn.textContent = seat;
            btn.disabled = !!room.pendingRequest;
            btn.addEventListener("click", () => {
                const you = room.spectators.find(s => s.isYou);
                if (you) CourtPieceRoom.requestSeat(room, you.id, seat);
            });
            requestAnySeatBtn.appendChild(btn);
        });
    }

    // ==================================================================
    // Incoming seat request targeting the human's own seat
    // ==================================================================
    const seatRequestModal = document.getElementById("seatRequestModal");
    let shownRequestKey = null;

    function maybeShowIncomingSeatRequest() {
        const req = room && room.pendingRequest;
        if (!req) {
            seatRequestModal.style.display = "none";
            shownRequestKey = null;
            return;
        }
        const targetMeta = seatMeta[req.targetSeat];
        if (!targetMeta || !targetMeta.isYou) return;

        const key = req.spectatorId + ":" + req.targetSeat;
        if (shownRequestKey === key) return;
        shownRequestKey = key;

        document.getElementById("seatRequestText").textContent =
            `${req.spectatorName} is requesting your seat (${req.targetSeat}). Give it up?`;
        seatRequestModal.style.display = "flex";
    }

    document.getElementById("seatRequestAcceptBtn").addEventListener("click", () => {
        seatRequestModal.style.display = "none";
        shownRequestKey = null;
        CourtPieceRoom.respondToRequest(room, true);
    });
    document.getElementById("seatRequestDeclineBtn").addEventListener("click", () => {
        seatRequestModal.style.display = "none";
        shownRequestKey = null;
        CourtPieceRoom.respondToRequest(room, false);
    });
})();
