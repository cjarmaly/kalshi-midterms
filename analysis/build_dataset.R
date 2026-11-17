# =====================================================================================
#  build_dataset.R  —  STAT 139 final project
#  Forecast Accuracy in Kalshi's 2026 Congressional Markets
#  Charlie Scheuermann, Kiran Bishop, Christian Armaly
#
#  Reads the raw pulls in raw_*/ (never edited by hand) and writes:
#     clean/races.csv               one row per 2026 House/Senate race with a Kalshi market
#     clean/results_candidates.csv  parsed general-election candidate rows (long), for reference
#     clean/dropped_rows.csv        every race/row dropped or left unmatched, with the reason
#  Variable definitions are in clean/codebook.md (maintained by hand; update it if you add columns).
#
#  Run from the project root:   Rscript analysis/build_dataset.R
# =====================================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(tidyr); library(purrr); library(lubridate)
})
options(readr.show_col_types = FALSE, dplyr.summarise.inform = FALSE)
suppressWarnings(for (loc in c("en_US.UTF-8", "C.UTF-8")) if (Sys.setlocale("LC_CTYPE", loc) != "") break)   # UTF-8 so accented names parse
dir.create("clean", showWarnings = FALSE)
dropped <- tibble(stage = character(), key = character(), detail = character(), reason = character())
log_drop <- function(stage, key, detail, reason) {
  dropped <<- bind_rows(dropped, tibble(stage = stage, key = as.character(key), detail = as.character(detail), reason = reason))
}

# -------------------------------------------------------------------------------------
# 0. Definitions (all times UTC; Eastern = UTC-4 until Nov 1 2026, UTC-5 after)
# -------------------------------------------------------------------------------------
# "Final" pre-election price: close of the hourly candle ending 23:00 UTC on Nov 3 = 6:00 pm ET,
# the last full hour before the first polls close (6 pm ET in parts of IN/KY, 7 pm ET elsewhere).
T_FINAL <- ymd_hms("2026-11-03 23:00:00", tz = "UTC")
# Daily candles end at midnight ET. 1 / 7 / 30 days out = price as of midnight ET on Nov 3 / Oct 27 / Oct 4.
T_1D    <- ymd_hms("2026-11-03 05:00:00", tz = "UTC")
T_7D    <- ymd_hms("2026-10-27 04:00:00", tz = "UTC")
T_30D   <- ymd_hms("2026-10-04 04:00:00", tz = "UTC")
ELECTION_DATE <- as.Date("2026-11-03")

last_at <- function(x, t, when) { i <- which(t <= when & !is.na(x)); if (length(i)) x[max(i)] else NA_real_ }  # last non-missing value at/before `when`

# -------------------------------------------------------------------------------------
# 1. KALSHI — per-contract pre-election metrics, then favorite per race
# -------------------------------------------------------------------------------------
events  <- read_csv("raw_kalshi/kalshi_events_raw.csv")
markets <- read_csv("raw_kalshi/kalshi_markets_raw.csv", guess_max = 5000)
daily   <- read_csv("raw_kalshi/kalshi_candles_daily_raw.csv")  %>% mutate(t = as_datetime(end_period_ts, tz = "UTC"))
hourly  <- read_csv("raw_kalshi/kalshi_candles_hourly_raw.csv") %>% mutate(t = as_datetime(end_period_ts, tz = "UTC"))

daily_m <- daily %>% arrange(ticker, t) %>% group_by(ticker) %>% summarise(
  prob_1d  = last_at(close, t, T_1D),
  prob_7d  = last_at(close, t, T_7D),
  prob_30d = last_at(close, t, T_30D),
  price_vol_30d = { w <- t > T_30D & t <= T_1D & !is.na(close); if (sum(w) >= 3) sd(diff(close[w])) else NA_real_ },
  n_days_30d = sum(t > T_30D & t <= T_1D & !is.na(close)),   # days with trades in the final 30
  vol_daily_pre   = sum(volume_fp[t <= T_1D]),
  dvol_daily_pre  = sum(volume_fp[t <= T_1D] * mean[t <= T_1D], na.rm = TRUE),
  oi_1d           = last_at(open_interest_fp, t, T_1D),
  first_candle    = min(t))

hourly_m <- hourly %>% filter(t > T_1D, t <= T_FINAL) %>% arrange(ticker, t) %>% group_by(ticker) %>% summarise(
  prob_final_h = last_at(close, t, T_FINAL), oi_final_h = last(open_interest_fp),
  bid_final = last(yes_bid_close), ask_final = last(yes_ask_close),
  vol_hourly_pre = sum(volume_fp), dvol_hourly_pre = sum(volume_fp * mean, na.rm = TRUE))

mk <- markets %>%
  select(ticker, event_ticker, race_key, chamber, state, district, special, person_market,
         primary_event_for_race, series_ticker, yes_sub_title, subtitle, result, status, open_time, close_time,
         volume_fp_lifetime = volume_fp, open_interest_lifetime = open_interest_fp, last_price_dollars) %>%
  left_join(daily_m, by = "ticker") %>% left_join(hourly_m, by = "ticker") %>%
  mutate(
    prob_final      = coalesce(prob_final_h, prob_1d),            # 5 contracts had no Election-Day hourly candle
    open_contract   = coalesce(oi_final_h, oi_1d),
    contract_volume = vol_daily_pre + coalesce(vol_hourly_pre, 0),
    dollar_volume_approx = dvol_daily_pre + coalesce(dvol_hourly_pre, 0),
    bid_ask_spread_final = ask_final - bid_final,
    contract_party  = case_when(str_detect(ticker, "-(D|DEM)$") ~ "DEM", str_detect(ticker, "-(R|GOP)$") ~ "REP",
                                str_detect(coalesce(subtitle, ""), regex("^Democratic", ignore_case = TRUE)) ~ "DEM",
                                str_detect(coalesce(subtitle, ""), regex("^Republican", ignore_case = TRUE)) ~ "REP", TRUE ~ "OTH"),
    # a few contracts are named for the party, not a person (e.g. Louisiana, Alaska): no candidate name from Kalshi
    yes_sub_title   = ifelse(str_detect(yes_sub_title, regex("^(Democratic|Republican) party$", ignore_case = TRUE)), NA_character_, yes_sub_title),
    days_open       = as.numeric(difftime(ELECTION_DATE, as.Date(open_time), units = "days")))

# keep one event per race (party-based markets preferred over "(Person)" markets); drop DC delegate
mk <- mk %>% filter(primary_event_for_race)
for (k in unique(mk$race_key[mk$race_key == "H-DC-AL"])) log_drop("kalshi", k, "KXHOUSERACE-DCAL-26", "DC delegate seat, no vote in House")
mk <- mk %>% filter(race_key != "H-DC-AL")
mk_na <- mk %>% filter(is.na(prob_final))
for (i in seq_len(nrow(mk_na))) log_drop("kalshi", mk_na$race_key[i], mk_na$ticker[i], "contract has no pre-election price candle")
mk <- mk %>% filter(!is.na(prob_final))

# Favorite = the contract with the highest pre-election price in the race; opponent = the next highest.
# (Race-level sums are computed first because dplyr::summarise lets later expressions see earlier results.)
races_k <- mk %>% arrange(race_key, desc(prob_final)) %>% group_by(race_key) %>% summarise(
  chamber = first(chamber), state = first(state), district = first(district),
  special = !is.na(first(special)) & first(special) == "S",
  event_ticker = first(event_ticker), n_contracts = n(),
  prob_sum_final = sum(prob_final),
  contract_volume_race = sum(contract_volume), dollar_volume_race_approx = sum(dollar_volume_approx),
  open_contract_race = sum(open_contract, na.rm = TRUE),
  fav_ticker = ticker[1], fav_candidate = yes_sub_title[1], fav_party = contract_party[1],
  opp_ticker = ticker[2], opp_candidate = yes_sub_title[2], opp_party = contract_party[2],
  fav_result = result[1], market_status = status[1],
  opp_prob_final = prob_final[2],
  fav_prob_final = prob_final[1], fav_prob_1d = prob_1d[1], fav_prob_7d = prob_7d[1], fav_prob_30d = prob_30d[1],
  fav_price_vol_30d = price_vol_30d[1], fav_n_days_30d = n_days_30d[1],
  fav_contract_volume = contract_volume[1], fav_dollar_volume_approx = dollar_volume_approx[1],
  fav_open_contract = open_contract[1], fav_bid_ask_spread_final = bid_ask_spread_final[1],
  fav_days_open = days_open[1], market_close_time = first(close_time)) %>%
  rename(prob_final = fav_prob_final, prob_1d = fav_prob_1d, prob_7d = fav_prob_7d, prob_30d = fav_prob_30d,
         price_vol_30d = fav_price_vol_30d, n_days_30d = fav_n_days_30d, contract_volume = fav_contract_volume,
         dollar_volume_approx = fav_dollar_volume_approx, open_contract = fav_open_contract,
         bid_ask_spread_final = fav_bid_ask_spread_final, days_open = fav_days_open) %>%
  mutate(
    favorite_won = case_when(fav_result == "yes" ~ 1L, fav_result == "no" ~ 0L, TRUE ~ NA_integer_),
    forecast_error     = (prob_final - favorite_won)^2,
    forecast_error_1d  = (prob_1d  - favorite_won)^2,
    forecast_error_7d  = (prob_7d  - favorite_won)^2,
    forecast_error_30d = (prob_30d - favorite_won)^2,
    market_uncertainty = prob_final * (1 - prob_final),
    trade_count = NA_integer_)   # not pulled (needs kalshi_pull.py --trades)

for (i in which(is.na(races_k$favorite_won))) log_drop("kalshi", races_k$race_key[i], races_k$event_ticker[i], "market still active / unsettled at pull (favorite_won = NA, row kept)")
cat(sprintf("Kalshi: %d races (%d House, %d Senate)\n", nrow(races_k), sum(races_k$chamber == "House"), sum(races_k$chamber == "Senate")))

# -------------------------------------------------------------------------------------
# 2. RESULTS — general-election candidate rows from the Wikipedia pull
# -------------------------------------------------------------------------------------
res_raw <- read_csv("raw_results/results_2026_raw.csv", col_types = cols(.default = "c"))
ordinal_to_num <- function(s) { n <- str_extract(s, "\\d+(?=(st|nd|rd|th))"); ifelse(is.na(n), NA, sprintf("%02d", as.integer(n))) }
state_abbr <- c(Alabama="AL",Alaska="AK",Arizona="AZ",Arkansas="AR",California="CA",Colorado="CO",Connecticut="CT",Delaware="DE",
  Florida="FL",Georgia="GA",Hawaii="HI",Idaho="ID",Illinois="IL",Indiana="IN",Iowa="IA",Kansas="KS",Kentucky="KY",Louisiana="LA",
  Maine="ME",Maryland="MD",Massachusetts="MA",Michigan="MI",Minnesota="MN",Mississippi="MS",Missouri="MO",Montana="MT",Nebraska="NE",
  Nevada="NV",`New Hampshire`="NH",`New Jersey`="NJ",`New Mexico`="NM",`New York`="NY",`North Carolina`="NC",`North Dakota`="ND",
  Ohio="OH",Oklahoma="OK",Oregon="OR",Pennsylvania="PA",`Rhode Island`="RI",`South Carolina`="SC",`South Dakota`="SD",Tennessee="TN",
  Texas="TX",Utah="UT",Vermont="VT",Virginia="VA",Washington="WA",`West Virginia`="WV",Wisconsin="WI",Wyoming="WY")

res <- res_raw %>% mutate(caption = coalesce(caption, "")) %>% filter(
  (chamber == "House"  & str_detect(caption, regex("congressional district (general )?election", ignore_case = TRUE)) |
   chamber == "Senate" & str_detect(caption, regex("Senate (special )?election in", ignore_case = TRUE))) &
  !str_detect(caption, regex("primary|runoff|convention|nomination", ignore_case = TRUE))) %>%
  mutate(st = state_abbr[state],
         dist = case_when(chamber == "Senate" ~ NA_character_,
                          str_detect(caption, regex("at-large", ignore_case = TRUE)) ~ "AL",
                          TRUE ~ ordinal_to_num(caption)),
         race_key = case_when(chamber == "House" ~ paste0("H-", st, "-", dist),
                              st == "OH" ~ "SEN-OHS", st == "FL" ~ "SEN-FLS",   # 2026 OH and FL are specials
                              TRUE ~ paste0("SEN-", st)))

# locate the (votes, %) pair in each row; candidate is the cell before votes, party the cell before that
cells <- as.matrix(res[, paste0("c", 0:7)])
find_pair <- function(r) {
  for (i in 2:7) {
    v <- r[i]; p <- r[i + 1]
    if (!is.na(v) && !is.na(p) && str_detect(v, "^[0-9][0-9,]*$") && str_detect(p, "^[0-9]+(\\.[0-9]+)?%?$")) return(i)
  }
  NA_integer_
}
res$vpos <- apply(cells, 1, find_pair)
ok <- !is.na(res$vpos); ri <- which(ok); vp <- res$vpos[ok]
res$votes <- NA_real_; res$pct <- NA_real_; res$candidate_raw <- NA_character_; res$party_raw <- NA_character_
res$votes[ok] <- as.numeric(str_remove_all(cells[cbind(ri, vp)], ","))
res$pct[ok]   <- as.numeric(str_remove(cells[cbind(ri, vp + 1)], "%"))
res$candidate_raw[ok] <- cells[cbind(ri, vp - 1)]
res$party_raw[ok]     <- ifelse(vp >= 3, cells[cbind(ri, pmax(vp - 2, 1))], NA_character_)
cand <- res %>% filter(ok) %>%
  filter(!is.na(party_raw), str_detect(party_raw, "^[A-Za-z][A-Za-z .'()/\\-\u2013\u2014]*$"), !is.na(candidate_raw),
         !str_detect(candidate_raw, "^[0-9.,%]+$"), !str_detect(tolower(party_raw), "total|turnout|majority|write")) %>%
  mutate(candidate = str_squish(str_remove_all(candidate_raw, "\\(incumbent\\)|\\[\\d+\\]|†|\\*")),
         party = case_when(str_detect(party_raw, regex("^Democratic", ignore_case = TRUE)) ~ "DEM",
                           str_detect(party_raw, regex("^Republican", ignore_case = TRUE)) ~ "REP", TRUE ~ "OTH")) %>%
  select(race_key, chamber, state = st, caption, party, party_raw, candidate, votes, pct)
write_csv(cand, "clean/results_candidates.csv")

res_race <- cand %>% group_by(race_key) %>% summarise(
  results_total_votes = sum(votes, na.rm = TRUE),
  winner_party_results = party[which.max(votes)], winner_candidate_results = candidate[which.max(votes)],
  dem_candidate = candidate[party == "DEM"][which.max(votes[party == "DEM"])][1],
  rep_candidate = candidate[party == "REP"][which.max(votes[party == "REP"])][1],
  dem_votes = suppressWarnings(max(votes[party == "DEM"], -Inf)), rep_votes = suppressWarnings(max(votes[party == "REP"], -Inf)),
  oth_votes = suppressWarnings(max(votes[party == "OTH"], -Inf)),
  dem_pct = suppressWarnings(max(pct[party == "DEM"], -Inf)),   rep_pct = suppressWarnings(max(pct[party == "REP"], -Inf)),
  oth_pct = suppressWarnings(max(pct[party == "OTH"], -Inf)),
  n_candidates_results = n()) %>%
  mutate(across(c(dem_votes, rep_votes, oth_votes, dem_pct, rep_pct, oth_pct), ~ ifelse(is.finite(.x), .x, NA_real_)))
cat(sprintf("Results: general-election tables parsed for %d races (%d House, %d Senate)\n", nrow(res_race),
            sum(str_starts(res_race$race_key, "H-")), sum(str_starts(res_race$race_key, "SEN-"))))

# -------------------------------------------------------------------------------------
# 3. FEC — candidate summary (receipts, incumbency) + independent expenditures
# -------------------------------------------------------------------------------------
SUFFIX <- c("JR", "SR", "II", "III", "IV", "MR", "MRS", "MS", "DR", "SEN", "REP", "HON")
name_tokens <- function(nm) {
  if (is.na(nm)) return(character())
  x <- chartr("\u00e1\u00e9\u00ed\u00f3\u00fa\u00f1\u00fc\u00c1\u00c9\u00cd\u00d3\u00da\u00d1\u00dc\u00e0\u00e8\u00ec\u00f2\u00f9\u00e2\u00ea\u00ee\u00f4\u00fb\u00e7\u00e3\u00f5\u00f6\u00e4",
              "aeiounuAEIOUNUaeiouaeioucaooa", nm)          # strip common accents (Sánchez -> Sanchez)
  x <- iconv(x, from = "UTF-8", to = "ASCII//TRANSLIT"); if (is.na(x)) x <- nm
  toks <- str_split(str_to_upper(str_replace_all(x, "[\"'.,()]", "")), "[\\s-]+")[[1]]
  toks[!toks %in% SUFFIX & toks != ""]
}
fec_cols <- c("CAND_ID","CAND_NAME","CAND_ICI","PTY_CD","CAND_PTY_AFFILIATION","TTL_RECEIPTS","TRANS_FROM_AUTH","TTL_DISB",
  "TRANS_TO_AUTH","COH_BOP","COH_COP","CAND_CONTRIB","CAND_LOANS","OTHER_LOANS","CAND_LOAN_REPAY","OTHER_LOAN_REPAY","DEBTS_OWED_BY",
  "TTL_INDIV_CONTRIB","CAND_OFFICE_ST","CAND_OFFICE_DISTRICT","SPEC_ELECTION","PRIM_ELECTION","RUN_ELECTION","GEN_ELECTION",
  "GEN_ELECTION_PRECENT","OTHER_POL_CMTE_CONTRIB","POL_PTY_CONTRIB","CVG_END_DT","INDIV_REFUNDS","CMTE_REFUNDS")
at_large <- c("AK","DE","ND","SD","VT","WY")
fec <- read_delim("raw_fec/weball26.txt", delim = "|", col_names = fec_cols,
                  col_types = cols(.default = "c", TTL_RECEIPTS = "d", TTL_INDIV_CONTRIB = "d", OTHER_POL_CMTE_CONTRIB = "d",
                                   TTL_DISB = "d", COH_COP = "d", POL_PTY_CONTRIB = "d")) %>%
  mutate(office = str_sub(CAND_ID, 1, 1)) %>% filter(office %in% c("H", "S")) %>%
  mutate(dist = ifelse(office == "H" & CAND_OFFICE_ST %in% at_large, "AL", CAND_OFFICE_DISTRICT),
         race_key = case_when(office == "H" ~ paste0("H-", CAND_OFFICE_ST, "-", dist),
                              CAND_OFFICE_ST == "OH" ~ "SEN-OHS", CAND_OFFICE_ST == "FL" ~ "SEN-FLS",
                              TRUE ~ paste0("SEN-", CAND_OFFICE_ST)),
         party = case_when(CAND_PTY_AFFILIATION %in% c("DEM", "DFL", "DNL") ~ "DEM",   # DFL = Minnesota Democrats, DNL = ND Dem-NPL
                           CAND_PTY_AFFILIATION == "REP" ~ "REP",
                           PTY_CD == "1" ~ "DEM", PTY_CD == "2" ~ "REP", TRUE ~ "OTH"),
         fec_tokens = map(CAND_NAME, name_tokens),
         fec_last   = map_chr(fec_tokens, ~ ifelse(length(.x), .x[1], NA_character_)),   # first token = surname (FEC is "LAST, FIRST")
         fec_first  = str_squish(str_to_upper(coalesce(str_extract(CAND_NAME, "(?<=,).*$"), ""))))

ie <- read_csv("raw_fec/fec_independent_expenditures_2026.csv", guess_max = 60000,
               col_select = c(candidate_id, candidate_office, support_oppose_indicator, expenditure_amount,
                              expenditure_date, election_type, memo_code, most_recent)) %>%
  filter(candidate_office %in% c("H", "S"), election_type == "G2026", most_recent == TRUE | most_recent == "t",
         is.na(memo_code), !is.na(candidate_id), as.Date(expenditure_date) <= ELECTION_DATE) %>%
  group_by(candidate_id) %>% summarise(ie_support = sum(expenditure_amount[support_oppose_indicator == "S"], na.rm = TRUE),
                                       ie_oppose  = sum(expenditure_amount[support_oppose_indicator == "O"], na.rm = TRUE))
fec <- fec %>% left_join(ie, by = c("CAND_ID" = "candidate_id")) %>%
  mutate(ie_support = coalesce(ie_support, 0), ie_oppose = coalesce(ie_oppose, 0))

# ---- matching a Kalshi candidate name to an FEC row ----
# Names are reduced to upper-case ASCII tokens (accents stripped, suffixes and titles dropped). A Kalshi name
# matches an FEC name when its surname token(s) appear among the FEC name tokens; this survives FEC quirks
# like "NICK, LALOTA" (reversed) and "ARENHOLZ, ASHLEY HINSON" (maiden/married names).
match_fec <- function(key, party, name) {
  if (is.na(party) || (party == "OTH" && is.na(name))) return(tibble(CAND_ID = NA, match_type = "no_party_market"))
  pool <- fec %>% filter(race_key == key, party == !!party)   # for OTH this is every non-D/R filer in the race
  if (!nrow(pool)) return(tibble(CAND_ID = NA, match_type = "no_fec_candidate_in_race_party"))
  if (is.na(name)) {   # contract named for the party only: take that party's top fundraiser in the race
    hit <- pool %>% arrange(desc(TTL_RECEIPTS)) %>% slice(1)
    return(tibble(CAND_ID = hit$CAND_ID, match_type = "party_top_receipts"))
  }
  kt <- name_tokens(name); if (!length(kt)) return(tibble(CAND_ID = NA, match_type = "unparseable_name"))
  k_last <- tail(kt, 1); k_surn <- if (length(kt) > 1) kt[-1] else kt; k_first <- kt[1]
  score <- function(ft) { if (k_last %in% ft) 2 else if (any(k_surn %in% ft)) 1 else 0 }
  pool$score <- map_dbl(pool$fec_tokens, score)
  hit <- pool %>% filter(score > 0)
  if (!nrow(hit)) {   # try the whole race regardless of party (FEC lists a few incumbents with party UNK)
    pool2 <- fec %>% filter(race_key == key); pool2$score <- map_dbl(pool2$fec_tokens, score)
    hit <- pool2 %>% filter(score == 2)
    if (!nrow(hit)) return(tibble(CAND_ID = NA, match_type = "lastname_not_found"))
    hit <- hit %>% arrange(desc(TTL_RECEIPTS)) %>% slice(1)
    return(tibble(CAND_ID = hit$CAND_ID, match_type = "lastname_any_party"))
  }
  if (nrow(hit) > 1) { h2 <- hit %>% filter(str_detect(fec_first, fixed(str_sub(k_first, 1, 3)))); if (nrow(h2) >= 1) hit <- h2 }
  n_hit <- nrow(hit)
  hit <- hit %>% arrange(desc(score), desc(TTL_RECEIPTS)) %>% slice(1)
  tibble(CAND_ID = hit$CAND_ID, match_type = ifelse(n_hit == 1, "surname", "surname_multi_top_receipts"))
}
fec_pick <- function(ids) fec %>% filter(CAND_ID %in% ids) %>%
  select(CAND_ID, fec_name = CAND_NAME, ici = CAND_ICI, receipts = TTL_RECEIPTS, indiv = TTL_INDIV_CONTRIB,
         pac = OTHER_POL_CMTE_CONTRIB, disb = TTL_DISB, cvg_end = CVG_END_DT, ie_support, ie_oppose)

fav_m <- pmap_dfr(list(races_k$race_key, races_k$fav_party, races_k$fav_candidate), match_fec) %>% rename(fav_cand_id = CAND_ID, fav_fec_match = match_type)
opp_m <- pmap_dfr(list(races_k$race_key, races_k$opp_party, races_k$opp_candidate), match_fec) %>% rename(opp_cand_id = CAND_ID, opp_fec_match = match_type)
races <- bind_cols(races_k, fav_m, opp_m) %>%
  left_join(fec_pick(.$fav_cand_id) %>% rename_with(~ paste0("fav_", .x), -CAND_ID), by = c("fav_cand_id" = "CAND_ID")) %>%
  left_join(fec_pick(.$opp_cand_id) %>% rename_with(~ paste0("opp_", .x), -CAND_ID), by = c("opp_cand_id" = "CAND_ID"))
for (i in which(is.na(races$fav_cand_id))) log_drop("fec", races$race_key[i], races$fav_candidate[i], paste0("favorite not matched to FEC: ", races$fav_fec_match[i]))
for (i in which(is.na(races$opp_cand_id))) log_drop("fec", races$race_key[i], races$opp_candidate[i], paste0("opponent not matched to FEC: ", races$opp_fec_match[i]))
cat(sprintf("FEC: favorite matched in %d/%d races, opponent in %d/%d\n", sum(!is.na(races$fav_cand_id)), nrow(races), sum(!is.na(races$opp_cand_id)), nrow(races)))

# -------------------------------------------------------------------------------------
# 4. 2024 PRESIDENTIAL MARGIN — The Downballot (districts, on 2026 lines) + state file (Senate)
# -------------------------------------------------------------------------------------
db <- read_csv("raw_pres2024/downballot_pres2024_by_cd.csv", skip = 3, col_names = c("district", "incumbent", "inc_party",
               "harris_2024", "trump_2024", "margin_2024", "biden_2020", "trump_2020", "margin_2020"), col_types = cols(.default = "c")) %>%
  filter(str_detect(district, "^[A-Z]{2}-(\\d{2}|AL)$")) %>%
  mutate(race_key = paste0("H-", str_replace(district, "-", "-")), across(c(harris_2024, trump_2024, margin_2024), as.numeric)) %>%
  select(race_key, pres_harris_2024 = harris_2024, pres_trump_2024 = trump_2024, pres_margin_2024 = margin_2024)
ps <- read_csv("raw_pres2024/pres2024_by_state.csv") %>%
  transmute(state, pres_harris_2024 = harris_pct, pres_trump_2024 = trump_pct, pres_margin_2024 = margin_d_minus_r)

races <- races %>%
  left_join(db, by = "race_key") %>%
  left_join(ps %>% rename(ph = pres_harris_2024, pt = pres_trump_2024, pm = pres_margin_2024), by = "state") %>%
  mutate(pres_harris_2024 = ifelse(chamber == "Senate", ph, pres_harris_2024),
         pres_trump_2024  = ifelse(chamber == "Senate", pt, pres_trump_2024),
         pres_margin_2024 = ifelse(chamber == "Senate", pm, pres_margin_2024)) %>% select(-ph, -pt, -pm)
for (i in which(is.na(races$pres_margin_2024))) log_drop("pres2024", races$race_key[i], "", "no 2024 presidential margin found")

# -------------------------------------------------------------------------------------
# 5. ASSEMBLE race-level variables
# -------------------------------------------------------------------------------------
races <- races %>% left_join(res_race, by = "race_key") %>% mutate(
  # favorite's and opponent's shares = the top candidate of each one's party class (DEM / REP / other) in the results table
  fav_pct_results = case_when(fav_party == "DEM" ~ dem_pct, fav_party == "REP" ~ rep_pct, TRUE ~ oth_pct),
  opp_pct_results = case_when(opp_party == "DEM" ~ dem_pct, opp_party == "REP" ~ rep_pct, TRUE ~ oth_pct),
  fav_votes = case_when(fav_party == "DEM" ~ dem_votes, fav_party == "REP" ~ rep_votes, TRUE ~ oth_votes),
  opp_votes = case_when(opp_party == "DEM" ~ dem_votes, opp_party == "REP" ~ rep_votes, TRUE ~ oth_votes),
  vote_margin = 100 * (fav_votes - opp_votes) / (fav_votes + opp_votes),   # favorite's two-party margin, pct points
  vote_margin_total = fav_pct_results - opp_pct_results,                    # margin in share of all votes
  results_available = !is.na(vote_margin),
  results_agree_with_kalshi = ifelse(!is.na(winner_party_results) & !is.na(favorite_won),
                                     (winner_party_results == fav_party) == (favorite_won == 1), NA),
  fundraising_log_ratio = log(fav_receipts / opp_receipts),
  fundraising_log_ratio = ifelse(is.finite(fundraising_log_ratio), fundraising_log_ratio, NA_real_),
  fav_indiv_share = fav_indiv / fav_receipts, fav_pac_share = fav_pac / fav_receipts,
  incumbency_status = case_when(fav_ici == "I" ~ "favorite_incumbent", opp_ici == "I" ~ "opponent_incumbent",
                                fav_ici == "O" | opp_ici == "O" ~ "open_seat",
                                is.na(fav_ici) & is.na(opp_ici) ~ NA_character_, TRUE ~ "no_incumbent_flag"),
  open_seat = case_when(incumbency_status == "open_seat" ~ 1L, is.na(incumbency_status) ~ NA_integer_, TRUE ~ 0L),
  pres_margin_fav = ifelse(fav_party == "DEM", pres_margin_2024, ifelse(fav_party == "REP", -pres_margin_2024, NA)))
races <- races %>% mutate(
  fav_candidate = ifelse(is.na(fav_candidate) & !is.na(fav_fec_name), paste0(fav_fec_name, " [name from FEC]"), fav_candidate),
  opp_candidate = ifelse(is.na(opp_candidate) & !is.na(opp_fec_name), paste0(opp_fec_name, " [name from FEC]"), opp_candidate))
for (i in which(!races$results_available)) log_drop("results", races$race_key[i], "", "no general-election results table on Wikipedia yet (vote_margin = NA, row kept)")
for (i in which(!is.na(races$results_agree_with_kalshi) & !races$results_agree_with_kalshi))
  log_drop("results", races$race_key[i], races$winner_candidate_results[i], "CHECK: Wikipedia winner party disagrees with Kalshi settlement")

out <- races %>% select(
  race_key, chamber, state, district, special, event_ticker, market_status,
  fav_ticker, fav_candidate, fav_party, opp_candidate, opp_party, n_contracts,
  favorite_won, vote_margin, vote_margin_total, forecast_error,
  prob_final, prob_1d, prob_7d, prob_30d, opp_prob_final, prob_sum_final, market_uncertainty, price_vol_30d,
  forecast_error_1d, forecast_error_7d, forecast_error_30d,
  contract_volume, contract_volume_race, dollar_volume_approx, dollar_volume_race_approx, trade_count,
  open_contract, open_contract_race, bid_ask_spread_final, days_open,
  receipts_favorite = fav_receipts, receipts_opponent = opp_receipts, fundraising_log_ratio,
  fav_indiv_contrib = fav_indiv, fav_pac_contrib = fav_pac, fav_indiv_share, fav_pac_share,
  opp_indiv_contrib = opp_indiv, opp_pac_contrib = opp_pac,
  fav_ie_support, fav_ie_oppose, opp_ie_support, opp_ie_oppose,
  fav_ici, opp_ici, incumbency_status, open_seat,
  pres_harris_2024, pres_trump_2024, pres_margin_2024, pres_margin_fav,
  fav_pct_results, opp_pct_results, fav_votes, opp_votes, results_total_votes, n_candidates_results,
  winner_party_results, winner_candidate_results, results_available, results_agree_with_kalshi,
  fav_cand_id, fav_fec_name, fav_fec_match, fav_cvg_end, opp_cand_id, opp_fec_name, opp_fec_match, opp_cvg_end,
  market_close_time)

write_csv(out, "clean/races.csv", na = "")
write_csv(dropped, "clean/dropped_rows.csv")

# -------------------------------------------------------------------------------------
# 6. Summary printed to console
# -------------------------------------------------------------------------------------
cat("\n==== clean/races.csv ====\n")
cat(sprintf("%d races: %d House, %d Senate | settled: %d | favorite won: %.1f%% House, %.1f%% Senate\n",
    nrow(out), sum(out$chamber == "House"), sum(out$chamber == "Senate"), sum(!is.na(out$favorite_won)),
    100 * mean(out$favorite_won[out$chamber == "House"], na.rm = TRUE), 100 * mean(out$favorite_won[out$chamber == "Senate"], na.rm = TRUE)))
cat(sprintf("vote_margin available: %d | fundraising_log_ratio: %d | pres_margin_2024: %d | incumbency_status: %d\n",
    sum(!is.na(out$vote_margin)), sum(!is.na(out$fundraising_log_ratio)), sum(!is.na(out$pres_margin_2024)), sum(!is.na(out$incumbency_status))))
cat(sprintf("prob_final range %.3f–%.3f | duplicate race_key: %d\n", min(out$prob_final), max(out$prob_final), sum(duplicated(out$race_key))))
cat("\nLargest forecast errors (upsets):\n")
print(out %>% filter(!is.na(forecast_error)) %>% arrange(desc(forecast_error)) %>%
        select(race_key, fav_candidate, fav_party, prob_final, favorite_won, vote_margin) %>% head(12), n = 12)
cat(sprintf("\ndropped/flagged rows logged: %d (clean/dropped_rows.csv)\n", nrow(dropped)))
