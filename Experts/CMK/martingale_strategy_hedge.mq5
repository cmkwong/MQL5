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
int    HedgingAfterDays[]  = {20, 10, 10, 10};            // condition of hedging: days after first opened position being hold
double HedgingMultiplier[] = {1.1, 1.1, 1.1, 1.1};   // The hedging mechanism will operate at this multiple in order to accelerate the completion of a position that has been maintained for a long time.
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
   // ----- check if init buy / sell
   ulong nr_tickets[];
   GetConditionalTickets(nr_tickets, symbolIndex, main_actionType, 0);   // start for 0
   // Open inital buy / sell position if no buy / sell positions
   if(ArraySize(nr_tickets) == 0 && TimeCurrent() >= v_backToTradeUntil[symbolIndex]) {
      // setting the magic number (setting in global)
      ulong magic = Encode3_Bytes(symbolIndex, main_actionType, 0);
      // initial position
      string comment = "Initial " + actionType_word + " level - " + IntegerToString(0);
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
      // Print("GetDifferenceDays(last_openTime): ", GetDifferenceDays(last_openTime), " - ", TimeToString(t, TIME_DATE | TIME_SECONDS));
      // ----- level-up
      v_hedgingLevels[symbolIndex][main_actionType]++;
      int sub_actionType = GetActionType_byLevel(symbolIndex, main_actionType, v_hedgingLevels[symbolIndex][main_actionType], true);
      // initial level position
      ulong  magic   = Encode3_Bytes(symbolIndex, main_actionType, v_hedgingLevels[symbolIndex][main_actionType]);
      string comment = "Initial " + actionType_word + " level - " + IntegerToString(v_hedgingLevels[symbolIndex][main_actionType]);
      double initLot = i_initialLotSize * MathPow(HedgingMultiplier[symbolIndex], v_hedgingLevels[symbolIndex][main_actionType]);
      initLot        = NormalizeLot(Symbols[symbolIndex], initLot);
      OpenInitialPosition(Symbols[symbolIndex], initLot, sub_actionType, magic, comment);
   }

   // ----- into the market (buy / sell) in each level
   int   balanacePip = 0;
   ulong maxTickets[];
   GetConditionalTickets(maxTickets, symbolIndex, main_actionType);
   int maxLevel = GetMaxLevel_byTickets(maxTickets);
   for(int level = 0; level < maxLevel + 1; level++) {
      // ----- get the required ticket based on level
      ulong requiredTickets[];
      GetConditionalTickets(requiredTickets, symbolIndex, main_actionType, level);
      if(ArraySize(requiredTickets) == 0) {
         continue;
      }
      // ----- check the grid level
      if(!PositionSelectByTicket(requiredTickets[0])) {   // first ticket is the direction
         continue;
      }
      int sub_actionType = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 0 : 1;
      CheckGridLevels(symbolIndex, main_actionType, level, sub_actionType);
      // ----- take profit by level
      bool targetMeet = false;
      int  earnedPip  = CheckBreakEvenTP(targetMeet, requiredTickets, symbolIndex);   // TODO: generalize into both direction: buy and short
      if(targetMeet) {
         v_accumEarnedPips[symbolIndex][main_actionType] = v_accumEarnedPips[symbolIndex][main_actionType] + earnedPip;
         if(level > 0) {
            v_hedgingLevels[symbolIndex][main_actionType]--;
         }
      } else {
         balanacePip += earnedPip;
      }
   }
   bool  targetMeet = false;
   ulong requiredTickets[];
   GetConditionalTickets(requiredTickets, symbolIndex, main_actionType);
   int earnedPip = CheckBreakEvenTP(targetMeet, requiredTickets, symbolIndex, true);
   if(targetMeet == true) {
      v_hedgingLevels[symbolIndex][main_actionType]   = 0;   // reset to level 0
      v_accumEarnedPips[symbolIndex][main_actionType] = 0;
   }
   // ----- check overall accumPips meet target, if so, close all the positions
   // ulong requiredTickets[];
   // GetConditionalTickets(requiredTickets, symbolIndex, main_actionType, level);
   // int earnedPip = CheckBreakEvenTP(targetMeet, requiredTickets, symbolIndex, sub_actionType);
   // if((balanacePip + v_accumEarnedPips[symbolIndex][main_actionType]) >= BreakEvenTPPips[symbolIndex]) {
   //    ulong nr_tickets[];
   //    GetConditionalTickets(nr_tickets, symbolIndex, main_actionType);
   //    if(ArraySize(nr_tickets) > 0) {
   //       CloseAllTickets(nr_tickets);
   //       v_hedgingLevels[symbolIndex][main_actionType]   = 0;   // reset to level 0
   //       v_accumEarnedPips[symbolIndex][main_actionType] = 0;
   //    }
   // }
}

// check the grid level and if good to buy, 0 = buy; 1 = sell
void CheckGridLevels(int symbolIndex, int main_actionType, int level, int sub_actionType) {
   // int                sub_actionType = GetActionType_byLevel(symbolIndex, main_actionType, level);
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
   // the init lot for the level
   double initLevelLot = DBL_MAX;

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
         double entryPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
         double entryVolume = PositionGetDouble(POSITION_VOLUME);
         if(sub_actionType == 0 && entryPrice < lastEntryPrice) {
            lastEntryPrice = entryPrice;
            // level of positions
            nr_positions++;
         } else if(sub_actionType == 1 && entryPrice > lastEntryPrice) {
            lastEntryPrice = entryPrice;
            // level of positions
            nr_positions++;
         }
         if(entryVolume <= initLevelLot) {
            initLevelLot = entryVolume;
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
         double newLotSize = initLevelLot * MathPow(i_lotMultiplier, nr_positions);
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
int CheckBreakEvenTP(bool &targetMeet, ulong &tickets[], int symbolIndex, bool _flag = false) {

   // ENUM_SYMBOL_INFO_DOUBLE symbol_bidask;
   ulong buy_tickets[];
   ulong sell_tickets[];
   // ----- concat the required buy & sell ticket
   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong ticket = tickets[i];
      if(!PositionSelectByTicket(ticket)) {
         continue;
      }
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
         int n = ArraySize(buy_tickets);
         ArrayResize(buy_tickets, n + 1);
         buy_tickets[n] = ticket;
      } else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
         int n = ArraySize(sell_tickets);
         ArrayResize(sell_tickets, n + 1);
         sell_tickets[n] = ticket;
      }
   }

   // ----- calculate the required breakEvenPrice for buy and sell
   ulong  required_tickets[];
   double buy_breakEvenPrice  = 0.0;
   double sell_breakEvenPrice = 0.0;
   double buy_positionCost    = 0.0;
   double sell_positionCost   = 0.0;
   double current_bid         = 0.0;
   double current_ask         = 0.0;
   double totalPositionVolume = 0.0;
   int    ACTION_TYPES[]      = {0, 1};
   for(int ticket_actionType = 0; ticket_actionType < ArraySize(ACTION_TYPES); ticket_actionType++) {
      if(ticket_actionType == 0) {
         ArrayCopy(required_tickets, buy_tickets);
      } else {
         ArrayCopy(required_tickets, sell_tickets);
      }

      int    targetPip    = (int)MathCeil(BreakEvenTPPips[symbolIndex]);
      double breakEvenTPs = targetPip * SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_POINT);   // eg: 200 * 0.00001 = 0.02
      if(ArraySize(buy_tickets) > 0 && ticket_actionType == 0) {
         // calculate the position cost
         buy_positionCost   = GetPositionCost(required_tickets, totalPositionVolume, ticket_actionType);
         buy_breakEvenPrice = NormalizeDouble(buy_positionCost + breakEvenTPs, v_digits_numbers[symbolIndex]);
         current_bid        = NormalizeDouble(SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_BID), v_digits_numbers[symbolIndex]);
      }
      if(ArraySize(sell_tickets) > 0 && ticket_actionType == 1) {
         // calculate the position cost
         sell_positionCost   = GetPositionCost(required_tickets, totalPositionVolume, ticket_actionType);
         sell_breakEvenPrice = NormalizeDouble(sell_positionCost - breakEvenTPs, v_digits_numbers[symbolIndex]);
         current_ask         = NormalizeDouble(SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_ASK), v_digits_numbers[symbolIndex]);
      }
   }

   // ----- checkout if overall profit
   if(totalPositionVolume > 0) {

      if(current_bid - buy_breakEvenPrice + (sell_breakEvenPrice - current_ask) >= 0.0) {
         Print("-------------------------------");
         Print(" totalPositionVolume: ", totalPositionVolume);
         Print("TERMINAL_COMMONDATA_PATH: ", TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "/" + filename);
         FileSeek(spreadSheetHandler, 0, SEEK_END);
         FileWrite(spreadSheetHandler, DoubleToString(totalPositionVolume));

         // WriteCsv(filename, cols, values);
         if(_flag == true) {
            Print("Stop");
         }
         CloseAllTickets(buy_tickets);
         CloseAllTickets(sell_tickets);
         targetMeet = true;
         Print("-------------------------------");
      }
   }
   // calculate the point difference
   int ptDiff = 0.0;
   if(ArraySize(buy_tickets) > 0) {
      ptDiff += PointsDiff(current_bid, buy_positionCost, Symbols[symbolIndex]);
   }
   if(ArraySize(sell_tickets) > 0) {
      ptDiff += PointsDiff(sell_positionCost, current_ask, Symbols[symbolIndex]);
   }
   return ptDiff;
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

// getting the max level
int GetMaxLevel_byTickets(ulong &tickets[]) {
   int maxLevel = 0;
   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong tk = tickets[i];
      if(!PositionSelectByTicket(tk))
         continue;
      int  _symbolIndex;
      int  _main_actionType;
      int  _level;
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      Decode3_Bytes((int)posMagic, _symbolIndex, _main_actionType, _level);
      if(_level > maxLevel) {
         maxLevel = _level;
      }
   }
   return maxLevel;
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
int GetActionType_byLevel(int symbolIndex, int main_actionType, int level, bool acctLossProb = false) {
   // if %2 residual value, used original main_actionType
   if(acctLossProb) {
      return SelectWithProbability(symbolIndex);
   } else {
      int sub_actionType;
      if(level % 2 == 0) {
         sub_actionType = main_actionType;
      } else {
         sub_actionType = main_actionType == 0 ? 1 : 0;
      }
      return sub_actionType;
   }
}

// Return 0 or 1
// pZero: probability to select 0 (0.0 ~ 1.0), e.g., 0.1 -> 10% select 0, 90% select 1
// seed:  optional random seed; if 0 then initialize with current time
int SelectWithProbability(int symbolIndex, uint seed = 0) {

   // ----- calculate the probablity
   ulong  tickets[];
   double totalLoss = 0.0;
   double buyLoss   = 0.0;
   double sellLoss  = 0.0;
   GetConditionalTickets(tickets, symbolIndex);
   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong tk = tickets[i];
      if(!PositionSelectByTicket(tk)) {
         continue;
      }
      double loss       = PositionGetDouble(POSITION_PROFIT);
      double actionType = PositionGetInteger(POSITION_TYPE);
      if(loss < 0) {
         totalLoss += loss;
         if(actionType == POSITION_TYPE_BUY) {
            buyLoss += loss;
         }
         if(actionType == POSITION_TYPE_SELL) {
            sellLoss += loss;
         }
      }
   }

   // less sell loss -> more probablility to select sell action type
   double pZero = sellLoss / totalLoss;

   // Initialize RNG seed (only once or when a seed is provided)
   static bool seeded = false;
   if(seed != 0) {
      MathSrand((int)seed);
      seeded = true;
   } else if(!seeded) {
      MathSrand((int)TimeLocal());
      seeded = true;
   }

   // Get a random number in [0,1)
   double r = (double)MathRand() / 32767.0;   // MathRand() returns 0..32767

   // Return 0 if r < pZero, otherwise return 1
   return (r < pZero) ? 0 : 1;
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