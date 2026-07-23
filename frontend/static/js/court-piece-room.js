// Court Piece "Private Online Room" simulation - a client-only mock of a
// multiplayer lobby (per spec: "Simulated Mock-Network Logic"). There is no
// real server here; simulated guests/spectators are generated locally and
// driven by the same bot AI as local-mode bots. This module owns seat/
// spectator bookkeeping only - it knows nothing about card-game rules.
(function (root) {
    "use strict";

    const SEATS = ["P1", "P2", "P3", "P4"];
    const GUEST_NAME_POOL = ["Guest", "Player", "User", "Table"];

    function randomGuestName() {
        const prefix = GUEST_NAME_POOL[Math.floor(Math.random() * GUEST_NAME_POOL.length)];
        return `${prefix}_${Math.floor(Math.random() * 900 + 100)}`;
    }

    function randomRoomCode() {
        return String(Math.floor(1000 + Math.random() * 9000));
    }

    function createRoomState() {
        return {
            code: null,
            seats: { P1: null, P2: null, P3: null, P4: null }, // {type:'human'|'guest', name, isYou}
            spectators: [], // FIFO queue, oldest first: {id, name}
            pendingRequest: null, // {spectatorId, spectatorName, targetSeat}
            nextSpectatorId: 1,
            onChange: null, // callback(reason) set by the UI layer
            timers: [],
        };
    }

    function emit(room, reason) {
        if (room.onChange) room.onChange(reason);
    }

    function firstOpenSeat(room) {
        return SEATS.find(s => !room.seats[s]) || null;
    }

    function addSpectator(room, name, isYou) {
        const spec = { id: room.nextSpectatorId++, name, isYou: !!isYou };
        room.spectators.push(spec);
        return spec;
    }

    function seatOrSpectate(room, name, isYou) {
        const seat = firstOpenSeat(room);
        if (seat) {
            room.seats[seat] = { type: isYou ? "human" : "guest", name, isYou: !!isYou };
            return { seat };
        }
        const spec = addSpectator(room, name, isYou);
        return { spectator: spec };
    }

    function scheduleGuestArrivals(room, count) {
        for (let i = 0; i < count; i++) {
            const delay = 900 + Math.random() * 1800 + i * 500;
            const t = setTimeout(() => {
                if (!room.code) return; // room was torn down
                const name = randomGuestName();
                const placement = seatOrSpectate(room, name, false);
                if (placement.seat) {
                    emit(room, `guest-joined-seat:${placement.seat}:${name}`);
                } else {
                    emit(room, `guest-joined-spectator:${name}`);
                }
                maybeScheduleSpectatorRequest(room);
            }, delay);
            room.timers.push(t);
        }
    }

    function maybeScheduleSpectatorRequest(room) {
        if (room.spectators.length === 0) return;
        const delay = 4000 + Math.random() * 6000;
        const t = setTimeout(() => {
            if (!room.code || room.pendingRequest) return;
            if (room.spectators.length === 0) return;
            const spec = room.spectators[Math.floor(Math.random() * room.spectators.length)];
            const targetSeat = SEATS[Math.floor(Math.random() * SEATS.length)];
            if (!room.seats[targetSeat]) return;
            requestSeat(room, spec.id, targetSeat);
        }, delay);
        room.timers.push(t);
    }

    function createRoom(humanSeat) {
        const room = createRoomState();
        room.code = randomRoomCode();
        room.seats[humanSeat] = { type: "human", name: "You", isYou: true };
        scheduleGuestArrivals(room, 3 + Math.floor(Math.random() * 2)); // fill the table, maybe one spectator too
        return room;
    }

    function joinRoom(code) {
        const room = createRoomState();
        room.code = code;
        // Simulate joining a room already in progress: 1-2 seats pre-filled.
        const preFilled = 1 + Math.floor(Math.random() * 2);
        for (let i = 0; i < preFilled; i++) {
            const seat = firstOpenSeat(room);
            room.seats[seat] = { type: "guest", name: randomGuestName(), isYou: false };
        }
        const placement = seatOrSpectate(room, "You", true);
        scheduleGuestArrivals(room, 4 - preFilled + Math.floor(Math.random() * 2));
        return { room, placement };
    }

    function requestSeat(room, spectatorId, targetSeat) {
        if (room.pendingRequest) return false;
        const spec = room.spectators.find(s => s.id === spectatorId);
        if (!spec || !room.seats[targetSeat]) return false;

        room.pendingRequest = { spectatorId, spectatorName: spec.name, targetSeat };
        emit(room, `seat-requested:${targetSeat}:${spec.name}`);

        const targetIsHuman = room.seats[targetSeat].type === "human" && room.seats[targetSeat].isYou;
        if (!targetIsHuman) {
            const delay = 1200 + Math.random() * 1800;
            const t = setTimeout(() => {
                if (!room.pendingRequest || room.pendingRequest.spectatorId !== spectatorId) return;
                respondToRequest(room, Math.random() < 0.5);
            }, delay);
            room.timers.push(t);
        }
        return true;
    }

    function respondToRequest(room, accept) {
        const req = room.pendingRequest;
        if (!req) return null;
        room.pendingRequest = null;

        if (!accept) {
            emit(room, `request-declined:${req.targetSeat}:${req.spectatorName}`);
            return { accepted: false };
        }

        const outgoing = room.seats[req.targetSeat];
        const specIdx = room.spectators.findIndex(s => s.id === req.spectatorId);
        const incoming = specIdx >= 0
            ? room.spectators.splice(specIdx, 1)[0]
            : { id: req.spectatorId, name: req.spectatorName, isYou: false };

        room.seats[req.targetSeat] = { type: incoming.isYou ? "human" : "guest", name: incoming.name, isYou: incoming.isYou };
        addSpectator(room, outgoing.name, outgoing.isYou);

        emit(room, `seat-transferred:${req.targetSeat}:${incoming.name}:${outgoing.name}`);
        maybeScheduleSpectatorRequest(room);
        return { accepted: true, seat: req.targetSeat, outgoingName: outgoing.name, incomingName: incoming.name };
    }

    // Human voluntarily leaves their seat: automatic FIFO promotion, no approval needed.
    function leaveTable(room, seat) {
        const leaving = room.seats[seat];
        if (!leaving) return null;

        room.seats[seat] = null;
        const promoted = room.spectators.shift(); // first in queue (oldest)
        addSpectator(room, leaving.name, leaving.isYou);

        if (promoted) {
            room.seats[seat] = { type: promoted.isYou ? "human" : "guest", name: promoted.name, isYou: !!promoted.isYou };
        }

        emit(room, `left-table:${seat}:${leaving.name}${promoted ? ":promoted:" + promoted.name : ""}`);
        maybeScheduleSpectatorRequest(room);
        return { promotedName: promoted ? promoted.name : null, promotedIsYou: promoted ? !!promoted.isYou : false };
    }

    function teardown(room) {
        room.timers.forEach(clearTimeout);
        room.timers = [];
        room.code = null;
    }

    const CourtPieceRoom = {
        SEATS, createRoom, joinRoom, requestSeat, respondToRequest, leaveTable,
        teardown, firstOpenSeat, randomGuestName, randomRoomCode,
    };

    if (typeof module !== "undefined" && module.exports) {
        module.exports = CourtPieceRoom;
    } else {
        root.CourtPieceRoom = CourtPieceRoom;
    }
})(typeof window !== "undefined" ? window : globalThis);
