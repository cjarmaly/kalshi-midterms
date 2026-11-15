"""
Kalshi 2026 U.S. House & Senate race-market puller  (STAT 139 final project)

Pulls RAW data from Kalshi's public trade API (no account or API key needed) and
writes four CSVs into ./raw_kalshi/ :

  kalshi_events_raw.csv         one row per race event (what Kalshi calls an "event":
                                  e.g. "NC-11 House winner?") with the series it lives in
  kalshi_markets_raw.csv        one row per market (each event has 2+ markets: the D
                                  contract, the R contract, sometimes a named candidate).
                                  All market fields straight from GET /markets/{ticker}:
                                  result, status, volume, open interest, close time, rules...
  kalshi_candles_daily_raw.csv  long format: one row per market per DAY, Jul 1 - Nov 5 2026
                                  (open/high/low/close/mean price, volume, open interest,
                                  yes-bid and yes-ask close).  Daily candles end at
                                  midnight US-Eastern (05:00 UTC).
  kalshi_candles_hourly_raw.csv long format: one row per market per HOUR for Nov 2-3 2026
                                  (use this to get a true "pre-polls-close" price on
                                  Election Day, e.g. the candle ending 18:00 ET Nov 3).
  kalshi_trades_raw.csv         (optional, --trades) every individual trade per market.
                                  Needed for trade_count.  Big for Senate markets.

Nothing is cleaned or derived here - every column is as returned by the API, plus a few
bookkeeping columns (race_key, chamber, state, district, special, person_market) that we
parse from the event title so you can join to FEC / results later.

How the markets are organized on Kalshi (learned by poking the API on 2026-11-14):
  * Most House races:   series KXHOUSERACE,  event KXHOUSERACE-<ST><DD>-26,  markets ...-D / ...-R
  * Some House races:   series HOUSE<ST><D>,  event HOUSE<ST><D>-26   (older naming, e.g. HOUSECA45-26)
                        series KXHOUSE<ST><DD>, event KXHOUSE<ST><DD>-26  (e.g. KXHOUSEUT03-26)
  * Senate races:       series SENATE<ST>,    event SENATE<ST>-26  (specials: SENATEOHS-26, SENATEFLS-26)
                        a few states also have a "(Person)" event with one market per
                        named candidate: KXMISENATE-26, KXMESENATEPERSON-26, KXIASENATE-26,
                        KXAKSENATE-26NOV03.  Louisiana is KXSENATELA-26NOV.
  * Kalshi quirk: the event SENATELA-26 is titled "Kentucky Senate winner?" - we key races
    by the TITLE (state name), not the ticker, so it lands under KY correctly.
  * No Alabama Senate market was found.  Alaska Senate was still unsettled on Nov 14.

Usage:
    pip install requests pandas
    python kalshi_pull.py            # events + markets + daily + hourly candles  (~10 min)
    python kalshi_pull.py --trades   # also pull every trade (adds a while; Senate markets
                                     # have tens of thousands of trades)

Be polite to the API: the script sleeps on HTTP 429 and retries.  If it dies midway,
just re-run - it skips markets it already has.
"""
import argparse, json, os, re, sys, time
from datetime import datetime, timezone

import pandas as pd
import requests

BASE = "https://api.elections.kalshi.com/trade-api/v2"
OUT = "raw_kalshi"
os.makedirs(OUT, exist_ok=True)
S = requests.Session()
S.headers["User-Agent"] = "stat139-final-project (student research)"


def get(url, params=None, tries=8):
    for a in range(tries):
        r = S.get(url, params=params, timeout=60)
        if r.status_code == 200:
            return r.json()
        if r.status_code == 429 or r.status_code >= 500:
            time.sleep(0.8 * (a + 1))
            continue
        raise RuntimeError(f"HTTP {r.status_code} {r.url} :: {r.text[:200]}")
    raise RuntimeError(f"gave up on {url}")


def paged(url, key, params=None, limit=200, max_pages=50):
    params = dict(params or {}, limit=limit)
    out, cursor = [], None
    for _ in range(max_pages):
        if cursor:
            params["cursor"] = cursor
        j = get(url, params)
        out += j.get(key, [])
        cursor = j.get("cursor")
        if not cursor:
            break
    return out


# ----------------------------------------------------------------------------------
# 1. find the series that hold House / Senate general-election race markets
# ----------------------------------------------------------------------------------
print("listing all series ...")
series = get(f"{BASE}/series", {"limit": 5000})["series"]
print(f"  {len(series)} series on the exchange")

EXCLUDE = re.compile(
    r"primary|nominee|primaries|runoff|state senate|state house|margin|within|closer|sweep|combo|"
    r"count|seats|control|turnout|counties|drop|committee|leader|speaker|whip|popular|generic|"
    r"AP call|advance|outright|ballot|endorse|votes|exact outcome|how many|which|japan|brazil|"
    r"italy|australia|colombia|paraguay|nigeria|chile|philippines|kenya|bolivia|sao paulo|"
    r"delegates|assembly", re.I)
cand = [x["ticker"] for x in series
        if x.get("category") == "Elections"
        and (re.search(r"house|senate|congress", x.get("title", ""), re.I)
             or re.match(r"^KX?(HOUSE|SENATE)", x["ticker"]) or x["ticker"].endswith("SENATE"))
        and not EXCLUDE.search(x.get("title", ""))]
print(f"  {len(cand)} candidate series (House/Senate-related)")

# ----------------------------------------------------------------------------------
# 2. pull every event (with nested markets) in those series
# ----------------------------------------------------------------------------------
events = []
for i, st in enumerate(cand, 1):
    evs = paged(f"{BASE}/events", "events", {"series_ticker": st, "with_nested_markets": "true"})
    for e in evs:
        e["_series"] = st
    events += evs
    if i % 25 == 0:
        print(f"  events: {i}/{len(cand)} series, {len(events)} events so far")
print(f"  {len(events)} events total")

# ----------------------------------------------------------------------------------
# 3. keep 2026 general-election race events and parse a race key from the title
# ----------------------------------------------------------------------------------
ST = {'alabama':'AL','alaska':'AK','arizona':'AZ','arkansas':'AR','california':'CA','colorado':'CO',
      'connecticut':'CT','delaware':'DE','florida':'FL','georgia':'GA','hawaii':'HI','idaho':'ID',
      'illinois':'IL','indiana':'IN','iowa':'IA','kansas':'KS','kentucky':'KY','louisiana':'LA',
      'maine':'ME','maryland':'MD','massachusetts':'MA','michigan':'MI','minnesota':'MN',
      'mississippi':'MS','missouri':'MO','montana':'MT','nebraska':'NE','nevada':'NV',
      'new hampshire':'NH','new jersey':'NJ','new mexico':'NM','new york':'NY','north carolina':'NC',
      'north dakota':'ND','ohio':'OH','oklahoma':'OK','oregon':'OR','pennsylvania':'PA',
      'rhode island':'RI','south carolina':'SC','south dakota':'SD','tennessee':'TN','texas':'TX',
      'utah':'UT','vermont':'VT','virginia':'VA','washington':'WA','west virginia':'WV',
      'wisconsin':'WI','wyoming':'WY'}


def is_race(e):
    t = e.get("title", "")
    return bool(re.search(r"(house|senate)\s+winner|win the (house|senate) race|who will win|"
                          r"house race for|senate race in|House [A-Z]{2}|HOUSE ", t, re.I)) \
        and not re.search(r"primary|nominee|runoff|state senate|state house|\(20(27|28|30|32)\)", t, re.I)


def is_2026(e):
    ms = e.get("markets") or []
    return any("2026-10-15" <= (m.get("close_time") or "") < "2027-03-01" for m in ms) \
        or bool(re.search(r"-26(NOV\d*)?$", e["event_ticker"])) \
        or any(m.get("status") == "active" and "2026-11-01" < (m.get("expected_expiration_time") or "") < "2027-03-01" for m in ms)


def race_key(e):
    t, k = e.get("title", ""), e["event_ticker"]
    if re.search(r"senate", t, re.I):
        st = next((a for n, a in ST.items() if re.match(rf"^{n}\b", t, re.I)), None)
        special = "S" if re.match(r"^SENATE[A-Z]{2}S-", k) else ""
        return dict(chamber="Senate", state=st, district="", special=special,
                    person_market=bool(re.search(r"person", t, re.I)), race_key=f"SEN-{st}{special}")
    m = re.search(r"\b([A-Z]{2})-(\d{1,2}|AL)\b", t) or re.search(r"HOUSE(?:RACE-|PARTY-)?([A-Z]{2})(\d{1,2}|AL)-", k)
    if not m:
        m2 = re.search(r"House\s+([A-Z]{2})\s*'?s?\s*(\d{1,2})", t, re.I) or \
             re.search(r"House\s+([A-Za-z ]+?)'?s?\s+(\d{1,2})(st|nd|rd|th)", t, re.I)
        if m2:
            st = m2.group(1).upper() if len(m2.group(1)) == 2 else ST.get(m2.group(1).lower())
            m = (None, st, m2.group(2))
        elif k == "KXALASKAHOUSE-26":
            m = (None, "AK", "AL")
        else:
            return None
    st, d = (m[1], m[2]) if isinstance(m, tuple) else (m.group(1), m.group(2))
    d = "AL" if d == "AL" else f"{int(d):02d}"
    sp = "S" if re.search(r"special", t, re.I) else ""
    return dict(chamber="House", state=st, district=d, special=sp,
                person_market=k == "KXALASKAHOUSE-26", race_key=f"H-{st}-{d}{sp}")


races = []
for e in events:
    if e["event_ticker"] in ("KXCLOSESTSENATE-27JAN03",) or e["event_ticker"].startswith("KXUSINDEPENDENTCONGRESS"):
        continue
    if not (is_race(e) or e["event_ticker"] == "KXALASKAHOUSE-26") or not is_2026(e):
        continue
    meta = race_key(e)
    if meta is None or meta["state"] is None:
        continue
    e.update(meta)
    races.append(e)

# several races have both a party-based event and a named-candidate "(Person)" event.
# Keep everything in the events file; flag which one we treat as primary (party markets first).
by_key = {}
for e in races:
    by_key.setdefault(e["race_key"], []).append(e)
for key, lst in by_key.items():
    lst.sort(key=lambda e: (len(e.get("markets") or []) == 0, e["person_market"]))
    for j, e in enumerate(lst):
        e["primary_event_for_race"] = (j == 0)

ev_rows = [{k: v for k, v in e.items() if k != "markets"} | {"n_markets": len(e.get("markets") or [])} for e in races]
pd.DataFrame(ev_rows).to_csv(f"{OUT}/kalshi_events_raw.csv", index=False)
print(f"  {len(races)} race events -> {len(by_key)} distinct races "
      f"({sum(1 for k in by_key if k.startswith('H-'))} House, {sum(1 for k in by_key if k.startswith('SEN-'))} Senate)")

# ----------------------------------------------------------------------------------
# 4. per-market detail + daily candles (Jul 1 - Nov 5) + hourly candles (Nov 2-3)
# ----------------------------------------------------------------------------------
def ts(s):
    return int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp())

D0, D1 = ts("2026-07-01T00:00:00"), ts("2026-11-05T12:00:00")
H0, H1 = ts("2026-11-02T05:00:00"), ts("2026-11-04T05:00:00")   # 00:00 ET Nov 2 -> 00:00 ET Nov 4

mk_path, cd_path, ch_path = (f"{OUT}/kalshi_markets_raw.csv", f"{OUT}/kalshi_candles_daily_raw.csv",
                             f"{OUT}/kalshi_candles_hourly_raw.csv")
done = set(pd.read_csv(mk_path)["ticker"]) if os.path.exists(mk_path) else set()

targets = [(e, m) for e in races for m in (e.get("markets") or [])]
print(f"pulling {len(targets)} markets ({len(done)} already on disk) ...")


def flat_candle(c, ticker, interval):
    p, b, a = c.get("price", {}), c.get("yes_bid", {}), c.get("yes_ask", {})
    return dict(ticker=ticker, interval_min=interval, end_period_ts=c["end_period_ts"],
                end_period_utc=datetime.fromtimestamp(c["end_period_ts"], timezone.utc).isoformat(),
                open=p.get("open_dollars"), high=p.get("high_dollars"), low=p.get("low_dollars"),
                close=p.get("close_dollars"), mean=p.get("mean_dollars"), previous=p.get("previous_dollars"),
                volume_fp=c.get("volume_fp"), open_interest_fp=c.get("open_interest_fp"),
                yes_bid_open=b.get("open_dollars"), yes_bid_close=b.get("close_dollars"),
                yes_ask_open=a.get("open_dollars"), yes_ask_close=a.get("close_dollars"))


MK_COLS = None

first = not os.path.exists(mk_path)
for i, (e, m) in enumerate(targets, 1):
    t = m["ticker"]
    if t in done:
        continue
    try:
        d = get(f"{BASE}/markets/{t}")["market"]
        cd = get(f"{BASE}/series/{e['_series']}/markets/{t}/candlesticks",
                 {"start_ts": D0, "end_ts": D1, "period_interval": 1440}).get("candlesticks", [])
        ch = get(f"{BASE}/series/{e['_series']}/markets/{t}/candlesticks",
                 {"start_ts": H0, "end_ts": H1, "period_interval": 60}).get("candlesticks", [])
    except Exception as ex:
        print("  !! ", t, ex)
        continue
    row = {k: (json.dumps(v) if isinstance(v, (dict, list)) else v) for k, v in d.items()}
    row.update(race_key=e["race_key"], chamber=e["chamber"], state=e["state"], district=e["district"],
               special=e["special"], person_market=e["person_market"],
               primary_event_for_race=e["primary_event_for_race"], series_ticker=e["_series"],
               event_title=e.get("title"))
    if MK_COLS is None:
        MK_COLS = list(row.keys()) if first else list(pd.read_csv(mk_path, nrows=0).columns)
    pd.DataFrame([row]).reindex(columns=MK_COLS).to_csv(mk_path, mode="a", header=first, index=False)
    pd.DataFrame([flat_candle(c, t, 1440) for c in cd]).to_csv(cd_path, mode="a", header=first, index=False)
    pd.DataFrame([flat_candle(c, t, 60) for c in ch]).to_csv(ch_path, mode="a", header=first, index=False)
    first = False
    done.add(t)
    if i % 50 == 0:
        print(f"  {i}/{len(targets)}")

# ----------------------------------------------------------------------------------
# 5. optional: every trade (for trade_count)
# ----------------------------------------------------------------------------------
if "--trades" in sys.argv:
    tr_path = f"{OUT}/kalshi_trades_raw.csv"
    have = set(pd.read_csv(tr_path, usecols=["ticker"])["ticker"]) if os.path.exists(tr_path) else set()
    first = not os.path.exists(tr_path)
    for i, (e, m) in enumerate(targets, 1):
        t = m["ticker"]
        if t in have:
            continue
        trades = paged(f"{BASE}/markets/trades", "trades", {"ticker": t}, limit=1000, max_pages=500)
        if trades:
            pd.DataFrame(trades).to_csv(tr_path, mode="a", header=first, index=False)
            first = False
        have.add(t)
        print(f"  trades {i}/{len(targets)} {t}: {len(trades)}")

print("done. files in ./raw_kalshi/")