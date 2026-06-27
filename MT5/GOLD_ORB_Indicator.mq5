//+------------------------------------------------------------------+
//|                                            GOLD_ORB_Indicator.mq5|
//|                       Gold Triple Session ORB — Asian, London, NY|
//|                        Configurable CST times + broker GMT offset|
//| Single .mq5: ORB helpers + COT + SMC inlined (no separate .mqh).   |
//| Chart: M5. ORB range H/L from M15 (see ORB_RANGE_TF).               |
//+------------------------------------------------------------------+
#property copyright "GOLD_ORB_Indicator"
#property version   "5.26"
#property strict
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

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
// Display string for dashboard (avoid name clash with any ORB_VERSION in other includes)
#define ORB_INDICATOR_VERSION "5.26"
// Attach to M5: patterns & signal logic use M5; ORB box uses M15 highs/lows only.
#define ORB_CHART_TF   PERIOD_M5
#define ORB_RANGE_TF   PERIOD_M15
#define ORB_IND_DASH_MAX_LABELS 40

//--- Inputs
input group "=== Session Times (CST / UTC-6) ==="
input int      InpBrokerGMTOffset = 2;     // Broker GMT Offset (ICMarkets = 2)
input string   InpAsiaOpenCST     = "18:00"; // Asia Open (CST)
input int      InpAsiaORBMins     = 60;    // Asia ORB Duration (minutes)
input string   InpLondonOpenCST   = "03:00"; // London Open (CST)
input int      InpLondonORBMins   = 15;    // London ORB Duration (minutes)
input string   InpNYOpenCST       = "08:30"; // NY Open (CST)
input int      InpNYORBMins       = 15;    // NY ORB Duration (minutes)

input group "=== Filters ==="
input double   InpMinRangePips  = 15;    // Min range size (pips) — skip flat sessions
input double   InpRiskReward    = 2.0;   // TP = RR × range height
input bool     InpUseEmaFilter  = false; // Use 200 EMA on chart timeframe

input group "=== Volume-confirmed breakout (CFD) ==="
input bool     InpUseVolumeFilter      = true;
input int      InpVolAvgPeriod         = 20;
input double   InpVolMinRelMult        = 1.5;
input bool     InpVolRequireRising     = true;
input bool     InpVolUseCandleStrength = true;
input double   InpVolMinCloseFrac      = 0.70;

input group "=== SMC / OB confluence (optional) ==="
input bool     InpUseSMCFilter  = false; // Require min score before ORB signal
input bool     InpShowSMCRow    = true;  // Show SMC score on dashboard
input int      InpSMCLookback   = 40;
input int      InpSMCMinScore   = 1;     // Min matching patterns (of enabled toggles)
input double   InpSMCImpulseAtrMult = 1.15; // Normal OB impulse vs ATR(14)
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

input group "=== Display ==="
input color    InpAsiaColor     = clrMediumSeaGreen;
input color    InpLondonColor   = clrDodgerBlue;
input color    InpNYColor       = clrOrange;
input color    InpSLColor       = clrCrimson;
input color    InpTPColor       = clrLime;
input int      InpLineWidth     = 2;
input bool     InpShowSignals   = true;
input bool     InpShowDashboard = true;
input int      InpPanelFontSize = 10;
input bool     InpDrawBoxes     = true;
input int      InpBoxAlpha      = 30;    // Box fill opacity 0-255 (low = transparent)

input group "=== Alerts ==="
input bool     InpAlertPopup    = true;  // MT5 popup alert dialog
input bool     InpAlertSound    = true;  // Sound alert
input bool     InpAlertPush     = true;  // Push notification (MT5 mobile app)

input group "=== COT weekly (reads MQL5\\Files — use EA or Script to fetch API) ==="
input bool     InpCotShowDashboard = true;  // Show COT block on panel
input string   InpCotFileName      = "COT_GOLD.csv";
input bool     InpCotFileCommon    = false;   // true = shared terminal Files folder
input int      InpCotReloadHours   = 24;    // Reload CSV periodically (0 = only on init)
input double   InpCotNeutralBand   = 0;     // Abs net below this = neutral bias label

//--- Globals
string g_prefix   = "ORB_";      // OnDeinit: delete all indicator objects
string g_vprefix  = "ORB_V_";    // Chart visuals (boxes, lines) — deleted each DrawAll
string g_dprefix  = "ORB_D_";    // Dashboard panel — updated in place, not bulk-deleted

double g_asiaHigh, g_asiaLow, g_asiaRange;    bool g_asiaValid;
datetime g_asiaT1, g_asiaT2;
double g_londonHigh, g_londonLow, g_londonRange; bool g_londonValid;
datetime g_londonT1, g_londonT2;
double g_nyHigh, g_nyLow, g_nyRange;           bool g_nyValid;
datetime g_nyT1, g_nyT2;

int    g_lastDay    = -1;
string g_phase      = "";
string g_signal     = "";
int    g_signalDir  = 0;
int    g_emaHandle  = INVALID_HANDLE;

SMCScoreResult g_smcLongDetail;
SMCScoreResult g_smcShortDetail;

// Persistent signal levels — stored once triggered, cleared when session expires
double g_sigEntry   = 0;
double g_sigSL      = 0;
double g_sigTP      = 0;
datetime g_sigTime  = 0;
string g_sigLabel   = "";
int    g_sigSession = 0; // 1=Asia, 2=London, 3=NY — used to expire at session boundary

// Bias tracking
int    g_asiaBias   = 0;  // +1 bull, -1 bear, 0 neutral
int    g_londonBias = 0;
int    g_nyBias     = 0;

// Trade outcome tracking per session  [0]=Asia [1]=London [2]=NY
int    g_wins[3]    = {0, 0, 0};
int    g_losses[3]  = {0, 0, 0};
int    g_totalWins  = 0;
int    g_totalLosses= 0;
string g_lastOutcome = "";         // "WIN" / "LOSS" — for dashboard flash
int    g_lastOutcomeSession = -1;  // which session the last outcome belonged to
bool   g_historyReplayed = false;  // ensures ReplayHistory runs only once per load
datetime g_lastAlertTime = 0;      // suppress duplicate alerts for same signal bar

datetime g_cotLastReload = 0;

// Computed broker-time session hours/minutes (set in OnInit)
int    g_asiaH, g_asiaM;
int    g_londonH, g_londonM;
int    g_nyH, g_nyM;
int    g_asiaOrbMins, g_londonOrbMins, g_nyOrbMins;

//+------------------------------------------------------------------+
//| Gold_ORB_Common.mqh (inlined — copy only this .mq5 to Indicators) |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
double GetPipSize()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
      return MathMax(0.1, point * 10);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return (digits == 3 || digits == 5) ? point * 10 : point;
}
double Pips(double p) { return p * GetPipSize(); }

//+------------------------------------------------------------------+
void SendOrbAlert(const string msg)
{
   if(!InpAlertPopup && !InpAlertSound && !InpAlertPush) return;
   if(InpAlertPopup) Alert(msg);
   if(InpAlertSound) PlaySound("alert.wav");
   if(InpAlertPush)  SendNotification(msg);
}

//+------------------------------------------------------------------+
int OnInit()
{
   // Remove objects from any prior version (e.g. ORB_AsiaBox vs ORB_V_AsiaBox) so nothing is left behind.
   ObjectsDeleteAll(0, g_prefix);

   ORB_CSTToBroker(InpAsiaOpenCST,   InpBrokerGMTOffset, g_asiaH,   g_asiaM);
   ORB_CSTToBroker(InpLondonOpenCST, InpBrokerGMTOffset, g_londonH, g_londonM);
   ORB_CSTToBroker(InpNYOpenCST,     InpBrokerGMTOffset, g_nyH,     g_nyM);
   g_asiaOrbMins   = InpAsiaORBMins;
   g_londonOrbMins = InpLondonORBMins;
   g_nyOrbMins     = InpNYORBMins;

   if(InpUseEmaFilter)
      g_emaHandle = iMA(_Symbol, ORB_CHART_TF, 200, 0, MODE_EMA, PRICE_CLOSE);

   if(Period() != ORB_CHART_TF)
      Print("GOLD_ORB WARNING: attach to ", EnumToString(ORB_CHART_TF),
            " chart. Current=", EnumToString(Period()), " (signals/SMC/EMA assume M5).");

   Print("ORB Indicator: Asia=", g_asiaH, ":", g_asiaM, " (", g_asiaOrbMins, "min)",
         " | London=", g_londonH, ":", g_londonM, " (", g_londonOrbMins, "min)",
         " | NY=", g_nyH, ":", g_nyM, " (", g_nyOrbMins, "min)",
         " | rangeTF=", EnumToString(ORB_RANGE_TF), " signalTF=", EnumToString(ORB_CHART_TF));
   g_cotLastReload = TimeCurrent();
   if(InpCotShowDashboard && StringLen(InpCotFileName) > 0)
   {
      if(COT_LoadFromFile(InpCotFileName, InpCotFileCommon))
         Print(g_cot_last_load_msg);
      else
         Print(g_cot_last_load_msg);
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
   ObjectsDeleteAll(0, g_prefix);
}

//+------------------------------------------------------------------+
// Replay: ORB ranges from M15; breakout simulation on M5 (chart TF).
//+------------------------------------------------------------------+
void ReplayHistory()
{
   datetime dayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));

   int dayBarIdxM15 = iBarShift(_Symbol, ORB_RANGE_TF, dayStart, false);
   if(dayBarIdxM15 < 0) return;
   int cntM15 = dayBarIdxM15 + 1;
   double h15[], l15[];
   datetime t15[];
   if(CopyHigh (_Symbol, ORB_RANGE_TF, 0, cntM15, h15) != cntM15) return;
   if(CopyLow  (_Symbol, ORB_RANGE_TF, 0, cntM15, l15) != cntM15) return;
   if(CopyTime (_Symbol, ORB_RANGE_TF, 0, cntM15, t15) != cntM15) return;

   int dayBarIdx = iBarShift(_Symbol, ORB_CHART_TF, dayStart, false);
   if(dayBarIdx < 2) return;

   double hArr[], lArr[], cArr[];
   datetime tArr[];
   int cnt = dayBarIdx + 1;
   if(CopyClose(_Symbol, ORB_CHART_TF, 0, cnt, cArr) != cnt) return;
   if(CopyHigh (_Symbol, ORB_CHART_TF, 0, cnt, hArr) != cnt) return;
   if(CopyLow  (_Symbol, ORB_CHART_TF, 0, cnt, lArr) != cnt) return;
   if(CopyTime (_Symbol, ORB_CHART_TF, 0, cnt, tArr) != cnt) return;

   double asiaStartF   = g_asiaH   + g_asiaM   / 60.0;
   double asiaEndF     = ORB_OrbEndFrac(g_asiaH,   g_asiaM,   g_asiaOrbMins);
   double londonStartF = g_londonH + g_londonM / 60.0;
   double londonEndF   = ORB_OrbEndFrac(g_londonH, g_londonM, g_londonOrbMins);
   double nyStartF     = g_nyH     + g_nyM     / 60.0;
   double nyEndF       = ORB_OrbEndFrac(g_nyH,     g_nyM,     g_nyOrbMins);

   // Phase 1: ORB ranges from M15 bars only
   double rAsiaH = 0, rAsiaL = 99999, rLonH = 0, rLonL = 99999, rNYH = 0, rNYL = 99999;
   bool rAsiaOk = false, rLonOk = false, rNYOk = false;

   for(int i = 0; i < cntM15; i++)
   {
      MqlDateTime bdt; TimeToStruct(t15[i], bdt);
      double bH = bdt.hour + bdt.min / 60.0;

      if(bH >= asiaStartF && bH < asiaEndF)
      {
         if(h15[i] > rAsiaH) rAsiaH = h15[i];
         if(l15[i] < rAsiaL) rAsiaL = l15[i];
         rAsiaOk = true;
      }
      if(bH >= londonStartF && bH < londonEndF)
      {
         if(h15[i] > rLonH) rLonH = h15[i];
         if(l15[i] < rLonL) rLonL = l15[i];
         rLonOk = true;
      }
      if(bH >= nyStartF && bH < nyEndF)
      {
         if(h15[i] > rNYH) rNYH = h15[i];
         if(l15[i] < rNYL) rNYL = l15[i];
         rNYOk = true;
      }
   }

   rAsiaOk   = rAsiaOk   && (rAsiaH - rAsiaL) >= Pips(InpMinRangePips);
   rLonOk    = rLonOk    && (rLonH  - rLonL)  >= Pips(InpMinRangePips);
   rNYOk     = rNYOk     && (rNYH   - rNYL)   >= Pips(InpMinRangePips);

   // Phase 2: M5 bars — breakouts and SL/TP
   int    sigDir = 0;
   double sigEntry = 0, sigSL = 0, sigTP = 0;
   int    sigSess = 0;        // 1=Asia, 2=London, 3=NY
   datetime sigTime = 0;
   string sigLabel = "";

   for(int i = 1; i < cnt - 1; i++) // i is the "current" bar, i-1 is the previous
   {
      MqlDateTime bdt; TimeToStruct(tArr[i], bdt);
      double bH = bdt.hour + bdt.min / 60.0;

      // Check active signal for SL/TP hit
      if(sigDir != 0)
      {
         bool hitTP = false, hitSL = false;
         if(sigDir == 1)
         {
            if(hArr[i] >= sigTP)  hitTP = true;
            if(lArr[i] <= sigSL)  hitSL = true;
         }
         else
         {
            if(lArr[i] <= sigTP)  hitTP = true;
            if(hArr[i] >= sigSL)  hitSL = true;
         }

         // Expire Asia signals at London start, London signals at NY start
         bool expired = false;
         if(sigSess == 1 && bH >= londonStartF) expired = true;
         if(sigSess == 2 && bH >= nyStartF)     expired = true;

         if(hitTP || hitSL)
         {
            int idx = sigSess - 1;
            if(idx >= 0 && idx < 3)
            {
               if(hitTP) { g_wins[idx]++;   g_totalWins++;   g_lastOutcome = "WIN";  }
               else      { g_losses[idx]++; g_totalLosses++; g_lastOutcome = "LOSS"; }
               g_lastOutcomeSession = idx;
            }
            sigDir = 0; sigEntry = sigSL = sigTP = 0; sigSess = 0; sigTime = 0; sigLabel = "";
         }
         else if(expired)
         {
            sigDir = 0; sigEntry = sigSL = sigTP = 0; sigSess = 0; sigTime = 0; sigLabel = "";
         }
      }

      // Detect new breakouts (only when no active signal)
      // Requires crossover: current bar closes beyond range, previous bar was inside
      if(sigDir == 0 && i >= 2)
      {
         double c_cur = cArr[i], c_prev = cArr[i - 1];

         // Asia breakout
         if(rAsiaOk && bH >= asiaEndF && bH < londonStartF)
         {
            if(c_cur > rAsiaH && c_prev <= rAsiaH)
            {
               double risk = c_cur - rAsiaL;
               sigDir = 1; sigSess = 1; sigEntry = c_cur;
               sigSL = rAsiaL; sigTP = c_cur + risk * InpRiskReward;
               sigTime = tArr[i]; sigLabel = "ASIAN LONG";
            }
            else if(c_cur < rAsiaL && c_prev >= rAsiaL)
            {
               double risk = rAsiaH - c_cur;
               sigDir = -1; sigSess = 1; sigEntry = c_cur;
               sigSL = rAsiaH; sigTP = c_cur - risk * InpRiskReward;
               sigTime = tArr[i]; sigLabel = "ASIAN SHORT";
            }
         }
         // London breakout
         if(sigDir == 0 && rLonOk && bH >= londonEndF && bH < nyStartF)
         {
            if(c_cur > rLonH && c_prev <= rLonH)
            {
               double risk = c_cur - rLonL;
               sigDir = 1; sigSess = 2; sigEntry = c_cur;
               sigSL = rLonL; sigTP = c_cur + risk * InpRiskReward;
               sigTime = tArr[i]; sigLabel = "LONDON LONG";
            }
            else if(c_cur < rLonL && c_prev >= rLonL)
            {
               double risk = rLonH - c_cur;
               sigDir = -1; sigSess = 2; sigEntry = c_cur;
               sigSL = rLonH; sigTP = c_cur - risk * InpRiskReward;
               sigTime = tArr[i]; sigLabel = "LONDON SHORT";
            }
         }
         // NY breakout
         if(sigDir == 0 && rNYOk && bH >= nyEndF)
         {
            if(c_cur > rNYH && c_prev <= rNYH)
            {
               double risk = c_cur - rNYL;
               sigDir = 1; sigSess = 3; sigEntry = c_cur;
               sigSL = rNYL; sigTP = c_cur + risk * InpRiskReward;
               sigTime = tArr[i]; sigLabel = "NY LONG";
            }
            else if(c_cur < rNYL && c_prev >= rNYL)
            {
               double risk = rNYH - c_cur;
               sigDir = -1; sigSess = 3; sigEntry = c_cur;
               sigSL = rNYH; sigTP = c_cur - risk * InpRiskReward;
               sigTime = tArr[i]; sigLabel = "NY SHORT";
            }
         }
      }
   }

   // Carry over any still-active signal into the live state
   if(sigDir != 0)
   {
      g_signalDir = sigDir;  g_sigSession = sigSess;
      g_sigEntry  = sigEntry; g_sigSL = sigSL; g_sigTP = sigTP;
      g_sigTime   = sigTime;  g_sigLabel = sigLabel;
   }

   Print("ORB ReplayHistory: W=", g_totalWins, " L=", g_totalLosses,
         " | Asia=", g_wins[0], "/", g_losses[0],
         " Lon=", g_wins[1], "/", g_losses[1],
         " NY=", g_wins[2], "/", g_losses[2],
         " | Active=", sigLabel);
}

bool OrbSignalVolumeOK(const datetime barTime, const bool isLong)
{
   return VBF_PassesBreakoutVolume(_Symbol, ORB_CHART_TF, barTime, isLong,
      InpUseVolumeFilter, InpVolAvgPeriod, InpVolMinRelMult, InpVolRequireRising,
      InpVolUseCandleStrength, InpVolMinCloseFrac);
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
{
   if(rates_total < 50) return 0;

   ArraySetAsSeries(time,  true);
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(open,  true);

   // On first full calc after load, replay today's history to rebuild counters
   if(!g_historyReplayed && rates_total > 50)
   {
      g_historyReplayed = true;
      ReplayHistory();
   }

   if(InpCotShowDashboard && StringLen(InpCotFileName) > 0 && InpCotReloadHours > 0)
   {
      int sec = InpCotReloadHours * 3600;
      if(TimeCurrent() - g_cotLastReload >= sec)
      {
         COT_LoadFromFile(InpCotFileName, InpCotFileCommon);
         g_cotLastReload = TimeCurrent();
      }
   }

   MqlDateTime dt;
   TimeToStruct(time[0], dt);
   int bh = dt.hour, bm = dt.min;
   double brokerHour = bh + bm / 60.0;

   // Per-session end times (fractional broker hour)
   double asiaStartH   = g_asiaH   + g_asiaM   / 60.0;
   double asiaEndH     = ORB_OrbEndFrac(g_asiaH,   g_asiaM,   g_asiaOrbMins);
   double londonStartH = g_londonH + g_londonM / 60.0;
   double londonEndH   = ORB_OrbEndFrac(g_londonH, g_londonM, g_londonOrbMins);
   double nyStartH     = g_nyH     + g_nyM     / 60.0;
   double nyEndH       = ORB_OrbEndFrac(g_nyH,     g_nyM,     g_nyOrbMins);

   // Reset on new day
   if(dt.day != g_lastDay)
   {
      g_lastDay = dt.day;
      g_asiaValid = g_londonValid = g_nyValid = false;
      g_asiaT1 = g_asiaT2 = g_londonT1 = g_londonT2 = g_nyT1 = g_nyT2 = 0;
      g_sigEntry = g_sigSL = g_sigTP = 0;
      g_sigTime = 0; g_sigLabel = ""; g_signalDir = 0; g_signal = ""; g_sigSession = 0;
      g_asiaBias = g_londonBias = g_nyBias = 0;
      for(int s = 0; s < 3; s++) { g_wins[s] = 0; g_losses[s] = 0; }
      g_totalWins = 0; g_totalLosses = 0;
      g_lastOutcome = ""; g_lastOutcomeSession = -1;
      g_historyReplayed = false;
      g_lastAlertTime = 0;
   }

   // ── Asian ORB (per-session duration) ──────────────────────────────
   if(brokerHour >= asiaStartH)
   {
      int aeH, aeM;
      ORB_OrbEndHM(g_asiaH, g_asiaM, g_asiaOrbMins, aeH, aeM);

      datetime t1 = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", dt.year, dt.mon, dt.day, g_asiaH, g_asiaM));
      datetime t2;
      if(brokerHour < asiaEndH)
         t2 = time[0];
      else
         t2 = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", dt.year, dt.mon, dt.day, aeH, aeM));

      g_asiaT1 = t1; g_asiaT2 = t2;

      double hi, lo;
      if(ORB_ScanRange(_Symbol, ORB_RANGE_TF, t1, t2, hi, lo))
      {
         g_asiaHigh  = hi; g_asiaLow = lo; g_asiaRange = hi - lo;
         g_asiaValid = (g_asiaRange >= Pips(InpMinRangePips));
      }
   }

   // ── London ORB ────────────────────────────────────────────────────
   if(brokerHour >= londonStartH)
   {
      int leH, leM;
      ORB_OrbEndHM(g_londonH, g_londonM, g_londonOrbMins, leH, leM);

      datetime t1 = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", dt.year, dt.mon, dt.day, g_londonH, g_londonM));
      datetime t2;
      if(brokerHour < londonEndH)
         t2 = time[0];
      else
         t2 = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", dt.year, dt.mon, dt.day, leH, leM));

      g_londonT1 = t1; g_londonT2 = t2;

      double hi, lo;
      if(ORB_ScanRange(_Symbol, ORB_RANGE_TF, t1, t2, hi, lo))
      {
         g_londonHigh  = hi; g_londonLow = lo; g_londonRange = hi - lo;
         g_londonValid = (g_londonRange >= Pips(InpMinRangePips));
      }
   }

   // ── NY ORB ────────────────────────────────────────────────────────
   if(brokerHour >= nyStartH)
   {
      int neH, neM;
      ORB_OrbEndHM(g_nyH, g_nyM, g_nyOrbMins, neH, neM);

      datetime t1 = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", dt.year, dt.mon, dt.day, g_nyH, g_nyM));
      datetime t2;
      if(brokerHour < nyEndH)
         t2 = time[0];
      else
         t2 = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", dt.year, dt.mon, dt.day, neH, neM));

      g_nyT1 = t1; g_nyT2 = t2;

      double hi, lo;
      if(ORB_ScanRange(_Symbol, ORB_RANGE_TF, t1, t2, hi, lo))
      {
         g_nyHigh  = hi; g_nyLow = lo; g_nyRange = hi - lo;
         g_nyValid = (g_nyRange >= Pips(InpMinRangePips));
      }
   }

   // ── Bias (price vs completed range) ───────────────────────────────
   double curBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_asiaValid && brokerHour >= asiaEndH)
   {
      if(curBid > g_asiaHigh)      g_asiaBias =  1;
      else if(curBid < g_asiaLow)  g_asiaBias = -1;
      else                         g_asiaBias =  0;
   }
   if(g_londonValid && brokerHour >= londonEndH)
   {
      if(curBid > g_londonHigh)      g_londonBias =  1;
      else if(curBid < g_londonLow)  g_londonBias = -1;
      else                           g_londonBias =  0;
   }
   if(g_nyValid && brokerHour >= nyEndH)
   {
      if(curBid > g_nyHigh)      g_nyBias =  1;
      else if(curBid < g_nyLow)  g_nyBias = -1;
      else                       g_nyBias =  0;
   }

   // ── Phase ─────────────────────────────────────────────────────────
   if     (brokerHour >= asiaStartH   && brokerHour < asiaEndH)    g_phase = "Asian ORB: Building";
   else if(brokerHour >= asiaEndH     && brokerHour < londonStartH) g_phase = "Asian: Trade window";
   else if(brokerHour >= londonStartH && brokerHour < londonEndH)  g_phase = "London ORB: Building";
   else if(brokerHour >= londonEndH   && brokerHour < nyStartH)    g_phase = "London: Trade window";
   else if(brokerHour >= nyStartH     && brokerHour < nyEndH)      g_phase = "NY ORB: Building";
   else if(brokerHour >= nyEndH)                                   g_phase = "NY: Trade window";
   else                                                            g_phase = "Pre-session";

   // Diagnostic: print once per new bar (chart TF)
   static datetime s_lastBarTime = 0;
   if(time[0] != s_lastBarTime)
   {
      s_lastBarTime = time[0];
      Print("ORB | bar=", TimeToString(time[0]), " brokerH=", DoubleToString(brokerHour,2),
            " asiaStart=", DoubleToString(asiaStartH,2), " asiaEnd=", DoubleToString(asiaEndH,2),
            " lonStart=", DoubleToString(londonStartH,2), " lonEnd=", DoubleToString(londonEndH,2),
            " nyStart=", DoubleToString(nyStartH,2), " nyEnd=", DoubleToString(nyEndH,2),
            " phase=", g_phase,
            " asiaValid=", g_asiaValid, " T1=", TimeToString(g_asiaT1), " T2=", TimeToString(g_asiaT2));
   }

   // ── SL/TP outcome detection ──────────────────────────────────────
   if(g_signalDir != 0 && g_sigEntry > 0)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      bool hitTP = false, hitSL = false;

      if(g_signalDir == 1) // LONG
      {
         if(bid >= g_sigTP)  hitTP = true;
         if(bid <= g_sigSL)  hitSL = true;
      }
      else // SHORT
      {
         if(bid <= g_sigTP)  hitTP = true;
         if(bid >= g_sigSL)  hitSL = true;
      }

      if(hitTP || hitSL)
      {
         int idx = g_sigSession - 1; // 0=Asia, 1=London, 2=NY
         if(idx >= 0 && idx < 3)
         {
            if(hitTP) { g_wins[idx]++;   g_totalWins++;   g_lastOutcome = "WIN";  }
            else      { g_losses[idx]++; g_totalLosses++; g_lastOutcome = "LOSS"; }
            g_lastOutcomeSession = idx;
         }

         // Draw outcome marker on chart
         string markerName = g_vprefix + "Result_" + IntegerToString(g_totalWins + g_totalLosses);
         ObjectCreate(0, markerName, OBJ_ARROW, 0, time[0], hitTP ? g_sigTP : g_sigSL);
         ObjectSetInteger(0, markerName, OBJPROP_ARROWCODE, hitTP ? 252 : 251);
         ObjectSetInteger(0, markerName, OBJPROP_COLOR,     hitTP ? clrLime : clrRed);
         ObjectSetInteger(0, markerName, OBJPROP_WIDTH,     3);
         ObjectSetInteger(0, markerName, OBJPROP_SELECTABLE, false);
         ObjectSetString(0,  markerName, OBJPROP_TEXT,      hitTP ? "TP HIT" : "SL HIT");

         Print("ORB Signal ", g_sigLabel, hitTP ? " TP HIT" : " SL HIT",
               " | Entry=", g_sigEntry, " SL=", g_sigSL, " TP=", g_sigTP);

         // Reset signal so a new breakout in the same session can trigger
         int prevSession = g_sigSession;
         g_signalDir = 0; g_sigEntry = g_sigSL = g_sigTP = 0;
         g_sigTime = 0; g_sigLabel = ""; g_sigSession = 0; g_signal = "";
      }
   }

   // ── Signal expiry at session boundaries ────────────────────────────
   if(g_sigSession == 1 && brokerHour >= londonStartH)
   {
      g_signalDir = 0; g_sigEntry = g_sigSL = g_sigTP = 0;
      g_sigTime = 0; g_sigLabel = ""; g_sigSession = 0; g_signal = "";
   }
   else if(g_sigSession == 2 && brokerHour >= nyStartH)
   {
      g_signalDir = 0; g_sigEntry = g_sigSL = g_sigTP = 0;
      g_sigTime = 0; g_sigLabel = ""; g_sigSession = 0; g_signal = "";
   }

   double ema200 = 0;
   if(InpUseEmaFilter && g_emaHandle != INVALID_HANDLE)
   {
      double ema[]; ArraySetAsSeries(ema, true);
      if(CopyBuffer(g_emaHandle, 0, 1, 1, ema) == 1) ema200 = ema[0];
   }

   double c1 = close[1], c2 = close[2];

   bool fireBreakoutAlert = false;

   SMC_ScoreLong(_Symbol, ORB_CHART_TF, InpSMCLookback, InpSMCImpulseAtrMult, InpSMCTweezerTolPips, InpSMCDojiBodyPct,
                 InpSMCUseFvg, InpSMCUsePin, InpSMCUseDoji, InpSMCUseEng, InpSMCUseTweezer, InpSMCUseLq,
                 InpSMCUseNormalOb, InpSMCUseManip, InpSMCUseMss, InpSMCUseOte, g_smcLongDetail);
   SMC_ScoreShort(_Symbol, ORB_CHART_TF, InpSMCLookback, InpSMCImpulseAtrMult, InpSMCTweezerTolPips, InpSMCDojiBodyPct,
                  InpSMCUseFvg, InpSMCUsePin, InpSMCUseDoji, InpSMCUseEng, InpSMCUseTweezer, InpSMCUseLq,
                  InpSMCUseNormalOb, InpSMCUseManip, InpSMCUseMss, InpSMCUseOte, g_smcShortDetail);
   bool smcLongOk = !InpUseSMCFilter || (g_smcLongDetail.maxScore == 0) || (g_smcLongDetail.score >= InpSMCMinScore);
   bool smcShortOk = !InpUseSMCFilter || (g_smcShortDetail.maxScore == 0) || (g_smcShortDetail.score >= InpSMCMinScore);

   if(g_signalDir == 0)
   {
      // Asian breakout: close[1] crosses beyond range while close[2] was inside
      if(brokerHour >= asiaEndH && brokerHour < londonStartH && g_asiaValid)
      {
         if(smcLongOk && c1 > g_asiaHigh && c2 <= g_asiaHigh && (!InpUseEmaFilter || c1 > ema200)
            && OrbSignalVolumeOK(time[1], true))
         {
            double sl = g_asiaLow;
            double risk = c1 - sl;
            g_signalDir = 1;  g_sigSession = 1;
            g_sigEntry  = c1;
            g_sigSL     = sl;
            g_sigTP     = c1 + risk * InpRiskReward;
            g_sigTime   = time[1];
            g_sigLabel  = "ASIAN LONG";
            fireBreakoutAlert = true;
         }
         else if(smcShortOk && c1 < g_asiaLow && c2 >= g_asiaLow && (!InpUseEmaFilter || c1 < ema200)
            && OrbSignalVolumeOK(time[1], false))
         {
            double sl = g_asiaHigh;
            double risk = sl - c1;
            g_signalDir = -1; g_sigSession = 1;
            g_sigEntry  = c1;
            g_sigSL     = sl;
            g_sigTP     = c1 - risk * InpRiskReward;
            g_sigTime   = time[1];
            g_sigLabel  = "ASIAN SHORT";
            fireBreakoutAlert = true;
         }
      }
      // London breakout
      if(g_signalDir == 0 && brokerHour >= londonEndH && brokerHour < nyStartH && g_londonValid)
      {
         if(smcLongOk && c1 > g_londonHigh && c2 <= g_londonHigh && (!InpUseEmaFilter || c1 > ema200)
            && OrbSignalVolumeOK(time[1], true))
         {
            double sl = g_londonLow;
            double risk = c1 - sl;
            g_signalDir = 1;  g_sigSession = 2;
            g_sigEntry  = c1;
            g_sigSL     = sl;
            g_sigTP     = c1 + risk * InpRiskReward;
            g_sigTime   = time[1];
            g_sigLabel  = "LONDON LONG";
            fireBreakoutAlert = true;
         }
         else if(smcShortOk && c1 < g_londonLow && c2 >= g_londonLow && (!InpUseEmaFilter || c1 < ema200)
            && OrbSignalVolumeOK(time[1], false))
         {
            double sl = g_londonHigh;
            double risk = sl - c1;
            g_signalDir = -1; g_sigSession = 2;
            g_sigEntry  = c1;
            g_sigSL     = sl;
            g_sigTP     = c1 - risk * InpRiskReward;
            g_sigTime   = time[1];
            g_sigLabel  = "LONDON SHORT";
            fireBreakoutAlert = true;
         }
      }
      // NY breakout
      if(g_signalDir == 0 && brokerHour >= nyEndH && g_nyValid)
      {
         if(smcLongOk && c1 > g_nyHigh && c2 <= g_nyHigh && (!InpUseEmaFilter || c1 > ema200)
            && OrbSignalVolumeOK(time[1], true))
         {
            double sl = g_nyLow;
            double risk = c1 - sl;
            g_signalDir = 1;  g_sigSession = 3;
            g_sigEntry  = c1;
            g_sigSL     = sl;
            g_sigTP     = c1 + risk * InpRiskReward;
            g_sigTime   = time[1];
            g_sigLabel  = "NY LONG";
            fireBreakoutAlert = true;
         }
         else if(smcShortOk && c1 < g_nyLow && c2 >= g_nyLow && (!InpUseEmaFilter || c1 < ema200)
            && OrbSignalVolumeOK(time[1], false))
         {
            double sl = g_nyHigh;
            double risk = sl - c1;
            g_signalDir = -1; g_sigSession = 3;
            g_sigEntry  = c1;
            g_sigSL     = sl;
            g_sigTP     = c1 - risk * InpRiskReward;
            g_sigTime   = time[1];
            g_sigLabel  = "NY SHORT";
            fireBreakoutAlert = true;
         }
      }
   }

   if(fireBreakoutAlert && g_sigTime != g_lastAlertTime)
   {
      string amsg = StringFormat("GOLD ORB: %s | Entry: %.2f | SL: %.2f | TP: %.2f (1:%.1fR)",
         g_sigLabel, g_sigEntry, g_sigSL, g_sigTP, InpRiskReward);
      SendOrbAlert(amsg);
      g_lastAlertTime = g_sigTime;
   }

   // Build dashboard signal string
   if(g_signalDir != 0)
      g_signal = StringFormat("%s | Entry:%.2f  SL:%.2f  TP:%.2f  RR:1:%.1f",
                  g_sigLabel, g_sigEntry, g_sigSL, g_sigTP, InpRiskReward);
   else
      g_signal = "";

   DrawAll(dt, time[0]);
   ChartRedraw(0);
   return rates_total;
}

//+------------------------------------------------------------------+
void DrawAll(MqlDateTime &dt, datetime now)
{
   // Only wipe chart visuals each pass — not the dashboard (ORB_D_*), or the panel flickers.
   ObjectsDeleteAll(0, g_vprefix);
   if(!InpShowDashboard)
      ObjectsDeleteAll(0, g_dprefix);

   // ── ORB Boxes ─────────────────────────────────────────────────────
   if(InpDrawBoxes)
   {
      if(g_asiaT1 > 0 && g_asiaHigh > g_asiaLow)
         DrawBox(g_vprefix+"AsiaBox", g_asiaT1, g_asiaT2, g_asiaLow, g_asiaHigh, InpAsiaColor, "Asian ORB");
      if(g_londonT1 > 0 && g_londonHigh > g_londonLow)
         DrawBox(g_vprefix+"LonBox", g_londonT1, g_londonT2, g_londonLow, g_londonHigh, InpLondonColor, "London ORB");
      if(g_nyT1 > 0 && g_nyHigh > g_nyLow)
         DrawBox(g_vprefix+"NYBox", g_nyT1, g_nyT2, g_nyLow, g_nyHigh, InpNYColor, "NY ORB");
   }

   // ── Horizontal level lines (extend right from ORB) ────────────────
   if(g_asiaValid)
   {
      DrawHLine(g_vprefix+"AsiaH",  g_asiaHigh,  InpAsiaColor, "Asia H");
      DrawHLine(g_vprefix+"AsiaL",  g_asiaLow,   InpAsiaColor, "Asia L");
   }
   if(g_londonValid)
   {
      DrawHLine(g_vprefix+"LonH",  g_londonHigh,  InpLondonColor, "London H");
      DrawHLine(g_vprefix+"LonL",  g_londonLow,   InpLondonColor, "London L");
   }
   if(g_nyValid)
   {
      DrawHLine(g_vprefix+"NYH",  g_nyHigh,  InpNYColor, "NY H");
      DrawHLine(g_vprefix+"NYL",  g_nyLow,   InpNYColor, "NY L");
   }

   // ── Signal Visuals ────────────────────────────────────────────────
   if(InpShowSignals && g_signalDir != 0 && g_sigTime > 0)
   {
      color sigColor = (g_signalDir == 1) ? clrLime : clrOrangeRed;

      // Arrow on the breakout bar
      string arr = g_vprefix+"Arrow";
      if(ObjectFind(0, arr) < 0) ObjectCreate(0, arr, OBJ_ARROW, 0, g_sigTime, g_sigEntry);
      ObjectSetInteger(0, arr, OBJPROP_TIME,       g_sigTime);
      ObjectSetDouble(0,  arr, OBJPROP_PRICE,      g_sigEntry);
      ObjectSetInteger(0, arr, OBJPROP_ARROWCODE,  g_signalDir == 1 ? 233 : 234);
      ObjectSetInteger(0, arr, OBJPROP_COLOR,      sigColor);
      ObjectSetInteger(0, arr, OBJPROP_WIDTH,      4);
      ObjectSetInteger(0, arr, OBJPROP_ANCHOR,     g_signalDir == 1 ? ANCHOR_TOP : ANCHOR_BOTTOM);
      ObjectSetInteger(0, arr, OBJPROP_SELECTABLE, false);

      // Signal label next to arrow
      string lbl = g_vprefix+"SigLbl";
      if(ObjectFind(0, lbl) < 0) ObjectCreate(0, lbl, OBJ_TEXT, 0, g_sigTime, g_sigEntry);
      ObjectSetInteger(0, lbl, OBJPROP_TIME,  g_sigTime);
      ObjectSetDouble(0,  lbl, OBJPROP_PRICE, g_sigEntry + (g_signalDir == 1 ? -Pips(8) : Pips(8)));
      ObjectSetString(0,  lbl, OBJPROP_TEXT,  g_sigLabel);
      ObjectSetString(0,  lbl, OBJPROP_FONT,  "Arial Bold");
      ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE,   9);
      ObjectSetInteger(0, lbl, OBJPROP_COLOR,      sigColor);
      ObjectSetInteger(0, lbl, OBJPROP_ANCHOR,     ANCHOR_RIGHT);
      ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);

      // Entry line (dashed, signal color)
      DrawSignalLine(g_vprefix+"Entry", g_sigEntry, sigColor,       STYLE_DOT,  1,
                     StringFormat("Entry: %.2f", g_sigEntry));

      // SL line (red, solid)
      DrawSignalLine(g_vprefix+"SL",    g_sigSL,    clrCrimson,     STYLE_SOLID, 2,
                     StringFormat("SL: %.2f", g_sigSL));

      // TP line (lime/orange, solid)
      DrawSignalLine(g_vprefix+"TP",    g_sigTP,    clrDodgerBlue,  STYLE_SOLID, 2,
                     StringFormat("TP: %.2f  (1:%.1fR)", g_sigTP, InpRiskReward));

      // SL/TP zone fill (semi-transparent rectangle from entry to SL)
      DrawZone(g_vprefix+"RiskZone", g_sigTime, now, g_sigEntry, g_sigSL, clrCrimson);
      DrawZone(g_vprefix+"RewardZone", g_sigTime, now, g_sigEntry, g_sigTP, clrLimeGreen);
   }

   // ── Dashboard ─────────────────────────────────────────────────────
   if(InpShowDashboard) DrawDashboard(dt, now);
}

//+------------------------------------------------------------------+
void DrawBox(string name, datetime t1, datetime t2, double lo, double hi, color clr, string lbl)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, lo, t2, hi);
   ObjectSetInteger(0, name, OBJPROP_TIME,  0, t1);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 0, lo);
   ObjectSetInteger(0, name, OBJPROP_TIME,  1, t2);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 1, hi);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL,  true);
   ObjectSetInteger(0, name, OBJPROP_BACK,  true);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, InpLineWidth);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString(0,  name, OBJPROP_TEXT, lbl);
}

void DrawSignalLine(string name, double price, color clr, int style, int width, string lbl)
{
   if(price <= 0) return;
   if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0,  name, OBJPROP_PRICE,      price);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,      width);
   ObjectSetInteger(0, name, OBJPROP_STYLE,      style);
   ObjectSetString(0,  name, OBJPROP_TEXT,       lbl);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void DrawZone(string name, datetime t1, datetime t2, double p1, double p2, color clr)
{
   if(p1 <= 0 || p2 <= 0 || t1 >= t2) return;
   double lo = MathMin(p1, p2), hi = MathMax(p1, p2);
   if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, lo, t2, hi);
   ObjectSetInteger(0, name, OBJPROP_TIME,  0, t1);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 0, lo);
   ObjectSetInteger(0, name, OBJPROP_TIME,  1, t2);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, 1, hi);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL,  true);
   ObjectSetInteger(0, name, OBJPROP_BACK,  true);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void DrawHLine(string name, double price, color clr, string lbl)
{
   if(price <= 0) return;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0,  name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, InpLineWidth);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetString(0,  name, OBJPROP_TEXT, lbl);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
int ORB_IndTextWidthPx(const string txt, const int fontSize)
{
   int len = StringLen(txt);
   if(len <= 0 || fontSize <= 0) return 0;
   // Consolas in MT5: average glyph wider than 0.56×fs; "|", "—", digits need headroom.
   int w = (int)(len * fontSize * 72 / 100) + fontSize * 2 + 32;
   return w;
}

int ORB_IndMaxTextWidthPx(const string &lines[], const int count, const int fontSize)
{
   int mx = 0;
   for(int i = 0; i < count; i++)
   {
      int w = ORB_IndTextWidthPx(lines[i], fontSize);
      if(w > mx) mx = w;
   }
   // Safety margin so long SMC/COT lines are not clipped at different DPI/scaling.
   return (int)(mx * 118 / 100);
}

void ORB_IndClearUnusedDashLabels(const string prefix, const int numUsed)
{
   for(int j = numUsed; j < ORB_IND_DASH_MAX_LABELS; j++)
   {
      string nx = prefix + "L" + IntegerToString(j);
      if(ObjectFind(0, nx) >= 0)
         ObjectSetString(0, nx, OBJPROP_TEXT, "");
   }
}

//+------------------------------------------------------------------+
void DrawDashboard(MqlDateTime &dt, const datetime now)
{
   int smcExtra = InpShowSMCRow ? 1 : 0;
   int numLines = 15 + (InpCotShowDashboard ? 4 : 0) + smcExtra;
   string lines[];
   ArrayResize(lines, numLines);
   int lineH = InpPanelFontSize + 6;
   const int padSide = 16;
   const int padTop  = 10;
   const int padBot  = 8;

   string bg = g_dprefix+"Bg";
   if(ObjectFind(0, bg) < 0)
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE,   5);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE,   20);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR,      C'20,20,30');
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE,  BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR,        clrDimGray);
   ObjectSetInteger(0, bg, OBJPROP_BACK,         false);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE,   false);
   ObjectSetInteger(0, bg, OBJPROP_ZORDER,       100);

   lines[0] = StringFormat("GOLD ORB v%s  M5 sig / M15 range  GMT+%d  %02d:%02d",
      ORB_INDICATOR_VERSION, InpBrokerGMTOffset, dt.hour, dt.min);
   lines[1] = "Phase: " + g_phase;
   lines[2] = "─────────────────────────────";
   lines[3] = g_asiaValid
      ? StringFormat("Asian  H:%.2f  L:%.2f  (%.0fp)", g_asiaHigh, g_asiaLow, g_asiaRange/GetPipSize())
      : "Asian ORB: —";
   lines[4] = g_londonValid
      ? StringFormat("London H:%.2f  L:%.2f  (%.0fp)", g_londonHigh, g_londonLow, g_londonRange/GetPipSize())
      : "London ORB: —";
   lines[5] = g_nyValid
      ? StringFormat("NY     H:%.2f  L:%.2f  (%.0fp)", g_nyHigh, g_nyLow, g_nyRange/GetPipSize())
      : "NY ORB: —";
   lines[6] = StringFormat("Bias  A:%s  L:%s  NY:%s",
      (g_asiaBias > 0) ? "BULL" : (g_asiaBias < 0) ? "BEAR" : "---",
      (g_londonBias > 0) ? "BULL" : (g_londonBias < 0) ? "BEAR" : "---",
      (g_nyBias > 0) ? "BULL" : (g_nyBias < 0) ? "BEAR" : "---");
   lines[7] = "─────────────────────────────";

   // Active signal or waiting
   if(g_signalDir != 0)
   {
      lines[8] = StringFormat("%s  Entry: %.2f", g_sigLabel, g_sigEntry);
      lines[9] = StringFormat("  SL: %.2f   TP: %.2f  (1:%.1fR)", g_sigSL, g_sigTP, InpRiskReward);
   }
   else if(g_lastOutcome != "")
   {
      lines[8] = StringFormat("Last: %s — awaiting new breakout", g_lastOutcome);
      lines[9] = " ";
   }
   else
   {
      lines[8] = "Signal: Wait for ORB breakout";
      lines[9] = " ";
   }

   int row = 10;
   if(InpShowSMCRow)
   {
      string smcL = StringFormat("SMC long %d/%d %s | short %d/%d %s  (%s)",
         g_smcLongDetail.score, g_smcLongDetail.maxScore, (g_smcLongDetail.tag == "" ? "—" : g_smcLongDetail.tag),
         g_smcShortDetail.score, g_smcShortDetail.maxScore, (g_smcShortDetail.tag == "" ? "—" : g_smcShortDetail.tag),
         InpUseSMCFilter ? ("filter min " + IntegerToString(InpSMCMinScore)) : "info only");
      lines[row++] = smcL;
   }

   int baseIdx = 0;
   if(InpCotShowDashboard)
   {
      double nnc = 0, nco = 0, dlt = 0;
      datetime rd = 0;
      bool have = false;
      string cot1 = "COT: (add COT_GOLD.csv to MQL5\\Files)";
      string cot2 = "";
      string cot3 = "";
      string cot4 = " ";
      if(StringLen(InpCotFileName) > 0 && COT_GetSnapshotForDay(now, nnc, nco, rd, dlt, have) && have)
      {
         cot1 = StringFormat("COT report %s", TimeToString(rd, TIME_DATE));
         cot2 = StringFormat("Net non-comm  %s  (WoW %s)",
            DoubleToString(nnc, 0), DoubleToString(dlt, 0));
         cot3 = StringFormat("Net commercial  %s   %s",
            DoubleToString(nco, 0), COT_FormatBias(nnc, InpCotNeutralBand));
         cot4 = "Non-comm net = longs - shorts (weekly CFTC-style)";
      }
      else if(StringLen(InpCotFileName) > 0 && g_cot_count <= 0)
         cot1 = "COT: no data — run EA (auto-fetch) or Script COT_FetchGold_COT / " + InpCotFileName;

      lines[row++] = "─────────────────────────────";
      lines[row++] = cot1;
      lines[row++] = cot2;
      lines[row++] = cot3;
      lines[row++] = cot4;
      baseIdx = row;
   }
   else
   {
      lines[row++] = "─────────────────────────────";
      baseIdx = row;
   }

   // Per-session trade counters
   lines[baseIdx] = StringFormat("Signals  A:%dW/%dL  L:%dW/%dL  NY:%dW/%dL",
      g_wins[0], g_losses[0], g_wins[1], g_losses[1], g_wins[2], g_losses[2]);

   int allTotal = g_totalWins + g_totalLosses;
   lines[baseIdx + 1] = StringFormat("Total: %d signals  %dW / %dL  (%.0f%% WR)",
      allTotal, g_totalWins, g_totalLosses, (allTotal > 0) ? (g_totalWins * 100.0 / allTotal) : 0);

   // Last outcome flash
   if(g_lastOutcome != "")
   {
      string sessName = (g_lastOutcomeSession == 0) ? "Asia" :
                        (g_lastOutcomeSession == 1) ? "London" : "NY";
      lines[baseIdx + 2] = StringFormat("Last result: %s %s", sessName, g_lastOutcome);
   }
   else
      lines[baseIdx + 2] = " ";

   lines[baseIdx + 3] = " ";

   int boxW = ORB_IndMaxTextWidthPx(lines, numLines, InpPanelFontSize) + padSide * 2;
   boxW = (int)MathMax(300, MathMin(1200, boxW));
   int boxH = padTop + numLines * lineH + padBot;
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, boxW);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, boxH);

   const int labelX = 5 + padSide;
   const int labelY0 = 20 + padTop;

   color sigClr = (g_signalDir == 1) ? clrLime : clrOrangeRed;
   for(int i = 0; i < numLines; i++)
   {
      string n = g_dprefix + "L" + IntegerToString(i);
      if(ObjectFind(0, n) < 0)
         ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_XDISTANCE,   labelX);
      ObjectSetInteger(0, n, OBJPROP_YDISTANCE,   labelY0 + i * lineH);
      ObjectSetInteger(0, n, OBJPROP_ANCHOR,      ANCHOR_LEFT_UPPER);
      ObjectSetString(0,  n, OBJPROP_TEXT,        lines[i]);
      ObjectSetString(0,  n, OBJPROP_FONT,        "Consolas");
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE,    InpPanelFontSize);
      color rowClr = clrWhite;
      if(i == 0)                                          rowClr = clrYellow;
      else if(i == 2 || i == 7 || StringFind(lines[i], "────────") >= 0) rowClr = clrDimGray;
      else if(i == 6)                                     rowClr = clrCyan;
      else if((i == 8 || i == 9) && g_signalDir != 0)     rowClr = sigClr;
      else if(InpShowSMCRow && i == 10)                   rowClr = clrPlum;
      else if(InpCotShowDashboard && i >= baseIdx - 4 && i <= baseIdx - 1) rowClr = clrDarkTurquoise;
      else if(i == baseIdx)                               rowClr = clrGold;
      else if(i == baseIdx + 1)                           rowClr = clrSkyBlue;
      else if(i == baseIdx + 2 && g_lastOutcome == "WIN") rowClr = clrLime;
      else if(i == baseIdx + 2 && g_lastOutcome == "LOSS") rowClr = clrRed;
      ObjectSetInteger(0, n, OBJPROP_COLOR,       rowClr);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(0, n, OBJPROP_ZORDER,      101);
   }
   ORB_IndClearUnusedDashLabels(g_dprefix, numLines);
}
//+------------------------------------------------------------------+
