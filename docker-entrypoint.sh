#!/bin/sh
# Starts both processes inside one Cloud Run container: uvicorn (bound to
# localhost only, never exposed directly) and Caddy, the only process
# listening on the port Cloud Run actually routes traffic to ($PORT),
# which reverse-proxies to uvicorn.
set -e

cd /app/backend
python -m uvicorn main:app --host 127.0.0.1 --port 8000 &

# Cloud Run's startup probe only checks that Caddy's port ($PORT) is open,
# not that uvicorn is actually ready behind it. uvicorn takes a while to
# finish importing every game module and opening the DB pool, so without
# this wait, real traffic can reach Caddy - and get proxied to a uvicorn
# that isn't listening yet - during that window, producing 502s.
until curl -s -o /dev/null "http://127.0.0.1:8000/api/auth/me"; do
    sleep 0.5
done

cd /app
exec caddy run --config Caddyfile --adapter caddyfile
