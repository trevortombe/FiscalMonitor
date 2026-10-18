# Fiscal Monitor

Monthly federal government financial results from the Department of Finance Canada's
[Fiscal Monitor](https://www.canada.ca/en/department-finance/services/publications/fiscal-monitor.html),
compiled into one consistent dataset from January 2000 on, plus the
[Fiscal Monitor Explorer](https://www.financesofthenation.ca/fiscal-monitor) for
[Finances of the Nation](https://financesofthenation.ca).

- **`fiscalmon-clean.csv`**: the dataset. One row per report month and published line of Tables 1 to 7, in millions of dollars.
- **`explorer/fiscal_monitor.html`**: the interactive explorer, a single self-contained file.

## How it updates

A scheduled Claude task runs on each Fiscal Monitor release date. It reads the new report,
transcribes its tables (`raw/`), checks them (`pipeline/fm.py`: every line matched to the
series it continues, the accounting identities within and across tables, the published per cent
changes, and year-to-date figures against last month's report), appends the month, rebuilds the
explorer with `explorer/build.R` and `explorer/validate.R`, and opens a pull request. The check
report for each month is in `reports/`.

After reviewing and merging the pull request, upload `explorer/fiscal_monitor.html` to
financesofthenation.ca as before.

Anything unusual (a renamed or new line, a table that doesn't add up, revisions) is resolved in
the pull request and explained there. `CLAUDE.md` has the full procedure.

## GitHub Pages

The repository is also served with GitHub Pages (Settings → Pages → Deploy from a branch → `main`, `/ (root)`):
https://trevortombe.github.io/FiscalMonitor/ opens the explorer, and each merged update republishes it.
The financesofthenation.ca copy remains the one embedded in WordPress: the explorer's embedded mode
(hiding its masthead, sizing the iframe, following the page address) needs the tool and the page on the
same domain. To embed the GitHub Pages copy elsewhere, use the cross-domain snippet in `explorer/README.md`.

## Working locally

Clone once, then `git pull` before working on the files. To add a month by hand:

```sh
python3 pipeline/fm.py check  raw/2026-08.txt --month 2026-08
python3 pipeline/fm.py append raw/2026-08.txt --month 2026-08
cd explorer && Rscript -e 'source("build.R")' && Rscript -e 'source("validate.R")'
```

## Licence

The compiled dataset and the explorer are released under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Source data from the Department of
Finance Canada are under the Open Government Licence – Canada.
