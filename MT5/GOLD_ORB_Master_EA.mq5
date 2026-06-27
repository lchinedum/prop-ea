//+------------------------------------------------------------------+
//| GOLD_ORB_Master_EA.mq5                                           |
//| Execution logic aligned with GOLD_ORB_Indicator.mq5 (same TF).  |
//| Single .mq5: Common + signal-bus + COT + SMC inlined (Trade includes only).|
//| M5 chart; ORB range from M15 (ORB_RANGE_TF). Match GOLD_ORB_Indicator. |
//+------------------------------------------------------------------+
#property copyright "GOLD_ORB_Master_EA"
#property version   "2.13"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

#define ORB_CHART_TF   PERIOD_M5   // signals, SMC, EMA — attach EA to M5
#define ORB_RANGE_TF   PERIOD_M15  // ORB session high/low only
#define ORB_EA_DASH_MAX_LABELS 32

//+------------------------------------------------------------------+
//| Inlined: Gold_ORB_COT + Gold_ORB_SMC + VolumeBreakoutFilter
//+------------------------------------------------------------------+

bool VBF_SpreadOK(const int maxSpreadPoints)
{
   if(maxSpreadPoints <= 0) return true;
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= maxSpreadPoints;
}

double VBF_AvgTickVolume(const string sym, const ENUM_TIMEFRAMES tf, const int shiftStart, const int period)
{
   if(period <= 0) return 0.0;
   long sum = 0;
   int count = 0;
   int bars = iBars(sym, tf);
   for(int i = shiftStart; i < shiftStart + period && i < bars; i++)
   {
      sum += (long)iTickVolume(sym, tf, i);
      count++;
   }
   return (count > 0) ? ((double)sum / (double)count) : 0.0;
}

bool VBF_PassesRelativeVolume(const string sym, const ENUM_TIMEFRAMES tf, const datetime signalBarTime,
                              const int avgPeriod, const double minRelMult)
{
   if(minRelMult <= 0.0 || avgPeriod <= 0) return true;
   int shSig = iBarShift(sym, tf, signalBarTime, false);
   if(shSig < 0) return false;
   long volSig = (long)iTickVolume(sym, tf, shSig);
   double avgVol = VBF_AvgTickVolume(sym, tf, shSig + 1, avgPeriod);
   if(avgVol <= 0.0) return (volSig > 0);
   return ((double)volSig >= avgVol * minRelMult);
}

bool VBF_PassesRisingVolume(const string sym, const ENUM_TIMEFRAMES tf, const datetime signalBarTime)
{
   int shSig = iBarShift(sym, tf, signalBarTime, false);
   if(shSig < 0) return false;
   int shPrev = shSig + 1;
   if(shPrev >= iBars(sym, tf)) return false;
   long volSig  = (long)iTickVolume(sym, tf, shSig);
   long volPrev = (long)iTickVolume(sym, tf, shPrev);
   return (volSig > volPrev);
}

bool VBF_PassesCandleStrength(const string sym, const ENUM_TIMEFRAMES tf, const datetime signalBarTime,
                              const bool isLong, const double minCloseFrac)
{
   if(minCloseFrac <= 0.0 || minCloseFrac >= 1.0) return true;
   int sh = iBarShift(sym, tf, signalBarTime, false);
   if(sh < 0) return false;
   double hi = iHigh(sym, tf, sh);
   double lo = iLow(sym, tf, sh);
   double cl = iClose(sym, tf, sh);
   double range = hi - lo;
   if(range <= 0.0) return true;
   double pos = (cl - lo) / range;
   if(isLong) return (pos >= minCloseFrac);
   return (pos <= (1.0 - minCloseFrac));
}

bool VBF_PassesBreakoutVolume(const string sym, const ENUM_TIMEFRAMES tf, const datetime signalBarTime,
                              const bool isLong,
                              const bool useFilter,
                              const int avgPeriod,
                              const double minRelMult,
                              const bool requireRising,
                              const bool useCandleStrength,
                              const double minCloseFrac)
{
   if(!useFilter) return true;
   if(signalBarTime <= 0) return false;
   if(requireRising && !VBF_PassesRisingVolume(sym, tf, signalBarTime)) return false;
   if(!VBF_PassesRelativeVolume(sym, tf, signalBarTime, avgPeriod, minRelMult)) return false;
   if(useCandleStrength && !VBF_PassesCandleStrength(sym, tf, signalBarTime, isLong, minCloseFrac)) return false;
   return true;
}

#define COT_MAX_ROWS 3000

datetime g_cot_dates[];
double   g_cot_net_nc[];
double   g_cot_net_c[];
int      g_cot_count = 0;
string   g_cot_last_load_msg = "";
string   g_cot_last_http_info = "";

//+------------------------------------------------------------------+
void COT_Clear()
{
   g_cot_count = 0;
   ArrayResize(g_cot_dates, 0);
   ArrayResize(g_cot_net_nc, 0);
   ArrayResize(g_cot_net_c, 0);
}

// Default: narrow CSV — Gold only, ASC by report date (Socrata API).
string COT_DefaultCftcGoldUrl()
{
   return "https://publicreporting.cftc.gov/resource/72hh-3qpy.csv?"
          "$select=report_date_as_yyyy_mm_dd,prod_merc_positions_long,prod_merc_positions_short,"
          "m_money_positions_long_all,m_money_positions_short_all&"
          "$where=cftc_contract_market_code=%27088691%27&"
          "$order=report_date_as_yyyy_mm_dd%20ASC&"
          "$limit=10000";
}

//+------------------------------------------------------------------+
datetime COT_ParseReportDateToken(const string tokenRaw)
{
   string t = tokenRaw;
   StringTrimLeft(t);
   StringTrimRight(t);
   StringReplace(t, "\"", "");
   int tpos = StringFind(t, "T");
   if(tpos > 0)
      t = StringSubstr(t, 0, tpos);
   if(StringLen(t) >= 10)
      t = StringSubstr(t, 0, 10);
   StringReplace(t, "-", ".");
   datetime d = StringToTime(t);
   return d;
}

//+------------------------------------------------------------------+
bool COT_ParseCftcNarrowCsvBody(const string body)
{
   COT_Clear();
   if(StringLen(body) < 20) return false;

   int pos = 0;
   int lineNo = 0;
   while(pos < StringLen(body) && g_cot_count < COT_MAX_ROWS)
   {
      int nl = StringFind(body, "\n", pos);
      string line;
      if(nl < 0)
      {
         line = StringSubstr(body, pos);
         pos = StringLen(body);
      }
      else
      {
         line = StringSubstr(body, pos, nl - pos);
         pos = nl + 1;
      }
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) == 0) continue;

      lineNo++;
      if(lineNo == 1)
      {
         if(StringFind(line, "report_date") < 0 && StringFind(line, "report_date_as_yyyy_mm_dd") < 0)
            return false;
         continue;
      }

      StringReplace(line, "\"", "");
      string fld[];
      int nf = StringSplit(line, ',', fld);
      if(nf < 5) continue;

      datetime rd = COT_ParseReportDateToken(fld[0]);
      if(rd <= 0) continue;

      double pl = StringToDouble(fld[1]);
      double ps = StringToDouble(fld[2]);
      double ml = StringToDouble(fld[3]);
      double ms = StringToDouble(fld[4]);

      double netComm = pl - ps;
      double netNc = ml - ms;

      ArrayResize(g_cot_dates, g_cot_count + 1);
      ArrayResize(g_cot_net_nc, g_cot_count + 1);
      ArrayResize(g_cot_net_c, g_cot_count + 1);
      g_cot_dates[g_cot_count] = rd;
      g_cot_net_nc[g_cot_count] = netNc;
      g_cot_net_c[g_cot_count] = netComm;
      g_cot_count++;
   }

   return (g_cot_count > 0);
}

//+------------------------------------------------------------------+
bool COT_SaveToFile(const string filename, const bool useCommonFolder)
{
   if(g_cot_count <= 0 || StringLen(filename) == 0) return false;

   int flags = FILE_WRITE | FILE_TXT | FILE_ANSI;
   if(useCommonFolder)
      flags |= FILE_COMMON;

   int h = FileOpen(filename, flags);
   if(h == INVALID_HANDLE)
      return false;

   FileWriteString(h, "# CFTC disaggregated GOLD 088691 — managed $ net, prod/merc net\n");
   FileWriteString(h, "date,net_noncommercial,net_commercial\n");
   for(int i = 0; i < g_cot_count; i++)
   {
      string row = TimeToString(g_cot_dates[i], TIME_DATE) + ","
         + DoubleToString(g_cot_net_nc[i], 0) + ","
         + DoubleToString(g_cot_net_c[i], 0) + "\n";
      FileWriteString(h, row);
   }
   FileClose(h);
   return true;
}

//+------------------------------------------------------------------+
void COT_SortAscending()
{
   for(int i = 0; i < g_cot_count - 1; i++)
   {
      for(int j = i + 1; j < g_cot_count; j++)
      {
         if(g_cot_dates[i] > g_cot_dates[j])
         {
            datetime td = g_cot_dates[i];
            g_cot_dates[i] = g_cot_dates[j];
            g_cot_dates[j] = td;
            double a = g_cot_net_nc[i];
            g_cot_net_nc[i] = g_cot_net_nc[j];
            g_cot_net_nc[j] = a;
            double b = g_cot_net_c[i];
            g_cot_net_c[i] = g_cot_net_c[j];
            g_cot_net_c[j] = b;
         }
      }
   }
}

//+------------------------------------------------------------------+
// Returns true if rows loaded. WebRequest must be allowed for URL.
//+------------------------------------------------------------------+
bool COT_FetchCftcGoldWeb(const int timeoutMs, const string urlOverride, const bool saveCache,
                          const string cacheFilename, const bool cacheCommon)
{
   g_cot_last_http_info = "";

   if(MQLInfoInteger(MQL_TESTER) != 0)
   {
      g_cot_last_load_msg = "COT: web fetch skipped in Strategy Tester";
      return false;
   }

   string url = urlOverride;
   if(StringLen(url) == 0)
      url = COT_DefaultCftcGoldUrl();

   char post[];
   char result[];
   string respHeaders;
   ArrayResize(post, 0);

   ResetLastError();
   int code = WebRequest("GET", url, "", timeoutMs, post, result, respHeaders);
   g_cot_last_http_info = "HTTP " + IntegerToString(code) + " | " + respHeaders;

   if(code == -1)
   {
      int err = GetLastError();
      g_cot_last_load_msg = "COT: WebRequest failed err=" + IntegerToString(err)
         + " (add https://publicreporting.cftc.gov in Terminal → Options → Experts)";
      return false;
   }

   if(code != 200)
   {
      g_cot_last_load_msg = "COT: HTTP " + IntegerToString(code);
      return false;
   }

   int bodyStart = 0;
   if(ArraySize(result) >= 3 && (uchar)result[0] == 0xEF && (uchar)result[1] == 0xBB && (uchar)result[2] == 0xBF)
      bodyStart = 3;
   string body = CharArrayToString(result, bodyStart);

   if(!COT_ParseCftcNarrowCsvBody(body))
   {
      g_cot_last_load_msg = "COT: empty or parse error from API";
      return false;
   }

   COT_SortAscending();
   g_cot_last_load_msg = "COT: API " + IntegerToString(g_cot_count) + " rows (CFTC disagg GOLD)";

   if(saveCache && StringLen(cacheFilename) > 0)
   {
      if(COT_SaveToFile(cacheFilename, cacheCommon))
         g_cot_last_load_msg += " | cached " + cacheFilename;
   }
   return true;
}

//+------------------------------------------------------------------+
// Try web first when auto=true; else or on failure load CSV file.
//+------------------------------------------------------------------+
bool COT_LoadAutoOrFile(const bool autoFetch, const int webTimeoutMs, const string webUrlOverride,
                        const string filename, const bool useCommonFolder)
{
   if(autoFetch)
   {
      if(COT_FetchCftcGoldWeb(webTimeoutMs, webUrlOverride, true, filename, useCommonFolder))
         return true;
   }
   return COT_LoadFromFile(filename, useCommonFolder);
}

//+------------------------------------------------------------------+
bool COT_ParseLineDate(const string raw, datetime &outDt)
{
   string s = raw;
   StringTrimLeft(s);
   StringTrimRight(s);
   if(StringLen(s) < 8) return false;
   StringReplace(s, "-", ".");
   // Allow first token only if line has extra chars
   int comma = StringFind(s, ",");
   if(comma > 0) s = StringSubstr(s, 0, comma);
   StringTrimRight(s);
   outDt = StringToTime(s);
   return (outDt > 0);
}

//+------------------------------------------------------------------+
bool COT_LoadFromFile(const string filename, const bool useCommonFolder)
{
   COT_Clear();

   if(StringLen(filename) == 0)
   {
      g_cot_last_load_msg = "COT: empty filename";
      return false;
   }

   int flags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(useCommonFolder)
      flags |= FILE_COMMON;

   int h = FileOpen(filename, flags);
   if(h == INVALID_HANDLE)
   {
      g_cot_last_load_msg = "COT: cannot open " + filename + " err=" + IntegerToString(GetLastError());
      return false;
   }

   bool headerSkipped = false;
   while(!FileIsEnding(h) && g_cot_count < COT_MAX_ROWS)
   {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) == 0) continue;
      if(StringGetCharacter(line, 0) == '#') continue;

      string p[];
      int n = StringSplit(line, ',', p);
      if(n < 2) continue;

      string low0 = p[0];
      StringToLower(low0);
      if(StringFind(low0, "date") >= 0 && !headerSkipped)
      {
         headerSkipped = true;
         continue;
      }

      datetime rd = 0;
      if(!COT_ParseLineDate(p[0], rd)) continue;

      double nnc = StringToDouble(p[1]);
      double nco = 0;
      if(n >= 3)
         nco = StringToDouble(p[2]);

      ArrayResize(g_cot_dates, g_cot_count + 1);
      ArrayResize(g_cot_net_nc, g_cot_count + 1);
      ArrayResize(g_cot_net_c, g_cot_count + 1);
      g_cot_dates[g_cot_count] = rd;
      g_cot_net_nc[g_cot_count] = nnc;
      g_cot_net_c[g_cot_count] = nco;
      g_cot_count++;
   }

   FileClose(h);

   if(g_cot_count == 0)
   {
      g_cot_last_load_msg = "COT: no valid rows in " + filename;
      return false;
   }

   COT_SortAscending();
   g_cot_last_load_msg = "COT: loaded " + IntegerToString(g_cot_count) + " rows from " + filename;
   return true;
}

//+------------------------------------------------------------------+
// Latest report with report date <= bar calendar day (00:00).
//+------------------------------------------------------------------+
bool COT_GetSnapshotForDay(const datetime barDayOrAny,
                           double &net_noncomm,
                           double &net_comm,
                           datetime &reportDate,
                           double &delta_noncomm_prev,
                           bool &haveRow)
{
   net_noncomm = 0;
   net_comm = 0;
   reportDate = 0;
   delta_noncomm_prev = 0;
   haveRow = false;

   if(g_cot_count <= 0) return false;

   datetime day0 = StringToTime(TimeToString(barDayOrAny, TIME_DATE));
   int idx = -1;
   for(int i = g_cot_count - 1; i >= 0; i--)
   {
      if(g_cot_dates[i] <= day0)
      {
         idx = i;
         break;
      }
   }

   if(idx < 0) return false;

   haveRow = true;
   reportDate = g_cot_dates[idx];
   net_noncomm = g_cot_net_nc[idx];
   net_comm = g_cot_net_c[idx];
   if(idx > 0)
      delta_noncomm_prev = g_cot_net_nc[idx] - g_cot_net_nc[idx - 1];
   else
      delta_noncomm_prev = 0;
   return true;
}

//+------------------------------------------------------------------+
string COT_FormatBias(const double net_noncomm, const double neutralAbs)
{
   double a = MathAbs(neutralAbs);
   if(net_noncomm > a)  return "SPEC LONG";
   if(net_noncomm < -a) return "SPEC SHORT";
   return "SPEC NEUTRAL";
}

//+------------------------------------------------------------------+
// dir: +1 long, -1 short. mode 0 = off (always true).
// mode 1 = align: long if net >= -band, short if net <= +band.
// mode 2 = strict: long only if net > minNet, short only if net < -minNet.
//+------------------------------------------------------------------+
bool COT_PassesDirectionFilter(const int dir,
                               const int mode,
                               const double neutralBand,
                               const double minAbsNet,
                               const datetime barTime,
                               string &reason)
{
   reason = "";
   if(mode == 0) return true;

   double nnc = 0, nc = 0, dlt = 0;
   datetime rd = 0;
   bool have = false;
   if(!COT_GetSnapshotForDay(barTime, nnc, nc, rd, dlt, have) || !have)
   {
      reason = "no COT row";
      return true; // fail-open: do not block trading without data
   }

   if(mode == 1)
   {
      double b = MathAbs(neutralBand);
      if(dir > 0)
      {
         bool ok = (nnc >= -b);
         if(!ok) reason = "net " + DoubleToString(nnc, 0) + " vs long";
         return ok;
      }
      if(dir < 0)
      {
         bool ok = (nnc <= b);
         if(!ok) reason = "net " + DoubleToString(nnc, 0) + " vs short";
         return ok;
      }
      return false;
   }

   if(mode == 2)
   {
      double m = MathAbs(minAbsNet);
      if(dir > 0)
      {
         bool ok = (nnc > m);
         if(!ok) reason = "strict long needs net > " + DoubleToString(m, 0);
         return ok;
      }
      if(dir < 0)
      {
         bool ok = (nnc < -m);
         if(!ok) reason = "strict short needs net < " + DoubleToString(-m, 0);
         return ok;
      }
      return false;
   }

   return true;
}

struct SMCScoreResult
{
   int    score;
   int    maxScore;
   string tag;
};

//+------------------------------------------------------------------+
double SMC_Body(const double o, const double c) { return MathAbs(c - o); }

double SMC_RangeSym(const string sym, const double h, const double l)
{
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   return MathMax(h - l, pt * 5.0);
}

//+------------------------------------------------------------------+
// ATR value at shift (MQL5: iATR returns handle; value via CopyBuffer).
//+------------------------------------------------------------------+
double SMC_AtrValue(const string sym, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int h = iATR(sym, tf, period);
   if(h == INVALID_HANDLE) return 0.0;
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(h, 0, shift, 1, b) != 1)
   {
      IndicatorRelease(h);
      return 0.0;
   }
   double v = b[0];
   IndicatorRelease(h);
   return v;
}

//+------------------------------------------------------------------+
// Bullish FVG: gap between wick high of bar[shift+2] and wick low of bar[shift].
//+------------------------------------------------------------------+
bool SMC_BullishFVGAt(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
{
   if(shift < 1) return false;
   double h3 = iHigh(sym, tf, shift + 2);
   double l1 = iLow(sym, tf, shift);
   if(h3 <= 0 || l1 <= 0) return false;
   return (l1 > h3);
}

bool SMC_BearishFVGAt(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
{
   if(shift < 1) return false;
   double l3 = iLow(sym, tf, shift + 2);
   double h1 = iHigh(sym, tf, shift);
   if(l3 <= 0 || h1 <= 0) return false;
   return (h1 < l3);
}

//+------------------------------------------------------------------+
bool SMC_BullishPinBar(const string sym, const ENUM_TIMEFRAMES tf, const int sh)
{
   double o = iOpen(sym, tf, sh), c = iClose(sym, tf, sh);
   double h = iHigh(sym, tf, sh), l = iLow(sym, tf, sh);
   double body = SMC_Body(o, c);
   double range = SMC_RangeSym(sym, h, l);
   if(range <= 0 || c < o) return false;
   double lowerWick = MathMin(o, c) - l;
   return (lowerWick >= body * 2.0 && body <= range * 0.35);
}

bool SMC_BearishPinBar(const string sym, const ENUM_TIMEFRAMES tf, const int sh)
{
   double o = iOpen(sym, tf, sh), c = iClose(sym, tf, sh);
   double h = iHigh(sym, tf, sh), l = iLow(sym, tf, sh);
   double body = SMC_Body(o, c);
   double range = SMC_RangeSym(sym, h, l);
   if(range <= 0 || c > o) return false;
   double upperWick = h - MathMax(o, c);
   return (upperWick >= body * 2.0 && body <= range * 0.35);
}

//+------------------------------------------------------------------+
bool SMC_DojiAt(const string sym, const ENUM_TIMEFRAMES tf, const int sh, const double maxBodyPct)
{
   double o = iOpen(sym, tf, sh), c = iClose(sym, tf, sh);
   double h = iHigh(sym, tf, sh), l = iLow(sym, tf, sh);
   double range = SMC_RangeSym(sym, h, l);
   return (SMC_Body(o, c) <= range * maxBodyPct);
}

//+------------------------------------------------------------------+
bool SMC_BullishEngulfing(const string sym, const ENUM_TIMEFRAMES tf, const int sh)
{
   double o1 = iOpen(sym, tf, sh), c1 = iClose(sym, tf, sh);
   double o2 = iOpen(sym, tf, sh + 1), c2 = iClose(sym, tf, sh + 1);
   if(c2 >= o2) return false;
   if(c1 <= o1) return false;
   return (c1 >= o2 && o1 <= c2 && (c1 - o1) > (o2 - c2));
}

bool SMC_BearishEngulfing(const string sym, const ENUM_TIMEFRAMES tf, const int sh)
{
   double o1 = iOpen(sym, tf, sh), c1 = iClose(sym, tf, sh);
   double o2 = iOpen(sym, tf, sh + 1), c2 = iClose(sym, tf, sh + 1);
   if(c2 <= o2) return false;
   if(c1 >= o1) return false;
   return (o1 >= c2 && c1 <= o2 && (o1 - c1) > (c2 - o2));
}

//+------------------------------------------------------------------+
bool SMC_TweezerBottom(const string sym, const ENUM_TIMEFRAMES tf, const int sh, const double tolPrice)
{
   double l1 = iLow(sym, tf, sh);
   double l2 = iLow(sym, tf, sh + 1);
   return (MathAbs(l1 - l2) <= tolPrice);
}

bool SMC_TweezerTop(const string sym, const ENUM_TIMEFRAMES tf, const int sh, const double tolPrice)
{
   double h1 = iHigh(sym, tf, sh);
   double h2 = iHigh(sym, tf, sh + 1);
   return (MathAbs(h1 - h2) <= tolPrice);
}

//+------------------------------------------------------------------+
// Sweep: wick pierces recent swing extreme then closes back inside.
//+------------------------------------------------------------------+
bool SMC_BullishLiquidityGrab(const string sym, const ENUM_TIMEFRAMES tf, const int lookback, const int tolBars)
{
   int from = 3;
   int to = MathMax(from + 1, lookback);
   double swingLow = iLow(sym, tf, from);
   for(int i = from; i <= to; i++)
   {
      double v = iLow(sym, tf, i);
      if(v < swingLow) swingLow = v;
   }
   double l1 = iLow(sym, tf, 1), c1 = iClose(sym, tf, 1);
   if(swingLow <= 0) return false;
   return (l1 < swingLow && c1 > swingLow);
}

bool SMC_BearishLiquidityGrab(const string sym, const ENUM_TIMEFRAMES tf, const int lookback, const int tolBars)
{
   int from = 3;
   int to = MathMax(from + 1, lookback);
   double swingHigh = iHigh(sym, tf, from);
   for(int i = from; i <= to; i++)
   {
      double v = iHigh(sym, tf, i);
      if(v > swingHigh) swingHigh = v;
   }
   double h1 = iHigh(sym, tf, 1), c1 = iClose(sym, tf, 1);
   if(swingHigh <= 0) return false;
   return (h1 > swingHigh && c1 < swingHigh);
}

//+------------------------------------------------------------------+
// "Normal OB": small bearish bar then strong bullish impulse (bar 1).
//+------------------------------------------------------------------+
bool SMC_NormalBullOB(const string sym, const ENUM_TIMEFRAMES tf, const double atrMult)
{
   double o2 = iOpen(sym, tf, 2), c2 = iClose(sym, tf, 2);
   double o1 = iOpen(sym, tf, 1), c1 = iClose(sym, tf, 1);
   if(c2 >= o2) return false;
   if(c1 <= o1) return false;
   double atr = SMC_AtrValue(sym, tf, 14, 1);
   if(atr <= 0) return false;
   double body1 = c1 - o1;
   double body2 = o2 - c2;
   return (body1 >= atr * atrMult && body2 < body1 * 0.55);
}

bool SMC_NormalBearOB(const string sym, const ENUM_TIMEFRAMES tf, const double atrMult)
{
   double o2 = iOpen(sym, tf, 2), c2 = iClose(sym, tf, 2);
   double o1 = iOpen(sym, tf, 1), c1 = iClose(sym, tf, 1);
   if(c2 <= o2) return false;
   if(c1 >= o1) return false;
   double atr = SMC_AtrValue(sym, tf, 14, 1);
   if(atr <= 0) return false;
   double body1 = o1 - c1;
   double body2 = c2 - o2;
   return (body1 >= atr * atrMult && body2 < body1 * 0.55);
}

//+------------------------------------------------------------------+
// Manipulation: tiny body green, sweeps prior lows, then closes up.
//+------------------------------------------------------------------+
bool SMC_ManipBullish(const string sym, const ENUM_TIMEFRAMES tf)
{
   double o1 = iOpen(sym, tf, 1), c1 = iClose(sym, tf, 1);
   double h1 = iHigh(sym, tf, 1), l1 = iLow(sym, tf, 1);
   if(c1 <= o1) return false;
   double range = SMC_RangeSym(sym, h1, l1);
   double body = c1 - o1;
   if(body > range * 0.45) return false;
   double l2 = iLow(sym, tf, 2), l3 = iLow(sym, tf, 3);
   return (l1 < l2 && l1 < l3 && c1 > iClose(sym, tf, 2));
}

bool SMC_ManipBearish(const string sym, const ENUM_TIMEFRAMES tf)
{
   double o1 = iOpen(sym, tf, 1), c1 = iClose(sym, tf, 1);
   double h1 = iHigh(sym, tf, 1), l1 = iLow(sym, tf, 1);
   if(c1 >= o1) return false;
   double range = SMC_RangeSym(sym, h1, l1);
   double body = o1 - c1;
   if(body > range * 0.45) return false;
   double h2 = iHigh(sym, tf, 2), h3 = iHigh(sym, tf, 3);
   return (h1 > h2 && h1 > h3 && c1 < iClose(sym, tf, 2));
}

//+------------------------------------------------------------------+
// MSS (simplified): last closed broke above recent swing high (bullish).
//+------------------------------------------------------------------+
bool SMC_BullishMSSSimple(const string sym, const ENUM_TIMEFRAMES tf, const int lookback)
{
   double c1 = iClose(sym, tf, 1);
   int to = lookback;
   double sh = iHigh(sym, tf, 2);
   for(int i = 3; i <= to; i++)
   {
      double v = iHigh(sym, tf, i);
      if(v > sh) sh = v;
   }
   return (c1 > sh);
}

bool SMC_BearishMSSSimple(const string sym, const ENUM_TIMEFRAMES tf, const int lookback)
{
   double c1 = iClose(sym, tf, 1);
   int to = lookback;
   double sl = iLow(sym, tf, 2);
   for(int i = 3; i <= to; i++)
   {
      double v = iLow(sym, tf, i);
      if(v < sl) sl = v;
   }
   return (c1 < sl);
}

//+------------------------------------------------------------------+
// OTE: close in 62–79% retrace of swing high/low over lookback (discount for longs).
//+------------------------------------------------------------------+
bool SMC_LongInOTE(const string sym, const ENUM_TIMEFRAMES tf, const int lookback,
                   const double fibLo, const double fibHi)
{
   int a = 1, b = lookback;
   double hi = iHigh(sym, tf, a), lo = iLow(sym, tf, a);
   for(int i = a; i <= b; i++)
   {
      double h = iHigh(sym, tf, i), l = iLow(sym, tf, i);
      if(h > hi) hi = h;
      if(l < lo) lo = l;
   }
   double range = hi - lo;
   if(range <= 0) return false;
   double c1 = iClose(sym, tf, 1);
   // Discount OTE: retrace fibLo..fibHi from swing high toward low (e.g. 0.62–0.79)
   double zoneHi = hi - fibLo * range;
   double zoneLo = hi - fibHi * range;
   if(zoneLo > zoneHi) { double t = zoneLo; zoneLo = zoneHi; zoneHi = t; }
   return (c1 >= zoneLo && c1 <= zoneHi);
}

bool SMC_ShortInOTE(const string sym, const ENUM_TIMEFRAMES tf, const int lookback,
                    const double fibLo, const double fibHi)
{
   int a = 1, b = lookback;
   double hi = iHigh(sym, tf, a), lo = iLow(sym, tf, a);
   for(int i = a; i <= b; i++)
   {
      double h = iHigh(sym, tf, i), l = iLow(sym, tf, i);
      if(h > hi) hi = h;
      if(l < lo) lo = l;
   }
   double range = hi - lo;
   if(range <= 0) return false;
   double c1 = iClose(sym, tf, 1);
   double zoneLo = lo + fibLo * range;
   double zoneHi = lo + fibHi * range;
   if(zoneLo > zoneHi) { double t = zoneLo; zoneLo = zoneHi; zoneHi = t; }
   return (c1 >= zoneLo && c1 <= zoneHi);
}

//+------------------------------------------------------------------+
void SMC_ScoreLong(const string sym, const ENUM_TIMEFRAMES tf,
                   const int lookback, const double atrMultImpulse,
                   const double tweezerTolPoints, const double dojiBodyPct,
                   const bool useFvg, const bool usePin, const bool useDoji, const bool useEng,
                   const bool useTweezer, const bool useLq, const bool useNormalOb,
                   const bool useManip, const bool useMss, const bool useOte,
                   SMCScoreResult &out)
{
   out.score = 0;
   out.maxScore = 0;
   out.tag = "";

   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   double tol = tweezerTolPoints * pt;
   if(StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0)
      tol = MathMax(tol, pt * 10.0);

   string bits = "";

   bool anyFvg = false;
   if(useFvg)
   {
      out.maxScore++;
      for(int s = 1; s <= 8 && !anyFvg; s++)
      {
         if(SMC_BullishFVGAt(sym, tf, s))
            anyFvg = true;
      }
      if(anyFvg) { out.score++; bits += "FVG"; }
   }

   bool pin = false;
   if(usePin)
   {
      out.maxScore++;
      for(int s = 2; s <= 12 && !pin; s++)
      {
         if(SMC_BullishPinBar(sym, tf, s))
            pin = true;
      }
      if(pin) { out.score++; bits += (bits == "" ? "" : "+") + "Pin"; }
   }

   bool doji = false;
   if(useDoji)
   {
      out.maxScore++;
      for(int s = 2; s <= 10 && !doji; s++)
      {
         if(SMC_DojiAt(sym, tf, s, dojiBodyPct))
            doji = true;
      }
      if(doji) { out.score++; bits += (bits == "" ? "" : "+") + "Doji"; }
   }

   if(useEng)
   {
      out.maxScore++;
      bool eng = SMC_BullishEngulfing(sym, tf, 1) || SMC_BullishEngulfing(sym, tf, 2);
      if(eng) { out.score++; bits += (bits == "" ? "" : "+") + "Eng"; }
   }

   if(useTweezer)
   {
      out.maxScore++;
      bool tw = SMC_TweezerBottom(sym, tf, 1, tol) || SMC_TweezerBottom(sym, tf, 2, tol);
      if(tw) { out.score++; bits += (bits == "" ? "" : "+") + "Twz"; }
   }

   if(useLq)
   {
      out.maxScore++;
      bool lq = SMC_BullishLiquidityGrab(sym, tf, lookback, 3);
      if(lq) { out.score++; bits += (bits == "" ? "" : "+") + "LQ"; }
   }

   if(useNormalOb)
   {
      out.maxScore++;
      bool nrm = SMC_NormalBullOB(sym, tf, atrMultImpulse);
      if(nrm) { out.score++; bits += (bits == "" ? "" : "+") + "OB"; }
   }

   if(useManip)
   {
      out.maxScore++;
      bool man = SMC_ManipBullish(sym, tf);
      if(man) { out.score++; bits += (bits == "" ? "" : "+") + "Manip"; }
   }

   if(useMss)
   {
      out.maxScore++;
      bool mss = SMC_BullishMSSSimple(sym, tf, lookback);
      if(mss) { out.score++; bits += (bits == "" ? "" : "+") + "MSS"; }
   }

   if(useOte)
   {
      out.maxScore++;
      bool ote = SMC_LongInOTE(sym, tf, lookback, 0.62, 0.79);
      if(ote) { out.score++; bits += (bits == "" ? "" : "+") + "OTE"; }
   }

   out.tag = bits;
}

//+------------------------------------------------------------------+
void SMC_ScoreShort(const string sym, const ENUM_TIMEFRAMES tf,
                    const int lookback, const double atrMultImpulse,
                    const double tweezerTolPoints, const double dojiBodyPct,
                    const bool useFvg, const bool usePin, const bool useDoji, const bool useEng,
                    const bool useTweezer, const bool useLq, const bool useNormalOb,
                    const bool useManip, const bool useMss, const bool useOte,
                    SMCScoreResult &out)
{
   out.score = 0;
   out.maxScore = 0;
   out.tag = "";

   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   double tol = tweezerTolPoints * pt;
   if(StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0)
      tol = MathMax(tol, pt * 10.0);

   string bits = "";

   bool anyFvg = false;
   if(useFvg)
   {
      out.maxScore++;
      for(int s = 1; s <= 8 && !anyFvg; s++)
      {
         if(SMC_BearishFVGAt(sym, tf, s))
            anyFvg = true;
      }
      if(anyFvg) { out.score++; bits += "FVG"; }
   }

   bool pin = false;
   if(usePin)
   {
      out.maxScore++;
      for(int s = 2; s <= 12 && !pin; s++)
      {
         if(SMC_BearishPinBar(sym, tf, s))
            pin = true;
      }
      if(pin) { out.score++; bits += (bits == "" ? "" : "+") + "Pin"; }
   }

   bool doji = false;
   if(useDoji)
   {
      out.maxScore++;
      for(int s = 2; s <= 10 && !doji; s++)
      {
         if(SMC_DojiAt(sym, tf, s, dojiBodyPct))
            doji = true;
      }
      if(doji) { out.score++; bits += (bits == "" ? "" : "+") + "Doji"; }
   }

   if(useEng)
   {
      out.maxScore++;
      bool eng = SMC_BearishEngulfing(sym, tf, 1) || SMC_BearishEngulfing(sym, tf, 2);
      if(eng) { out.score++; bits += (bits == "" ? "" : "+") + "Eng"; }
   }

   if(useTweezer)
   {
      out.maxScore++;
      bool tw = SMC_TweezerTop(sym, tf, 1, tol) || SMC_TweezerTop(sym, tf, 2, tol);
      if(tw) { out.score++; bits += (bits == "" ? "" : "+") + "Twz"; }
   }

   if(useLq)
   {
      out.maxScore++;
      bool lq = SMC_BearishLiquidityGrab(sym, tf, lookback, 3);
      if(lq) { out.score++; bits += (bits == "" ? "" : "+") + "LQ"; }
   }

   if(useNormalOb)
   {
      out.maxScore++;
      bool nrm = SMC_NormalBearOB(sym, tf, atrMultImpulse);
      if(nrm) { out.score++; bits += (bits == "" ? "" : "+") + "OB"; }
   }

   if(useManip)
   {
      out.maxScore++;
      bool man = SMC_ManipBearish(sym, tf);
      if(man) { out.score++; bits += (bits == "" ? "" : "+") + "Manip"; }
   }

   if(useMss)
   {
      out.maxScore++;
      bool mss = SMC_BearishMSSSimple(sym, tf, lookback);
      if(mss) { out.score++; bits += (bits == "" ? "" : "+") + "MSS"; }
   }

   if(useOte)
   {
      out.maxScore++;
      bool ote = SMC_ShortInOTE(sym, tf, lookback, 0.62, 0.79);
      if(ote) { out.score++; bits += (bits == "" ? "" : "+") + "OTE"; }
   }

   out.tag = bits;
}

//+------------------------------------------------------------------+
bool SMC_PassesLongFilter(const string sym, const ENUM_TIMEFRAMES tf,
                          const int lookback, const int minScore,
                          const double atrMultImpulse, const double tweezerTolPoints,
                          const double dojiBodyPct,
                          const bool useFvg, const bool usePin, const bool useDoji, const bool useEng,
                          const bool useTweezer, const bool useLq, const bool useNormalOb,
                          const bool useManip, const bool useMss, const bool useOte,
                          SMCScoreResult &detail)
{
   SMC_ScoreLong(sym, tf, lookback, atrMultImpulse, tweezerTolPoints, dojiBodyPct,
                 useFvg, usePin, useDoji, useEng, useTweezer, useLq, useNormalOb,
                 useManip, useMss, useOte, detail);
   if(detail.maxScore <= 0) return true;
   return (detail.score >= minScore);
}

bool SMC_PassesShortFilter(const string sym, const ENUM_TIMEFRAMES tf,
                           const int lookback, const int minScore,
                           const double atrMultImpulse, const double tweezerTolPoints,
                           const double dojiBodyPct,
                           const bool useFvg, const bool usePin, const bool useDoji, const bool useEng,
                           const bool useTweezer, const bool useLq, const bool useNormalOb,
                           const bool useManip, const bool useMss, const bool useOte,
                           SMCScoreResult &detail)
{
   SMC_ScoreShort(sym, tf, lookback, atrMultImpulse, tweezerTolPoints, dojiBodyPct,
                  useFvg, usePin, useDoji, useEng, useTweezer, useLq, useNormalOb,
                  useManip, useMss, useOte, detail);
   if(detail.maxScore <= 0) return true;
   return (detail.score >= minScore);
}
enum ENUM_COT_MODE
{
   COT_OFF    = 0, // No COT filter
   COT_ALIGN  = 1, // With non-comm net: long if net >= -band, short if net <= +band
   COT_STRICT = 2  // Long only if net > minAbs; short only if net < -minAbs
};

enum ENUM_ENTRY_MODE
{
   ENTRY_BREAKOUT = 0,
   ENTRY_RETEST_M1 = 1
};

enum ENUM_SL_MODE
{
   SL_ORB_EDGE = 0,
   SL_ORB_EDGE_ATR = 1
};

input group "=== Signal bus (optional — follower EA only) ==="
input bool     InpPublishSignals       = false;
input string   InpSignalChannel        = "CH1";
input string   InpSignalSymbol         = "";

input group "=== Risk (EA only — not in indicator) ==="
input double   InpRiskPercent          = 0.35;
input double   InpDailyLossLimitPercent = 2.0;
input double   InpDrawdownLimitPercent  = 8.0;
input int      InpMagicNumber          = 20260405;
input int      InpMaxSpread            = 0;    // Max spread in points (0=off); tune for CFD broker
input bool     InpDebugLog             = false;

input group "=== Session toggles ==="
input bool     InpTradeAsia            = true;
input bool     InpTradeLondon          = true;
input bool     InpTradeNY              = true;

input group "=== Session times (CST) — match indicator ==="
input int      InpBrokerGMTOffset      = 2;
input string   InpAsiaOpenCST          = "18:00";
input int      InpAsiaORBMins          = 60;
input string   InpLondonOpenCST        = "03:00";
input int      InpLondonORBMins        = 15;
input string   InpNYOpenCST            = "08:30";
input int      InpNYORBMins            = 15;

input group "=== Same inputs as indicator ==="
input double   InpRiskReward           = 2.0;
input double   InpMinRangePips         = 15.0;
input bool     InpUseEmaFilter         = false;
input int      InpEmaPeriod            = 200;

input group "=== Entry / SL refinement ==="
input ENUM_ENTRY_MODE InpEntryMode     = ENTRY_RETEST_M1;  // Faster retest execution on M1
input double   InpRetestBufferPips     = 1.0;              // Entry level +/- buffer
input int      InpRetestMaxBarsM1      = 4;                // Cancel setup if not retested in N M1 bars
input ENUM_SL_MODE InpSLMode           = SL_ORB_EDGE_ATR;  // ATR buffer helps avoid wick-outs
input ENUM_TIMEFRAMES InpSLAtrTF       = PERIOD_M15;
input int      InpSLAtrPeriod          = 14;
input double   InpSLAtrMultiplier      = 0.30;
input group "=== Volume-confirmed breakout (CFD) ==="
input bool     InpUseVolumeFilter      = true;   // Require relative tick-volume on signal bar
input int      InpVolAvgPeriod         = 20;     // Avg tick-volume lookback (ORB_CHART_TF bars)
input double   InpVolMinRelMult        = 1.5;    // Signal vol >= avg × this (research: 1.5–2.0)
input bool     InpVolRequireRising     = true;   // Also require vol > prior bar
input bool     InpVolUseCandleStrength = true;   // Close in strong side of breakout bar
input double   InpVolMinCloseFrac      = 0.70;   // Long: close in top 30%; short: bottom 30%

input group "=== SMC / OB confluence (match indicator) ==="
input bool     InpUseSMCFilter  = false;
input int      InpSMCLookback   = 40;
input int      InpSMCMinScore   = 1;
input double   InpSMCImpulseAtrMult = 1.15;
input double   InpSMCTweezerTolPips = 2.0;
input double   InpSMCDojiBodyPct  = 0.12;
input bool     InpSMCUseFvg     = true;
input bool     InpSMCUsePin     = true;
input bool     InpSMCUseDoji    = true;
input bool     InpSMCUseEng     = true;
input bool     InpSMCUseTweezer = true;
input bool     InpSMCUseLq      = true;
input bool     InpSMCUseNormalOb = true;
input bool     InpSMCUseManip   = true;
input bool     InpSMCUseMss     = false;
input bool     InpSMCUseOte     = true;

input group "=== EA-only trade management (indicator has none) ==="
input bool     InpMoveSLtoBE           = false;
input double   InpBreakEvenAtTPFraction = 0.5;
input int      InpBreakEvenBufferPips  = 2;

input group "=== Dashboard ==="
input bool     InpShowDashboard        = true;
input int      InpDashFontSize         = 9;
input int      InpDashBottomMargin     = 28;   // Pixels above time axis (panel anchored from chart bottom)

input group "=== COT weekly (CSV in MQL5\\Files) ==="
input bool     InpCotLoadFile          = true;
input bool     InpCotAutoFetch         = true; // Download from CFTC API (EA only — whitelist URL in Terminal options)
input int      InpCotWebTimeoutMs      = 25000;
input string   InpCotWebUrl            = "";   // Empty = default CFTC Socrata CSV for GOLD 088691
input string   InpCotFileName          = "COT_GOLD.csv";
input bool     InpCotFileCommon        = false;
input int      InpCotReloadHours       = 24;
input ENUM_COT_MODE InpCotMode        = COT_OFF;
input double   InpCotNeutralBand       = 0;    // ALIGN: treat |net| inside band as neutral (allow both sides)
input double   InpCotMinAbsNet         = 5000; // STRICT: required |net| for directional trades

CTrade         g_trade;
CSymbolInfo    g_symbol;
double         g_peakBalance           = 0;

string         g_sigSym                = "";
string         g_gvPrefix              = "";
ulong          g_publishSeq            = 0;

int            g_asiaStartH, g_asiaStartM, g_asiaEndH, g_asiaEndM;
int            g_londonStartH, g_londonStartM, g_londonEndH, g_londonEndM;
int            g_nyStartH, g_nyStartM, g_nyEndH, g_nyEndM;

double         g_asiaHigh, g_asiaLow;
bool           g_asiaRangeValid        = false;
double         g_londonHigh, g_londonLow;
bool           g_londonRangeValid      = false;
double         g_nyHigh, g_nyLow;
bool           g_nyRangeValid          = false;

int            g_emaHandle             = INVALID_HANDLE;
SMCScoreResult g_smcLongDetail;
SMCScoreResult g_smcShortDetail;
int            g_lastDay               = -1;

// Mirror GOLD_ORB_Indicator signal state (g_signalDir, g_sig*, etc.)
int            g_sigDir                = 0;
double         g_sigEntry              = 0;
double         g_sigSL               = 0;
double         g_sigTP               = 0;
datetime       g_sigTime             = 0;
int            g_sigSession          = 0;
datetime       g_lastAlertTime       = 0;

bool           g_retestActive        = false;
int            g_retestDir           = 0;
int            g_retestSession       = 0;
double         g_retestEntry         = 0;
double         g_retestSL            = 0;
datetime       g_retestSigBarTime    = 0;
datetime       g_retestExpiryTime    = 0;
string         g_retestLabel         = "";

datetime       g_cotLastReload        = 0;

string         g_dashPrefix           = "GOEA_";

// --- Gold_ORB_Common.mqh (inlined: single-file EA for MQL5\Experts) ---
void ORB_CSTToBroker(const string cstTime, const int brokerGMTOffset, int &brokerH, int &brokerM)
{
   int cstH = (int)StringSubstr(cstTime, 0, 2);
   int cstM = (int)StringSubstr(cstTime, 3, 2);
   int cstGMT = -6;
   int totalMins = cstH * 60 + cstM + (brokerGMTOffset - cstGMT) * 60;
   if(totalMins < 0)     totalMins += 1440;
   if(totalMins >= 1440) totalMins -= 1440;
   brokerH = totalMins / 60;
   brokerM = totalMins % 60;
}

void ORB_OrbEndHM(const int startH, const int startM, const int durationMins, int &endH, int &endM)
{
   int totalMins = startH * 60 + startM + durationMins;
   if(totalMins >= 1440) totalMins -= 1440;
   if(totalMins < 0)     totalMins += 1440;
   endH = totalMins / 60;
   endM = totalMins % 60;
}

double ORB_OrbEndFrac(const int startH, const int startM, const int durationMins)
{
   int totalMins = startH * 60 + startM + durationMins;
   if(totalMins >= 1440) totalMins -= 1440;
   if(totalMins < 0)     totalMins += 1440;
   return totalMins / 60.0;
}

double ORB_BrokerHourNow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.hour + dt.min / 60.0;
}

bool ORB_ScanRange(const string sym, const ENUM_TIMEFRAMES tf, const datetime t1, const datetime t2, double &hi, double &lo)
{
   int bs = iBarShift(sym, tf, t1, false);
   int be = iBarShift(sym, tf, t2, false);
   if(bs < 0 || be < 0) return false;
   int cnt = MathAbs(bs - be) + 1;
   if(cnt <= 0 || cnt > 200) return false;
   double h[], l[];
   int first = MathMin(bs, be);
   if(CopyHigh(sym, tf, first, cnt, h) != cnt) return false;
   if(CopyLow (sym, tf, first, cnt, l) != cnt) return false;
   hi = h[0]; lo = l[0];
   for(int i = 1; i < cnt; i++)
   {
      if(h[i] > hi) hi = h[i];
      if(l[i] < lo) lo = l[i];
   }
   return true;
}

// --- Signal bus (optional follower) ---
string ORB_SignalSanitizeSymbol(const string sym)
{
   string s = sym;
   StringReplace(s, "#", "_");
   StringReplace(s, ".", "_");
   StringReplace(s, " ", "_");
   StringReplace(s, "-", "_");
   return s;
}

string ORB_SignalGVPrefix(const string channel, const string sym)
{
   return "ORB_" + ORB_SignalSanitizeSymbol(channel) + "_" + ORB_SignalSanitizeSymbol(sym) + "_";
}

void ORB_SignalPublish(const string prefix, const ulong seq, const datetime sigBarTime, const int dir,
                       const double refEntry, const double sl, const double rr, const int sess)
{
   GlobalVariableSet(prefix + "seq",  (double)seq);
   GlobalVariableSet(prefix + "time", (double)sigBarTime);
   GlobalVariableSet(prefix + "dir",  (double)dir);
   GlobalVariableSet(prefix + "entry", refEntry);
   GlobalVariableSet(prefix + "sl",   sl);
   GlobalVariableSet(prefix + "rr",   rr);
   GlobalVariableSet(prefix + "sess", (double)sess);
}

bool ORB_SignalGVExists(const string prefix)
{
   return GlobalVariableCheck(prefix + "seq");
}

bool ORB_SignalRead(const string prefix, ulong &seq, datetime &sigBarTime, int &dir,
                    double &refEntry, double &sl, double &rr, int &sess)
{
   if(!GlobalVariableCheck(prefix + "seq")) return false;
   seq        = (ulong)GlobalVariableGet(prefix + "seq");
   sigBarTime = (datetime)GlobalVariableGet(prefix + "time");
   dir        = (int)GlobalVariableGet(prefix + "dir");
   refEntry   = GlobalVariableGet(prefix + "entry");
   sl         = GlobalVariableGet(prefix + "sl");
   rr         = GlobalVariableGet(prefix + "rr");
   sess       = (int)GlobalVariableGet(prefix + "sess");
   return true;
}

//+------------------------------------------------------------------+
double GetPipSize()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
      return MathMax(0.1, point * 10);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return (digits == 3 || digits == 5) ? point * 10 : point;
}

double PipsToPrice(const double pips) { return pips * GetPipSize(); }

double GetPipValue()
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) return 0;
   return tickValue / tickSize * GetPipSize();
}

double CalcLotSize(const double riskDistPrice)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;
   double pipVal = GetPipValue();
   if(pipVal <= 0) return 0;
   double slPips = riskDistPrice / GetPipSize();
   if(slPips <= 0) return 0;
   double lotSize = riskAmount / (slPips * pipVal);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lotSize = MathFloor(lotSize / stepLot) * stepLot;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   return NormalizeDouble(lotSize, 2);
}

bool NormalizeSLTP(const ENUM_ORDER_TYPE type, const double price, double &sl, double &tp)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double pipSize = GetPipSize();
   double minDist = (stopsLevel > 0) ? stopsLevel * point : MathMax(pipSize * 2, point * 10);

   if(type == ORDER_TYPE_BUY)
   {
      if(sl >= price - minDist) return false;
      if(tp > 0 && tp <= price + minDist) return false;
      if(tp > 0 && tp < price) return false;
   }
   else
   {
      if(sl <= price + minDist) return false;
      if(tp > 0 && tp >= price - minDist) return false;
      if(tp > 0 && tp > price) return false;
   }
   sl = NormalizeDouble(sl, digits);
   if(tp > 0) tp = NormalizeDouble(tp, digits);
   return true;
}

bool GetBar0Context(MqlDateTime &dt, double &brokerHour, datetime &tBar0)
{
   tBar0 = iTime(_Symbol, ORB_CHART_TF, 0);
   if(tBar0 == 0)
      tBar0 = iTime(_Symbol, Period(), 0);
   if(tBar0 == 0)
      tBar0 = TimeCurrent();
   TimeToStruct(tBar0, dt);
   brokerHour = dt.hour + dt.min / 60.0;
   return true;
}

void ResetDayState()
{
   g_asiaRangeValid = g_londonRangeValid = g_nyRangeValid = false;
   g_sigDir = 0;
   g_sigEntry = g_sigSL = g_sigTP = 0;
   g_sigTime = 0;
   g_sigSession = 0;
   g_lastAlertTime = 0;
}

void UpdateAsiaRange(const MqlDateTime &dt, const double brokerHour, const datetime tBar0)
{
   double asiaStartF = g_asiaStartH + g_asiaStartM / 60.0;
   double asiaEndF   = ORB_OrbEndFrac(g_asiaStartH, g_asiaStartM, InpAsiaORBMins);
   if(brokerHour < asiaStartF) return;

   datetime t1 = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", dt.year, dt.mon, dt.day, g_asiaStartH, g_asiaStartM));
   datetime t2;
   if(brokerHour < asiaEndF)
      t2 = tBar0;
   else
      t2 = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", dt.year, dt.mon, dt.day, g_asiaEndH, g_asiaEndM));

   double hi, lo;
   if(!ORB_ScanRange(_Symbol, ORB_RANGE_TF, t1, t2, hi, lo)) return;
   if(hi <= lo) return;
   g_asiaHigh = hi;
   g_asiaLow = lo;
   g_asiaRangeValid = ((hi - lo) >= PipsToPrice(InpMinRangePips));
}

void UpdateLondonRange(const MqlDateTime &dt, const double brokerHour, const datetime tBar0)
{
   double lonStartF = g_londonStartH + g_londonStartM / 60.0;
   double lonEndF   = ORB_OrbEndFrac(g_londonStartH, g_londonStartM, InpLondonORBMins);
   if(brokerHour < lonStartF) return;

   datetime t1 = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", dt.year, dt.mon, dt.day, g_londonStartH, g_londonStartM));
   datetime t2;
   if(brokerHour < lonEndF)
      t2 = tBar0;
   else
      t2 = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", dt.year, dt.mon, dt.day, g_londonEndH, g_londonEndM));

   double hi, lo;
   if(!ORB_ScanRange(_Symbol, ORB_RANGE_TF, t1, t2, hi, lo)) return;
   if(hi <= lo) return;
   g_londonHigh = hi;
   g_londonLow = lo;
   g_londonRangeValid = ((hi - lo) >= PipsToPrice(InpMinRangePips));
}

void UpdateNYRange(const MqlDateTime &dt, const double brokerHour, const datetime tBar0)
{
   double nyStartF = g_nyStartH + g_nyStartM / 60.0;
   double nyEndF   = ORB_OrbEndFrac(g_nyStartH, g_nyStartM, InpNYORBMins);
   if(brokerHour < nyStartF) return;

   datetime t1 = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", dt.year, dt.mon, dt.day, g_nyStartH, g_nyStartM));
   datetime t2;
   if(brokerHour < nyEndF)
      t2 = tBar0;
   else
      t2 = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", dt.year, dt.mon, dt.day, g_nyEndH, g_nyEndM));

   double hi, lo;
   if(!ORB_ScanRange(_Symbol, ORB_RANGE_TF, t1, t2, hi, lo)) return;
   if(hi <= lo) return;
   g_nyHigh = hi;
   g_nyLow = lo;
   g_nyRangeValid = ((hi - lo) >= PipsToPrice(InpMinRangePips));
}

double GetTodayNetPL()
{
   MqlDateTime dayDt;
   TimeToStruct(TimeCurrent(), dayDt);
   datetime todayStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dayDt.year, dayDt.mon, dayDt.day));
   double closedPL = 0;
   if(HistorySelect(todayStart, TimeCurrent()))
   {
      for(int d = HistoryDealsTotal() - 1; d >= 0; d--)
      {
         ulong dTicket = HistoryDealGetTicket(d);
         if(dTicket == 0) continue;
         if(HistoryDealGetString(dTicket, DEAL_SYMBOL) != _Symbol) continue;
         if(HistoryDealGetInteger(dTicket, DEAL_MAGIC) != InpMagicNumber) continue;
         if(HistoryDealGetInteger(dTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT ||
            HistoryDealGetInteger(dTicket, DEAL_ENTRY) == DEAL_ENTRY_INOUT)
            closedPL += HistoryDealGetDouble(dTicket, DEAL_PROFIT)
                      + HistoryDealGetDouble(dTicket, DEAL_SWAP)
                      + HistoryDealGetDouble(dTicket, DEAL_COMMISSION);
      }
   }
   double ownProfit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      ownProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return closedPL + ownProfit;
}

bool IsDailyLossBreached()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0) return true;
   return GetTodayNetPL() <= -(balance * InpDailyLossLimitPercent / 100.0);
}

bool IsDrawdownBreached()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_peakBalance <= 0) g_peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double ddPct = (g_peakBalance > 0) ? ((g_peakBalance - equity) / g_peakBalance * 100.0) : 0;
   return ddPct >= InpDrawdownLimitPercent;
}

bool IsSignalVolumeOK(const datetime signalBarTime, const int dir)
{
   if(dir == 0) return false;
   return VBF_PassesBreakoutVolume(_Symbol, ORB_CHART_TF, signalBarTime, dir > 0,
      InpUseVolumeFilter, InpVolAvgPeriod, InpVolMinRelMult, InpVolRequireRising,
      InpVolUseCandleStrength, InpVolMinCloseFrac);
}

void ManagePositions()
{
   if(!InpMoveSLtoBE) return;
   if(InpBreakEvenAtTPFraction <= 0 || InpBreakEvenAtTPFraction > 1.0) return;

   double beBuf = PipsToPrice(MathMax(0, InpBreakEvenBufferPips));

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double posSL = PositionGetDouble(POSITION_SL);
      double posTP = PositionGetDouble(POSITION_TP);
      long type = PositionGetInteger(POSITION_TYPE);
      if(posSL == 0 || posTP <= 0) continue;

      bool tpOk = (type == POSITION_TYPE_BUY && posTP > openPrice)
               || (type == POSITION_TYPE_SELL && posTP < openPrice);
      if(!tpOk) continue;

      double triggerPrice = openPrice + (posTP - openPrice) * InpBreakEvenAtTPFraction;
      double price = (type == POSITION_TYPE_BUY)
         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      bool triggerBE = (type == POSITION_TYPE_BUY && price >= triggerPrice - beBuf)
                    || (type == POSITION_TYPE_SELL && price <= triggerPrice + beBuf);
      bool notYetBE  = (type == POSITION_TYPE_BUY && posSL < openPrice - beBuf)
                    || (type == POSITION_TYPE_SELL && posSL > openPrice + beBuf);

      if(triggerBE && notYetBE)
         g_trade.PositionModify(ticket, openPrice, posTP);
   }
}

bool CotAllowForDir(const int dir, const datetime sigBarTime, string &reason)
{
   reason = "";
   if(InpCotMode == COT_OFF) return true;
   int mode = (InpCotMode == COT_STRICT) ? 2 : 1;
   return COT_PassesDirectionFilter(dir, mode, InpCotNeutralBand, InpCotMinAbsNet, sigBarTime, reason);
}

double GetAtrForSL()
{
   if(InpSLMode != SL_ORB_EDGE_ATR) return 0.0;
   if(InpSLAtrPeriod <= 1 || InpSLAtrMultiplier <= 0) return 0.0;
   double atr = SMC_AtrValue(_Symbol, InpSLAtrTF, InpSLAtrPeriod, 1);
   if(atr <= 0) return 0.0;
   return atr * InpSLAtrMultiplier;
}

double BuildSignalSL(const int dir, const double rangeHigh, const double rangeLow)
{
   double sl = (dir > 0) ? rangeLow : rangeHigh;
   double atrBuf = GetAtrForSL();
   if(atrBuf > 0)
      sl = (dir > 0) ? (sl - atrBuf) : (sl + atrBuf);
   return sl;
}

void ClearRetestSetup()
{
   g_retestActive = false;
   g_retestDir = 0;
   g_retestSession = 0;
   g_retestEntry = 0;
   g_retestSL = 0;
   g_retestSigBarTime = 0;
   g_retestExpiryTime = 0;
   g_retestLabel = "";
}

bool PlaceOrbOrder(const ENUM_ORDER_TYPE otype, const double slInd, const double entryRef,
                   const datetime sigBarTime, const int sessId, const string sigLabel)
{
   if(!VBF_SpreadOK(InpMaxSpread))
   {
      if(InpDebugLog) Print(sigLabel, ": spread too wide (max ", InpMaxSpread, " pts)");
      return false;
   }

   double risk = (otype == ORDER_TYPE_BUY) ? (entryRef - slInd) : (slInd - entryRef);
   if(risk <= 0) return false;

   double price = (otype == ORDER_TYPE_BUY) ? g_symbol.Ask() : g_symbol.Bid();
   double sl = slInd;
   double tp = (otype == ORDER_TYPE_BUY) ? (entryRef + risk * InpRiskReward) : (entryRef - risk * InpRiskReward);

   if(!NormalizeSLTP(otype, price, sl, tp))
   {
      if(InpDebugLog) Print(sigLabel, ": NormalizeSLTP failed");
      return false;
   }

   double lots = CalcLotSize(risk);
   if(lots <= 0) return false;

   string comment = "ORB_M_" + sigLabel;
   bool ok = (otype == ORDER_TYPE_BUY)
      ? g_trade.Buy(lots, _Symbol, price, sl, tp, comment)
      : g_trade.Sell(lots, _Symbol, price, sl, tp, comment);

   if(!ok)
   {
      Print(sigLabel, " order failed: ", g_trade.ResultRetcodeDescription());
      return false;
   }

   if(InpPublishSignals)
   {
      g_publishSeq++;
      int pubDir = 1;
      if(otype != ORDER_TYPE_BUY)
         pubDir = -1;
      ORB_SignalPublish(g_gvPrefix, g_publishSeq, sigBarTime, pubDir, entryRef, slInd, InpRiskReward, sessId);
   }
   return true;
}

// Core loop: same order as GOLD_ORB_Indicator OnCalculate (signal + bid TP/SL + expiry + breakouts).
void RunIndicatorParityAndTrade(const bool allowNewOrders)
{
   if(iBars(_Symbol, ORB_CHART_TF) < 50) return;

   MqlDateTime dt;
   double brokerHour;
   datetime tBar0;
   GetBar0Context(dt, brokerHour, tBar0);

   double asiaStartH   = g_asiaStartH + g_asiaStartM / 60.0;
   double asiaEndH     = ORB_OrbEndFrac(g_asiaStartH, g_asiaStartM, InpAsiaORBMins);
   double londonStartH = g_londonStartH + g_londonStartM / 60.0;
   double londonEndH   = ORB_OrbEndFrac(g_londonStartH, g_londonStartM, InpLondonORBMins);
   double nyStartH     = g_nyStartH + g_nyStartM / 60.0;
   double nyEndH       = ORB_OrbEndFrac(g_nyStartH, g_nyStartM, InpNYORBMins);

   if(dt.day != g_lastDay)
   {
      g_lastDay = dt.day;
      ResetDayState();
      ClearRetestSetup();
   }

   UpdateAsiaRange(dt, brokerHour, tBar0);
   UpdateLondonRange(dt, brokerHour, tBar0);
   UpdateNYRange(dt, brokerHour, tBar0);

   // ── Virtual TP/SL on bid (same as indicator) ─────────────────────
   if(g_sigDir != 0 && g_sigEntry > 0 && !g_retestActive)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      bool hitTP = false, hitSL = false;

      if(g_sigDir == 1)
      {
         if(bid >= g_sigTP) hitTP = true;
         if(bid <= g_sigSL) hitSL = true;
      }
      else
      {
         if(bid <= g_sigTP) hitTP = true;
         if(bid >= g_sigSL) hitSL = true;
      }

      if(hitTP || hitSL)
      {
         g_sigDir = 0;
         g_sigEntry = g_sigSL = g_sigTP = 0;
         g_sigTime = 0;
         g_sigSession = 0;
      }
   }

   // ── Session expiry (same as indicator) ────────────────────────────
   if(g_sigSession == 1 && brokerHour >= londonStartH)
   {
      g_sigDir = 0;
      g_sigEntry = g_sigSL = g_sigTP = 0;
      g_sigTime = 0;
      g_sigSession = 0;
      ClearRetestSetup();
   }
   else if(g_sigSession == 2 && brokerHour >= nyStartH)
   {
      g_sigDir = 0;
      g_sigEntry = g_sigSL = g_sigTP = 0;
      g_sigTime = 0;
      g_sigSession = 0;
      ClearRetestSetup();
   }

   if(!allowNewOrders)
   {
      ClearRetestSetup();
      return;
   }

   double ema200 = 0;
   if(InpUseEmaFilter && g_emaHandle != INVALID_HANDLE)
   {
      double ema[];
      ArraySetAsSeries(ema, true);
      if(CopyBuffer(g_emaHandle, 0, 1, 1, ema) == 1) ema200 = ema[0];
   }

   double c1 = iClose(_Symbol, ORB_CHART_TF, 1);
   double c2 = iClose(_Symbol, ORB_CHART_TF, 2);
   datetime time1 = iTime(_Symbol, ORB_CHART_TF, 1);

   SMC_ScoreLong(_Symbol, ORB_CHART_TF, InpSMCLookback, InpSMCImpulseAtrMult, InpSMCTweezerTolPips, InpSMCDojiBodyPct,
                 InpSMCUseFvg, InpSMCUsePin, InpSMCUseDoji, InpSMCUseEng, InpSMCUseTweezer, InpSMCUseLq,
                 InpSMCUseNormalOb, InpSMCUseManip, InpSMCUseMss, InpSMCUseOte, g_smcLongDetail);
   SMC_ScoreShort(_Symbol, ORB_CHART_TF, InpSMCLookback, InpSMCImpulseAtrMult, InpSMCTweezerTolPips, InpSMCDojiBodyPct,
                  InpSMCUseFvg, InpSMCUsePin, InpSMCUseDoji, InpSMCUseEng, InpSMCUseTweezer, InpSMCUseLq,
                  InpSMCUseNormalOb, InpSMCUseManip, InpSMCUseMss, InpSMCUseOte, g_smcShortDetail);
   bool smcLongOk = !InpUseSMCFilter || (g_smcLongDetail.maxScore == 0) || (g_smcLongDetail.score >= InpSMCMinScore);
   bool smcShortOk = !InpUseSMCFilter || (g_smcShortDetail.maxScore == 0) || (g_smcShortDetail.score >= InpSMCMinScore);

   if(InpCotLoadFile && StringLen(InpCotFileName) > 0 && InpCotReloadHours > 0)
   {
      int sec = InpCotReloadHours * 3600;
      if(TimeCurrent() - g_cotLastReload >= sec)
      {
         COT_LoadAutoOrFile(InpCotAutoFetch, InpCotWebTimeoutMs, InpCotWebUrl, InpCotFileName, InpCotFileCommon);
         g_cotLastReload = TimeCurrent();
      }
   }

   bool fireBreakoutAlert = false;

   // Execute pending M1 retest setup (if any) before detecting fresh breakouts.
   if(g_retestActive)
   {
      if(TimeCurrent() > g_retestExpiryTime)
      {
         if(InpDebugLog) Print("Retest expired: ", g_retestLabel);
         ClearRetestSetup();
      }
      else
      {
         double tol = PipsToPrice(MathMax(0.0, InpRetestBufferPips));
         bool touched = false;
         if(g_retestDir > 0)
            touched = (g_symbol.Ask() <= g_retestEntry + tol);
         else if(g_retestDir < 0)
            touched = (g_symbol.Bid() >= g_retestEntry - tol);

         if(touched)
         {
            if(!IsSignalVolumeOK(g_retestSigBarTime, g_retestDir))
            {
               if(InpDebugLog) Print("Volume skip retest: ", g_retestLabel);
               ClearRetestSetup();
            }
            else
            {
            ENUM_ORDER_TYPE rt = (g_retestDir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
            if(PlaceOrbOrder(rt, g_retestSL, g_retestEntry, g_retestSigBarTime, g_retestSession, g_retestLabel))
            {
               if(InpDebugLog) Print("Retest filled: ", g_retestLabel, " @ ", g_retestEntry);
               fireBreakoutAlert = true;
            }
            else if(InpDebugLog)
               Print("Retest order failed: ", g_retestLabel);
            ClearRetestSetup();
            }
         }
      }
   }

   if(g_sigDir == 0)
   {
      if(InpTradeAsia && brokerHour >= asiaEndH && brokerHour < londonStartH && g_asiaRangeValid)
      {
         if(smcLongOk && c1 > g_asiaHigh && c2 <= g_asiaHigh && (!InpUseEmaFilter || c1 > ema200))
         {
            string cotR = "";
            if(!CotAllowForDir(1, time1, cotR))
            {
               if(InpDebugLog) Print("COT skip ASIAN_LONG: ", cotR);
            }
            else
            {
            if(!IsSignalVolumeOK(time1, 1))
            {
               if(InpDebugLog) Print("Volume skip ASIAN_LONG");
            }
            else
            {
            double sl = BuildSignalSL(1, g_asiaHigh, g_asiaLow);
            double risk = c1 - sl;
            g_sigDir = 1;
            g_sigSession = 1;
            g_sigEntry = c1;
            g_sigSL = sl;
            g_sigTP = c1 + risk * InpRiskReward;
            g_sigTime = time1;
            fireBreakoutAlert = true;
            if(InpEntryMode == ENTRY_BREAKOUT)
            {
               if(!PlaceOrbOrder(ORDER_TYPE_BUY, sl, c1, time1, 1, "ASIAN_LONG"))
               {
                  g_sigDir = 0;
                  g_sigEntry = g_sigSL = g_sigTP = 0;
                  g_sigTime = 0;
                  g_sigSession = 0;
                  fireBreakoutAlert = false;
               }
            }
            else
            {
               g_retestActive = true;
               g_retestDir = 1;
               g_retestSession = 1;
               g_retestEntry = g_asiaHigh;
               g_retestSL = sl;
               g_retestSigBarTime = time1;
               g_retestExpiryTime = TimeCurrent() + (datetime)(MathMax(1, InpRetestMaxBarsM1) * 60);
               g_retestLabel = "ASIAN_LONG_RT";
            }
            }
            }
         }
         else if(smcShortOk && c1 < g_asiaLow && c2 >= g_asiaLow && (!InpUseEmaFilter || c1 < ema200))
         {
            string cotR = "";
            if(!CotAllowForDir(-1, time1, cotR))
            {
               if(InpDebugLog) Print("COT skip ASIAN_SHORT: ", cotR);
            }
            else
            {
            if(!IsSignalVolumeOK(time1, -1))
            {
               if(InpDebugLog) Print("Volume skip ASIAN_SHORT");
            }
            else
            {
            double sl = BuildSignalSL(-1, g_asiaHigh, g_asiaLow);
            double risk = sl - c1;
            g_sigDir = -1;
            g_sigSession = 1;
            g_sigEntry = c1;
            g_sigSL = sl;
            g_sigTP = c1 - risk * InpRiskReward;
            g_sigTime = time1;
            fireBreakoutAlert = true;
            if(InpEntryMode == ENTRY_BREAKOUT)
            {
               if(!PlaceOrbOrder(ORDER_TYPE_SELL, sl, c1, time1, 1, "ASIAN_SHORT"))
               {
                  g_sigDir = 0;
                  g_sigEntry = g_sigSL = g_sigTP = 0;
                  g_sigTime = 0;
                  g_sigSession = 0;
                  fireBreakoutAlert = false;
               }
            }
            else
            {
               g_retestActive = true;
               g_retestDir = -1;
               g_retestSession = 1;
               g_retestEntry = g_asiaLow;
               g_retestSL = sl;
               g_retestSigBarTime = time1;
               g_retestExpiryTime = TimeCurrent() + (datetime)(MathMax(1, InpRetestMaxBarsM1) * 60);
               g_retestLabel = "ASIAN_SHORT_RT";
            }
            }
            }
         }
      }

      if(g_sigDir == 0 && InpTradeLondon && brokerHour >= londonEndH && brokerHour < nyStartH && g_londonRangeValid)
      {
         if(smcLongOk && c1 > g_londonHigh && c2 <= g_londonHigh && (!InpUseEmaFilter || c1 > ema200))
         {
            string cotR = "";
            if(!CotAllowForDir(1, time1, cotR))
            {
               if(InpDebugLog) Print("COT skip LONDON_LONG: ", cotR);
            }
            else
            {
            if(!IsSignalVolumeOK(time1, 1))
            {
               if(InpDebugLog) Print("Volume skip LONDON_LONG");
            }
            else
            {
            double sl = BuildSignalSL(1, g_londonHigh, g_londonLow);
            double risk = c1 - sl;
            g_sigDir = 1;
            g_sigSession = 2;
            g_sigEntry = c1;
            g_sigSL = sl;
            g_sigTP = c1 + risk * InpRiskReward;
            g_sigTime = time1;
            fireBreakoutAlert = true;
            if(InpEntryMode == ENTRY_BREAKOUT)
            {
               if(!PlaceOrbOrder(ORDER_TYPE_BUY, sl, c1, time1, 2, "LONDON_LONG"))
               {
                  g_sigDir = 0;
                  g_sigEntry = g_sigSL = g_sigTP = 0;
                  g_sigTime = 0;
                  g_sigSession = 0;
                  fireBreakoutAlert = false;
               }
            }
            else
            {
               g_retestActive = true;
               g_retestDir = 1;
               g_retestSession = 2;
               g_retestEntry = g_londonHigh;
               g_retestSL = sl;
               g_retestSigBarTime = time1;
               g_retestExpiryTime = TimeCurrent() + (datetime)(MathMax(1, InpRetestMaxBarsM1) * 60);
               g_retestLabel = "LONDON_LONG_RT";
            }
            }
            }
         }
         else if(smcShortOk && c1 < g_londonLow && c2 >= g_londonLow && (!InpUseEmaFilter || c1 < ema200))
         {
            string cotR = "";
            if(!CotAllowForDir(-1, time1, cotR))
            {
               if(InpDebugLog) Print("COT skip LONDON_SHORT: ", cotR);
            }
            else
            {
            if(!IsSignalVolumeOK(time1, -1))
            {
               if(InpDebugLog) Print("Volume skip LONDON_SHORT");
            }
            else
            {
            double sl = BuildSignalSL(-1, g_londonHigh, g_londonLow);
            double risk = sl - c1;
            g_sigDir = -1;
            g_sigSession = 2;
            g_sigEntry = c1;
            g_sigSL = sl;
            g_sigTP = c1 - risk * InpRiskReward;
            g_sigTime = time1;
            fireBreakoutAlert = true;
            if(InpEntryMode == ENTRY_BREAKOUT)
            {
               if(!PlaceOrbOrder(ORDER_TYPE_SELL, sl, c1, time1, 2, "LONDON_SHORT"))
               {
                  g_sigDir = 0;
                  g_sigEntry = g_sigSL = g_sigTP = 0;
                  g_sigTime = 0;
                  g_sigSession = 0;
                  fireBreakoutAlert = false;
               }
            }
            else
            {
               g_retestActive = true;
               g_retestDir = -1;
               g_retestSession = 2;
               g_retestEntry = g_londonLow;
               g_retestSL = sl;
               g_retestSigBarTime = time1;
               g_retestExpiryTime = TimeCurrent() + (datetime)(MathMax(1, InpRetestMaxBarsM1) * 60);
               g_retestLabel = "LONDON_SHORT_RT";
            }
            }
            }
         }
      }

      if(g_sigDir == 0 && InpTradeNY && brokerHour >= nyEndH && g_nyRangeValid)
      {
         if(smcLongOk && c1 > g_nyHigh && c2 <= g_nyHigh && (!InpUseEmaFilter || c1 > ema200))
         {
            string cotR = "";
            if(!CotAllowForDir(1, time1, cotR))
            {
               if(InpDebugLog) Print("COT skip NY_LONG: ", cotR);
            }
            else
            {
            if(!IsSignalVolumeOK(time1, 1))
            {
               if(InpDebugLog) Print("Volume skip NY_LONG");
            }
            else
            {
            double sl = BuildSignalSL(1, g_nyHigh, g_nyLow);
            double risk = c1 - sl;
            g_sigDir = 1;
            g_sigSession = 3;
            g_sigEntry = c1;
            g_sigSL = sl;
            g_sigTP = c1 + risk * InpRiskReward;
            g_sigTime = time1;
            fireBreakoutAlert = true;
            if(InpEntryMode == ENTRY_BREAKOUT)
            {
               if(!PlaceOrbOrder(ORDER_TYPE_BUY, sl, c1, time1, 3, "NY_LONG"))
               {
                  g_sigDir = 0;
                  g_sigEntry = g_sigSL = g_sigTP = 0;
                  g_sigTime = 0;
                  g_sigSession = 0;
                  fireBreakoutAlert = false;
               }
            }
            else
            {
               g_retestActive = true;
               g_retestDir = 1;
               g_retestSession = 3;
               g_retestEntry = g_nyHigh;
               g_retestSL = sl;
               g_retestSigBarTime = time1;
               g_retestExpiryTime = TimeCurrent() + (datetime)(MathMax(1, InpRetestMaxBarsM1) * 60);
               g_retestLabel = "NY_LONG_RT";
            }
            }
            }
         }
         else if(smcShortOk && c1 < g_nyLow && c2 >= g_nyLow && (!InpUseEmaFilter || c1 < ema200))
         {
            string cotR = "";
            if(!CotAllowForDir(-1, time1, cotR))
            {
               if(InpDebugLog) Print("COT skip NY_SHORT: ", cotR);
            }
            else
            {
            if(!IsSignalVolumeOK(time1, -1))
            {
               if(InpDebugLog) Print("Volume skip NY_SHORT");
            }
            else
            {
            double sl = BuildSignalSL(-1, g_nyHigh, g_nyLow);
            double risk = sl - c1;
            g_sigDir = -1;
            g_sigSession = 3;
            g_sigEntry = c1;
            g_sigSL = sl;
            g_sigTP = c1 - risk * InpRiskReward;
            g_sigTime = time1;
            fireBreakoutAlert = true;
            if(InpEntryMode == ENTRY_BREAKOUT)
            {
               if(!PlaceOrbOrder(ORDER_TYPE_SELL, sl, c1, time1, 3, "NY_SHORT"))
               {
                  g_sigDir = 0;
                  g_sigEntry = g_sigSL = g_sigTP = 0;
                  g_sigTime = 0;
                  g_sigSession = 0;
                  fireBreakoutAlert = false;
               }
            }
            else
            {
               g_retestActive = true;
               g_retestDir = -1;
               g_retestSession = 3;
               g_retestEntry = g_nyLow;
               g_retestSL = sl;
               g_retestSigBarTime = time1;
               g_retestExpiryTime = TimeCurrent() + (datetime)(MathMax(1, InpRetestMaxBarsM1) * 60);
               g_retestLabel = "NY_SHORT_RT";
            }
            }
            }
         }
      }
   }

   if(fireBreakoutAlert && g_sigTime != g_lastAlertTime)
   {
      if(InpDebugLog)
         Print("GOLD ORB EA: signal | entry=", g_sigEntry, " SL=", g_sigSL, " TP=", g_sigTP);
      g_lastAlertTime = g_sigTime;
   }
}

string SessionPhaseFromBrokerHour(const double brokerHour)
{
   double asiaStartH   = g_asiaStartH + g_asiaStartM / 60.0;
   double asiaEndH     = ORB_OrbEndFrac(g_asiaStartH, g_asiaStartM, InpAsiaORBMins);
   double londonStartH = g_londonStartH + g_londonStartM / 60.0;
   double londonEndH   = ORB_OrbEndFrac(g_londonStartH, g_londonStartM, InpLondonORBMins);
   double nyStartH     = g_nyStartH + g_nyStartM / 60.0;
   double nyEndH       = ORB_OrbEndFrac(g_nyStartH, g_nyStartM, InpNYORBMins);

   if     (brokerHour >= asiaStartH   && brokerHour < asiaEndH)    return "Asian ORB: Building";
   else if(brokerHour >= asiaEndH     && brokerHour < londonStartH) return "Asian: Trade window";
   else if(brokerHour >= londonStartH && brokerHour < londonEndH)  return "London ORB: Building";
   else if(brokerHour >= londonEndH   && brokerHour < nyStartH)    return "London: Trade window";
   else if(brokerHour >= nyStartH     && brokerHour < nyEndH)      return "NY ORB: Building";
   else if(brokerHour >= nyEndH)                                   return "NY: Trade window";
   return "Pre-session";
}

int CountOwnPositions(double &floatingProfit)
{
   int n = 0;
   floatingProfit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      n++;
      floatingProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return n;
}

void CleanupDashboard()
{
   ObjectsDeleteAll(0, g_dashPrefix);
}

int ORB_EaTextWidthPx(const string txt, const int fontSize)
{
   int len = StringLen(txt);
   if(len <= 0 || fontSize <= 0) return 0;
   int w = (int)(len * fontSize * 72 / 100) + fontSize * 2 + 32;
   return w;
}

int ORB_EaMaxTextWidthPx(const string &lines[], const int count, const int fontSize)
{
   int mx = 0;
   for(int i = 0; i < count; i++)
   {
      int w = ORB_EaTextWidthPx(lines[i], fontSize);
      if(w > mx) mx = w;
   }
   return (int)(mx * 118 / 100);
}

void ORB_EaClearUnusedDashLabels(const string prefix, const int numUsed)
{
   for(int j = numUsed; j < ORB_EA_DASH_MAX_LABELS; j++)
   {
      string nx = prefix + "L" + IntegerToString(j);
      if(ObjectFind(0, nx) >= 0)
         ObjectSetString(0, nx, OBJPROP_TEXT, "");
   }
}

void UpdateDashboard()
{
   if(!InpShowDashboard)
   {
      CleanupDashboard();
      return;
   }

   MqlDateTime dt;
   double brokerHour;
   datetime tBar0;
   GetBar0Context(dt, brokerHour, tBar0);

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double fl  = eq - bal;
   double dayPL = GetTodayNetPL();
   double posPL = 0;
   int posN = CountOwnPositions(posPL);

   bool dayBlock = IsDailyLossBreached();
   bool ddBlock  = IsDrawdownBreached();
   string status = "ACTIVE";
   color statusClr = clrLime;
   if(dayBlock)     { status = "DAILY LIMIT"; statusClr = clrRed; }
   else if(ddBlock) { status = "DD LIMIT";    statusClr = clrOrangeRed; }

   string phase = SessionPhaseFromBrokerHour(brokerHour);

   string sigOne = "Signal: — (no virtual ORB signal)";
   if(g_sigDir != 0)
   {
      string sd = (g_sigDir > 0) ? "LONG" : "SHORT";
      string sn = (g_sigSession == 1) ? "Asia" : (g_sigSession == 2) ? "London" : (g_sigSession == 3) ? "NY" : "?";
      sigOne = StringFormat("Signal: %s %s @ %.2f  SL %.2f  TP %.2f  RR 1:%.1f",
         sd, sn, g_sigEntry, g_sigSL, g_sigTP, InpRiskReward);
   }

   double pipSz = GetPipSize();
   string aP = g_asiaRangeValid   ? IntegerToString((int)MathRound((g_asiaHigh - g_asiaLow) / pipSz)) : "—";
   string lP = g_londonRangeValid ? IntegerToString((int)MathRound((g_londonHigh - g_londonLow) / pipSz)) : "—";
   string nP = g_nyRangeValid     ? IntegerToString((int)MathRound((g_nyHigh - g_nyLow) / pipSz)) : "—";

   const int nlines = 7;
   string lines[];
   ArrayResize(lines, nlines);

   lines[0] = StringFormat("GOLD ORB EA  %s  |  chart %s  range %s",
      _Symbol, EnumToString(ORB_CHART_TF), EnumToString(ORB_RANGE_TF));
   lines[1] = StringFormat("Equity $%.2f  Balance $%.2f  Float %s$%.2f",
      eq, bal, (fl >= 0 ? "+" : "-"), MathAbs(fl));
   lines[2] = StringFormat("Today P/L %s$%.2f  |  %s",
      (dayPL >= 0 ? "+" : "-"), MathAbs(dayPL), status);
   lines[3] = StringFormat("Phase: %s", phase);
   lines[4] = sigOne;
   lines[5] = StringFormat("ORB width (pips)  A:%s  L:%s  NY:%s", aP, lP, nP);
   lines[6] = StringFormat("Positions %d  P/L %s$%.2f  |  risk %.2f%%  RR 1:%.1f",
      posN, (posPL >= 0 ? "+" : "-"), MathAbs(posPL), InpRiskPercent, InpRiskReward);

   int lineH = InpDashFontSize + 6;
   const int padX   = 5;
   const int padSide = 16;
   const int padTop  = 8;
   const int padBot  = 8;

   int boxW = ORB_EaMaxTextWidthPx(lines, nlines, InpDashFontSize) + padSide * 2;
   boxW = (int)MathMax(300, MathMin(1200, boxW));
   int boxH = padTop + nlines * lineH + padBot;

   long chartHpx = ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   if(chartHpx < 120) chartHpx = 800;
   int margin = MathMax(10, InpDashBottomMargin);
   int yBg = (int)chartHpx - boxH - margin;
   if(yBg < 8) yBg = 8;

   // Create once; only ObjectSet* each tick (no delete/recreate) to avoid flicker.
   string bg = g_dashPrefix + "BG";
   if(ObjectFind(0, bg) < 0)
   {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'20,20,30');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, clrDimGray);
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_ZORDER, 100);
   }
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, padX);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, yBg);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, boxW);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, boxH);

   const int labelX = padX + padSide;
   const int labelY0 = yBg + padTop;

   for(int i = 0; i < nlines; i++)
   {
      string name = g_dashPrefix + "L" + IntegerToString(i);
      if(ObjectFind(0, name) < 0)
      {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
         ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_ZORDER, 101);
      }
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, labelX);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, labelY0 + i * lineH);
      ObjectSetString(0, name, OBJPROP_TEXT, lines[i]);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpDashFontSize);
      color rowClr = clrWhite;
      if(i == 0)
         rowClr = clrYellow;
      else if(i == 1)
         rowClr = clrDimGray;
      else if(i == 2)
         rowClr = statusClr;
      else if(i == 3)
      {
         if(StringFind(phase, "ORB") >= 0) rowClr = clrGold;
         else if(StringFind(phase, "Asia") >= 0) rowClr = clrDodgerBlue;
         else if(StringFind(phase, "London") >= 0) rowClr = clrOrange;
         else if(StringFind(phase, "NY") >= 0) rowClr = clrMediumPurple;
         else rowClr = clrSilver;
      }
      else if(i == 4)
         rowClr = (g_sigDir != 0) ? (g_sigDir > 0 ? clrLime : clrOrangeRed) : C'120,120,135';
      else if(i == 5)
         rowClr = clrSilver;
      else if(i == 6)
      {
         if(posPL > 0) rowClr = clrLime;
         else if(posPL < 0) rowClr = clrTomato;
         else rowClr = C'120,120,135';
      }
      ObjectSetInteger(0, name, OBJPROP_COLOR, rowClr);
   }
   ORB_EaClearUnusedDashLabels(g_dashPrefix, nlines);

   // Experts do not auto-repaint after object updates; without this the panel may stay invisible.
   ChartRedraw(0);
}

int OnInit()
{
   if(!g_symbol.Name(_Symbol)) return INIT_FAILED;
   if(Period() != ORB_CHART_TF)
      Print("GOLD_ORB Master EA WARNING: attach to ", EnumToString(ORB_CHART_TF),
            " chart. Current=", EnumToString(Period()));

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(10);

   g_sigSym = (StringLen(InpSignalSymbol) == 0) ? _Symbol : InpSignalSymbol;
   g_gvPrefix = ORB_SignalGVPrefix(InpSignalChannel, g_sigSym);

   ORB_CSTToBroker(InpAsiaOpenCST,   InpBrokerGMTOffset, g_asiaStartH,   g_asiaStartM);
   ORB_OrbEndHM(g_asiaStartH, g_asiaStartM, InpAsiaORBMins, g_asiaEndH, g_asiaEndM);

   ORB_CSTToBroker(InpLondonOpenCST, InpBrokerGMTOffset, g_londonStartH, g_londonStartM);
   ORB_OrbEndHM(g_londonStartH, g_londonStartM, InpLondonORBMins, g_londonEndH, g_londonEndM);

   ORB_CSTToBroker(InpNYOpenCST,     InpBrokerGMTOffset, g_nyStartH,     g_nyStartM);
   ORB_OrbEndHM(g_nyStartH, g_nyStartM, InpNYORBMins, g_nyEndH, g_nyEndM);

   if(InpUseEmaFilter)
      g_emaHandle = iMA(_Symbol, ORB_CHART_TF, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);

   g_peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   g_cotLastReload = TimeCurrent();
   if(InpCotLoadFile && StringLen(InpCotFileName) > 0)
   {
      if(COT_LoadAutoOrFile(InpCotAutoFetch, InpCotWebTimeoutMs, InpCotWebUrl, InpCotFileName, InpCotFileCommon))
         Print(g_cot_last_load_msg);
      else
         Print(g_cot_last_load_msg);
   }

   if(InpPublishSignals && ORB_SignalGVExists(g_gvPrefix))
   {
      ulong rs;
      datetime rt;
      int rd;
      double re, rsl, rrr;
      int rss;
      if(ORB_SignalRead(g_gvPrefix, rs, rt, rd, re, rsl, rrr, rss))
         g_publishSeq = rs;
   }

   Print("GOLD_ORB_Master_EA v2.13 | sigTF=", EnumToString(ORB_CHART_TF),
         " rangeTF=", EnumToString(ORB_RANGE_TF),
         " | match GOLD_ORB_Indicator | publish=", (InpPublishSignals ? "ON" : "OFF"),
         " | dashboard=", (InpShowDashboard ? "ON" : "OFF"),
         " | volFilter=", (InpUseVolumeFilter ? "ON" : "OFF"),
         " rel=", DoubleToString(InpVolMinRelMult, 1), "x avg", InpVolAvgPeriod);
   if(InpCotAutoFetch && InpCotLoadFile)
      Print("COT: auto-fetch ON — allow WebRequest to https://publicreporting.cftc.gov (Tools→Options→Experts)");

   if(InpShowDashboard)
      ChartRedraw(0);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   CleanupDashboard();
   if(g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
}

void OnTick()
{
   if(!g_symbol.RefreshRates()) return;

   ManagePositions();

   bool allowOrders = !IsDailyLossBreached() && !IsDrawdownBreached();
   RunIndicatorParityAndTrade(allowOrders);

   UpdateDashboard();
}
