//+------------------------------------------------------------------+
//| GeneralMacro.mq5                                                 |
//| General macro bias + framework dashboard (generalization of      |
//| GoldMacroStandalone v2.00). Does NOT place orders.               |
//|                                                                  |
//| Tools -> Options -> Expert Advisors -> Allow WebRequest for:     |
//|   https://query1.finance.yahoo.com                               |
//|   https://nfs.faireconomy.media                                  |
//|   https://fred.stlouisfed.org       (fund history, all currencies)|
//| The MT5 built-in economic calendar (v4.9, third fund source)    |
//| needs NO WebRequest entry - it reads the terminal's own database.|
//| Attach to any watchlist chart (XAUUSD keeps full legacy gold     |
//| behavior; USTEC/US30 are first-class index citizens since v4.3). |
//| AutoTrade can stay off.                                          |
//+------------------------------------------------------------------+
#property copyright "general_macro"
#property version   "4.92"
#property strict
#property description "General macro bias + framework dashboard. No trading."

input group "Schedule (America/Chicago)"
input bool   InpUsePcLocalAsChicago = true;  // true if Windows timezone is Central
input int    InpAsiaHour            = 18;    // 6pm
input int    InpNyHour              = 7;     // 7am
input int    InpTimerSec            = 20;
input bool   InpFetchOnAttach       = true;
input bool   InpAlertOnUpdate       = true;

input group "News"
input int    InpBlackoutBeforeMin   = 20;
input int    InpBlackoutAfterMin    = 15;

input group "Watchlist"
input string InpWatchlist           = "XAUUSD,EURUSD,GBPUSD,USDJPY,USDCAD,USDCHF,USTEC,US30";

input group "Framework"
input double InpMinRR               = 2.0;   // minimum R:R (vs extended target T2) for WHAT leg

input group "Risk"
input double InpRiskA               = 1.0;   // % equity risk, grade A
input double InpRiskB               = 0.5;   // % equity risk, grade B
input double InpRiskC               = 0.0;   // % equity risk, grade C (0 = skip)
input double InpMaxExposurePct      = 6.0;   // max total open risk, % of equity (prop-appropriate)
input double InpFirmDailyLossPct    = 5.0;   // firm daily loss limit, % (informational)

input group "Dashboard"
input int    InpCorner              = CORNER_LEFT_UPPER;
input int    InpX                   = 12;
input int    InpY                   = 24;
input int    InpWidth               = 520;
input int    InpPanelH              = 918;   // legacy (v4.5): panel auto-fits its content, this value is IGNORED - kept only so old .set files load without shifting other inputs

#define PREF "GM_"
#define NOISE 0.12
#define LONG_TH 0.28
#define SHORT_TH -0.28
// v4.5: panel height AUTO-FITS the content and no longer comes from
// an input (MT5 preserves stale saved inputs across recompiles, which
// left a tall empty black tail under the panel). PANEL_FIT_H is the
// fitted layout height from the v4.4 geometry: last fixed row rk3 at
// +815, legend at FIT-68 (+850), guide at FIT-48 (+870), error line
// at FIT-28 (+890), panel bottom at +918. If rows are added/removed
// from the layout, adjust this one number.
#define PANEL_FIT_H 918

struct Snap
{
   string symbol;
   double last;
   double pct1;
   double pct5;
   bool   ok;
};

struct Fac
{
   string key;
   string label;
   string yahoo;
   string yahoo2;
   bool   gold_likes_up;
   double weight;
   Snap   snap;
   int    score;
   double weighted;
};

struct News
{
   string title;
   string country;
   datetime gmt;
   int    minutes;
   string forecast;
   string actual;
   string surprise;
   bool   ok;
};

struct Ccy
{
   string code;
   string yahoo;        // Yahoo symbol for this currency's USD cross (DXY for USD)
   bool   up_is_ccy_up; // true if the cross rising means THIS currency strengthens
   Snap   snap;
   int    price_score;  // -1..+1 from the 1d/5d agreement method
   double fund;         // v4.1 fundamental-trend score, -3..+3 (valid only if fund_ok)
   bool   fund_ok;      // false = "bldg" (building): fewer than 2 scored indicators
   bool   fund_turn;    // a core series printed a TURN (see fund engine)
   datetime fund_stamp; // last time this currency's FUND was scored from a live fetch
   double strength;     // v4.1 total: price_score + fund, clamped -4..+4 (100% data-driven)
};

struct Tech
{
   bool   ok;
   double price;
   double basis;        // SMA(100) of last 100 closed D1 bars = BB(100) basis
   double upper;        // basis + 2 * stdev(100)
   double lower;        // basis - 2 * stdev(100)
   double sma200;       // SMA(200) "final wall"
   double f50;          // band-to-band Fibonacci levels (prices)
   double f618;
   double f786;
   int    regime;       // +1 bull, -1 bear, 0 none
   string regime_label;
   bool   regime_change; // price beyond SMA200 against the regime
   int    zone;         // +1 buy zone, -1 sell zone, +2 buy overshoot, -2 sell overshoot, 0 mid-range
   string zone_text;
   double entry;        // reference entry for the R:R readout
   double stop;         // failure-forecast stop
   double t1;           // target 1 = opposite band
   double t2;           // target 2 = projected 78.6 extension beyond opposite band
   double rr1;
   double rr2;
   int    confluence;   // 0..4
};

struct PairState
{
   string sym;          // display/input name
   string rsym;         // resolved broker symbol
   string base;
   string quote;
   bool   is_gold;
   bool   is_chart;
   bool   resolved;
   string bias;         // LONG / SHORT / NEUTRAL / "-"
   int    bias_n;       // +1 / 0 / -1
   int    conv;         // 0..100
   double diff;         // strength(base) - strength(quote); gold: n/a (see rank)
   double rank;         // watchlist sort key
   bool   blackout;     // high-impact event for base/quote inside the blackout window
   string next_news;
   string next_when;
   int    mins_news;    // minutes to next pair event, -1 = none this week
   int    grade;        // 0 = none, 1 = A, 2 = B, 3 = C
   Tech   tech;
   // v4.1 per-leg news (chart-pair detail lines)
   string nb_title;     // next high-impact event title, base leg
   string nb_when;      // "Tue 13:30" local, base leg
   int    nb_mins;      // minutes to base-leg event, -1 = none this week
   string nq_title;     // quote leg
   string nq_when;
   int    nq_mins;
   string tilt_b;       // latest surprise tilt, base leg: hawkish/dovish/mixed/none
   string tilt_q;       // quote leg
   // v4.3 index citizens (USTEC / US30): no currency legs - base is
   // "USD" (their macro driver), quote is "". Strength comes from
   // the index legs (g_idx), copied here per pair for rendering.
   bool   is_index;
   int    idx_kind;     // 0 = not an index, 1 = USTEC, 2 = US30
   int    idx_px;       // price score -1..+1 (AgreeScore, as currencies)
   bool   idx_px_ok;
   double idx_fund;     // USD fund + TNX rates overlay, -3..+3
   bool   idx_fund_ok;  // false = "bldg" (mirrors USD fund state)
   double idx_tot;      // px + fund, clamped -4..+4 (also in diff)
};

// v4.3: one leg per index. px reuses the currency AgreeScore
// machinery verbatim, so it sits on the same -1..+1 scale as a
// currency's price_score; fund carries the -3..+3 range exactly as
// a currency's fund does, so tot (px + fund, clamped -4..+4) is
// directly comparable to a currency's total strength.
struct IdxLeg
{
   string key;          // "USTEC" / "US30"
   string yahoo;        // QQQ / DIA
   string yahoo2;       // ^IXIC / ^DJI
   Snap   snap;
   int    px;
   bool   px_ok;
   double fund;
   bool   fund_ok;
   double tot;
};

// v4.1 fundamental-trend series: one (currency, indicator, source)
// triple. Points are kept date-ascending and deduped by date (a later
// add on the same date replaces the value - data revisions win).
// src is "fred" (FRED history, all currencies since v4.8), "cal"
// (MT5 built-in calendar history, since v4.9) or "ff" (accumulated
// calendar prints, persisted in ff_history.csv). Series from
// different sources are NEVER mixed into one point list, because
// their units differ (e.g. FRED CPI is YoY %, a calendar CPI print
// may be m/m %) - scoring picks the deepest series per indicator.
struct FSeries
{
   string   ccy;
   string   key;        // cpi, pce, jobs, unemp, gdp, retail, pmi, rate
   string   src;
   datetime dts[];
   double   vals[];
   int      dir;        // -1/0/+1 direction of the string of prints
   bool     turn;       // latest print broke (or is breaking) a run
   bool     scored;     // true once the series holds >= 2 points
};

Fac    g_fac[];
Ccy    g_ccy[];
IdxLeg g_idx[2];            // v4.3: [0] = USTEC, [1] = US30
string g_risk_sent = "n/a"; // v4.3: RISK-ON / RISK-OFF / MIXED / n/a (display only)
News   g_news[];
PairState g_pairs[];
Snap   g_gold;
string g_bias = "-";
int    g_bias_n = 0;
int    g_conv = 0;
string g_session = "";
string g_asof = "";
string g_regime = "";
bool   g_agree = false;
bool   g_blackout = false;
bool   g_news_risk = false;
string g_next_news = "";
string g_next_when = "";
int    g_mins_news = -1;
string g_play[8];
int    g_nplay = 0;
string g_err = "";
string g_status = "idle";
int    g_last_asia_day = -1;
int    g_last_ny_day = -1;
string g_last_bias_alert = "";
string g_last_pair_alert = "";
bool   g_busy = false;

// gate state for the chart symbol
bool   g_why_ok = false, g_where_ok = false, g_when_ok = false, g_what_ok = false;
string g_why_txt = "", g_where_txt = "", g_when_txt = "", g_what_txt = "";
string g_verdict = "NO TRADE - no data yet";
bool   g_setup_valid = false;
int    g_grade = 0;              // chart pair grade: 0 none, 1 A, 2 B, 3 C
double g_size_lots = 0;
string g_size_txt = "-";
double g_deployed_pct = 0;       // open risk as % of equity (positions with stops)
double g_deployed_money = 0;
int    g_unprotected = 0;        // open positions with NO stop loss set

// v4.1: fundamental trend engine state
FSeries g_fser[];
bool   g_ff_dirty = false;       // ff_history.csv has unsaved points
string g_gold_tilt_txt = "none"; // gold-set surprise tilt as text
// v4.2 fund cross-check (XAUUSD): the gold factor engine reads 1-5
// day price weather; the USD FUND score reads months of data trend.
// When the trend strongly opposes the weather-driven bias, conviction
// is capped and the panel says so under the headline (Jamaal's
// hierarchy: fundamentals decide direction).
string g_fund_check = "neutral"; // opposed / aligned / neutral
string g_fund_check_txt = "";    // panel line under the headline ("" = no line)
bool   g_fund_check_bad = false; // true when opposed (caution color + cap)
bool   g_cycle_fetched = false;  // true while a fetch cycle is running

// v4.1: fetch diagnostics (last fetch cycle, per source). The counters
// reset at the start of every FetchAndScore; g_fetch_diag and
// g_fetch_last_err persist across panel redraws so a failure stays
// visible at the top of the panel until a clean cycle clears it.
int    g_d_yahoo_try = 0;
int    g_d_yahoo_ok = 0;
int    g_d_ff = -1;              // -1 = not tried, 0 = failed, 1 = ok
int    g_d_fred_try = 0;
int    g_d_fred_ok = 0;
// v4.9: MT5 built-in calendar diagnostics. g_d_cal_avail is set when
// the broker's calendar database enumerates ANY event for a ladder
// currency this cycle; try/ok count (currency, indicator) slots -
// attempted = an event was selected and its history pulled, ok = the
// history yielded a usable series (>= 2 dated actual points).
bool   g_d_cal_avail = false;
int    g_d_cal_try = 0;
int    g_d_cal_ok = 0;
string g_fetch_diag = "fetch: not run yet";
string g_fetch_last_err = "";    // e.g. "err 4060 http -1 @nfs.faireconomy.media"
int    g_fetch_health = 0;       // 0 unknown, 1 ok, 2 partial, 3 fail

//+------------------------------------------------------------------+
int OnInit()
{
   BuildFactors();
   BuildCurrencies();
   BuildIndexLegs();       // v4.3: USTEC / US30 index legs
   BuildPairs();
   LoadFFHistory();        // v4.1: accumulated calendar prints from disk
   ComputeFundScores();    // score whatever history already exists
   ScrubAllStrayObjects(); // v4.2: delete ANY default-text object (any prefix)
   ScrubStrayLabels();     // v4.1: repair any default-text label objects
   EventSetTimer(MathMax(10, InpTimerSec));
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, false);
   DrawPanel("starting...");
   if(InpFetchOnAttach)
      FetchAndScore("attach");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, PREF);
   Comment("");
}

void OnTick() {}

void OnTimer()
{
   CheckSchedule();
   RefreshTechnicals();
   SortPairs();
   EvaluateGate();
   DrawPanel(g_status);
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(sparam == PREF "btn")
   {
      ObjectSetInteger(0, PREF "btn", OBJPROP_STATE, false);
      FetchAndScore("manual");
      return;
   }
}

//+------------------------------------------------------------------+
void BuildFactors()
{
   ArrayResize(g_fac, 8);
   InitFac(0, "dxy", "US Dollar", "DX-Y.NYB", "UUP", false, 2.0);
   InitFac(1, "tnx", "US 10Y yield", "^TNX", "", false, 2.0);
   InitFac(2, "irx", "US 13w bill", "^IRX", "", false, 1.0);
   InitFac(3, "usdjpy", "USDJPY", "USDJPY=X", "", false, 1.0);
   InitFac(4, "vix", "VIX", "^VIX", "", true, 0.75);
   InitFac(5, "spy", "SPY", "SPY", "", false, 0.5);
   InitFac(6, "oil", "WTI", "CL=F", "", true, 0.35);
   InitFac(7, "silver", "Silver", "SI=F", "SLV", true, 0.5);
}

void InitFac(int i, string key, string label, string y1, string y2, bool likes_up, double w)
{
   g_fac[i].key = key;
   g_fac[i].label = label;
   g_fac[i].yahoo = y1;
   g_fac[i].yahoo2 = y2;
   g_fac[i].gold_likes_up = likes_up;
   g_fac[i].weight = w;
   g_fac[i].snap.ok = false;
   g_fac[i].score = 0;
   g_fac[i].weighted = 0;
}

//+------------------------------------------------------------------+
// Currency legs. Price score comes from the currency's USD cross on
// Yahoo, scored with the SAME SignMove 1d/5d-agreement method as gold.
void BuildCurrencies()
{
   ArrayResize(g_ccy, 8);
   InitCcy(0, "USD", "DX-Y.NYB", true);   // DXY rising = USD strengthening
   InitCcy(1, "EUR", "EURUSD=X", true);
   InitCcy(2, "GBP", "GBPUSD=X", true);
   InitCcy(3, "JPY", "USDJPY=X", false);  // USDJPY rising = JPY weakening
   InitCcy(4, "CHF", "USDCHF=X", false);
   InitCcy(5, "CAD", "USDCAD=X", false);
   InitCcy(6, "AUD", "AUDUSD=X", true);
   InitCcy(7, "NZD", "NZDUSD=X", true);
}

void InitCcy(int i, string code, string yahoo, bool up)
{
   g_ccy[i].code = code;
   g_ccy[i].yahoo = yahoo;
   g_ccy[i].up_is_ccy_up = up;
   g_ccy[i].snap.ok = false;
   g_ccy[i].price_score = 0;
   g_ccy[i].fund = 0;
   g_ccy[i].fund_ok = false;
   g_ccy[i].fund_turn = false;
   g_ccy[i].fund_stamp = 0;
   g_ccy[i].strength = 0;
}

int CcyIdx(const string code)
{
   for(int i = 0; i < ArraySize(g_ccy); i++)
      if(g_ccy[i].code == code) return i;
   return -1;
}

bool IsGoldSymbol(const string sym)
{
   return (StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0);
}

// v4.3 index detection: 1 = USTEC (Nasdaq-100 family), 2 = US30
// (Dow family), 0 = not an index. Keyword match on the uppercased
// symbol, tolerant of broker prefixes/suffixes ("USTEC.cash",
// "US30Cash", "NAS100_m" all land). Bare "NQ" is matched only as an
// exact symbol or with a separator - a loose substring would be too
// collision-prone; "NQ100" is matched as a keyword. Checked against
// every watchlist name: no FX pair or XAUUSD trips either family
// (e.g. "USDJPY" contains neither "DJI" nor "DOW" as a substring).
int IndexKind(const string sym)
{
   string u = sym;
   StringToUpper(u);
   if(StringFind(u, "USTEC") >= 0 || StringFind(u, "USTECH") >= 0 ||
      StringFind(u, "NAS100") >= 0 || StringFind(u, "NASDAQ") >= 0 ||
      StringFind(u, "US100") >= 0 || StringFind(u, "NQ100") >= 0 ||
      u == "NQ" || StringFind(u, "NQ.") == 0 || StringFind(u, "NQ-") == 0 ||
      StringFind(u, "NQ_") == 0)
      return 1;
   if(StringFind(u, "US30") >= 0 || StringFind(u, "DJ30") >= 0 ||
      StringFind(u, "DJI") >= 0 || StringFind(u, "WS30") >= 0 ||
      StringFind(u, "DOW") >= 0 || u == "DIA")
      return 2;
   return 0;
}

void BuildIndexLegs()
{
   g_idx[0].key = "USTEC";
   g_idx[0].yahoo = "QQQ";
   g_idx[0].yahoo2 = "^IXIC";
   g_idx[1].key = "US30";
   g_idx[1].yahoo = "DIA";
   g_idx[1].yahoo2 = "^DJI";
   for(int k = 0; k < 2; k++)
   {
      g_idx[k].snap.ok = false;
      g_idx[k].px = 0;
      g_idx[k].px_ok = false;
      g_idx[k].fund = 0;
      g_idx[k].fund_ok = false;
      g_idx[k].tot = 0;
   }
}

// Fetch both index ETFs via the standard Yahoo path (so the fetch
// diagnostics count them like every other Yahoo call) and score the
// price leg with the currency AgreeScore machinery verbatim:
// 1d/5d agreement, noise bands, likes_up = true. Runs early in the
// fetch cycle, beside FetchCurrencies.
void FetchIndexLegs()
{
   for(int k = 0; k < 2; k++)
   {
      if(!FetchYahoo(g_idx[k].yahoo, g_idx[k].snap))
         FetchYahoo(g_idx[k].yahoo2, g_idx[k].snap);
      g_idx[k].px_ok = g_idx[k].snap.ok;
      g_idx[k].px = g_idx[k].snap.ok
                    ? AgreeScore(g_idx[k].snap.pct1, g_idx[k].snap.pct5, true)
                    : 0;
   }
}

// Index FUND = the USD currency FUND (an index has no central bank
// of its own; the US data trend IS its macro driver), plus a rates
// overlay off the already-fetched ^TNX gold factor: yields rising
// fast (TNX 5d >= +1.5%) are a headwind, falling fast (<= -1.5%) a
// tailwind, and the Nasdaq leg takes double the Dow's dose
// (growth/tech is more rate-sensitive: -1.0/+1.0 vs -0.5/+0.5).
// Between the bands the overlay is 0. If the USD FUND is still
// building, the index FUND is building too - the overlay alone
// never fabricates a score. tot = px + fund clamped -4..+4, the
// exact currency-strength arithmetic. Also computes the risk
// sentiment gauge from the two px scores (display only - it feeds
// no bias anywhere).
void ComputeIndexLegs()
{
   int ui = CcyIdx("USD");
   int it = FacIdx("tnx");
   double tnx5 = 0;
   bool tnx_ok = (it >= 0 && g_fac[it].snap.ok);
   if(tnx_ok) tnx5 = g_fac[it].snap.pct5;
   for(int k = 0; k < 2; k++)
   {
      double dose = (k == 0) ? 1.0 : 0.5;   // USTEC full dose, US30 half
      double ov = 0;
      if(tnx_ok)
      {
         if(tnx5 >= 1.5) ov = -dose;
         else if(tnx5 <= -1.5) ov = dose;
      }
      g_idx[k].fund_ok = (ui >= 0 && g_ccy[ui].fund_ok);
      g_idx[k].fund = 0;
      if(g_idx[k].fund_ok)
      {
         g_idx[k].fund = g_ccy[ui].fund + ov;
         if(g_idx[k].fund > 3) g_idx[k].fund = 3;
         if(g_idx[k].fund < -3) g_idx[k].fund = -3;
      }
      double t = (double)g_idx[k].px + (g_idx[k].fund_ok ? g_idx[k].fund : 0.0);
      if(t > 4) t = 4;
      if(t < -4) t = -4;
      g_idx[k].tot = t;
   }
   if(!g_idx[0].px_ok || !g_idx[1].px_ok)
      g_risk_sent = "n/a";
   else if(g_idx[0].px >= 1 && g_idx[1].px >= 1)
      g_risk_sent = "RISK-ON";
   else if(g_idx[0].px <= -1 && g_idx[1].px <= -1)
      g_risk_sent = "RISK-OFF";
   else
      g_risk_sent = "MIXED";
}

string ResolveSymbol(const string name)
{
   double tmp;
   if(SymbolInfoDouble(name, SYMBOL_BID, tmp))
   {
      SymbolSelect(name, true);
      return name;
   }
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
   {
      string s = SymbolName(i, false);
      if(StringFind(s, name) == 0)
      {
         SymbolSelect(s, true);
         return s;
      }
   }
   return name;
}

bool SplitPair(const string sym, string &base, string &quote)
{
   base = "";
   quote = "";
   if(IsGoldSymbol(sym))
   {
      base = "XAU";
      quote = "USD";
      return true;
   }
   if(StringLen(sym) < 6) return false;
   base = StringSubstr(sym, 0, 3);
   quote = StringSubstr(sym, 3, 3);
   return (CcyIdx(base) >= 0 && CcyIdx(quote) >= 0);
}

void BuildPairs()
{
   ArrayResize(g_pairs, 0);
   string parts[];
   int k = StringSplit(InpWatchlist, ',', parts);
   bool chart_found = false;
   for(int i = 0; i < k; i++)
   {
      string name = parts[i];
      StringTrimLeft(name);
      StringTrimRight(name);
      if(name == "") continue;
      if(ArraySize(g_pairs) >= 8) break;
      AddPair(name, chart_found);
   }
   if(!chart_found)
   {
      if(ArraySize(g_pairs) < 8)
         AddPair(_Symbol, chart_found);
   }
}

void AddPair(const string name, bool &chart_found)
{
   int n = ArraySize(g_pairs);
   ArrayResize(g_pairs, n + 1);
   g_pairs[n].sym = name;
   g_pairs[n].rsym = ResolveSymbol(name);
   g_pairs[n].resolved = (g_pairs[n].rsym != name) || SymbolSelect(g_pairs[n].rsym, true);
   g_pairs[n].is_gold = IsGoldSymbol(name);
   // v4.3: index detection runs on the watchlist name first, then on
   // the resolved broker symbol (brokers suffix/prefix freely). Gold
   // wins ties - an index is never gold.
   g_pairs[n].idx_kind = IndexKind(name);
   if(g_pairs[n].idx_kind == 0)
      g_pairs[n].idx_kind = IndexKind(g_pairs[n].rsym);
   g_pairs[n].is_index = (g_pairs[n].idx_kind > 0 && !g_pairs[n].is_gold);
   g_pairs[n].idx_px = 0;
   g_pairs[n].idx_px_ok = false;
   g_pairs[n].idx_fund = 0;
   g_pairs[n].idx_fund_ok = false;
   g_pairs[n].idx_tot = 0;
   string b, q;
   if(g_pairs[n].is_index)
   {
      b = "USD";   // an index's macro driver is the US data trend
      q = "";      // no second leg - PairNewsState matches USD only
   }
   else
      SplitPair(name, b, q);
   g_pairs[n].base = b;
   g_pairs[n].quote = q;
   g_pairs[n].is_chart = (g_pairs[n].rsym == _Symbol || name == _Symbol);
   if(g_pairs[n].is_chart) chart_found = true;
   g_pairs[n].bias = "-";
   g_pairs[n].bias_n = 0;
   g_pairs[n].conv = 0;
   g_pairs[n].diff = 0;
   g_pairs[n].rank = 0;
   g_pairs[n].blackout = false;
   g_pairs[n].next_news = "";
   g_pairs[n].next_when = "";
   g_pairs[n].mins_news = -1;
   g_pairs[n].grade = 0;
   g_pairs[n].nb_title = "";
   g_pairs[n].nb_when = "";
   g_pairs[n].nb_mins = -1;
   g_pairs[n].nq_title = "";
   g_pairs[n].nq_when = "";
   g_pairs[n].nq_mins = -1;
   g_pairs[n].tilt_b = "none";
   g_pairs[n].tilt_q = "none";
   g_pairs[n].tech.ok = false;
   g_pairs[n].tech.regime = 0;
   g_pairs[n].tech.zone = 0;
   g_pairs[n].tech.confluence = 0;
   g_pairs[n].tech.zone_text = "no data";
   g_pairs[n].tech.regime_label = "no data";
   g_pairs[n].tech.regime_change = false;
}

int ChartPairIdx()
{
   for(int i = 0; i < ArraySize(g_pairs); i++)
      if(g_pairs[i].is_chart) return i;
   return -1;
}

//+------------------------------------------------------------------+
// Chicago clock (unchanged from v2.00)
bool ChicagoNow(MqlDateTime &chi)
{
   if(InpUsePcLocalAsChicago)
   {
      TimeToStruct(TimeLocal(), chi);
      return true;
   }
   MqlDateTime g;
   TimeGMT(g);
   int off = ChicagoOffsetHours(g.year, g.mon, g.day, g.hour);
   int hour = g.hour + off;
   int day = g.day, mon = g.mon, year = g.year;
   while(hour < 0) { hour += 24; AddDaysYmd(year, mon, day, -1); }
   while(hour >= 24) { hour -= 24; AddDaysYmd(year, mon, day, 1); }
   chi.year = year; chi.mon = mon; chi.day = day;
   chi.hour = hour; chi.min = g.min; chi.sec = g.sec;
   chi.day_of_week = DowYmd(year, mon, day);
   return true;
}

int ChicagoOffsetHours(int y, int m, int d, int gmt_hour)
{
   int start_d = NthWeekday(y, 3, 0, 2);
   int end_d = NthWeekday(y, 11, 0, 1);
   int ymd = y * 10000 + m * 100 + d;
   int start = y * 10000 + 3 * 100 + start_d;
   int endv = y * 10000 + 11 * 100 + end_d;
   if(ymd > start && ymd < endv) return -5;
   if(ymd == start && gmt_hour >= 8) return -5;
   if(ymd == endv && gmt_hour < 7) return -5;
   return -6;
}

int NthWeekday(int y, int m, int weekday, int n)
{
   int first = DowYmd(y, m, 1);
   int day = 1 + ((weekday - first + 7) % 7) + (n - 1) * 7;
   return day;
}

int DowYmd(int y, int m, int d)
{
   int t[] = {0,3,2,5,0,3,5,1,4,6,2,4};
   if(m < 3) y--;
   return (y + y/4 - y/100 + y/400 + t[m-1] + d) % 7;
}

void AddDaysYmd(int &y, int &m, int &d, int delta)
{
   int mdays[] = {0,31,28,31,30,31,30,31,31,30,31,30,31};
   int dim = mdays[m];
   if(m == 2 && ((y%4==0 && y%100!=0) || y%400==0)) dim = 29;
   d += delta;
   if(d < 1)
   {
      m--;
      if(m < 1) { m = 12; y--; }
      dim = mdays[m];
      if(m == 2 && ((y%4==0 && y%100!=0) || y%400==0)) dim = 29;
      d += dim;
   }
   else if(d > dim)
   {
      d -= dim;
      m++;
      if(m > 12) { m = 1; y++; }
   }
}

string SessionNow()
{
   MqlDateTime c;
   ChicagoNow(c);
   return (c.hour >= 15 ? "asia" : "ny");
}

bool WeekendSkip(const string session)
{
   MqlDateTime c;
   ChicagoNow(c);
   if(c.day_of_week == 6) return true;
   if(session == "ny" && c.day_of_week == 0) return true;
   return false;
}

void CheckSchedule()
{
   MqlDateTime c;
   ChicagoNow(c);
   int ymd = c.year * 10000 + c.mon * 100 + c.day;
   if(c.hour == InpNyHour && c.min <= 2 && g_last_ny_day != ymd && !WeekendSkip("ny"))
   {
      g_last_ny_day = ymd;
      FetchAndScore("ny");
      return;
   }
   if(c.hour == InpAsiaHour && c.min <= 2 && g_last_asia_day != ymd && !WeekendSkip("asia"))
   {
      g_last_asia_day = ymd;
      FetchAndScore("asia");
   }
}

//+------------------------------------------------------------------+
// Fetch + score cycle. The gold factor path is the v2.00 original;
// currency legs, fundamentals and pair biases are layered on top.
void FetchAndScore(const string why)
{
   if(g_busy) return;
   g_busy = true;
   g_err = "";
   g_status = "fetching " + why + "...";
   DrawPanel(g_status);

   string session = why;
   if(why == "attach" || why == "manual")
      session = SessionNow();

   // v4.1: reset per-cycle diagnostics (the last-error string itself
   // persists until a fully clean cycle clears it - see BuildFetchDiag)
   g_d_yahoo_try = 0;
   g_d_yahoo_ok = 0;
   g_d_ff = -1;
   g_d_fred_try = 0;
   g_d_fred_ok = 0;
   g_d_cal_avail = false;
   g_d_cal_try = 0;
   g_d_cal_ok = 0;
   g_cycle_fetched = true;

   bool any = false;
   for(int i = 0; i < ArraySize(g_fac); i++)
   {
      if(!FetchYahoo(g_fac[i].yahoo, g_fac[i].snap))
      {
         if(g_fac[i].yahoo2 != "")
            FetchYahoo(g_fac[i].yahoo2, g_fac[i].snap);
      }
      if(g_fac[i].snap.ok) any = true;
      ScoreFac(g_fac[i]);
   }
   if(!FetchYahoo("GC=F", g_gold))
      FetchYahoo("GLD", g_gold);

   FetchCurrencies();
   FetchIndexLegs();                    // v4.3: USTEC/US30 price legs (Yahoo, diag-counted)
   FetchNews();                         // calendar + v4.1 print accumulation
   FetchFred();                         // v4.1: USD fundamental history
   FetchFredIntl();                     // v4.8: non-USD fundamental history (FRED)
   FetchCalendarIntl();                 // v4.9: MT5 built-in calendar history (no WebRequest)
   BuildFetchDiag();

   // v4.1: degrade gracefully. v4.0 stopped dead when Yahoo failed;
   // now any single live source (calendar, FRED) is enough to
   // keep the framework/gate/pair sections honest, and the fetch
   // line at the top of the panel says exactly which source is down.
   bool anyData = any || g_d_ff > 0 || g_d_fred_ok > 0 || g_d_cal_ok > 0;
   if(!anyData)
   {
      g_err = "All fetches failed - see the fetch line (WebRequest allowlist?)";
      g_status = "error";
      g_cycle_fetched = false;
      g_busy = false;
      DrawPanel(g_status);
      return;
   }
   if(!any)
      g_err = "Yahoo down - factor/price scores stale, other sources live";

   ApplyNewsAndBias(session, g_news);   // gold engine (parity with v2.00)
   ComputeFundScores();                 // v4.1: fundamental trend per currency
   ApplyFundCrossCheck();               // v4.2: USD fund trend vs gold bias (cap + line)
   if(g_ff_dirty) { SaveFFHistory(); g_ff_dirty = false; }
   ComputeStrengths();                  // currency legs: price + fund totals
   ComputeIndexLegs();                  // v4.3: index fund (USD fund + TNX overlay), tot, sentiment
   g_cycle_fetched = false;
   ComputeAllPairs();                   // pair biases + per-pair news state
   RefreshTechnicals();                // D1 framework layer for every pair
   SortPairs();                         // watchlist ranking
   EvaluateGate();                      // Why/Where/When/What for the chart pair
   Publish();
   int ci = ChartPairIdx();
   if(ci >= 0 && g_pairs[ci].is_gold)
      WriteIni();                       // legacy gold_bias.ini (gold charts only)
   WriteGeneralIni();
   g_status = "ok " + why;
   g_asof = ChicagoStamp();
   if(InpAlertOnUpdate && ci >= 0)
   {
      if(g_pairs[ci].is_gold)
      {
         if(g_last_bias_alert != g_bias)
         {
            Alert("Gold bias ", g_bias, " conv ", g_conv, "  ", g_next_news);
            g_last_bias_alert = g_bias;
         }
      }
      else
      {
         string cur = g_pairs[ci].bias + IntegerToString(g_pairs[ci].conv);
         if(g_last_pair_alert != cur)
         {
            Alert("GeneralMacro ", g_pairs[ci].sym, " bias ", g_pairs[ci].bias,
                  " conv ", g_pairs[ci].conv, "  ", g_pairs[ci].next_news);
            g_last_pair_alert = cur;
         }
      }
   }
   g_busy = false;
   DrawPanel(g_status);
}

string ChicagoStamp()
{
   MqlDateTime c;
   ChicagoNow(c);
   return StringFormat("Chicago %04d-%02d-%02d %02d:%02d", c.year, c.mon, c.day, c.hour, c.min);
}

//+------------------------------------------------------------------+
string UrlEnc(string s)
{
   string o = s;
   StringReplace(o, "^", "%5E");
   StringReplace(o, "=", "%3D");
   return o;
}

string HostOf(const string url)
{
   string u = url;
   int p = StringFind(u, "://");
   if(p >= 0) u = StringSubstr(u, p + 3);
   int s = StringFind(u, "/");
   if(s >= 0) u = StringSubstr(u, 0, s);
   return u;
}

bool HttpGet(const string url, string &body)
{
   body = "";
   char data[], result[];
   string headers = "User-Agent: Mozilla/5.0 (gold-bias-ea)\r\nAccept: application/json\r\n";
   string rh;
   ResetLastError();
   int code = WebRequest("GET", url, headers, 15000, data, result, rh);
   if(code != 200)
   {
      int err = GetLastError();
      Print("WebRequest ", url, " code=", code, " err=", err);
      // v4.1: remember the failure for the panel diagnostics line.
      // err 4060 = URL not on the WebRequest allowlist - the classic
      // cause of a totally blank dashboard on a fresh terminal.
      g_fetch_last_err = StringFormat("err %d http %d @%s", err, code, HostOf(url));
      return false;
   }
   body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return (StringLen(body) > 10);
}

bool FetchYahoo(const string symbol, Snap &s)
{
   s.ok = false;
   s.symbol = symbol;
   string url = "https://query1.finance.yahoo.com/v8/finance/chart/" + UrlEnc(symbol) + "?range=2mo&interval=1d";
   string body;
   g_d_yahoo_try++;
   if(!HttpGet(url, body)) return false;
   double closes[];
   if(!ParseCloses(body, closes)) return false;
   int n = ArraySize(closes);
   if(n < 3) return false;
   s.last = closes[n - 1];
   s.pct1 = Pct(closes, 1);
   s.pct5 = Pct(closes, 5);
   s.ok = true;
   g_d_yahoo_ok++;
   return true;
}

double Pct(const double &closes[], int bars)
{
   int n = ArraySize(closes);
   if(n <= bars || closes[n - 1 - bars] == 0) return 0;
   return (closes[n - 1] / closes[n - 1 - bars] - 1.0) * 100.0;
}

bool ParseCloses(const string json, double &closes[])
{
   int p = StringFind(json, "\"close\":[");
   if(p < 0) return false;
   p = StringFind(json, "[", p);
   int e = StringFind(json, "]", p);
   if(e < 0) return false;
   string arr = StringSubstr(json, p + 1, e - p - 1);
   ArrayResize(closes, 0);
   string parts[];
   int k = StringSplit(arr, ',', parts);
   for(int i = 0; i < k; i++)
   {
      string t = parts[i];
      StringTrimLeft(t);
      StringTrimRight(t);
      if(t == "null" || t == "") continue;
      ArrayResize(closes, ArraySize(closes) + 1);
      closes[ArraySize(closes) - 1] = StringToDouble(t);
   }
   return ArraySize(closes) >= 3;
}

int SignMove(double pct, bool likes_up, double noise)
{
   if(MathAbs(pct) < noise) return 0;
   bool up = pct > 0;
   bool friendly = likes_up ? up : !up;
   return friendly ? 1 : -1;
}

// The 1d/5d agreement combiner, shared by gold factors (ScoreFac, kept
// verbatim below) and the currency price scores: both horizons must
// agree, otherwise the score is 0 (the anti-whipsaw rule).
int AgreeScore(double pct1, double pct5, bool likes_up)
{
   int s1 = SignMove(pct1, likes_up, NOISE);
   int s5 = SignMove(pct5, likes_up, NOISE * 1.4);
   if(s1 == 0 && s5 == 0) return 0;
   if(s1 == 0) return s5;
   if(s5 == 0 || s1 == s5) return s1;
   return 0;
}

void ScoreFac(Fac &f)
{
   f.score = 0;
   f.weighted = 0;
   if(!f.snap.ok) return;
   int s1 = SignMove(f.snap.pct1, f.gold_likes_up, NOISE);
   int s5 = SignMove(f.snap.pct5, f.gold_likes_up, NOISE * 1.4);
   if(s1 == 0 && s5 == 0) f.score = 0;
   else if(s1 == 0) f.score = s5;
   else if(s5 == 0 || s1 == s5) f.score = s1;
   else f.score = 0;
   f.weighted = f.score * f.weight;
}

int FacIdx(const string key)
{
   for(int i = 0; i < ArraySize(g_fac); i++)
      if(g_fac[i].key == key) return i;
   return -1;
}

string Regime()
{
   int id = FacIdx("dxy");
   int iv = FacIdx("vix");
   if(id < 0 || iv < 0 || !g_fac[id].snap.ok || !g_fac[iv].snap.ok) return "unknown";
   double d = g_fac[id].snap.pct1;
   double v = g_fac[iv].snap.pct1;
   bool dxy_up = d > NOISE, dxy_dn = d < -NOISE, vix_up = v > NOISE * 4;
   if(vix_up && dxy_up) return "dollar squeeze (often gold-negative)";
   if(vix_up && dxy_dn) return "classic risk-off (gold-friendly)";
   if(!vix_up && dxy_dn) return "soft dollar, calm vol";
   if(dxy_up && !vix_up) return "firm dollar, calm vol (headwind)";
   return "mixed / quiet";
}

//+------------------------------------------------------------------+
// Currency legs: fetch each currency's USD cross. USD reuses the DXY
// factor snapshot and JPY reuses the USDJPY factor snapshot when they
// are already fresh, so a cycle costs only 6 extra Yahoo calls.
void FetchCurrencies()
{
   int idxy = FacIdx("dxy");
   int ijpy = FacIdx("usdjpy");
   for(int i = 0; i < ArraySize(g_ccy); i++)
   {
      if(g_ccy[i].code == "USD" && idxy >= 0 && g_fac[idxy].snap.ok)
      {
         g_ccy[i].snap = g_fac[idxy].snap;
         continue;
      }
      if(g_ccy[i].code == "JPY" && ijpy >= 0 && g_fac[ijpy].snap.ok)
      {
         g_ccy[i].snap = g_fac[ijpy].snap;
         continue;
      }
      FetchYahoo(g_ccy[i].yahoo, g_ccy[i].snap);
   }
}

// v4.1 total strength = price score (-1..+1) + fundamental trend
// (-3..+3, only when the currency has scored data), clamped to
// -4..+4. 100% data-driven: the v4.0 manual ladder (+/- buttons)
// was removed in v4.1 at Mazi's direction - no manual component
// exists anywhere. A currency whose FUND is still building
// contributes 0 from fundamentals and shows "bldg" on its ladder
// row - never a fabricated neutral zero.
void ComputeStrengths()
{
   for(int i = 0; i < ArraySize(g_ccy); i++)
   {
      g_ccy[i].price_score = 0;
      if(g_ccy[i].snap.ok)
         g_ccy[i].price_score = AgreeScore(g_ccy[i].snap.pct1, g_ccy[i].snap.pct5,
                                           g_ccy[i].up_is_ccy_up);
      double s = (double)g_ccy[i].price_score +
                 (g_ccy[i].fund_ok ? g_ccy[i].fund : 0.0);
      if(s > 4) s = 4;
      if(s < -4) s = -4;
      g_ccy[i].strength = s;
   }
}

//+------------------------------------------------------------------+
// v4.1 FETCH DIAGNOSTICS. One line, built at the end of every fetch
// cycle from the per-source counters, drawn high on the panel so a
// dead feed (usually a missing WebRequest allowlist entry, err 4060)
// is diagnosable from the chart alone - no Experts log needed.
void BuildFetchDiag()
{
   string ys = (g_d_yahoo_try == 0) ? "-" :
               (IntegerToString(g_d_yahoo_ok) + "/" + IntegerToString(g_d_yahoo_try));
   string fs = (g_d_ff < 0) ? "-" : (g_d_ff > 0 ? "OK" : "FAIL");
   string fr = (g_d_fred_try == 0) ? "-" :
               (IntegerToString(g_d_fred_ok) + "/" + IntegerToString(g_d_fred_try));
   bool hardFail = (g_d_yahoo_try > 0 && g_d_yahoo_ok == 0) || g_d_ff == 0 ||
                   (g_d_fred_try > 0 && g_d_fred_ok == 0);
   bool partial = (g_d_yahoo_ok < g_d_yahoo_try) ||
                  (g_d_fred_ok < g_d_fred_try);
   g_fetch_health = hardFail ? 3 : (partial ? 2 : 1);
   if(g_fetch_health == 1) g_fetch_last_err = "";  // a clean cycle clears the stain
   // v4.9: the calendar slot reads n/m (usable series / slots
   // attempted), or "n/a" when the broker feeds no calendar at all.
   // Cal state deliberately does NOT feed hardFail/partial above: a
   // broker that serves no calendar database is a legitimate state,
   // not a fetch failure, and every other source is unaffected.
   string cs = (!g_d_cal_avail) ? "n/a" :
               (IntegerToString(g_d_cal_ok) + "/" + IntegerToString(g_d_cal_try));
   string srcs = "yahoo " + ys + " | ff " + fs + " | fred " + fr + " | cal " + cs;
   if(g_fetch_last_err != "")
      g_fetch_diag = "fetch: " + g_fetch_last_err + " | " + srcs;  // error first: panel width truncates the tail, never the host
   else
      g_fetch_diag = "fetch: " + srcs;
}

// v4.2 UNIVERSAL STRAY SWEEP (Problem 2, second round). Two objects
// still rendered the literal text "Label" on Mazi's charts under
// v4.1, at the two unused watchlist slots (rows 7-8 of 8; only 6
// pairs are configured, so those slots' resting text is blank).
// Forensics: they are orphans the v4.1 scrub could not reach - it
// only BLANKED objects carrying this build's own GM_ prefix and
// only label/text types, so anything left behind by the earlier
// v4.0 build under a name/type outside that scope survived every
// draw. The v4.2 sweep is namespace-blind: ANY chart object of type
// label, text or button whose text is exactly "Label" or "Text"
// (MQL5's birth strings) is DELETED, whatever prefix it carries.
// No panel string of this EA ever equals those two words, and the
// Refresh button reads "Refresh now", so the sweep cannot eat a
// live panel object - DrawPanel recreates anything it owns anyway.
// Runs at OnInit and at the start of every DrawPanel.
void ScrubAllStrayObjects()
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, -1);
      long otype = ObjectGetInteger(0, name, OBJPROP_TYPE);
      if(otype != OBJ_LABEL && otype != OBJ_TEXT && otype != OBJ_BUTTON)
         continue;
      string txt = ObjectGetString(0, name, OBJPROP_TEXT);
      if(txt == "Label" || txt == "Text")
         ObjectDelete(0, name);
   }
}

// v4.1 STRAY-LABEL SCRUB (Problem 2). MQL5 gives a freshly created
// OBJ_LABEL the literal text "Label" (OBJ_TEXT: "Text"). Every panel
// object is supposed to get its text in the same call sequence that
// creates it; if any create/set sequence is ever interrupted, the
// object survives with the default string and v4.0 never repaired it.
// The scrub runs before every draw: any GM_-prefixed label/text
// object still showing a default string is blanked and parked at the
// panel origin (the draw that follows re-sets every owned label).
void ScrubStrayLabels()
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, PREF) != 0) continue;
      // v4.0's manual-ladder buttons are gone in v4.1 (Mazi: strength
      // is data-driven now) - delete any orphans a crashed v4.0 left
      if(StringFind(name, PREF "lp") == 0 || StringFind(name, PREF "lm") == 0)
      {
         ObjectDelete(0, name);
         continue;
      }
      long otype = ObjectGetInteger(0, name, OBJPROP_TYPE);
      if(otype != OBJ_LABEL && otype != OBJ_TEXT) continue;
      string txt = ObjectGetString(0, name, OBJPROP_TEXT);
      if(txt == "Label" || txt == "Text")
      {
         ObjectSetString(0, name, OBJPROP_TEXT, "");
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpX + 14);
         ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpY);
      }
   }
}

//+------------------------------------------------------------------+
// v4.1 small helpers
string YmdStr(datetime t)
{
   MqlDateTime s;
   TimeToStruct(t, s);
   return StringFormat("%04d-%02d-%02d", s.year, s.mon, s.day);
}

datetime ParseDateOnly(string s)
{
   StringReplace(s, ".", "-");
   string parts[];
   int k = StringSplit(s, '-', parts);
   if(k < 3) return 0;
   int y = (int)StringToInteger(parts[0]);
   int mo = (int)StringToInteger(parts[1]);
   int d = (int)StringToInteger(parts[2]);
   if(y < 1970 || mo < 1 || mo > 12 || d < 1 || d > 31) return 0;
   return (datetime)(DaysSince1970(y, mo, d) * 86400);
}

string FmtCountdown(int mins)
{
   if(mins < 0) return "";
   int d = mins / 1440;
   int h = (mins % 1440) / 60;
   int m = mins % 60;
   if(d > 0) return StringFormat("%dd %dh", d, h);
   if(h > 0) return StringFormat("%dh %02dm", h, m);
   return StringFormat("%dm", m);
}

string DowShort(int dow)
{
   string names[7] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
   if(dow < 0 || dow > 6) return "";
   return names[dow];
}

string Trunc(const string s, int n)
{
   if(StringLen(s) <= n) return s;
   return StringSubstr(s, 0, n);
}

bool IsMedium(string impact)
{
   string low = impact;
   StringToLower(low);
   return (low == "medium" || low == "2" || low == "orange");
}

// Normalize a calendar event title to an indicator key. Keyword
// order matters: "unemployment"/"jobless"/"claims" are tested before
// "employment" (payrolls), and "unemployment" never matches a plain
// "Employment Change" title (it lacks the "un" prefix).
string IndicatorKey(string title)
{
   string t = title;
   StringToLower(t);
   if(StringFind(t, "unemployment") >= 0) return "unemp";
   if(StringFind(t, "jobless") >= 0) return "unemp";
   if(StringFind(t, "claims") >= 0) return "unemp";
   if(StringFind(t, "non-farm") >= 0 || StringFind(t, "nonfarm") >= 0 ||
      StringFind(t, "payroll") >= 0) return "jobs";
   if(StringFind(t, "employment") >= 0) return "jobs";
   if(StringFind(t, "pce") >= 0) return "pce";
   if(StringFind(t, "cpi") >= 0 || StringFind(t, "consumer price") >= 0 ||
      StringFind(t, "inflation") >= 0) return "cpi";
   if(StringFind(t, "gdp") >= 0 || StringFind(t, "gross domestic") >= 0) return "gdp";
   if(StringFind(t, "retail") >= 0) return "retail";
   if(StringFind(t, "pmi") >= 0 || StringFind(t, "purchasing managers") >= 0) return "pmi";
   if(StringFind(t, "interest rate") >= 0 || StringFind(t, "rate decision") >= 0 ||
      StringFind(t, "cash rate") >= 0 || StringFind(t, "overnight rate") >= 0 ||
      StringFind(t, "federal funds") >= 0 || StringFind(t, "bank rate") >= 0 ||
      StringFind(t, "policy rate") >= 0 || StringFind(t, "refinancing rate") >= 0)
      return "rate";
   return "";
}

// Parse a calendar actual/forecast/previous string ("3.1%", "215K",
// "-0.2%", "1.2M", "4.25%") into a plain number. K/M/B suffixes are
// expanded so a string of prints stays unit-consistent per series.
bool ParseActualNum(string s, double &v)
{
   v = 0;
   StringTrimLeft(s);
   StringTrimRight(s);
   if(s == "" || s == "n/a") return false;
   double mult = 1;
   string last = StringSubstr(s, StringLen(s) - 1);
   if(last == "K" || last == "k") { mult = 1000.0; s = StringSubstr(s, 0, StringLen(s) - 1); }
   else if(last == "M") { mult = 1000000.0; s = StringSubstr(s, 0, StringLen(s) - 1); }
   else if(last == "B") { mult = 1000000000.0; s = StringSubstr(s, 0, StringLen(s) - 1); }
   StringReplace(s, "%", "");
   StringReplace(s, ",", "");
   StringTrimLeft(s);
   StringTrimRight(s);
   if(s == "" || s == "-" || s == "+") return false;
   v = StringToDouble(s) * mult;
   if(v == 0 && StringFind(s, "0") < 0) return false;  // silent non-numeric parse
   return true;
}

//+------------------------------------------------------------------+
// v4.1 FUNDAMENTAL TREND ENGINE (Jamaal, TTFX Ch. 9): do not trade
// the data print - trade the DIRECTION a string of prints confirms.
// One print is a data point; a string of prints is a trend; and
// watch for THE TURN - a series reversing after a run of prints.
int FSerIdx(const string ccy, const string key, const string src, bool create)
{
   for(int i = 0; i < ArraySize(g_fser); i++)
      if(g_fser[i].ccy == ccy && g_fser[i].key == key && g_fser[i].src == src)
         return i;
   if(!create) return -1;
   int n = ArraySize(g_fser);
   ArrayResize(g_fser, n + 1);
   g_fser[n].ccy = ccy;
   g_fser[n].key = key;
   g_fser[n].src = src;
   g_fser[n].dir = 0;
   g_fser[n].turn = false;
   g_fser[n].scored = false;
   ArrayResize(g_fser[n].dts, 0);
   ArrayResize(g_fser[n].vals, 0);
   return n;
}

// Insert a point keeping dates ascending; same date replaces the
// value (revised prints win). Returns true if anything changed.
bool FSerAdd(int idx, datetime d, double v)
{
   if(idx < 0 || d <= 0) return false;
   int n = ArraySize(g_fser[idx].dts);
   int pos = n;
   for(int i = 0; i < n; i++)
   {
      if(g_fser[idx].dts[i] == d)
      {
         if(g_fser[idx].vals[i] == v) return false;
         g_fser[idx].vals[i] = v;
         return true;
      }
      if(g_fser[idx].dts[i] > d) { pos = i; break; }
   }
   ArrayResize(g_fser[idx].dts, n + 1);
   ArrayResize(g_fser[idx].vals, n + 1);
   for(int i = n; i > pos; i--)
   {
      g_fser[idx].dts[i] = g_fser[idx].dts[i - 1];
      g_fser[idx].vals[i] = g_fser[idx].vals[i - 1];
   }
   g_fser[idx].dts[pos] = d;
   g_fser[idx].vals[pos] = v;
   return true;
}

// Score one series into dir/turn. Flat prints (zero change) neither
// extend nor break a run, so the sign sequence drops them.
//   - trailing run of >= 2 same signs incl. the latest: dir = that
//     sign. If the run is young (<= 2) and replaced an opposite run
//     of >= 2, TURN is flagged: two consecutive prints against the
//     old run = a new direction forming (the book's rule).
//   - latest print against a run of >= 3: TURN flagged, dir KEEPS
//     the run's sign - once is noise.
//   - latest print against a run of 2, or no run at all: dir = 0.
// Policy-rate series are scored on level changes instead: the most
// recent change is the stance (hike +, cut -); a hold changes
// nothing; a change against the previous change is a TURN.
void FSerScoreSeries(int idx)
{
   int n = ArraySize(g_fser[idx].vals);
   g_fser[idx].dir = 0;
   g_fser[idx].turn = false;
   g_fser[idx].scored = (n >= 2);
   if(n < 2) return;

   if(g_fser[idx].key == "rate")
   {
      int lastSign = 0, prevSign = 0, lastIdx = -1;
      for(int i = n - 1; i >= 1; i--)
      {
         double d = g_fser[idx].vals[i] - g_fser[idx].vals[i - 1];
         if(MathAbs(d) <= 1e-9) continue;
         int s = (d > 0) ? 1 : -1;
         if(lastSign == 0) { lastSign = s; lastIdx = i; }
         else { prevSign = s; break; }
      }
      g_fser[idx].dir = lastSign;
      g_fser[idx].turn = (prevSign != 0 && lastSign != 0 && prevSign != lastSign &&
                          lastIdx >= n - 4);
      return;
   }

   int sg[];
   for(int i = 1; i < n; i++)
   {
      double d = g_fser[idx].vals[i] - g_fser[idx].vals[i - 1];
      if(MathAbs(d) <= 1e-9) continue;
      int m = ArraySize(sg);
      ArrayResize(sg, m + 1);
      sg[m] = (d > 0) ? 1 : -1;
   }
   int m = ArraySize(sg);
   if(m == 0) return;                    // perfectly flat string: no direction
   if(m == 1) { g_fser[idx].dir = sg[0]; return; }
   int last = sg[m - 1], prev = sg[m - 2];
   if(last == prev)
   {
      int run = 0;
      for(int i = m - 1; i >= 0 && sg[i] == last; i--) run++;
      g_fser[idx].dir = last;
      g_fser[idx].turn = (run <= 2 && (m - run) >= 2);
   }
   else
   {
      int runPrev = 0;
      for(int i = m - 2; i >= 0 && sg[i] == prev; i--) runPrev++;
      if(runPrev >= 3)
      {
         g_fser[idx].dir = prev;         // once is noise: keep the score
         g_fser[idx].turn = true;
      }
      else
         g_fser[idx].turn = (runPrev >= 2);
   }
}

// Indicator -> currency-strength sign and weight. Rising inflation
// pressures the bank hawkish (+); rising unemployment weakens (-);
// a hike is +, a cut is -. Inflation and jobs carry the most weight
// (the book: rates, CPI and jobs are the firepower).
int FundKeySign(const string key)
{
   if(key == "unemp") return -1;
   return 1;   // cpi, pce, jobs, gdp, retail, pmi, rate
}

double FundKeyWeight(const string key)
{
   if(key == "cpi") return 2.0;
   if(key == "jobs") return 2.0;
   if(key == "rate") return 2.0;
   if(key == "unemp") return 1.5;
   if(key == "pce") return 1.0;
   if(key == "gdp") return 1.0;
   if(key == "retail") return 0.75;
   if(key == "pmi") return 0.75;
   return 0.5;
}

// Pick the deepest scored series for one (currency, indicator);
// source priority on ties: fred > cal > ff (a real history source
// beats the accumulated prints; depth always beats priority, so a
// cal string overtakes a shallower - e.g. frozen - FRED series on
// points alone, and never double-counts a release).
bool BestFundDir(const string ccy, const string key, int &dir, bool &turn)
{
   dir = 0;
   turn = false;
   int best = -1, bestPts = -1, bestPri = -1;
   for(int i = 0; i < ArraySize(g_fser); i++)
   {
      if(g_fser[i].ccy != ccy || g_fser[i].key != key || !g_fser[i].scored) continue;
      int pts = ArraySize(g_fser[i].vals);
      int pri = (g_fser[i].src == "fred") ? 3 : (g_fser[i].src == "cal") ? 2 : 1;
      if(pts > bestPts || (pts == bestPts && pri > bestPri))
      {
         best = i;
         bestPts = pts;
         bestPri = pri;
      }
   }
   if(best < 0) return false;
   dir = g_fser[best].dir;
   turn = g_fser[best].turn;
   return true;
}

// Did this currency's fund source answer during the current cycle?
// v4.8: every ladder currency has a FRED map now (EUR migrated off
// the ECB SDW feed), so liveness is uniform: FRED answered at all,
// or the calendar parse produced prints. v4.9: a usable built-in
// calendar series counts as live too, so a terminal whose only
// working fund source is the broker calendar still stamps fresh.
bool CcySourceLive(const string code)
{
   return (g_d_fred_ok > 0 || g_d_ff > 0 || g_d_cal_ok > 0);
}

// FUND per currency = 3 x weighted mean of indicator directions
// (mapped through the sign table), so it lands in -3..+3. Fewer
// than 2 scored indicators = "bldg" (building): fund_ok stays false
// and the score is never displayed as a number.
void ComputeFundScores()
{
   string keys[8] = {"cpi", "pce", "jobs", "unemp", "gdp", "retail", "pmi", "rate"};
   for(int s = 0; s < ArraySize(g_fser); s++)
      FSerScoreSeries(s);
   for(int i = 0; i < ArraySize(g_ccy); i++)
   {
      double wsum = 0, acc = 0;
      int cnt = 0;
      bool anyTurn = false;
      for(int k = 0; k < 8; k++)
      {
         int d = 0;
         bool tn = false;
         if(!BestFundDir(g_ccy[i].code, keys[k], d, tn)) continue;
         cnt++;
         double w = FundKeyWeight(keys[k]);
         acc += w * (double)(FundKeySign(keys[k]) * d);
         wsum += w;
         if(tn) anyTurn = true;
      }
      g_ccy[i].fund_turn = anyTurn;
      if(cnt >= 2 && wsum > 0)
      {
         g_ccy[i].fund_ok = true;
         g_ccy[i].fund = 3.0 * acc / wsum;
         if(g_cycle_fetched && CcySourceLive(g_ccy[i].code))
            g_ccy[i].fund_stamp = TimeGMT();
      }
      else
      {
         g_ccy[i].fund_ok = false;
         g_ccy[i].fund = 0;
      }
   }
}

// v4.2 FUND CROSS-CHECK (XAUUSD). The gold factor engine reads 1-5
// day price weather (a risk-off day can flash LONG while the dollar
// is fundamentally strong); the USD FUND score reads months of data
// trend. Jamaal's hierarchy says fundamentals decide direction, so a
// strong opposing data trend may not be overridden by factor weather
// without a warning: when USD FUND is at least +/-1.5 AGAINST the
// gold bias, conviction is capped at 40 (mirroring the existing
// dollar/yields disagreement cap) and the panel prints a CAUTION
// line under the headline. A strong ALIGNED trend prints a muted
// confirmation line and changes nothing. In between: silent.
// Runs after ComputeFundScores and before ComputeAllPairs, so the
// capped g_conv flows into the pair state, Publish, both INIs and
// the alert text consistently.
void ApplyFundCrossCheck()
{
   g_fund_check = "neutral";
   g_fund_check_txt = "";
   g_fund_check_bad = false;
   if(g_bias_n == 0) return;                    // no bias to oppose
   int ui = CcyIdx("USD");
   if(ui < 0 || !g_ccy[ui].fund_ok) return;     // no fund read, no opinion
   double uf = g_ccy[ui].fund;
   string ufs = StringFormat("%+0.1f", uf);
   if(g_bias_n > 0)                             // gold LONG
   {
      if(uf >= 1.5)
      {
         g_fund_check = "opposed";
         g_fund_check_bad = true;
         if(g_conv > 40) g_conv = 40;
         g_fund_check_txt = "CAUTION: strong USD data trend (" + ufs +
                            ") - gold longs against it";
      }
      else if(uf <= -1.5)
      {
         g_fund_check = "aligned";
         g_fund_check_txt = "USD data trend aligned (" + ufs + ")";
      }
   }
   else                                         // gold SHORT
   {
      if(uf <= -1.5)
      {
         g_fund_check = "opposed";
         g_fund_check_bad = true;
         if(g_conv > 40) g_conv = 40;
         g_fund_check_txt = "CAUTION: weak USD data trend (" + ufs +
                            ") - gold shorts against it";
      }
      else if(uf >= 1.5)
      {
         g_fund_check = "aligned";
         g_fund_check_txt = "USD data trend aligned (" + ufs + ")";
      }
   }
}

// A FUND score counts as fresh for the WHY gate when it was scored
// from data fetched within the last 24h.
bool FundFreshCcy(const string code)
{
   int i = CcyIdx(code);
   if(i < 0) return false;
   return (g_ccy[i].fund_ok && g_ccy[i].fund_stamp > 0 &&
           (TimeGMT() - g_ccy[i].fund_stamp) <= 86400);
}

string FundStr(const string code)
{
   if(code == "XAU") return "engine";
   int i = CcyIdx(code);
   if(i < 0) return "n/a";
   if(!g_ccy[i].fund_ok) return "bldg";
   return StringFormat("%+0.1f", g_ccy[i].fund) + (g_ccy[i].fund_turn ? "!" : "");
}

//+------------------------------------------------------------------+
// FRED (USD depth): key-less graph CSV endpoint. Series are pulled
// as LEVELS and transformed here: CPI/PCE -> YoY %, PAYEMS ->
// monthly change, GDP -> quarterly % change, UNRATE/RSXFS/FEDFUNDS
// -> levels. ~1100 days of history covers the YoY lookback.
bool FetchFredCsv(const string id, datetime &dts[], double &vals[])
{
   ArrayResize(dts, 0);
   ArrayResize(vals, 0);
   MqlDateTime pt;
   TimeToStruct(TimeGMT() - 1100 * 86400, pt);
   string url = "https://fred.stlouisfed.org/graph/fredgraph.csv?id=" + id +
                StringFormat("&cosd=%04d-%02d-%02d", pt.year, pt.mon, pt.day);
   string body;
   if(!HttpGet(url, body)) return false;
   string lines[];
   int nl = StringSplit(body, '\n', lines);
   for(int i = 0; i < nl; i++)
   {
      string ln = lines[i];
      StringTrimLeft(ln);
      StringTrimRight(ln);
      string parts[];
      if(StringSplit(ln, ',', parts) < 2) continue;
      string d0 = parts[0];
      StringTrimLeft(d0);
      StringTrimRight(d0);
      if(StringLen(d0) != 10 || StringGetCharacter(d0, 4) != '-') continue;  // header/junk
      string v0 = parts[1];
      StringTrimLeft(v0);
      StringTrimRight(v0);
      if(v0 == "" || v0 == ".") continue;   // FRED missing-value marker
      datetime d = ParseDateOnly(d0);
      if(d <= 0) continue;
      int n = ArraySize(vals);
      ArrayResize(dts, n + 1);
      ArrayResize(vals, n + 1);
      dts[n] = d;
      vals[n] = StringToDouble(v0);
   }
   return (ArraySize(vals) >= 2);
}

void FetchFred()
{
   string ids[7]  = {"CPIAUCSL", "PCEPILFE", "UNRATE", "PAYEMS", "RSXFS", "GDP", "FEDFUNDS"};
   string keys[7] = {"cpi", "pce", "unemp", "jobs", "retail", "gdp", "rate"};
   for(int s = 0; s < 7; s++)
   {
      g_d_fred_try++;
      datetime dts[];
      double lv[];
      if(!FetchFredCsv(ids[s], dts, lv)) continue;
      int n = ArraySize(lv);
      string key = keys[s];
      int si = FSerIdx("USD", key, "fred", true);
      bool usable = false;
      if(key == "cpi" || key == "pce")
      {
         if(n < 14) continue;
         for(int i = 12; i < n; i++)
         {
            if(lv[i - 12] == 0) continue;
            FSerAdd(si, dts[i], (lv[i] / lv[i - 12] - 1.0) * 100.0);
            usable = true;
         }
      }
      else if(key == "jobs")
      {
         if(n < 3) continue;
         for(int i = 1; i < n; i++) { FSerAdd(si, dts[i], lv[i] - lv[i - 1]); usable = true; }
      }
      else if(key == "gdp")
      {
         if(n < 3) continue;
         for(int i = 1; i < n; i++)
         {
            if(lv[i - 1] == 0) continue;
            FSerAdd(si, dts[i], (lv[i] / lv[i - 1] - 1.0) * 100.0);
            usable = true;
         }
      }
      else
      {
         for(int i = 0; i < n; i++) { FSerAdd(si, dts[i], lv[i]); usable = true; }
      }
      if(usable) g_d_fred_ok++;
   }
}

//+------------------------------------------------------------------+
// v4.8: FRED history for the NON-USD currencies. Through v4.7 only
// USD had a real history source (EUR had the ECB SDW feed, which
// never answered on Mazi's terminal - "ecb 0/2" every cycle); every
// other currency's FUND could only be built from accumulated
// calendar prints, i.e. weeks of "bldg". FRED carries OECD /
// Eurostat / central-bank series for the whole ladder, so each
// non-USD currency now gets the same treatment as USD: one FRED
// series per indicator, pulled as levels through FetchFredCsv and
// transformed here with the SAME math FetchFred uses. Transform
// kinds: 0 = level as-is (unemployment %, rate %, and the NAEXKP01
// GDP series, whose values are already q/q %); 1 = YoY % from a
// monthly index (lag 12, the USD CPI branch); 2 = q/q % from a
// quarterly level (the USD GDP branch). Every series ID below was
// verified live against fredgraph.csv before being wired in:
// >= 8 usable observations inside the same 1100-day window
// FetchFredCsv requests (per-series counts and last-observation
// dates: BUILD-NOTES-v4.md section 19). Slots with no verified
// FRED series (JPY/AUD/NZD cpi, EUR/CHF unemp, intl retail, jobs,
// pmi) stay on the ff-accumulation path - BestFundDir picks ONE
// series per (currency, indicator), deepest first, so a FRED slot
// and an accumulated slot never double-count the same release.
// The ECB SDW fetch is gone entirely (EUR migrated to FRED: HICP
// index, the ECBMRRFR policy rate, EA19 GDP) - one host less on
// the allowlist, one failure mode less on the fetch line.
// Cadence honesty: OECD/FRED foreign series lag their reference
// period by ~1-2 months (GDP by a quarter or more) - accepted by
// design for a months-long trend string. The GBP/CHF/CAD CPI
// index series are additionally frozen at their source (last
// prints Mar-Apr 2025): their strings are real history, honestly
// stale, and accumulated prints take the slot over once deeper.
// "rate" rows other than EUR's are 3-month interbank rates
// (IR3TIB01) - the same stance-proxy trick FEDFUNDS plays for USD:
// a market rate that follows the policy path, scored on changes.
void FetchFredIntl()
{
   string ccy[23] = {"EUR","EUR","EUR",
                     "GBP","GBP","GBP","GBP",
                     "JPY","JPY","JPY",
                     "CHF","CHF","CHF",
                     "CAD","CAD","CAD","CAD",
                     "AUD","AUD","AUD",
                     "NZD","NZD","NZD"};
   string key[23] = {"cpi","rate","gdp",
                     "cpi","unemp","rate","gdp",
                     "unemp","rate","gdp",
                     "cpi","rate","gdp",
                     "cpi","unemp","rate","gdp",
                     "unemp","rate","gdp",
                     "unemp","rate","gdp"};
   string ids[23] = {"CP0000EZ19M086NEST","ECBMRRFR","CLVMNACSCAB1GQEA19",
                     "GBRCPIALLMINMEI","LRHUTTTTGBM156S","IR3TIB01GBM156N","NAEXKP01GBQ657S",
                     "LRHUTTTTJPM156S","IR3TIB01JPM156N","NAEXKP01JPQ657S",
                     "CHECPIALLMINMEI","IR3TIB01CHM156N","CLVMNACSCAB1GQCH",
                     "CANCPIALLMINMEI","LRHUTTTTCAM156S","IR3TIB01CAM156N","NAEXKP01CAQ657S",
                     "LRHUTTTTAUM156S","IR3TIB01AUM156N","NAEXKP01AUQ657S",
                     "LRHUTTTTNZQ156S","IR3TIB01NZM156N","NAEXKP01NZQ657S"};
   int    xf[23]  = {1,0,2,
                     1,0,0,0,
                     0,0,0,
                     1,0,2,
                     1,0,0,0,
                     0,0,0,
                     0,0,0};
   for(int s = 0; s < 23; s++)
   {
      g_d_fred_try++;
      datetime dts[];
      double lv[];
      if(!FetchFredCsv(ids[s], dts, lv)) continue;
      int n = ArraySize(lv);
      int si = FSerIdx(ccy[s], key[s], "fred", true);
      bool usable = false;
      if(xf[s] == 1)             // YoY % from a monthly index (USD CPI branch)
      {
         if(n < 14) continue;
         for(int i = 12; i < n; i++)
         {
            if(lv[i - 12] == 0) continue;
            FSerAdd(si, dts[i], (lv[i] / lv[i - 12] - 1.0) * 100.0);
            usable = true;
         }
      }
      else if(xf[s] == 2)        // q/q % from a quarterly level (USD GDP branch)
      {
         if(n < 3) continue;
         for(int i = 1; i < n; i++)
         {
            if(lv[i - 1] == 0) continue;
            FSerAdd(si, dts[i], (lv[i] / lv[i - 1] - 1.0) * 100.0);
            usable = true;
         }
      }
      else                       // level as-is
      {
         for(int i = 0; i < n; i++) { FSerAdd(si, dts[i], lv[i]); usable = true; }
      }
      if(usable) g_d_fred_ok++;
   }
}

//+------------------------------------------------------------------+
// v4.9: MT5 BUILT-IN CALENDAR history - a third fundamental source.
// FRED (v4.8) covers most slots, but some have no living FRED
// series (JPY/AUD/NZD cpi, EUR/CHF unemp) and three CPI index
// series are frozen at their source in Mar-Apr 2025 (GBP/CHF/CAD).
// The terminal's own economic-calendar database holds months of
// ACTUAL prints for those same releases, readable with no
// WebRequest and no allowlist entry - IF the broker feeds the
// database (coverage is broker-dependent; some serve nothing).
//
// Discipline mirrors the other sources:
//   - ONE event per (currency, indicator), chosen by name matching
//     (CalClassify below): a series is that event_id end-to-end,
//     never a mix of variants (a headline YoY CPI and a core MoM
//     CPI can never blend into one string).
//   - Values are the calendar's actual prints, stored as the
//     numbers themselves - a % release (CPI, GDP, retail) lands as
//     the % value, EXACTLY as the faireconomy accumulation stores
//     prints (see FetchNews): the string scorer reads the
//     DIRECTION of the print string, and one event never changes
//     its units mid-string, so the raw scale is immaterial.
//   - Points land in the same FSer store with src "cal", so
//     scoring, sign maps, weights, TURN logic and the >= 2
//     indicator "bldg" rule are the shared code paths.
//   - BestFundDir picks ONE series per slot, deepest first: cal
//     fills empty slots immediately, overtakes the frozen FRED
//     CPI strings once deeper, and never double-counts a release
//     another source already scored.
//   - Revisions: the calendar can carry several values for one
//     reporting period (original + revisions). Points are keyed
//     by the value's PERIOD floored to the day (the release day
//     when no period is set) and within a period the highest
//     revision wins, so a revised print REPLACES its original in
//     the string - the same revision-wins rule FSerAdd applies -
//     and the outcome does not depend on return order.
//   - Only values already published (datetime <= now) with an
//     actual present are used - no forecasts, no future events.
// Graceful absence: when enumeration finds nothing for ANY ladder
// currency, the source marks itself unavailable for the cycle
// (fetch line: "cal n/a") and every other path runs unchanged.
// Every Calendar API return is checked before it is trusted, and
// nothing here can block the fetch cycle.
// API-usage risk, stated plainly (this code is not compiled on
// the build VM): the calls and members used are CalendarEvents-
// ByCurrency, CalendarValueHistoryByEvent, MqlCalendarEvent.id /
// .name, and MqlCalendarValue.time / .period / .revision
// plus its HasActualValue() / GetActualValue() accessors, per
// MetaQuotes documentation. If a member name differs in Mazi's
// build, the first MetaEditor compile points at these lines.

// Classify one calendar event name into an indicator key plus a
// variant tier (higher = the variant we would rather score).
// Returns "" for events we do not score. Keyword order matters:
// unemployment is claimed before jobs ("Unemployment Rate" must
// never become a jobs series), claimant count is GBP's jobs read,
// and PMI checks composite, then services / non-manufacturing,
// then manufacturing (a "Non-Manufacturing PMI" is services).
string CalClassify(const string rawname, int &tier)
{
   tier = -1;
   string t = rawname;
   StringToLower(t);
   // ---- cpi: headline YoY preferred; core (incl. trimmed-mean /
   // median measures) fills the slot only if no headline exists.
   // PCE price indices match none of the triggers, by design.
   if(StringFind(t, "cpi") >= 0 || StringFind(t, "consumer price") >= 0 ||
      StringFind(t, "inflation rate") >= 0)
   {
      if(StringFind(t, "expectation") >= 0) return "";
      bool core = (StringFind(t, "core") >= 0 || StringFind(t, "trimmed") >= 0 ||
                   StringFind(t, "median") >= 0);
      bool yoy = (StringFind(t, "yoy") >= 0 || StringFind(t, "y/y") >= 0 ||
                  StringFind(t, "annual") >= 0);
      tier = (yoy ? 2 : 0) + (core ? 0 : 1);
      return "cpi";
   }
   // ---- unemp: the rate itself first, then any unemployment
   // series (e.g. a national unemployment-change release).
   if(StringFind(t, "unemployment rate") >= 0 || StringFind(t, "jobless rate") >= 0)
   {
      tier = 2;
      return "unemp";
   }
   if(StringFind(t, "unemployment") >= 0 || StringFind(t, "jobless") >= 0)
   {
      tier = 1;
      return "unemp";
   }
   // ---- jobs: headline payrolls first; employment change and the
   // GBP claimant count next; any other employment release last;
   // the ADP private print is a fallback only.
   if(StringFind(t, "nonfarm") >= 0 || StringFind(t, "non-farm") >= 0 ||
      StringFind(t, "non farm") >= 0 || StringFind(t, "payroll") >= 0 ||
      StringFind(t, "employment change") >= 0 || StringFind(t, "claimant count") >= 0 ||
      StringFind(t, "employment") >= 0)
   {
      if(StringFind(t, "cost index") >= 0) return "";  // Employment Cost Index = wages, not jobs
      tier = 1;
      if(StringFind(t, "employment change") >= 0 || StringFind(t, "claimant count") >= 0)
         tier = 2;
      if(StringFind(t, "nonfarm") >= 0 || StringFind(t, "non-farm") >= 0 ||
         StringFind(t, "non farm") >= 0 || StringFind(t, "payroll") >= 0)
         tier = 3;
      if(StringFind(t, "adp") >= 0) tier = 0;
      return "jobs";
   }
   // ---- rate: policy decisions only. "Unemployment Rate" was
   // already claimed above, and every trigger here is a policy
   // phrase anyway, so no rate-named statistic can slip in.
   if(StringFind(t, "interest rate") >= 0 || StringFind(t, "rate decision") >= 0 ||
      StringFind(t, "policy rate") >= 0 || StringFind(t, "bank rate") >= 0 ||
      StringFind(t, "cash rate") >= 0 || StringFind(t, "overnight rate") >= 0 ||
      StringFind(t, "refinancing rate") >= 0 || StringFind(t, "federal funds") >= 0 ||
      StringFind(t, "official rate") >= 0 || StringFind(t, "key rate") >= 0 ||
      StringFind(t, "repo rate") >= 0 || StringFind(t, "facility rate") >= 0)
   {
      tier = (StringFind(t, "interest rate decision") >= 0) ? 3 : 2;
      return "rate";
   }
   // ---- gdp: q/q is the standard read; flash/prelim variants
   // are docked a tier (clamped at 0), never excluded.
   if(StringFind(t, "gdp") >= 0 || StringFind(t, "gross domestic") >= 0)
   {
      if(StringFind(t, "deflator") >= 0 || StringFind(t, "price index") >= 0)
         return "";   // GDP price indices are inflation, not growth
      tier = 2;
      if(StringFind(t, "qoq") >= 0 || StringFind(t, "q/q") >= 0) tier = 3;
      else if(StringFind(t, "mom") >= 0 || StringFind(t, "m/m") >= 0) tier = 1;
      if(StringFind(t, "prelim") >= 0 || StringFind(t, "flash") >= 0)
         tier = (tier > 0) ? tier - 1 : 0;
      return "gdp";
   }
   // ---- retail: headline m/m preferred; core / ex-auto docked.
   if(StringFind(t, "retail sales") >= 0)
   {
      tier = 1;
      if(StringFind(t, "mom") >= 0 || StringFind(t, "m/m") >= 0) tier = 2;
      if(StringFind(t, "core") >= 0 || StringFind(t, "ex auto") >= 0)
         tier = (tier > 0) ? tier - 1 : 0;
      return "retail";
   }
   // ---- pmi: composite > services > manufacturing > any other.
   if(StringFind(t, "pmi") >= 0 || StringFind(t, "purchasing managers") >= 0)
   {
      tier = 0;
      if(StringFind(t, "manufacturing") >= 0) tier = 1;
      if(StringFind(t, "services") >= 0 || StringFind(t, "non-manufacturing") >= 0 ||
         StringFind(t, "non manufacturing") >= 0)
         tier = 2;
      if(StringFind(t, "composite") >= 0) tier = 3;
      if(StringFind(t, "prelim") >= 0 || StringFind(t, "flash") >= 0)
         tier = (tier > 0) ? tier - 1 : 0;
      return "pmi";
   }
   return "";
}

void FetchCalendarIntl()
{
   string keys[7] = {"cpi", "jobs", "unemp", "rate", "gdp", "retail", "pmi"};
   datetime nowS = TimeCurrent();
   datetime from = nowS - 1100 * 86400;   // same depth as the FRED window
   for(int c = 0; c < ArraySize(g_ccy); c++)
   {
      string ccy = g_ccy[c].code;
      MqlCalendarEvent evs[];
      int nev = CalendarEventByCurrency(ccy, evs);
      if(nev <= 0) continue;   // this broker serves nothing for the currency
      g_d_cal_avail = true;
      // classify each event once for this currency
      string ekey[];
      int etier[];
      ArrayResize(ekey, nev);
      ArrayResize(etier, nev);
      for(int e = 0; e < nev; e++)
         ekey[e] = CalClassify(evs[e].name, etier[e]);
      for(int k = 0; k < 7; k++)
      {
         // One event per slot: highest variant tier, then the
         // SHORTEST name - the un-prefixed aggregate release
         // ("CPI (YoY)") over a national one ("German CPI (YoY)")
         // at equal tier - then the lowest event id, so the pick
         // is deterministic across cycles.
         ulong bestId = 0;
         int bestTier = -1, bestLen = 0;
         for(int e = 0; e < nev; e++)
         {
            if(ekey[e] != keys[k] || etier[e] < 0) continue;
            int len = StringLen(evs[e].name);
            if(etier[e] > bestTier || (etier[e] == bestTier && len < bestLen) ||
               (etier[e] == bestTier && len == bestLen && evs[e].id < bestId))
            {
               bestId = evs[e].id;
               bestTier = etier[e];
               bestLen = len;
            }
         }
         if(bestId == 0) continue;
         g_d_cal_try++;
         MqlCalendarValue vals[];
         int nv = CalendarValueHistoryByEvent(bestId, vals, from, nowS);
         if(nv <= 0) continue;
         // Dedupe by reporting period (release day when the value
         // carries no period); within a period the highest
         // revision wins, so a revision replaces its original.
         datetime kd[];
         double kv[];
         int kr[];
         for(int i = 0; i < nv; i++)
         {
            if(!vals[i].HasActualValue()) continue;
            if(vals[i].time <= 0 || vals[i].time > nowS) continue;
            datetime base = (vals[i].period > 0) ? vals[i].period : vals[i].time;
            datetime day = (datetime)((long)(base / 86400) * 86400);
            double v = vals[i].GetActualValue();
            int seen = -1;
            for(int j = 0; j < ArraySize(kd); j++)
               if(kd[j] == day) { seen = j; break; }
            if(seen < 0)
            {
               int m = ArraySize(kd);
               ArrayResize(kd, m + 1);
               ArrayResize(kv, m + 1);
               ArrayResize(kr, m + 1);
               kd[m] = day;
               kv[m] = v;
               kr[m] = vals[i].revision;
            }
            else if(vals[i].revision >= kr[seen])
            {
               kv[seen] = v;
               kr[seen] = vals[i].revision;
            }
         }
         if(ArraySize(kd) < 2) continue;   // not a usable string yet
         int si = FSerIdx(ccy, keys[k], "cal", true);
         for(int j = 0; j < ArraySize(kd); j++)
            FSerAdd(si, kd[j], kv[j]);
         g_d_cal_ok++;
      }
   }
}

//+------------------------------------------------------------------+
// ff_history.csv (Common Files): the accumulated calendar-print
// store. Format per line: date,currency,indicator_key,actual
// (date = ISO yyyy-mm-dd, the release day). Loaded at init, rewritten
// whenever a fetch cycle adds or revises a point.
void FFHistoryAdd(const string ccy, const string key, datetime d, double v)
{
   int si = FSerIdx(ccy, key, "ff", true);
   if(FSerAdd(si, d, v)) g_ff_dirty = true;
}

void LoadFFHistory()
{
   int h = FileOpen("ff_history.csv", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   int loaded = 0;
   while(!FileIsEnding(h))
   {
      string ln = FileReadString(h);
      string parts[];
      if(StringSplit(ln, ',', parts) < 4) continue;
      string ccy = parts[1];
      string key = parts[2];
      StringTrimLeft(ccy);
      StringTrimRight(ccy);
      StringTrimLeft(key);
      StringTrimRight(key);
      if(CcyIdx(ccy) < 0 || key == "") continue;
      datetime d = ParseDateOnly(parts[0]);
      if(d <= 0) continue;
      int si = FSerIdx(ccy, key, "ff", true);
      if(FSerAdd(si, d, StringToDouble(parts[3]))) loaded++;
   }
   FileClose(h);
   g_ff_dirty = false;
   if(loaded > 0) Print("GeneralMacro: loaded ", loaded, " accumulated calendar prints from ff_history.csv");
}

void SaveFFHistory()
{
   int h = FileOpen("ff_history.csv", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   for(int s = 0; s < ArraySize(g_fser); s++)
   {
      if(g_fser[s].src != "ff") continue;
      for(int i = 0; i < ArraySize(g_fser[s].dts); i++)
         FileWriteString(h, YmdStr(g_fser[s].dts[i]) + "," + g_fser[s].ccy + "," +
                            g_fser[s].key + "," + DoubleToString(g_fser[s].vals[i], 4) + "\n");
   }
   FileClose(h);
}

//+------------------------------------------------------------------+
// v4.1 per-leg helpers. Latest surprise tilt for one currency: the
// hawkish/dovish balance of its prints from the last 6 hours (the
// same window the gold engine tilts on).
string LegTilt(const string ccy)
{
   int hawk = 0, dove = 0;
   for(int i = 0; i < ArraySize(g_news); i++)
   {
      if(g_news[i].country != ccy) continue;
      int m = g_news[i].minutes;
      if(m < 0 && m >= -360)
      {
         if(g_news[i].surprise == "hawkish") hawk++;
         if(g_news[i].surprise == "dovish") dove++;
      }
   }
   if(hawk > dove) return "hawkish";
   if(dove > hawk) return "dovish";
   if(hawk > 0) return "mixed";
   return "none";
}

// Next future high-impact event for one currency.
void FillLegNews(const string ccy, string &title, string &when, int &mins)
{
   title = "";
   when = "";
   mins = -1;
   int best = 999999;
   string bt = "";
   for(int i = 0; i < ArraySize(g_news); i++)
   {
      if(g_news[i].country != ccy) continue;
      int m = g_news[i].minutes;
      if(m >= 0 && m < best)
      {
         best = m;
         bt = g_news[i].title;
      }
   }
   if(best == 999999) return;
   mins = best;
   title = bt;
   MqlDateTime c;
   TimeToStruct(TimeLocal() + best * 60, c);
   when = DowShort(c.day_of_week) + StringFormat(" %02d:%02d", c.hour, c.min);
}

//+------------------------------------------------------------------+
// Per-pair news state from the shared calendar: blackout if a high-
// impact event for either leg is inside the blackout window. Gold's
// "legs" for news purposes are USD + EUR + CNY (the v2.00 set).
void PairNewsState(PairState &p)
{
   p.blackout = false;
   p.next_news = "";
   p.next_when = "";
   p.mins_news = -1;
   int best = 999999;
   string best_title = "";
   for(int i = 0; i < ArraySize(g_news); i++)
   {
      string c = g_news[i].country;
      bool match;
      if(p.is_gold)
         match = (c == "USD" || c == "EUR" || c == "CNY");
      else
         match = (c == p.base || c == p.quote);
      if(!match) continue;
      int m = g_news[i].minutes;
      if(m >= 0 && m < best)
      {
         best = m;
         best_title = c + " " + g_news[i].title;
      }
      if(m >= 0 && m <= InpBlackoutBeforeMin) p.blackout = true;
      if(m < 0 && m >= -InpBlackoutAfterMin) p.blackout = true;
   }
   if(best != 999999)
   {
      p.mins_news = best;
      p.next_news = best_title;
      MqlDateTime c;
      TimeToStruct(TimeLocal() + best * 60, c);
      p.next_when = StringFormat("%02d:%02d CT", c.hour, c.min);
   }

   // v4.1: per-leg detail for the chart-pair section. Gold's base
   // leg shows the gold engine's own next event/tilt (the USD/EUR/
   // CNY set); its quote leg is plain USD.
   if(p.is_gold)
   {
      p.nb_title = g_next_news;
      p.nb_mins = g_mins_news;
      if(g_mins_news >= 0)
      {
         MqlDateTime c2;
         TimeToStruct(TimeLocal() + g_mins_news * 60, c2);
         p.nb_when = DowShort(c2.day_of_week) + StringFormat(" %02d:%02d", c2.hour, c2.min);
      }
      else
         p.nb_when = "";
      p.tilt_b = g_gold_tilt_txt;
   }
   else
   {
      FillLegNews(p.base, p.nb_title, p.nb_when, p.nb_mins);
      p.tilt_b = LegTilt(p.base);
   }
   FillLegNews(p.quote, p.nq_title, p.nq_when, p.nq_mins);
   p.tilt_q = LegTilt(p.quote);
}

// Pair bias = strength(base) - strength(quote), diff in -8..+8,
// normalized diff/8 and read against the same +/-0.28 thresholds the
// gold engine uses. XAUUSD keeps the gold factor engine as primary.
// v4.3 indices: single-asset bias from the index leg's tot (-4..+4),
// normalized tot/4 to the same -1..+1 range.
void ComputeAllPairs()
{
   for(int i = 0; i < ArraySize(g_pairs); i++)
   {
      if(g_pairs[i].is_gold)
      {
         g_pairs[i].bias = g_bias;
         g_pairs[i].bias_n = g_bias_n;
         g_pairs[i].conv = g_conv;
         g_pairs[i].diff = 0;
      }
      else if(g_pairs[i].is_index)
      {
         // v4.3: single-asset bias. tot spans -4..+4 (one leg, not a
         // difference of two), so the equivalent normalization is
         // tot / 4 - it maps to the same -1..+1 normalized range the
         // pair diff / 8 produces, read against the same +/-0.28
         // thresholds and the same conviction formula.
         int k = g_pairs[i].idx_kind - 1;
         g_pairs[i].idx_px = g_idx[k].px;
         g_pairs[i].idx_px_ok = g_idx[k].px_ok;
         g_pairs[i].idx_fund = g_idx[k].fund;
         g_pairs[i].idx_fund_ok = g_idx[k].fund_ok;
         g_pairs[i].idx_tot = g_idx[k].tot;
         double norm = g_idx[k].tot / 4.0;
         g_pairs[i].diff = g_idx[k].tot;   // gap slot / INI / rank read diff
         if(norm >= LONG_TH) { g_pairs[i].bias = "LONG"; g_pairs[i].bias_n = 1; }
         else if(norm <= SHORT_TH) { g_pairs[i].bias = "SHORT"; g_pairs[i].bias_n = -1; }
         else { g_pairs[i].bias = "NEUTRAL"; g_pairs[i].bias_n = 0; }
         int cv = (int)MathRound(MathMin(100.0, MathAbs(norm) / 0.9 * 100.0));
         if(g_pairs[i].bias_n == 0) cv = (int)MathMin(cv, 40);
         g_pairs[i].conv = cv;
      }
      else
      {
         int bi = CcyIdx(g_pairs[i].base);
         int qi = CcyIdx(g_pairs[i].quote);
         if(bi < 0 || qi < 0)
         {
            g_pairs[i].bias = "-";
            g_pairs[i].bias_n = 0;
            g_pairs[i].conv = 0;
            g_pairs[i].diff = 0;
         }
         else
         {
            // v4.1: totals now span -4..+4 per leg, so the diff spans
            // -8..+8; same normalization approach as v4.0 (diff over
            // the full span, read against the same +/-0.28 gold
            // thresholds), rescaled: norm = diff / 8.
            double diff = g_ccy[bi].strength - g_ccy[qi].strength;
            double norm = diff / 8.0;
            g_pairs[i].diff = diff;
            if(norm >= LONG_TH) { g_pairs[i].bias = "LONG"; g_pairs[i].bias_n = 1; }
            else if(norm <= SHORT_TH) { g_pairs[i].bias = "SHORT"; g_pairs[i].bias_n = -1; }
            else { g_pairs[i].bias = "NEUTRAL"; g_pairs[i].bias_n = 0; }
            int cv = (int)MathRound(MathMin(100.0, MathAbs(norm) / 0.9 * 100.0));
            if(g_pairs[i].bias_n == 0) cv = (int)MathMin(cv, 40);
            g_pairs[i].conv = cv;
         }
      }
      PairNewsState(g_pairs[i]);
      if(g_pairs[i].blackout && g_pairs[i].conv > 25)
         g_pairs[i].conv = 25;
   }
}

//+------------------------------------------------------------------+
string JsonStr(const string src, const string key, int from, int span)
{
   string needle = "\"" + key + "\":\"";
   int p = StringFind(src, needle, from);
   if(p < 0 || p > from + span) return "";
   p += StringLen(needle);
   int e = StringFind(src, "\"", p);
   if(e < 0) return "";
   return StringSubstr(src, p, e - p);
}

int DaysSince1970(int y, int m, int d)
{
   int days = 0;
   for(int yy = 1970; yy < y; yy++)
      days += (((yy % 4 == 0 && yy % 100 != 0) || yy % 400 == 0) ? 366 : 365);
   int md[] = {0,31,28,31,30,31,30,31,31,30,31,30,31};
   for(int i = 1; i < m; i++)
   {
      days += md[i];
      if(i == 2 && ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0))
         days++;
   }
   return days + d - 1;
}

datetime ParseIsoGmt(string iso)
{
   if(StringLen(iso) < 16) return 0;
   int y = (int)StringToInteger(StringSubstr(iso, 0, 4));
   int mo = (int)StringToInteger(StringSubstr(iso, 5, 2));
   int d = (int)StringToInteger(StringSubstr(iso, 8, 2));
   int h = (int)StringToInteger(StringSubstr(iso, 11, 2));
   int mi = (int)StringToInteger(StringSubstr(iso, 14, 2));
   int sign = 1, oh = 0, om = 0;
   int zp = StringFind(iso, "Z");
   int pp = StringFind(iso, "+", 19);
   int mp = StringFind(iso, "-", 19);
   if(pp > 0)
   {
      sign = 1;
      oh = (int)StringToInteger(StringSubstr(iso, pp + 1, 2));
      om = (int)StringToInteger(StringSubstr(iso, pp + 4, 2));
   }
   else if(mp > 0 && zp < 0)
   {
      sign = -1;
      oh = (int)StringToInteger(StringSubstr(iso, mp + 1, 2));
      om = (int)StringToInteger(StringSubstr(iso, mp + 4, 2));
   }
   datetime wall = (datetime)(DaysSince1970(y, mo, d) * 86400 + h * 3600 + mi * 60);
   int off = sign * (oh * 3600 + om * 60);
   return wall - off;
}

bool IsHigh(string impact)
{
   string low = impact;
   StringToLower(low);
   return (low == "high" || low == "3" || low == "red");
}

bool IsG10(string c)
{
   return (c == "USD" || c == "EUR" || c == "GBP" || c == "JPY" || c == "CHF" ||
           c == "CAD" || c == "AUD" || c == "NZD" || c == "CNY");
}

string ClassifySurprise(string title, string actual, string forecast)
{
   if(actual == "" || forecast == "" || actual == "n/a") return "";
   double a = StringToDouble(actual);
   double f = StringToDouble(forecast);
   if(a == 0 && StringFind(actual, "0") < 0) return "";
   if(a == f) return "";
   bool above = a > f;
   string t = title;
   StringToLower(t);
   if(StringFind(t, "unemployment") >= 0 || StringFind(t, "jobless") >= 0 || StringFind(t, "claims") >= 0)
      return above ? "dovish" : "hawkish";
   if(StringFind(t, "cpi") >= 0 || StringFind(t, "pce") >= 0 || StringFind(t, "ppi") >= 0 ||
      StringFind(t, "non-farm") >= 0 || StringFind(t, "nonfarm") >= 0 || StringFind(t, "nfp") >= 0 ||
      StringFind(t, "gdp") >= 0 || StringFind(t, "retail") >= 0 || StringFind(t, "interest rate") >= 0 ||
      StringFind(t, "federal funds") >= 0)
      return above ? "hawkish" : "dovish";
   return "";
}

// Calendar fetch: same faireconomy feed as v2.00, but the country
// filter is widened from USD/CNY/EUR to all G10 so every pair can run
// its own blackout. The gold engine below still reads only its
// original USD/CNY/EUR subset (see ApplyNewsAndBias), preserving parity.
void FetchNews()
{
   ArrayResize(g_news, 0);
   string body;
   if(!HttpGet("https://nfs.faireconomy.media/ff_calendar_thisweek.json", body))
   {
      g_d_ff = 0;
      return;
   }
   g_d_ff = 1;
   int pos = 0;
   datetime nowg = TimeGMT();
   while(true)
   {
      int t = StringFind(body, "\"title\":\"", pos);
      if(t < 0) break;
      string title = JsonStr(body, "title", t, 400);
      string country = JsonStr(body, "country", t, 800);
      string impact = JsonStr(body, "impact", t, 800);
      string date = JsonStr(body, "date", t, 800);
      string forecast = JsonStr(body, "forecast", t, 800);
      string actual = JsonStr(body, "actual", t, 800);
      string previous = JsonStr(body, "previous", t, 800);
      pos = t + 10;
      if(!IsG10(country)) continue;
      datetime gmt = ParseIsoGmt(date);
      if(gmt <= 0) continue;
      // v4.1 accumulation: EVERY high/medium-impact print for one of
      // the 8 tracked currencies joins that currency's fundamental
      // history (the book's string of prints). The feed's "previous"
      // seeds the prior point (dated ~30 days earlier - monthly
      // cadence approximation, see BUILD-NOTES). The g_news set
      // below stays high-impact only, exactly as v4.0 built it.
      if(CcyIdx(country) >= 0 && (IsHigh(impact) || IsMedium(impact)))
      {
         string ikey = IndicatorKey(title);
         double av = 0;
         if(ikey != "" && ParseActualNum(actual, av))
         {
            datetime day = (datetime)((long)(gmt / 86400) * 86400);
            FFHistoryAdd(country, ikey, day, av);
            double pv = 0;
            if(ParseActualNum(previous, pv))
               FFHistoryAdd(country, ikey, day - 30 * 86400, pv);
         }
      }
      if(!IsHigh(impact)) continue;
      int n = ArraySize(g_news);
      ArrayResize(g_news, n + 1);
      g_news[n].title = title;
      g_news[n].country = country;
      g_news[n].gmt = gmt;
      g_news[n].minutes = (int)MathRound((double)(gmt - nowg) / 60.0);
      g_news[n].forecast = forecast;
      g_news[n].actual = actual;
      g_news[n].surprise = ClassifySurprise(title, actual, forecast);
      g_news[n].ok = true;
   }
}

// Gold engine, v2.00 logic unchanged. The only edit: the loop skips
// non-USD/CNY/EUR events, because the shared calendar now carries all
// G10 — the gold next-event, blackout and surprise tilt must see
// exactly the set v2.00 saw.
void ApplyNewsAndBias(const string session, News &news[])
{
   g_session = session;
   int horizon = (session == "asia" ? 20 * 60 : 10 * 60);
   int nxt = -1, nxtmin = 999999;
   g_blackout = false;
   int tilt = 0;
   string snote = "";
   for(int i = 0; i < ArraySize(news); i++)
   {
      if(news[i].country != "USD" && news[i].country != "CNY" && news[i].country != "EUR")
         continue;
      int m = news[i].minutes;
      if(m >= 0 && m <= horizon && m < nxtmin)
      {
         nxtmin = m;
         nxt = i;
      }
      if(m >= 0 && m <= InpBlackoutBeforeMin) g_blackout = true;
      if(m < 0 && m >= -InpBlackoutAfterMin) g_blackout = true;
      if(m < 0 && m >= -360)
      {
         if(news[i].surprise == "hawkish") { tilt--; snote += news[i].country + " " + news[i].title + " hawkish. "; }
         if(news[i].surprise == "dovish") { tilt++; snote += news[i].country + " " + news[i].title + " dovish. "; }
      }
   }
   if(tilt > 1) tilt = 1;
   if(tilt < -1) tilt = -1;
   g_gold_tilt_txt = (tilt > 0) ? "dovish" : (tilt < 0) ? "hawkish" :
                     (snote != "") ? "mixed" : "none";

   if(nxt >= 0)
   {
      g_next_news = news[nxt].country + " " + news[nxt].title;
      g_mins_news = news[nxt].minutes;
      MqlDateTime c;
      ChicagoNow(c);
      datetime localish = TimeGMT() + news[nxt].minutes * 60;
      TimeToStruct(TimeLocal() + news[nxt].minutes * 60, c);
      g_next_when = StringFormat("%02d:%02d CT", c.hour, c.min);
      g_news_risk = (g_blackout || g_mins_news <= 180);
   }
   else
   {
      g_next_news = "";
      g_next_when = "";
      g_mins_news = -1;
      g_news_risk = false;
   }

   g_regime = Regime();
   int id = FacIdx("dxy"), it = FacIdx("tnx");
   g_agree = (id >= 0 && it >= 0 && g_fac[id].score != 0 && g_fac[id].score == g_fac[it].score);

   double raw = 0, wsum = 0;
   for(int i = 0; i < ArraySize(g_fac); i++)
   {
      if(g_fac[i].weight <= 0) continue;
      wsum += g_fac[i].weight;
      raw += g_fac[i].weighted;
   }
   if(StringFind(g_regime, "dollar squeeze") >= 0) raw -= 0.75;
   raw += 0.55 * tilt;
   double norm = (wsum > 0 ? raw / wsum : 0);
   if(norm >= LONG_TH) { g_bias = "LONG"; g_bias_n = 1; }
   else if(norm <= SHORT_TH) { g_bias = "SHORT"; g_bias_n = -1; }
   else { g_bias = "NEUTRAL"; g_bias_n = 0; }
   g_conv = (int)MathRound(MathMin(100.0, MathAbs(norm) / 0.9 * 100.0));
   if(g_bias == "NEUTRAL") g_conv = (int)MathMin(g_conv, 40);
   if(!g_agree && g_bias != "NEUTRAL" && g_conv > 55) g_conv = 55;
   if(g_blackout) g_conv = (int)MathMin(g_conv, 25);

   BuildPlaybook(session, snote);
}

void BuildPlaybook(const string session, const string snote)
{
   g_nplay = 0;
   if(g_blackout)
      AddPlay("HIGH-IMPACT BLACKOUT - do not trade S/R through the print.");
   else if(g_mins_news >= 0 && g_mins_news <= 90)
      AddPlay("High-impact in " + IntegerToString(g_mins_news) + " min: " + g_next_news + ". Shrink size or wait.");
   if(session == "asia")
   {
      AddPlay("Asia 6pm CT briefing - before your 7-8pm direction window.");
      AddPlay("Wait 7-8pm CT vs S/R, then follow that trend. This card is not an entry.");
   }
   else
   {
      AddPlay("Pre-NY 7am CT: if overnight gold fought Asia bias, do not force it.");
      AddPlay("Still wait for NY structure vs S/R. This card is not an entry.");
   }
   string side = (g_bias == "LONG" ? "favor longs off support" : (g_bias == "SHORT" ? "favor shorts off resistance" : "no preferred side - demand a clean S/R break"));
   AddPlay("Macro: " + side + ".");
   if(!g_agree) AddPlay("Dollar and yields disagree - keep conviction low.");
   if(snote != "") AddPlay(snote);
}

void AddPlay(const string s)
{
   if(g_nplay >= 8) return;
   g_play[g_nplay++] = s;
}

//+------------------------------------------------------------------+
// Technical layer (Jamaal's chassis) per symbol, D1, from TERMINAL
// price history (CopyRates) — never Yahoo. Bands/fib/MAs are computed
// manually from closes: basis = SMA(100) of the last 100 CLOSED daily
// bars, bands = basis +/- 2 * population stdev of those closes,
// SMA(200) over the last 200 closed bars. "Price" is the live bid.
bool ComputeTech(const string rsym, Tech &t)
{
   t.ok = false;
   t.regime = 0;
   t.zone = 0;
   t.confluence = 0;
   t.entry = 0; t.stop = 0; t.t1 = 0; t.t2 = 0; t.rr1 = 0; t.rr2 = 0;
   t.price = 0; t.basis = 0; t.upper = 0; t.lower = 0; t.sma200 = 0;
   t.f50 = 0; t.f618 = 0; t.f786 = 0;
   t.regime_change = false;
   t.zone_text = "no data";
   t.regime_label = "no data";

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(rsym, PERIOD_D1, 0, 230, rates);
   if(copied < 201)
   {
      t.zone_text = "no D1 history";
      t.regime_label = "no data";
      return false;
   }

   // bars are series-indexed: rates[0] = current (forming) bar,
   // rates[1] = last closed bar. All averages use CLOSED bars only.
   double sum100 = 0;
   for(int i = 1; i <= 100; i++) sum100 += rates[i].close;
   double basis = sum100 / 100.0;
   double sq = 0;
   for(int i = 1; i <= 100; i++)
   {
      double d = rates[i].close - basis;
      sq += d * d;
   }
   double sd = MathSqrt(sq / 100.0);
   double upper = basis + 2.0 * sd;
   double lower = basis - 2.0 * sd;
   double sum200 = 0;
   for(int i = 1; i <= 200; i++) sum200 += rates[i].close;
   double sma200 = sum200 / 200.0;
   double sumPrev = 0;
   for(int i = 6; i <= 105; i++) sumPrev += rates[i].close;
   double basisPrev = sumPrev / 100.0;

   double price = 0;
   if(!SymbolInfoDouble(rsym, SYMBOL_BID, price) || price <= 0)
      price = rates[0].close;

   double R = upper - lower;
   if(R <= 0)
   {
      t.zone_text = "flat bands";
      t.regime_label = "no range";
      return false;
   }

   t.ok = true;
   t.price = price;
   t.basis = basis;
   t.upper = upper;
   t.lower = lower;
   t.sma200 = sma200;

   double eps = 0.01 * R;
   int slope = 0;
   if(basis > basisPrev + eps) slope = 1;
   else if(basis < basisPrev - eps) slope = -1;

   int regime = 0;
   if(price > basis) regime = 1;
   else if(price < basis) regime = -1;
   else regime = slope;
   t.regime = regime;

   // Band-to-band Fibonacci. Bull: drawn lower band -> upper band, so
   // the retracement levels sit below the top: 50% at the midpoint
   // (= basis, the framework's drawn-correctly check), 61.8% deeper,
   // 78.6% deepest. Bear is the mirror.
   if(regime >= 0)
   {
      t.f50  = lower + 0.500 * R;
      t.f618 = lower + 0.382 * R;
      t.f786 = lower + 0.214 * R;
   }
   else
   {
      t.f50  = upper - 0.500 * R;
      t.f618 = upper - 0.382 * R;
      t.f786 = upper - 0.214 * R;
   }

   // Opportunity zone: bulls buy at/below fib 50 down to fib 78.6;
   // bears sell at/above fib 50 up to fib 78.6. Past 78.6 the level
   // has failed — that is the failure forecast's territory, not a zone.
   if(regime > 0)
   {
      if(price <= t.f50 && price >= t.f786) t.zone = 1;
      else if(price < t.f786) t.zone = 2;
      else t.zone = 0;
   }
   else if(regime < 0)
   {
      if(price >= t.f50 && price <= t.f786) t.zone = -1;
      else if(price > t.f786) t.zone = -2;
      else t.zone = 0;
   }
   t.zone_text = (t.zone == 1)  ? "IN ZONE (BUY)" :
                 (t.zone == -1) ? "IN ZONE (SELL)" :
                 (t.zone == 2)  ? "OVERSHOT (below 78.6)" :
                 (t.zone == -2) ? "OVERSHOT (above 78.6)" :
                                  "NO TRADE (mid-range)";

   // Trade plan. Entry reference: live price when price is in/past the
   // zone, otherwise the zone edge (fib 50) the trade would trigger at.
   // Stop = failure forecast: re-anchor the fib with its 50% on the
   // traded level (fib 78.6); the stop sits below the extended grid's
   // 61.8 line (0.118R past the level) plus 0.05R breathing room.
   // T1 = opposite band. T2 = projected 78.6 of the grid shifted onto
   // the opposite band (0.286R beyond it).
   if(regime != 0)
   {
      t.entry = (t.zone != 0) ? price : t.f50;
      if(regime > 0)
      {
         t.stop = t.f786 - 0.168 * R;
         t.t1 = upper;
         t.t2 = upper + 0.286 * R;
      }
      else
      {
         t.stop = t.f786 + 0.168 * R;
         t.t1 = lower;
         t.t2 = lower - 0.286 * R;
      }
      double dist = MathAbs(t.entry - t.stop);
      if(dist > 0)
      {
         t.rr1 = MathAbs(t.t1 - t.entry) / dist;
         t.rr2 = MathAbs(t.t2 - t.entry) / dist;
      }
   }

   // Confluence (0..4): (1) price near a band, (2) price near a fib
   // level, (3) basis == fib 50 structural check, (4) SMA200 on the
   // regime's side. Tolerance = 10% of the band range.
   int conf = 0;
   double tol = 0.10 * R;
   if(MathMin(MathAbs(price - upper), MathAbs(price - lower)) <= tol) conf++;
   double dfib = MathMin(MathAbs(price - t.f50),
                 MathMin(MathAbs(price - t.f618), MathAbs(price - t.f786)));
   if(dfib <= tol) conf++;
   if(MathAbs(basis - t.f50) <= 0.02 * R) conf++;
   if((regime > 0 && price > sma200) || (regime < 0 && price < sma200)) conf++;
   t.confluence = conf;

   t.regime_change = (regime > 0 && price < sma200) || (regime < 0 && price > sma200);
   string sdir = (slope > 0) ? "basis rising" : (slope < 0) ? "basis falling" : "basis flat";
   if(regime > 0)
      t.regime_label = (price > sma200) ? ("BULL (" + sdir + ")") : "BULL, deep correction - below 200 wall";
   else if(regime < 0)
      t.regime_label = (price < sma200) ? ("BEAR (" + sdir + ")") : "BEAR, deep correction - above 200 wall";
   else
      t.regime_label = "FLAT / no regime";
   if(t.regime_change)
      t.regime_label += " - REGIME CHANGE";
   return true;
}

void RefreshTechnicals()
{
   for(int i = 0; i < ArraySize(g_pairs); i++)
   {
      Tech t;
      ComputeTech(g_pairs[i].rsym, t);
      g_pairs[i].tech = t;
      double base = g_pairs[i].is_gold ? (2.5 + 5.5 * g_pairs[i].conv / 100.0)
                                       : MathAbs(g_pairs[i].diff);
      bool inz = (t.zone == 1 || t.zone == -1);
      g_pairs[i].rank = base * (inz ? 2.0 : 1.0);
      g_pairs[i].grade = GradeFor(g_pairs[i].conv, t);
   }
}

// Grade mapping (documented in BUILD-NOTES-v4.md):
//   A: confluence >= 3 AND conviction >= 55
//   B: confluence >= 2 AND conviction >= 40
//   C: any other graded setup (risk tier defaults to 0% = skip)
int GradeFor(int conv, const Tech &t)
{
   if(!t.ok) return 0;
   if(t.confluence >= 3 && conv >= 55) return 1;
   if(t.confluence >= 2 && conv >= 40) return 2;
   return 3;
}

string GradeLetter(int g)
{
   if(g == 1) return "A";
   if(g == 2) return "B";
   if(g == 3) return "C";
   return "-";
}

double RiskPctForGrade(int g)
{
   if(g == 1) return InpRiskA;
   if(g == 2) return InpRiskB;
   if(g == 3) return InpRiskC;
   return 0;
}

void SortPairs()
{
   int n = ArraySize(g_pairs);
   for(int i = 0; i < n - 1; i++)
      for(int j = 0; j < n - 1 - i; j++)
         if(g_pairs[j].rank < g_pairs[j + 1].rank)
         {
            PairState tmp = g_pairs[j];
            g_pairs[j] = g_pairs[j + 1];
            g_pairs[j + 1] = tmp;
         }
}

//+------------------------------------------------------------------+
// Position size for a risk % against the failure-forecast stop.
// Value of the stop distance per lot comes from the broker's own
// tick value / tick size, so JPY pairs and XAUUSD contract sizes are
// handled by the terminal, not by hard-coded pip math.
bool ComputeSize(const PairState &p, double riskpct, double &lots, string &txt)
{
   lots = 0;
   txt = "-";
   Tech t = p.tech;
   if(riskpct <= 0) { txt = "grade C - skip"; return false; }
   if(!t.ok) { txt = "no tech data"; return false; }
   double dist = MathAbs(t.entry - t.stop);
   if(dist <= 0) { txt = "no stop distance"; return false; }
   double tickSize = 0, tickVal = 0;
   SymbolInfoDouble(p.rsym, SYMBOL_TRADE_TICK_SIZE, tickSize);
   SymbolInfoDouble(p.rsym, SYMBOL_TRADE_TICK_VALUE, tickVal);
   if(tickSize <= 0 || tickVal <= 0) { txt = "tick value n/a"; return false; }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * riskpct / 100.0;
   double lossPerLot = dist / tickSize * tickVal;
   if(lossPerLot <= 0) { txt = "size n/a"; return false; }
   double raw = riskMoney / lossPerLot;
   double vmin = 0, vmax = 0, vstep = 0;
   SymbolInfoDouble(p.rsym, SYMBOL_VOLUME_MIN, vmin);
   SymbolInfoDouble(p.rsym, SYMBOL_VOLUME_MAX, vmax);
   SymbolInfoDouble(p.rsym, SYMBOL_VOLUME_STEP, vstep);
   if(vstep <= 0) vstep = 0.01;
   lots = MathFloor(raw / vstep) * vstep;
   if(lots < vmin)
   {
      txt = StringFormat("raw %.3f lots < min %.2f", raw, vmin);
      lots = 0;
      return false;
   }
   if(vmax > 0 && lots > vmax) lots = vmax;
   lots = MathRound(lots / vstep) * vstep;
   txt = StringFormat("%.2f lots ($%.0f risk)", lots, lots * lossPerLot);
   return true;
}

// Max-exposure ledger: sum of entry->stop risk over open positions
// that HAVE a stop. Positions without a stop are counted separately —
// their risk is undefined, not zero.
void ComputeLedger()
{
   g_deployed_money = 0;
   g_unprotected = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      string sym = PositionGetSymbol(i);
      if(sym == "") continue;
      double open = 0, sl = 0, vol = 0;
      PositionGetDouble(POSITION_PRICE_OPEN, open);
      PositionGetDouble(POSITION_SL, sl);
      PositionGetDouble(POSITION_VOLUME, vol);
      if(sl <= 0) { g_unprotected++; continue; }
      double ts = 0, tv = 0;
      SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE, ts);
      SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE, tv);
      if(ts <= 0 || tv <= 0) continue;
      g_deployed_money += MathAbs(open - sl) / ts * tv * vol;
   }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_deployed_pct = (equity > 0) ? g_deployed_money / equity * 100.0 : 0;
}

//+------------------------------------------------------------------+
// The gate: Why / Where / When / What, in that order (Jamaal Ch. 20).
// Any blank answer = NO TRADE, with the first failing leg named.
void EvaluateGate()
{
   ComputeLedger();
   g_setup_valid = false;
   g_grade = 0;
   g_size_lots = 0;
   g_size_txt = "-";
   int ci = ChartPairIdx();
   if(ci < 0)
   {
      g_why_txt = g_where_txt = g_when_txt = g_what_txt = "no chart pair";
      g_verdict = "NO TRADE - no chart pair";
      return;
   }
   PairState p = g_pairs[ci];
   Tech t = p.tech;
   g_grade = p.grade;

   // WHY — a real bias exists. Freshness (v4.1): with the manual
   // ladder gone, the only freshness question is whether the
   // fundamental data behind the read was fetched/updated within
   // the last 24h. Stale fundamentals do NOT hard-fail WHY - price
   // may be the only live input through no fault of the setup, and
   // there is no manual stamp left to blame - so they raise a
   // CAUTION on the line instead. A NEUTRAL bias still fails.
   string whyReason = "";
   bool fundFresh = FundFreshCcy(p.base) || FundFreshCcy(p.quote);
   g_why_ok = (p.bias_n != 0);
   if(!g_why_ok) whyReason = "bias is NEUTRAL";
   if(p.is_gold)
      g_why_txt = "gold factor bias " + p.bias + " conv " + IntegerToString(p.conv) +
                  " - USD fund " + FundStr("USD");
   else if(p.is_index)
      // v4.3: an index has one leg - the "gap" is its own total
      // strength, and freshness is the USD fund's (its only driver)
      g_why_txt = p.bias + " idx tot " + StringFormat("%+0.1f", p.idx_tot) +
                  " (px " + (p.idx_px_ok ? StringFormat("%+d", p.idx_px) : "n/a") +
                  ", fund " + (p.idx_fund_ok ? StringFormat("%+0.1f", p.idx_fund) : "bldg") + ")" +
                  (FundFreshCcy("USD") ? " - FUND fresh (<24h)"
                                       : " - CAUTION: fundamentals stale - price-led read");
   else
      g_why_txt = p.bias + " gap " + StringFormat("%+0.1f", p.diff) +
                  (fundFresh ? " - FUND fresh (<24h)"
                             : " - CAUTION: fundamentals stale - price-led read");
   if(!g_why_ok) g_why_txt += " - FAIL: " + whyReason;

   // WHERE — price is in the opportunity zone, on the bias's side
   string whereReason = "";
   g_where_ok = false;
   if(!t.ok) whereReason = "no D1 framework data";
   else if(t.zone == 1 && p.bias_n > 0) g_where_ok = true;
   else if(t.zone == -1 && p.bias_n < 0) g_where_ok = true;
   else if(t.zone == 1 || t.zone == -1) whereReason = "zone is against the bias";
   else whereReason = t.zone_text;
   g_where_txt = t.ok ? t.zone_text : "no data";
   if(!g_where_ok && whereReason != "") g_where_txt += " - FAIL: " + whereReason;

   // WHEN — no high-impact event for either leg inside the blackout window
   g_when_ok = !p.blackout;
   if(p.blackout)
      g_when_txt = "BLACKOUT - " + p.next_news;
   else if(p.next_news != "")
      g_when_txt = "clear - next HI: " + p.next_news + " " + p.next_when +
                   " (" + IntegerToString(p.mins_news) + "m)";
   else
      g_when_txt = "clear - no high-impact event for this pair this week";

   // WHAT — stop/target defined, R:R clears the bar, size computable
   double riskpct = RiskPctForGrade(p.grade);
   double lots = 0;
   string stxt = "";
   bool sizeOk = ComputeSize(p, riskpct, lots, stxt);
   g_size_lots = lots;
   g_size_txt = stxt;
   string whatReason = "";
   g_what_ok = (t.ok && t.rr2 >= InpMinRR && sizeOk);
   if(!t.ok) whatReason = "no stop/target - no tech data";
   else if(t.rr2 < InpMinRR) whatReason = StringFormat("RR %.2f < %.1f min", t.rr2, InpMinRR);
   else if(!sizeOk) whatReason = stxt;
   g_what_txt = t.ok ? StringFormat("stop %s  T1 %s  T2 %s  RR %.2f/%.2f  size %s",
                                    FmtPrice(p.rsym, t.stop), FmtPrice(p.rsym, t.t1),
                                    FmtPrice(p.rsym, t.t2), t.rr1, t.rr2, stxt)
                     : "no data";
   if(!g_what_ok && whatReason != "") g_what_txt += " - FAIL: " + whatReason;

   // verdict — first failing leg, in Why/Where/When/What order
   if(g_why_ok && g_where_ok && g_when_ok && g_what_ok)
   {
      g_setup_valid = true;
      g_verdict = "SETUP VALID - Grade " + GradeLetter(p.grade) + " - " + stxt;
   }
   else
   {
      string leg = !g_why_ok ? "WHY" : (!g_where_ok ? "WHERE" : (!g_when_ok ? "WHEN" : "WHAT"));
      string rsn = (leg == "WHY") ? whyReason :
                   (leg == "WHERE") ? whereReason :
                   (leg == "WHEN") ? "news blackout" : whatReason;
      g_verdict = "NO TRADE - " + leg + ": " + rsn;
   }
}

//+------------------------------------------------------------------+
string FmtPrice(const string rsym, double v)
{
   long dg = 2;
   SymbolInfoInteger(rsym, SYMBOL_DIGITS, dg);
   return DoubleToString(v, (int)dg);
}

string Sanitize(const string s)
{
   string o = "";
   for(int i = 0; i < StringLen(s); i++)
   {
      ushort ch = StringGetCharacter(s, i);
      bool ok = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9');
      o += ok ? StringSubstr(s, i, 1) : "_";
   }
   return o;
}

void Publish()
{
   int ci = ChartPairIdx();
   if(ci < 0) return;
   string cs = Sanitize(_Symbol);
   GlobalVariableSet("GeneralMacro_" + cs + "_BiasN", (double)g_pairs[ci].bias_n);
   GlobalVariableSet("GeneralMacro_" + cs + "_Conviction", (double)g_pairs[ci].conv);
   GlobalVariableSet("GeneralMacro_" + cs + "_Blackout", g_pairs[ci].blackout ? 1.0 : 0.0);
   if(g_pairs[ci].is_gold)
      PublishLegacy();
}

// Legacy v2.00 publishing, unchanged — written only on gold charts.
void PublishLegacy()
{
   GlobalVariableSet("GoldBias_N", (double)g_bias_n);
   GlobalVariableSet("GoldBias_Conviction", (double)g_conv);
   GlobalVariableSet("GoldBias_NewsBlackout", g_blackout ? 1.0 : 0.0);
   GlobalVariableSet("GoldBias_NewsRisk", g_news_risk ? 1.0 : 0.0);
   GlobalVariableSet("GoldBias_MinutesToNews", (double)g_mins_news);
}

// Legacy v2.00 gold_bias.ini, unchanged — written only on gold charts.
void WriteIni()
{
   int h = FileOpen("gold_bias.ini", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, "bias=" + g_bias + "\n");
   FileWriteString(h, "bias_n=" + IntegerToString(g_bias_n) + "\n");
   FileWriteString(h, "conviction=" + IntegerToString(g_conv) + "\n");
   FileWriteString(h, "session=" + g_session + "\n");
   FileWriteString(h, "as_of=" + g_asof + "\n");
   FileWriteString(h, "dollar_yields_agree=" + IntegerToString(g_agree ? 1 : 0) + "\n");
   FileWriteString(h, "news_blackout=" + IntegerToString(g_blackout ? 1 : 0) + "\n");
   FileWriteString(h, "news_risk=" + IntegerToString(g_news_risk ? 1 : 0) + "\n");
   FileWriteString(h, "next_news=" + g_next_news + "\n");
   FileWriteString(h, "next_news_when=" + g_next_when + "\n");
   FileWriteString(h, "minutes_to_news=" + IntegerToString(g_mins_news) + "\n");
   FileWriteString(h, "regime=" + g_regime + "\n");
   string pb = "";
   for(int i = 0; i < g_nplay; i++)
   {
      if(i > 0) pb += " | ";
      pb += g_play[i];
   }
   FileWriteString(h, "playbook=" + pb + "\n");
   FileClose(h);
}

void WriteGeneralIni()
{
   int h = FileOpen("general_macro.ini", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, "as_of=" + g_asof + "\n");
   FileWriteString(h, "session=" + g_session + "\n");
   FileWriteString(h, "chart_symbol=" + _Symbol + "\n");
   FileWriteString(h, "fetch_diag=" + g_fetch_diag + "\n");
   FileWriteString(h, "fund_check=" + g_fund_check + "\n");   // v4.2 XAU/USD-fund cross-check
   FileWriteString(h, "risk_sentiment=" + g_risk_sent + "\n");   // v4.3 gauge (display only)
   for(int k = 0; k < 2; k++)
   {
      string kk = g_idx[k].key;
      FileWriteString(h, "index_" + kk + "_px=" +
                      (g_idx[k].px_ok ? StringFormat("%+d", g_idx[k].px) : "n/a") + "\n");
      FileWriteString(h, "index_" + kk + "_fund=" +
                      (g_idx[k].fund_ok ? DoubleToString(g_idx[k].fund, 2) : "bldg") + "\n");
      FileWriteString(h, "index_" + kk + "_tot=" + DoubleToString(g_idx[k].tot, 2) + "\n");
   }
   for(int i = 0; i < ArraySize(g_pairs); i++)
   {
      string k = Sanitize(g_pairs[i].sym);
      FileWriteString(h, k + "_bias=" + g_pairs[i].bias + "\n");
      FileWriteString(h, k + "_bias_n=" + IntegerToString(g_pairs[i].bias_n) + "\n");
      FileWriteString(h, k + "_conviction=" + IntegerToString(g_pairs[i].conv) + "\n");
      FileWriteString(h, k + "_gap=" + DoubleToString(g_pairs[i].diff, 1) + "\n");
      FileWriteString(h, k + "_zone=" + g_pairs[i].tech.zone_text + "\n");
      FileWriteString(h, k + "_grade=" + GradeLetter(g_pairs[i].grade) + "\n");
      FileWriteString(h, k + "_blackout=" + IntegerToString(g_pairs[i].blackout ? 1 : 0) + "\n");
   }
   for(int i = 0; i < ArraySize(g_ccy); i++)
   {
      FileWriteString(h, "fund_" + g_ccy[i].code + "=" +
                      (g_ccy[i].fund_ok ? DoubleToString(g_ccy[i].fund, 2) : "bldg") + "\n");
      FileWriteString(h, "total_" + g_ccy[i].code + "=" + DoubleToString(g_ccy[i].strength, 2) + "\n");
   }
   FileClose(h);
}

// Compact fundamental marker for watchlist rows: f^ = base leg's
// FUND exceeds the quote leg's by > 0.75, fv = the reverse, f- =
// no real edge, "fund n/a" = neither leg has scored fund data yet.
// For gold the marker reads the USD leg (the pair's fundamental
// driver). v4.2: plain words instead of the v4.1 f^/fv/f-/f? glyphs
// (Mazi: "i do not understand the factor up and down"). "fund+"
// means the fundamental data trend (months) favors the pair's base
// side over its quote side; "fund-" the reverse; "fund flat" = no
// real fundamental edge either way.
string FundMarker(const PairState &q)
{
   if(q.is_index)
   {
      // v4.3: the marker reads the index's own fund (USD fund + the
      // rates overlay), against the same +/-0.5 band gold uses
      if(!q.idx_fund_ok) return "fund n/a";
      return (q.idx_fund > 0.5) ? "fund+" : (q.idx_fund < -0.5) ? "fund-" : "fund flat";
   }
   if(q.is_gold)
   {
      int ui = CcyIdx("USD");
      if(ui < 0 || !g_ccy[ui].fund_ok) return "fund n/a";
      return (g_ccy[ui].fund > 0.5) ? "fund+" : (g_ccy[ui].fund < -0.5) ? "fund-" : "fund flat";
   }
   int bi = CcyIdx(q.base), qi = CcyIdx(q.quote);
   if(bi < 0 || qi < 0) return "fund n/a";
   if(!g_ccy[bi].fund_ok && !g_ccy[qi].fund_ok) return "fund n/a";
   double fd = (g_ccy[bi].fund_ok ? g_ccy[bi].fund : 0.0) -
               (g_ccy[qi].fund_ok ? g_ccy[qi].fund : 0.0);
   return (fd > 0.75) ? "fund+" : (fd < -0.75) ? "fund-" : "fund flat";
}

// v4.6: characters that fit on one panel line at the ACTUAL panel
// width. The v4.x layout was designed at the InpWidth default of
// 520, but MT5 preserved the width saved from the old v2.00-era EA
// (430) across recompiles, and the hard-coded Wrap limits (84/76/74)
// overflowed the narrower panel - words clipped mid-word at the
// right edge ("gold longs fight the fu", "<<== ch", "vs firm daily
// limi"). 6.0px per char at font size 8 is deliberately
// conservative (covers DPI scaling); clamped so an extreme saved
// width cannot produce a silly budget. At 430 -> 67, at 520 -> 82.
int CharBudget()
{
   int b = (int)MathFloor((InpWidth - 28) / 6.0);
   if(b < 48) b = 48;
   if(b > 96) b = 96;
   return b;
}

//+------------------------------------------------------------------+
void DrawPanel(const string status)
{
   ScrubAllStrayObjects();   // v4.2: delete ANY default-text object first
   ScrubStrayLabels();       // v4.1: repair any default-text label objects

   color bg = C'12,18,32';
   color line = C'36,49,73';
   color tx = C'232,238,248';
   color mut = C'139,155,180';
   color grn = C'62,207,142';
   color red = C'227,93,106';
   color amb = C'230,184,77';

   int ci = ChartPairIdx();
   bool have = (ci >= 0);
   PairState p;
   Tech t;
   if(have)
   {
      p = g_pairs[ci];
      t = p.tech;
   }
   color acc = (have && p.bias_n > 0) ? grn : (have && p.bias_n < 0) ? red : amb;

   // v4.5: fitted height - the panel is always exactly as tall as
   // its content (PANEL_FIT_H); InpPanelH is legacy and ignored here
   const int fitH = PANEL_FIT_H;
   const int cb = CharBudget();   // v4.6: per-line char budget at the saved width
   Rect(PREF "bg", InpX, InpY, InpWidth, fitH, bg, line);
   Lab(PREF "t", InpX + 14, InpY + 10, "GENERAL MACRO BIAS v4.92", 11, mut);
   Lab(PREF "b", InpX + 14, InpY + 32,
       have ? (p.sym + "  " + p.bias + "   " + IntegerToString(p.conv) + "/100") : "-",
       18, acc);
   // v4.2 fund cross-check line, directly under the headline (gold
   // charts only; blank elsewhere): a strong USD data trend opposing
   // the gold bias is a CAUTION in amber, an aligned one is muted
   Lab(PREF "fx", InpX + 14, InpY + 56, (have && p.is_gold) ? g_fund_check_txt : "",
       8, g_fund_check_bad ? amb : mut);
   Lab(PREF "s", InpX + 14, InpY + 74, g_session + "   " + g_asof + "   " + status, 8, mut);

   string news = "news: none nearby for this pair";
   color nc = mut;
   if(have && p.blackout) { news = "NEWS BLACKOUT  " + p.next_news; nc = red; }
   else if(have && p.next_news != "")
   {
      news = "next HI (pair): " + p.next_news + "  " + p.next_when +
             "  (" + IntegerToString(p.mins_news) + "m)";
      nc = amb;
   }
   Lab(PREF "n", InpX + 14, InpY + 94, news, 9, nc);
   Lab(PREF "rg", InpX + 14, InpY + 112, "USD/vol (gold engine): " + g_regime, 8, mut);

   // v4.3 risk sentiment gauge: the two index price scores agree up
   // = RISK-ON, agree down = RISK-OFF, scored but split/flat =
   // MIXED, either unscored = n/a. Display only - by design it
   // feeds no bias, no gate leg and no size anywhere in v4.3.
   color rsc = (g_risk_sent == "RISK-ON") ? grn :
               (g_risk_sent == "RISK-OFF") ? red :
               (g_risk_sent == "MIXED") ? amb : mut;
   Lab(PREF "rs", InpX + 14, InpY + 130,
       "risk sentiment: " + g_risk_sent +
       "  (USTEC px " + (g_idx[0].px_ok ? StringFormat("%+d", g_idx[0].px) : "n/a") +
       ", US30 px " + (g_idx[1].px_ok ? StringFormat("%+d", g_idx[1].px) : "n/a") + ")",
       8, rsc);

   // v4.1 fetch diagnostics - high on the panel, always visible:
   // green-ish when every source answered, amber on a partial cycle,
   // red when a source is down (err 4060 = missing allowlist entry)
   color fdc = (g_fetch_health == 3) ? red : (g_fetch_health == 2) ? amb : mut;
   Lab(PREF "fd", InpX + 14, InpY + 148, Wrap(g_fetch_diag, cb), 8, fdc);

   // ---- watchlist, ranked ----
   Lab(PREF "wh", InpX + 14, InpY + 167, "WATCHLIST  (ranked: |gap| x in-zone)", 9, mut);
   for(int r = 0; r < 8; r++)
   {
      string row = "";
      color rc = tx;
      if(r < ArraySize(g_pairs))
      {
         PairState q = g_pairs[r];
         string zs = !q.tech.ok ? "no data" :
                     (q.tech.zone == 1) ? "BUY ZONE" :
                     (q.tech.zone == -1) ? "SELL ZONE" :
                     (q.tech.zone == 2 || q.tech.zone == -2) ? "OVERSHOT" : "mid-range";
         // v4.2 plain words: gold rows name their engine ("gold-engine
         // gap" - the XAU read comes from the factor engine, not a leg
         // diff); FX rows show the numeric strength gap of the two legs.
         // v4.3: index rows show "idx +x.x" - their total strength,
         // worded so it never implies a two-leg difference
         string gap = q.is_gold ? "gold-engine gap"
                      : q.is_index ? ("idx " + StringFormat("%+0.1f", q.idx_tot))
                      : ("gap " + StringFormat("%+0.1f", q.diff));
         // v4.6: the chart marker moves to directly after the symbol
         // name ("XAUUSD << LONG ...") and the trailing word "chart"
         // is dropped - at the saved width of 430 the end-of-row
         // marker was the first thing to clip ("<<== ch")
         string symf = q.sym + (q.is_chart ? " <<" : "");
         row = StringFormat("%-10s %-7s %3d  %-10s %s %s",
                            symf, q.bias, q.conv, zs, gap, FundMarker(q));
         rc = (q.bias_n > 0) ? grn : (q.bias_n < 0) ? red : amb;
         if(!q.tech.ok) rc = mut;
      }
      Lab(PREF "w" + IntegerToString(r), InpX + 14, InpY + 185 + r * 15, row, 8, rc);
   }

   // ---- strength ladder: a pure readout of computed strength ----
   Lab(PREF "lh", InpX + 14, InpY + 315,
       "STRENGTH LADDER  (px + fund = tot - from data)", 9, mut);
   datetime latestFund = 0;
   for(int i = 0; i < ArraySize(g_ccy); i++)
      if(g_ccy[i].fund_stamp > latestFund) latestFund = g_ccy[i].fund_stamp;
   string fl;
   color fc = mut;
   if(latestFund == 0)
      fl = "fund data: none scored yet - currencies read bldg until data lands";
   else if(TimeGMT() - latestFund <= 86400)
      fl = "fund data: last scored " + TimeToString(latestFund, TIME_DATE|TIME_MINUTES) + " - fresh (<24h)";
   else
   {
      fl = "fund data: last scored " + TimeToString(latestFund, TIME_DATE|TIME_MINUTES) +
           " - STALE (>24h), check the fetch line";
      fc = red;
   }
   Lab(PREF "ls", InpX + 14, InpY + 333, fl, 8, fc);
   int ord[];
   ArrayResize(ord, ArraySize(g_ccy));
   for(int i = 0; i < ArraySize(g_ccy); i++) ord[i] = i;
   for(int i = 0; i < ArraySize(ord) - 1; i++)
      for(int j = 0; j < ArraySize(ord) - 1 - i; j++)
         if(g_ccy[ord[j]].strength < g_ccy[ord[j + 1]].strength)
         {
            int tmp = ord[j];
            ord[j] = ord[j + 1];
            ord[j + 1] = tmp;
         }
   for(int r = 0; r < 8; r++)
   {
      int y = InpY + 351 + r * 18;
      if(r < ArraySize(ord))
      {
         int k = ord[r];
         string row = StringFormat("%d. %-4s px %+d   fund %-6s tot %+0.1f",
                                   r + 1, g_ccy[k].code, g_ccy[k].price_score,
                                   FundStr(g_ccy[k].code), g_ccy[k].strength);
         color rc = (g_ccy[k].strength > 0) ? grn : (g_ccy[k].strength < 0) ? red : amb;
         Lab(PREF "l" + IntegerToString(r), InpX + 14, y, row, 9, rc);
      }
      else
         Lab(PREF "l" + IntegerToString(r), InpX + 14, y, "", 9, tx);
   }

   // ---- framework detail for the chart symbol ----
   Lab(PREF "th", InpX + 14, InpY + 505,
       "FRAMEWORK - " + (have ? p.sym : _Symbol) + "  D1  BB(100) + band fib", 9, mut);
   if(have && t.ok)
   {
      Lab(PREF "k1", InpX + 14, InpY + 523,
          StringFormat("price %s   basis %s   SMA200 %s",
                       FmtPrice(p.rsym, t.price), FmtPrice(p.rsym, t.basis),
                       FmtPrice(p.rsym, t.sma200)), 8, tx);
      Lab(PREF "k2", InpX + 14, InpY + 538,
          StringFormat("upper %s   lower %s",
                       FmtPrice(p.rsym, t.upper), FmtPrice(p.rsym, t.lower)), 8, tx);
      Lab(PREF "k3", InpX + 14, InpY + 553,
          StringFormat("fib 50 %s   61.8 %s   78.6 %s",
                       FmtPrice(p.rsym, t.f50), FmtPrice(p.rsym, t.f618),
                       FmtPrice(p.rsym, t.f786)), 8, tx);
      Lab(PREF "k4", InpX + 14, InpY + 568, "regime: " + t.regime_label, 8,
          t.regime_change ? red : tx);
      Lab(PREF "k5", InpX + 14, InpY + 583,
          "zone: " + t.zone_text + "   confluence " + IntegerToString(t.confluence) + "/4",
          8, (t.zone == 1 || t.zone == -1) ? grn : tx);
      // v4.7: tightened format (single spaces, one headline RR at
      // one decimal) so the plan fits the 430-width budget whole:
      // 31 fixed chars + 4 prices + RR digits = gold 62, FX majors
      // 62, indices 66, absolute ceiling 67 (8-char prices AND an
      // rr2 >= 10 together). The RR shown is rr2 - the to-T2 R:R
      // the gate's WHAT leg enforces; the rr1/rr2 pair still
      // prints in full on the WHAT line itself. Wrapped at cb as
      // insurance only - it cannot trigger for the classes above.
      Lab(PREF "k6", InpX + 14, InpY + 598,
          Wrap(StringFormat("plan: entry %s stop %s T1 %s T2 %s R:R %.1f",
                            FmtPrice(p.rsym, t.entry), FmtPrice(p.rsym, t.stop),
                            FmtPrice(p.rsym, t.t1), FmtPrice(p.rsym, t.t2), t.rr2), cb), 8, tx);
   }
   else
   {
      Lab(PREF "k1", InpX + 14, InpY + 523, "framework: no D1 history yet for this symbol", 8, mut);
      Lab(PREF "k2", InpX + 14, InpY + 538, "", 8, tx);
      Lab(PREF "k3", InpX + 14, InpY + 553, "", 8, tx);
      Lab(PREF "k4", InpX + 14, InpY + 568, "", 8, tx);
      Lab(PREF "k5", InpX + 14, InpY + 583, "", 8, tx);
      Lab(PREF "k6", InpX + 14, InpY + 598, "", 8, tx);
   }

   // v4.1: per-pair news (next high-impact event per leg, with
   // countdown) and per-leg fundamentals/tilt for the chart pair.
   // v4.3: an index chart shows ONE leg - USD - on both lines: its
   // "pair news" is the USD calendar, its fund is the index fund.
   if(have)
   {
      string legB = (p.nb_mins >= 0)
                    ? (Trunc(p.nb_title, 20) + " " + p.nb_when + " (" + FmtCountdown(p.nb_mins) + ")")
                    : "no HI event this wk";
      string legQ = (p.nq_mins >= 0)
                    ? (Trunc(p.nq_title, 20) + " " + p.nq_when + " (" + FmtCountdown(p.nq_mins) + ")")
                    : "no HI event this wk";
      if(p.is_index)
         Lab(PREF "k7", InpX + 14, InpY + 613,
             Wrap(StringFormat("news USD: %s", legB), cb), 8, tx);
      else
         Lab(PREF "k7", InpX + 14, InpY + 613,
             Wrap(StringFormat("news %s: %s  |  %s: %s", p.base, legB, p.quote, legQ), cb), 8, tx);
      string k8;
      if(p.is_gold)
         k8 = StringFormat("fund XAU engine   USD %s  |  tilt %s / %s",
                           FundStr("USD"), p.tilt_b, p.tilt_q);
      else if(p.is_index)
         k8 = StringFormat("fund USD %s  ->  index %s (USD fund + rates overlay)  |  tilt %s",
                           FundStr("USD"),
                           p.idx_fund_ok ? StringFormat("%+0.1f", p.idx_fund) : "bldg",
                           p.tilt_b);
      else
         k8 = StringFormat("fund %s %s   %s %s  |  tilt %s / %s",
                           p.base, FundStr(p.base), p.quote, FundStr(p.quote),
                           p.tilt_b, p.tilt_q);
      Lab(PREF "k8", InpX + 14, InpY + 628, Wrap(k8, cb), 8, tx);
   }
   else
   {
      Lab(PREF "k7", InpX + 14, InpY + 613, "", 8, tx);
      Lab(PREF "k8", InpX + 14, InpY + 628, "", 8, tx);
   }

   // ---- gate ----
   // v4.6: gate text wraps at cb - 16: the longest "WHY    FAIL  "
   // style prefix measures 13 chars (all eight variants are exactly
   // 13), and Wrap() appends "..." (+3) when it truncates, so
   // 13 + (cb - 16) + 3 = cb - the rendered line can never exceed
   // the budget, prefix included
   Lab(PREF "gh", InpX + 14, InpY + 653, "GATE - Why / Where / When / What", 9, mut);
   Lab(PREF "g1", InpX + 14, InpY + 671, (g_why_ok ? "WHY    OK    " : "WHY    FAIL  ") + Wrap(g_why_txt, cb - 16), 8, g_why_ok ? tx : red);
   Lab(PREF "g2", InpX + 14, InpY + 686, (g_where_ok ? "WHERE  OK    " : "WHERE  FAIL  ") + Wrap(g_where_txt, cb - 16), 8, g_where_ok ? tx : red);
   Lab(PREF "g3", InpX + 14, InpY + 701, (g_when_ok ? "WHEN   OK    " : "WHEN   FAIL  ") + Wrap(g_when_txt, cb - 16), 8, g_when_ok ? tx : red);
   Lab(PREF "g4", InpX + 14, InpY + 716, (g_what_ok ? "WHAT   OK    " : "WHAT   FAIL  ") + Wrap(g_what_txt, cb - 16), 8, g_what_ok ? tx : red);
   Lab(PREF "gv", InpX + 14, InpY + 739, g_verdict, 11, g_setup_valid ? grn : red);

   // ---- risk ----
   Lab(PREF "rh", InpX + 14, InpY + 767, "RISK", 9, mut);
   Lab(PREF "rk1", InpX + 14, InpY + 785,
       StringFormat("grade %s   risk %.1f%%   size %s",
                    GradeLetter(g_grade), RiskPctForGrade(g_grade), g_size_txt), 8, tx);
   string rk2 = StringFormat("exposure deployed %.1f%% of %.1f%% max - headroom %.1f%%",
                             g_deployed_pct, InpMaxExposurePct,
                             InpMaxExposurePct - g_deployed_pct);
   if(g_unprotected > 0)
      rk2 += "   (" + IntegerToString(g_unprotected) + " open position(s) have NO stop - not counted)";
   Lab(PREF "rk2", InpX + 14, InpY + 800, Wrap(rk2, cb - 4), 8,
       (g_deployed_pct > InpMaxExposurePct) ? red : tx);
   // v4.6: shortened ("of equity" and "limit" wording dropped) and
   // wrapped at the budget - the old string ran 84 chars and clipped
   // to "vs firm daily limi" at the saved width of 430
   Lab(PREF "rk3", InpX + 14, InpY + 815,
       Wrap(StringFormat("worst case all stops hit: -%.1f%% vs firm daily limit %.1f%% (%s)",
                    g_deployed_pct, InpFirmDailyLossPct,
                    (g_deployed_pct <= InpFirmDailyLossPct) ? "inside" : "OVER"), cb),
       8, (g_deployed_pct <= InpFirmDailyLossPct) ? tx : red);

   // v4.3: the GOLD FACTORS (XAU leg) block is REMOVED from the
   // panel at Mazi's direction - display only. The engine still
   // computes every factor exactly as before and the factor data
   // still lands in gold_bias.ini / general_macro.ini. Delete the
   // old block's objects so an upgraded chart shows no ghost rows.
   ObjectDelete(0, PREF "fh");
   ObjectDelete(0, PREF "gg");
   for(int fi = 0; fi < 8; fi++)
      ObjectDelete(0, PREF "f" + IntegerToString(fi));

   // v4.4: the PLAYBOOK block is REMOVED from the panel at Mazi's
   // direction - display only. BuildPlaybook() still computes
   // g_play every cycle and the playbook= line still lands in
   // gold_bias.ini exactly as before. Delete the old block's
   // objects so an upgraded chart shows no ghost rows.
   for(int pi = 0; pi < 5; pi++)
      ObjectDelete(0, PREF "p" + IntegerToString(pi));

   // v4.2 legend, very bottom of the panel (plain words, one line)
   // v4.7: shortened 84 -> 60 chars so it fits the 430-width budget
   // (67) whole - it had clipped even at the designed 520 width
   // (budget 82). The days-vs-months distinction - the legend's
   // whole point - is preserved verbatim in shorter clothes.
   Lab(PREF "lg", InpX + 14, InpY + fitH - 68,
       "px=price (days) | fund=data (months) | tot=combined | !=turn", 8, mut);
   Lab(PREF "d", InpX + 14, InpY + fitH - 48,
       "Guide only - EA does not trade. Daily framework vetoes intraday breakouts.", 8, mut);

   if(ObjectFind(0, PREF "btn") < 0)
   {
      ObjectCreate(0, PREF "btn", OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, PREF "btn", OBJPROP_CORNER, InpCorner);
      ObjectSetInteger(0, PREF "btn", OBJPROP_XSIZE, 92);
      ObjectSetInteger(0, PREF "btn", OBJPROP_YSIZE, 22);
      ObjectSetInteger(0, PREF "btn", OBJPROP_BGCOLOR, C'30,80,160');
      ObjectSetInteger(0, PREF "btn", OBJPROP_COLOR, clrWhite);
   }
   // text is set on EVERY draw, not only at creation: a button whose
   // create/set sequence was ever interrupted would otherwise sit on
   // the chart forever with MQL5's default text (Problem 2)
   ObjectSetString(0, PREF "btn", OBJPROP_TEXT, "Refresh now");
   ObjectSetInteger(0, PREF "btn", OBJPROP_XDISTANCE, InpX + InpWidth - 108);
   ObjectSetInteger(0, PREF "btn", OBJPROP_YDISTANCE, InpY + 12);
   if(g_err != "")
      Lab(PREF "e", InpX + 14, InpY + fitH - 28, g_err, 8, red);
   ChartRedraw();
}

string Wrap(string s, int n)
{
   if(StringLen(s) <= n) return s;
   return StringSubstr(s, 0, n) + "...";
}

void Rect(const string name, int x, int y, int w, int h, color bg, color br)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, InpCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_COLOR, br);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void Lab(const string name, int x, int y, const string text, int sz, color c)
{
   // v4.92: empty text means "no label" - delete the object and
   // return. A freshly created OBJ_LABEL is born with the literal
   // text "Label", and setting "" on it does not stick in every
   // terminal build: in the v4.91 live run the conditional fx line
   // rendered its birth text whenever the fund cross-check was
   // neutral (see BUILD-NOTES). Call sites pass "" precisely to
   // blank a stale row - deletion produces the same blank, and no
   // object survives to resurrect the birth string on a later draw.
   if(text == "")
   {
      ObjectDelete(0, name);
      return;
   }
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      // text FIRST, in the same call sequence as the creation: a new
      // OBJ_LABEL is born with the literal text "Label", and it must
      // never survive its first draw (Problem 2)
      ObjectSetString(0, name, OBJPROP_TEXT, text);
   }
   ObjectSetInteger(0, name, OBJPROP_CORNER, InpCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, sz);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   // read-back repair: if the terminal did not take the text (the
   // object still shows something else), set it once more
   if(ObjectGetString(0, name, OBJPROP_TEXT) != text)
      ObjectSetString(0, name, OBJPROP_TEXT, text);
}
//+------------------------------------------------------------------+
