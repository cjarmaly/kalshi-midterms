# Codebook — `clean/races.csv`

One row per 2026 U.S. House or Senate general-election race that had a Kalshi market (457 rows: 423 House,
34 Senate). Built by `analysis/build_dataset.R` from the raw pulls in `raw_*/`; rebuild with
`Rscript analysis/build_dataset.R` from the project root. Rows that were dropped or left partly unmatched are
listed with reasons in `clean/dropped_rows.csv`.

**Key timing definitions** (all Kalshi prices are in dollars on a 0–1 contract = implied probability):

| name | definition |
|---|---|
| *final* | close of the hourly candle ending 23:00 UTC on Nov 3 2026 = 6:00 pm ET, the last full hour before any polls closed. If a contract had no trade that day, the last daily close is used. |
| *1d / 7d / 30d* | last traded price as of midnight ET on Nov 3 / Oct 27 / Oct 4 2026 (end of the daily candle). |
| *pre-election* (volumes) | everything through the *final* cutoff; post-election trading is excluded. |

## Identifiers

| column | description |
|---|---|
| `race_key` | `H-<ST>-<DD>` (House; `AL` = at-large) or `SEN-<ST>` (Senate; `SEN-OHS`, `SEN-FLS` = Ohio and Florida specials). Join key across all sources. |
| `chamber` | `House` / `Senate` |
| `state`, `district` | two-letter state; district `01`–`53` or `AL`; blank for Senate |
| `special` | TRUE for the two Senate specials |
| `event_ticker` | the Kalshi event used (party-based event preferred when a race also had a "(Person)" event) |
| `market_status` | `finalized` (settled) or `active` (unsettled at pull: Alaska Senate and nine House seats) |
| `fav_ticker`, `fav_candidate`, `fav_party` | the **favorite**: the contract with the highest *final* price. Party is DEM / REP / OTH. Where Kalshi named the contract for the party rather than a person, the name is filled from the FEC and tagged `[name from FEC]`. |
| `opp_candidate`, `opp_party` | the second-highest-priced contract in the race |
| `n_contracts` | contracts in the event (2 for most races; 3 where an independent was listed) |

## Outcomes

| column | description |
|---|---|
| `favorite_won` | 1 if the favorite's contract settled YES, 0 if NO, blank if unsettled |
| `vote_margin` | favorite's **two-party margin**, percentage points: 100·(fav − opp)/(fav + opp) using the top vote-getter of each side's party class. Negative = favorite lost. Blank where Wikipedia had not posted a results table at pull time (292 races as of Nov 17 — re-run `pull/results_pull_v2.py` later to fill). |
| `vote_margin_total` | favorite's share minus opponent's share of **all** votes (pct points) |
| `forecast_error` | (`prob_final` − `favorite_won`)² — the main response (Brier-type squared error) |
| `forecast_error_1d`, `_7d`, `_30d` | same using the 1-, 7-, 30-day-out price |

## Kalshi market variables

| column | description |
|---|---|
| `prob_final` | favorite's implied probability at the *final* cutoff (always ≥ 0.5 by construction) |
| `prob_1d`, `prob_7d`, `prob_30d` | favorite's price 1 / 7 / 30 days out (blank if the contract had not traded yet) |
| `opp_prob_final` | opponent's contract price at the cutoff |
| `prob_sum_final` | sum of all contract prices in the race at the cutoff (≈1 if the book is internally consistent; >1 = overround) |
| `market_uncertainty` | `prob_final`·(1 − `prob_final`) |
| `price_vol_30d` | SD of day-to-day changes in the favorite's daily close over Oct 4 – Nov 2 (days with trades only) |
| `contract_volume` | contracts traded in the favorite's market, pre-election |
| `contract_volume_race` | pre-election contracts traded across all contracts in the race |
| `dollar_volume_approx`, `dollar_volume_race_approx` | Σ (contracts × mean daily price) — approximate dollars committed on the YES side; Kalshi does not report dollar volume directly |
| `trade_count` | **not available** (requires `kalshi_pull.py --trades`); all blank |
| `open_contract`, `open_contract_race` | open interest (outstanding contracts) at the cutoff, favorite / whole race |
| `bid_ask_spread_final` | yes-ask minus yes-bid on the favorite's contract at the cutoff (liquidity) |
| `days_open` | days from the favorite's market open to Election Day |
| `market_close_time` | when Kalshi closed the market (settlement) |

## Campaign finance (FEC, through the Oct 14 2026 pre-general report; `*_cvg_end` gives each candidate's actual coverage date)

| column | description |
|---|---|
| `receipts_favorite`, `receipts_opponent` | total receipts (`TTL_RECEIPTS`) |
| `fundraising_log_ratio` | log(`receipts_favorite` / `receipts_opponent`); positive = favorite out-raised. Blank when the opponent has no FEC record (minor candidates who never filed) or either side raised $0. |
| `fav_indiv_contrib`, `fav_pac_contrib`, `opp_*` | individual contributions and other-committee (PAC) contributions |
| `fav_indiv_share`, `fav_pac_share` | those as a share of the favorite's receipts |
| `fav_ie_support`, `fav_ie_oppose`, `opp_*` | independent expenditures for / against the candidate in the 2026 general (`G2026`), dated on or before Election Day, from the Schedule E export (de-duplicated to `most_recent`, memo rows excluded). 0 = none reported. |
| `fav_ici`, `opp_ici` | FEC incumbent/challenger/open-seat flag: `I`, `C`, `O` |
| `incumbency_status` | `favorite_incumbent` / `opponent_incumbent` / `open_seat` / `no_incumbent_flag` (neither matched candidate is flagged I or O) |
| `open_seat` | 1 if `incumbency_status == "open_seat"` |
| `fav_cand_id`, `fav_fec_name`, `fav_fec_match`, `opp_*` | the FEC record used and how it was matched: `surname` (unique surname match in race + party), `surname_multi_top_receipts` (several surname matches; first-name prefix then highest receipts), `party_top_receipts` (contract was party-named; took the party's top fundraiser), `lastname_any_party` (matched ignoring party; FEC lists a few incumbents with party UNK), `lastname_not_found`, `no_fec_candidate_in_race_party` |

## 2024 presidential baseline

| column | description |
|---|---|
| `pres_harris_2024`, `pres_trump_2024`, `pres_margin_2024` | 2024 presidential vote shares and Harris-minus-Trump margin: by **district on the 2026 lines** (The Downballot) for House, statewide for Senate. Rounded to whole points in the Downballot file. |
| `pres_margin_fav` | the same margin signed toward the favorite's party (positive = favorite's party carried the seat in 2024); blank for OTH favorites |

## Results detail (from Wikipedia; see `clean/results_candidates.csv` for every candidate row)

| column | description |
|---|---|
| `fav_pct_results`, `opp_pct_results`, `fav_votes`, `opp_votes` | shares and raw votes of the favorite's and opponent's party-class top candidate |
| `results_total_votes`, `n_candidates_results` | table total and number of candidate rows parsed |
| `winner_party_results`, `winner_candidate_results` | top vote-getter in the Wikipedia table |
| `results_available` | TRUE if a general-election results table with votes was parsed |
| `results_agree_with_kalshi` | TRUE if the Wikipedia winner's party matches the Kalshi settlement (all 158 available rows agree) |

## Known limitations to state in the paper
- Alabama had no Senate market; Alaska Senate and nine House seats were unsettled at pull (Nov 14). DC's delegate seat was dropped.
- `vote_margin` is only available for 165 races as of Nov 17 because Wikipedia had not posted vote counts for the rest (notably all of California); the pull can be re-run.
- Kalshi only lists trade volume in contracts; dollar volume is approximated.
- The FEC pre-general report cuts off Oct 14, so the last three weeks of fundraising are missing.
- 45 opponents (mostly token challengers in safe seats) have no FEC record; `fundraising_log_ratio` is blank there rather than ±∞.
- Alaska uses ranked-choice voting; its `vote_margin` is from first-choice votes.
