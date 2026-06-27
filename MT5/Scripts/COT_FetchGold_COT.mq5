//+------------------------------------------------------------------+
//| COT_FetchGold_COT.mq5                                            |
//| One-click download: CFTC Disaggregated GOLD → MQL5\\Files cache |
//| Place in MQL5\\Scripts\\ and Run. Requires WebRequest allow:     |
//| https://publicreporting.cftc.gov (Terminal → Options → Experts). |
//+------------------------------------------------------------------+
#property copyright "COT fetch"
#property version   "1.00"
#property script_show_inputs

#include <Gold_ORB_COT.mqh>

input string InpCacheFile   = "COT_GOLD.csv";
input bool   InpFileCommon  = false;
input int    InpTimeoutMs   = 25000;
input string InpUrlOverride = "";

void OnStart()
{
   if(COT_FetchCftcGoldWeb(InpTimeoutMs, InpUrlOverride, true, InpCacheFile, InpFileCommon))
      Print("OK: ", g_cot_last_load_msg);
   else
      Print("FAIL: ", g_cot_last_load_msg, " | ", g_cot_last_http_info);
}
