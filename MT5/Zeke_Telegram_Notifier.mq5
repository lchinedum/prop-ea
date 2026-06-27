//+------------------------------------------------------------------+
//| Zeke_Telegram_Notifier.mq5                                       |
//| Zeke Trading — standalone trade alerts to Telegram channel       |
//| Attach to any chart; monitors account deals via OnTradeTransaction|
//+------------------------------------------------------------------+
#property copyright "Zeke Trading"
#property version   "1.00"
#property strict

input group "=== Telegram ==="
input string   InpBotToken      = "8867534633:AAHn3IEQXzFQ658RgdELxKASL3iBwlYT2nM"; // Bot token (from @BotFather)
input string   InpChatId        = "@zeketrading";     // Channel: @username or -100...
input int      InpTimeoutMs     = 5000;               // WebRequest timeout (ms)

input group "=== Filters ==="
input ulong    InpMagicFilter   = 0;                  // 0 = all trades; else magic only
input string   InpSymbolFilter  = "";                 // Empty = all symbols
input bool     InpNotifyOpen    = true;               // Notify position open
input bool     InpNotifyClose   = true;               // Notify position close
input bool     InpNotifyPartial = true;               // Notify partial close / reverse

input group "=== Message ==="
input bool     InpShowSLTP      = true;               // Include SL/TP on open
input bool     InpShowProfit    = true;               // Include P/L on close
input bool     InpUseEmojis     = true;               // Use emoji prefixes

//--- runtime
bool g_webrequest_ok = false;

//+------------------------------------------------------------------+
string UrlEncode(const string text)
{
   string out = "";
   uchar data[];
   int n = StringToCharArray(text, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(n <= 0) return "";

   for(int i = 0; i < n - 1; i++)
   {
      uchar c = data[i];
      if((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
         (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~')
         out += CharToString(c);
      else if(c == ' ')
         out += "%20";
      else
         out += StringFormat("%%%02X", c);
   }
   return out;
}

//+------------------------------------------------------------------+
int SymbolDigitsFor(const string symbol)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits <= 0) digits = _Digits;
   return digits;
}

//+------------------------------------------------------------------+
bool SendTelegram(const string message)
{
   if(StringLen(InpBotToken) == 0 || StringLen(InpChatId) == 0)
   {
      Print("Telegram: bot token or chat id not set");
      return false;
   }

   if(MQLInfoInteger(MQL_TESTER) != 0)
   {
      Print("Telegram: skipped in Strategy Tester");
      return false;
   }

   string url = "https://api.telegram.org/bot" + InpBotToken +
                "/sendMessage?chat_id=" + UrlEncode(InpChatId) +
                "&text=" + UrlEncode(message);

   char post[];
   char result[];
   string headers;
   ArrayResize(post, 0);

   ResetLastError();
   int code = WebRequest("GET", url, "", InpTimeoutMs, post, result, headers);
   if(code == -1)
   {
      int err = GetLastError();
      Print("Telegram WebRequest failed err=", err,
            " — add https://api.telegram.org in Tools → Options → Expert Advisors");
      return false;
   }

   if(code != 200)
   {
      string body = CharArrayToString(result);
      Print("Telegram HTTP ", code, ": ", body);
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
string DealSide(const long deal_type)
{
   if(deal_type == DEAL_TYPE_BUY)  return "BUY";
   if(deal_type == DEAL_TYPE_SELL) return "SELL";
   return "UNKNOWN";
}

//+------------------------------------------------------------------+
string EntryLabel(const long entry)
{
   if(entry == DEAL_ENTRY_IN)    return "OPEN";
   if(entry == DEAL_ENTRY_OUT)   return "CLOSE";
   if(entry == DEAL_ENTRY_INOUT) return "PARTIAL";
   return "DEAL";
}

//+------------------------------------------------------------------+
string EmojiFor(const long entry, const long deal_type)
{
   if(!InpUseEmojis) return "";

   if(entry == DEAL_ENTRY_IN)
      return (deal_type == DEAL_TYPE_BUY) ? "🟢 " : "🔴 ";

   if(entry == DEAL_ENTRY_OUT)
      return "✅ ";

   return "ℹ️ ";
}

//+------------------------------------------------------------------+
bool PassesFilters(const ulong deal)
{
   if(InpMagicFilter > 0 &&
      HistoryDealGetInteger(deal, DEAL_MAGIC) != (long)InpMagicFilter)
      return false;

   if(StringLen(InpSymbolFilter) > 0)
   {
      string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
      if(sym != InpSymbolFilter)
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
bool ShouldNotify(const long entry)
{
   if(entry == DEAL_ENTRY_IN)    return InpNotifyOpen;
   if(entry == DEAL_ENTRY_OUT)   return InpNotifyClose;
   if(entry == DEAL_ENTRY_INOUT) return InpNotifyPartial;
   return false;
}

//+------------------------------------------------------------------+
string FormatDealMessage(const ulong deal)
{
   string sym     = HistoryDealGetString(deal, DEAL_SYMBOL);
   long   type      = HistoryDealGetInteger(deal, DEAL_TYPE);
   long   entry     = HistoryDealGetInteger(deal, DEAL_ENTRY);
   double vol       = HistoryDealGetDouble(deal, DEAL_VOLUME);
   double price     = HistoryDealGetDouble(deal, DEAL_PRICE);
   double profit    = HistoryDealGetDouble(deal, DEAL_PROFIT);
   double commission= HistoryDealGetDouble(deal, DEAL_COMMISSION);
   double swap      = HistoryDealGetDouble(deal, DEAL_SWAP);
   long   magic     = HistoryDealGetInteger(deal, DEAL_MAGIC);
   string comment   = HistoryDealGetString(deal, DEAL_COMMENT);
   ulong  pos_id    = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);

   int digits = SymbolDigitsFor(sym);
   string side  = DealSide(type);
   string label = EntryLabel(entry);

   string msg = "Zeke Trading\n";
   msg += EmojiFor(entry, type) + label + " " + side + " " + sym + "\n";
   msg += "Lot: " + DoubleToString(vol, 2) + "\n";
   msg += "Price: " + DoubleToString(price, digits) + "\n";

   if(InpShowSLTP && entry == DEAL_ENTRY_IN && pos_id > 0)
   {
      if(PositionSelectByTicket(pos_id))
      {
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         if(sl > 0.0) msg += "SL: " + DoubleToString(sl, digits) + "\n";
         if(tp > 0.0) msg += "TP: " + DoubleToString(tp, digits) + "\n";
      }
   }

   if(InpShowProfit && (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT))
   {
      double net = profit + commission + swap;
      msg += "P/L: " + DoubleToString(net, 2) + "\n";
   }

   if(magic > 0)
      msg += "Magic: " + IntegerToString(magic) + "\n";

   if(comment != "")
      msg += "Comment: " + comment;

   return msg;
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(InpBotToken) == 0)
   {
      Print("Zeke Telegram Notifier: set InpBotToken in EA inputs");
      return INIT_SUCCEEDED;
   }

   if(MQLInfoInteger(MQL_TESTER) == 0)
   {
      char post[], result[];
      string headers;
      ArrayResize(post, 0);
      ResetLastError();
      string ping = "https://api.telegram.org/bot" + InpBotToken + "/getMe";
      int code = WebRequest("GET", ping, "", InpTimeoutMs, post, result, headers);
      g_webrequest_ok = (code == 200);
      if(!g_webrequest_ok)
      {
         int err = GetLastError();
         Print("Telegram: WebRequest check failed (HTTP ", code, ", err ", err, "). ",
               "Allow https://api.telegram.org in Tools → Options → Expert Advisors.");
      }
      else
      {
         Print("Zeke Telegram Notifier: ready for ", InpChatId);
      }
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong deal = trans.deal;
   if(deal == 0 || !HistoryDealSelect(deal)) return;
   if(!PassesFilters(deal)) return;

   long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(!ShouldNotify(entry)) return;

   string message = FormatDealMessage(deal);
   if(!SendTelegram(message))
      Print("Telegram: failed to send alert for deal #", deal);
}

//+------------------------------------------------------------------+
