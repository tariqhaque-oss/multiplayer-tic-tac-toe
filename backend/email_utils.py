import smtplib
import ssl
from email.message import EmailMessage

from fastapi import Request

from config import GMAIL_SENDER, GMAIL_APP_PASSWORD


def send_email(to_address, subject, body):
    if not GMAIL_SENDER or not GMAIL_APP_PASSWORD:
        print(f"WARNING: GMAIL_SENDER/GMAIL_APP_PASSWORD not set. Would have emailed {to_address}: {subject}\n{body}")
        return

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = GMAIL_SENDER
    msg["To"] = to_address
    msg.set_content(body)

    context = ssl.create_default_context()
    with smtplib.SMTP("smtp.gmail.com", 587) as server:
        server.starttls(context=context)
        server.login(GMAIL_SENDER, GMAIL_APP_PASSWORD)
        server.send_message(msg)


def build_base_url(request: Request):
    host = request.headers.get("host", request.url.netloc)
    scheme = "http" if host.startswith("localhost") or host.startswith("127.0.0.1") else "https"
    return f"{scheme}://{host}"
