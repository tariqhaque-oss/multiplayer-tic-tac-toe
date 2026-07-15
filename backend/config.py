import os
import re
import secrets

from dotenv import load_dotenv

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(BASE_DIR)
FRONTEND_DIR = os.path.join(REPO_ROOT, "frontend")
PAGES_DIR = os.path.join(FRONTEND_DIR, "pages")
STATIC_ASSETS_DIR = os.path.join(FRONTEND_DIR, "static")

load_dotenv(os.path.join(BASE_DIR, ".env"))

# Database connection
PGHOST = os.environ.get("PGHOST", "localhost")
PGPORT = os.environ.get("PGPORT", "5432")
PGDATABASE = os.environ.get("PGDATABASE", "tictactoe")
PGUSER = os.environ.get("PGUSER", "tictactoe_app")
PGPASSWORD = os.environ.get("PGPASSWORD")

# Sessions
SESSION_SECRET = os.environ.get("SESSION_SECRET")
if not SESSION_SECRET:
    SESSION_SECRET = secrets.token_hex(32)
    print("WARNING: SESSION_SECRET not set, using a random key for this run. "
          "Existing sessions will be invalidated on every restart. "
          "Set the SESSION_SECRET env var for persistent sessions.")

SESSION_COOKIE = "session"
SESSION_MAX_AGE = 60 * 60 * 24 * 7  # 7 days

# Email (Gmail SMTP)
GMAIL_SENDER = os.environ.get("GMAIL_SENDER")
GMAIL_APP_PASSWORD = os.environ.get("GMAIL_APP_PASSWORD")

# Validation patterns
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
NICKNAME_RE = re.compile(r"^[A-Za-z0-9_]{3,24}$")
KEY_RE = re.compile(r"^[A-Za-z0-9]{5}$")

# Bot accounts (synthetic users - see migrations/004_bot_accounts.sql)
BOT_DIFFICULTIES = {"easy", "medium", "hard"}
BOT_EMAILS = {
    "easy": "bot-easy@system.local",
    "medium": "bot-medium@system.local",
    "hard": "bot-hard@system.local",
}
