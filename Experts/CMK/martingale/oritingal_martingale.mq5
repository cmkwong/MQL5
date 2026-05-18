#property strict
#property version "1.00"

#include <Trade/AccountInfo.mqh>
#include <Trade/Trade.mqh>

input string          InpTradeSymbol     = "";               // Symbol to trade (empty = chart symbol)
input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_CURRENT;   // Signal timeframe
input bool            InpTradeOnNewBar   = true;             // Open at most once per new signal bar

input double InpBaseLot              = 0.01;   // Base lot size
input double InpMartingaleMultiplier = 2.0;    // Lot multiplier after each loss
input int    InpMaxGridPositions     = 8;      // Maximum positions per grid basket (including initial)
input double InpGridStepPips         = 10.0;   // Distance in pips to open next grid position
input double InpGridStepMultiplier   = 1.00;   // Optional widening factor by grid level

input double InpSLPips          = 100.0;                                       // Stop loss in pips
input double InpTPPips          = 150.0;                                       // Take profit in pips
input double InpBreakEvenTPPips = 20.0;                                        // Basket break-even TP offset in pips
input string InpLogCsvFileName  = "martingale/oritingal_martingale_log.csv";   // CSV log file name
input bool   InpLogUseCommon    = true;                                        // Store log in Common Files

input ulong InpMagicNumber    = 26051001;   // EA magic number
input int   InpDeviationPoint = 20;         // Slippage in points

CTrade              g_trade;
static CAccountInfo g_accountInfo;

string          g_tradeSymbol           = "";
ENUM_TIMEFRAMES g_signalTimeframe       = PERIOD_CURRENT;
datetime        g_lastBarTime           = 0;
int             g_activeBasketDirection = 0;
datetime        g_basketStartTime       = 0;
double          g_basketProfitPips      = 0.0;
double          g_basketProfitUsd       = 0.0;
string          g_basketStepsConcat     = "";
string          g_runLogCsvFileName     = "";

// Converts a string to uppercase for case-insensitive comparisons.
string ToUpperCopy(const string value) {
   string out = value;
   StringToUpper(out);
   return out;
}

// Converts datetime to a stable log text format.
string DateTimeToText(const datetime value) {
   return TimeToString(value, TIME_DATE | TIME_SECONDS);
}

// Finds the last index of a character in a string.
int FindLastCharIndex(const string text, const ushort ch) {
   int last = -1;
   int len  = StringLen(text);
   for(int i = 0; i < len; i++) {
      if((ushort)StringGetCharacter(text, i) == ch)
         last = i;
   }
   return last;
}

// Returns a filesystem-safe timestamp string like YYYYMMDD_HHMMSS.
string DateTimeToStamp(const datetime value) {
   MqlDateTime tm = {};
   TimeToStruct(value, tm);
   return StringFormat("%04d%02d%02d_%02d%02d%02d",
                       tm.year,
                       tm.mon,
                       tm.day,
                       tm.hour,
                       tm.min,
                       tm.sec);
}

// Adds run timestamp to output CSV file name so each test run uses a unique file.
string BuildRunLogFileName(const string baseName, const datetime runTime) {
   string base = baseName;
   if(StringLen(base) == 0)
      base = "oritingal_martingale_log.csv";

   int    lastSlash = MathMax(FindLastCharIndex(base, (ushort)'/'), FindLastCharIndex(base, (ushort)'\\'));
   int    lastDot   = FindLastCharIndex(base, (ushort)'.');
   string stamp     = DateTimeToStamp(runTime);

   if(lastDot > lastSlash) {
      string left = StringSubstr(base, 0, lastDot);
      string ext  = StringSubstr(base, lastDot);
      return left + "_" + stamp + ext;
   }

   return base + "_" + stamp + ".csv";
}

// Converts direction code into operation text.
string DirectionToOperation(const int direction) {
   if(direction > 0)
      return "long";
   if(direction < 0)
      return "short";
   return "";
}

// Returns the current final step as text.
string BuildStepsConcatFromCount(const int count) {
   if(count <= 0)
      return "";

   return IntegerToString(count);
}

// Resolves user input symbol to an available Market Watch symbol (exact first, then prefix match).
string ResolveSymbolName(const string requested) {
   string req = requested;
   StringTrimLeft(req);
   StringTrimRight(req);
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

// Returns pip size from symbol point/digits (handles 3/5-digit symbols).
double GetPipSize(const string symbol) {
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return 0.0;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return point * 10.0;

   return point;
}

// Normalizes price to symbol digits.
double NormalizePrice(const string symbol, const double price) {
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

// Normalizes requested volume into broker min/max/step constraints.
double NormalizeVolume(const string symbol, const double requestedVolume) {
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(requestedVolume <= 0.0 || minLot <= 0.0 || maxLot <= 0.0 || stepLot <= 0.0)
      return 0.0;

   double clipped    = MathMax(minLot, MathMin(maxLot, requestedVolume));
   double steps      = MathFloor(clipped / stepLot + 1e-10);
   double normalized = steps * stepLot;

   int    stepDigits = 0;
   double s          = stepLot;
   while(stepDigits < 8 && MathAbs(s - MathRound(s)) > 1e-10) {
      s *= 10.0;
      stepDigits++;
   }

   return NormalizeDouble(normalized, stepDigits);
}

// Counts managed positions by direction and returns extreme entry used for grid trigger.
int CountManagedPositions(const int directionFilter, double &extremeOpenPrice) {
   int count = 0;
   if(directionFilter > 0)
      extremeOpenPrice = DBL_MAX;
   else if(directionFilter < 0)
      extremeOpenPrice = -DBL_MAX;
   else
      extremeOpenPrice = 0.0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long   magic  = PositionGetInteger(POSITION_MAGIC);
      if(symbol != g_tradeSymbol || (ulong)magic != InpMagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      if(directionFilter > 0 && type != POSITION_TYPE_BUY)
         continue;
      if(directionFilter < 0 && type != POSITION_TYPE_SELL)
         continue;

      count++;

      if(directionFilter > 0) {
         double entry = PositionGetDouble(POSITION_PRICE_OPEN);
         if(entry < extremeOpenPrice)
            extremeOpenPrice = entry;
      } else if(directionFilter < 0) {
         double entry = PositionGetDouble(POSITION_PRICE_OPEN);
         if(entry > extremeOpenPrice)
            extremeOpenPrice = entry;
      }
   }

   if(count == 0)
      extremeOpenPrice = 0.0;

   return count;
}

// Returns oldest open time for current managed basket side.
datetime GetOldestManagedPositionTime(const int directionFilter) {
   datetime oldest = 0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long   magic  = PositionGetInteger(POSITION_MAGIC);
      if(symbol != g_tradeSymbol || (ulong)magic != InpMagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      if(directionFilter > 0 && type != POSITION_TYPE_BUY)
         continue;
      if(directionFilter < 0 && type != POSITION_TYPE_SELL)
         continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(oldest == 0 || t < oldest)
         oldest = t;
   }

   return oldest;
}

// Detects whether the current basket is BUY-only, SELL-only, mixed, or empty.
int GetManagedBasketDirection() {
   double buyExtreme  = 0.0;
   double sellExtreme = 0.0;
   int    buyCount    = CountManagedPositions(1, buyExtreme);
   int    sellCount   = CountManagedPositions(-1, sellExtreme);

   if(buyCount > 0 && sellCount > 0)
      return 99;
   if(buyCount > 0)
      return 1;
   if(sellCount > 0)
      return -1;

   return 0;
}

// True only when a new bar appears on configured signal timeframe.
bool IsNewBar() {
   datetime currentBar = iTime(g_tradeSymbol, g_signalTimeframe, 0);
   if(currentBar <= 0)
      return false;

   if(currentBar == g_lastBarTime)
      return false;

   g_lastBarTime = currentBar;
   return true;
}

// Simple initial entry signal from last closed candle direction.
int GetBarDirectionSignal() {
   MqlRates bar[];
   ArraySetAsSeries(bar, true);

   int copied = CopyRates(g_tradeSymbol, g_signalTimeframe, 1, 1, bar);
   if(copied != 1)
      return 0;

   if(bar[0].close > bar[0].open)
      return 1;
   if(bar[0].close < bar[0].open)
      return -1;

   return 0;
}

// Builds per-order SL/TP with stop-level protection.
bool BuildSLTP(const int direction, double &sl, double &tp) {
   sl = 0.0;
   tp = 0.0;

   double point = SymbolInfoDouble(g_tradeSymbol, SYMBOL_POINT);
   double pip   = GetPipSize(g_tradeSymbol);
   if(point <= 0.0 || pip <= 0.0)
      return false;

   int    stopsLevelPoints = (int)SymbolInfoInteger(g_tradeSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist          = (double)stopsLevelPoints * point;

   double slDist = MathMax(InpSLPips * pip, minDist);
   double tpDist = MathMax(InpTPPips * pip, minDist);

   double ask = SymbolInfoDouble(g_tradeSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_tradeSymbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   if(direction > 0) {
      sl = NormalizePrice(g_tradeSymbol, ask - slDist);
      tp = NormalizePrice(g_tradeSymbol, ask + tpDist);
   } else {
      sl = NormalizePrice(g_tradeSymbol, bid + slDist);
      tp = NormalizePrice(g_tradeSymbol, bid - tpDist);
   }

   return true;
}

// Checks if account free margin is enough for the next order.
bool HasEnoughMarginForOrder(const int signal, const double lot) {
   if((signal != 1 && signal != -1) || lot <= 0.0)
      return false;

   double ask = SymbolInfoDouble(g_tradeSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_tradeSymbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   ENUM_ORDER_TYPE orderType  = (signal > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double          orderPrice = (signal > 0 ? ask : bid);

   // Pre-check margin before sending any order.
   double requiredMargin = g_accountInfo.MarginCheck(g_tradeSymbol, orderType, lot, orderPrice);
   if(requiredMargin > g_accountInfo.FreeMargin()) {
      PrintFormat("[ERROR] Not enough margin. Required=%.2f Free=%.2f signal=%d lot=%.2f",
                  requiredMargin,
                  g_accountInfo.FreeMargin(),
                  signal,
                  lot);
      return false;
   }

   return true;
}

// Converts money result to pips for the closed volume.
double MoneyToPips(const string symbol, const double money, const double volume) {
   if(volume <= 0.0)
      return 0.0;

   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double pip       = GetPipSize(symbol);
   if(tickSize <= 0.0 || tickValue <= 0.0 || pip <= 0.0)
      return 0.0;

   double pipValuePerLot = tickValue * (pip / tickSize);
   if(pipValuePerLot <= 0.0)
      return 0.0;

   return money / (volume * pipValuePerLot);
}

// Appends one basket summary row to CSV log file.
void AppendBasketLog(const datetime startTime,
                     const int      direction,
                     const double   durationHours,
                     const double   profitPips,
                     const double   profitUsd,
                     const string   stepsConcat) {
   if(StringLen(g_runLogCsvFileName) == 0)
      return;

   int flags = FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI;
   if(InpLogUseCommon)
      flags |= FILE_COMMON;

   int h = FileOpen(g_runLogCsvFileName, flags, ',');
   if(h == INVALID_HANDLE) {
      PrintFormat("[ERROR] Cannot open log file %s (err=%d)", g_runLogCsvFileName, GetLastError());
      return;
   }

   bool needHeader = (FileSize(h) == 0);
   FileSeek(h, 0, SEEK_END);

   if(needHeader)
      FileWrite(h, "date_time", "operation", "duration_hours", "profit_pips", "profit_usd", "steps");

   FileWrite(h,
             DateTimeToText(startTime),
             DirectionToOperation(direction),
             DoubleToString(durationHours, 4),
             DoubleToString(profitPips, 2),
             DoubleToString(profitUsd, 2),
             stepsConcat);

   FileClose(h);
}

// Synchronizes basket state when EA starts with existing managed positions.
void SyncBasketStateFromPositions() {
   int dir = GetManagedBasketDirection();
   if(dir != 1 && dir != -1)
      return;

   g_activeBasketDirection = dir;
   g_basketStartTime       = GetOldestManagedPositionTime(dir);

   double sideExtreme  = 0.0;
   int    sideCount    = CountManagedPositions(dir, sideExtreme);
   g_basketStepsConcat = BuildStepsConcatFromCount(sideCount);
}

// Starts a basket log session if this is the first order.
void StartOrExtendBasketSession(const int direction, const int gridLevel) {
   if(direction != 1 && direction != -1)
      return;

   if(g_activeBasketDirection == 0) {
      g_activeBasketDirection = direction;
      g_basketStartTime       = TimeCurrent();
      g_basketProfitPips      = 0.0;
      g_basketProfitUsd       = 0.0;
      g_basketStepsConcat     = IntegerToString(gridLevel + 1);
      return;
   }

   if(g_activeBasketDirection != direction)
      return;

   string stepText     = IntegerToString(gridLevel + 1);
   g_basketStepsConcat = stepText;
}

// Writes CSV row when a basket is fully closed.
void FinalizeBasketIfClosed() {
   if(g_activeBasketDirection == 0)
      return;

   int dirNow = GetManagedBasketDirection();
   if(dirNow != 0)
      return;

   datetime endTime       = TimeCurrent();
   datetime startTime     = (g_basketStartTime > 0 ? g_basketStartTime : endTime);
   double   durationHours = (double)(endTime - startTime) / 3600.0;

   AppendBasketLog(startTime,
                   g_activeBasketDirection,
                   durationHours,
                   g_basketProfitPips,
                   g_basketProfitUsd,
                   g_basketStepsConcat);

   g_activeBasketDirection = 0;
   g_basketStartTime       = 0;
   g_basketProfitPips      = 0.0;
   g_basketProfitUsd       = 0.0;
   g_basketStepsConcat     = "";
}

// Closes all managed positions on one direction (BUY or SELL).
bool CloseManagedPositions(const int directionFilter) {
   ulong tickets[];
   ArrayResize(tickets, 0);

   int total = PositionsTotal();
   for(int i = 0; i < total; i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long   magic  = PositionGetInteger(POSITION_MAGIC);
      if(symbol != g_tradeSymbol || (ulong)magic != InpMagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      if(directionFilter > 0 && type != POSITION_TYPE_BUY)
         continue;
      if(directionFilter < 0 && type != POSITION_TYPE_SELL)
         continue;

      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      tickets[n] = ticket;
   }

   bool allClosed = true;
   for(int i = 0; i < ArraySize(tickets); i++) {
      if(!g_trade.PositionClose(tickets[i], ULONG_MAX)) {
         PrintFormat("[ERROR] Close failed ticket=%I64u ret=%d %s",
                     tickets[i],
                     g_trade.ResultRetcode(),
                     g_trade.ResultRetcodeDescription());
         allClosed = false;
      }
   }

   return allClosed;
}

// Closes basket when price reaches weighted average entry plus/minus break-even offset.
void CheckBreakEvenTakeProfit() {
   if(InpBreakEvenTPPips <= 0.0)
      return;

   double pip = GetPipSize(g_tradeSymbol);
   if(pip <= 0.0)
      return;

   double totalBuyVolume  = 0.0;
   double totalBuyCost    = 0.0;
   double totalSellVolume = 0.0;
   double totalSellCost   = 0.0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long   magic  = PositionGetInteger(POSITION_MAGIC);
      if(symbol != g_tradeSymbol || (ulong)magic != InpMagicNumber)
         continue;

      long   type   = PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double entry  = PositionGetDouble(POSITION_PRICE_OPEN);

      if(type == POSITION_TYPE_BUY) {
         totalBuyVolume += volume;
         totalBuyCost   += entry * volume;
      } else if(type == POSITION_TYPE_SELL) {
         totalSellVolume += volume;
         totalSellCost   += entry * volume;
      }
   }

   // Break-even TP offset in absolute price terms.
   double beOffset = InpBreakEvenTPPips * pip;

   if(totalBuyVolume > 0.0) {
      double buyAvg = totalBuyCost / totalBuyVolume;
      double beTp   = buyAvg + beOffset;
      double bid    = SymbolInfoDouble(g_tradeSymbol, SYMBOL_BID);
      if(bid > 0.0 && bid >= beTp) {
         PrintFormat("[BE-TP] BUY basket hit. bid=%.5f target=%.5f avg=%.5f", bid, beTp, buyAvg);
         CloseManagedPositions(1);
      }
   }

   if(totalSellVolume > 0.0) {
      double sellAvg = totalSellCost / totalSellVolume;
      double beTp    = sellAvg - beOffset;
      double ask     = SymbolInfoDouble(g_tradeSymbol, SYMBOL_ASK);
      if(ask > 0.0 && ask <= beTp) {
         PrintFormat("[BE-TP] SELL basket hit. ask=%.5f target=%.5f avg=%.5f", ask, beTp, sellAvg);
         CloseManagedPositions(-1);
      }
   }
}

// Opens one order and sizes lot by current side position count (grid level).
bool OpenTrade(const int signal) {
   if(signal != 1 && signal != -1)
      return false;

   double sideExtreme = 0.0;
   int    sideCount   = CountManagedPositions(signal, sideExtreme);
   int    gridLevel   = sideCount;

   double requestedLot = InpBaseLot * MathPow(InpMartingaleMultiplier, (double)gridLevel);
   double lot          = NormalizeVolume(g_tradeSymbol, requestedLot);
   if(lot <= 0.0) {
      PrintFormat("[ERROR] Invalid lot. requested=%.6f gridLevel=%d", requestedLot, gridLevel);
      return false;
   }

   if(!HasEnoughMarginForOrder(signal, lot))
      return false;

   double sl = 0.0;
   double tp = 0.0;
   if(!BuildSLTP(signal, sl, tp)) {
      Print("[ERROR] Failed to build SL/TP");
      return false;
   }

   g_trade.SetTypeFillingBySymbol(g_tradeSymbol);

   bool ok = false;
   if(signal > 0)
      ok = g_trade.Buy(lot, g_tradeSymbol, 0.0, sl, tp);
   else
      ok = g_trade.Sell(lot, g_tradeSymbol, 0.0, sl, tp);

   if(!ok) {
      PrintFormat("[ERROR] Open failed. signal=%d lot=%.2f ret=%d %s",
                  signal,
                  lot,
                  g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
      return false;
   }

   PrintFormat("[OPEN] %s lot=%.2f gridLevel=%d sl=%.5f tp=%.5f",
               (signal > 0 ? "BUY" : "SELL"),
               lot,
               gridLevel,
               sl,
               tp);

   StartOrExtendBasketSession(signal, gridLevel);

   return true;
}

// Evaluates grid condition and adds next position when adverse move reaches grid trigger.
bool TryOpenNextGridPosition(const int basketDirection) {
   if(basketDirection != 1 && basketDirection != -1)
      return false;

   double extremeEntry = 0.0;
   int    basketCount  = CountManagedPositions(basketDirection, extremeEntry);
   if(basketCount <= 0)
      return false;

   if(basketCount >= InpMaxGridPositions)
      return false;

   double pip = GetPipSize(g_tradeSymbol);
   if(pip <= 0.0)
      return false;

   // Match the original-style spacing: base grid step * widening factor by position count.
   double gridDistance = InpGridStepPips * pip * MathPow(InpGridStepMultiplier, (double)basketCount);

   if(basketDirection > 0) {
      double ask = SymbolInfoDouble(g_tradeSymbol, SYMBOL_ASK);
      if(ask <= 0.0)
         return false;

      double nextBuyPrice = extremeEntry - gridDistance;
      if(ask <= nextBuyPrice)
         return OpenTrade(1);

      return false;
   }

   double bid = SymbolInfoDouble(g_tradeSymbol, SYMBOL_BID);
   if(bid <= 0.0)
      return false;

   double nextSellPrice = extremeEntry + gridDistance;
   if(bid >= nextSellPrice)
      return OpenTrade(-1);

   return false;
}

// Validates inputs, resolves symbol/timeframe, and initializes trading context.
int OnInit() {
   if(InpBaseLot <= 0.0 || InpMartingaleMultiplier <= 1.0 || InpMaxGridPositions < 1) {
      Print("[ERROR] Invalid martingale parameters");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpGridStepPips <= 0.0 || InpGridStepMultiplier <= 0.0) {
      Print("[ERROR] Grid step settings must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpSLPips <= 0.0 || InpTPPips <= 0.0 || InpBreakEvenTPPips <= 0.0) {
      Print("[ERROR] SL/TP pips must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(StringLen(InpTradeSymbol) == 0)
      g_tradeSymbol = _Symbol;
   else {
      g_tradeSymbol = ResolveSymbolName(InpTradeSymbol);
      if(StringLen(g_tradeSymbol) == 0) {
         PrintFormat("[ERROR] Trade symbol not found: %s", InpTradeSymbol);
         return INIT_PARAMETERS_INCORRECT;
      }
   }

   if(!SymbolSelect(g_tradeSymbol, true)) {
      PrintFormat("[ERROR] Could not select symbol: %s", g_tradeSymbol);
      return INIT_FAILED;
   }

   g_signalTimeframe = (InpSignalTimeframe == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpSignalTimeframe);
   if(PeriodSeconds(g_signalTimeframe) <= 0) {
      Print("[ERROR] Invalid signal timeframe");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoint);

   g_runLogCsvFileName = BuildRunLogFileName(InpLogCsvFileName, TimeLocal());

   SyncBasketStateFromPositions();

   PrintFormat("[INIT] oritingal_martingale on %s %s | BaseLot=%.2f Mult=%.2f MaxPos=%d GridStep=%.1f GridStepMult=%.2f | SL=%.1f TP=%.1f BE-TP=%.1f pips",
               g_tradeSymbol,
               EnumToString(g_signalTimeframe),
               InpBaseLot,
               InpMartingaleMultiplier,
               InpMaxGridPositions,
               InpGridStepPips,
               InpGridStepMultiplier,
               InpSLPips,
               InpTPPips,
               InpBreakEvenTPPips);

   PrintFormat("[INIT] Log file: %s%s",
               (InpLogUseCommon ? "[COMMON] " : "[LOCAL] "),
               g_runLogCsvFileName);

   return INIT_SUCCEEDED;
}

// Captures closed deals and accumulates basket profit in pips.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result) {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal = trans.deal;
   if(deal == 0 || !HistoryDealSelect(deal))
      return;

   string symbol = HistoryDealGetString(deal, DEAL_SYMBOL);
   if(symbol != g_tradeSymbol)
      return;

   long magic = HistoryDealGetInteger(deal, DEAL_MAGIC);
   if((ulong)magic != InpMagicNumber)
      return;

   long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   double volume = HistoryDealGetDouble(deal, DEAL_VOLUME);
   double net    = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_COMMISSION);

   if(g_activeBasketDirection != 0) {
      g_basketProfitPips += MoneyToPips(g_tradeSymbol, net, volume);
      g_basketProfitUsd  += net;
   }
}

// Main loop: run basket break-even exit, then grid expansion or fresh entry.
void OnTick() {
   CheckBreakEvenTakeProfit();
   FinalizeBasketIfClosed();

   int basketDirection = GetManagedBasketDirection();
   if(basketDirection == 99) {
      Print("[WARN] Mixed managed BUY/SELL positions detected. Grid add is disabled until one side is closed.");
      return;
   }

   if(basketDirection != 0) {
      TryOpenNextGridPosition(basketDirection);
      return;
   }

   if(InpTradeOnNewBar && !IsNewBar())
      return;

   int signal = GetBarDirectionSignal();
   if(signal == 0)
      return;

   OpenTrade(signal);
}
