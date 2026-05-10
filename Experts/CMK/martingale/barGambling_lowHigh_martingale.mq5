#property strict
#property version "1.00"

#include <Trade/Trade.mqh>

input string          InpTradeSymbol     = "";               // Symbol to trade (empty = chart symbol)
input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_CURRENT;   // Timeframe for pattern check
input bool            InpTradeOnNewBar   = true;             // Evaluate only on a new signal bar

input double InpBearBreakPct      = 120.0;   // Bear setup break threshold (% of first bar body)
input double InpBullBreakPct      = 150.0;   // Bull setup break threshold (% of first bar body)
input double InpOpenNearClosePips = 10.0;    // |Open(second) - Close(first)| <= this many pips

input double InpBaseLotShort = 0.01;   // Base lot for short setup
input double InpBaseLotLong  = 0.02;   // Base lot for long setup
input int    InpInitialStep  = 1;      // Initial martingale step per direction
input int    InpMinStep      = 1;      // Minimum step floor
input int    InpMaxStep      = 20;     // Maximum step cap

input double InpSLPips = 10.0;   // Stop loss in pips
input double InpTPPips = 15.0;   // Take profit in pips

input ulong InpMagicNumber    = 26050901;   // EA magic number
input int   InpDeviationPoint = 20;         // Slippage in points

CTrade g_trade;

string          g_tradeSymbol     = "";
ENUM_TIMEFRAMES g_signalTimeframe = PERIOD_CURRENT;
datetime        g_lastBarTime     = 0;
int             g_stepLong        = 1;
int             g_stepShort       = 1;

string ToUpperCopy(const string value) {
   string out = value;
   StringToUpper(out);
   return out;
}

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

double GetPipSize(const string symbol) {
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return 0.0;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return point * 10.0;

   return point;
}

double NormalizePrice(const string symbol, const double price) {
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

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

bool HasManagedPosition() {
   int total = PositionsTotal();
   for(int i = 0; i < total; i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long   magic  = PositionGetInteger(POSITION_MAGIC);
      if(symbol == g_tradeSymbol && (ulong)magic == InpMagicNumber)
         return true;
   }
   return false;
}

bool IsNewBar() {
   datetime currentBar = iTime(g_tradeSymbol, g_signalTimeframe, 0);
   if(currentBar <= 0)
      return false;

   if(currentBar == g_lastBarTime)
      return false;

   g_lastBarTime = currentBar;
   return true;
}

int GetPatternSignal() {
   MqlRates bars[];
   ArraySetAsSeries(bars, true);

   int copied = CopyRates(g_tradeSymbol, g_signalTimeframe, 1, 2, bars);
   if(copied != 2)
      return 0;

   MqlRates second = bars[0];   // Most recent closed bar
   MqlRates first  = bars[1];   // Previous closed bar

   double pip = GetPipSize(g_tradeSymbol);
   if(pip <= 0.0)
      return 0;

   bool openNearClose = (MathAbs(second.open - first.close) <= InpOpenNearClosePips * pip);

   bool   firstUp       = (first.close > first.open);
   bool   secondDown    = (second.close < second.open);
   double firstUpBody   = MathMax(0.0, first.close - first.open);
   double bearBreakMove = first.open - second.close;
   double bearNeeded    = firstUpBody * (InpBearBreakPct / 100.0);
   bool   bearBreakOk   = (firstUpBody > 0.0 && bearBreakMove >= bearNeeded);

   if(firstUp && secondDown && openNearClose && bearBreakOk)
      return -1;

   bool   firstDown     = (first.close < first.open);
   bool   secondUp      = (second.close > second.open);
   double firstDownBody = MathMax(0.0, first.open - first.close);
   double bullBreakMove = second.close - first.open;
   double bullNeeded    = firstDownBody * (InpBullBreakPct / 100.0);
   bool   bullBreakOk   = (firstDownBody > 0.0 && bullBreakMove >= bullNeeded);

   if(firstDown && secondUp && openNearClose && bullBreakOk)
      return 1;

   return 0;
}

bool BuildSLTP(const int direction, double &sl, double &tp) {
   sl = 0.0;
   tp = 0.0;

   if(InpSLPips <= 0.0 || InpTPPips <= 0.0)
      return false;

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

bool OpenTrade(const int signal) {
   if(signal != 1 && signal != -1)
      return false;

   int    stepUsed     = (signal > 0 ? g_stepLong : g_stepShort);
   double baseLot      = (signal > 0 ? InpBaseLotLong : InpBaseLotShort);
   double requestedLot = baseLot * (double)stepUsed;
   double lot          = NormalizeVolume(g_tradeSymbol, requestedLot);
   if(lot <= 0.0) {
      PrintFormat("[ERROR] Invalid lot. signal=%d requested=%.6f step=%d", signal, requestedLot, stepUsed);
      return false;
   }

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
      PrintFormat("[ERROR] Open failed. signal=%d lot=%.2f sl=%.5f tp=%.5f ret=%d %s",
                  signal,
                  lot,
                  sl,
                  tp,
                  g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
      return false;
   }

   PrintFormat("[OPEN] %s lot=%.2f step=%d sl=%.5f tp=%.5f",
               (signal > 0 ? "BUY" : "SELL"),
               lot,
               stepUsed,
               sl,
               tp);

   return true;
}

int OnInit() {
   if(InpBearBreakPct <= 0.0 || InpBullBreakPct <= 0.0 || InpOpenNearClosePips < 0.0) {
      Print("[ERROR] Invalid pattern parameters");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpBaseLotShort <= 0.0 || InpBaseLotLong <= 0.0) {
      Print("[ERROR] Base lots must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpInitialStep < 1 || InpMinStep < 1 || InpMaxStep < InpMinStep) {
      Print("[ERROR] Invalid step parameters");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpSLPips <= 0.0 || InpTPPips <= 0.0) {
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

   g_stepLong  = MathMin(InpMaxStep, MathMax(InpMinStep, InpInitialStep));
   g_stepShort = MathMin(InpMaxStep, MathMax(InpMinStep, InpInitialStep));

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoint);

   PrintFormat("[INIT] barGambling_lowHigh_martingale on %s %s | BearPct=%.1f BullPct=%.1f Near=%.1f pips | BaseShort=%.2f BaseLong=%.2f | StepLong=%d StepShort=%d [%d..%d] | SL=%.1f TP=%.1f pips",
               g_tradeSymbol,
               EnumToString(g_signalTimeframe),
               InpBearBreakPct,
               InpBullBreakPct,
               InpOpenNearClosePips,
               InpBaseLotShort,
               InpBaseLotLong,
               g_stepLong,
               g_stepShort,
               InpMinStep,
               InpMaxStep,
               InpSLPips,
               InpTPPips);

   return INIT_SUCCEEDED;
}

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

   long dealType = HistoryDealGetInteger(deal, DEAL_TYPE);

   double net = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_COMMISSION);

   // Exit SELL deal usually closes a BUY position; exit BUY deal usually closes a SELL position.
   bool closedLong  = (dealType == DEAL_TYPE_SELL);
   bool closedShort = (dealType == DEAL_TYPE_BUY);
   if(!closedLong && !closedShort)
      return;

   if(closedLong) {
      if(net < 0.0)
         g_stepLong = MathMin(InpMaxStep, g_stepLong + 1);
      else if(net > 0.0)
         g_stepLong = MathMax(InpMinStep, g_stepLong - 1);

      PrintFormat("[MARTI] LONG close net=%.2f -> next LONG step=%d", net, g_stepLong);
      return;
   }

   if(net < 0.0)
      g_stepShort = MathMin(InpMaxStep, g_stepShort + 1);
   else if(net > 0.0)
      g_stepShort = MathMax(InpMinStep, g_stepShort - 1);

   PrintFormat("[MARTI] SHORT close net=%.2f -> next SHORT step=%d", net, g_stepShort);
}

void OnTick() {
   if(InpTradeOnNewBar && !IsNewBar())
      return;

   if(HasManagedPosition())
      return;

   int signal = GetPatternSignal();
   if(signal == 0)
      return;

   OpenTrade(signal);
}
