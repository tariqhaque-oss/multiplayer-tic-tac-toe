"""Start/stop/status helper for the tic-tac-toe stack on this laptop.

Controls the three pieces described in "deployment guide.txt" sections 1-2:
Postgres (backend/pgdata, port 5433), uvicorn (backend/main.py, port 8000),
and Caddy (infra/Caddyfile, ports 80/443). Windows-only - shells out to
netstat/taskkill and the same pg_ctl.exe/caddy.exe binaries the manual
instructions use, so there is nothing here the guide doesn't also show how
to do by hand.

Usage (run from anywhere - paths below are absolute):
    python deploy.py status
    python deploy.py start
    python deploy.py stop
    python deploy.py restart
"""
import os
import subprocess
import sys
import time

REPO_ROOT = os.path.dirname(os.path.abspath(__file__))
BACKEND_DIR = os.path.join(REPO_ROOT, "backend")
INFRA_DIR = os.path.join(REPO_ROOT, "infra")

PG_CTL = r"C:\Program Files\PostgreSQL\17\bin\pg_ctl.exe"
CADDY_EXE = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "WinGet", "Links", "caddy.exe")

UVICORN_LOG = os.path.join(BACKEND_DIR, "uvicorn.log")
CADDY_LOG = os.path.join(INFRA_DIR, "caddy.log")

SERVICES = [
    ("postgres", 5433),
    ("uvicorn", 8000),
    ("caddy (http)", 80),
    ("caddy (https)", 443),
]


def pid_on_port(port):
    """Return the PID of the process LISTENING on the given local TCP port, or None."""
    out = subprocess.run(["netstat", "-ano"], capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[0] == "TCP" and parts[-1].isdigit():
            local_addr, state, pid = parts[1], parts[3], parts[-1]
            if state == "LISTENING" and local_addr.endswith(f":{port}"):
                return int(pid)
    return None


def status():
    print(f"{'service':<15}{'port':<8}status")
    for name, port in SERVICES:
        pid = pid_on_port(port)
        print(f"{name:<15}{port:<8}{'running (pid ' + str(pid) + ')' if pid else 'stopped'}")


def kill_port(label, port):
    pid = pid_on_port(port)
    if not pid:
        print(f"{label}: nothing listening on {port}, skipping")
        return
    print(f"{label}: killing pid {pid} (was listening on {port})")
    subprocess.run(["taskkill", "/PID", str(pid), "/F"], check=False)


def start():
    if pid_on_port(5433):
        print("postgres: already running")
    else:
        print("postgres: starting")
        subprocess.run([PG_CTL, "-D", "pgdata", "-l", "pglog.txt", "start"], cwd=BACKEND_DIR, check=True)

    if pid_on_port(8000):
        print("uvicorn: already running")
    else:
        print("uvicorn: starting (log: backend/uvicorn.log)")
        with open(UVICORN_LOG, "a") as log:
            subprocess.Popen(
                [sys.executable, "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"],
                cwd=BACKEND_DIR, stdout=log, stderr=subprocess.STDOUT,
            )
        time.sleep(2)

    if pid_on_port(80) or pid_on_port(443):
        print("caddy: already running")
    elif not os.path.isfile(CADDY_EXE):
        print(f"caddy: EXE NOT FOUND at {CADDY_EXE}, skipping - install via 'winget install CaddyServer.Caddy'")
    else:
        print("caddy: starting (log: infra/caddy.log)")
        with open(CADDY_LOG, "a") as log:
            subprocess.Popen(
                [CADDY_EXE, "run", "--config", "Caddyfile"],
                cwd=INFRA_DIR, stdout=log, stderr=subprocess.STDOUT,
            )
        time.sleep(2)

    print()
    status()


def stop():
    kill_port("caddy", 443)
    kill_port("caddy", 80)
    kill_port("uvicorn", 8000)

    if pid_on_port(5433):
        print("postgres: stopping")
        subprocess.run([PG_CTL, "-D", "pgdata", "stop"], cwd=BACKEND_DIR, check=False)
    else:
        print("postgres: already stopped")


def restart():
    stop()
    time.sleep(2)
    start()


COMMANDS = {"status": status, "start": start, "stop": stop, "restart": restart}

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in COMMANDS:
        print(f"usage: python {os.path.basename(__file__)} {{{'|'.join(COMMANDS)}}}")
        sys.exit(1)
    COMMANDS[sys.argv[1]]()
