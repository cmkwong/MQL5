#property script_show_inputs

input bool InpRemoveChartObjects = true;   // Remove all chart drawing objects
input bool InpRemoveIndicators   = true;   // Remove all attached indicators
input bool InpClearChartComment  = true;   // Clear Comment() text on chart

// Remove all indicators from every chart window and return count removed.
int RemoveAllIndicators(const long chartId, int &failedDeletes) {
   int removed   = 0;
   failedDeletes = 0;

   int windowsTotal = (int)ChartGetInteger(chartId, CHART_WINDOWS_TOTAL);
   for(int window = windowsTotal - 1; window >= 0; window--) {
      int indicatorsTotal = ChartIndicatorsTotal(chartId, window);
      for(int i = indicatorsTotal - 1; i >= 0; i--) {
         string indicatorName = ChartIndicatorName(chartId, window, i);
         if(StringLen(indicatorName) == 0)
            continue;

         if(ChartIndicatorDelete(chartId, window, indicatorName))
            removed++;
         else
            failedDeletes++;
      }
   }

   return (removed);
}

void OnStart() {
   long chartId = ChartID();

   int removedObjects = 0;
   if(InpRemoveChartObjects)
      removedObjects = ObjectsDeleteAll(chartId, -1, -1);

   int failedIndicatorDeletes = 0;
   int removedIndicators      = 0;
   if(InpRemoveIndicators)
      removedIndicators = RemoveAllIndicators(chartId, failedIndicatorDeletes);

   if(InpClearChartComment)
      Comment("");

   ChartRedraw(chartId);

   PrintFormat("[DONE] Cleared chart drawings on %s %s | Objects=%d | Indicators=%d | IndicatorDeleteFailed=%d",
               _Symbol,
               EnumToString((ENUM_TIMEFRAMES)_Period),
               removedObjects,
               removedIndicators,
               failedIndicatorDeletes);
}
