#property strict
#property version "1.00"

#include <Trade/Trade.mqh>

enum ENUM_TRADE_SIDE_MODE {
   TRADE_SIDE_BOTH = 0,
   TRADE_SIDE_LHS  = 1,
   TRADE_SIDE_RHS  = 2
};

input string               InpLhsSymbol       = "EURUSD";                                         // LHS symbol (Y)
input string               InpRhsSymbol1      = "EURGBP";                                         // RHS symbol X1
input string               InpRhsSymbol2      = "GBPUSD";                                         // RHS symbol X2
input double               InpCoeff1          = 1.34285999;                                       // p1 in Y = p1*X1 + p2*X2 + c
input double               InpCoeff2          = 0.86878936;                                       // p2 in Y = p1*X1 + p2*X2 + c
input double               InpIntercept       = -1.16663185;                                      // c in Y = p1*X1 + p2*X2 + c
input double               InpLotMultiplier   = 0.01;                                             // Base lot multiplier for all legs
input ENUM_TRADE_SIDE_MODE InpTradeSideMode   = TRADE_SIDE_BOTH;                                  // Trade legs: BOTH, LHS-only, RHS-only
input double               InpSignalThreshold = 0.00000;                                          // No-trade band around zero spread
input bool                 InpCloseOnNeutral  = false;                                            // Close basket when spread is inside threshold
input bool                 InpTradeOnNewBar   = true;                                             // Evaluate/open/flip only on new bar
input ENUM_TIMEFRAMES      InpSignalTimeframe = PERIOD_CURRENT;                                   // Bar timeframe used by new-bar gate
input bool                 InpShowVariantPlot = true;                                             // Show variant plot indicator while trading
input int                  InpVariantPlotBars = 3000;                                             // Bars to plot for variant indicator
input ulong                InpMagicNumber     = 26050601;                                         // Magic number for this strategy
input int                  InpDeviationPoints = 20;                                               // Slippage allowance in points
input string               InpTradeLogCsvPath = "cointegration/cointegration_apply_trades.csv";   // CSV log output path
input bool                 InpTradeLogCommon  = true;                                             // true=Common Files, false=terminal Files

CTrade g_trade;

struct OpenPositionState {
   ulong    positionId;
   string   symbol;
   datetime openTime;
   double   openPrice;
   double   lots;
   int      direction;   // 1=buy, -1=sell
};

datetime          g_lastBarTime  = 0;
string            g_lhsResolved  = "";
string            g_rhs1Resolved = "";
string            g_rhs2Resolved = "";
OpenPositionState g_openStates[];
string            g_tradeLogResolvedPath = "";
int               g_variantHandle        = INVALID_HANDLE;
int               g_variantSubwindow     = -1;
string            g_variantShortName     = "";

string ToUpperCopy(const string value) {
   string out = value;
   StringToUpper(out);
   return out;
}

string ResolveSymbolName(const string requested) {
   if(StringLen(requested) == 0)
      return "";

   string reqUp = ToUpperCopy(requested);

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

bool PrepareSymbol(const string requested, string &resolved) {
   resolved = ResolveSymbolName(requested);
   if(StringLen(resolved) == 0) {
      PrintFormat("[ERROR] Symbol not found: %s", requested);
      return false;
   }

   if(!SymbolSelect(resolved, true)) {
      PrintFormat("[ERROR] Could not select symbol: %s", resolved);
      return false;
   }

   return true;
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

string SanitizeFileTag(const string value) {
   string out = "";
   int    len = StringLen(value);

   for(int i = 0; i < len; i++) {
      ushort ch      = (ushort)StringGetCharacter(value, i);
      bool   isNum   = (ch >= '0' && ch <= '9');
      bool   isUpper = (ch >= 'A' && ch <= 'Z');
      bool   isLower = (ch >= 'a' && ch <= 'z');

      if(isNum || isUpper || isLower)
         out += StringSubstr(value, i, 1);
      else
         out += "_";
   }

   return out;
}

string ToPathSafeNumberTag(const double value, const int digits) {
   string tag = DoubleToString(value, digits);
   StringReplace(tag, "-", "m");
   StringReplace(tag, ".", "p");
   return tag;
}

string GetTimeStampTag() {
   MqlDateTime dt;
   TimeToStruct(TimeLocal(), dt);
   uint ms = GetTickCount() % 1000;
   return StringFormat("%02d%02d%02d%02d%02d%02d%03u", dt.year % 100, dt.mon, dt.day, dt.hour, dt.min, dt.sec, ms);
}

uint HashTextFNV1a(const string text) {
   uchar bytes[];
   int   copied = StringToCharArray(text, bytes, 0, -1);
   if(copied <= 1)
      return 2166136261;

   uint hash = 2166136261;
   for(int i = 0; i < copied - 1; i++) {
      hash ^= (uint)bytes[i];
      hash *= 16777619;
   }

   return hash;
}

string BuildCriticalParamKey() {
   ENUM_TIMEFRAMES tf = (InpSignalTimeframe == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpSignalTimeframe);

   return StringFormat("%s|%s|%s|%.8f|%.8f|%.8f|%.6f|%.8f|%d|%I64u|%d|%d",
                       g_lhsResolved,
                       g_rhs1Resolved,
                       g_rhs2Resolved,
                       InpCoeff1,
                       InpCoeff2,
                       InpIntercept,
                       InpLotMultiplier,
                       InpSignalThreshold,
                       (int)tf,
                       InpMagicNumber,
                       (InpCloseOnNeutral ? 1 : 0),
                       (InpTradeOnNewBar ? 1 : 0));
}

void SplitOutputPath(const string outputPath, string &directory, string &baseName, string &extension) {
   string normalized = outputPath;
   StringReplace(normalized, "\\", "/");

   int    lastSlash = FindLastSlashIndex(normalized);
   string fileName  = normalized;
   directory        = "";

   if(lastSlash >= 0) {
      directory = StringSubstr(normalized, 0, lastSlash);
      fileName  = StringSubstr(normalized, lastSlash + 1);
   }

   if(StringLen(fileName) == 0)
      fileName = "cointegration_apply_trades.csv";

   int lastDot = -1;
   int len     = StringLen(fileName);
   for(int i = 0; i < len; i++) {
      if((ushort)StringGetCharacter(fileName, i) == '.')
         lastDot = i;
   }

   if(lastDot > 0) {
      baseName  = StringSubstr(fileName, 0, lastDot);
      extension = StringSubstr(fileName, lastDot);
   } else {
      baseName  = fileName;
      extension = ".csv";
   }
}

string BuildTradeLogParameterizedPath(const string outputPath) {
   string directory = "";
   string baseName  = "";
   string extension = "";
   SplitOutputPath(outputPath, directory, baseName, extension);

   uint   paramHash = HashTextFNV1a(BuildCriticalParamKey());
   string hashTag   = StringFormat("%08X", paramHash);
   string tsTag     = GetTimeStampTag();
   string fileName  = StringFormat("ct_%s_%s%s", hashTag, tsTag, extension);

   if(StringLen(directory) > 0)
      return directory + "/" + fileName;

   return fileName;
}

string EnsureUniqueOutputPath(const string outputPath, const bool useCommonFiles) {
   int commonFlag = (useCommonFiles ? FILE_COMMON : 0);
   if(!FileIsExist(outputPath, commonFlag))
      return outputPath;

   int    lastSlash = FindLastSlashIndex(outputPath);
   string directory = "";
   string fileName  = outputPath;

   if(lastSlash >= 0) {
      directory = StringSubstr(outputPath, 0, lastSlash);
      fileName  = StringSubstr(outputPath, lastSlash + 1);
   }

   int lastDot = -1;
   int len     = StringLen(fileName);
   for(int i = 0; i < len; i++) {
      if((ushort)StringGetCharacter(fileName, i) == '.')
         lastDot = i;
   }

   string baseName  = fileName;
   string extension = "";
   if(lastDot > 0) {
      baseName  = StringSubstr(fileName, 0, lastDot);
      extension = StringSubstr(fileName, lastDot);
   }

   for(int i = 1; i <= 999; i++) {
      string numbered  = StringFormat("%s_%03d%s", baseName, i, extension);
      string candidate = (StringLen(directory) > 0 ? directory + "/" + numbered : numbered);
      if(!FileIsExist(candidate, commonFlag))
         return candidate;
   }

   return outputPath;
}

bool AppendTradeCsvRow(const string row) {
   int fileFlags = FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI;
   if(InpTradeLogCommon)
      fileFlags |= FILE_COMMON;

   int handle = FileOpen(g_tradeLogResolvedPath, fileFlags);
   if(handle == INVALID_HANDLE) {
      PrintFormat("[ERROR] Cannot open trade log CSV: %s (err=%d)", g_tradeLogResolvedPath, GetLastError());
      return false;
   }

   FileSeek(handle, 0, SEEK_END);
   FileWriteString(handle, row + "\r\n");
   FileClose(handle);
   return true;
}

bool InitializeTradeLogCsv() {
   g_tradeLogResolvedPath = BuildTradeLogParameterizedPath(InpTradeLogCsvPath);
   g_tradeLogResolvedPath = EnsureUniqueOutputPath(g_tradeLogResolvedPath, InpTradeLogCommon);

   EnsureParentFolders(g_tradeLogResolvedPath, InpTradeLogCommon);

   int  commonFlag = (InpTradeLogCommon ? FILE_COMMON : 0);
   bool exists     = FileIsExist(g_tradeLogResolvedPath, commonFlag);
   if(exists)
      return true;

   string header = "time start,currency,lots,position price,operation,start_end,profit (in pips),duration (in mins)";
   return AppendTradeCsvRow(header);
}

double GetPipSize(const string symbol) {
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return point * 10.0;
   return point;
}

int FindOpenStateIndex(const ulong positionId) {
   int total = ArraySize(g_openStates);
   for(int i = 0; i < total; i++) {
      if(g_openStates[i].positionId == positionId)
         return i;
   }
   return -1;
}

void RemoveOpenStateByIndex(const int index) {
   int total = ArraySize(g_openStates);
   if(index < 0 || index >= total)
      return;

   for(int i = index; i < total - 1; i++)
      g_openStates[i] = g_openStates[i + 1];

   ArrayResize(g_openStates, total - 1);
}

void UpsertOpenState(const ulong    positionId,
                     const string   symbol,
                     const datetime openTime,
                     const double   openPrice,
                     const double   lots,
                     const int      direction) {
   int idx = FindOpenStateIndex(positionId);
   if(idx < 0) {
      idx = ArraySize(g_openStates);
      ArrayResize(g_openStates, idx + 1);
   }

   g_openStates[idx].positionId = positionId;
   g_openStates[idx].symbol     = symbol;
   g_openStates[idx].openTime   = openTime;
   g_openStates[idx].openPrice  = openPrice;
   g_openStates[idx].lots       = lots;
   g_openStates[idx].direction  = direction;
}

bool GetOpenState(const ulong positionId, OpenPositionState &state) {
   int idx = FindOpenStateIndex(positionId);
   if(idx < 0)
      return false;

   state = g_openStates[idx];
   return true;
}

bool IsPositionIdStillOpen(const ulong positionId) {
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      long identifier = PositionGetInteger(POSITION_IDENTIFIER);
      if((ulong)identifier == positionId)
         return true;
   }

   return false;
}

bool LoadOpenStateFromHistory(const ulong positionId, OpenPositionState &state) {
   if(!HistorySelect(0, TimeCurrent()))
      return false;

   int      total        = HistoryDealsTotal();
   datetime earliestTime = LONG_MAX;
   bool     found        = false;

   for(int i = 0; i < total; i++) {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;

      ulong dealPositionId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(dealPositionId != positionId)
         continue;

      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_IN)
         continue;

      long dealType = HistoryDealGetInteger(deal, DEAL_TYPE);
      if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL)
         continue;

      datetime t = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      if(t >= earliestTime)
         continue;

      earliestTime     = t;
      found            = true;
      state.positionId = positionId;
      state.symbol     = HistoryDealGetString(deal, DEAL_SYMBOL);
      state.openTime   = t;
      state.openPrice  = HistoryDealGetDouble(deal, DEAL_PRICE);
      state.lots       = HistoryDealGetDouble(deal, DEAL_VOLUME);
      state.direction  = (dealType == DEAL_TYPE_BUY ? 1 : -1);
   }

   return found;
}

bool IsManagedSymbol(const string symbol) {
   return (symbol == g_lhsResolved || symbol == g_rhs1Resolved || symbol == g_rhs2Resolved);
}

bool GetMidPrice(const string symbol, double &midPrice) {
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return false;

   midPrice = (bid + ask) / 2.0;
   return true;
}

double NormalizeVolume(const string symbol, const double requestedVolume) {
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(requestedVolume <= 0.0 || minLot <= 0.0 || maxLot <= 0.0 || lotStep <= 0.0)
      return 0.0;

   double clipped = MathMax(minLot, MathMin(maxLot, requestedVolume));
   double steps   = MathFloor(clipped / lotStep + 1e-10);
   double norm    = steps * lotStep;

   int    stepDigits = 0;
   double s          = lotStep;
   while(stepDigits < 8 && MathAbs(s - MathRound(s)) > 1e-10) {
      s *= 10.0;
      stepDigits++;
   }

   return NormalizeDouble(norm, stepDigits);
}

int SignFromValue(const double value, const double eps = 1e-8) {
   if(value > eps)
      return 1;
   if(value < -eps)
      return -1;
   return 0;
}

string DirectionToOperationText(const int direction) {
   return (direction >= 0 ? "long" : "short");
}

string TradeSideModeToText() {
   if(InpTradeSideMode == TRADE_SIDE_LHS)
      return "LHS";
   if(InpTradeSideMode == TRADE_SIDE_RHS)
      return "RHS";
   return "BOTH";
}

bool IsLhsEnabled() {
   return (InpTradeSideMode == TRADE_SIDE_BOTH || InpTradeSideMode == TRADE_SIDE_LHS);
}

bool IsRhsEnabled() {
   return (InpTradeSideMode == TRADE_SIDE_BOTH || InpTradeSideMode == TRADE_SIDE_RHS);
}

string BuildEquationText() {
   return StringFormat("%s=(%.8f)*%s+(%.8f)*%s+%.8f",
                       g_lhsResolved,
                       InpCoeff1,
                       g_rhs1Resolved,
                       InpCoeff2,
                       g_rhs2Resolved,
                       InpIntercept);
}

string BuildDealPlanText(const int signalDirection) {
   if(signalDirection != 1 && signalDirection != -1)
      return "none";

   int lhsDir = (signalDirection == 1 ? 1 : -1);
   int rhsDir = -lhsDir;

   double lhsLots  = NormalizeVolume(g_lhsResolved, InpLotMultiplier);
   double rhs1Lots = NormalizeVolume(g_rhs1Resolved, InpLotMultiplier * MathAbs(InpCoeff1));
   double rhs2Lots = NormalizeVolume(g_rhs2Resolved, InpLotMultiplier * MathAbs(InpCoeff2));

   string plan = "";
   if(IsLhsEnabled()) {
      plan += StringFormat("LHS:%s %s %.2f",
                           DirectionToOperationText(lhsDir),
                           g_lhsResolved,
                           lhsLots);
   }

   if(IsRhsEnabled()) {
      if(StringLen(plan) > 0)
         plan += " | ";
      plan += StringFormat("RHS1:%s %s %.2f; RHS2:%s %s %.2f",
                           DirectionToOperationText(rhsDir),
                           g_rhs1Resolved,
                           rhs1Lots,
                           DirectionToOperationText(rhsDir),
                           g_rhs2Resolved,
                           rhs2Lots);
   }

   if(StringLen(plan) == 0)
      return "none";

   return plan;
}

int CreateVariantIndicatorHandle(const string indicatorName) {
   return iCustom(_Symbol,
                  _Period,
                  indicatorName,
                  InpSignalTimeframe,
                  InpVariantPlotBars,
                  true,
                  g_lhsResolved,
                  g_rhs1Resolved,
                  g_rhs2Resolved,
                  InpCoeff1,
                  InpCoeff2,
                  InpIntercept,
                  clrDeepSkyBlue,
                  false,
                  "",
                  "",
                  "",
                  0.0,
                  0.0,
                  0.0,
                  clrOrange,
                  false,
                  "",
                  "",
                  "",
                  0.0,
                  0.0,
                  0.0,
                  clrLimeGreen);
}

bool TryAttachVariantPlotByName(const string indicatorName) {
   int handle = CreateVariantIndicatorHandle(indicatorName);
   if(handle == INVALID_HANDLE)
      return false;

   int targetWindow = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL, 0);
   if(!ChartIndicatorAdd(0, targetWindow, handle)) {
      PrintFormat("[WARN] Failed to attach variant indicator '%s' (err=%d)", indicatorName, GetLastError());
      IndicatorRelease(handle);
      return false;
   }

   g_variantHandle    = handle;
   g_variantSubwindow = targetWindow;

   ENUM_TIMEFRAMES tf = (InpSignalTimeframe == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpSignalTimeframe);
   g_variantShortName = "Cointegration Variant Plot (" + EnumToString(tf) + ")";

   PrintFormat("[INFO] Variant plot attached using '%s'", indicatorName);
   return true;
}

bool AttachVariantPlot() {
   if(!InpShowVariantPlot)
      return true;

   // Try several likely names so it works whether the indicator is in Experts or Indicators tree.
   string names[] = {
       "Experts\\CMK\\cointegration\\cointegration_variant_plot",
       "\\Experts\\CMK\\cointegration\\cointegration_variant_plot",
       "CMK\\cointegration\\cointegration_variant_plot",
       "cointegration_variant_plot"};

   for(int i = 0; i < ArraySize(names); i++) {
      if(TryAttachVariantPlotByName(names[i]))
         return true;
   }

   Print("[WARN] Variant plot indicator could not be loaded. Trading continues without plot.");
   Print("[WARN] Ensure cointegration_variant_plot is compiled and accessible to iCustom.");
   return false;
}

void DetachVariantPlot() {
   if(g_variantShortName != "" && g_variantSubwindow >= 0)
      ChartIndicatorDelete(0, g_variantSubwindow, g_variantShortName);

   if(g_variantHandle != INVALID_HANDLE) {
      IndicatorRelease(g_variantHandle);
      g_variantHandle = INVALID_HANDLE;
   }

   g_variantSubwindow = -1;
   g_variantShortName = "";
}

double GetManagedNetVolume(const string symbol) {
   double net   = 0.0;
   int    total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      long   magic     = PositionGetInteger(POSITION_MAGIC);
      if(posSymbol != symbol || (ulong)magic != InpMagicNumber)
         continue;

      long   type   = PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);

      if(type == POSITION_TYPE_BUY)
         net += volume;
      else if(type == POSITION_TYPE_SELL)
         net -= volume;
   }

   return net;
}

int GetBasketDirection() {
   int lhsSign  = SignFromValue(GetManagedNetVolume(g_lhsResolved));
   int rhs1Sign = SignFromValue(GetManagedNetVolume(g_rhs1Resolved));
   int rhs2Sign = SignFromValue(GetManagedNetVolume(g_rhs2Resolved));

   if(InpTradeSideMode == TRADE_SIDE_LHS) {
      if(rhs1Sign != 0 || rhs2Sign != 0)
         return 99;
      if(lhsSign == 1)
         return 1;
      if(lhsSign == -1)
         return -1;
      return 0;
   }

   if(InpTradeSideMode == TRADE_SIDE_RHS) {
      if(lhsSign != 0)
         return 99;
      if(rhs1Sign == 0 && rhs2Sign == 0)
         return 0;
      if(rhs1Sign != rhs2Sign)
         return 99;

      return (rhs1Sign == -1 ? 1 : -1);   // signal=1 means RHS short; signal=-1 means RHS long
   }

   if(lhsSign == 1 && rhs1Sign == -1 && rhs2Sign == -1)
      return 1;   // LHS long, RHS legs short

   if(lhsSign == -1 && rhs1Sign == 1 && rhs2Sign == 1)
      return -1;   // LHS short, RHS legs long

   if(lhsSign == 0 && rhs1Sign == 0 && rhs2Sign == 0)
      return 0;

   return 99;   // Mixed/partial state
}

bool CloseManagedSymbolPositions(const string symbol) {
   bool allClosed = true;
   int  total     = PositionsTotal();

   for(int i = total - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      long   magic     = PositionGetInteger(POSITION_MAGIC);
      if(posSymbol != symbol || (ulong)magic != InpMagicNumber)
         continue;

      if(!g_trade.PositionClose(ticket)) {
         allClosed = false;
         PrintFormat("[ERROR] Failed to close %s ticket %I64u. ret=%d %s",
                     symbol,
                     ticket,
                     g_trade.ResultRetcode(),
                     g_trade.ResultRetcodeDescription());
      }
   }

   return allClosed;
}

bool CloseManagedBasket() {
   bool ok1 = CloseManagedSymbolPositions(g_lhsResolved);
   bool ok2 = CloseManagedSymbolPositions(g_rhs1Resolved);
   bool ok3 = CloseManagedSymbolPositions(g_rhs2Resolved);
   return (ok1 && ok2 && ok3);
}

bool OpenLeg(const string symbol, const int direction, const double volume) {
   if(direction == 0 || volume <= 0.0)
      return true;

   double normalizedVolume = NormalizeVolume(symbol, volume);
   if(normalizedVolume <= 0.0) {
      PrintFormat("[ERROR] Invalid volume for %s (requested=%.6f)", symbol, volume);
      return false;
   }

   g_trade.SetTypeFillingBySymbol(symbol);

   bool sent = false;
   if(direction > 0)
      sent = g_trade.Buy(normalizedVolume, symbol);
   else
      sent = g_trade.Sell(normalizedVolume, symbol);

   if(!sent) {
      PrintFormat("[ERROR] Failed to open %s %s %.2f. ret=%d %s",
                  (direction > 0 ? "BUY" : "SELL"),
                  symbol,
                  normalizedVolume,
                  g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
      return false;
   }

   PrintFormat("[ORDER] Eq:%s | %s %s %.2f",
               BuildEquationText(),
               (direction > 0 ? "BUY" : "SELL"),
               symbol,
               normalizedVolume);
   return true;
}

bool OpenBasketBySignal(const int signalDirection) {
   if(signalDirection != 1 && signalDirection != -1)
      return false;

   double lhsLots  = InpLotMultiplier;
   double rhs1Lots = InpLotMultiplier * MathAbs(InpCoeff1);
   double rhs2Lots = InpLotMultiplier * MathAbs(InpCoeff2);

   int lhsDir = (signalDirection == 1 ? 1 : -1);
   int rhsDir = -lhsDir;

   bool okLhs  = true;
   bool okRhs1 = true;
   bool okRhs2 = true;

   if(IsLhsEnabled())
      okLhs = OpenLeg(g_lhsResolved, lhsDir, lhsLots);

   if(IsRhsEnabled()) {
      okRhs1 = OpenLeg(g_rhs1Resolved, rhsDir, rhs1Lots);
      okRhs2 = OpenLeg(g_rhs2Resolved, rhsDir, rhs2Lots);
   }

   return (okLhs && okRhs1 && okRhs2);
}

bool IsNewBar() {
   ENUM_TIMEFRAMES tf = (InpSignalTimeframe == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpSignalTimeframe);
   datetime        t  = iTime(_Symbol, tf, 0);
   if(t <= 0)
      return false;

   if(t == g_lastBarTime)
      return false;

   g_lastBarTime = t;
   return true;
}

bool GetVariantSpreadFromIndicator(double &variantSpread) {
   if(g_variantHandle == INVALID_HANDLE)
      return false;

   double buf[];
   int    copied = CopyBuffer(g_variantHandle, 0, 0, 3, buf);
   if(copied <= 0)
      return false;

   for(int i = 0; i < copied; i++) {
      double v = buf[i];
      if(v != EMPTY_VALUE) {
         variantSpread = v;
         return true;
      }
   }

   return false;
}

int EvaluateSignal(double &lhs, double &rhs, double &spread) {
   double lhsPrice  = 0.0;
   double rhs1Price = 0.0;
   double rhs2Price = 0.0;

   if(!GetMidPrice(g_lhsResolved, lhsPrice))
      return 0;
   if(!GetMidPrice(g_rhs1Resolved, rhs1Price))
      return 0;
   if(!GetMidPrice(g_rhs2Resolved, rhs2Price))
      return 0;

   lhs    = lhsPrice;
   rhs    = InpCoeff1 * rhs1Price + InpCoeff2 * rhs2Price + InpIntercept;
   spread = lhs - rhs;

   // Reuse variant-plot indicator calculation when available.
   // Fallback remains the direct equation calculation above.
   double indicatorSpread = 0.0;
   if(GetVariantSpreadFromIndicator(indicatorSpread)) {
      spread = indicatorSpread;
      rhs    = lhs - spread;
   }

   // Mean-reversion direction:
   // spread > 0 (LHS above RHS)  -> short LHS / long RHS legs
   // spread < 0 (LHS below RHS)  -> long LHS / short RHS legs
   if(spread > InpSignalThreshold)
      return -1;
   if(spread < -InpSignalThreshold)
      return 1;

   return 0;
}

int OnInit() {
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);

   if(InpLotMultiplier <= 0.0) {
      Print("[ERROR] InpLotMultiplier must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   bool ok = true;
   ok      = ok && PrepareSymbol(InpLhsSymbol, g_lhsResolved);
   ok      = ok && PrepareSymbol(InpRhsSymbol1, g_rhs1Resolved);
   ok      = ok && PrepareSymbol(InpRhsSymbol2, g_rhs2Resolved);

   if(!ok)
      return INIT_FAILED;

   PrintFormat("[INIT] Equation: %s = (%.8f)*%s + (%.8f)*%s + %.8f",
               g_lhsResolved,
               InpCoeff1,
               g_rhs1Resolved,
               InpCoeff2,
               g_rhs2Resolved,
               InpIntercept);

   if(!InitializeTradeLogCsv())
      Print("[WARN] Trade CSV log is not initialized. Logging may fail.");
   else
      PrintFormat("[INFO] Trade CSV log: %s%s",
                  (InpTradeLogCommon ? "[COMMON] " : "[LOCAL] "),
                  g_tradeLogResolvedPath);

   if(InpShowVariantPlot)
      AttachVariantPlot();

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   DetachVariantPlot();
   PrintFormat("[DEINIT] cointegration_apply stopped. reason=%d", reason);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result) {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal = trans.deal;
   if(deal == 0)
      return;

   if(!HistoryDealSelect(deal))
      return;

   long magic = HistoryDealGetInteger(deal, DEAL_MAGIC);
   if((ulong)magic != InpMagicNumber)
      return;

   string symbol = HistoryDealGetString(deal, DEAL_SYMBOL);
   if(!IsManagedSymbol(symbol))
      return;

   long entry    = HistoryDealGetInteger(deal, DEAL_ENTRY);
   long dealType = HistoryDealGetInteger(deal, DEAL_TYPE);
   if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL)
      return;

   ulong positionId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   if(positionId == 0)
      return;

   datetime dealTime = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   double   volume   = HistoryDealGetDouble(deal, DEAL_VOLUME);
   double   price    = HistoryDealGetDouble(deal, DEAL_PRICE);

   if(entry == DEAL_ENTRY_IN) {
      int direction = (dealType == DEAL_TYPE_BUY ? 1 : -1);
      UpsertOpenState(positionId, symbol, dealTime, price, volume, direction);

      string openRow = StringFormat("%s,%s,%.2f,%.5f,%s,start,,",
                                    TimeToString(dealTime, TIME_DATE | TIME_SECONDS),
                                    symbol,
                                    volume,
                                    price,
                                    DirectionToOperationText(direction));
      AppendTradeCsvRow(openRow);
      return;
   }

   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) {
      OpenPositionState st;
      if(!GetOpenState(positionId, st)) {
         if(!LoadOpenStateFromHistory(positionId, st))
            return;
      }

      double pipSize = GetPipSize(symbol);
      if(pipSize <= 0.0)
         return;

      double profitPips   = (st.direction > 0) ? ((price - st.openPrice) / pipSize) : ((st.openPrice - price) / pipSize);
      double durationMins = (double)(dealTime - st.openTime) / 60.0;

      string closeRow = StringFormat("%s,%s,%.2f,%.5f,%s,end,%.2f,%.2f",
                                     TimeToString(st.openTime, TIME_DATE | TIME_SECONDS),
                                     symbol,
                                     volume,
                                     price,
                                     DirectionToOperationText(st.direction),
                                     profitPips,
                                     durationMins);
      AppendTradeCsvRow(closeRow);

      if(!IsPositionIdStillOpen(positionId)) {
         int idx = FindOpenStateIndex(positionId);
         if(idx >= 0)
            RemoveOpenStateByIndex(idx);
      }
   }
}

void OnTick() {
   if(InpTradeOnNewBar && !IsNewBar())
      return;

   double lhs    = 0.0;
   double rhs    = 0.0;
   double spread = 0.0;

   int signal = EvaluateSignal(lhs, rhs, spread);
   int basket = GetBasketDirection();

   string eqText   = BuildEquationText();
   string dealPlan = BuildDealPlanText(signal);

   PrintFormat("[STATE] Eq:%s Mode=%s LHS=%.6f RHS=%.6f Spread=%.6f Signal=%d Basket=%d Deal=%s",
               eqText,
               TradeSideModeToText(),
               lhs,
               rhs,
               spread,
               signal,
               basket,
               dealPlan);

   if(signal == 0) {
      if(InpCloseOnNeutral && basket != 0) {
         if(CloseManagedBasket())
            Print("[ACTION] Closed basket in neutral zone.");
      }
      return;
   }

   if(basket == signal)
      return;

   if(basket != 0) {
      if(!CloseManagedBasket())
         return;
   }

   PrintFormat("[DEAL] Eq:%s Mode=%s Signal=%d -> %s",
               eqText,
               TradeSideModeToText(),
               signal,
               dealPlan);

   OpenBasketBySignal(signal);
}
