-- Ludo game history, in its own table (separate from game_results and
-- connect4_results) since Ludo rounds can have 2-4 participants instead of
-- exactly 2 - one row per participant per finished round, grouped by
-- round_id (a random hex token generated in app code, not a DB sequence,
-- so no extension dependency is needed to group rows from the same round).
CREATE TABLE ludo_results (
    id SERIAL PRIMARY KEY,
    mode TEXT NOT NULL,
    round_id TEXT NOT NULL,
    player_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    color TEXT NOT NULL,
    winner BOOLEAN NOT NULL,
    played_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_ludo_results_player ON ludo_results(player_id);
CREATE INDEX idx_ludo_results_round ON ludo_results(round_id);
