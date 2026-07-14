-- Synthetic "bot" accounts, one per difficulty. Password hashes are real
-- bcrypt hashes of random, discarded strings - nobody knows a matching
-- plaintext, and these accounts are never reachable via the login form
-- in practice since bot games are only started from within the app.
INSERT INTO users (email, nickname, password_hash, email_verified)
VALUES
    ('bot-easy@system.local', 'Bot (Easy)', '$2b$12$2iAikMdx9Lv892fTxAob2..Ry/AR0NdMTRfnWq6sG50/WBb3fNKqC', true),
    ('bot-medium@system.local', 'Bot (Medium)', '$2b$12$21zclzcFtgJxArXDknUoZe06fYhlnrlo6q9Bblz5SY.siJVuZ0kHu', true),
    ('bot-hard@system.local', 'Bot (Hard)', '$2b$12$E6gf0Aq7J8rP79g9cOEtTeik5BucJYrZzruIzG2rofO7tmlyJhFMG', true)
ON CONFLICT (email) DO NOTHING;
