#property script_show_inputs
#property strict

input string          InpSymbols         = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,USDCHF,NZDUSD,EURGBP,EURJPY,GBPJPY";   // Comma-separated symbols
input ENUM_TIMEFRAMES InpTimeframe       = PERIOD_H1;                                                                 // Analysis timeframe
input int             InpBarsToAnalyze   = 1500;                                                                      // Number of return bars
input bool            InpUseLogReturns   = true;                                                                      // true=log returns, false=simple returns
input bool            InpOutputAsPercent = true;                                                                      // true=output in -100..100, false=-1..1
input string          InpOutputCsvPath   = "analysis_checking/correlation_table.csv";                                 // Output CSV path
input bool            InpUseCommonFiles  = true;                                                                      // true=Common Files, false=terminal Files

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

int Idx(const int row, const int col, const int cols) {
   return row * cols + col;
}

bool ParseSymbols(string &symbols[]) {
   string parts[];
   int    count = StringSplit(InpSymbols, ',', parts);
   if(count <= 0)
      return false;

   ArrayResize(symbols, 0);

   for(int i = 0; i < count; i++) {
      string resolved = ResolveSymbolName(parts[i]);
      if(StringLen(resolved) == 0)
         continue;

      bool dup = false;
      for(int j = 0; j < ArraySize(symbols); j++) {
         if(symbols[j] == resolved) {
            dup = true;
            break;
         }
      }
      if(dup)
         continue;

      if(!SymbolSelect(resolved, true))
         continue;

      int n = ArraySize(symbols);
      ArrayResize(symbols, n + 1);
      symbols[n] = resolved;
   }

   return (ArraySize(symbols) >= 2);
}

bool BuildReturns(const string         &symbols[],
                  const int             symCount,
                  const ENUM_TIMEFRAMES tf,
                  const int             requestedBars,
                  const bool            useLogReturns,
                  double               &retVals[],
                  uchar                &retValid[],
                  int                  &obsCount) {
   datetime anchorTimes[];
   ArraySetAsSeries(anchorTimes, true);

   int copied = CopyTime(symbols[0], tf, 0, requestedBars + 1, anchorTimes);
   if(copied < 20)
      return false;

   obsCount = MathMin(requestedBars, copied - 1);
   if(obsCount < 10)
      return false;

   ArrayResize(retVals, symCount * obsCount);
   ArrayResize(retValid, symCount * obsCount);

   for(int s = 0; s < symCount; s++) {
      string sym = symbols[s];

      for(int i = 0; i < obsCount; i++) {
         int idx       = Idx(s, i, obsCount);
         retVals[idx]  = 0.0;
         retValid[idx] = 0;

         datetime t0 = anchorTimes[i];
         datetime t1 = anchorTimes[i + 1];

         int shift0 = iBarShift(sym, tf, t0, false);
         int shift1 = iBarShift(sym, tf, t1, false);
         if(shift0 < 0 || shift1 < 0)
            continue;

         double c0 = iClose(sym, tf, shift0);
         double c1 = iClose(sym, tf, shift1);
         if(c0 <= 0.0 || c1 <= 0.0)
            continue;

         double ret = 0.0;
         if(useLogReturns)
            ret = MathLog(c0 / c1);
         else
            ret = (c0 - c1) / c1;

         retVals[idx]  = ret;
         retValid[idx] = 1;
      }
   }

   return true;
}

bool ComputeCorrelationPair(const double &retVals[],
                            const uchar  &retValid[],
                            const int     obsCount,
                            const int     symA,
                            const int     symB,
                            double       &corr,
                            int          &nUsed) {
   nUsed       = 0;
   double sumA = 0.0;
   double sumB = 0.0;

   for(int i = 0; i < obsCount; i++) {
      int ia = Idx(symA, i, obsCount);
      int ib = Idx(symB, i, obsCount);
      if(retValid[ia] == 0 || retValid[ib] == 0)
         continue;

      sumA += retVals[ia];
      sumB += retVals[ib];
      nUsed++;
   }

   if(nUsed < 2) {
      corr = 0.0;
      return false;
   }

   double meanA = sumA / (double)nUsed;
   double meanB = sumB / (double)nUsed;

   double covAcc  = 0.0;
   double varAAcc = 0.0;
   double varBAcc = 0.0;

   for(int i = 0; i < obsCount; i++) {
      int ia = Idx(symA, i, obsCount);
      int ib = Idx(symB, i, obsCount);
      if(retValid[ia] == 0 || retValid[ib] == 0)
         continue;

      double da = retVals[ia] - meanA;
      double db = retVals[ib] - meanB;

      covAcc  += da * db;
      varAAcc += da * da;
      varBAcc += db * db;
   }

   if(varAAcc <= 0.0 || varBAcc <= 0.0) {
      corr = (symA == symB ? 1.0 : 0.0);
      return (symA == symB);
   }

   corr = covAcc / MathSqrt(varAAcc * varBAcc);
   if(corr > 1.0)
      corr = 1.0;
   if(corr < -1.0)
      corr = -1.0;

   return true;
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

bool WriteCorrelationCsv(const string &symbols[],
                         const int     symCount,
                         const int     obsCount,
                         const double &corrMatrix[]) {
   EnsureParentFolders(InpOutputCsvPath, InpUseCommonFiles);

   int flags = FILE_WRITE | FILE_TXT | FILE_ANSI;
   if(InpUseCommonFiles)
      flags |= FILE_COMMON;

   int h = FileOpen(InpOutputCsvPath, flags);
   if(h == INVALID_HANDLE) {
      PrintFormat("[ERROR] Cannot open CSV output: %s (err=%d)", InpOutputCsvPath, GetLastError());
      return false;
   }

   string unit = (InpOutputAsPercent ? "corr(%)" : "corr(-1..1)");
   FileWriteString(h, StringFormat("# Correlation table, timeframe=%s, bars=%d, log_returns=%s, output=%s\r\n",
                                   EnumToString(InpTimeframe),
                                   obsCount,
                                   (InpUseLogReturns ? "true" : "false"),
                                   unit));

   string header[];
   ArrayResize(header, symCount + 1);
   header[0] = "symbol";
   for(int j = 0; j < symCount; j++)
      header[j + 1] = symbols[j];

   FileWriteString(h, BuildCsvRow(header) + "\r\n");

   int digits = (InpOutputAsPercent ? 2 : 6);

   for(int i = 0; i < symCount; i++) {
      string row[];
      ArrayResize(row, symCount + 1);
      row[0] = symbols[i];

      for(int j = 0; j < symCount; j++) {
         double v = corrMatrix[Idx(i, j, symCount)];
         if(InpOutputAsPercent)
            v *= 100.0;

         row[j + 1] = DoubleToString(v, digits);
      }

      FileWriteString(h, BuildCsvRow(row) + "\r\n");
   }

   FileClose(h);
   return true;
}

void PrintCorrelationTable(const string &symbols[],
                           const int     symCount,
                           const int     obsCount,
                           const double &corrMatrix[]) {
   PrintFormat("[INFO] Correlation table | symbols=%d | bars=%d | tf=%s | log_returns=%s | output_as_percent=%s",
               symCount,
               obsCount,
               EnumToString(InpTimeframe),
               (InpUseLogReturns ? "true" : "false"),
               (InpOutputAsPercent ? "true" : "false"));

   int digits = (InpOutputAsPercent ? 2 : 6);

   for(int i = 0; i < symCount; i++) {
      string line = symbols[i] + ": ";
      for(int j = 0; j < symCount; j++) {
         if(j > 0)
            line += " | ";

         double v = corrMatrix[Idx(i, j, symCount)];
         if(InpOutputAsPercent)
            v *= 100.0;

         line += symbols[j] + "=" + DoubleToString(v, digits);
      }
      Print(line);
   }
}

void OnStart() {
   if(InpBarsToAnalyze < 10) {
      Print("[ERROR] InpBarsToAnalyze must be >= 10");
      return;
   }

   string symbols[];
   if(!ParseSymbols(symbols)) {
      Print("[ERROR] Need at least 2 valid symbols in InpSymbols");
      return;
   }

   int symCount = ArraySize(symbols);

   double retVals[];
   uchar  retValid[];
   int    obsCount = 0;

   if(!BuildReturns(symbols,
                    symCount,
                    InpTimeframe,
                    InpBarsToAnalyze,
                    InpUseLogReturns,
                    retVals,
                    retValid,
                    obsCount)) {
      Print("[ERROR] Could not build aligned return series");
      return;
   }

   double corrMatrix[];
   ArrayResize(corrMatrix, symCount * symCount);

   int minPairObs = 1000000;
   for(int i = 0; i < symCount; i++) {
      for(int j = 0; j < symCount; j++) {
         double corr  = 0.0;
         int    nUsed = 0;
         ComputeCorrelationPair(retVals, retValid, obsCount, i, j, corr, nUsed);
         corrMatrix[Idx(i, j, symCount)] = corr;

         if(i != j && nUsed < minPairObs)
            minPairObs = nUsed;
      }
   }

   PrintCorrelationTable(symbols, symCount, obsCount, corrMatrix);

   if(!WriteCorrelationCsv(symbols, symCount, obsCount, corrMatrix))
      return;

   PrintFormat("[DONE] Correlation CSV written: %s%s | min_pair_obs=%d",
               (InpUseCommonFiles ? "[COMMON] " : "[LOCAL] "),
               InpOutputCsvPath,
               minPairObs);
}
