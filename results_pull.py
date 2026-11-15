"""
2026 House & Senate election results (RAW) from Wikipedia  (STAT 139 final project)

Dumps every HTML table on the Wikipedia pages for the 2026 House and Senate elections
to CSV, untouched, so you can pick the ones with candidate vote shares yourself.

  raw_results/senate_2026_table_<k>.csv      every table on the Senate page
  raw_results/house_2026_table_<k>.csv       every table on the national House page
  raw_results/house_2026_<ST>_table_<k>.csv  every table on each state's House page
                                             (these have the district-level candidate % rows)
  raw_results/index.csv                      which file came from which page/table, with
                                             the table's column headers, so you can grep for
                                             the ones that say "Candidate" / "Votes" / "%"

Usage:
    pip install pandas lxml requests
    python results_pull.py

Wikipedia is the fastest source this close to the election; certified results will show up
at MIT Election Lab (electionlab.mit.edu/data) in a few months if you want to re-pull later.
"""
import io, os, re, time
import pandas as pd
import requests

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
AB = dict(zip(STATES, ['AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS',
                        'KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY',
                        'NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV',
                        'WI','WY']))

pages = [("senate_2026", "https://en.wikipedia.org/wiki/2026_United_States_Senate_elections"),
         ("house_2026", "https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections")]
pages += [(f"house_2026_{AB[s]}",
           f"https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_{s.replace(' ', '_')}")
          for s in STATES]

index = []
for name, url in pages:
    r = requests.get(url, headers=H, timeout=60)
    if r.status_code != 200:
        print(f"  !! {name}: HTTP {r.status_code} ({url})")
        continue
    try:
        tables = pd.read_html(io.StringIO(r.text))
    except ValueError:
        print(f"  !! {name}: no tables")
        continue
    for k, t in enumerate(tables):
        fn = f"{OUT}/{name}_table_{k}.csv"
        t.to_csv(fn, index=False)
        cols = " | ".join(str(c) for c in t.columns)[:300]
        index.append(dict(page=name, url=url, table=k, file=fn, nrows=len(t), columns=cols))
    print(f"  {name}: {len(tables)} tables")
    time.sleep(1.0)   # be nice to Wikipedia

pd.DataFrame(index).to_csv(f"{OUT}/index.csv", index=False)
print("done. see raw_results/index.csv")