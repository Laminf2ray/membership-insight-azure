"""
Generate synthetic membership data for the Membership Insight Pipeline.

All data is synthetic (Faker, en_GB locale, example.com emails). A fixed
random seed makes every run identical, so the CSVs never need to be committed.

Deliberate data-quality issues are injected so the cleaning stage (Day 4)
has real work to do. Every injected issue is counted in data/dq_injected.json,
so the clean-up can later be reconciled against it.

Output (in data/):
  members.csv, events.csv, attendance.csv, survey_responses.csv,
  web_sessions.csv, dq_injected.json

Run from the project root:
  python src\\generate\\generate_data.py
"""

import json
from datetime import date, datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd
from faker import Faker

# ---------------------------------------------------------------- settings
SEED = 42
N_MEMBERS = 5_000
N_EVENTS = 60
N_SESSIONS = 40_000
START = date(2021, 1, 1)
END = date(2026, 9, 30)

OUT = Path(__file__).resolve().parents[2] / "data"

rng = np.random.default_rng(SEED)
Faker.seed(SEED)
fake = Faker("en_GB")

REGIONS = [
    "Scotland", "Wales", "Northern Ireland", "North East", "North West",
    "Yorkshire and the Humber", "East Midlands", "West Midlands",
    "East of England", "London", "South East", "South West",
]
REGION_P = [0.08, 0.05, 0.03, 0.04, 0.11, 0.08, 0.07, 0.09, 0.09, 0.14, 0.14, 0.08]

ROLES = [
    "Diagnostic Radiographer", "Therapeutic Radiographer", "Sonographer",
    "Assistant Practitioner", "Student", "Manager",
]
ROLE_P = [0.45, 0.15, 0.08, 0.10, 0.15, 0.07]

# Topic popularity drives registrations; quality drives feedback scores.
TOPIC_POPULARITY = {
    "AI in imaging": 1.8, "Radiation safety": 1.2, "Leadership": 0.8,
    "MRI safety": 1.1, "Paediatric imaging": 0.9, "Research skills": 0.7,
    "Wellbeing": 1.0, "Ultrasound": 1.0, "Radiotherapy planning": 0.8,
    "Professional standards": 0.9,
}
TOPICS = list(TOPIC_POPULARITY)
TOPIC_QUALITY = {t: rng.uniform(3.2, 4.6) for t in TOPICS}
EVENT_TYPES = ["Webinar", "Study Day", "Workshop", "Masterclass", "Update"]

# Hidden effects that create real patterns for the analysis to find.
REGION_EFFECT = {r: rng.normal(0, 0.6) for r in REGIONS}
ROLE_EFFECT = {r: rng.normal(0, 0.5) for r in ROLES}


def rand_date(a: date, b: date) -> date:
    return a + timedelta(days=int(rng.integers(0, (b - a).days + 1)))


# ----------------------------------------------------------------- members
members, engagement = [], {}
for i in range(1, N_MEMBERS + 1):
    mid = f"M{i:05d}"
    role = str(rng.choice(ROLES, p=ROLE_P))
    region = str(rng.choice(REGIONS, p=REGION_P))
    join = rand_date(START, END - timedelta(days=30))
    eng = float(rng.beta(2, 3))  # hidden engagement propensity, not exported
    engagement[mid] = eng

    mtype = "Student" if role == "Student" else str(
        rng.choice(["Full", "Associate", "Retired"], p=[0.88, 0.07, 0.05]))

    u = rng.random()
    p_lapse = 0.05 + 0.45 * (1 - eng) ** 2
    if u < 0.03:
        status = "Cancelled"
    elif u < 0.03 + p_lapse and (END - join).days > 400:
        status = "Lapsed"
    else:
        status = "Active"

    if status == "Active":
        renewal = max(join, END - timedelta(days=int(rng.integers(0, 365))))
    else:
        renewal = max(join, END - timedelta(days=int(rng.integers(395, 900))))

    first, last = fake.first_name(), fake.last_name()
    members.append({
        "member_id": mid, "first_name": first, "last_name": last,
        "email": f"{first}.{last}{i}@example.com".lower().replace(" ", ""),
        "region": region, "role": role, "membership_type": mtype,
        "join_date": join, "status": status, "last_renewal_date": renewal,
    })
members = pd.DataFrame(members)

# ------------------------------------------------------------------ events
events = []
for i in range(1, N_EVENTS + 1):
    topic = str(rng.choice(TOPICS))
    fmt = str(rng.choice(["Online", "In-person", "Hybrid"], p=[0.5, 0.3, 0.2]))
    events.append({
        "event_id": f"E{i:03d}",
        "title": f"{topic} {rng.choice(EVENT_TYPES)}",
        "topic": topic,
        "format": fmt,
        "event_date": rand_date(START, END),
        "region": "National" if fmt == "Online" else str(rng.choice(REGIONS, p=REGION_P)),
        "cpd_hours": float(rng.choice([1, 1.5, 2, 3, 6])),
        "capacity": 500 if fmt == "Online" else int(rng.integers(40, 151)),
    })
events = pd.DataFrame(events)

# -------------------------------------------------------------- attendance
attendance = []
ev_dates = events["event_date"].to_numpy()
for m in members.itertuples(index=False):
    eng = engagement[m.member_id]
    n = int(rng.poisson(eng * 6))
    eligible = events[ev_dates >= m.join_date]
    if n == 0 or eligible.empty:
        continue
    w = eligible["topic"].map(TOPIC_POPULARITY).to_numpy()
    w = w * np.where(eligible["format"] == "Online", 1.3, 1.0)
    w = w * np.where(eligible["region"].isin([m.region, "National"]), 1.5, 0.6)
    picks = rng.choice(len(eligible), size=min(n, len(eligible)), replace=False, p=w / w.sum())
    for ev in eligible.iloc[picks].itertuples(index=False):
        attended = rng.random() < 0.55 + 0.35 * eng
        score = None
        if attended and rng.random() < 0.6:
            score = int(np.clip(round(rng.normal(TOPIC_QUALITY[ev.topic], 0.8)), 1, 5))
        attendance.append({
            "member_id": m.member_id, "event_id": ev.event_id,
            "registered_date": ev.event_date - timedelta(days=int(rng.integers(1, 46))),
            "attended": "Y" if attended else "N", "feedback_score": score,
        })
attendance = pd.DataFrame(attendance)
attendance.insert(0, "attendance_id", [f"A{i:06d}" for i in range(1, len(attendance) + 1)])

# ------------------------------------------------------------------ survey
survey = []
for year in range(2022, 2026):
    for m in members.itertuples(index=False):
        sdate = date(year, 10, int(rng.integers(1, 29)))
        eng = engagement[m.member_id]
        if m.join_date > sdate or rng.random() > 0.15 + 0.45 * eng:
            continue
        sat = int(np.clip(round(rng.normal(
            3.5 + 5 * eng + REGION_EFFECT[m.region] + ROLE_EFFECT[m.role], 1.4)), 1, 10))
        survey.append({
            "member_id": m.member_id, "survey_date": sdate, "satisfaction": sat,
            "likely_to_recommend": int(np.clip(round(sat + rng.normal(0, 1.2)), 0, 10)),
        })
survey = pd.DataFrame(survey)
survey.insert(0, "response_id", [f"R{i:06d}" for i in range(1, len(survey) + 1)])

# ------------------------------------------------------------ web sessions
ids = members["member_id"].to_numpy()
w = np.array([engagement[i] for i in ids])
who = rng.choice(ids, size=N_SESSIONS, p=w / w.sum()).astype(object)
anon = rng.random(N_SESSIONS) < 0.15
who[anon] = None
span = int((datetime.combine(END, datetime.min.time())
            - datetime.combine(START, datetime.min.time())).total_seconds())
starts = [datetime.combine(START, datetime.min.time()) + timedelta(seconds=int(s))
          for s in rng.integers(0, span, N_SESSIONS)]
pages = rng.poisson(3, N_SESSIONS) + 1
sessions = pd.DataFrame({
    "session_id": [f"S{i:06d}" for i in range(1, N_SESSIONS + 1)],
    "member_id": who,
    "session_start": starts,
    "device": rng.choice(["Desktop", "Mobile", "Tablet"], N_SESSIONS, p=[0.5, 0.42, 0.08]),
    "source": rng.choice(["Direct", "Email", "Search", "Social"], N_SESSIONS, p=[0.3, 0.3, 0.3, 0.1]),
    "pages_viewed": pages,
    "duration_seconds": (pages * rng.gamma(2.0, 30.0, N_SESSIONS)).round().astype(int),
})

# ------------------------------------------------- inject data-quality issues
dq = {}


def sample_idx(df: pd.DataFrame, frac: float) -> pd.Index:
    return df.sample(frac=frac, random_state=int(rng.integers(1e9))).index


# Members: missing and inconsistent regions, messy emails, mixed date formats.
idx = sample_idx(members, 0.03)
members.loc[idx, "region"] = None
dq["members_region_missing"] = len(idx)

idx = sample_idx(members[members["region"].notna()], 0.02)
messy = {"North West": "NW", "London": "london ", "Scotland": " SCOTLAND"}
members.loc[idx, "region"] = members.loc[idx, "region"].map(
    lambda r: messy.get(r, r.lower() + " "))
dq["members_region_inconsistent"] = len(idx)

idx = sample_idx(members, 0.02)
members.loc[idx, "email"] = " " + members.loc[idx, "email"].str.upper() + " "
dq["members_email_messy"] = len(idx)

members["join_date"] = members["join_date"].map(lambda d: d.isoformat())
idx = sample_idx(members, 0.05)
members.loc[idx, "join_date"] = members.loc[idx, "join_date"].map(
    lambda s: datetime.fromisoformat(s).strftime("%d/%m/%Y"))
dq["members_join_date_ddmmyyyy"] = len(idx)

dups = members.sample(frac=0.01, random_state=SEED)
members = pd.concat([members, dups], ignore_index=True)
dq["members_duplicate_rows"] = len(dups)

# Attendance: orphan member IDs and duplicate rows.
idx = sample_idx(attendance, 0.005)
attendance.loc[idx, "member_id"] = [f"M9{int(x):04d}" for x in rng.integers(0, 9999, len(idx))]
dq["attendance_orphan_member_id"] = len(idx)

dups = attendance.sample(frac=0.01, random_state=SEED)
attendance = pd.concat([attendance, dups], ignore_index=True)
dq["attendance_duplicate_rows"] = len(dups)

# Survey: out-of-range and missing satisfaction scores.
survey["satisfaction"] = survey["satisfaction"].astype("Int64")
idx = sample_idx(survey, 0.005)
survey.loc[idx, "satisfaction"] = rng.choice([-1, 0, 11, 99], len(idx))
dq["survey_satisfaction_out_of_range"] = len(idx)

idx = sample_idx(survey[survey["satisfaction"].between(1, 10)], 0.01)
survey.loc[idx, "satisfaction"] = pd.NA
dq["survey_satisfaction_missing"] = len(idx)

# Web sessions: negative durations and future-dated sessions.
idx = sample_idx(sessions, 0.005)
sessions.loc[idx, "duration_seconds"] = -sessions.loc[idx, "duration_seconds"]
dq["sessions_negative_duration"] = len(idx)

idx = sample_idx(sessions, 0.003)
sessions.loc[idx, "session_start"] = sessions.loc[idx, "session_start"].map(
    lambda d: d.replace(year=2027))
dq["sessions_future_dated"] = len(idx)

# ------------------------------------------------------------------- write
OUT.mkdir(exist_ok=True)
tables = {
    "members": members, "events": events, "attendance": attendance,
    "survey_responses": survey, "web_sessions": sessions,
}
for name, df in tables.items():
    df.to_csv(OUT / f"{name}.csv", index=False)

dq["row_counts"] = {name: len(df) for name, df in tables.items()}
(OUT / "dq_injected.json").write_text(json.dumps(dq, indent=2))

for name, df in tables.items():
    print(f"{name:<18}{len(df):>8,} rows")
print(f"\nData-quality issues injected: see {OUT / 'dq_injected.json'}")
