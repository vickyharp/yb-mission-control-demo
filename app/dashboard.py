"""Mission Control — the business app for the bucket index demo.

One page, deliberately thin:
  - world map of the latest telemetry (the real ISS is on it)
  - the refresh latency of the ONE query that carries the demo
  - ingest throughput as reported by ingest.py
  - write-distribution heat per storage layout (base table / range index / bucket index)

The dashboard's own refresh latency IS the demo's problem statement.

Run: streamlit run dashboard.py
"""

import pandas as pd
import plotly.graph_objects as go
import streamlit as st
from streamlit_autorefresh import st_autorefresh

from db import query

ISS_NORAD_ID = 25544
REFRESH_MS = 3000
HEAT_SAMPLE = 5000
NUM_BUCKETS = 6

# The one query the whole demo is about — IDENTICAL to the one in
# sql/03_walkthrough.sql (satellite names are joined client-side from a
# cached lookup so the timed query stays pure). The {hint} slot lets the
# presenter force a read path with the same pg_hint_plan hints as the
# walkthrough — with both indexes pre-created, that's the honest way to
# show the before/after without running DDL on stage.
LATEST_TELEMETRY_SQL = """{hint}
    SELECT norad_id, ts, latitude, longitude, altitude_km, velocity_kms
    FROM telemetry
    ORDER BY ts DESC
    LIMIT 100
"""

READ_PATHS = {
    "auto (planner picks)": "",
    "1 · no index (seq scan)": "/*+ SeqScan(telemetry) */",
    "2 · range index": "/*+ IndexOnlyScan(telemetry telemetry_by_time) */",
    "3 · bucket index": "/*+ IndexOnlyScan(telemetry telemetry_by_bucket) */",
}

# One cheap-ish sample that feeds all three heat charts.
HEAT_SAMPLE_SQL = f"""
    SELECT yb_hash_code(ts) %% {NUM_BUCKETS} AS bucket,
           yb_hash_code(reading_id) AS row_hash,
           ts
    FROM telemetry ORDER BY ts DESC LIMIT {HEAT_SAMPLE}
"""

st.set_page_config(page_title="Mission Control", page_icon="🛰️", layout="wide")
st_autorefresh(interval=REFRESH_MS, key="refresh")


@st.cache_data(ttl=30)
def get_range_split_points():
    """Lower bounds of the range index tablets, recorded at index creation."""
    try:
        rows, _ = query(
            "SELECT ordinal, lower_ts FROM range_split_points ORDER BY ordinal")
        return rows
    except Exception:
        return []


@st.cache_data(ttl=300)
def get_satellite_names():
    rows, _ = query("SELECT norad_id, name FROM satellites")
    return {r["norad_id"]: r["name"] for r in rows}


@st.cache_data(ttl=15)
def get_indexes():
    rows, _ = query("""
        SELECT indexname FROM pg_indexes
        WHERE tablename = 'telemetry' AND indexname NOT LIKE '%pkey'
        ORDER BY indexname""")
    return [r["indexname"] for r in rows]


def latency_color(ms):
    return "🟢" if ms < 50 else ("🟠" if ms < 250 else "🔴")


# ── Data fetch (timed — this is the demo) ─────────────────────────────────────

read_path = st.radio("Read path (demo)", list(READ_PATHS), horizontal=True,
                     label_visibility="collapsed")

try:
    latest, latency_ms = query(
        LATEST_TELEMETRY_SQL.format(hint=READ_PATHS[read_path]))
except Exception as exc:
    st.error(f"Cannot query telemetry — is the cluster up and `make setup` done? ({exc})")
    st.stop()

try:
    stats, _ = query("SELECT inserts_per_sec, updated_at FROM ingest_stats WHERE id = 1")
except Exception:
    stats = []

df = pd.DataFrame(latest)
if not df.empty:
    df["name"] = df["norad_id"].map(get_satellite_names()).fillna("(unknown)")

# ── Header ────────────────────────────────────────────────────────────────────

title_col, m1, m2, m3 = st.columns([3, 1, 1, 1])
title_col.markdown("## 🛰️ Mission Control")
m1.metric(f"{latency_color(latency_ms)} Telemetry refresh",
          f"{latency_ms:,.0f} ms",
          help="Wall-clock time of: SELECT … FROM telemetry ORDER BY ts DESC LIMIT 100")
if stats and stats[0]["inserts_per_sec"] is not None:
    m2.metric("📡 Ingest rate", f"{stats[0]['inserts_per_sec']:,.0f}/s",
              help="As reported by ingest.py — drops when writes contend on a hot tablet")
else:
    m2.metric("📡 Ingest rate", "—", help="Start `make load` to begin live ingest")
if not df.empty:
    age_s = (pd.Timestamp.now(tz="UTC") - df["ts"].max()).total_seconds()
    m3.metric("🕐 Data age", f"{age_s:,.1f} s",
              help="Now minus the newest reading on the dashboard")

indexes = get_indexes()
st.caption("Secondary indexes on telemetry: "
           + (", ".join(f"`{i}`" for i in indexes) if indexes else "none"))

# ── Map ───────────────────────────────────────────────────────────────────────

if not df.empty:
    others = df[df["norad_id"] != ISS_NORAD_ID]
    iss = df[df["norad_id"] == ISS_NORAD_ID]
    fig = go.Figure()
    fig.add_trace(go.Scattergeo(
        lat=others["latitude"], lon=others["longitude"],
        text=others["name"] + "<br>alt " + others["altitude_km"].astype(str)
             + " km · " + others["velocity_kms"].astype(str) + " km/s",
        mode="markers", name="fleet",
        marker=dict(size=7, color="#636efa", opacity=0.75)))
    if not iss.empty:
        fig.add_trace(go.Scattergeo(
            lat=iss["latitude"], lon=iss["longitude"],
            text="ISS (ZARYA) — the real one, right now",
            mode="markers+text", textposition="top center", name="ISS",
            textfont=dict(size=13, color="#ef553b"),
            marker=dict(size=14, color="#ef553b", symbol="star"),
            texttemplate="ISS"))
    fig.update_geos(projection_type="natural earth", showcountries=True,
                    landcolor="#1e2530", oceancolor="#0e1117", showocean=True,
                    countrycolor="#39414d", coastlinecolor="#39414d", bgcolor="rgba(0,0,0,0)")
    fig.update_layout(margin=dict(l=0, r=0, t=0, b=0), height=420,
                      showlegend=False, paper_bgcolor="rgba(0,0,0,0)")
    st.plotly_chart(fig, use_container_width=True)
    st.caption(f"Latest {len(df)} readings · {df['norad_id'].nunique()} satellites in view")

# ── Write-distribution heat ───────────────────────────────────────────────────

st.markdown(f"#### Where are the last {HEAT_SAMPLE:,} readings stored?")

try:
    heat_rows, _ = query(HEAT_SAMPLE_SQL)
    heat = pd.DataFrame(heat_rows)
except Exception:
    heat = pd.DataFrame()

if not heat.empty:
    c1, c2, c3 = st.columns(3)

    def bars(col, title, counts, color):
        series = [counts.get(i, 0) for i in range(NUM_BUCKETS)]
        fig = go.Figure(go.Bar(
            x=series, y=[f"tablet {i + 1}" for i in range(NUM_BUCKETS)],
            orientation="h", marker_color=color))
        fig.update_layout(title=dict(text=title, font=dict(size=14)),
                          height=230, margin=dict(l=0, r=0, t=30, b=0),
                          xaxis=dict(range=[0, HEAT_SAMPLE]),
                          yaxis=dict(autorange="reversed"),
                          paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)")
        col.plotly_chart(fig, use_container_width=True)

    # Base table: hash of the PK against the 6 equal SPLIT INTO ranges
    base_counts = (heat["row_hash"] // (65536 // NUM_BUCKETS)).clip(
        upper=NUM_BUCKETS - 1).value_counts().to_dict()
    bars(c1, "base table — hash (PK)", base_counts, "#636efa")

    # Range index: timestamps against the recorded split points
    splits = get_range_split_points()
    if any(i.endswith("by_time") for i in indexes) and splits:
        bounds = [pd.Timestamp(s["lower_ts"]) for s in splits]
        ts = pd.to_datetime(heat["ts"], utc=True)
        tablet = pd.Series(0, index=heat.index)
        for b in bounds:  # bounds ascend; newest range = highest ordinal
            tablet += (ts >= b).astype(int)
        bars(c2, "range index — by time", tablet.value_counts().to_dict(), "#ef553b")
    else:
        c2.markdown("**range index — by time**")
        c2.caption("not created yet")

    # Bucket index: yb_hash_code(ts) % 6
    if any(i.endswith("by_bucket") for i in indexes):
        bars(c3, "bucket index — hash(ts) % 6", heat["bucket"].value_counts().to_dict(),
             "#00cc96")
    else:
        c3.markdown("**bucket index — hash(ts) % 6**")
        c3.caption("not created yet")

    st.caption("Every write lands in exactly one tablet per layout. "
               "One tall bar = one hot tablet = one node doing all the work.")
