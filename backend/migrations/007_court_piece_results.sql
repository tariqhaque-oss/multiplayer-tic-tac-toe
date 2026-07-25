-- Court Piece game history, in its own table like the other games -
-- one row per participant per finished round, grouped by an app-generated
-- round_id (matching the pattern used by ludo_results/connect4_results).
-- "team" is redundant with "seat" (P1/P3 = A, P2/P4 = B) but kept as its
-- own column since team, not seat, is what actually won or lost.
CREATE TABLE court_piece_results (
    id SERIAL PRIMARY KEY,
    mode TEXT NOT NULL,
    round_id TEXT NOT NULL,
    player_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    seat TEXT NOT NULL,
    team TEXT NOT NULL,
    winner BOOLEAN NOT NULL,
    played_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_court_piece_results_player ON court_piece_results(player_id);
CREATE INDEX idx_court_piece_results_round ON court_piece_results(round_id);
