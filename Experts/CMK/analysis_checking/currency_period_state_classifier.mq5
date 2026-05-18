#property script_show_inputs
#property strict

input string          InpSymbol                         = "EURUSD";                                                   // Single symbol to analyze
input ENUM_TIMEFRAMES InpTimeframe                      = PERIOD_H1;                                                  // Analysis timeframe
input string          InpAnalysisStartText              = "2025.01.01 00:00";                                       // Start datetime string
input string          InpAnalysisEndText                = "0";                                                       // End datetime string ("0"=now)
input int             InpPeriodBars                     = 300;                                                        // Bars per classified period
input int             InpStepBars                       = 10;                                                         // Shift between classified periods
input bool            InpUseLogReturns                  = true;                                                       // true=log returns, false=simple returns
input bool            InpReturnAsPercent                = true;                                                       // true=return unit in percent
input int             InpRollingWindow                  = 50;                                                         // Window for rolling vol and Sharpe
input int             InpRegimeLookback                 = 300;                                                        // Lookback for volatility percentiles
input double          InpLowVolPercentile               = 20.0;                                                       // Low-vol percentile
input double          InpHighVolPercentile              = 80.0;                                                       // High-vol percentile
input double          InpRiskFreeRateAnnual             = 0.0;                                                        // Annual risk-free rate
input double          InpSuitabilityStopDrawdownPct     = 8.0;                                                        // STOP threshold for current drawdown (%)
input int             InpSuitabilityStopDrawdownBars    = 300;                                                        // STOP threshold for drawdown duration (bars)
input double          InpSuitabilityStopSharpe          = -0.50;                                                      // STOP threshold for rolling Sharpe
input double          InpSuitabilityCautionDrawdownPct  = 4.0;                                                        // CAUTION threshold for current drawdown (%)
input int             InpSuitabilityCautionDrawdownBars = 120;                                                        // CAUTION threshold for drawdown duration (bars)
input double          InpSuitabilityCautionSharpe       = 0.0;                                                        // CAUTION threshold for rolling Sharpe
input double          InpSuitabilityNearHighVolRatio    = 0.90;                                                       // CAUTION when current vol is near high threshold
input string          InpOutputCsvPath                  = "analysis_checking/currency_period_state_classifier.csv";   // Output CSV path
input bool            InpUseCommonFiles                 = true;                                                       // true=Common Files
input bool            InpAppendRunTimestamp             = true;                                                       // Append run datetime into output file name

string TrimCopy(const string value) {
   string out = value;
   StringTrimLeft(out);
   StringTrimRight(out);
   return out;
}

string ToUpperCopy(const string value) {
   string out = value;
   StringToUpper(out);
   return out;
}

string ResolveSymbolName(const string requested) {
   string req = TrimCopy(requested);
   if(StringLen(req) == 0)
      return "";

   string reqUp = ToUpperCopy(req);

   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++) {
      string symbol = SymbolName(i, false);
      if(ToUpperCopy(symbol) == reqUp)
         return symbol;
   }

   string best    = "";
   int    bestLen = 100000;
   for(int i = 0; i < total; i++) {
      string symbol = SymbolName(i, false);
      string up     = ToUpperCopy(symbol);
      if(StringFind(up, reqUp) != 0)
         continue;

      int len = StringLen(symbol);
      if(len < bestLen) {
         best    = symbol;
         bestLen = len;
      }
   }

   return best;
}

int FindLastSlashIndex(const string path) {
   int last = -1;
   int len  = StringLen(path);

   for(int i = 0; i < len; i++) {
      ushort ch = (ushort)StringGetCharacter(path, i);
      if(ch == '/' || ch == '\\')
         last = i;
   }

   return last;
}

int FindLastDotIndex(const string text) {
   int last = -1;
   int len  = StringLen(text);

   for(int i = 0; i < len; i++) {
      ushort ch = (ushort)StringGetCharacter(text, i);
      if(ch == '.')
         last = i;
   }

   return last;
}

string BuildRunTimestamp(const datetime t) {
   MqlDateTime tm = {};
   TimeToStruct(t, tm);
   return StringFormat("%04d%02d%02d_%02d%02d%02d", tm.year, tm.mon, tm.day, tm.hour, tm.min, tm.sec);
}

string BuildRunOutputPath(const string basePath, const datetime runTime) {
   if(!InpAppendRunTimestamp)
      return basePath;

   string stamp     = BuildRunTimestamp(runTime);
   int    lastSlash = FindLastSlashIndex(basePath);
   int    lastDot   = FindLastDotIndex(basePath);

   if(lastDot > lastSlash) {
      string left = StringSubstr(basePath, 0, lastDot);
      string ext  = StringSubstr(basePath, lastDot);
      return left + "_" + stamp + ext;
   }

   return basePath + "_" + stamp + ".csv";
}

void EnsureParentFolders(const string outputPath, const bool useCommonFiles) {
   string normalized = outputPath;
   StringReplace(normalized, "\\", "/");

   int lastSlash = FindLastSlashIndex(normalized);
   if(lastSlash < 0)
      return;

   string folderPath = StringSubstr(normalized, 0, lastSlash);
   if(StringLen(folderPath) == 0)
      return;

   string parts[];
   int    partCount = StringSplit(folderPath, '/', parts);
   if(partCount <= 0)
      return;

   string current = "";
   for(int i = 0; i < partCount; i++) {
      if(StringLen(parts[i]) == 0)
         continue;

      if(StringLen(current) == 0)
         current = parts[i];
      else
         current = current + "/" + parts[i];

      FolderCreate(current, useCommonFiles ? FILE_COMMON : 0);
   }
}

string BuildCsvRow(const string &values[]) {
   string row = "";
   int    n   = ArraySize(values);

   for(int i = 0; i < n; i++) {
      if(i > 0)
         row += ",";
      row += values[i];
   }

   return row;
}

string DateTimeToText(const datetime t) {
   if(t <= 0)
      return "";
   return TimeToString(t, TIME_DATE | TIME_SECONDS);
}

bool ParseDateTimeInput(const string rawText, const bool allowZeroAsNow, datetime &out) {
   string text = TrimCopy(rawText);
   if(StringLen(text) == 0)
      return false;

   if(allowZeroAsNow && text == "0") {
      out = 0;
      return true;
   }

   datetime t = StringToTime(text);
   if(t <= 0)
      return false;

   out = t;
   return true;
}

bool MeanStdRange(const double &values[], const int start, const int len, double &mean, double &stdDev) {
   if(len < 2)
      return false;

   double sum = 0.0;
   for(int i = start; i < start + len; i++)
      sum += values[i];

   mean = sum / (double)len;

   double varAcc = 0.0;
   for(int i = start; i < start + len; i++) {
      double d  = values[i] - mean;
      varAcc   += d * d;
   }

   stdDev = MathSqrt(varAcc / (double)(len - 1));
   return true;
}

bool ComputeRollingVolSeries(const double &returnsChrono[], const int retCount, const int window, double &rollingVols[]) {
   if(retCount < window || window < 2)
      return false;

   int count = retCount - window + 1;
   ArrayResize(rollingVols, count);

   for(int i = 0; i < count; i++) {
      double mean   = 0.0;
      double stdDev = 0.0;
      if(!MeanStdRange(returnsChrono, i, window, mean, stdDev))
         return false;
      rollingVols[i] = stdDev;
   }

   return true;
}

double Quantile(const double &values[], const int n, const double percentile) {
   if(n <= 0)
      return 0.0;

   double p = MathMax(0.0, MathMin(100.0, percentile));

   double tmp[];
   ArrayResize(tmp, n);
   for(int i = 0; i < n; i++)
      tmp[i] = values[i];

   ArraySort(tmp);

   if(n == 1)
      return tmp[0];

   double pos = (p / 100.0) * (double)(n - 1);
   int    lo  = (int)MathFloor(pos);
   int    hi  = (int)MathCeil(pos);
   double w   = pos - (double)lo;

   return tmp[lo] * (1.0 - w) + tmp[hi] * w;
}

bool ComputeCurrentRollingSharpe(const double &returnsChrono[],
                                 const int     retCount,
                                 const int     window,
                                 const double  riskFreeAnnual,
                                 const int     periodSeconds,
                                 const bool    useLogReturns,
                                 double       &rollingSharpe) {
   if(retCount < window || window < 2 || periodSeconds <= 0)
      return false;

   int start = retCount - window;

   const double yearSeconds = 31557600.0;
   double       rfBarSimple = MathPow(1.0 + riskFreeAnnual, (double)periodSeconds / yearSeconds) - 1.0;
   double       rfBar       = (useLogReturns ? MathLog(1.0 + rfBarSimple) : rfBarSimple);

   double sumExcess = 0.0;
   for(int i = start; i < retCount; i++)
      sumExcess += (returnsChrono[i] - rfBar);

   double meanExcess = sumExcess / (double)window;

   double varAcc = 0.0;
   for(int i = start; i < retCount; i++) {
      double d  = (returnsChrono[i] - rfBar) - meanExcess;
      varAcc   += d * d;
   }

   double stdExcess = MathSqrt(varAcc / (double)(window - 1));
   if(stdExcess <= 0.0)
      return false;

   double barsPerYear = yearSeconds / (double)periodSeconds;
   rollingSharpe      = (meanExcess / stdExcess) * MathSqrt(barsPerYear);
   return true;
}

void ComputeDrawdownMetrics(const double &closesChrono[],
                            const int     n,
                            double       &currentDDPct,
                            double       &maxDDPct,
                            int          &currentDDBars,
                            int          &maxDDBars) {
   currentDDPct  = 0.0;
   maxDDPct      = 0.0;
   currentDDBars = 0;
   maxDDBars     = 0;

   if(n < 2)
      return;

   double peak   = closesChrono[0];
   int    curDur = 0;

   for(int i = 0; i < n; i++) {
      double price = closesChrono[i];
      double ddPct = 0.0;

      if(price >= peak) {
         peak   = price;
         curDur = 0;
      } else {
         ddPct = (peak - price) / peak * 100.0;
         curDur++;

         if(ddPct > maxDDPct)
            maxDDPct = ddPct;
         if(curDur > maxDDBars)
            maxDDBars = curDur;
      }

      if(i == n - 1) {
         currentDDPct  = ddPct;
         currentDDBars = curDur;
      }
   }
}

string EvaluateMartingaleSuitability(const string regime,
                                     const bool   sharpeOk,
                                     const double rollingSharpe,
                                     const double currentDDPct,
                                     const int    currentDDBars,
                                     const double currentVol,
                                     const double highTh) {
   if(regime == "HIGH" || currentDDPct >= InpSuitabilityStopDrawdownPct || currentDDBars >= InpSuitabilityStopDrawdownBars || (sharpeOk && rollingSharpe <= InpSuitabilityStopSharpe))
      return "STOP";

   bool nearHighVol = (highTh > 0.0 && currentVol >= highTh * InpSuitabilityNearHighVolRatio);
   if(nearHighVol || currentDDPct >= InpSuitabilityCautionDrawdownPct || currentDDBars >= InpSuitabilityCautionDrawdownBars || (sharpeOk && rollingSharpe < InpSuitabilityCautionSharpe))
      return "CAUTION";

   if(regime == "LOW")
      return "GO";

   return "CAUTION";
}

bool BuildPeriodClosesAndReturns(const MqlRates &ratesChrono[],
                                 const int       startIdx,
                                 const int       periodBars,
                                 const bool      useLogReturns,
                                 const bool      returnAsPercent,
                                 double         &periodCloses[],
                                 double         &periodReturns[]) {
   if(periodBars < 3)
      return false;

   ArrayResize(periodCloses, periodBars);
   for(int i = 0; i < periodBars; i++)
      periodCloses[i] = ratesChrono[startIdx + i].close;

   int nRet = periodBars - 1;
   ArrayResize(periodReturns, nRet);

   for(int i = 1; i < periodBars; i++) {
      double p0 = periodCloses[i - 1];
      double p1 = periodCloses[i];
      if(p0 <= 0.0 || p1 <= 0.0)
         return false;

      double r = 0.0;
      if(useLogReturns)
         r = MathLog(p1 / p0);
      else
         r = (p1 - p0) / p0;

      if(returnAsPercent)
         r *= 100.0;

      periodReturns[i - 1] = r;
   }

   return true;
}

int OnStart() {
   datetime parsedAnalysisStart = 0;
   datetime parsedAnalysisEnd = 0;

   if(!ParseDateTimeInput(InpAnalysisStartText, false, parsedAnalysisStart)) {
      Print("[ERROR] Invalid InpAnalysisStartText. Use format: YYYY.MM.DD HH:MI (e.g., 2025.01.01 00:00)");
      return 0;
   }

   if(!ParseDateTimeInput(InpAnalysisEndText, true, parsedAnalysisEnd)) {
      Print("[ERROR] Invalid InpAnalysisEndText. Use format: YYYY.MM.DD HH:MI or 0 for now.");
      return 0;
   }

   if(InpPeriodBars < 3 || InpStepBars < 1 || InpRollingWindow < 2 || InpRegimeLookback < 5) {
      Print("[ERROR] Invalid period/step/rolling inputs.");
      return 0;
   }

   if(InpLowVolPercentile < 0.0 || InpLowVolPercentile >= InpHighVolPercentile || InpHighVolPercentile > 100.0) {
      Print("[ERROR] Invalid volatility percentiles. Require 0 <= low < high <= 100.");
      return 0;
   }

   datetime endTime = parsedAnalysisEnd;
   if(endTime <= 0)
      endTime = TimeCurrent();

   if(parsedAnalysisStart <= 0 || parsedAnalysisStart >= endTime) {
      Print("[ERROR] Invalid date range. Require start < end.");
      return 0;
   }

   string symbol = ResolveSymbolName(InpSymbol);
   if(StringLen(symbol) == 0) {
      PrintFormat("[ERROR] Symbol not found: %s", InpSymbol);
      return 0;
   }

   if(!SymbolSelect(symbol, true)) {
      PrintFormat("[ERROR] Could not select symbol: %s", symbol);
      return 0;
   }

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(symbol, InpTimeframe, parsedAnalysisStart, endTime, rates);
   if(copied < InpPeriodBars) {
      PrintFormat("[ERROR] Not enough bars in selected range. copied=%d periodBars=%d", copied, InpPeriodBars);
      return 0;
   }

   string outputPath = BuildRunOutputPath(InpOutputCsvPath, TimeLocal());
   EnsureParentFolders(outputPath, InpUseCommonFiles);

   int flags = FILE_WRITE | FILE_TXT | FILE_ANSI;
   if(InpUseCommonFiles)
      flags |= FILE_COMMON;

   int h = FileOpen(outputPath, flags);
   if(h == INVALID_HANDLE) {
      PrintFormat("[ERROR] Cannot open CSV output: %s (err=%d)", outputPath, GetLastError());
      return 0;
   }

   int periodSec = PeriodSeconds(InpTimeframe);
   if(periodSec <= 0)
      periodSec = 60;

   string header[];
   ArrayResize(header, 18);
   header[0]  = "symbol";
   header[1]  = "timeframe";
   header[2]  = "period_start";
   header[3]  = "period_end";
   header[4]  = "period_bars";
   header[5]  = "current_vol";
   header[6]  = "vol_threshold_low";
   header[7]  = "vol_threshold_high";
   header[8]  = "vol_regime";
   header[9]  = "rolling_sharpe_annual";
   header[10] = "current_drawdown_pct";
   header[11] = "max_drawdown_pct";
   header[12] = "current_drawdown_duration_bars";
   header[13] = "max_drawdown_duration_bars";
   header[14] = "current_drawdown_duration_minutes";
   header[15] = "max_drawdown_duration_minutes";
   header[16] = "martingale_suitability_score";
   header[17] = "status";
   FileWriteString(h, BuildCsvRow(header) + "\r\n");

   for(int endIdx = InpPeriodBars - 1; endIdx < copied; endIdx += InpStepBars) {
      int startIdx = endIdx - InpPeriodBars + 1;

      double closes[];
      double returns[];

      string row[];
      ArrayResize(row, 18);
      row[0] = symbol;
      row[1] = EnumToString(InpTimeframe);
      row[2] = DateTimeToText(rates[startIdx].time);
      row[3] = DateTimeToText(rates[endIdx].time);
      row[4] = IntegerToString(InpPeriodBars);

      bool ok = BuildPeriodClosesAndReturns(rates,
                                            startIdx,
                                            InpPeriodBars,
                                            InpUseLogReturns,
                                            InpReturnAsPercent,
                                            closes,
                                            returns);
      if(!ok) {
         row[5]  = "";
         row[6]  = "";
         row[7]  = "";
         row[8]  = "";
         row[9]  = "";
         row[10] = "";
         row[11] = "";
         row[12] = "";
         row[13] = "";
         row[14] = "";
         row[15] = "";
         row[16] = "";
         row[17] = "ERROR: invalid close/return data";
         FileWriteString(h, BuildCsvRow(row) + "\r\n");
         continue;
      }

      int    retCount = ArraySize(returns);
      double rollingVols[];
      if(!ComputeRollingVolSeries(returns, retCount, InpRollingWindow, rollingVols)) {
         row[5]  = "";
         row[6]  = "";
         row[7]  = "";
         row[8]  = "";
         row[9]  = "";
         row[10] = "";
         row[11] = "";
         row[12] = "";
         row[13] = "";
         row[14] = "";
         row[15] = "";
         row[16] = "";
         row[17] = "ERROR: not enough bars for rolling window";
         FileWriteString(h, BuildCsvRow(row) + "\r\n");
         continue;
      }

      int rollingCount = ArraySize(rollingVols);
      int lb           = MathMin(InpRegimeLookback, rollingCount);
      int lbStart      = rollingCount - lb;

      double sample[];
      ArrayResize(sample, lb);
      for(int i = 0; i < lb; i++)
         sample[i] = rollingVols[lbStart + i];

      double lowTh      = Quantile(sample, lb, InpLowVolPercentile);
      double highTh     = Quantile(sample, lb, InpHighVolPercentile);
      double currentVol = rollingVols[rollingCount - 1];

      string regime = "NORMAL";
      if(currentVol < lowTh)
         regime = "LOW";
      else if(currentVol > highTh)
         regime = "HIGH";

      double rollingSharpe = 0.0;
      bool   sharpeOk      = ComputeCurrentRollingSharpe(returns,
                                                         retCount,
                                                         InpRollingWindow,
                                                         InpRiskFreeRateAnnual,
                                                         periodSec,
                                                         InpUseLogReturns,
                                                         rollingSharpe);

      double currentDD     = 0.0;
      double maxDD         = 0.0;
      int    currentDDBars = 0;
      int    maxDDBars     = 0;
      ComputeDrawdownMetrics(closes, ArraySize(closes), currentDD, maxDD, currentDDBars, maxDDBars);

      string suitability = EvaluateMartingaleSuitability(regime,
                                                         sharpeOk,
                                                         rollingSharpe,
                                                         currentDD,
                                                         currentDDBars,
                                                         currentVol,
                                                         highTh);

      row[5]  = DoubleToString(currentVol, 8);
      row[6]  = DoubleToString(lowTh, 8);
      row[7]  = DoubleToString(highTh, 8);
      row[8]  = regime;
      row[9]  = (sharpeOk ? DoubleToString(rollingSharpe, 6) : "");
      row[10] = DoubleToString(currentDD, 4);
      row[11] = DoubleToString(maxDD, 4);
      row[12] = IntegerToString(currentDDBars);
      row[13] = IntegerToString(maxDDBars);
      row[14] = DoubleToString((double)currentDDBars * (double)periodSec / 60.0, 2);
      row[15] = DoubleToString((double)maxDDBars * (double)periodSec / 60.0, 2);
      row[16] = suitability;
      row[17] = "OK";

      FileWriteString(h, BuildCsvRow(row) + "\r\n");
   }

   FileClose(h);

   PrintFormat("[DONE] Period classifier CSV written: %s%s",
               (InpUseCommonFiles ? "[COMMON] " : "[LOCAL] "),
               outputPath);

   return 0;
}
