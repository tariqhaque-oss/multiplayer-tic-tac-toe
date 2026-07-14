-- Remove orphaned pre-migration row that isn't a valid email (leftover test data)
DELETE FROM users WHERE email !~ '@';

ALTER TABLE users ADD COLUMN nickname VARCHAR(24);
UPDATE users SET nickname = split_part(email, '@', 1) WHERE nickname IS NULL;
ALTER TABLE users ALTER COLUMN nickname SET NOT NULL;
CREATE UNIQUE INDEX idx_users_nickname_lower ON users (LOWER(nickname));

CREATE TABLE game_results (
    id SERIAL PRIMARY KEY,
    mode TEXT NOT NULL,
    player_x_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    player_o_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    winner TEXT NOT NULL,
    played_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_game_results_player_x ON game_results(player_x_id);
CREATE INDEX idx_game_results_player_o ON game_results(player_o_id);
