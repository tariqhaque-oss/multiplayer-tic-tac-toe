import os
import json
import urllib.request
from datetime import datetime, timezone

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ENV_PATH = os.path.join(BASE_DIR, ".env")
LOG_PATH = os.path.join(BASE_DIR, "ddns_update.log")


def load_env():
    env = {}
    with open(ENV_PATH) as f:
        for line in f:
            line = line.strip()
            if line and "=" in line:
                key, value = line.split("=", 1)
                env[key] = value
    return env


def http_json(url, method="GET", token=None, data=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode("utf-8"))


def log(message):
    timestamp = datetime.now(timezone.utc).isoformat()
    with open(LOG_PATH, "a") as f:
        f.write(f"{timestamp} {message}\n")


def main():
    env = load_env()

    current_ip = http_json("https://api.ipify.org?format=json")["ip"]

    record_url = (
        f"https://api.cloudflare.com/client/v4/zones/{env['CF_ZONE_ID']}"
        f"/dns_records/{env['CF_RECORD_ID']}"
    )
    record = http_json(record_url, token=env["CF_API_TOKEN"])["result"]

    if record["content"] == current_ip:
        log(f"no change ({current_ip})")
        return

    updated = http_json(
        record_url,
        method="PATCH",
        token=env["CF_API_TOKEN"],
        data={"type": "A", "name": env["CF_RECORD_NAME"], "content": current_ip, "ttl": 300, "proxied": False},
    )

    if updated.get("success"):
        log(f"updated {env['CF_RECORD_NAME']}: {record['content']} -> {current_ip}")
    else:
        log(f"FAILED to update: {updated}")


if __name__ == "__main__":
    main()
