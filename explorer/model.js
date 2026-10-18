/* =============================================================================
   model.js -- measures and units for the Fiscal Monitor Explorer
   -----------------------------------------------------------------------------
   Each Fiscal Monitor line is stored as four published columns, in $ millions
   (Table 1 expenses already turned positive by build.R):

     py  prior year, same month        ty  this year, the month
     pf  prior fiscal year to date     cf  current fiscal year to date

   Which pair a view uses depends on the line's type (data/items.csv):

     flow      Monthly view  -> value ty, comparison py
               Year-to-date  -> value cf, comparison pf
     balance   Cash balances (ids 116, 631). Finance Canada reports these only in
               the year-to-date columns, so both views use cf and pf.
     position  Table 7 balances. ty is the end-of-month balance and py the balance
               on March 31 of the previous fiscal year, in both views.

   In April, the first month of the fiscal year, year to date equals the month, so
   a blank year-to-date figure for a flow is filled with the monthly one.

   UNITS. Every amount covers a run of months: one month (monthly flows), April to
   the month (year to date), the 12 months to the month (12-month totals), or a
   single point (balances). Over the months a..b it covers, an amount x becomes:

     nom   x                                         $ millions
     real  x / mean(CPI[a..b]) * 100                 $ millions of the base year
     pc    x * 1e6 / mean(POP[a..b])                 dollars per person
     rpc   x * 1e6 / mean(POP[a..b]) / mean(CPI[a..b]) * 100
     gdp   x / sum(GDP[a..b]) * 100                  % of GDP over the same months
           (balances: x / sum(GDP[t-11..t]) * 100, % of the past year's GDP)

   CPI, POP and GDP are monthly series that build.R interpolates from the annual
   FON macro data (GDP is $ millions per month). The comparison amount uses the
   months a year earlier. Changes are then taken in the chosen units.

   MEASURES, for value v and comparison p in month t, both in the chosen units:

     level   v
     yoy     v - p                                 change from a year earlier
     yoyp    (v - p) / |p| * 100                   change from a year earlier, %
     mom     v(t) - v(t-1)                         change from the previous month
     momp    (v(t) - v(t-1)) / |v(t-1)| * 100      change from the previous month, %
     r12     ty(t-11) + ... + ty(t), in units over those 12 months
                                                   12-month total, flows only, all
                                                   12 months needed

   The comparison p is the prior-year figure as published in month t's report, so
   it includes any restatement Finance Canada made. The month-to-month change uses
   the two reports' own figures and needs both consecutive months.

   validate.R recomputes every measure in every unit in R from fiscalmon-clean.csv
   and data/macro.csv. Months are numbered from D.mo0/D.y0 (0 = first month).
   ============================================================================= */
(function (root) {
  'use strict';

  var MEASURES = [
    { id: 'level', label: 'Amount',                                 kind: 'level' },
    { id: 'yoy',   label: 'Change from a year earlier',             kind: 'change' },
    { id: 'yoyp',  label: 'Change from a year earlier (%)',         kind: 'pct' },
    { id: 'mom',   label: 'Change from the previous month',         kind: 'change' },
    { id: 'momp',  label: 'Change from the previous month (%)',     kind: 'pct' },
    { id: 'r12',   label: '12-month total (monthly values)',        kind: 'level' }
  ];
  function unitsList(D) {
    var b = D.macro.base;
    return [
      { id: 'nom',  label: 'Millions of dollars',              axis: 'Millions of dollars',              text: 'millions of dollars' },
      { id: 'real', label: 'Millions of ' + b + ' dollars',    axis: 'Millions of ' + b + ' dollars',    text: 'millions of ' + b + ' dollars' },
      { id: 'pc',   label: 'Dollars per person',               axis: 'Dollars per person',               text: 'dollars per person' },
      { id: 'rpc',  label: b + ' dollars per person',          axis: b + ' dollars per person',          text: b + ' dollars per person' },
      { id: 'gdp',  label: 'Per cent of GDP',                  axis: 'Per cent of GDP',                  text: 'per cent of GDP' }
    ];
  }

  // The four published columns for line id in month t, or null if not in that report
  function raw(D, id, t) {
    var s = D.series[id];
    if (!s) return null;
    var i = t - s.s;
    if (i < 0 || i >= s.ty.length) return null;
    var r = [s.py[i], s.ty[i], s.pf[i], s.cf[i]];
    for (var k = 0; k < 4; k++) if (r[k] === undefined) r[k] = null;
    return r[0] === null && r[1] === null && r[2] === null && r[3] === null ? null : r;
  }

  // Line type from data/items.csv; build.R lists only the non-flow lines
  function typeOf(D, id) { return (D.types && D.types[id]) || 'flow'; }
  function isApril(D, t) { return ((D.mo0 - 1 + t) % 12 + 12) % 12 === 3; }
  // First month (April) of the fiscal year that month t falls in
  function fyStartT(D, t) { var m = ((D.mo0 - 1 + t) % 12 + 12) % 12; return t - ((m - 3 + 12) % 12); }

  // Macro series at month t (null outside the data)
  function mac(D, k, t) { var a = D.macro[k], i = t - D.macro.s; return i >= 0 && i < a.length ? a[i] : null; }
  function meanOf(D, k, a, b) { var s = 0, x; for (var t = a; t <= b; t++) { x = mac(D, k, t); if (x === null) return null; s += x; } return s / (b - a + 1); }
  function sumOf(D, k, a, b)  { var s = 0, x; for (var t = a; t <= b; t++) { x = mac(D, k, t); if (x === null) return null; s += x; } return s; }

  // Express amount x (covering months a..b) in units u; stock = a balance at month b
  function inUnits(D, x, u, a, b, stock) {
    if (x === null) return null;
    var c, p, g;
    switch (u) {
      case 'nom':  return x;
      case 'real': c = meanOf(D, 'cpi', a, b); return c ? x / c * 100 : null;
      case 'pc':   p = meanOf(D, 'pop', a, b); return p ? x * 1e6 / p : null;
      case 'rpc':  p = meanOf(D, 'pop', a, b); c = meanOf(D, 'cpi', a, b); return p && c ? x * 1e6 / p / c * 100 : null;
      case 'gdp':  g = stock ? sumOf(D, 'gdp', b - 11, b) : sumOf(D, 'gdp', a, b); return g ? x / g * 100 : null;
    }
    return null;
  }

  // Value and comparison for a view, in units u: col is 'm' (monthly) or 'ytd'
  function pair(D, id, t, col, u) {
    u = u || 'nom';
    var r = raw(D, id, t);
    if (!r) return { v: null, p: null };
    var type = typeOf(D, id), v, p, a = t, stock = type !== 'flow';
    if (type === 'balance')       { v = r[3]; p = r[2]; }
    else if (type === 'position') { v = r[1]; p = r[0]; }
    else if (col === 'ytd') {
      v = r[3]; p = r[2]; a = fyStartT(D, t);
      if (isApril(D, t)) { if (v === null) v = r[1]; if (p === null) p = r[0]; }
    }
    else                          { v = r[1]; p = r[0]; }
    // Table 7's comparison is March 31 of the previous fiscal year, not a year earlier
    var tp = type === 'position' ? fyStartT(D, t) - 1 : t - 12, ap = type === 'position' ? tp : a - 12;
    return { v: inUnits(D, v, u, a, t, stock), p: inUnits(D, p, u, ap, tp, stock) };
  }

  function pctChange(a, b) { return a === null || b === null || b === 0 ? null : (a - b) / Math.abs(b) * 100; }

  function value(D, id, t, col, m, u) {
    var c, prev, k, sum, x;
    switch (m) {
      case 'level': return pair(D, id, t, col, u).v;
      case 'yoy':   c = pair(D, id, t, col, u); return c.v === null || c.p === null ? null : c.v - c.p;
      case 'yoyp':  c = pair(D, id, t, col, u); return pctChange(c.v, c.p);
      case 'mom':
      case 'momp':
        c = pair(D, id, t, col, u).v; prev = pair(D, id, t - 1, col, u).v;
        if (c === null || prev === null) return null;
        return m === 'mom' ? c - prev : pctChange(c, prev);
      case 'r12':
        if (typeOf(D, id) !== 'flow') return null;
        sum = 0;
        for (k = 0; k < 12; k++) {
          x = pair(D, id, t - k, 'm', 'nom').v;
          if (x === null) return null;
          sum += x;
        }
        return inUnits(D, sum, u || 'nom', t - 11, t, false);
    }
    return null;
  }

  root.FMModel = { MEASURES: MEASURES, units: unitsList, raw: raw, pair: pair, value: value, typeOf: typeOf,
                   pctChange: pctChange, inUnits: inUnits, fyStartT: fyStartT };
})(typeof window !== 'undefined' ? window : this);
