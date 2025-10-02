//+------------------------------------------------------------------+
//|                                                  MartingaleMA.mq5|
//|                                         Copyright 2025, YourName |
//|                    Added operation for offset the idle positions |
//+------------------------------------------------------------------+

#include <CMK/Helper.mqh>
#include <CMK/Num.mqh>
#include <CMK/String.mqh>
#include <CMK/Time.mqh>
#include <Trade/AccountInfo.mqh>
#include <Trade/Trade.mqh>
CTrade              trade;
static CAccountInfo accountInfo;

// grid parameters
input double i_initialLotSize      = 0.01;
input double i_lotMultiplier       = 1.1;
input int    i_gridStepPoints      = 50;
input double i_gridStepMultiplier  = 1.25;
input int    i_breakEvenTPPoints   = 200;
input int    i_symbolStopLossMoney = 2500;   // set to 0 means it is no stop loss
input int    i_sleepDays           = 120;    // after stop loss / no margin, the currency will be resume trading after this day passed

// strategy constant
string Symbols[]           = {"AUDNZD"};   // , "AUDUSD", "GBPUSD", "EURGBP"
int    RSIPeriod[]         = {14, 14, 14, 14};
int    HedgingAfterDays[]  = {10, 10, 10, 10};           // doing hedging after these day being hold
double HedgingMultiplier[] = {1.05, 1.05, 1.05, 1.05};   // The hedging mechanism will operate at this multiple in order to accelerate the completion of a position that has been maintained for a long time.
int    SymbolTotal         = ArraySize(Symbols);

// strategy variables
double   v_breakEvenTPs[ArraySize(Symbols)];
long     v_strategyMagicNumbers[ArraySize(Symbols)][2];   // magic number for first strategy
int      v_hedgingLevels[ArraySize(Symbols)][2];          // storate of the hedging level, 0 means the basic
datetime v_positionOpenDate[ArraySize(Symbols)][2];       // the opening date that position begin
datetime v_backToTradeUntil[ArraySize(Symbols)];          // continue to trade after this date
double   v_ActionGridSteps[ArraySize(Symbols)];
int      v_digits_numbers[ArraySize(Symbols)];
int      v_handle_rsi[ArraySize(Symbols)];
double   v_rsi_array[ArraySize(Symbols)][3];
string   filename;
int      spreadSheetHandler;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {

   // create the RSI handler one-by-one
   for(int symbolIndex = 0; symbolIndex < SymbolTotal; symbolIndex++) {
      Print(SymbolTotal);
      v_handle_rsi[symbolIndex]       = iRSI(Symbols[symbolIndex], PERIOD_M30, RSIPeriod[symbolIndex], PRICE_CLOSE);
      v_ActionGridSteps[symbolIndex]  = 0;
      v_backToTradeUntil[symbolIndex] = 0;
      // set the hedging current level
      v_hedgingLevels[symbolIndex][0] = 0;
      v_hedgingLevels[symbolIndex][1] = 0;
      // set the digit number
      v_digits_numbers[symbolIndex] = (int)SymbolInfoInteger(Symbols[symbolIndex], SYMBOL_DIGITS);
   }
   // filename   = "logFile_" + getCurrentTimeString() + ".csv";
   filename = "logFile_" + getCurrentTimeString() + "_" + getRandomString(5) + ".csv";
   // write file
   spreadSheetHandler = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   // write header
   FileSeek(spreadSheetHandler, 0, SEEK_END);
   FileWrite(spreadSheetHandler, "totalPositionCost", "totalPositionVolume", "totalPositionCost / totalPositionVolume", "breakEvenTP");
   return (INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
}
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   // store the RSI values
   for(int symbolIndex = 0; symbolIndex < SymbolTotal; symbolIndex++) {
      // create the temp vector to store
      double temp_vector[3];
      CopyBuffer(v_handle_rsi[symbolIndex], 0, 0, 3, temp_vector);
      // copy the element one-by-one into required array
      for(int i = 0; i < ArraySize(temp_vector); i++) {
         v_rsi_array[symbolIndex][i] = temp_vector[i];
      }
      // initial variables
      InitializeVariables(symbolIndex);
      // running strategy
      RunTradingStrategy(symbolIndex, 0);   // for buy
      RunTradingStrategy(symbolIndex, 1);   // for sell
      // stop loss for the symbol
      CheckSymbolStopLoss(symbolIndex);
   }
}
//+------------------------------------------------------------------+
//| Function to execute trades                                       |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
void InitializeVariables(int symbolIndex) {

   // never do the any trading yet
   if(v_ActionGridSteps[symbolIndex] == 0) {
      // eg: 50 * 0.00001 = 0.0005
      v_ActionGridSteps[symbolIndex] = i_gridStepPoints * SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_POINT);
      // eg: 200 * 0.00001 = 0.02
      v_breakEvenTPs[symbolIndex] = i_breakEvenTPPoints * SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_POINT);
   }
}

// run required strategy
void RunTradingStrategy(int symbolIndex, int actionType) {
   // ----- check if buy / sell position holding
   int nr_positions = CountAllPositions(Symbols[symbolIndex], actionType);
   // Open inital buy / sell position if no buy / sell positions
   if(nr_positions == 0 && TimeCurrent() >= v_backToTradeUntil[symbolIndex]) {
      // setting the magic number (setting in global)
      ulong magic = Encode3_Bytes(symbolIndex, actionType, v_hedgingLevels[symbolIndex][actionType]);
      // initial position
      OpenInitialPosition(Symbols[symbolIndex], i_initialLotSize, actionType, magic);
   }

   // ----- check if need to increase the level
   // get the magic number (current hedging level)
   ulong magic = Encode3_Bytes(symbolIndex, actionType, v_hedgingLevels[symbolIndex][actionType]);
   // first date of magic
   long lastMagic_openTime = GetFirstMagicDate(magic);
   Print("GetDifferenceDays(lastMagic_openTime): ", GetDifferenceDays(lastMagic_openTime));
   if(GetDifferenceDays(lastMagic_openTime) >= HedgingAfterDays[symbolIndex]) {

      v_hedgingLevels[symbolIndex][actionType]++;
   }
   // ----- into the market (buy / sell) in each level
   for(int level = 0; level < v_hedgingLevels[symbolIndex][actionType] + 1; level++) {
      // get the new action type
      int newActionType;
      if(level % 2 == 0) {
         newActionType = actionType;
      } else {
         newActionType = actionType == 0 ? 1 : 0;
      }
      CheckGridLevels(symbolIndex, newActionType, level);
   }
   // ----- take profit
   SetBreakEvenTP(symbolIndex, actionType);
}

// check the grid level and if good to buy, 0 = buy; 1 = sell
void CheckGridLevels(int symbolIndex, int actionType = 0, int level = 0) {
   double             lastEntryPrice;
   string             long_short_wording;
   ENUM_POSITION_TYPE positionType;
   ENUM_ORDER_TYPE    orderType;
   int                nr_positions = 0;
   // setting condition
   if(actionType == 0) {
      lastEntryPrice     = DBL_MAX;
      positionType       = POSITION_TYPE_BUY;
      orderType          = ORDER_TYPE_BUY;
      long_short_wording = "long";
   } else {
      lastEntryPrice     = DBL_MIN;
      positionType       = POSITION_TYPE_SELL;
      orderType          = ORDER_TYPE_SELL;
      long_short_wording = "short";
   }

   // calculate how many level to be concat
   ulong tickets[];
   // getting require magic
   ulong magic = Encode3_Bytes(symbolIndex, actionType, level);
   GetTickets_ByMagic(tickets, magic);
   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong ticket = tickets[i];
      // select the position and with the same symbol
      if(PositionSelectByTicket(ticket)) {
         // get the position entry price
         double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         if(actionType == 0 && entryPrice < lastEntryPrice) {
            lastEntryPrice = entryPrice;
            // level of positions
            nr_positions++;
         } else if(actionType == 1 && entryPrice > lastEntryPrice) {
            lastEntryPrice = entryPrice;
            // level of positions
            nr_positions++;
         }
      }
   }

   if(nr_positions > 0) {
      double nextGridPrice;
      double currentPrice;
      // setting the magic number (setting in global)
      trade.SetExpertMagicNumber(Encode3_Bytes(symbolIndex, actionType, level));
      if(positionType == 0) {
         // calculate the next grid buying price
         nextGridPrice = NormalizeDouble(lastEntryPrice - (v_ActionGridSteps[symbolIndex]) * MathPow(i_gridStepMultiplier, nr_positions), v_digits_numbers[symbolIndex]);
         // get normalized ask price
         currentPrice = NormalizeDouble(SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_ASK), v_digits_numbers[symbolIndex]);
      } else {
         // calculate the next grid selling price
         nextGridPrice = NormalizeDouble(lastEntryPrice + (v_ActionGridSteps[symbolIndex]) * MathPow(i_gridStepMultiplier, nr_positions), v_digits_numbers[symbolIndex]);
         // get normalized bid price
         currentPrice = NormalizeDouble(SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_BID), v_digits_numbers[symbolIndex]);
      }
      // int ptDiff;
      // if(actionType == 0) {
      //    ptDiff = PointsBetween(nextGridPrice, SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_ASK), Symbols[symbolIndex]);
      //    Print("nextGridPrice, SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_ASK), SymbolInfoDouble(sym, SYMBOL_POINT), ptDiff: ", nextGridPrice, ", ", SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_BID), ", ", SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_POINT), ", ", ptDiff);
      // } else {
      //    ptDiff = PointsBetween(nextGridPrice, SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_BID), Symbols[symbolIndex]);
      //    Print("nextGridPrice, SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_ASK), SymbolInfoDouble(sym, SYMBOL_POINT), ptDiff: ", nextGridPrice, ", ", SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_ASK), ", ", SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_POINT), ", ", ptDiff);
      // }

      if((actionType == 0 && currentPrice <= nextGridPrice) || (actionType == 1 && currentPrice >= nextGridPrice)) {
         // new lot size
         double newLotSize = i_initialLotSize * MathPow(HedgingMultiplier[symbolIndex], v_hedgingLevels[symbolIndex][actionType]) * MathPow(i_lotMultiplier, nr_positions);
         newLotSize        = NormalizeLot(Symbols[symbolIndex], newLotSize);

         // check required margin
         double requiredMargin = accountInfo.MarginCheck(Symbols[symbolIndex], orderType, newLotSize, currentPrice);
         if(requiredMargin > accountInfo.FreeMargin()) {
            Print("Not enough margin for grid ", long_short_wording, "! Required Margin / Free Margin: ", DoubleToString(requiredMargin), " / ", DoubleToString(accountInfo.FreeMargin()));
            CloseAllPositions(Symbols[symbolIndex], 0);
            datetime currDatetime           = TimeCurrent();
            v_backToTradeUntil[symbolIndex] = AddDate(currDatetime, i_sleepDays);
            Print("==============> Restarted ", TimeToString(currDatetime), " until ", TimeToString(v_backToTradeUntil[symbolIndex]), " <==============");
            return;
         }

         // take action
         if(actionType == 0) {
            if(!trade.Buy(newLotSize, Symbols[symbolIndex], currentPrice, 0, 0, "Grid Buy level - " + IntegerToString(level))) {
               Print("Grid buy error: ", GetLastError());
            }
         } else {
            if(!trade.Sell(newLotSize, Symbols[symbolIndex], currentPrice, 0, 0, "Grid Sell level - " + IntegerToString(level))) {
               Print("Grid sell error: ", GetLastError());
            }
         }
      }
   }
}

// calculate the break even point account with profit token
void SetBreakEvenTP(int symbolIndex, int actionType = 0) {
   ENUM_SYMBOL_INFO_DOUBLE symbol_bidask;
   if(actionType == 0) {
      symbol_bidask = SYMBOL_BID;
   } else {
      symbol_bidask = SYMBOL_ASK;
   }
   double totalPositionVolume = 0;
   double totalPositionCost   = 0;

   // calculate the buy cost
   ulong requiredTickets[];
   GetAllTickets(requiredTickets, Symbols[symbolIndex], actionType);
   for(int i = 0; i < ArraySize(requiredTickets); i++) {
      ulong ticket = requiredTickets[i];
      // select the position and with the same symbol
      if(PositionSelectByTicket(ticket)) {
         double volume        = PositionGetDouble(POSITION_VOLUME);
         double entryPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
         totalPositionVolume += volume;
         totalPositionCost   += entryPrice * volume;
      }
   }
   double breakEvenPrice;
   if(totalPositionVolume > 0) {
      double positionCost = totalPositionCost / totalPositionVolume;
      if(actionType == 0) {
         breakEvenPrice = NormalizeDouble(positionCost + v_breakEvenTPs[symbolIndex], v_digits_numbers[symbolIndex]);
      } else {
         breakEvenPrice = NormalizeDouble(positionCost - v_breakEvenTPs[symbolIndex], v_digits_numbers[symbolIndex]);
      }
      double current_bidAsk = NormalizeDouble(SymbolInfoDouble(Symbols[symbolIndex], symbol_bidask), v_digits_numbers[symbolIndex]);

      if((actionType == 0 && current_bidAsk >= breakEvenPrice) ||
         (actionType == 1 && current_bidAsk <= breakEvenPrice)) {
         Print("-------------------------------");
         Print("totalPositionCost: ", totalPositionCost, " totalPositionVolume: ", totalPositionVolume, " (totalPositionCost / totalPositionVolume): ", (totalPositionCost / totalPositionVolume), " breakEvenTP: ", v_breakEvenTPs[symbolIndex]);
         // string nowStr = TimeToString(TimeCurrent());
         // string filename = "logFile" + "_" + nowStr + ".csv";

         Print("TERMINAL_COMMONDATA_PATH: ", TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "/" + filename);
         FileSeek(spreadSheetHandler, 0, SEEK_END);
         FileWrite(spreadSheetHandler, DoubleToString(totalPositionCost), DoubleToString(totalPositionVolume), DoubleToString((totalPositionCost / totalPositionVolume)), DoubleToString(v_breakEvenTPs[symbolIndex]));

         // WriteCsv(filename, cols, values);
         CloseAllPositions(Symbols[symbolIndex], actionType);
         Print("-------------------------------");
      }
   }
}

// check if the balance excced the stop loss
void CheckSymbolStopLoss(int symbolIndex) {
   double balance = GetSymbolBalance(Symbols[symbolIndex]);
   // set to 0 means it is no stop loss
   if(i_symbolStopLossMoney != 0 && balance * -1 >= i_symbolStopLossMoney) {
      // clase all the position for this symbol
      CloseAllPositions(Symbols[symbolIndex], -1);
      datetime currDatetime = TimeCurrent();
      // stop the trading until below the date passed
      v_backToTradeUntil[symbolIndex] = AddDate(currDatetime, i_sleepDays);
      Print("==============> Stopped Symbol Loss at ", TimeToString(currDatetime), " - ", balance * -1, " until ", TimeToString(v_backToTradeUntil[symbolIndex]), "<==============");
   }
}

double lotExp(int nr_buy_positions) {
   return 0.1 * exp(nr_buy_positions / 25) + 1;
}

// getting the first position date
long GetFirstMagicDate(ulong magic) {
   ulong tickets[];
   long  openTime = INT_MAX;
   GetTickets_ByMagic(tickets, magic);
   for(int i = 0; i < ArraySize(tickets); i++) {
      if(PositionSelectByTicket(tickets[i])) {
         if(PositionGetInteger(POSITION_TIME) <= openTime) {
            openTime = PositionGetInteger(POSITION_TIME);
         }
      }
   }
   return openTime;
}

// getting the difference in days
double GetDifferenceDays(long firstDate, long lastDate = NULL) {
   if(!lastDate) {
      lastDate = TimeCurrent();
   }
   long   timeDifferenceSeconds = (long)lastDate - (long)firstDate;
   double daysDifference        = (double)timeDifferenceSeconds / 86400.0;
   return daysDifference;
}
