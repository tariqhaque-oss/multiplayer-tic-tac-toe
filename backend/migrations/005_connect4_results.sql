-- Connect Four game history, kept in its own table (separate from
-- tic-tac-toe's game_results) since the two games' code is intentionally
-- kept independent.
CREATE TABLE connect4_results (
    id SERIAL PRIMARY KEY,
    mode TEXT NOT NULL,
    player_red_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    player_yellow_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    winner TEXT NOT NULL,
    played_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_connect4_results_player_red ON connect4_results(player_red_id);
CREATE INDEX idx_connect4_results_player_yellow ON connect4_results(player_yellow_id);
