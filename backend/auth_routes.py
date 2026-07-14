import os

import psycopg2.errors
from fastapi import APIRouter, Request, Form
from fastapi.responses import FileResponse, RedirectResponse

from config import STATIC_DIR, EMAIL_RE, NICKNAME_RE, SESSION_COOKIE, SESSION_MAX_AGE
from db import db_execute
from security import hash_password, verify_password, generate_token, hash_token, create_session_cookie
from email_utils import send_email, build_base_url

router = APIRouter()


def is_password_reused(user_id, current_hash, new_password):
    if verify_password(new_password, current_hash):
        return True

    rows = db_execute(
        "SELECT password_hash FROM password_history WHERE user_id = %s",
        (user_id,),
        fetch="all",
    )
    for (old_hash,) in rows:
        if verify_password(new_password, old_hash):
            return True

    return False


@router.get("/login")
def login_page():
    return FileResponse(os.path.join(STATIC_DIR, "login.html"))


@router.get("/signup")
def signup_page():
    return FileResponse(os.path.join(STATIC_DIR, "signup.html"))


@router.post("/signup")
def signup(request: Request, email: str = Form(...), nickname: str = Form(...),
           password: str = Form(...), confirm_password: str = Form(...)):
    email = email.strip().lower()
    nickname = nickname.strip()

    if not EMAIL_RE.match(email):
        return RedirectResponse("/signup?error=invalid_email", status_code=303)

    if not NICKNAME_RE.match(nickname):
        return RedirectResponse("/signup?error=invalid_nickname", status_code=303)

    if password != confirm_password:
        return RedirectResponse("/signup?error=mismatch", status_code=303)

    if len(password) < 8 or len(password.encode("utf-8")) > 72:
        return RedirectResponse("/signup?error=weak", status_code=303)

    password_hash = hash_password(password)

    existing = db_execute("SELECT 1 FROM users WHERE email = %s", (email,), fetch="one")
    if existing:
        return RedirectResponse("/signup?error=taken", status_code=303)

    existing_nickname = db_execute("SELECT 1 FROM users WHERE LOWER(nickname) = LOWER(%s)", (nickname,), fetch="one")
    if existing_nickname:
        return RedirectResponse("/signup?error=nickname_taken", status_code=303)

    try:
        row = db_execute(
            "INSERT INTO users (email, nickname, password_hash) VALUES (%s, %s, %s) RETURNING id",
            (email, nickname, password_hash),
            fetch="one",
            commit=True,
        )
    except psycopg2.errors.UniqueViolation:
        return RedirectResponse("/signup?error=taken", status_code=303)

    user_id = row[0]

    token = generate_token()
    db_execute(
        "INSERT INTO email_verification_tokens (user_id, token_hash, expires_at) "
        "VALUES (%s, %s, now() + interval '24 hours')",
        (user_id, hash_token(token)),
        commit=True,
    )

    verify_link = f"{build_base_url(request)}/verify-email?token={token}"
    send_email(
        email,
        "Verify your Tic Tac Toe account",
        f"Click the link below to verify your email and activate your account:\n\n{verify_link}\n\n"
        "This link expires in 24 hours.",
    )

    return RedirectResponse("/login?created=1", status_code=303)


@router.get("/verify-email")
def verify_email(token: str):
    token_hash = hash_token(token)
    row = db_execute(
        "SELECT user_id FROM email_verification_tokens WHERE token_hash = %s AND used_at IS NULL AND expires_at > now()",
        (token_hash,),
        fetch="one",
    )

    if not row:
        return RedirectResponse("/login?error=invalid_token", status_code=303)

    user_id = row[0]
    db_execute("UPDATE users SET email_verified = true WHERE id = %s", (user_id,), commit=True)
    db_execute("UPDATE email_verification_tokens SET used_at = now() WHERE token_hash = %s", (token_hash,), commit=True)

    return RedirectResponse("/login?verified=1", status_code=303)


@router.post("/resend-verification")
def resend_verification(request: Request, email: str = Form(...)):
    email = email.strip().lower()
    row = db_execute("SELECT id, email_verified FROM users WHERE email = %s", (email,), fetch="one")

    if row and not row[1]:
        user_id = row[0]
        token = generate_token()
        db_execute(
            "INSERT INTO email_verification_tokens (user_id, token_hash, expires_at) "
            "VALUES (%s, %s, now() + interval '24 hours')",
            (user_id, hash_token(token)),
            commit=True,
        )

        verify_link = f"{build_base_url(request)}/verify-email?token={token}"
        send_email(
            email,
            "Verify your Tic Tac Toe account",
            f"Click the link below to verify your email and activate your account:\n\n{verify_link}\n\n"
            "This link expires in 24 hours.",
        )

    return RedirectResponse("/login?resent=1", status_code=303)


@router.post("/login")
def login(email: str = Form(...), password: str = Form(...)):
    email = email.strip().lower()
    row = db_execute(
        "SELECT id, password_hash, email_verified, nickname FROM users WHERE email = %s",
        (email,),
        fetch="one",
    )

    if not row or len(password.encode("utf-8")) > 72 or not verify_password(password, row[1]):
        return RedirectResponse("/login?error=invalid", status_code=303)

    if not row[2]:
        return RedirectResponse("/login?error=unverified", status_code=303)

    user_id, nickname = row[0], row[3]

    redirect = RedirectResponse("/games", status_code=303)
    redirect.set_cookie(
        SESSION_COOKIE,
        create_session_cookie(user_id, email, nickname),
        max_age=SESSION_MAX_AGE,
        httponly=True,
        samesite="lax",
    )
    return redirect


@router.get("/logout")
def logout():
    redirect = RedirectResponse("/login?logged_out=1", status_code=303)
    redirect.delete_cookie(SESSION_COOKIE)
    return redirect


@router.get("/forgot-password")
def forgot_password_page():
    return FileResponse(os.path.join(STATIC_DIR, "forgot-password.html"))


@router.post("/forgot-password")
def forgot_password(request: Request, email: str = Form(...)):
    email = email.strip().lower()
    row = db_execute("SELECT id FROM users WHERE email = %s", (email,), fetch="one")

    if row:
        user_id = row[0]
        token = generate_token()
        db_execute(
            "INSERT INTO password_reset_tokens (user_id, token_hash, expires_at) "
            "VALUES (%s, %s, now() + interval '1 hour')",
            (user_id, hash_token(token)),
            commit=True,
        )

        reset_link = f"{build_base_url(request)}/reset-password?token={token}"
        send_email(
            email,
            "Reset your Tic Tac Toe password",
            f"Click the link below to choose a new password:\n\n{reset_link}\n\n"
            "This link expires in 1 hour. If you didn't request this, you can ignore this email.",
        )

    return RedirectResponse("/login?reset_requested=1", status_code=303)


@router.get("/reset-password")
def reset_password_page():
    return FileResponse(os.path.join(STATIC_DIR, "reset-password.html"))


@router.post("/reset-password")
def reset_password(token: str = Form(...), new_password: str = Form(...), confirm_new_password: str = Form(...)):
    token_hash = hash_token(token)
    row = db_execute(
        "SELECT user_id FROM password_reset_tokens WHERE token_hash = %s AND used_at IS NULL AND expires_at > now()",
        (token_hash,),
        fetch="one",
    )

    if not row:
        return RedirectResponse("/login?error=invalid_reset_link", status_code=303)

    user_id = row[0]

    if new_password != confirm_new_password:
        return RedirectResponse(f"/reset-password?token={token}&error=mismatch", status_code=303)

    if len(new_password) < 8 or len(new_password.encode("utf-8")) > 72:
        return RedirectResponse(f"/reset-password?token={token}&error=weak", status_code=303)

    current_hash = db_execute("SELECT password_hash FROM users WHERE id = %s", (user_id,), fetch="one")[0]

    if is_password_reused(user_id, current_hash, new_password):
        return RedirectResponse(f"/reset-password?token={token}&error=reused", status_code=303)

    new_hash = hash_password(new_password)

    db_execute("INSERT INTO password_history (user_id, password_hash) VALUES (%s, %s)", (user_id, current_hash), commit=True)
    db_execute("UPDATE users SET password_hash = %s WHERE id = %s", (new_hash, user_id), commit=True)
    db_execute("UPDATE password_reset_tokens SET used_at = now() WHERE token_hash = %s", (token_hash,), commit=True)

    return RedirectResponse("/login?reset_done=1", status_code=303)
