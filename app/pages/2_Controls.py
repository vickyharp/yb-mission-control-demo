"""Controls: get the demo into the state you want without a terminal.

Buttons shell out to the same make targets documented in the README, so
there is exactly one implementation of every action.
"""

import os
import signal
import subprocess
import sys
from pathlib import Path

import streamlit as st

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from db import query  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
PIDFILE = Path("/tmp/mission-control-load.pid")
LOADLOG = Path("/tmp/mission-control-load.log")

st.set_page_config(page_title="Controls · Mission Control", page_icon="⚙️",
                   layout="wide")
st.markdown("## ⚙️ Controls")
st.caption(
    "Buttons run the same `make` targets as the terminal. "
    "**Slow** (~2–5 min; skip these mid-presentation): `make setup`, "
    "`make demo-mode`, `make refill`. "
    "**Fast**: `make lab-mode` (drops indexes, seconds)."
)


# ── Current state ──────────────────────────────────────────────────────────────

def loader_pid():
    try:
        pid = int(PIDFILE.read_text().strip())
        os.kill(pid, 0)
        return pid
    except (FileNotFoundError, ValueError, ProcessLookupError, PermissionError):
        return None


def fetch_loader_rate():
    try:
        rows, _ = query(
            "SELECT inserts_per_sec FROM ingest_stats WHERE id = 1 "
            "AND updated_at > now() - interval '15 seconds'")
        return rows[0]["inserts_per_sec"] if rows else None
    except Exception:
        return None


def fetch_state():
    state = {"reachable": False, "nodes": 0, "rows": None, "indexes": {}}
    try:
        rows, _ = query("SELECT count(*) AS n FROM yb_servers()")
        state["nodes"] = rows[0]["n"]
        state["reachable"] = True
    except Exception:
        return state
    try:
        rows, _ = query("""
            SELECT indexrelid::regclass::text AS name, indisvalid
            FROM pg_index WHERE indrelid = 'telemetry'::regclass
              AND indexrelid::regclass::text NOT LIKE '%pkey'""")
        state["indexes"] = {r["name"]: r["indisvalid"] for r in rows}
        rows, _ = query("SELECT count(*) AS n FROM telemetry")
        state["rows"] = rows[0]["n"]
    except Exception:
        state["rows"] = None  # schema not created yet
    return state


state = fetch_state()
pid = loader_pid()

c1, c2, c3, c4, c5 = st.columns(5)
c1.metric("Cluster nodes", state["nodes"] if state["reachable"] else "down")
c2.metric("Telemetry rows",
          f"{state['rows']:,}" if state["rows"] is not None else "no schema")
if state["rows"] is not None:
    n_idx = len(state["indexes"])
    mode = {2: "DEMO", 0: "LAB"}.get(n_idx, "MID-LAB")
    invalid = [k for k, v in state["indexes"].items() if not v]
    c3.metric("Mode", mode, help="DEMO = both indexes built · LAB = none · "
              "MID-LAB = partway through the lab")
    index_help = ", ".join(state["indexes"]) or "none"
    if invalid:
        c4.metric("Indexes", f"{n_idx} (invalid)", help=index_help)
    else:
        c4.metric("Indexes", str(n_idx) if n_idx else "none", help=index_help)
else:
    c3.metric("Mode", "—")
    c4.metric("Indexes", "—")

c5.metric("Load generator", "▶ running" if pid else "stopped",
          help="Live rate updates in the panel below while running")

if state["indexes"]:
    names = []
    for name, valid in sorted(state["indexes"].items()):
        names.append(f"`{name}`" + ("" if valid else " ⚠️ invalid"))
    st.caption("Secondary indexes: " + " · ".join(names))

st.divider()


# ── Make-target actions ────────────────────────────────────────────────────────

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


def action_button(col, label, target, minutes, confirm, detail):
    """Slow/destructive actions take two clicks; quick ones run immediately."""
    key = f"confirm_{target}"
    if not confirm:
        if col.button(label, use_container_width=True):
            run_make(target, minutes)
    elif st.session_state.get(key):
        col.warning(f"`make {target}` takes ~{minutes}. Not for mid-presentation.")
        yes, no = col.columns(2)
        if yes.button("Yes, run", type="primary", use_container_width=True,
                      key=f"yes_{target}"):
            st.session_state[key] = False
            run_make(target, minutes)
        if no.button("Cancel", use_container_width=True, key=f"cancel_{target}"):
            st.session_state[key] = False
            st.rerun()
    elif col.button(label, key=f"ask_{target}", use_container_width=True):
        st.session_state[key] = True
        st.rerun()
    col.caption(detail)


if state["rows"] is None and state["reachable"]:
    st.markdown("**First run**")
    st.caption("Pick a mode to create the schema and load ~3M rows of history.")
    f1, f2 = st.columns(2)
    action_button(
        f1, "🎬 Set up DEMO mode (~3–5 min)", "setup", "3–5 min", confirm=True,
        detail="Creates schema, loads ~3M rows of real satellite history, "
               "and pre-builds both indexes (`telemetry_by_time`, "
               "`telemetry_by_bucket`). Ready to present or run "
               "sql/demo/walkthrough.sql with hint-based read paths.")
    action_button(
        f2, "🧪 Set up LAB mode (~2–4 min)", "setup-lab", "2–4 min", confirm=True,
        detail="Same schema and ~3M rows, but no secondary indexes. You build "
               "them yourself in sql/lab/walkthrough.sql and watch the dashboard "
               "read-path options light up as each index appears.")

elif state["reachable"]:
    st.markdown("**Actions**")
    a1, a2, a3 = st.columns(3)
    action_button(
        a1, "🎬 Demo mode (~2 min)", "demo-mode", "2 min", confirm=True,
        detail="Drops both secondary indexes and rebuilds them fresh (~2 min). "
               "Puts you in presenter mode: dashboard read-path hints work, "
               "all three heat charts populate. Data is untouched.")
    action_button(
        a2, "🧪 Lab mode (instant)", "lab-mode", "seconds", confirm=False,
        detail="Drops both secondary indexes only. Dashboard read-path collapses "
               "to auto; range and bucket heat charts show \"not created yet\". "
               "Data is untouched. Open sql/lab/walkthrough.sql to rebuild.")
    action_button(
        a3, "♻️ Refill telemetry (~2 min)", "refill", "2 min", confirm=True,
        detail="TRUNCATE telemetry and reload a fresh ~3M-row backfill. Keeps "
               "whatever indexes exist now. Use if a long-running loader grew "
               "the table past demo size.")

else:
    st.error("Cluster unreachable. Start it from **Connect** → Cluster management, "
             "or run `make up` in a terminal.")

st.divider()


# ── Load generator ─────────────────────────────────────────────────────────────

st.markdown("**Load generator**")
st.caption("Live telemetry writes. The write-side story needs this running.")

l1, l2 = st.columns([1, 3])
rate = l1.number_input("readings/sec", min_value=10, max_value=1000, value=150,
                       step=10, label_visibility="collapsed")

with l2:
    if pid is None:
        if st.button("▶ Start load", disabled=state["rows"] is None):
            py = REPO / ".venv" / "bin" / "python"
            proc = subprocess.Popen(
                [str(py if py.exists() else sys.executable),
                 str(REPO / "app" / "ingest.py"), "--rate", str(int(rate))],
                cwd=REPO, stdout=LOADLOG.open("w"), stderr=subprocess.STDOUT,
                start_new_session=True)
            PIDFILE.write_text(str(proc.pid))
            st.rerun()
    elif st.button("⏹ Stop load", use_container_width=True):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        PIDFILE.unlink(missing_ok=True)
        st.rerun()


@st.fragment(run_every=2)
def loader_live_panel():
    """Poll log + rate without rerunning the whole page (no screen dim)."""
    if not loader_pid():
        return
    live_rate = fetch_loader_rate()
    if live_rate:
        st.success(
            f"Running at **{live_rate:,.0f}** readings/sec "
            f"(ingest reports every 5 s)")
    else:
        st.info("Process up — first throughput line in ~5 s…")
    with st.status("Load generator log", expanded=True, state="running"):
        if LOADLOG.exists():
            log = LOADLOG.read_text().splitlines()[-30:]
            st.code("\n".join(log) if log else "(no output yet)", language=None)
        else:
            st.caption("Waiting for log file…")


if pid:
    loader_live_panel()

st.caption("Terminal equivalent: `make load`. Zero-Python alternative: "
           "`sql/lab/load.sql`.")
