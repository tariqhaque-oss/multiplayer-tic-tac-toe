# Multiplayer Tic Tac Toe

A real-time multiplayer Tic Tac Toe game with email-based accounts. Built with FastAPI (WebSockets) on the backend and plain HTML/CSS/JS on the frontend - no frontend framework or build step.

## Features

- Email signup with verification link, login, logout
- Forgot password flow (emailed reset link) with password-reuse prevention (a password can never be reused once changed)
- Unique display nickname chosen at signup - shown to other players instead of your email
- Join a random opponent, or create/join a private game behind a shared secret phrase (5+ words, unique per active game)
- Any number of games can run concurrently; each game is capped at exactly 2 players
- Live board, turn indicator, win/draw detection, running score per game
- Persistent per-player stats (games/wins/losses/draws), filterable by "All Games", "Random Games" (combined), or a specific private-game opponent

## Stack

- **Backend**: FastAPI + WebSockets, Python
- **Database**: PostgreSQL (accounts, password history, email verification/reset tokens, game results)
- **Email**: Gmail SMTP (via an App Password)
- **Frontend**: Raw HTML/CSS/vanilla JS served as static files - no framework, no build step

## Project structure

```
.
├── backend/
│   ├── main.py              FastAPI app: auth, email, and game/WebSocket logic
│   ├── requirements.txt
│   ├── migrate_v2.sql       Schema migration (username -> email, verification/reset/history tables)
│   ├── migrate_v3.sql       Schema migration (nicknames, game_results table)
│   ├── .env.example         Template for required environment variables
│   └── static/
│       ├── index.html            Game lobby + board
│       ├── login.html
│       ├── signup.html
│       ├── forgot-password.html
│       └── reset-password.html
└── .gitignore
```

## Setup

1. Install PostgreSQL and create a database/role for the app (or point `.env` at an existing instance).
2. Copy `backend/.env.example` to `backend/.env` and fill in real values:
   - `PG*` - your Postgres connection details
   - `SESSION_SECRET` - generate with `python -c "import secrets; print(secrets.token_urlsafe(32))"`
   - `GMAIL_SENDER` / `GMAIL_APP_PASSWORD` - a Gmail account and an [App Password](https://myaccount.google.com/apppasswords) (requires 2-Step Verification enabled on that account) used to send verification/reset emails
3. Run the schema migrations against your database, in order:
   ```
   psql -f backend/migrate_v2.sql
   psql -f backend/migrate_v3.sql
   ```
   (`migrate_v2.sql` expects a `users` table with `id`/`password_hash` to already exist - see the SQL for the base schema it assumes.)
4. Install dependencies:
   ```
   cd backend
   python -m pip install -r requirements.txt
   ```
5. Run the server:
   ```
   python -m uvicorn main:app --host 0.0.0.0 --port 8000
   ```
6. Open `http://localhost:8000/signup` to create an account.

## Playing over the internet

To let someone outside your network play, expose port 8000 with a tunnel (e.g. `ngrok http 8000`) and share the resulting HTTPS URL. Each person signs up/logs in with their own email, then either joins a random game or creates/joins a private game with a shared phrase.
