// Court Piece game engine - pure game rules and bot AI, no DOM access.
// Loaded as a plain <script> in the browser (exposes window.CourtPieceEngine)
// and via require() under Node for the engine's own test suite.
(function (root) {
    "use strict";

    const SUITS = ["♠", "♥", "♦", "♣"];
    const RED_SUITS = new Set(["♥", "♦"]);
    const RANKS = [2, 3, 4, 5, 6, 7, 8, 9, 10, "J", "Q", "K", "A"];
    const RANK_VALUE = { 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 7, 8: 8, 9: 9, 10: 10, J: 11, Q: 12, K: 13, A: 14 };

    const SEATS = ["P1", "P2", "P3", "P4"];
    const TEAM_OF = { P1: "A", P3: "A", P2: "B", P4: "B" };
    const PARTNER_OF = { P1: "P3", P3: "P1", P2: "P4", P4: "P2" };

    function cardKey(card) { return card.suit + card.rank; }
    function isRed(suit) { return RED_SUITS.has(suit); }
    function isTen(card) { return card.rank === 10; }

    function buildDeck() {
        const deck = [];
        for (const suit of SUITS) {
            for (const rank of RANKS) {
                deck.push({ suit, rank, value: RANK_VALUE[rank], color: isRed(suit) ? "red" : "black" });
            }
        }
        return deck;
    }

    function defaultRng() { return Math.random(); }

    function shuffle(deck, rng) {
        rng = rng || defaultRng;
        const arr = deck.slice();
        for (let i = arr.length - 1; i > 0; i--) {
            const j = Math.floor(rng() * (i + 1));
            [arr[i], arr[j]] = [arr[j], arr[i]];
        }
        return arr;
    }

    function nextSeat(seat) { return SEATS[(SEATS.indexOf(seat) + 1) % 4]; }

    // ------------------------------------------------------------------
    // Round state machine
    // ------------------------------------------------------------------
    function createRound(trumpCallerSeat, rng) {
        const deck = shuffle(buildDeck(), rng);
        return {
            phase: "dealing-first-five",
            deck,
            hands: { P1: [], P2: [], P3: [], P4: [] },
            trumpCallerSeat,
            trumpSuit: null,
            leader: null,
            currentTrick: [],       // [{seat, card}]
            ledSuit: null,
            tricksPlayed: 0,
            trickWins: { A: 0, B: 0 },
            lastTrickWinnerSeat: null,
            pendingPile: [],        // array of {seat, card} not yet collected by a team
            collected: { A: [], B: [] }, // cards a team has actually collected (for 10s counting)
            lastTrickInfo: null,    // {winnerSeat, cardsCount} for UI display
            winner: null,           // "A" | "B" once phase === "round-over"
        };
    }

    function dealFirstFive(state) {
        if (state.phase !== "dealing-first-five") throw new Error("wrong phase for dealFirstFive");
        for (const seat of SEATS) {
            state.hands[seat] = state.deck.splice(0, 5);
        }
        state.phase = "trump-selection";
        return state;
    }

    function chooseBotTrump(hand) {
        const counts = {};
        for (const suit of SUITS) counts[suit] = 0;
        for (const card of hand) counts[card.suit]++;

        let best = SUITS[0];
        for (const suit of SUITS) {
            if (counts[suit] > counts[best]) best = suit;
        }
        return best;
    }

    function dealRemaining(state, trumpSuit) {
        if (state.phase !== "trump-selection") throw new Error("wrong phase for dealRemaining");
        state.trumpSuit = trumpSuit;
        for (const seat of SEATS) {
            state.hands[seat] = state.hands[seat].concat(state.deck.splice(0, 8));
        }
        state.deck = [];
        state.phase = "playing";
        state.leader = state.trumpCallerSeat;
        return state;
    }

    function legalMoves(hand, ledSuit) {
        if (!ledSuit) return hand.slice();
        const following = hand.filter(c => c.suit === ledSuit);
        return following.length ? following : hand.slice();
    }

    function isLegalMove(hand, ledSuit, card) {
        const moves = legalMoves(hand, ledSuit);
        return moves.some(c => cardKey(c) === cardKey(card));
    }

    function resolveTrick(trick, ledSuit, trumpSuit) {
        const trumpPlays = trick.filter(t => t.card.suit === trumpSuit);
        const pool = trumpPlays.length ? trumpPlays : trick.filter(t => t.card.suit === ledSuit);
        let best = pool[0];
        for (const play of pool) {
            if (play.card.value > best.card.value) best = play;
        }
        return best.seat;
    }

    function removeFromHand(hand, card) {
        const idx = hand.findIndex(c => cardKey(c) === cardKey(card));
        if (idx === -1) throw new Error("card not in hand: " + cardKey(card));
        hand.splice(idx, 1);
    }

    // Applies one legal card play. Throws if illegal. Returns info about
    // whether a trick (and/or the round) completed as a result.
    function playCard(state, seat, card) {
        if (state.phase !== "playing") throw new Error("wrong phase for playCard");
        if (seat !== currentTurnSeat(state)) throw new Error(`not ${seat}'s turn`);

        const hand = state.hands[seat];
        if (!isLegalMove(hand, state.ledSuit, card)) throw new Error("illegal move: must follow suit if possible");

        removeFromHand(hand, card);
        state.currentTrick.push({ seat, card });
        if (state.currentTrick.length === 1) state.ledSuit = card.suit;

        const result = { trickCompleted: false, roundCompleted: false, trickWinnerSeat: null, collected: false };

        if (state.currentTrick.length === 4) {
            const winnerSeat = resolveTrick(state.currentTrick, state.ledSuit, state.trumpSuit);
            state.tricksPlayed++;
            state.trickWins[TEAM_OF[winnerSeat]]++;

            state.pendingPile.push(...state.currentTrick);

            const isFinalTrick = state.tricksPlayed === 13;
            const doubleWin = winnerSeat === state.lastTrickWinnerSeat;

            if (doubleWin || isFinalTrick) {
                const team = TEAM_OF[winnerSeat];
                state.collected[team].push(...state.pendingPile.map(p => p.card));
                state.pendingPile = [];
                result.collected = true;
            }

            state.lastTrickInfo = { winnerSeat, cardsCount: state.currentTrick.length };
            state.lastTrickWinnerSeat = winnerSeat;
            state.currentTrick = [];
            state.ledSuit = null;
            state.leader = winnerSeat;

            result.trickCompleted = true;
            result.trickWinnerSeat = winnerSeat;

            if (isFinalTrick) {
                state.phase = "round-over";
                state.winner = computeRoundWinner(state);
                result.roundCompleted = true;
            }
        }

        return result;
    }

    function currentTurnSeat(state) {
        if (state.currentTrick.length === 0) return state.leader;
        const lastSeat = state.currentTrick[state.currentTrick.length - 1].seat;
        return nextSeat(lastSeat);
    }

    function countTens(cards) { return cards.filter(isTen).length; }

    function computeRoundWinner(state) {
        const tensA = countTens(state.collected.A);
        const tensB = countTens(state.collected.B);

        if (tensA >= 3) return "A";
        if (tensB >= 3) return "B";
        // 2-2 split (only remaining possibility once all 4 tens are collected)
        if (state.trickWins.A > state.trickWins.B) return "A";
        if (state.trickWins.B > state.trickWins.A) return "B";
        return null; // theoretically unreachable (13 tricks is odd), kept for safety
    }

    // ------------------------------------------------------------------
    // Bot AI
    // ------------------------------------------------------------------
    function chooseBotCard(hand, state) {
        const ledSuit = state.ledSuit;
        const trumpSuit = state.trumpSuit;
        const moves = legalMoves(hand, ledSuit);

        if (ledSuit) {
            const followingSuit = moves.filter(c => c.suit === ledSuit);
            if (followingSuit.length) {
                return followingSuit.reduce((a, b) => (b.value > a.value ? b : a));
            }
        }

        // Can't follow suit (or leading the trick with no constraint): consider trumping.
        const seat = state.currentTrick.length === 0 ? state.leader : nextSeat(state.currentTrick[state.currentTrick.length - 1].seat);
        const partnerSeat = PARTNER_OF[seat];
        const partnerIsWinning = state.currentTrick.length > 0 &&
            resolveTrick(state.currentTrick, state.ledSuit, trumpSuit) === partnerSeat;

        if (!ledSuit) {
            // Leading the trick: play highest non-trump if possible, else lowest trump.
            const nonTrump = hand.filter(c => c.suit !== trumpSuit);
            const pool = nonTrump.length ? nonTrump : hand;
            return pool.reduce((a, b) => (b.value > a.value ? b : a));
        }

        const trumpsInHand = hand.filter(c => c.suit === trumpSuit);
        const trumpAlreadyPlayed = state.currentTrick.some(t => t.card.suit === trumpSuit);

        if (trumpsInHand.length && !partnerIsWinning) {
            if (!trumpAlreadyPlayed) {
                return trumpsInHand.reduce((a, b) => (b.value < a.value ? b : a));
            }
            const highestTrumpInTrick = Math.max(...state.currentTrick.filter(t => t.card.suit === trumpSuit).map(t => t.card.value));
            const winningTrumps = trumpsInHand.filter(c => c.value > highestTrumpInTrick);
            if (winningTrumps.length) {
                return winningTrumps.reduce((a, b) => (b.value < a.value ? b : a));
            }
        }

        // Can't or won't win: discard lowest card.
        return hand.reduce((a, b) => (b.value < a.value ? b : a));
    }

    // ------------------------------------------------------------------
    const CourtPieceEngine = {
        SUITS, RANKS, RANK_VALUE, SEATS, TEAM_OF, PARTNER_OF,
        buildDeck, shuffle, cardKey, isTen, isRed,
        createRound, dealFirstFive, dealRemaining, chooseBotTrump,
        legalMoves, isLegalMove, resolveTrick, playCard, currentTurnSeat,
        computeRoundWinner, countTens, chooseBotCard, nextSeat,
    };

    if (typeof module !== "undefined" && module.exports) {
        module.exports = CourtPieceEngine;
    } else {
        root.CourtPieceEngine = CourtPieceEngine;
    }
})(typeof window !== "undefined" ? window : globalThis);
