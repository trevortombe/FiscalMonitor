# =============================================================================
# validate.R -- check the explorer's numbers against the dataset
# -----------------------------------------------------------------------------
# Loads data.js and model.js into a JavaScript engine (V8) and checks them
# against ../fiscalmon-clean.csv, recomputed here in R:
#   * the four published columns, for every line and month
#   * the sign flip for Table 1 expenses (sign = -1 in data/items.csv)
#   * the monthly GDP, population and CPI series, interpolated here from
#     data/macro.csv the way build.R describes
#   * every measure (amount, changes from a year and a month earlier, 12-month
#     totals) x Monthly / Year to date x every unit (dollars, real dollars, per
#     person, real per person, per cent of GDP), for every line and month, using
#     the rules set out at the top of model.js
#   * the lines in each month's statement, against the lines in that month's report
#   * the default month, which should be the newest one
# Ends with PASS or FAIL. Run build.R first.
#
# Usage: set the working directory to this folder, then source("validate.R").
# Requires: dplyr, readr, jsonlite, V8
# =============================================================================
suppressPackageStartupMessages({ library(dplyr); library(readr); library(jsonlite); library(V8) })

ct <- v8()
invisible(ct$eval("var window = this;"))
invisible(ct$source("data.js"))
invisible(ct$source("model.js"))
n  <- ct$get("FM_DATA.n"); FM_mo0 <- ct$get("FM_DATA.mo0")

# ---- The dataset, read independently of build.R ---------------------------------
num <- function(x) { x <- trimws(x); x[x %in% c("", "-", "–", "—")] <- NA
                     as.numeric(gsub(",", "", x)) }
fm <- read_csv("../fiscalmon-clean.csv", col_types = cols(.default = col_character())) %>%
  filter(!grepl("^Note:", name)) %>%
  transmute(t = (as.integer(year) - ct$get("FM_DATA.y0")) * 12 + as.integer(month) - ct$get("FM_DATA.mo0"),
            table = as.integer(tablenum), id = as.integer(id),
            py = num(prior_year), ty = num(this_year), pf = num(prior_FY_to_date), cf = num(current_FY_to_date))
items <- read_csv("data/items.csv", show_col_types = FALSE)
fm <- fm %>% left_join(select(items, id, sign), by = "id") %>%
  mutate(py = py * sign, ty = ty * sign, pf = pf * sign, cf = cf * sign)
vals  <- fm %>% filter(!is.na(py) | !is.na(ty) | !is.na(pf) | !is.na(cf))
ids   <- sort(unique(vals$id))

# Complete grid: every line x every month, NA where not reported
grid <- expand.grid(t = 0:(n - 1), id = ids) %>% as_tibble() %>%
  left_join(select(vals, t, id, py, ty, pf, cf), by = c("t", "id")) %>%
  left_join(select(items, id, type), by = "id") %>%
  arrange(id, t)

fails <- 0
cmp <- function(a, b, what) {
  a <- as.numeric(a); b <- as.numeric(b)
  na_bad <- sum(is.na(a) != is.na(b))
  ok  <- !is.na(a) & !is.na(b)
  rel <- abs(a[ok] - b[ok]) / pmax(1, abs(b[ok]))
  bad <- sum(rel > 1e-7) + na_bad      # rounding noise between R and JavaScript sums
  cat(sprintf("  %-44s %8d values  max rel. diff %.1e  %s\n", what, sum(ok), if (any(ok)) max(rel) else 0,
              if (bad) paste(bad, "MISMATCHES") else "ok"))
  fails <<- fails + bad
}

# ---- 1. Published columns ---------------------------------------------------------
ct$assign("IDS", ids)
got_raw <- fromJSON(ct$eval(sprintf("JSON.stringify((function () { var out = [];
  IDS.forEach(function (id) { for (var t = 0; t < %d; t++) { var r = FMModel.raw(FM_DATA, id, t); out.push(r || [null, null, null, null]); } });
  return out; })())", n)))
got_raw[is.na(got_raw)] <- NA_real_
cat("Published columns,", length(ids), "lines x", n, "months:\n")
cmp(got_raw[, 1], grid$py, "prior year (monthly)")
cmp(got_raw[, 2], grid$ty, "this year (monthly)")
cmp(got_raw[, 3], grid$pf, "prior fiscal year to date")
cmp(got_raw[, 4], grid$cf, "current fiscal year to date")

# ---- 2. Monthly macro series -----------------------------------------------------------
# Straight lines between mid-year points chosen so each calendar year's months average
# to the annual value; past the last year, that year's growth. Recomputed here.
cat("\nMacro series:\n")
y0 <- ct$get("FM_DATA.y0"); MS <- ct$get("FM_DATA.macro.s"); base <- ct$get("FM_DATA.macro.base")
macro <- read_csv("data/macro.csv", show_col_types = FALSE)
tt <- seq(MS, n - 1)
interp <- function(var) {
  a <- macro %>% filter(Variable == var, !is.na(Value)) %>% arrange(Year); k <- nrow(a)
  x <- (a$Year - y0) * 12 + (6 - FM_mo0) + 0.5
  g <- seq((a$Year[1] - y0) * 12 + 1 - FM_mo0, max(n - 1, x[k] + 6)); yr <- y0 + (g + FM_mo0 - 1) %/% 12
  f <- function(A) ifelse(g > x[k], A[k] * (A[k] / A[k - 1])^((g - x[k]) / 12),
                    ifelse(g < x[1], A[1] * (A[2] / A[1])^((g - x[1]) / 12), approx(x, A, xout = g, rule = 2)$y))
  A <- a$Value
  for (i in 1:200) { mu <- tapply(f(A), yr, mean)[as.character(a$Year)]; if (max(abs(mu / a$Value - 1)) < 1e-12) break; A <- A * a$Value / mu }
  list(v = f(A)[match(tt, g)], all = f(A), yr = yr, a = a)
}
ci <- interp("Canada-Wide CPI (2020=100)"); pi_ <- interp("Population"); gi <- interp("Nominal GDP (Millions)")
want_cpi <- round(ci$v / ci$a$Value[ci$a$Year == base] * 100, 6)
want_pop <- round(pi_$v); want_gdp <- round(gi$v / 12, 3)
CPI <- ct$get("FM_DATA.macro.cpi"); POP <- as.numeric(ct$get("FM_DATA.macro.pop")); GDP <- ct$get("FM_DATA.macro.gdp")
cmp(CPI, want_cpi, "consumer price index"); cmp(POP, want_pop, "population"); cmp(GDP, want_gdp, "GDP per month")
# Each calendar year's months average to the annual value (GDP: add up to it)
for (z in list(ci, pi_, gi)) {
  mu <- tapply(z$all, z$yr, mean)[as.character(z$a$Year)]
  bad <- sum(abs(mu / z$a$Value - 1) > 1e-9)
  cat(sprintf("  %-44s %8d years   %s\n", paste("annual averages kept:", z$a$Variable[1]), nrow(z$a), if (bad) paste(bad, "MISMATCHES") else "ok"))
  fails <- fails + bad
}

# ---- 3. Measures, recomputed in R ----------------------------------------------------
lag1  <- function(x) c(NA, head(x, -1))
roll12 <- function(x) as.numeric(stats::filter(x, rep(1, 12), sides = 1))   # NA if any month is missing
pctch <- function(a, b) ifelse(is.na(a) | is.na(b) | b == 0, NA, (a - b) / abs(b) * 100)
csum <- function(x) c(0, cumsum(x))
CS <- list(cpi = csum(CPI), pop = csum(POP), gdp = csum(GDP))
rsum <- function(k, a, b) { ia <- a - MS + 1; ib <- b - MS + 1
  ifelse(ia < 1 | ib > length(CPI) | is.na(a), NA, CS[[k]][ib + 1] - CS[[k]][ia]) }
rmean <- function(k, a, b) rsum(k, a, b) / (b - a + 1)
units_of <- function(x, u, a, b, stock) { stock <- rep_len(stock, length(x)); switch(u,
  nom  = x,
  real = x / rmean("cpi", a, b) * 100,
  pc   = x * 1e6 / rmean("pop", a, b),
  rpc  = x * 1e6 / rmean("pop", a, b) / rmean("cpi", a, b) * 100,
  gdp  = x / ifelse(stock, rsum("gdp", b - 11, b), rsum("gdp", a, b)) * 100) }
fy_start <- function(t) t - ((t + FM_mo0 - 1) %% 12 - 3) %% 12          # April of the fiscal year

expected <- function(col, u) {
  g <- grid %>% mutate(
    stock = type != "flow",
    v = case_when(type == "balance" ~ cf, type == "position" ~ ty, col == "ytd" ~ cf, TRUE ~ ty),
    p = case_when(type == "balance" ~ pf, type == "position" ~ py, col == "ytd" ~ pf, TRUE ~ py),
    # April: year to date equals the month, used where the year-to-date figure is blank
    april = (t + FM_mo0 - 1) %% 12 == 3 & type == "flow" & col == "ytd",
    v = ifelse(april & is.na(v), ty, v), p = ifelse(april & is.na(p), py, p),
    a  = ifelse(type == "flow" & col == "ytd", fy_start(t), t),
    tp = ifelse(type == "position", fy_start(t) - 1, t - 12),
    ap = ifelse(type == "position", tp, a - 12),
    v = units_of(v, u, a, t, stock), p = units_of(p, u, ap, tp, stock))
  g %>% group_by(id) %>% mutate(
    level = v, yoy = v - p, yoyp = pctch(v, p),
    mom = v - lag1(v), momp = pctch(v, lag1(v)),
    r12 = ifelse(type == "flow", units_of(roll12(ty), u, t - 11, t, FALSE), NA)) %>% ungroup()
}

measures <- c("level", "yoy", "yoyp", "mom", "momp", "r12")
cat("\nMeasures:\n")
for (u in c("nom", "real", "pc", "rpc", "gdp")) for (col in c("m", "ytd")) {
  e <- expected(col, u)
  js <- ct$eval(sprintf("JSON.stringify((function () { var ms = %s, out = [];
    IDS.forEach(function (id) { for (var t = 0; t < %d; t++) out.push(ms.map(function (m) { return FMModel.value(FM_DATA, id, t, '%s', m, '%s'); })); });
    return out; })())", toJSON(measures), n, col, u))
  got <- fromJSON(js); got[is.na(got)] <- NA_real_
  for (k in seq_along(measures)) cmp(got[, k], e[[measures[k]]], sprintf("%-5s %-3s %s", measures[k], col, u))
}

# ---- 4. Statement lines ---------------------------------------------------------------
cat("\nStatements:\n")
lay <- fromJSON(ct$eval("JSON.stringify((function () { var out = [];
  [1,2,3,4,5,6,7].forEach(function (tb) { for (var t = 0; t < FM_DATA.n; t++) { var li = FM_DATA.lay[tb][t];
    if (li === null) continue; FM_DATA.layouts[tb][li].forEach(function (id) { out.push([tb, t, id]); }); } });
  return out; })())"))
lay <- tibble(table = lay[, 1], t = lay[, 2], id = lay[, 3]) %>%
  left_join(select(items, id, kind), by = "id") %>% filter(kind != "header")
# Header rows (kind "header" in data/items.csv) are labels only; values stored on them are not shown
hdr_vals <- vals %>% semi_join(filter(items, kind == "header"), by = "id")
if (nrow(hdr_vals)) cat(sprintf("  Note: %d header row(s) carry values in the dataset and are not shown: %s\n", nrow(hdr_vals),
                                paste0("id ", hdr_vals$id, " in ", month.name[(hdr_vals$t + ct$get("FM_DATA.mo0") - 1) %% 12 + 1], " ",
                                       ct$get("FM_DATA.y0") + (hdr_vals$t + ct$get("FM_DATA.mo0") - 1) %/% 12, collapse = "; ")))
want <- vals %>% anti_join(filter(items, kind == "header"), by = "id") %>% distinct(table, t, id)
miss  <- anti_join(want, lay, by = c("table", "t", "id"))
extra <- anti_join(lay, want, by = c("table", "t", "id"))
cat(sprintf("  %-44s %8d lines  %s\n", "lines in each month's statement", nrow(want),
            if (nrow(miss) + nrow(extra)) paste(nrow(miss), "missing,", nrow(extra), "extra") else "ok"))
fails <- fails + nrow(miss) + nrow(extra)

# ---- 5. Default month -------------------------------------------------------------------
last_js <- ct$eval("(function () { var L = -1; for (var t = 0; t < FM_DATA.n; t++) if (Object.keys(FM_DATA.lay).some(function (k) { return FM_DATA.lay[k][t] !== null; })) L = t; return L; })()")
ok <- as.integer(last_js) == max(fm$t)
cat(sprintf("  %-44s %s\n", "newest month is the default", if (ok) "ok" else "MISMATCH"))
fails <- fails + !ok

cat(if (fails == 0) "\nPASS\n" else paste0("\nFAIL (", fails, " mismatches)\n"))
