import psycopg2.errors
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, RedirectResponse
from pydantic import BaseModel

from config import EMAIL_RE, NICKNAME_RE, SESSION_COOKIE, SESSION_MAX_AGE
from db import db_execute
from security import hash_password, verify_password, generate_token, hash_token, create_session_cookie, get_session
from email_utils import send_email, build_base_url

router = APIRouter(prefix="/api/auth")


class SignupBody(BaseModel):
    email: str
    nickname: str
    password: str
    confirm_password: str


class LoginBody(BaseModel):
    email: str
    password: str


class ResendVerificationBody(BaseModel):
    email: str


class ForgotPasswordBody(BaseModel):
    email: str


class ResetPasswordBody(BaseModel):
    token: str
    new_password: str
    confirm_new_password: str


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


def ok(**extra):
    return JSONResponse({"ok": True, **extra})


def err(code):
    return JSONResponse({"ok": False, "error": code})


@router.get("/me")
def me(request: Request):
    session = get_session(request)
    if not session:
        return JSONResponse({"authenticated": False})
    return JSONResponse({
        "authenticated": True,
        "email": session["email"],
        "nickname": session["nickname"],
    })


@router.post("/signup")
def signup(request: Request, body: SignupBody):
    email = body.email.strip().lower()
    nickname = body.nickname.strip()

    if not EMAIL_RE.match(email):
        return err("invalid_email")

    if not NICKNAME_RE.match(nickname):
        return err("invalid_nickname")

    if body.password != body.confirm_password:
        return err("mismatch")

    if len(body.password) < 8 or len(body.password.encode("utf-8")) > 72:
        return err("weak")

    password_hash = hash_password(body.password)

    existing = db_execute("SELECT 1 FROM users WHERE email = %s", (email,), fetch="one")
    if existing:
        return err("taken")

    existing_nickname = db_execute("SELECT 1 FROM users WHERE LOWER(nickname) = LOWER(%s)", (nickname,), fetch="one")
    if existing_nickname:
        return err("nickname_taken")

    try:
        row = db_execute(
            "INSERT INTO users (email, nickname, password_hash) VALUES (%s, %s, %s) RETURNING id",
            (email, nickname, password_hash),
            fetch="one",
            commit=True,
        )
    except psycopg2.errors.UniqueViolation:
        return err("taken")

    user_id = row[0]

    token = generate_token()
    db_execute(
        "INSERT INTO email_verification_tokens (user_id, token_hash, expires_at) "
        "VALUES (%s, %s, now() + interval '24 hours')",
        (user_id, hash_token(token)),
        commit=True,
    )

    verify_link = f"{build_base_url(request)}/api/auth/verify-email?token={token}"
    send_email(
        email,
        "Verify your Tic Tac Toe account",
        f"Click the link below to verify your email and activate your account:\n\n{verify_link}\n\n"
        "This link expires in 24 hours.",
    )

    return ok()


@router.get("/verify-email")
def verify_email(token: str):
    token_hash = hash_token(token)
    row = db_execute(
        "SELECT user_id FROM email_verification_tokens WHERE token_hash = %s AND used_at IS NULL AND expires_at > now()",
        (token_hash,),
        fetch="one",
    )

    if not row:
        return RedirectResponse("/login.html?error=invalid_token", status_code=303)

    user_id = row[0]
    db_execute("UPDATE users SET email_verified = true WHERE id = %s", (user_id,), commit=True)
    db_execute("UPDATE email_verification_tokens SET used_at = now() WHERE token_hash = %s", (token_hash,), commit=True)

    return RedirectResponse("/login.html?verified=1", status_code=303)


@router.post("/resend-verification")
def resend_verification(request: Request, body: ResendVerificationBody):
    email = body.email.strip().lower()
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

        verify_link = f"{build_base_url(request)}/api/auth/verify-email?token={token}"
        send_email(
            email,
            "Verify your Tic Tac Toe account",
            f"Click the link below to verify your email and activate your account:\n\n{verify_link}\n\n"
            "This link expires in 24 hours.",
        )

    return ok()


@router.post("/login")
def login(body: LoginBody):
    email = body.email.strip().lower()
    row = db_execute(
        "SELECT id, password_hash, email_verified, nickname FROM users WHERE email = %s",
        (email,),
        fetch="one",
    )

    if not row or len(body.password.encode("utf-8")) > 72 or not verify_password(body.password, row[1]):
        return err("invalid")

    if not row[2]:
        return err("unverified")

    user_id, nickname = row[0], row[3]

    response = ok(nickname=nickname)
    response.set_cookie(
        SESSION_COOKIE,
        create_session_cookie(user_id, email, nickname),
        max_age=SESSION_MAX_AGE,
        httponly=True,
        samesite="lax",
    )
    return response


@router.post("/logout")
def logout():
    response = ok()
    response.delete_cookie(SESSION_COOKIE)
    return response


@router.post("/forgot-password")
def forgot_password(request: Request, body: ForgotPasswordBody):
    email = body.email.strip().lower()
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

        reset_link = f"{build_base_url(request)}/reset-password.html?token={token}"
        send_email(
            email,
            "Reset your Tic Tac Toe password",
            f"Click the link below to choose a new password:\n\n{reset_link}\n\n"
            "This link expires in 1 hour. If you didn't request this, you can ignore this email.",
        )

    return ok()


@router.post("/reset-password")
def reset_password(body: ResetPasswordBody):
    token_hash = hash_token(body.token)
    row = db_execute(
        "SELECT user_id FROM password_reset_tokens WHERE token_hash = %s AND used_at IS NULL AND expires_at > now()",
        (token_hash,),
        fetch="one",
    )

    if not row:
        return err("invalid_reset_link")

    user_id = row[0]

    if body.new_password != body.confirm_new_password:
        return err("mismatch")

    if len(body.new_password) < 8 or len(body.new_password.encode("utf-8")) > 72:
        return err("weak")

    current_hash = db_execute("SELECT password_hash FROM users WHERE id = %s", (user_id,), fetch="one")[0]

    if is_password_reused(user_id, current_hash, body.new_password):
        return err("reused")

    new_hash = hash_password(body.new_password)

    db_execute("INSERT INTO password_history (user_id, password_hash) VALUES (%s, %s)", (user_id, current_hash), commit=True)
    db_execute("UPDATE users SET password_hash = %s WHERE id = %s", (new_hash, user_id), commit=True)
    db_execute("UPDATE password_reset_tokens SET used_at = now() WHERE token_hash = %s", (token_hash,), commit=True)

    return ok()
