#!/usr/bin/env python3
"""Download the PhysioNet annotation files (NOT the ECG signals) used by the validation into ./data/.

  afdb      MIT-BIH Atrial Fibrillation Database      .atr (rhythm), .qrs / .qrsc (beats), .hea
  nsrdb     MIT-BIH Normal Sinus Rhythm Database      .atr (beats), .hea
  mitdb     MIT-BIH Arrhythmia Database               .atr (beats + rhythm), .hea
  fantasia  Fantasia Database                         .ecg (beats), .hea

All four are open access on https://physionet.org (see the pages for their citations and terms). Only a few
megabytes of annotations are fetched. ./data is git-ignored: the data are never committed or shipped.
"""
import os
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
BASE = "https://physionet.org/files/{db}/1.0.0/{name}"
EXTS = {
    "afdb": ["atr", "qrs", "qrsc", "hea"],
    "nsrdb": ["atr", "hea"],
    "mitdb": ["atr", "hea"],
    "fantasia": ["ecg", "hea"],
}


def fetch(url):
    last = None
    for attempt in range(6):
        try:
            with urllib.request.urlopen(url, timeout=300) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None          # e.g. a .qrsc that only some records have
            last = e
        except Exception as e:       # connection reset and the like
            last = e
        time.sleep(1.5 * (attempt + 1))
    raise last


def job(args):
    db, rec, ext = args
    dest = os.path.join(DATA, db, f"{rec}.{ext}")
    if os.path.exists(dest):
        return
    data = fetch(BASE.format(db=db, name=f"{rec}.{ext}"))
    if data is not None:
        with open(dest, "wb") as f:
            f.write(data)


def main():
    jobs = []
    for db, exts in EXTS.items():
        os.makedirs(os.path.join(DATA, db), exist_ok=True)
        records = fetch(BASE.format(db=db, name="RECORDS")).decode().split()
        jobs += [(db, rec, ext) for rec in records for ext in exts]
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(job, jobs))
    for db in EXTS:
        print(db, len(os.listdir(os.path.join(DATA, db))), "files")


if __name__ == "__main__":
    main()
