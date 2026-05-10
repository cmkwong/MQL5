#property script_show_inputs
#property strict

input int                InpSMAPeriod1   = 20;            // SMA period 1 (<=0 to disable)
input int                InpSMAPeriod2   = 50;            // SMA period 2 (<=0 to disable)
input int                InpSMAPeriod3   = 200;           // SMA period 3 (<=0 to disable)
input int                InpBarsToDraw   = 1500;          // Number of bars to draw
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE;   // Price used for SMA
input color              InpColor1       = clrDodgerBlue;
input color              InpColor2       = clrOrange;
input color              InpColor3       = clrMagenta;
input int                InpLineWidth    = 2;
input ENUM_LINE_STYLE    InpLineStyle    = STYLE_SOLID;

string g_prefix = "CMK_SMA_DRAWER__";

int RemovePreviousSmaDrawings(const long chartId) {
   int removed = 0;
   int total   = ObjectsTotal(chartId);

   for(int i = total - 1; i >= 0; i--) {
      string objName = ObjectName(chartId, i);
      if(StringFind(objName, g_prefix) == 0) {
         if(ObjectDelete(chartId, objName))
            removed++;
      }
   }

   return removed;
}

bool DrawSmaSegments(const long chartId, const int smaPeriod, const color lineColor) {
   if(smaPeriod <= 0)
      return false;

   int barsToCopy = MathMax(InpBarsToDraw, 2);

   int handle = iMA(_Symbol, _Period, smaPeriod, 0, MODE_SMA, InpAppliedPrice);
   if(handle == INVALID_HANDLE) {
      PrintFormat("[ERROR] Could not create SMA handle for period %d", smaPeriod);
      return false;
   }

   double   maValues[];
   datetime barTimes[];
   ArraySetAsSeries(maValues, true);
   ArraySetAsSeries(barTimes, true);

   int copiedMa    = CopyBuffer(handle, 0, 0, barsToCopy, maValues);
   int copiedTimes = CopyTime(_Symbol, _Period, 0, barsToCopy, barTimes);

   if(copiedMa < 2 || copiedTimes < 2) {
      IndicatorRelease(handle);
      PrintFormat("[WARN] Not enough data to draw SMA(%d)", smaPeriod);
      return false;
   }

   int    points      = MathMin(copiedMa, copiedTimes);
   string description = StringFormat("CMK SMA Drawer | %s %s | SMA(%d) | Bars=%d",
                                     _Symbol,
                                     EnumToString((ENUM_TIMEFRAMES)_Period),
                                     smaPeriod,
                                     points);

   int created = 0;
   for(int i = points - 2; i >= 0; i--) {
      string objName = StringFormat("%sP%d_SEG_%04d", g_prefix, smaPeriod, i);

      datetime t1 = barTimes[i + 1];
      datetime t2 = barTimes[i];
      double   p1 = maValues[i + 1];
      double   p2 = maValues[i];

      if(!ObjectCreate(chartId, objName, OBJ_TREND, 0, t1, p1, t2, p2))
         continue;

      ObjectSetInteger(chartId, objName, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(chartId, objName, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(chartId, objName, OBJPROP_COLOR, lineColor);
      ObjectSetInteger(chartId, objName, OBJPROP_STYLE, InpLineStyle);
      ObjectSetInteger(chartId, objName, OBJPROP_WIDTH, InpLineWidth);
      ObjectSetInteger(chartId, objName, OBJPROP_BACK, false);
      ObjectSetInteger(chartId, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(chartId, objName, OBJPROP_SELECTED, false);
      ObjectSetInteger(chartId, objName, OBJPROP_HIDDEN, false);
      ObjectSetString(chartId, objName, OBJPROP_TOOLTIP, description);

      created++;
   }

   IndicatorRelease(handle);

   PrintFormat("[INFO] Drawn SMA(%d): %d segments", smaPeriod, created);
   return (created > 0);
}

void OnStart() {
   long chartId = ChartID();

   int removed = RemovePreviousSmaDrawings(chartId);

   int   periods[3] = {InpSMAPeriod1, InpSMAPeriod2, InpSMAPeriod3};
   color colors[3]  = {InpColor1, InpColor2, InpColor3};

   int activeLines = 0;
   int drawnLines  = 0;

   for(int i = 0; i < 3; i++) {
      if(periods[i] <= 0)
         continue;

      activeLines++;
      if(DrawSmaSegments(chartId, periods[i], colors[i]))
         drawnLines++;
   }

   ChartRedraw(chartId);

   if(activeLines == 0) {
      Print("[WARN] No SMA periods enabled. Set at least one input period > 0.");
      return;
   }

   PrintFormat("[DONE] CMK SMA Drawer | Removed previous objects: %d | Requested lines: %d | Drawn lines: %d",
               removed,
               activeLines,
               drawnLines);
}
