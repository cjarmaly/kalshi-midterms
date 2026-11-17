Forecast Accuracy in Kalshi's 2026 Congressional Markets

STAT 139 final project — Charlie Scheuermann, Kiran Bishop, Christian Armaly

Which race and market characteristics are associated with larger Kalshi forecast errors in the 2026 U.S. House and Senate elections? Unit of analysis: one race (435 House + 33 Senate + 2 specials), joined to its Kalshi market, FEC fundraising, certified/AP vote margins, and 2024 presidential margins.

This repo currently holds the raw data pull only. Nothing in raw_*/ has been cleaned or edited by hand; cleaning will live in analysis/ and write to clean/.

Layout
pull/            scripts that produced the raw Kalshi and results files
raw_kalshi/      Kalshi market data (pulled 2026-11-14)
raw_fec/         FEC campaign-finance files (pulled 2026-11-14)
raw_results/     Wikipedia election-results tables (pulled 2026-11-14)
raw_pres2024/    2024 presidential results by district and by state
Sources
Kalshi — raw_kalshi/ (pull/kalshi_pull.py)

Public trade API, https://api.elections.kalshi.com/trade-api/v2 (no key required).

file	contents
kalshi_events_raw.csv	one row per race event (e.g. "NC-11 House winner?") with race_key (H-NC-11, SEN-NC, SEN-OHS = Ohio special), chamber, state, district, and primary_event_for_race (flags the party-based event when a race also has a named-candidate "(Person)" event)
kalshi_markets_raw.csv	one row per contract (D, R, occasionally a third party) — result, status, volume_fp, open_interest_fp, last_price_dollars, close_time, settlement_ts, yes_sub_title (candidate), rules_primary, … as returned by GET /markets/{ticker}
kalshi_candles_daily_raw.csv	one row per contract per day, Jul 1 – Nov 5 2026: open/high/low/close/mean price, volume, open interest, yes-bid/ask. Daily candles end at midnight Eastern (end_period_utc = 05:00Z), so the candle ending 2026-11-03 05:00Z is the close of Nov 2 ET, the last full pre-election day
kalshi_candles_hourly_raw.csv	one row per contract per hour, Nov 2–3 ET, for an intraday pre-polls-close price on Election Day

Notes: prices are in dollars (0–1) and equal implied probability; volume is in contracts. Kalshi used three naming schemes for House races (KXHOUSERACE-XX##-26, HOUSEXX#-26, KXHOUSEXX##-26); the script keys all of them by state + district. The event ticker SENATELA-26 is actually Kentucky (Kalshi labeling error); Louisiana is KXSENATELA-26NOV. No Alabama Senate market exists. Alaska Senate was still unsettled (status = active) at pull time. DC-AL appears as a market but is a non-voting delegate seat.

FEC — raw_fec/
weball26.txt — FEC bulk "Candidate summary" file, 2025–26 cycle (https://www.fec.gov/files/bulk-downloads/2026/weball26.zip). Pipe-delimited, no header row; the 30 column names are in the FEC all-candidates file description. Key fields: TTL_RECEIPTS, TTL_INDIV_CONTRIB, OTHER_POL_CMTE_CONTRIB (PAC), CAND_ICI (I/C/O), CAND_OFFICE_ST, CAND_OFFICE_DISTRICT (00 = Senate and at-large House; use the H/S prefix of CAND_ID), CVG_END_DT (pre-general report, through 2026-10-14).
fec_independent_expenditures_2026.csv — Schedule E export from https://www.fec.gov/data/independent-expenditures/ (two-year period 2026, processed data, House + Senate), exported 2026-11-14. 51,081 rows; one row per expenditure with candidate_id, support_oppose_indicator, expenditure_amount, election_type (G2026 = general). ~10% of rows have no candidate_id; all rows are 24/48-hour notices (is_notice = t).
Election results — raw_results/ (pull/results_pull.py)

Every HTML table from the Wikipedia pages for the 2026 Senate elections, the national House elections page, and each state's House elections page, dumped untouched as <page>_table_<k>.csv. index.csv lists each file with its page, table number, row count, and column headers; the district-level candidate/party/votes/% tables are on the state pages. Some races may still have been uncalled at pull time. To be replaced with certified results (MIT Election Lab) if available before the paper is due.

2024 presidential margins — raw_pres2024/
downballot_pres2024_by_cd.csv — The Downballot (formerly Daily Kos Elections), 2024 presidential results by congressional district, calculated on the 2026 district lines (sheet, methodology). Margin = Democratic share − Republican share.
wiki_pres2024_table_<k>.csv — results-by-state table from the Wikipedia 2024 presidential election page, for Senate races.
Reproducing the pull
pip install requests pandas lxml
python pull/kalshi_pull.py          # ~10 min; add --trades for per-trade data (large)
python pull/results_pull.py

FEC and presidential files are manual downloads from the links above.

Rules for this repo
raw_*/ is read-only. Never edit a raw file by hand.
All cleaning and joins go in scripts under analysis/ that read raw_*/ and write clean/.
Work on a branch and open a pull request for changes to shared scripts.
