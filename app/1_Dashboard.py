"""Mission Control: the business app for the bucket index demo.

One page, deliberately thin:
  - world map of the latest telemetry (ISS, Hubble, and CSS highlighted)
  - the refresh latency of the ONE query that carries the demo
  - ingest throughput as reported by ingest.py
  - write-distribution heat per storage layout (base table / range index / bucket index)

The dashboard's own refresh latency IS the demo's problem statement.

Run: make dash  (streamlit run app/1_Dashboard.py)
"""

import pandas as pd
import plotly.graph_objects as go
import streamlit as st

from db import query

st.set_page_config(page_title="Mission Control", page_icon="🛰️", layout="wide")

# Featured spacecraft: star markers + colored ground tracks on the map.
# Everyone else is a small dot. NORAD IDs match tle_snapshot.json / ingest.py.
TRACKED_SATELLITES = {
    25544: {"label": "ISS", "color": "#ef553b"},   # red
    20580: {"label": "HST", "color": "#fecb52"},   # gold, for the mirror
    48274: {"label": "CSS", "color": "#19d3f3"},   # cyan
}

REFRESH_MS = 3000
TELEMETRY_LIMIT = 500   # the one demo query; ~3.3 s of fleet at 150 writes/sec
GLOW_LIMIT = 100        # rows 1–100 of that batch = "newest 100 readings" glow
HEAT_SAMPLE = 5000      # rows sampled for the three tablet-distribution bar charts
NUM_BUCKETS = 6         # telemetry SPLIT INTO and bucket-index modulus

# ── SQL ───────────────────────────────────────────────────────────────────────
# One query for everything: timed metric, map feed, glow membership. Accepts a
# {hint} prefix (pg_hint_plan) so the presenter can force the same read path
# the walkthrough EXPLAINs show. Names are joined client-side so this string
# stays byte-identical to the walkthrough.

TELEMETRY_SQL = f"""{{hint}}
    SELECT norad_id, ts, latitude, longitude, altitude_km, velocity_kms
    FROM telemetry
    ORDER BY ts DESC
    LIMIT {TELEMETRY_LIMIT}
"""

# Rows for the heat charts: bucket (for bucket index), row_hash and ts (for
# base table and range index tablet assignment). Not timed; not part of the demo.
HEAT_SAMPLE_SQL = f"""
    SELECT yb_hash_code(ts) % {NUM_BUCKETS} AS bucket,
           yb_hash_code(reading_id) AS row_hash,
           ts
    FROM telemetry ORDER BY ts DESC LIMIT {HEAT_SAMPLE}
"""


def read_paths(indexes):
    """Build read-path radio options from indexes that actually exist.

    No stored "mode": lab vs demo is whether secondary indexes are present.
    Options appear/disappear as the learner creates or drops indexes.
    """
    paths = {"auto (planner picks)": ""}
    if indexes:
        # Forcing a seq scan only contrasts with an index once one exists.
        paths["no index (seq scan)"] = "/*+ SeqScan(telemetry) */"
    if "telemetry_by_time" in indexes:
        paths["range index"] = "/*+ IndexOnlyScan(telemetry telemetry_by_time) */"
    if "telemetry_by_bucket" in indexes:
        paths["bucket index"] = "/*+ IndexOnlyScan(telemetry telemetry_by_bucket) */"
    return paths


REFRESH_CHOICES = {"⏸ paused": None, "2s": 2000, "3s": 3000, "5s": 5000, "10s": 10000}


@st.cache_data(ttl=30)
def get_range_split_points():
    """Lower bounds of range-index tablets, written at index creation time."""
    try:
        rows, _ = query(
            "SELECT ordinal, lower_ts FROM range_split_points ORDER BY ordinal")
        return rows
    except Exception:
        return []


@st.cache_data(ttl=300)
def get_satellite_names():
    """NORAD id → name for map hovers (not joined into the timed query)."""
    rows, _ = query("SELECT norad_id, name FROM satellites")
    return {r["norad_id"]: r["name"] for r in rows}


@st.cache_data(ttl=5)
def get_indexes():
    """VALID secondary indexes on telemetry; drives read-path radio and panels.

    Validity matters: an index mid-backfill (or one an interrupted backfill
    left invalid) is ignored by the planner, so offering it as a read path
    would show a hint that silently does nothing. to_regclass keeps this
    harmless before setup has created the table.
    """
    rows, _ = query("""
        SELECT indexrelid::regclass::text AS indexname
        FROM pg_index
        WHERE indrelid = to_regclass('telemetry')
          AND indexrelid::regclass::text NOT LIKE '%pkey'
          AND indisvalid
        ORDER BY 1""")
    return [r["indexname"] for r in rows]


def latency_color(ms):
    """Traffic light for the demo query wall-clock time."""
    return "🟢" if ms < 50 else ("🟠" if ms < 250 else "🔴")


def append_trail(trail, lat, lon):
    """Grow a ground-track polyline; None breaks the line at the antimeridian."""
    pt = (lat, lon)
    if not trail or trail[-1] != pt:
        if trail and trail[-1] is not None and abs(trail[-1][1] - pt[1]) > 180:
            trail.append(None)
        trail.append(pt)
        del trail[:-120]


def build_map_figure(fleet, glow_ids, positions):
    """Build the fleet map figure (caller paints it)."""
    others = fleet[~fleet["norad_id"].isin(TRACKED_SATELLITES)]
    in_latest = others["norad_id"].isin(glow_ids)
    fresh, rest = others[in_latest], others[~in_latest]

    trails = st.session_state.setdefault("satellite_trails", {})
    names = get_satellite_names()
    for norad_id in TRACKED_SATELLITES:
        pos = positions.get(norad_id)
        if pos:
            append_trail(trails.setdefault(norad_id, []),
                         float(pos["latitude"]), float(pos["longitude"]))

    fig = go.Figure()
    fig.add_trace(go.Scattergeo(
        lat=rest["latitude"], lon=rest["longitude"],
        text=rest["name"] + "<br>alt " + rest["altitude_km"].astype(str)
             + " km · " + rest["velocity_kms"].astype(str) + " km/s",
        mode="markers", name="fleet",
        marker=dict(size=6, color="#636efa", opacity=0.35)))
    fig.add_trace(go.Scattergeo(
        lat=fresh["latitude"], lon=fresh["longitude"],
        text=fresh["name"] + "<br>alt " + fresh["altitude_km"].astype(str)
             + " km · " + fresh["velocity_kms"].astype(str) + " km/s · in newest 100",
        mode="markers", name="in newest 100 readings",
        marker=dict(size=8, color="#9aa7ff", opacity=1.0)))
    for norad_id, style in TRACKED_SATELLITES.items():
        color, label = style["color"], style["label"]
        trail = trails.get(norad_id, [])
        if trail:
            fig.add_trace(go.Scattergeo(
                lat=[p[0] if p else None for p in trail],
                lon=[p[1] if p else None for p in trail],
                mode="lines", name=f"{label} track",
                line=dict(color=color, width=1.5), opacity=0.6,
                hoverinfo="skip"))
        pos = positions.get(norad_id)
        if not pos:
            continue
        fig.add_trace(go.Scattergeo(
            lat=[pos["latitude"]], lon=[pos["longitude"]],
            text=f"{names.get(norad_id, label)}: the real one, right now",
            mode="markers+text", textposition="top center", name=label,
            textfont=dict(size=13, color=color),
            marker=dict(size=14, color=color, symbol="star"),
            texttemplate=label))
    # showland stays OFF: unfilled continents pick up the page background
    # (white on a light theme), which reads far better than any fill we tried.
    fig.update_geos(projection_type="natural earth", showcountries=True,
                    landcolor="#1e2530", oceancolor="#0e1117", showocean=True,
                    countrycolor="#39414d", coastlinecolor="#39414d",
                    bgcolor="rgba(0,0,0,0)")
    fig.update_layout(margin=dict(l=0, r=0, t=0, b=0), height=420,
                      showlegend=False, paper_bgcolor="rgba(0,0,0,0)")
    return fig


def paint_metrics(slots, latency_ms, ingest_rate, data_age_s):
    """Write the three headline metrics into empty() slots.

    Always paints all three: a value of None or False renders as an em-dash
    placeholder. On a brand-new session the labels are on screen before the
    first query returns, so values fill in without the row assembling
    piece by piece.
    """
    m1_ph, m2_ph, m3_ph = slots
    if latency_ms is not None:
        m1_ph.metric(f"{latency_color(latency_ms)} Telemetry refresh",
                     f"{latency_ms:,.0f} ms",
                     help=f"Wall-clock time of: SELECT … FROM telemetry "
                          f"ORDER BY ts DESC LIMIT {TELEMETRY_LIMIT}")
    else:
        m1_ph.metric("⚪ Telemetry refresh", "—",
                     help=f"Wall-clock time of: SELECT … FROM telemetry "
                          f"ORDER BY ts DESC LIMIT {TELEMETRY_LIMIT}")
    if ingest_rate not in (None, False):
        m2_ph.metric("📡 Ingest rate", f"{ingest_rate:,.0f}/s",
                     help="As reported by ingest.py; drops when writes contend on a hot tablet")
    else:
        m2_ph.metric("📡 Ingest rate", "—",
                     help="Start `make load` to begin live ingest")
    if data_age_s not in (None, False):
        m3_ph.metric("🕐 Data age", f"{data_age_s:,.1f} s",
                     help="Now minus the newest reading on the dashboard")
    else:
        m3_ph.metric("🕐 Data age", "—")


def render_heat(indexes):
    """Same HEAT_SAMPLE rows, three tablet assignments. One tall bar = hot tablet."""
    st.markdown(f"#### Where are the last {HEAT_SAMPLE:,} readings stored?")
    try:
        heat_rows, _ = query(HEAT_SAMPLE_SQL)
        heat = pd.DataFrame(heat_rows)
    except Exception as exc:
        st.caption(f"heat charts unavailable: {exc}")
        return
    if heat.empty:
        return

    c1, c2, c3 = st.columns(3)

    def bars(col, title, counts, color, key):
        series = [counts.get(i, 0) for i in range(NUM_BUCKETS)]
        fig = go.Figure(go.Bar(
            x=series, y=[f"tablet {i + 1}" for i in range(NUM_BUCKETS)],
            orientation="h", marker_color=color))
        fig.update_layout(title=dict(text=title, font=dict(size=14)),
                          height=230, margin=dict(l=0, r=0, t=30, b=0),
                          xaxis=dict(range=[0, HEAT_SAMPLE]),
                          yaxis=dict(autorange="reversed"),
                          paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)")
        col.plotly_chart(fig, key=key)

    # Base table: which hash-PK tablet (6 equal ranges from SPLIT INTO).
    base_counts = (heat["row_hash"] // (65536 // NUM_BUCKETS)).clip(
        upper=NUM_BUCKETS - 1).value_counts().to_dict()
    bars(c1, "base table (hash PK)", base_counts, "#636efa", "heat_base")

    # Range index: which time-range tablet (split points from index creation).
    splits = get_range_split_points()
    if any(i.endswith("by_time") for i in indexes) and splits:
        bounds = [pd.Timestamp(s["lower_ts"]) for s in splits]
        ts = pd.to_datetime(heat["ts"], utc=True)
        tablet = pd.Series(0, index=heat.index)
        for b in bounds:
            tablet += (ts >= b).astype(int)
        bars(c2, "range index (by time)", tablet.value_counts().to_dict(),
             "#ef553b", "heat_range")
    else:
        c2.markdown("**range index (by time)**")
        c2.caption("not created yet")

    # Bucket index: yb_hash_code(ts) % 6 — writes spread, reads merge.
    if any(i.endswith("by_bucket") for i in indexes):
        bars(c3, "bucket index (hash(ts) % 6)", heat["bucket"].value_counts().to_dict(),
             "#00cc96", "heat_bucket")
    else:
        c3.markdown("**bucket index (hash(ts) % 6)**")
        c3.caption("not created yet")

    st.caption("Every write lands in exactly one tablet per layout. "
               "One tall bar = one hot tablet = one node doing all the work.")


# ── Page shell (renders once; never reruns on the timer) ───────────────────────
# The controls and title live out here. Only live_view() below reruns on the
# refresh clock, so the page never dims or reflows: the earlier whole-page
# st_autorefresh blocked on the slow query mid-render and jumped the layout.

indexes = get_indexes()
paths = read_paths(indexes)

# A remembered selection can point at an index that was just dropped (lab
# mode). Clear it so the radio falls back to "auto" instead of erroring.
if st.session_state.get("read_path") not in paths:
    st.session_state.pop("read_path", None)

st.markdown("## 🛰️ Mission Control")
path_col, refresh_col = st.columns([3, 2])
read_path = path_col.radio("Read path (demo)", list(paths), horizontal=True,
                           label_visibility="collapsed", key="read_path")
refresh_choice = refresh_col.radio("Refresh", list(REFRESH_CHOICES), index=2,
                                   horizontal=True, label_visibility="collapsed",
                                   key="refresh_choice")

# Refresh cadence is recomputed each time the fragment runs (the seq-scan path
# is slow enough that a fixed 2s would queue queries). The floor stays at 1.5x
# the last measured query time; None means paused.
base_ms = REFRESH_CHOICES[refresh_choice]
last_ms = st.session_state.get("last_latency_ms", 0)
run_every = None
if base_ms is not None:
    run_every = max(base_ms, int(last_ms * 1.5) + 250) / 1000.0


@st.fragment(run_every=run_every)
def live_view():
    # The fragment reruns on the clock; the shell (radio options, this
    # closure's `indexes`) does not. Re-check the catalog each tick and
    # rebuild the whole page when it changes, so a lab user's CREATE or
    # DROP INDEX lights up the radio and panels without a manual click.
    if get_indexes() != indexes:
        st.rerun(scope="app")

    # Emit the whole above-the-fold block BEFORE the timed query, painting the
    # last tick's values, then swap in fresh ones once the query returns.
    # Fragment ticks don't need this (verified on 1.50: a rerun leaves prior
    # content on screen until each element is re-emitted), but app-level reruns
    # (radio click, index-change rerun) and brand-new sessions do: there the
    # fragment's output doesn't exist yet, and without the fixed-height boxes
    # and early paint the metrics and map assemble on screen piece by piece,
    # shoving everything below down as each one lands.
    metrics_box = st.container(height=140, border=False)
    m1, m2, m3 = metrics_box.columns(3)
    metric_slots = (m1.empty(), m2.empty(), m3.empty())
    paint_metrics(
        metric_slots,
        st.session_state.get("last_latency_ms"),
        st.session_state.get("last_ingest_rate"),
        st.session_state.get("last_data_age_s"),
    )

    st.caption("Secondary indexes on telemetry: "
               + (", ".join(f"`{i}`" for i in indexes) if indexes else
                  "none. LAB mode: build them in sql/lab/walkthrough.sql"))

    map_box = st.container(height=420, border=False)
    map_ph = map_box.empty()
    if st.session_state.get("last_map_fig") is not None:
        map_ph.plotly_chart(st.session_state["last_map_fig"],
                            use_container_width=True, key="fleet_map_last_tick")

    fleet_cap_ph = st.empty()
    if st.session_state.get("last_fleet_count"):
        fleet_cap_ph.caption(
            f"{st.session_state['last_fleet_count']} satellites at latest known position")

    hint = paths.get(st.session_state["read_path"], "")
    try:
        latest, latency_ms = query(TELEMETRY_SQL.format(hint=hint))
    except Exception as exc:
        st.error(f"Cannot query telemetry. Is the cluster up and `make setup` "
                 f"(or `make setup-lab`) done? See the Controls page. ({exc})")
        return
    st.session_state["last_latency_ms"] = latency_ms

    try:
        stats, _ = query(
            "SELECT inserts_per_sec, updated_at FROM ingest_stats WHERE id = 1")
    except Exception:
        stats = []

    df = pd.DataFrame(latest)
    # Glow = norad_ids in rows 1–100 (newest 100 readings, not 100 sats).
    glow_ids = set(df.head(GLOW_LIMIT)["norad_id"]) if not df.empty else set()

    # Map: dedupe the batch (newest-first → first row per norad_id wins), merge
    # into a persistent store so sats missing this batch keep their last spot.
    positions = st.session_state.setdefault("last_positions", {})
    if not df.empty:
        for row in df.drop_duplicates("norad_id", keep="first").to_dict("records"):
            positions[int(row["norad_id"])] = row
    fleet = pd.DataFrame(positions.values()) if positions else pd.DataFrame()
    if not fleet.empty:
        fleet["name"] = fleet["norad_id"].map(get_satellite_names()).fillna("(unknown)")

    ingest_rate = None
    if stats and stats[0]["inserts_per_sec"] is not None:
        ingest_rate = stats[0]["inserts_per_sec"]
        st.session_state["last_ingest_rate"] = ingest_rate
    else:
        st.session_state["last_ingest_rate"] = False
        ingest_rate = False

    data_age_s = None
    if not df.empty:
        data_age_s = (pd.Timestamp.now(tz="UTC") - df["ts"].max()).total_seconds()
        st.session_state["last_data_age_s"] = data_age_s
    else:
        st.session_state["last_data_age_s"] = False
        data_age_s = False

    paint_metrics(metric_slots, latency_ms, ingest_rate, data_age_s)

    if not fleet.empty:
        fig = build_map_figure(fleet, glow_ids, positions)
        st.session_state["last_map_fig"] = fig
        map_ph.plotly_chart(fig, use_container_width=True, key="fleet_map_fresh")
        st.session_state["last_fleet_count"] = len(fleet)
        fleet_cap_ph.caption(f"{len(fleet)} satellites at latest known position")

    render_heat(indexes)


live_view()
