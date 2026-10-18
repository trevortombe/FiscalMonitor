#!/usr/bin/env python3
"""
fm.py -- turn a transcribed Fiscal Monitor report into rows of fiscalmon-clean.csv,
check them, and append them.

Input is a plain-text transcription of the report's tables (raw/YYYY-MM.txt), one
line per published row:

    T1 | Revenues | 42,607 | 42,825 | 163,443 | 175,469
    T3 | Major transfers to persons                       <- header row, no values
    T2 | Personal | 17,121 | 18,480 | 7.9 | 71,037 | 76,679 | 7.9   <- % columns kept
    T7 | Marketable bonds | 1,169,397 | 1,280,472 | 111,075

Lines starting with # are comments. Labels are matched to ids with pipeline/labels.csv.

Commands
    python3 pipeline/fm.py check   raw/2026-08.txt --month 2026-08
    python3 pipeline/fm.py append  raw/2026-08.txt --month 2026-08
    python3 pipeline/fm.py compare raw/2026-07.txt --month 2026-07   (month already stored:
                                                                       re-extract and diff)
Exit codes: 0 ok, 1 check errors, 2 the transcription could not be parsed or mapped,
            3 the month is already in the CSV (append).

Only the standard library is used.
"""
import argparse, csv, json, math, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
import os
CSV_PATH = Path(os.environ.get("FM_CSV", ROOT / "fiscalmon-clean.csv"))
SCHEMA_PATH = ROOT / "fiscalmon_schema.json"
LABELS_PATH = ROOT / "pipeline" / "labels.csv"
REPORTS = ROOT / "reports"
COLS = ["date", "fiscalyear", "year", "month", "fyear", "fymon", "tablenum", "title", "rowid",
        "id", "name", "prior_year", "this_year", "prior_FY_to_date", "current_FY_to_date"]
V = ["py", "ty", "pf", "cf"]                      # prior_year, this_year, prior FYTD, current FYTD
VCOL = dict(zip(V, COLS[11:]))
CASH_IDS = {116, 631}                              # point-in-time: values in FYTD columns only
DASHES = {"-", "–", "—"}

# ---------------------------------------------------------------------------- helpers
def norm(label):
    s = label.replace("’", "'").replace("–", "-").replace("—", "-").strip()
    s = re.sub(r"(?<=[A-Za-z\)])\d+(,\d+)*$", "", s)          # trailing footnote markers
    s = s.lower()
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return s.strip()

def to_num(s):
    """Published cell -> number. '' -> None; dash -> 0 (as stored since 2024); n/a -> None."""
    s = (s or "").strip().replace("−", "-").replace("$", "")
    if s == "" or s.lower() in {"n/a", "na", ".."}:
        return None
    if s in DASHES:
        return 0
    s = s.replace(",", "").replace(" ", "")
    if s.startswith("(") and s.endswith(")"):
        s = "-" + s[1:-1]
    return float(s) if "." in s else int(s)

def fmt(x):
    if x is None:
        return ""
    if isinstance(x, float) and x.is_integer():
        x = int(x)
    return f"{x:,}"

def month_meta(ym):
    y, m = map(int, ym.split("-"))
    fyear = y if m >= 4 else y - 1
    return {"date": f"{y}m{m}", "fiscalyear": f"{fyear}/{str(fyear + 1)[-2:]}", "year": str(y),
            "month": str(m), "fyear": str(fyear), "fymon": str((m - 4) % 12 + 1)}, y, m

def shift(y, m, k):
    t = y * 12 + (m - 1) + k
    return t // 12, t % 12 + 1

# ---------------------------------------------------------------------------- stored data
def load_csv():
    with open(CSV_PATH, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

class Store:
    def __init__(self, rows, exclude_date=None):
        self.rows = rows
        self.by = {}                 # (date, id) -> row
        self.latest = {}             # id -> most recent row (template for rowid/name/title)
        self.dates = []
        for r in rows:
            if r["date"] == exclude_date:
                continue
            self.by[(r["date"], int(r["id"]))] = r
            key = (int(r["year"]), int(r["month"]))
            prev = self.latest.get(int(r["id"]))
            if prev is None or key >= (int(prev["year"]), int(prev["month"])):
                self.latest[int(r["id"])] = r
            self.dates.append(key)
        self.dates = sorted(set(self.dates))

    def val(self, y, m, i, v):
        r = self.by.get((f"{y}m{m}", i))
        return None if r is None else to_num(r[VCOL[v]])

    def has(self, y, m):
        return (y, m) in set(self.dates)

    def ids_in(self, y, m, tables):
        return {i for (d, i), r in self.by.items() if d == f"{y}m{m}" and int(r["tablenum"]) in tables}

# ---------------------------------------------------------------------------- parse
def load_labels():
    lab = {}
    with open(LABELS_PATH, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            lab[(int(r["table"]), norm(r["label"]))] = r["id"]
    return lab

def parse(path):
    """-> list of dicts {table, label, cells, line}"""
    out = []
    for n, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        m = re.match(r"^(?:T|Table\s*)?(\d)$", parts[0], re.I)
        if not m:
            raise SystemExit(f"line {n}: first field must be the table (T1..T7): {line}")
        label, cells = parts[1] if len(parts) > 1 else "", parts[2:]
        if not label or label.lower().startswith("note"):      # column headings, footnotes
            continue
        out.append({"table": int(m.group(1)), "label": label, "cells": cells, "line": n})
    return out

def to_rows(parsed, ym, store, labels, schema):
    """Map parsed lines to CSV rows. Returns (rows, problems, pct_checks)."""
    meta, y, m = month_meta(ym)
    problems, rows, pct = [], {}, []
    for p in parsed:
        t, key = p["table"], norm(p["label"])
        sid = labels.get((t, key))
        if sid is None:
            problems.append(f"line {p['line']}: no id for Table {t} label '{p['label']}' -- add it to pipeline/labels.csv")
            continue
        if sid == "skip":
            continue
        sid = int(sid)
        try:
            nums = [to_num(c) for c in p["cells"]]
        except ValueError:
            problems.append(f"line {p['line']}: non-numeric cell in {p['cells']}")
            continue
        if t == 7:
            if len(nums) not in (0, 2, 3):
                problems.append(f"line {p['line']}: Table 7 row needs 3 cells (March 31, current, change), got {len(nums)}")
                continue
            vals = {"py": nums[0] if nums else None, "ty": nums[1] if nums else None, "pf": None, "cf": None}
            if len(nums) == 3 and None not in nums[:2] and nums[2] is not None:
                pct.append((t, sid, "change", nums[1] - nums[0], nums[2]))
        else:
            if len(nums) == 6:                                     # Tables 2-4 carry % columns
                pct.append((t, sid, "this month %", nums[0], nums[1], nums[2]))
                pct.append((t, sid, "FY-to-date %", nums[3], nums[4], nums[5]))
                nums = [nums[0], nums[1], nums[3], nums[4]]
            if len(nums) not in (0, 4):
                problems.append(f"line {p['line']}: expected 4 values (or 6 with % columns), got {len(nums)}")
                continue
            vals = dict(zip(V, nums)) if nums else dict.fromkeys(V)
            if sid in CASH_IDS:
                vals["py"] = vals["ty"] = None
        if sid in rows:
            problems.append(f"line {p['line']}: id {sid} appears twice in Table {t}")
            continue
        rows[sid] = {"table": t, "id": sid, **vals}
    # synthetic id 104 = 103 + 107 (program expenses incl. net actuarial losses)
    if 103 in rows and 107 in rows:
        rows[104] = {"table": 1, "id": 104, **{v: (None if rows[103][v] is None or rows[107][v] is None
                                                    else rows[103][v] + rows[107][v]) for v in V}}
    # attach rowid / name / title: continue what the CSV used most recently
    schema_ids = {int(e["id"]): (int(t), e) for t, es in schema["tables"].items() for e in es}
    out = []
    for sid, r in rows.items():
        tpl = store.latest.get(sid)
        if tpl is not None:
            rowid, name, title = tpl["rowid"], tpl["name"], tpl["title"]
        elif sid in schema_ids:
            rowid, name = str(schema_ids[sid][1]["rowid"]), schema_ids[sid][1]["name"]
            title = next((x["title"] for x in store.latest.values() if int(x["tablenum"]) == r["table"]), "")
            problems.append(f"id {sid} has no earlier rows in the CSV; used schema rowid/name -- review")
        else:
            problems.append(f"id {sid} is new: add it to fiscalmon_schema.json and explorer/data/items.csv")
            continue
        if sid == 103:
            rowid = "9006"
        out.append({**meta, "tablenum": str(r["table"]), "title": title, "rowid": rowid, "id": str(sid),
                    "name": name, **{VCOL[v]: fmt(r[v]) for v in V}, "_v": r})
    out.sort(key=lambda r: (int(r["tablenum"]), float(r["rowid"])))
    return out, problems, pct

# ---------------------------------------------------------------------------- checks
SUMS = [  # lhs = sum(sign * id); None-valued terms count as 0 when the line isn't published
    (106, [101, 103, 105]), (108, [106, 107]), (111, [108, 110]), (114, [111, 113]),
    (205, [202, 203, 204]), (211, [207, 208, 209, 210]), (213, [205, 211]), (218, [213, 214, 215, 217]),
    (311, [304, 305, 309, 310]), (328, [318, 319, 323, 324, 384, 325, 781, 327]), (368, [346, 365]),
    (369, [311, 328, 344, 368]), (371, [369, 370]), (376, [371, 372]),
    (413, [403, 404, 405, 406, 407, 408, 409, 410, 411, 412]), (414, [400, 413]), (416, [414, 415]), (419, [416, 417]),
    (520, [513, 515, 516, 518, 519]), (522, [500, 520]),
    (617, [606, 610]), (623, [617, 619]), (628, [623, 626]), (630, [600, 628]),
    (721, [710, 713]), (725, [721, 718, 724]), (731, [727, 729, 730]), (732, [725, 731]),
    (743, [733, -741]), (745, [743, -744]),
]
EQUALS = [  # same number published in two tables (second id may be sign-flipped)
    (101, 218), (103, -369), (103, -414), (105, -370), (105, -415), (107, -372), (107, -417),
    (369, 414), (370, 415), (372, 417), (376, 419), (365, 413), (108, 500), (110, 520), (111, 522),
    (111, 600), (113, 628), (114, 630), (116, 631),
]

def run_checks(rows, ym, store, pct):
    meta, y, m = month_meta(ym)
    fymon = int(meta["fymon"])
    vals = {int(r["id"]): r["_v"] for r in rows}
    errors, warns, info = [], [], []
    g = lambda i, v: vals.get(i, {}).get(v)

    # 1. coverage: same lines as the most recent stored month (Tables 1-6) and Table 7 month
    tabs = {int(r["tablenum"]) for r in rows}
    if any(t in tabs for t in range(1, 7)):
        last = max((d for d in store.dates if d < (y, m)), default=None)
        if last:
            exp = store.ids_in(*last, set(range(1, 7)))
            got = {i for i in vals if vals[i]["table"] <= 6}
            if exp - got: errors.append(f"lines in {last[0]}m{last[1]} but missing now (Tables 1-6): {sorted(exp - got)}")
            if got - exp: warns.append(f"lines new this month (Tables 1-6): {sorted(got - exp)}")
    if 7 in tabs:
        t7m = [d for d in store.dates if d < (y, m) and store.ids_in(*d, {7})]
        if t7m:
            exp, got = store.ids_in(*t7m[-1], {7}), {i for i in vals if vals[i]["table"] == 7}
            if exp - got: errors.append(f"Table 7 lines missing vs {t7m[-1][0]}m{t7m[-1][1]}: {sorted(exp - got)}")
            if got - exp: warns.append(f"Table 7 lines new this month: {sorted(got - exp)}")

    # 2. accounting identities within the report
    for lhs, terms in SUMS:
        if lhs not in vals:
            continue
        for v in V:
            if g(lhs, v) is None:
                continue
            tot = sum((1 if t > 0 else -1) * (g(abs(t), v) or 0) for t in terms)
            tol = max(2, len(terms))
            if abs(g(lhs, v) - tot) > tol:
                errors.append(f"identity {lhs} = {' + '.join(map(str, terms))} fails in {VCOL[v]}: {fmt(g(lhs, v))} vs {fmt(tot)}")
    for a, b in EQUALS:
        sb, b = (1 if b > 0 else -1), abs(b)
        if a not in vals or b not in vals:
            continue
        for v in V:
            if g(a, v) is None or g(b, v) is None:
                continue
            if abs(g(a, v) - sb * g(b, v)) > 1:
                errors.append(f"id {a} and id {b} should match in {VCOL[v]}: {fmt(g(a, v))} vs {fmt(sb * g(b, v))}")
    # published % changes and Table 7 changes must agree with the transcribed levels
    for c in pct:
        if c[2] == "change":
            _, sid, _, calc, pub = c
            if abs(calc - pub) > 1:
                errors.append(f"Table 7 id {sid}: published change {fmt(pub)} but levels imply {fmt(calc)}")
            continue
        t, sid, what, old, new, pub = c
        if None in (old, new, pub) or old == 0:
            continue
        calc = (new - old) / abs(old) * 100           # Finance uses old or |old| as the base
        if min(abs(calc - pub), abs(-calc - pub)) > 0.15 + 50 / max(abs(old), 1):
            errors.append(f"Table {t} id {sid} {what}: published {pub} but values imply {calc:.1f}")

    # 3. fiscal-year-to-date continuity with the previous stored month (warnings: Finance revises)
    py_, pm_ = shift(y, m, -1)
    flows = [i for i, r in vals.items() if r["table"] <= 6 and i not in CASH_IDS]
    if fymon == 1:
        for i in flows:
            for a, b in (("cf", "ty"), ("pf", "py")):
                if g(i, a) is not None and g(i, b) is not None and g(i, a) != g(i, b):
                    warns.append(f"April: id {i} year-to-date {VCOL[a]} {fmt(g(i, a))} differs from month {fmt(g(i, b))}")
    elif store.has(py_, pm_):
        for i in flows:
            for ytd, mo in (("cf", "ty"), ("pf", "py")):
                prev = store.val(py_, pm_, i, ytd)
                if None in (g(i, ytd), g(i, mo), prev):
                    continue
                d = g(i, ytd) - prev - g(i, mo)
                if abs(d) > 3:
                    warns.append(f"id {i} {VCOL[ytd]}: {fmt(g(i, ytd))} - last month {fmt(prev)} = {fmt(g(i, ytd) - prev)}, "
                                 f"but this month is {fmt(g(i, mo))} (gap {fmt(d)})")
        for i, flow in ((631, 630), (116, 114)):
            prev = store.val(py_, pm_, i, "cf")
            if i in vals and None not in (g(i, "cf"), prev, g(flow, "ty")) and abs(g(i, "cf") - prev - g(flow, "ty")) > 2:
                warns.append(f"cash id {i}: {fmt(g(i, 'cf'))} - last month {fmt(prev)} != change in cash {fmt(g(flow, 'ty'))}")
    else:
        warns.append(f"{py_}m{pm_} is not in the CSV, so year-to-date continuity was not checked")

    # 4. prior-year columns against what was stored a year ago (warnings: restatements happen)
    ly, lm = y - 1, m
    if store.has(ly, lm):
        n = 0
        for i, r in vals.items():
            if r["table"] == 7:
                continue
            for new, old in (("py", "ty"), ("pf", "cf")):
                was = store.val(ly, lm, i, old)
                if None in (g(i, new), was) or abs(g(i, new) - was) <= 1:
                    continue
                n += 1
                info.append(f"id {i} {VCOL[new]} {fmt(g(i, new))} vs {fmt(was)} stored for {ly}m{lm} (diff {fmt(g(i, new) - was)})")
    # Table 7 opening balances vs the stored March report of the previous fiscal year
    if 7 in tabs:
        fy = int(meta["fyear"])
        if store.has(fy, 3) and (y, m) != (fy, 3):
            for i, r in vals.items():
                if r["table"] == 7 and None not in (r["py"], store.val(fy, 3, i, "ty")) and abs(r["py"] - store.val(fy, 3, i, "ty")) > 1:
                    info.append(f"Table 7 id {i} March 31 balance {fmt(r['py'])} vs {fmt(store.val(fy, 3, i, 'ty'))} in {fy}m3 report")
    return errors, warns, info

# ---------------------------------------------------------------------------- report
def headline(rows):
    v = {int(r["id"]): r["_v"] for r in rows}
    out = []
    for i, lab in ((108, "Budgetary balance"), (101, "Revenues"), (104, "Program expenses (incl. net actuarial losses)"), (105, "Public debt charges")):
        if i in v and v[i]["cf"] is not None:
            sgn = -1 if i in (104, 105) else 1
            out.append(f"| {lab} | {fmt(sgn * v[i]['ty'])} | {fmt(sgn * v[i]['cf'])} | {fmt(sgn * v[i]['pf'])} |")
    if not out:
        return ""
    return "| $ millions | This month | FY to date | FY to date, a year earlier |\n|---|---:|---:|---:|\n" + "\n".join(out)

def report(ym, rows, problems, errors, warns, info, mode):
    lines = [f"# Fiscal Monitor {ym}: {mode}", "",
             f"{len(rows)} rows across Tables {', '.join(sorted({r['tablenum'] for r in rows}))}.", ""]
    h = headline(rows)
    if h:
        lines += [h, ""]
    lines += [f"## Mapping problems ({len(problems)})"] + [f"- {p}" for p in problems] + [""]
    lines += [f"## Errors ({len(errors)})"] + [f"- {e}" for e in errors] + [""]
    lines += [f"## Warnings ({len(warns)})", "Year-to-date figures that don't follow from last month's report plus this month. "
              "Usually Finance Canada revising earlier months; each needs a short explanation."] + [f"- {w}" for w in warns] + [""]
    lines += [f"## Revisions to year-earlier figures ({len(info)})", "Prior-year columns that differ from what was stored a year ago "
              "(restatements, reclassifications, audited Public Accounts figures). Informational."] + [f"- {w}" for w in info]
    return "\n".join(lines) + "\n"

# ---------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["check", "append", "compare"])
    ap.add_argument("raw")
    ap.add_argument("--month", required=True, help="report month, YYYY-MM")
    ap.add_argument("--force", action="store_true", help="append despite check errors (only after review)")
    a = ap.parse_args()
    meta, y, m = month_meta(a.month)
    stored = load_csv()
    present = any(r["date"] == meta["date"] for r in stored)
    store = Store(stored, exclude_date=meta["date"])
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    rows, problems, pct = to_rows(parse(a.raw), a.month, store, load_labels(), schema)
    errors, warns, info = run_checks(rows, a.month, store, pct)

    if a.cmd == "compare":
        old = {r["id"]: r for r in stored if r["date"] == meta["date"] and int(r["tablenum"]) in {int(x["tablenum"]) for x in rows}}
        new = {r["id"]: r for r in rows}
        diffs = []
        for i in sorted(set(old) | set(new), key=int):
            if i not in old or i not in new:
                diffs.append(f"id {i}: only in {'transcription' if i in new else 'CSV'}")
                continue
            for c in COLS:
                if old[i][c] != new[i][c]:
                    diffs.append(f"id {i} {c}: CSV '{old[i][c]}' vs new '{new[i][c]}'")
        print(report(a.month, rows, problems, errors, warns, info, "compare with stored rows"))
        print(f"## Differences from the stored rows ({len(diffs)})")
        print("\n".join(diffs) if diffs else "None: the transcription reproduces the CSV exactly.")
        sys.exit(2 if problems else (1 if errors or diffs else 0))

    txt = report(a.month, rows, problems, errors, warns, info, "check" if a.cmd == "check" else "append")
    REPORTS.mkdir(exist_ok=True)
    (REPORTS / f"{a.month}.md").write_text(txt, encoding="utf-8")
    print(txt)
    if problems:
        sys.exit(2)
    if a.cmd == "check":
        sys.exit(1 if errors else 0)
    if present:
        print(f"{meta['date']} is already in {CSV_PATH.name}; nothing appended.")
        sys.exit(3)
    if errors and not a.force:
        print("Not appended: fix the errors (or rerun with --force after review).")
        sys.exit(1)
    raw = CSV_PATH.read_bytes()
    with open(CSV_PATH, "a", newline="", encoding="utf-8") as f:
        if raw and not raw.endswith(b"\n"):
            f.write("\r\n")
        w = csv.writer(f, lineterminator="\r\n")
        for r in rows:
            w.writerow([r[c] for c in COLS])
    print(f"Appended {len(rows)} rows for {meta['date']} to {CSV_PATH.name}.")

if __name__ == "__main__":
    main()
