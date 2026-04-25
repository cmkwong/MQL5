//+------------------------------------------------------------------+
//| Pressure & Support Line Breakout Checker                         |
//| - Loads a named MT5 profile on init                              |
//| - Scans all trend/horizontal line objects on the chart           |
//| - Classifies lines as "pressure" (resistance) or "support"       |
//|   by comparing the line price to the current Ask/Bid             |
//| - Prints a console message when price breaks above pressure      |
//|   or below support                                               |
//+------------------------------------------------------------------+
#property copyright "CMK"
#property version   "1.00"

//--- Input parameters
input string InpProfileName   = "cmk_210321"; // MT5 profile to load on start
input double InpBreakBuffer   = 10.0;          // Extra buffer (pips * Point) beyond line
input bool   InpAutoLoadProfile = true;       // Switch to profile on init

//--- Object name prefix filters (leave empty to scan ALL lines)
//    e.g. "pres_" for objects named "pres_upper", "pres_channel"
input string InpPressurePrefix = "";  // Pressure line name prefix (empty = by position)
input string InpSupportPrefix  = "";  // Support  line name prefix (empty = by position)

//--- Colours to classify lines (0 = ignore colour filter)
input color  InpPressureColor  = clrRed;    // Colour of pressure lines  (0 = any)
input color  InpSupportColor   = clrGreen;  // Colour of support  lines  (0 = any)

//--- Proximity alert
input double InpProximityPct = 5.0;  // Alert when price is within X% of a line (0 = disable)

//--- State tracking to avoid repeated alerts on the same bar
datetime g_lastBarTime = 0;

// Track which lines already fired a proximity/breakout alert this bar
// (prevents duplicate prints for the same line on the same bar)
string g_alertedProximity  = "";
string g_alertedBreakout   = "";

//+------------------------------------------------------------------+
//| Helper – get the price value of a trend/hline object at time t  |
//+------------------------------------------------------------------+
double GetLinePrice(long chartId, string objName, datetime t)
{
   int objType = (int)ObjectGetInteger(chartId, objName, OBJPROP_TYPE);

   if(objType == OBJ_HLINE)
      return ObjectGetDouble(chartId, objName, OBJPROP_PRICE);

   if(objType == OBJ_TREND || objType == OBJ_TRENDBYANGLE || objType == OBJ_REGRESSION)
   {
      datetime t1 = (datetime)ObjectGetInteger(chartId, objName, OBJPROP_TIME,  0);
      datetime t2 = (datetime)ObjectGetInteger(chartId, objName, OBJPROP_TIME,  1);
      double   p1 = ObjectGetDouble (chartId, objName, OBJPROP_PRICE, 0);
      double   p2 = ObjectGetDouble (chartId, objName, OBJPROP_PRICE, 1);

      if(t2 == t1) return p1; // vertical – return anchor price

      // Linear interpolation / extrapolation
      double slope = (p2 - p1) / (double)(t2 - t1);
      return p1 + slope * (double)(t - t1);
   }

   return EMPTY_VALUE;
}

//+------------------------------------------------------------------+
//| Helper – decide if an object is a "pressure" or "support" line   |
//| Returns: 1 = pressure, -1 = support, 0 = ignore                  |
//+------------------------------------------------------------------+
int ClassifyObject(long chartId, string objName, double currentPrice)
{
   int objType = (int)ObjectGetInteger(chartId, objName, OBJPROP_TYPE);

   // Only handle line types
   if(objType != OBJ_HLINE    &&
      objType != OBJ_TREND    &&
      objType != OBJ_TRENDBYANGLE &&
      objType != OBJ_REGRESSION)
      return 0;

   color objColor = (color)ObjectGetInteger(chartId, objName, OBJPROP_COLOR);
   string name    = objName;

   // --- Name-prefix filter (takes priority if set) ---
   if(StringLen(InpPressurePrefix) > 0 && StringFind(name, InpPressurePrefix) == 0)
      return 1;
   if(StringLen(InpSupportPrefix) > 0 && StringFind(name, InpSupportPrefix) == 0)
      return -1;

   // --- Colour filter ---
   if(InpPressureColor != 0 && objColor == InpPressureColor) return 1;
   if(InpSupportColor  != 0 && objColor == InpSupportColor)  return -1;

   // --- Fall-back: position relative to current price ---
   double linePrice = GetLinePrice(chartId, objName, TimeCurrent());
   if(linePrice == EMPTY_VALUE) return 0;

   if(linePrice > currentPrice) return 1;   // above price → pressure
   if(linePrice < currentPrice) return -1;  // below price → support

   return 0;
}

//+------------------------------------------------------------------+
//| Scan all chart objects and check for breakouts                   |
//+------------------------------------------------------------------+
void CheckBreakouts(long chartId)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double mid = (ask + bid) / 2.0;

   int totalObjects = ObjectsTotal(chartId);

   for(int i = 0; i < totalObjects; i++)
   {
      string objName = ObjectName(chartId, i);
      int    role    = ClassifyObject(chartId, objName, mid);

      if(role == 0) continue; // not a line we care about

      double linePrice = GetLinePrice(chartId, objName, TimeCurrent());
      if(linePrice == EMPTY_VALUE) continue;

      double buffer = InpBreakBuffer * _Point;

      // -- Proximity zone: linePrice ± (linePrice * InpProximityPct / 100) --
      double proximityDist = (InpProximityPct > 0.0) ? linePrice * InpProximityPct / 100.0 : 0.0;

      bool brokeOut  = false;
      bool nearLine  = false;
      string roleStr = (role == 1) ? "pressure" : "support";

      if(role == 1) // PRESSURE line
      {
         brokeOut = (ask > linePrice + buffer);
         nearLine = (!brokeOut && InpProximityPct > 0.0 && ask >= linePrice - proximityDist);
      }
      else if(role == -1) // SUPPORT line
      {
         brokeOut = (bid < linePrice - buffer);
         nearLine = (!brokeOut && InpProximityPct > 0.0 && bid <= linePrice + proximityDist);
      }

      // ---- Breakout alert ----
      if(brokeOut)
      {
         string key = objName + "_break";
         if(StringFind(g_alertedBreakout, key) < 0)
         {
            g_alertedBreakout += key + "|";
            if(role == 1)
               PrintFormat("[BREAKOUT] %s %s - Price ROSE ABOVE %s line \"%s\"  "
                           "| Ask=%.5f  Line=%.5f",
                           _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
                           roleStr, objName, ask, linePrice);
            else
               PrintFormat("[BREAKOUT] %s %s - Price FELL BELOW %s line \"%s\"  "
                           "| Bid=%.5f  Line=%.5f",
                           _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
                           roleStr, objName, bid, linePrice);
         }
      }

      // ---- Proximity alert ----
      if(nearLine)
      {
         string key = objName + "_near";
         if(StringFind(g_alertedProximity, key) < 0)
         {
            g_alertedProximity += key + "|";
            double priceDist = (role == 1) ? (linePrice - ask) : (bid - linePrice);
            double pctAway   = (linePrice > 0) ? MathAbs(priceDist) / linePrice * 100.0 : 0.0;
            PrintFormat("[NEAR] %s %s - Price is %.2f%% away from %s line \"%s\"  "
                        "| Mid=%.5f  Line=%.5f  (within %.1f%% zone)",
                        _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
                        pctAway, roleStr, objName,
                        (ask + bid) / 2.0, linePrice, InpProximityPct);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialisation                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // Switch to the requested profile
   if(InpAutoLoadProfile && StringLen(InpProfileName) > 0)
   {
      if(ProfileSwitch(InpProfileName))
         PrintFormat("[INFO] Switched to profile: %s", InpProfileName);
      else
         PrintFormat("[WARN] Could not switch to profile: %s  (profile may not exist or is already active)", InpProfileName);
   }

   PrintFormat("[INFO] Pressure/Support checker started on %s %s - OK",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PrintFormat("[INFO] Checker stopped. Reason: %d", reason);
}

//+------------------------------------------------------------------+
//| Expert tick – run check on every new bar (avoids spam)           |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == g_lastBarTime) return; // same bar – skip
   g_lastBarTime = currentBarTime;

   // Reset per-bar alert dedup trackers
   g_alertedProximity = "";
   g_alertedBreakout  = "";

   long chartId = ChartID(); // EA runs on this chart
   CheckBreakouts(chartId);
}

//+------------------------------------------------------------------+
//| Chart event – re-check immediately when user adds/moves a line   |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CHANGE ||
      id == CHARTEVENT_OBJECT_CREATE ||
      id == CHARTEVENT_OBJECT_DELETE)
   {
      CheckBreakouts(ChartID());
   }
}
//+------------------------------------------------------------------+
