# Forecast Accuracy in Kalshi's 2026 Congressional Markets

STAT 139 final project — Charlie Scheuermann, Kiran Bishop, Christian Armaly

Which race and market characteristics are associated with larger Kalshi forecast errors in the 2026
U.S. House and Senate elections? Unit of analysis: one race, joined to its Kalshi market, FEC fundraising,
vote margins, and 2024 presidential margins.

## Layout

```
kalshi_pull.py        pulls the raw Kalshi files (public API, no key)
results_pull_v2.py    pulls the raw Wikipedia results file
raw_kalshi/           Kalshi market data            (pulled 2026-11-14)
raw_fec/              FEC campaign-finance files    (pulled 2026-11-14)
raw_results/          Wikipedia election results    (pulled 2026-11-17)
raw_pres2024/         2024 presidential results by district and by state
analysis/
  build_dataset.R     reads raw_*/ and writes clean/   <- the only place cleaning happens
clean/
  races.csv           ONE ROW PER RACE (457): the analysis dataset
  codebook.md         definition of every column in races.csv
  results_candidates.csv  parsed general-election candidate rows (long), for reference
  dropped_rows.csv    every race dropped or left partly unmatched, with the reason
```

Rules: `raw_*/` is read-only and never edited by hand. All cleaning and joins live in `analysis/build_dataset.R`,
so anyone can regenerate `clean/` with

```
Rscript analysis/build_dataset.R      # needs dplyr, readr, stringr, tidyr, purrr, lubridate
```

Work on a branch and open a pull request for changes to shared scripts.

## The clean dataset — `clean/races.csv`

457 races (423 House, 34 Senate) that had a Kalshi market. For each race the **favorite** is the contract with
the highest price at 6:00 pm ET on Election Day (the last hour before any polls closed). Main columns:

- outcomes: `favorite_won`, `vote_margin` (favorite's two-party margin), `forecast_error` = (`prob_final` − `favorite_won`)²
- market: `prob_final`, `prob_1d/7d/30d`, `market_uncertainty`, `price_vol_30d`, `contract_volume`, `open_contract`, `bid_ask_spread_final`, `prob_sum_final`
- money: `receipts_favorite`, `receipts_opponent`, `fundraising_log_ratio`, individual/PAC splits, independent expenditures for/against each side
- race: `chamber`, `state`, `district`, `incumbency_status`, `open_seat`, `pres_margin_2024`, `pres_margin_fav`

Every column is defined in `clean/codebook.md`, including the exact cutoff times and how FEC names were matched.
Current coverage: `favorite_won` for 447 races (10 still unsettled on Nov 14), `fundraising_log_ratio` for 408,
`pres_margin_2024` for all, `vote_margin` for 165 (Wikipedia had not yet posted vote counts for the rest — re-run
`results_pull_v2.py` and the build script later to fill it in). Sanity check: favorites won 95.7% of settled House
races and 90.9% of Senate races, in line with Kalshi's own post-election tally.

## Raw sources

### Kalshi — `raw_kalshi/` (`kalshi_pull.py`)
Public trade API `https://api.elections.kalshi.com/trade-api/v2`, no key required.

| file | contents |
|---|---|
| `kalshi_events_raw.csv` | one row per race event with `race_key` (`H-NC-11`, `SEN-NC`, `SEN-OHS` = Ohio special), chamber, state, district, and `primary_event_for_race` (flags the party-based event when a race also has a named-candidate "(Person)" event) |
| `kalshi_markets_raw.csv` | one row per contract (D, R, occasionally a third party): `result`, `status`, `volume_fp`, `open_interest_fp`, `last_price_dollars`, `close_time`, `yes_sub_title` (candidate), `rules_primary`, … as returned by `GET /markets/{ticker}` |
| `kalshi_candles_daily_raw.csv` | one row per contract per day, Jul 1 – Nov 5 2026: open/high/low/close/mean, volume, open interest, yes-bid/ask. Daily candles end at midnight Eastern. `close` is blank on days with no trades. |
| `kalshi_candles_hourly_raw.csv` | one row per contract per hour, Nov 2–3 ET, for an intraday pre-polls-close price on Election Day |

Notes: prices are dollars on a 0–1 contract = implied probability; volume is in contracts. Kalshi used three naming
schemes for House races (`KXHOUSERACE-XX##-26`, `HOUSEXX#-26`, `KXHOUSEXX##-26`); the script keys all of them by
state + district. The event ticker `SENATELA-26` is actually Kentucky (Kalshi labeling error); Louisiana is
`KXSENATELA-26NOV`. No Alabama Senate market exists. Alaska Senate was unsettled at pull time. `DC-AL` is a
non-voting delegate seat and is dropped in cleaning.

### FEC — `raw_fec/`
- `weball26.txt` — FEC bulk "Candidate summary" file, 2025–26 cycle
  (`https://www.fec.gov/files/bulk-downloads/2026/weball26.zip`). Pipe-delimited, no header row; the 30 column
  names are hard-coded in `build_dataset.R` and documented in the FEC
  [all-candidates file description](https://www.fec.gov/campaign-finance-data/all-candidates-file-description/).
  Key fields: `TTL_RECEIPTS`, `TTL_INDIV_CONTRIB`, `OTHER_POL_CMTE_CONTRIB` (PAC), `CAND_ICI` (I/C/O),
  `CAND_OFFICE_ST`, `CAND_OFFICE_DISTRICT` (`00` = Senate and at-large House), `CVG_END_DT` (pre-general report,
  through 2026-10-14). Minnesota Democrats are coded `DFL`.
- `fec_independent_expenditures_2026.csv` — Schedule E export from
  `https://www.fec.gov/data/independent-expenditures/` (two-year period 2026, processed data, House + Senate),
  exported 2026-11-14. One row per expenditure with `candidate_id`, `support_oppose_indicator`,
  `expenditure_amount`, `election_type` (`G2026` = general), `most_recent`, `memo_code`.

### Election results — `raw_results/` (`results_pull_v2.py`)
`results_2026_raw.csv`: every candidate/votes/% row from the Wikipedia pages for each state's 2026 House elections
and each state's 2026 Senate election (plus the Ohio and Florida specials), labeled with `chamber`, `state`, the
section headings (`h2`, `h3`, `h4`) and the table `caption` (e.g. "2026 Alabama's 1st congressional district
election"), and the raw cells `c0`–`c7`. General-election tables are identified by caption in the build script.
Many districts had only an empty placeholder table on Nov 17; re-pull later for full coverage.

### 2024 presidential margins — `raw_pres2024/`
- `downballot_pres2024_by_cd.csv` — The Downballot (formerly Daily Kos Elections), 2024 presidential results by
  congressional district on the **2026 district lines**
  ([sheet](https://docs.google.com/spreadsheets/d/1eZfaFI-c-PFOoKx1-zZA2MP0_dxRq_LVK0re3BOQqy0/edit?gid=620838163),
  [methodology](https://www.the-downballot.com/p/the-downballots-calculations-of-presidential)). Whole-point
  percentages; `Margin` = Democratic − Republican.
- `pres2024_by_state.csv` — statewide 2024 Harris / Trump percentages for all 50 states + DC (one decimal), for the
  Senate races; transcribed from the state results table at pollcheck.com/results/president/2024 and spot-checked
  against certified results.

## Reproducing the raw pull
```
pip install requests pandas lxml beautifulsoup4
python kalshi_pull.py            # ~10 min; add --trades for per-trade data (large; needed for trade_count)
python results_pull_v2.py        # ~2 min
```
FEC and presidential files are manual downloads from the links above.
