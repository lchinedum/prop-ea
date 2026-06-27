//+------------------------------------------------------------------+
//| Gold_ORB_COT.mqh                                                |
//| Weekly COT snapshot loader (CSV) for GOLD_ORB indicator / EA.   |
//| Place this file in MQL5\Include\                                |
//| Data file: MQL5\Files\<filename> (or Common\MQL5\Files if       |
//|   useCommonFolder=true).                                          |
//|                                                                   |
//| CSV format (comma-separated, one row per report week):            |
//|   date,net_noncommercial,net_commercial                         |
//|   2024.01.02,150000,-120000                                     |
//| Dates: YYYY.MM.DD or YYYY-MM-DD. Lines starting with # ignored. |
//| First row may be a header containing "date".                      |
//| net_* = long minus short contracts (your source / spreadsheet). |
//|                                                                   |
//| Auto-fetch: CFTC Disaggregated Futures (Socrata) — contract       |
//| 088691 GOLD. Uses managed-money net as "non-comm" proxy and       |
//| producer/merchant net as "commercial". Requires WebRequest URL:   |
//| https://publicreporting.cftc.gov in Terminal → Options → Experts. |
//+------------------------------------------------------------------+
#ifndef GOLD_ORB_COT_MQH
#define GOLD_ORB_COT_MQH

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

#endif // GOLD_ORB_COT_MQH
