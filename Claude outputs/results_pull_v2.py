"""
2026 House & Senate election results from Wikipedia, v2  (STAT 139 final project)

Replaces results_pull.py.  v1 dumped every table on every page as its own CSV, which lost the
section heading, so a results table couldn't be tied back to its district.  v2 walks each page in
document order, keeps the nearest headings and the table caption, and writes ONE long-format CSV per
chamber with every candidate/votes/% row still raw (no cleaning of names or numbers), but labeled:

  raw_results/results_2026_raw.csv

Columns: page, page_url, state, h2, h3, h4 (nearest section headings above the table), caption
(the table's own title, e.g. "2026 Alabama's 1st congressional district election"), table_index,
row_index, then the raw cell texts c0..c7 of each table row.  For a typical Wikipedia results table:
c0 = party colour cell (blank), c1 = party, c2 = candidate, c3 = votes, c4 = %, (c5 = +/- swing).
Rows like "Total votes" and "Republican hold" are kept too - filter them out yourself.

You will then keep the rows whose h3/caption say general election (not primary/runoff), which is
what you need for vote_margin.  Everything goes into ONE file, raw_results/results_2026_raw.csv,
with a `chamber` column (House / Senate).

Usage:
    pip install requests pandas beautifulsoup4 lxml
    python results_pull_v2.py
"""
import os, re, time
import pandas as pd
import requests
from bs4 import BeautifulSoup

OUT = "raw_results"
os.makedirs(OUT, exist_ok=True)
H = {"User-Agent": "stat139-final-project (student research; contact via Harvard email)"}

STATES = ['Alabama','Alaska','Arizona','Arkansas','California','Colorado','Connecticut','Delaware',
          'Florida','Georgia','Hawaii','Idaho','Illinois','Indiana','Iowa','Kansas','Kentucky',
          'Louisiana','Maine','Maryland','Massachusetts','Michigan','Minnesota','Mississippi',
          'Missouri','Montana','Nebraska','Nevada','New Hampshire','New Jersey','New Mexico',
          'New York','North Carolina','North Dakota','Ohio','Oklahoma','Oregon','Pennsylvania',
          'Rhode Island','South Carolina','South Dakota','Tennessee','Texas','Utah','Vermont',
          'Virginia','Washington','West Virginia','Wisconsin','Wyoming']
SENATE_STATES = ['Alabama','Alaska','Arkansas','Colorado','Delaware','Georgia','Idaho','Illinois','Iowa',
                 'Kansas','Kentucky','Louisiana','Maine','Massachusetts','Michigan','Minnesota',
                 'Mississippi','Montana','Nebraska','New Hampshire','New Jersey','New Mexico',
                 'North Carolina','Oklahoma','Oregon','Rhode Island','South Carolina','South Dakota',
                 'Tennessee','Texas','Virginia','West Virginia','Wyoming']
SENATE_SPECIALS = ['Ohio', 'Florida']


def clean(s):
    return re.sub(r"\s+", " ", s.replace("\xa0", " ")).strip()


def parse_page(html, page, url, state, chamber):
    """Walk the page in order; return labeled rows from every results-style table."""
    soup = BeautifulSoup(html, "lxml")
    body = soup.find("div", class_="mw-parser-output") or soup
    rows, heads = [], {"h2": "", "h3": "", "h4": ""}
    t_idx = 0
    for el in body.descendants:
        if getattr(el, "name", None) in ("h2", "h3", "h4"):
            txt = clean(el.get_text())
            txt = re.sub(r"\[edit\]$", "", txt).strip()
            heads[el.name] = txt
            if el.name == "h2":
                heads["h3"] = heads["h4"] = ""
            elif el.name == "h3":
                heads["h4"] = ""
        elif getattr(el, "name", None) == "table":
            cls = " ".join(el.get("class", []))
            if "wikitable" not in cls:
                continue
            header_txt = clean(" ".join(th.get_text() for th in el.find_all("th")))
            if not re.search(r"Candidate", header_txt, re.I) or not re.search(r"Votes|%", header_txt, re.I):
                continue
            cap = el.find("caption")
            caption = clean(cap.get_text()) if cap else ""
            t_idx += 1
            for r_idx, tr in enumerate(el.find_all("tr")):
                cells = [clean(td.get_text()) for td in tr.find_all(["td", "th"])]
                if not cells:
                    continue
                row = dict(chamber=chamber, page=page, page_url=url, state=state, h2=heads["h2"], h3=heads["h3"],
                           h4=heads["h4"], caption=caption, table_index=t_idx, row_index=r_idx)
                for i in range(8):
                    row[f"c{i}"] = cells[i] if i < len(cells) else ""
                row["n_cells"] = len(cells)
                rows.append(row)
    return rows


def fetch(url):
    r = requests.get(url, headers=H, timeout=60)
    return r.text if r.status_code == 200 else None


def run(pages, chamber):
    allrows = []
    for page, url, state in pages:
        html = fetch(url)
        if html is None:
            print(f"  !! missing: {url}")
            continue
        rows = parse_page(html, page, url, state, chamber)
        print(f"  {page}: {len(rows)} rows from {len({r['table_index'] for r in rows})} tables")
        allrows += rows
        time.sleep(1.0)
    return allrows


W = "https://en.wikipedia.org/wiki/"
house_pages = [(f"house_2026_{s}", W + f"2026_United_States_House_of_Representatives_elections_in_{s.replace(' ', '_')}", s)
               for s in STATES]
senate_pages = [(f"senate_2026_{s}", W + f"2026_United_States_Senate_election_in_{s.replace(' ', '_')}", s)
                for s in SENATE_STATES]
senate_pages += [(f"senate_2026_{s}_special", W + f"2026_United_States_Senate_special_election_in_{s}", s)
                 for s in SENATE_SPECIALS]

print("House ...");  rows = run(house_pages, "House")
print("Senate ..."); rows += run(senate_pages, "Senate")
out = f"{OUT}/results_2026_raw.csv"
pd.DataFrame(rows).to_csv(out, index=False)
print(f"wrote {out} ({len(rows)} rows)")
