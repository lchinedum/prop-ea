//+------------------------------------------------------------------+
//| Gold_ORB_SignalBus.mqh                                           |
//| Terminal global variables: Master EA publishes, Follower reads   |
//+------------------------------------------------------------------+
#ifndef GOLD_ORB_SIGNAL_BUS_MQH
#define GOLD_ORB_SIGNAL_BUS_MQH

string ORB_SignalSanitizeSymbol(const string sym)
{
   string s = sym;
   StringReplace(s, "#", "_");
   StringReplace(s, ".", "_");
   StringReplace(s, " ", "_");
   StringReplace(s, "-", "_");
   return s;
}

// Prefix: ORB_<channel>_<symbol>_
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

#endif // GOLD_ORB_SIGNAL_BUS_MQH
