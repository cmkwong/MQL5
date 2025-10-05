//+------------------------------------------------------------------+
//|                                                  MartingaleMA.mq5|
//|                                         Copyright 2025, YourName |
//|                    Added operation for offset the idle positions |
//+------------------------------------------------------------------+

#include <CMK/Array.mqh>
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
input double i_gridStepMultiplier  = 1.25;
input int    i_symbolStopLossMoney = 2500;   // set to 0 means it is no stop loss
input int    i_sleepDays           = 120;    // after stop loss / no margin, the currency will be resume trading after this day passed

// strategy constant
string Symbols[]           = {"AUDNZD"};   // , "AUDUSD", "GBPUSD", "EURGBP"
int    RSIPeriod[]         = {14, 14, 14, 14};
int    HedgingAfterDays[]  = {5, 10, 10, 10};            // condition of hedging: days after first opened position being hold
double HedgingMultiplier[] = {1.05, 1.05, 1.05, 1.05};   // The hedging mechanism will operate at this multiple in order to accelerate the completion of a position that has been maintained for a long time.
int    GridStepPoints[]    = {50, 50, 50, 50};
int    BreakEvenTPPips[]   = {200, 200, 200, 200};
int    SymbolTotal         = ArraySize(Symbols);

// strategy variables
int      v_hedgingLevels[ArraySize(Symbols)][2];      // storate of the hedging level, 0 means the basic
int      v_accumEarnedPips[ArraySize(Symbols)][2];    // accumulative points being earning
datetime v_positionOpenDate[ArraySize(Symbols)][2];   // the opening date that position begin
datetime v_backToTradeUntil[ArraySize(Symbols)];      // continue to trade after this date
double   v_actionGridSteps[ArraySize(Symbols)];
int      v_digits_numbers[ArraySize(Symbols)];
// indicator buffer
int    v_handle_rsi[ArraySize(Symbols)];
double v_rsi_array[ArraySize(Symbols)][3];
string filename;
int    spreadSheetHandler;
// long     v_strategyMagicNumbers[ArraySize(Symbols)][2];   // magic number for first strategy

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {

   // create the RSI handler one-by-one
   for(int symbolIndex = 0; symbolIndex < SymbolTotal; symbolIndex++) {
      Print(SymbolTotal);
      v_handle_rsi[symbolIndex]       = iRSI(Symbols[symbolIndex], PERIOD_M30, RSIPeriod[symbolIndex], PRICE_CLOSE);
      v_actionGridSteps[symbolIndex]  = 0;
      v_backToTradeUntil[symbolIndex] = 0;
      // set the hedging current level
      v_hedgingLevels[symbolIndex][0] = 0;   // start with level 0
      v_hedgingLevels[symbolIndex][1] = 0;   // start with level 0
      // set the profit pips
      v_accumEarnedPips[symbolIndex][0] = 0;
      v_accumEarnedPips[symbolIndex][1] = 0;
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
   if(v_actionGridSteps[symbolIndex] == 0) {
      // eg: 50 * 0.00001 = 0.0005
      v_actionGridSteps[symbolIndex] = GridStepPoints[symbolIndex] * SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_POINT);
   }
}

// run required strategy
void RunTradingStrategy(int symbolIndex, int main_actionType) {
   string actionType_word = main_actionType == 0 ? "Buy" : "Sell";
   // ----- check if buy / sell position holding
   ulong nr_tickets[];
   GetConditionalTickets(nr_tickets, symbolIndex, main_actionType);
   // Open inital buy / sell position if no buy / sell positions
   if(ArraySize(nr_tickets) == 0 && TimeCurrent() >= v_backToTradeUntil[symbolIndex]) {
      // setting the magic number (setting in global)
      ulong magic = Encode3_Bytes(symbolIndex, main_actionType, v_hedgingLevels[symbolIndex][main_actionType]);
      // initial position
      string comment = "Initial " + actionType_word + " level - " + IntegerToString(v_hedgingLevels[symbolIndex][main_actionType]);
      OpenInitialPosition(Symbols[symbolIndex], i_initialLotSize, main_actionType, magic, comment);
   }

   // ----- check if need to increase the level
   // get the magic number (current hedging level)
   int   current_level = v_hedgingLevels[symbolIndex][main_actionType];
   ulong magic         = Encode3_Bytes(symbolIndex, main_actionType, current_level);
   // first date of holding position
   long   last_openTime = GetFirstMagicDate(symbolIndex, main_actionType, 0);
   double diffDays      = GetDifferenceDays(last_openTime);
   if(GetDifferenceDays(last_openTime) >= HedgingAfterDays[symbolIndex] * (current_level + 1)) {
      datetime t = (datetime)(last_openTime / 1000);

      Print("GetDifferenceDays(last_openTime): ", GetDifferenceDays(last_openTime), " - ", TimeToString(t, TIME_DATE | TIME_SECONDS));
      // ----- level-up
      v_hedgingLevels[symbolIndex][main_actionType]++;
      int sub_actionType = GetActionType_byLevel(main_actionType, v_hedgingLevels[symbolIndex][main_actionType]);
      // initial level position
      ulong  magic   = Encode3_Bytes(symbolIndex, main_actionType, v_hedgingLevels[symbolIndex][main_actionType]);
      string comment = "Initial " + actionType_word + " level - " + IntegerToString(v_hedgingLevels[symbolIndex][main_actionType]);
      OpenInitialPosition(Symbols[symbolIndex], i_initialLotSize * HedgingMultiplier[symbolIndex], sub_actionType, magic, comment);
   }

   // ----- into the market (buy / sell) in each level
   int balanacePip = 0;
   for(int level = 0; level < v_hedgingLevels[symbolIndex][main_actionType] + 1; level++) {
      bool closed = false;
      // check the grid level
      CheckGridLevels(symbolIndex, main_actionType, level);
      // ----- take profit by level
      int earnedPip = SetBreakEvenTP(symbolIndex, main_actionType, level, closed);
      if(closed) {
         v_accumEarnedPips[symbolIndex][main_actionType] = v_accumEarnedPips[symbolIndex][main_actionType] + earnedPip;
      } else {
         balanacePip += earnedPip;
      }
   }

   // ----- check overall accumPips meet target, if so, close all the positions

   if((balanacePip + v_accumEarnedPips[symbolIndex][main_actionType]) >= BreakEvenTPPips[symbolIndex]) {
      ulong nr_tickets[];
      GetConditionalTickets(nr_tickets, symbolIndex, main_actionType);
      if(ArraySize(nr_tickets) > 0) {
         CloseAllTickets(nr_tickets);
         v_hedgingLevels[symbolIndex][main_actionType]   = 0;   // reset to level 0
         v_accumEarnedPips[symbolIndex][main_actionType] = 0;
      }
   }
}

// check the grid level and if good to buy, 0 = buy; 1 = sell
void CheckGridLevels(int symbolIndex, int main_actionType, int level) {
   int                sub_actionType = GetActionType_byLevel(main_actionType, level);
   double             lastEntryPrice;
   string             long_short_wording;
   ENUM_POSITION_TYPE positionType;
   ENUM_ORDER_TYPE    orderType;
   int                nr_positions = 0;
   // setting condition
   if(sub_actionType == 0) {
      lastEntryPrice     = DBL_MAX;
      positionType       = POSITION_TYPE_BUY;
      orderType          = ORDER_TYPE_BUY;
      long_short_wording = "Buy";
   } else {
      lastEntryPrice     = DBL_MIN;
      positionType       = POSITION_TYPE_SELL;
      orderType          = ORDER_TYPE_SELL;
      long_short_wording = "Sell";
   }

   // calculate how many level to be concat
   ulong tickets[];
   // getting require magic
   ulong magic = Encode3_Bytes(symbolIndex, main_actionType, level);
   GetTickets_ByMagic(tickets, magic);
   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong ticket = tickets[i];
      // select the position and with the same symbol
      if(PositionSelectByTicket(ticket)) {
         // get the position entry price
         double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         if(sub_actionType == 0 && entryPrice < lastEntryPrice) {
            lastEntryPrice = entryPrice;
            // level of positions
            nr_positions++;
         } else if(sub_actionType == 1 && entryPrice > lastEntryPrice) {
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
      trade.SetExpertMagicNumber(Encode3_Bytes(symbolIndex, main_actionType, level));
      if(sub_actionType == 0) {
         // calculate the next grid buying price
         nextGridPrice = NormalizeDouble(lastEntryPrice - (v_actionGridSteps[symbolIndex]) * MathPow(i_gridStepMultiplier, nr_positions), v_digits_numbers[symbolIndex]);
         // get normalized ask price
         currentPrice = NormalizeDouble(SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_ASK), v_digits_numbers[symbolIndex]);
      } else {
         // calculate the next grid selling price
         nextGridPrice = NormalizeDouble(lastEntryPrice + (v_actionGridSteps[symbolIndex]) * MathPow(i_gridStepMultiplier, nr_positions), v_digits_numbers[symbolIndex]);
         // get normalized bid price
         currentPrice = NormalizeDouble(SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_BID), v_digits_numbers[symbolIndex]);
      }

      if((sub_actionType == 0 && currentPrice <= nextGridPrice) || (sub_actionType == 1 && currentPrice >= nextGridPrice)) {
         // new lot size
         // increase the initial lot based on the level
         double newLotSize = i_initialLotSize * MathPow(HedgingMultiplier[symbolIndex], v_hedgingLevels[symbolIndex][sub_actionType]) * MathPow(i_lotMultiplier, nr_positions);
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
         string master_actionType_word = main_actionType == 0 ? "Buy" : "Sell";

         if(sub_actionType == 0) {
            if(!trade.Buy(newLotSize, Symbols[symbolIndex], currentPrice, 0, 0, "Grid " + master_actionType_word + " level - " + IntegerToString(level))) {
               Print("Grid buy error: ", GetLastError());
            }
         } else {
            if(!trade.Sell(newLotSize, Symbols[symbolIndex], currentPrice, 0, 0, "Grid " + master_actionType_word + " level - " + IntegerToString(level))) {
               Print("Grid sell error: ", GetLastError());
            }
         }
      }
   }
}

// calculate the break even point account with profit token
int SetBreakEvenTP(int symbolIndex, int main_actionType, int level, bool &closed) {

   // ----- calculate the buy cost
   // getting the magic number
   // int    current_level = v_hedgingLevels[symbolIndex][main_actionType];
   int                     sub_actionType = GetActionType_byLevel(main_actionType, level);
   ulong                   magic          = Encode3_Bytes(symbolIndex, main_actionType, level);
   ENUM_SYMBOL_INFO_DOUBLE symbol_bidask;
   ulong                   requiredTickets[];
   double                  positionCost = 0.0;
   double                  breakEvenPrice;
   double                  breakEvenTPs;
   double                  current_bidAsk;
   int                     targetPip = 0;
   if(sub_actionType == 0) {
      symbol_bidask = SYMBOL_BID;
   } else {
      symbol_bidask = SYMBOL_ASK;
   }
   GetTickets_ByMagic(requiredTickets, magic);
   double totalPositionVolume = GetPositionCost(requiredTickets, positionCost);
   if(totalPositionVolume > 0) {
      targetPip    = (int)MathCeil(BreakEvenTPPips[symbolIndex] * MathPow(HedgingMultiplier[symbolIndex], level));
      breakEvenTPs = targetPip * SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_POINT);   // eg: 200 * 0.00001 = 0.02
      if(sub_actionType == 0) {
         breakEvenPrice = NormalizeDouble(positionCost + breakEvenTPs, v_digits_numbers[symbolIndex]);
      } else {
         breakEvenPrice = NormalizeDouble(positionCost - breakEvenTPs, v_digits_numbers[symbolIndex]);
      }
      current_bidAsk = NormalizeDouble(SymbolInfoDouble(Symbols[symbolIndex], symbol_bidask), v_digits_numbers[symbolIndex]);

      if((sub_actionType == 0 && current_bidAsk >= breakEvenPrice) ||
         (sub_actionType == 1 && current_bidAsk <= breakEvenPrice)) {
         Print("-------------------------------");
         Print(" (totalPositionCost / totalPositionVolume): ", positionCost);

         Print("TERMINAL_COMMONDATA_PATH: ", TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "/" + filename);
         FileSeek(spreadSheetHandler, 0, SEEK_END);
         FileWrite(spreadSheetHandler, DoubleToString(positionCost));

         // WriteCsv(filename, cols, values);
         CloseAllTickets(requiredTickets);
         closed = true;
         Print("-------------------------------");
      }
      // calculate the point difference
      int ptDiff;
      if(sub_actionType == 0) {
         ptDiff = PointsDiff(current_bidAsk, positionCost, Symbols[symbolIndex]);
      } else {
         ptDiff = PointsDiff(positionCost, current_bidAsk, Symbols[symbolIndex]);
      }
      return ptDiff;
   }
   return 0;
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
long GetFirstMagicDate(int symbolIndex, int main_actionType, int level) {
   ulong tickets[];
   GetConditionalTickets(tickets, symbolIndex, main_actionType, level);
   long openTime = INT_MAX;
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

// get the new action type by the level
int GetActionType_byLevel(int main_actionType, int level) {
   // if %2 residual value, used original main_actionType
   int sub_actionType;
   if(level % 2 == 0) {
      sub_actionType = main_actionType;
   } else {
      sub_actionType = main_actionType == 0 ? 1 : 0;
   }
   return sub_actionType;
}

// get required condition by below arguments
void GetConditionalTickets(ulong &tickets[], int symbolIndex = -1, int main_actionType = -1, int level = -1, int sub_actionType = -1) {
   // reset the tickets array
   ArrayResize(tickets, 0);

   int totalPos = PositionsTotal();
   for(int i = 0; i < totalPos; i++) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(!PositionSelectByTicket(tk))
         continue;
      int  _symbolIndex;
      int  _main_actionType;
      int  _level;
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      Decode3_Bytes((int)posMagic, _symbolIndex, _main_actionType, _level);
      if(symbolIndex != -1) {
         if(_symbolIndex != symbolIndex)
            continue;
      }
      if(main_actionType != -1) {
         if(_main_actionType != main_actionType)
            continue;
      }
      if(level != -1) {
         if(_level != level)
            continue;
      }
      if(sub_actionType != -1) {
         if((sub_actionType == 0 && PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) ||
            (sub_actionType == 1 && PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)) {
            continue;
         }
      }
      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      tickets[n] = tk;
   }
}