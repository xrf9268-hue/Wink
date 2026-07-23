#!/usr/bin/env python3
"""Build a synthetic usage.db for Insights screenshots (no real user data).

Usage: make-demo-usage.py <output.db>

The schema and user_version MUST match PersistenceService
(requiredSchemaVersion = 3) or Wink wipes the file at launch.
"""
import datetime
import pathlib
import sqlite3
import sys
import zlib

out = pathlib.Path(sys.argv[1])
out.unlink(missing_ok=True)
db = sqlite3.connect(out)
db.executescript(
    """
CREATE TABLE daily_usage (
    shortcut_id TEXT NOT NULL,
    date        TEXT NOT NULL,
    count       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (shortcut_id, date)
);
CREATE TABLE usage_hourly (
    shortcut_id TEXT NOT NULL,
    date        TEXT NOT NULL,
    hour        INTEGER NOT NULL CHECK(hour BETWEEN 0 AND 23),
    count       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (shortcut_id, date, hour)
);
CREATE INDEX idx_usage_hourly_date_hour ON usage_hourly(date, hour);
CREATE INDEX idx_daily_usage_date ON daily_usage(date);
CREATE TABLE app_activations (
    bundle_id TEXT NOT NULL,
    date      TEXT NOT NULL,
    count     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (bundle_id, date)
);
CREATE INDEX idx_app_activations_date ON app_activations(date);
PRAGMA user_version = 3;
"""
)

S = "AAAAAAA1-0000-4000-8000-000000000001"
T = "AAAAAAA2-0000-4000-8000-000000000002"
N = "AAAAAAA3-0000-4000-8000-000000000003"
today = datetime.date.today()


def wobble(i, lo, hi):
    return lo + ((i * 7919 + 104729) % (hi - lo + 1))


def stable_seed(text):
    # hash() is randomized per process (PYTHONHASHSEED); crc32 is not.
    return zlib.crc32(text.encode())


HOURS = [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21]
WEIGHTS = [4, 9, 10, 7, 3, 2, 6, 8, 9, 8, 5, 3, 2, 1]
WSUM = sum(WEIGHTS)

for i in range(30):
    day = today - datetime.timedelta(days=i)
    if i == 16:
        continue  # one quiet day caps the streak at 16
    weekend = day.weekday() >= 5
    for sid, lo, hi in ((S, 9, 24), (T, 12, 30), (N, 3, 11)):
        total = wobble(i + stable_seed(sid) % 97, lo, hi)
        if weekend:
            total = max(1, total // 3)
        db.execute("INSERT INTO daily_usage VALUES (?,?,?)", (sid, day.isoformat(), total))
        left = total
        for h, w in zip(HOURS, WEIGHTS):
            c = min(round(total * w / WSUM), left)
            if c > 0:
                db.execute("INSERT INTO usage_hourly VALUES (?,?,?,?)", (sid, day.isoformat(), h, c))
                left -= c
        if left > 0:
            db.execute(
                "UPDATE usage_hourly SET count = count + ? WHERE shortcut_id=? AND date=? AND hour=10",
                (left, sid, day.isoformat()),
            )

# suggestion candidates: unbound apps with foreground activity — but only
# ones actually installed on THIS machine, or the Suggested card renders
# nothing on a different host.
CANDIDATES = [
    ("com.googlecode.iterm2", "/Applications/iTerm.app"),
    ("ru.keepcoder.Telegram", "/Applications/Telegram.app"),
    ("com.tinyspeck.slackmacgap", "/Applications/Slack.app"),
    ("com.google.Chrome", "/Applications/Google Chrome.app"),
    ("org.mozilla.firefox", "/Applications/Firefox.app"),
    ("com.microsoft.VSCode", "/Applications/Visual Studio Code.app"),
]
installed = [b for b, path in CANDIDATES if pathlib.Path(path).exists()][:2]
if not installed:
    print("warning: no suggestion candidates installed; Suggested card will be empty")
for i in range(7):
    day = today - datetime.timedelta(days=i)
    for rank, bundle in enumerate(installed):
        db.execute(
            "INSERT INTO app_activations VALUES (?,?,?)",
            (bundle, day.isoformat(), (3 + (i % 4)) if rank == 0 else (1 + (i % 2))),
        )

db.commit()
print("rows:", db.execute("SELECT COUNT(*) FROM usage_hourly").fetchone()[0])
db.close()
