# =============================================================================
# build.R -- assemble the Fiscal Monitor Explorer into one HTML file
# -----------------------------------------------------------------------------
# Inputs
#   ../fiscalmon-clean.csv   the Fiscal Monitor dataset (one row per month x line)
#   data/items.csv           every line shown: table, label, indentation, type, sign
#   data/tables.csv          the seven tables: titles and short notes
#   data/macro.csv           FON macro data for Canada: GDP, population, CPI (annual).
#                            Refreshed from the FONmacro repository on each build
#                            when online; otherwise the saved copy is used.
#   model.js                 the measures (changes, 12-month totals) and units
#                            (2020 dollars, per person, per cent of GDP)
#   template.html            layout, styling and interface
#   FON_logo.png             logo
#
# Outputs
#   data.js                  the data as JavaScript (lets template.html run directly)
#   fiscal_monitor.html      the single file to upload / embed
#
# Monthly update: append the new month to ../fiscalmon-clean.csv, then run this
# script, then validate.R. The newest month becomes the default automatically.
#
# Usage: set the working directory to this folder, then source("build.R").
# Requires: dplyr, readr, jsonlite
# =============================================================================
suppressPackageStartupMessages({ library(dplyr); library(readr); library(jsonlite) })

# ---- Settings ------------------------------------------------------------------
SETTINGS <- list(
  tool_name    = "Fiscal Monitor Explorer",
  tool_url     = "www.financesofthenation.ca/fiscal-monitor",   # page the tool lives on
  licence_year = format(Sys.Date(), "%Y"),
  contact      = "ttombe@ucalgary.ca",
  real_base    = 2020                      # "2020 dollars": CPI averages 100 in this year
)
MACRO_URL  <- "https://raw.githubusercontent.com/FONCanada/FONmacro/main/MacroData.csv"
MACRO_FILE <- "data/macro.csv"
MACRO_VARS <- c(gdp = "Nominal GDP (Millions)", pop = "Population", cpi = "Canada-Wide CPI (2020=100)")
INPUT  <- "../fiscalmon-clean.csv"
OUTPUT <- "fiscal_monitor.html"

# ---- Read and check inputs -----------------------------------------------------
if (!file.exists(INPUT)) stop("Can't find ", INPUT, ". Run this from the explorer folder inside Fiscal Monitor.")
fm <- read_csv(INPUT, col_types = cols(.default = col_character()), na = c("", "NA"))
need <- c("year", "month", "tablenum", "rowid", "id", "name",
          "prior_year", "this_year", "prior_FY_to_date", "current_FY_to_date")
if (length(setdiff(need, names(fm)))) stop("Missing columns in ", INPUT, ": ", paste(setdiff(need, names(fm)), collapse = ", "))

items  <- read_csv("data/items.csv",  show_col_types = FALSE, col_types = cols(id = "i", table = "i", level = "i", sign = "i"))
tables <- read_csv("data/tables.csv", show_col_types = FALSE, col_types = cols(table = "i"), na = "")

# A lone dash in the published tables is stored as missing (shown as n/a), as before.
DASH <- c("", "-", "\u2013", "\u2014")
num  <- function(x) { x <- trimws(x); x[x %in% DASH] <- NA; suppressWarnings(parse_number(x, locale = locale(grouping_mark = ","))) }
fm_raw <- fm %>% filter(!grepl("^Note:", name))
fm <- fm %>%
  filter(!grepl("^Note:", name)) %>%                       # footnote rows carry no data
  transmute(year = as.integer(year), month = as.integer(month), table = as.integer(tablenum),
            rowid = as.numeric(rowid), id = as.integer(id), name,
            py = num(prior_year), ty = num(this_year), pf = num(prior_FY_to_date), cf = num(current_FY_to_date))

# Every row needs a month and id, and every non-blank value must be a number
bad <- fm %>% filter(is.na(year) | is.na(month) | is.na(id) | is.na(table))
if (nrow(bad)) stop(nrow(bad), " rows have a missing year, month, table or id in ", INPUT)
vals <- c("prior_year", "this_year", "prior_FY_to_date", "current_FY_to_date")
for (v in vals) {
  s <- trimws(fm_raw[[v]]); nonnum <- !is.na(s) & !s %in% DASH & !grepl("^-?[0-9][0-9,]*(\\.[0-9]+)?$", s)
  if (any(nonnum)) stop("Non-numeric ", v, " in ", INPUT, ": '", s[nonnum][1], "' (", sum(nonnum), " cells)")
}

fm <- fm %>% mutate(t = (year - min(year)) * 12 + month - 1)
m0 <- fm %>% filter(t == min(t)) %>% slice(1)
fm <- fm %>% mutate(t = t - min(t))                          # 0 = first month in the data
M  <- max(fm$t) + 1

# One row per month x line
dup <- fm %>% count(t, id) %>% filter(n > 1)
if (nrow(dup)) stop("Duplicate rows for ", nrow(dup), " month x id pairs, e.g. id ", dup$id[1], " in month ", dup$t[1] + 1, ". Fix ", INPUT, ".")

# Every line in the data must be described in data/items.csv
has_val <- fm %>% filter(!is.na(py) | !is.na(ty) | !is.na(pf) | !is.na(cf))
missing_items <- setdiff(unique(fm$id), items$id)
if (length(missing_items))
  stop("These ids are in ", INPUT, " but not in data/items.csv: ", paste(sort(missing_items), collapse = ", "),
       ". Add a row for each (table, id, label, level, kind, type, status).")
wrong_tab <- fm %>% distinct(id, table) %>% inner_join(select(items, id, it = table), by = "id") %>% filter(table != it)
if (nrow(wrong_tab)) stop("ids listed under the wrong table in data/items.csv: ", paste(wrong_tab$id, collapse = ", "))
if (any(duplicated(items$id))) stop("Duplicate ids in data/items.csv: ", paste(items$id[duplicated(items$id)], collapse = ", "))
if (!all(items$type %in% c("flow", "balance", "position"))) stop("data/items.csv: type must be flow, balance or position")
if (!all(items$kind %in% c("item", "total", "header"))) stop("data/items.csv: kind must be item, total or header")
if (!all(1:7 %in% tables$table)) stop("data/tables.csv must list tables 1 to 7")
if (!all(items$sign %in% c(1, -1))) stop("data/items.csv: sign must be 1 or -1")

# Sign: Table 1 publishes expenses, debt charges and net actuarial losses as
# negative numbers. Lines with sign -1 in data/items.csv are flipped so expenses
# are positive everywhere in the tool (and in its downloads).
fm <- fm %>% left_join(select(items, id, sign), by = "id") %>%
  mutate(py = py * sign, ty = ty * sign, pf = pf * sign, cf = cf * sign) %>% select(-sign)
has_val <- fm %>% filter(!is.na(py) | !is.na(ty) | !is.na(pf) | !is.na(cf))

# ---- Macro data: monthly GDP, population and CPI ------------------------------------
# FON macro data are annual (calendar years). They are turned into monthly series
# that are straight lines between mid-year points, with the mid-year points chosen
# so that each calendar year's twelve months average exactly to the annual value
# (so 12-month totals for a calendar year match annual GDP). Months after the last
# year continue that year's growth rate until the next annual value is published.
macro_raw <- tryCatch({
  tmp <- tempfile(fileext = ".csv")
  suppressWarnings(download.file(MACRO_URL, tmp, quiet = TRUE, mode = "wb"))
  x <- read_csv(tmp, show_col_types = FALSE) %>%
    filter(Region == "Canada", Variable %in% MACRO_VARS, Year >= 1990) %>% select(Year, Variable, Value)
  if (nrow(x) < 3 * 10) stop("too few rows")
  write_csv(x, MACRO_FILE)
  cat("Macro data refreshed from FONmacro.\n")
  x
}, error = function(e) {
  if (!file.exists(MACRO_FILE)) stop("Can't download the FON macro data and there is no saved copy at ", MACRO_FILE)
  cat("Couldn't download the FON macro data; using the saved copy in ", MACRO_FILE, ".\n", sep = "")
  read_csv(MACRO_FILE, show_col_types = FALSE)
})
if (!all(MACRO_VARS %in% macro_raw$Variable)) stop(MACRO_FILE, " must have ", paste(MACRO_VARS, collapse = ", "))

MS <- -24                                                    # macro series start two years before the data,
tt <- seq(MS, M - 1)                                         # for year-earlier comparisons in the first months
monthly <- function(var) {
  a  <- macro_raw %>% filter(Variable == var, !is.na(Value)) %>% arrange(Year)
  k  <- nrow(a)
  x  <- (a$Year - m0$year) * 12 + 6 - m0$month + 0.5        # mid-year, in months from the first month
  g  <- seq((a$Year[1] - m0$year) * 12 + 1 - m0$month, max(M - 1, x[k] + 6))   # every month covered
  yr <- m0$year + (g + m0$month - 1) %/% 12                  # calendar year of each month
  line <- function(A) {                                      # straight lines through the mid-year points
    v <- approx(x, A, xout = g, rule = 2)$y
    v[g > x[k]] <- A[k] * (A[k] / A[k - 1])^((g[g > x[k]] - x[k]) / 12)
    v[g < x[1]] <- A[1] * (A[2] / A[1])^((g[g < x[1]] - x[1]) / 12)
    v
  }
  A <- a$Value
  for (i in 1:200) {                                         # rescale points until annual averages match
    mu  <- tapply(line(A), yr, mean)[as.character(a$Year)]
    if (max(abs(mu / a$Value - 1)) < 1e-12) break
    A <- A * a$Value / mu
  }
  v <- line(A)
  list(v = v[match(tt, g)], last_year = max(a$Year), last_x = x[k])
}
cpi <- monthly(MACRO_VARS[["cpi"]]); pop <- monthly(MACRO_VARS[["pop"]]); gdp <- monthly(MACRO_VARS[["gdp"]])
base_cpi <- macro_raw %>% filter(Variable == MACRO_VARS[["cpi"]], Year == SETTINGS$real_base) %>% pull(Value)
if (length(base_cpi) != 1) stop("No CPI for the real_base year ", SETTINGS$real_base, " in ", MACRO_FILE)
macro_last <- min(cpi$last_year, pop$last_year, gdp$last_year)
MACRO <- list(
  s   = MS,
  cpi = round(cpi$v / base_cpi * 100, 6),                    # index, real_base year = 100
  pop = round(pop$v),                                        # persons
  gdp = round(gdp$v / 12, 3),                                # $ millions per month (annual rate / 12)
  base = SETTINGS$real_base,
  last_year = macro_last,
  extrap_from = floor(min(cpi$last_x, pop$last_x, gdp$last_x)) + 1   # first month past the last mid-year
)

# ---- Pack the series ------------------------------------------------------------
# Each line is {s: first month, py, ty, pf, cf: [values]}; missing months are null.
pack <- function(g) {
  s <- min(g$t); e <- max(g$t); idx <- match(seq(s, e), g$t)
  col <- function(v) I(v[idx])                               # I() keeps one-month series as arrays
  list(s = s, py = col(g$py), ty = col(g$ty), pf = col(g$pf), cf = col(g$cf))
}
series <- lapply(split(has_val, has_val$id), pack)

# Months each line appears in (for the item menus)
span <- has_val %>% group_by(id) %>% summarise(first = min(t), last = max(t), .groups = "drop")
items_out <- items %>% left_join(span, by = "id") %>%
  filter(kind == "header" | !is.na(first))                   # drop lines that never have data

# ---- Statement layouts ----------------------------------------------------------
# The rows of each table in each month's report, in the published order (rowid).
# Program expenses excluding net actuarial losses (id 103) carries the sentinel
# rowid 9006, so it is placed just before program expenses (id 104).
lay_rows <- fm %>%
  filter(id %in% items_out$id) %>%
  group_by(t) %>%
  mutate(rowid = ifelse(id == 103 & any(id == 104), rowid[id == 104][1] - 0.5, rowid)) %>%
  ungroup() %>%
  left_join(select(items, id, kind), by = "id") %>%
  filter(kind == "header" | !is.na(py) | !is.na(ty) | !is.na(pf) | !is.na(cf)) %>%
  arrange(table, t, rowid)
layouts <- list(); lay <- list()
for (tb in 1:7) {
  rows <- filter(lay_rows, table == tb)
  keys <- tapply(rows$id, rows$t, function(x) paste(x, collapse = "."))
  # a month whose rows are all headers has no data for the table
  has  <- has_val %>% filter(table == tb) %>% distinct(t) %>% pull(t)
  keys <- keys[names(keys) %in% as.character(has)]
  uniq <- unique(unname(keys))
  layouts[[as.character(tb)]] <- lapply(uniq, function(k) I(as.integer(strsplit(k, ".", fixed = TRUE)[[1]])))
  v <- rep(NA_integer_, M); v[as.integer(names(keys)) + 1] <- match(keys, uniq) - 1L
  lay[[as.character(tb)]] <- I(v)
}

types <- as.list(setNames(items$type, items$id)[items$type != "flow"])

today <- Sys.Date()
DATA <- list(
  settings = SETTINGS,
  built    = paste0(format(today, "%B "), as.integer(format(today, "%d")), format(today, ", %Y")),
  y0 = m0$year, mo0 = m0$month, n = M,           # month t is (y0, mo0) + t months
  tables  = tables,
  items   = items_out %>% select(table, id, label, level, kind, type, status, first, last),
  types   = types,
  series  = series,
  layouts = layouts,
  lay     = lay,
  macro   = MACRO
)

# ---- Write data.js -----------------------------------------------------------------
js <- paste0("/* Generated by build.R on ", today,
             " -- do not edit by hand; edit ../fiscalmon-clean.csv or data/*.csv instead. */\n",
             "window.FM_DATA = ",
             toJSON(DATA, digits = NA, dataframe = "rows", auto_unbox = TRUE, na = "null", null = "null"),
             ";\n")
writeBin(charToRaw(enc2utf8(js)), "data.js")

# ---- Inline everything into the final HTML ----------------------------------------
# Files are handled as raw bytes so no locale can re-encode characters.
read_text <- function(f) { x <- rawToChar(readBin(f, "raw", file.info(f)$size)); Encoding(x) <- "bytes"; x }
replace_once <- function(x, pattern, replacement) {
  Encoding(replacement) <- "bytes"
  pos <- regexpr(pattern, x, fixed = TRUE, useBytes = TRUE)
  if (pos < 0) stop("Placeholder not found in template.html: ", pattern)
  paste0(substr(x, 1, pos - 1), replacement,
         substr(x, pos + attr(pos, "match.length"), nchar(x, type = "bytes")))
}

html <- read_text("template.html")
html <- replace_once(html, '<script src="data.js"></script>', paste0("<script>\n", enc2utf8(js), "</script>"))
html <- replace_once(html, '<script src="model.js"></script>',
                     paste0("<script>\n", read_text("model.js"), "\n</script>"))
logo <- paste0("data:image/png;base64,",
               base64_enc(readBin("FON_logo.png", "raw", file.info("FON_logo.png")$size)))
html <- replace_once(html, 'src="FON_logo.png"', paste0('src="', logo, '"'))
writeBin(charToRaw(html), OUTPUT)

last <- fm %>% filter(t == max(t)) %>% slice(1)
cat(sprintf("Built %s (%.0f KB): %d lines in %d tables, %s %d to %s %d.\n",
            OUTPUT, file.info(OUTPUT)$size / 1024, length(series), 7,
            month.name[m0$month], m0$year, month.name[last$month], last$year))
cat(sprintf("Macro data to %d; months from %s %d on extend its growth rates.\n", macro_last,
            month.name[(m0$month - 1 + MACRO$extrap_from) %% 12 + 1], m0$year + (m0$month - 1 + MACRO$extrap_from) %/% 12))
