import hashlib
import secrets

import bcrypt
from fastapi import Request
from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired

from config import SESSION_SECRET, SESSION_COOKIE, SESSION_MAX_AGE

serializer = URLSafeTimedSerializer(SESSION_SECRET)


def hash_password(password):
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(password, password_hash):
    return bcrypt.checkpw(password.encode("utf-8"), password_hash.encode("utf-8"))


def generate_token():
    return secrets.token_urlsafe(32)


def hash_token(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def create_session_cookie(user_id, email, nickname):
    return serializer.dumps({"user_id": user_id, "email": email, "nickname": nickname})


def read_session_cookie(token):
    if not token:
        return None
    try:
        data = serializer.loads(token, max_age=SESSION_MAX_AGE)
    except (BadSignature, SignatureExpired):
        return None
    if "user_id" not in data:
        return None
    return data


def get_session(request: Request):
    return read_session_cookie(request.cookies.get(SESSION_COOKIE))
