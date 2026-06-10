"""Connect your tools: cluster endpoints, shell access, and make reference."""

import os
import re
import subprocess
from pathlib import Path

import sys

import streamlit as st

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from db import DB_PARAMS  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
IN_CODESPACE = os.environ.get("CODESPACES", "").lower() == "true"

# Published ports (docker-compose.yml). DB name matches Makefile DB=.
YSQL_PORT = DB_PARAMS["port"]
YSQL_USER = DB_PARAMS["user"]
YSQL_DB = DB_PARAMS["dbname"]
UIS = [
    ("Mission Control dashboard", "http://localhost:8501", "live map and read-path demo"),
    ("yugabyted", "http://localhost:15433", "cluster overview; watch CPU during the hot-tablet beat"),
    ("YB-Master", "http://localhost:7000", "tablet distribution and Raft leaders"),
    ("YB-TServer", "http://localhost:9000", "per-node tablet stats"),
]

st.set_page_config(page_title="Connect · Mission Control", page_icon="🔌",
                   layout="wide")
st.markdown("## 🔌 Connect")


def resolve_ysql_host():
    """Same host selection as ``make`` (scripts/resolve-ysql-host.sh)."""
    if os.environ.get("YSQL_HOST"):
        return DB_PARAMS["host"]
    script = REPO / "scripts" / "resolve-ysql-host.sh"
    try:
        out = subprocess.run([str(script)], cwd=REPO, text=True,
                             capture_output=True, check=True, timeout=5)
        return out.stdout.strip() or "localhost"
    except (subprocess.SubprocessError, OSError):
        return DB_PARAMS["host"]


def run_make(target, minutes):
    with st.status(f"Running `make {target}` (~{minutes})…", expanded=True) as box:
        proc = subprocess.run(["make", target], cwd=REPO, text=True,
                              capture_output=True, timeout=3600)
        st.code((proc.stdout + proc.stderr)[-4000:] or "(no output)")
        if proc.returncode == 0:
            box.update(label=f"`make {target}` done ✅", state="complete")
        else:
            box.update(label=f"`make {target}` FAILED (exit {proc.returncode})",
                       state="error")
    st.cache_data.clear()


def cluster_button(col, label, target, minutes, confirm, detail):
    key = f"cluster_confirm_{target}"
    if not confirm:
        if col.button(label, use_container_width=True, key=f"cluster_{target}"):
            run_make(target, minutes)
    elif st.session_state.get(key):
        col.warning(f"`make {target}` takes ~{minutes}.")
        yes, no = col.columns(2)
        if yes.button("Yes, run", type="primary", use_container_width=True,
                      key=f"cluster_yes_{target}"):
            st.session_state[key] = False
            run_make(target, minutes)
        if no.button("Cancel", use_container_width=True, key=f"cluster_no_{target}"):
            st.session_state[key] = False
            st.rerun()
    elif col.button(label, key=f"cluster_ask_{target}", use_container_width=True):
        st.session_state[key] = True
        st.rerun()
    col.caption(detail)


def parse_make_targets():
    """Read ``##`` help lines from the Makefile (same text as ``make help``)."""
    entries = []
    section = "General"
    for line in (REPO / "Makefile").read_text().splitlines():
        if line.startswith("# ──"):
            section = line.strip("# ").strip("─").strip()
        match = re.match(r"^([a-zA-Z_-]+):.*?## (.+)$", line)
        if match:
            entries.append((section, match.group(1), match.group(2)))
    return entries


YSQL_HOST = resolve_ysql_host()
CONN_FLAGS = f"-h {YSQL_HOST} -p {YSQL_PORT} -U {YSQL_USER} -d {YSQL_DB}"


# ── Connection settings ────────────────────────────────────────────────────────

st.markdown("### Connection settings")
st.caption("Values below match the Makefile and docker-compose port map.")

c1, c2 = st.columns(2)
with c1:
    st.markdown(
        f"| | |\n"
        f"|---|---|\n"
        f"| Host | `{YSQL_HOST}` |\n"
        f"| Port | `{YSQL_PORT}` |\n"
        f"| Database | `{YSQL_DB}` |\n"
        f"| User | `{YSQL_USER}` |\n"
        f"| Password | *(none)* |"
    )
with c2:
    ui_rows = "\n".join(
        f"| {name} | [{url}]({url}) | {note} |"
        for name, url, note in UIS
    )
    st.markdown(f"| UI | URL | Notes |\n|---|---|---|\n{ui_rows}")

st.divider()


# ── Command line ───────────────────────────────────────────────────────────────

st.markdown("### Command line")
st.caption("Either client works. Yugabyte speaks the PostgreSQL wire protocol.")

st.markdown("**ysqlsh**")
st.markdown(
    "Yugabyte's SQL shell. Best if you already have the client tools installed, "
    "or you want `\\d`, `\\timing`, and other psql-style meta-commands without "
    "thinking about compatibility."
)
st.code(
    f"ysqlsh {CONN_FLAGS}\n"
    f"# install: brew tap yugabyte/tap && brew install yugabyte-client\n"
    f"# no install: make connect  (opens ysqlsh inside the container)",
    language="bash",
)

st.markdown("**psql**")
st.markdown(
    "Standard PostgreSQL client. Handy if you already have `psql` from Homebrew, "
    "apt, or a Postgres install. Step through walkthrough files with "
    "`:file path/to/script.sql` or paste statements one at a time."
)
st.code(
    f"psql {CONN_FLAGS}\n"
    f"# install (macOS): brew install libpq && brew link --force libpq\n"
    f"# install (Debian/Ubuntu): sudo apt install postgresql-client",
    language="bash",
)

st.divider()


# ── Walkthrough scripts ────────────────────────────────────────────────────────

st.markdown("### Walkthrough scripts")
st.markdown(
    "Open one of these in a client-side SQL tool and step through with "
    "Ctrl/Cmd-Enter or by pasting blocks into `ysqlsh` / `psql`:\n\n"
    "- `sql/demo/walkthrough.sql` — presenter script after `make setup` or "
    "**Set up DEMO mode** on Controls (~3 min)\n"
    "- `sql/lab/walkthrough.sql` — hands-on lab after `make setup-lab` or "
    "**Set up LAB mode** on Controls (~30–45 min)"
)

st.divider()


# ── Local vs Codespaces ────────────────────────────────────────────────────────

st.markdown("### Local vs Codespaces")

if IN_CODESPACE:
    st.markdown(
        "**You are in a Codespace.** The cluster is on the compose network; "
        f"the host above (`{YSQL_HOST}`) is what `make` and the app use.\n\n"
        "**Easiest path:** open the codespace in VS Code Desktop "
        "(menu ☰ → *Open in VS Code Desktop*). Port forwarding follows you, "
        "and every tool on your machine connects with the settings at the top.\n\n"
        "**Staying in the browser?** SQLTools is pre-configured (database icon "
        "in the left bar). Web UIs are on the **Ports** tab "
        f"({YSQL_PORT}, 15433, 7000, 9000, 8501).\n\n"
        "**Other tools:** forward ports from your machine with the GitHub CLI:"
    )
    st.code(
        "gh codespace ports forward 5433:5433 15433:15433 7000:7000 "
        "9000:9000 8501:8501",
        language="bash",
    )
else:
    st.markdown(
        "**Running locally (Docker):** everything is plain `localhost` on the "
        "ports above. No tunnels, no passwords.\n\n"
        "**Client-side tools:** any PostgreSQL-compatible GUI or IDE SQL "
        "extension on your machine. New Connection → PostgreSQL, then enter "
        "the connection table above. The standard PostgreSQL driver works "
        "fine.\n\n"
        "**GitHub Codespaces:** **Code → Codespaces → Create codespace on main**. "
        "The cluster starts automatically. Open this **Connect** page there for "
        "Codespace-specific port-forward notes."
    )

st.divider()


# ── Cluster management ─────────────────────────────────────────────────────────

st.markdown("### Cluster management")
st.caption("Start and stop the 3-node Docker cluster. Demo setup lives on **Controls**.")

k1, k2, k3 = st.columns(3)
cluster_button(
    k1, "▶ Start cluster", "up", "2–5 min", confirm=True,
    detail="`make up` — starts three YugabyteDB nodes and waits until "
           "all are visible in `yb_servers()`.")
cluster_button(
    k2, "⏹ Stop cluster", "down", "seconds", confirm=True,
    detail="`make down` — stops containers. Data volumes are kept; "
           "`make up` picks up where you left off.")
cluster_button(
    k3, "↻ Restart cluster", "restart", "2–5 min", confirm=True,
    detail="`make restart` — full stop then start. Same data volumes as before.")

st.divider()


# ── Shell reference ────────────────────────────────────────────────────────────

st.markdown("### Shell reference")
st.caption("Every target from `make help`. Run these from the repo root in a terminal.")

current_section = None
for section, target, desc in parse_make_targets():
    if section != current_section:
        st.markdown(f"**{section}**")
        current_section = section
    st.markdown(f"- `make {target}` — {desc}")
