//+------------------------------------------------------------------+
//|                                                  MartingaleMA.mq5|
//|                                         Copyright 2025, YourName |
//|                    Added operation for offset the idle positions |
//+------------------------------------------------------------------+

#include <CMK/Array.mqh>
#include <CMK/Files.mqh>
#include <CMK/Helper.mqh>
#include <CMK/Num.mqh>
#include <CMK/String.mqh>
#include <CMK/Time.mqh>
#include <Trade/AccountInfo.mqh>
#include <Trade/Trade.mqh>
CTrade              trade;
static CAccountInfo accountInfo;

// grid parameters
double i_initialLotSize      = 0.01;
double i_lotMultiplier       = 1.3;
double i_gridStepMultiplier  = 1.5;
int    i_symbolStopLossMoney = 2500;   // set to 0 means it is no stop loss
int    i_sleepDays           = 120;    // after stop loss / no margin, the currency will be resume trading after this day passed
int    i_actionSelectMethod  = 0;      // 0 = account loss; 1 = %2; 3 = opposite

// strategy constant
string Symbols[]           = {"AUDNZD", "AUDUSD", "GBPUSD", "EURGBP"};   // , "AUDUSD", "GBPUSD", "EURGBP"
int    RSIPeriod[]         = {14, 14, 14, 14};
int    HedgingAfterDays[]  = {10, 10, 10, 10};       // condition of hedging: days after first opened position being hold
double HedgingMultiplier[] = {1.5, 1.5, 1.5, 1.5};   // The hedging mechanism will operate at this multiple in order to accelerate the completion of a position that has been maintained for a long time.
int    GridStepPoints[]    = {50, 50, 50, 50};
int    BreakEvenTPPips[]   = {50, 50, 50, 50};
double accumEarnedTarget[] = {100, 100, 100, 100};   // account for overall balance meet, if done, that will close all tickets
int    SymbolTotal         = ArraySize(Symbols);

// strategy variables
double   v_accumEarned[ArraySize(Symbols)][2];        // accumulative points being earning
datetime v_positionOpenDate[ArraySize(Symbols)][2];   // the opening date that position begin
datetime v_backToTradeUntil[ArraySize(Symbols)];      // continue to trade after this date
double   v_actionGridSteps[ArraySize(Symbols)];
double   v_breakEvenTPs[ArraySize(Symbols)];
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
string tradeLogFilename;
int    tradeLogHandler;
int    OnInit() {
   // create the RSI handler one-by-one
   for(int symbolIndex = 0; symbolIndex < SymbolTotal; symbolIndex++) {
      v_handle_rsi[symbolIndex]       = iRSI(Symbols[symbolIndex], PERIOD_M30, RSIPeriod[symbolIndex], PRICE_CLOSE);
      v_actionGridSteps[symbolIndex]  = 0;
      v_backToTradeUntil[symbolIndex] = 0;
      // set the profit pips
      v_accumEarned[symbolIndex][0] = 0;
      v_accumEarned[symbolIndex][1] = 0;
      // set the digit number
      v_digits_numbers[symbolIndex] = (int)SymbolInfoInteger(Symbols[symbolIndex], SYMBOL_DIGITS);
   }

   // Create timestamp and random string to avoid conflicts
   string timeStr = getCurrentTimeString();
   string randStr = getRandomString(5);

   // Create CSV file for position closures
   filename           = "martingale_closure_log_" + timeStr + "_" + randStr + ".csv";
   spreadSheetHandler = OpenCSVFile(filename);

   // Write header row for position closures
   if(spreadSheetHandler != INVALID_HANDLE) {
      string columns[] = {"timestamp", "symbol", "totalPositionVolume", "buyPositionCost", "sellPositionCost",
                             "buyBreakEvenPrice", "sellBreakEvenPrice", "currentBid", "currentAsk", "profit"};
      string values[]  = {"", "", "", "", "", "", "", "", "", ""};
      WriteCSV(spreadSheetHandler, columns, values, true);
   }

   // Create CSV file for trade executions
   tradeLogFilename = "martingale_trade_log_" + timeStr + "_" + randStr + ".csv";
   tradeLogHandler  = OpenCSVFile(tradeLogFilename);

   // Write header row for trade executions
   if(tradeLogHandler != INVALID_HANDLE) {
      string columns[] = {"timestamp", "symbol", "action", "lotSize", "price", "level", "comment"};
      string values[]  = {"", "", "", "", "", "", ""};
      WriteCSV(tradeLogHandler, columns, values, true);
   }

   return (INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   // Close file handles if open
   CloseCSVFile(spreadSheetHandler);
   CloseCSVFile(tradeLogHandler);
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
      v_actionGridSteps[symbolIndex] = GridStepPoints[symbolIndex] * SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_POINT) * 10;
      // define the breakEvenTps
      int targetPip               = (int)MathCeil(BreakEvenTPPips[symbolIndex]);
      v_breakEvenTPs[symbolIndex] = targetPip * SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_POINT) * 10;   // eg: 200 * 0.00001 = 0.02
   }
}

// Open initial buy/sell position or increase hedging level if needed
void RunTradingStrategy(int symbolIndex, int main_actionType) {

   string actionType_word = main_actionType == 0 ? "Buy" : "Sell";
   // ----- check if init buy / sell
   ulong nr_tickets[];
   GetConditionalTickets(nr_tickets, symbolIndex, main_actionType, 0);   // start for level 0

   // Case 1: No positions exist at level 0 - open initial position
   if(ArraySize(nr_tickets) == 0 && TimeCurrent() >= v_backToTradeUntil[symbolIndex]) {
      // Open initial position at level 0
      OpenLevelPosition(symbolIndex, main_actionType, 0, main_actionType, actionType_word);
   }
   // Case 2: Positions exist - check if need to increase hedging level
   else if(ArraySize(nr_tickets) > 0) {
      // Get the open time of the most recently triggered level position
      long last_openTime = GetLastLevelOpenTime(symbolIndex, main_actionType);

      // Check if enough days have passed to increase hedging level
      if(last_openTime > 0 && GetDifferenceDays(last_openTime) >= HedgingAfterDays[symbolIndex]) {
         // Find the next valid level to open
         int new_level = FindNextValidLevel(symbolIndex, main_actionType);

         // Determine action type for this new level
         int sub_actionType = GetActionType_byLevel(symbolIndex, main_actionType, new_level, i_actionSelectMethod);

         // Open position for the new level
         OpenLevelPosition(symbolIndex, main_actionType, new_level, sub_actionType, actionType_word);
      }
   }

   // ----- into the market (buy / sell) for each level
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
      // FIX: Check if array has elements before accessing requiredTickets[0]
      if(ArraySize(requiredTickets) == 0 || !PositionSelectByTicket(requiredTickets[0])) {
         continue;
      }
      int sub_actionType = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 0 : 1;
      CheckGridLevels(symbolIndex, main_actionType, level, sub_actionType);
      // ----- take profit by level
      bool   isTargetMeet = false;
      double earned       = CheckBreakEvenTP(isTargetMeet, requiredTickets, symbolIndex);   // TODO: generalize into both direction: buy and short
      if(isTargetMeet) {
         v_accumEarned[symbolIndex][main_actionType] += earned;
      }
   }
   // ----- getting tickets balance and see if meet the target
   bool  isTargetMeet = false;
   ulong requiredTickets[];
   GetConditionalTickets(requiredTickets, symbolIndex, main_actionType);
   double earned = CheckBreakEvenTP(isTargetMeet, requiredTickets, symbolIndex);
   if(isTargetMeet) {
      v_accumEarned[symbolIndex][main_actionType] = 0;
   }

   // getting tickets accum balance and see if meet the target
   ulong forAccum_tickets[];
   GetConditionalTickets(forAccum_tickets, symbolIndex, main_actionType);
   double current_ticket_balance = GetTicketsBalance(forAccum_tickets);
   if(v_accumEarned[symbolIndex][main_actionType] + current_ticket_balance >= accumEarnedTarget[symbolIndex]) {
      CloseAllTickets(forAccum_tickets);
      v_accumEarned[symbolIndex][main_actionType] = 0;
   }
}

// Helper function to open a position at a specific level
void OpenLevelPosition(int symbolIndex, int main_actionType, int level, int action_type, string actionType_word) {
   // Calculate lot size based on level and accumulated loss
   double lotSize = i_initialLotSize;
   if(level > 0) {
      // Get accumulated loss for this symbol and main action type
      double accumulatedLoss = GetAccumulatedLoss(symbolIndex, main_actionType);

      // Calculate base multiplier from level
      double levelMultiplier = MathPow(HedgingMultiplier[symbolIndex], level);

      // Adjust lot size based on both level and loss
      lotSize = CalculateAdjustedLotSize(symbolIndex, i_initialLotSize, levelMultiplier, accumulatedLoss);
      lotSize = NormalizeLot(Symbols[symbolIndex], lotSize);
   }

   // Set magic number and comment
   ulong  magic   = Encode4_Bytes(symbolIndex, main_actionType, level, action_type);
   string comment = "Initial " + actionType_word + " level - " + IntegerToString(level);

   // Open the position
   OpenInitialPosition(Symbols[symbolIndex], lotSize, action_type, magic, comment);
}

// check the grid level and if good to buy, 0 = buy; 1 = sell
// check the grid level and if good to buy, 0 = buy; 1 = sell
void CheckGridLevels(int symbolIndex, int main_actionType, int level, int sub_actionType) {
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

   // the init lot for the level - start with initial lot size instead of DBL_MAX
   double initLevelLot = i_initialLotSize;
   double lastLotSize  = 0;   // To track the lot size of the last position in the grid

   // calculate how many level to be concat
   ulong tickets[];
   // getting require magic
   ulong magic = Encode4_Bytes(symbolIndex, main_actionType, level, sub_actionType);
   GetTickets_ByMagic(tickets, magic);

   // First pass - determine the number of positions and find the last entry price
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

   // Second pass - find the lot size of the most recent position
   // We need to track the position with the price closest to lastEntryPrice
   double closestPriceDiff = DBL_MAX;
   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong ticket = tickets[i];
      if(PositionSelectByTicket(ticket)) {
         double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double priceDiff  = MathAbs(entryPrice - lastEntryPrice);

         if(priceDiff < closestPriceDiff) {
            closestPriceDiff = priceDiff;
            lastLotSize      = PositionGetDouble(POSITION_VOLUME);
         }
      }
   }

   // If we found positions, use the last lot size as our base
   if(nr_positions > 0 && lastLotSize > 0) {
      initLevelLot = lastLotSize;
   }

   if(nr_positions > 0) {
      double nextGridPrice;
      double currentPrice;
      // setting the magic number (setting in global)
      trade.SetExpertMagicNumber(Encode4_Bytes(symbolIndex, main_actionType, level, sub_actionType));
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
         double newLotSize = initLevelLot * i_lotMultiplier;   // Multiply by i_lotMultiplier directly
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
            } else {
               // Log successful grid trade
               LogTradeExecution(symbolIndex, "Grid " + long_short_wording, newLotSize, currentPrice, level,
                                 "Grid step: " + IntegerToString(nr_positions) + ", Base lot: " + DoubleToString(initLevelLot, 2));
            }
         } else {
            if(!trade.Sell(newLotSize, Symbols[symbolIndex], currentPrice, 0, 0, "Grid " + master_actionType_word + " level - " + IntegerToString(level))) {
               Print("Grid sell error: ", GetLastError());
            } else {
               // Log successful grid trade
               LogTradeExecution(symbolIndex, "Grid " + long_short_wording, newLotSize, currentPrice, level,
                                 "Grid step: " + IntegerToString(nr_positions) + ", Base lot: " + DoubleToString(initLevelLot, 2));
            }
         }
      }
   }
}

// Helper function to categorize tickets by type and level
void CategorizeTickets(ulong &tickets[], ulong &buy_tickets[], ulong &sell_tickets[],
                       ulong &level0_buy_tickets[], ulong &level0_sell_tickets[]) {
   // Reset arrays
   ArrayResize(buy_tickets, 0);
   ArrayResize(sell_tickets, 0);
   ArrayResize(level0_buy_tickets, 0);
   ArrayResize(level0_sell_tickets, 0);

   // Categorize each ticket
   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong ticket = tickets[i];
      if(!PositionSelectByTicket(ticket)) {
         continue;
      }

      // Get position details
      int  _symbolIndex;
      int  _main_actionType;
      int  _level;
      int  _sub_actionType;
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      Decode4_Bytes((int)posMagic, _symbolIndex, _main_actionType, _level, _sub_actionType);

      // Categorize by position type
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
         int n = ArraySize(buy_tickets);
         ArrayResize(buy_tickets, n + 1);
         buy_tickets[n] = ticket;

         // Store level 0 tickets separately
         if(_level == 0) {
            int m = ArraySize(level0_buy_tickets);
            ArrayResize(level0_buy_tickets, m + 1);
            level0_buy_tickets[m] = ticket;
         }
      } else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
         int n = ArraySize(sell_tickets);
         ArrayResize(sell_tickets, n + 1);
         sell_tickets[n] = ticket;

         // Store level 0 tickets separately
         if(_level == 0) {
            int m = ArraySize(level0_sell_tickets);
            ArrayResize(level0_sell_tickets, m + 1);
            level0_sell_tickets[m] = ticket;
         }
      }
   }
}

// Helper function to calculate break-even prices
void CalculateBreakEvenPrices(ulong &buy_tickets[], ulong &sell_tickets[], int symbolIndex,
                              double &buy_breakEvenPrice, double &sell_breakEvenPrice,
                              double &buy_positionCost, double &sell_positionCost,
                              double &current_bid, double &current_ask, double &totalPositionVolume) {
   // Initialize values
   buy_breakEvenPrice  = 0.0;
   sell_breakEvenPrice = 0.0;
   buy_positionCost    = 0.0;
   sell_positionCost   = 0.0;
   current_bid         = 0.0;
   current_ask         = 0.0;
   totalPositionVolume = 0.0;

   ulong required_tickets[];

   // Calculate for buy positions
   if(ArraySize(buy_tickets) > 0) {
      ArrayCopy(required_tickets, buy_tickets);
      buy_positionCost   = GetPositionCost(required_tickets, totalPositionVolume, 0);
      buy_breakEvenPrice = NormalizeDouble(buy_positionCost + v_breakEvenTPs[symbolIndex], v_digits_numbers[symbolIndex]);
      current_bid        = NormalizeDouble(SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_BID), v_digits_numbers[symbolIndex]);
   }

   // Calculate for sell positions
   if(ArraySize(sell_tickets) > 0) {
      ArrayCopy(required_tickets, sell_tickets);
      sell_positionCost   = GetPositionCost(required_tickets, totalPositionVolume, 1);
      sell_breakEvenPrice = NormalizeDouble(sell_positionCost - v_breakEvenTPs[symbolIndex], v_digits_numbers[symbolIndex]);
      current_ask         = NormalizeDouble(SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_ASK), v_digits_numbers[symbolIndex]);
   }
}

// Helper function to filter non-level 0 tickets
void FilterNonLevel0Tickets(ulong &source_tickets[], ulong &non_level0_tickets[]) {
   ArrayResize(non_level0_tickets, 0);

   for(int i = 0; i < ArraySize(source_tickets); i++) {
      ulong ticket = source_tickets[i];
      if(!PositionSelectByTicket(ticket))
         continue;

      int  _symbolIndex;
      int  _main_actionType;
      int  _level;
      int  _sub_actionType;
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      Decode4_Bytes((int)posMagic, _symbolIndex, _main_actionType, _level, _sub_actionType);

      if(_level > 0) {
         int n = ArraySize(non_level0_tickets);
         ArrayResize(non_level0_tickets, n + 1);
         non_level0_tickets[n] = ticket;
      }
   }
}

// Helper function to process ticket closing with level 0 protection
double ProcessTicketClosing(ulong &tickets[], ulong &level0_tickets[], int symbolIndex, int positionType) {
   double profit = 0.0;

   if(ArraySize(tickets) > 0) {
      profit = GetTicketsBalance(tickets);

      // Check if there are level 0 tickets and if higher levels exist
      if(ArraySize(level0_tickets) > 0) {
         bool hasHigherLevels = false;
         int  main_actionType = -1;

         // Extract main_actionType from first ticket to check for higher levels
         if(PositionSelectByTicket(level0_tickets[0])) {
            int  _symbolIndex;
            int  _main_actionType;
            int  _level;
            int  _sub_actionType;
            long posMagic = PositionGetInteger(POSITION_MAGIC);
            Decode4_Bytes((int)posMagic, _symbolIndex, _main_actionType, _level, _sub_actionType);

            main_actionType = _main_actionType;
            hasHigherLevels = HasHigherLevels(symbolIndex, _main_actionType, 0);
         }

         // If higher levels exist, don't close level 0 tickets
         if(hasHigherLevels) {
            string posTypeStr = positionType == 0 ? "buy" : "sell";
            Print("Not closing level 0 ", posTypeStr, " positions because higher levels exist");

            // Create array of non-level 0 tickets to close
            ulong non_level0_tickets[];
            FilterNonLevel0Tickets(tickets, non_level0_tickets);

            // Close only non-level 0 tickets
            if(ArraySize(non_level0_tickets) > 0) {
               CloseAllTickets(non_level0_tickets);
            }
         } else {
            // If no higher levels, close all tickets
            CloseAllTickets(tickets);
         }
      } else {
         // No level 0 tickets, close all tickets
         CloseAllTickets(tickets);
      }
   }

   return profit;
}

// Refactored CheckBreakEvenTP function with improved CSV logging
double CheckBreakEvenTP(bool &isTargetMeet, ulong &tickets[], int symbolIndex) {
   // Initialize arrays for different ticket categories
   ulong buy_tickets[];
   ulong sell_tickets[];
   ulong level0_buy_tickets[];
   ulong level0_sell_tickets[];

   // Step 1: Categorize tickets by type and level
   CategorizeTickets(tickets, buy_tickets, sell_tickets, level0_buy_tickets, level0_sell_tickets);

   // Step 2: Calculate break-even prices
   double buy_breakEvenPrice, sell_breakEvenPrice;
   double buy_positionCost, sell_positionCost;
   double current_bid, current_ask;
   double totalPositionVolume = 0.0;

   CalculateBreakEvenPrices(buy_tickets, sell_tickets, symbolIndex,
                            buy_breakEvenPrice, sell_breakEvenPrice,
                            buy_positionCost, sell_positionCost,
                            current_bid, current_ask, totalPositionVolume);

   // Step 3: Check if target is met and process ticket closing
   double buy_profit   = 0.0;
   double sell_profit  = 0.0;
   double total_profit = 0.0;

   if(totalPositionVolume > 0) {
      if(current_bid - buy_breakEvenPrice + (sell_breakEvenPrice - current_ask) >= 0.0) {
         Print("-------------------------------");
         Print(" totalPositionVolume: ", totalPositionVolume);

         // Process buy and sell tickets with level 0 protection
         buy_profit   = ProcessTicketClosing(buy_tickets, level0_buy_tickets, symbolIndex, 0);
         sell_profit  = ProcessTicketClosing(sell_tickets, level0_sell_tickets, symbolIndex, 1);
         total_profit = buy_profit + sell_profit;

         // Log the data using our new CSV function
         if(spreadSheetHandler != INVALID_HANDLE) {
            string data[10][2];
            data[0][0] = "timestamp";
            data[0][1] = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
            data[1][0] = "symbol";
            data[1][1] = Symbols[symbolIndex];
            data[2][0] = "totalPositionVolume";
            data[2][1] = DoubleToString(totalPositionVolume, 2);
            data[3][0] = "buyPositionCost";
            data[3][1] = DoubleToString(buy_positionCost, v_digits_numbers[symbolIndex]);
            data[4][0] = "sellPositionCost";
            data[4][1] = DoubleToString(sell_positionCost, v_digits_numbers[symbolIndex]);
            data[5][0] = "buyBreakEvenPrice";
            data[5][1] = DoubleToString(buy_breakEvenPrice, v_digits_numbers[symbolIndex]);
            data[6][0] = "sellBreakEvenPrice";
            data[6][1] = DoubleToString(sell_breakEvenPrice, v_digits_numbers[symbolIndex]);
            data[7][0] = "currentBid";
            data[7][1] = DoubleToString(current_bid, v_digits_numbers[symbolIndex]);
            data[8][0] = "currentAsk";
            data[8][1] = DoubleToString(current_ask, v_digits_numbers[symbolIndex]);
            data[9][0] = "profit";
            data[9][1] = DoubleToString(total_profit, 2);

            WriteCSVRecord(spreadSheetHandler, data);
         }

         isTargetMeet = true;
         Print("-------------------------------");
      }
   }

   // Step 4: Calculate point difference
   double ptDiff = 0.0;
   if(ArraySize(buy_tickets) > 0) {
      ptDiff += PointsDiff(current_bid, buy_positionCost, Symbols[symbolIndex]);
   }
   if(ArraySize(sell_tickets) > 0) {
      ptDiff += PointsDiff(sell_positionCost, current_ask, Symbols[symbolIndex]);
   }

   return total_profit;
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
   // FIX: Check if array has elements before looping through it
   if(ArraySize(tickets) == 0) {
      return 0;   // Return 0 if no tickets found
   }

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
   // FIX: Check if array has elements before looping through it
   if(ArraySize(tickets) == 0) {
      return 0;   // Return 0 if no tickets found
   }

   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong tk = tickets[i];
      if(!PositionSelectByTicket(tk))
         continue;
      int  _symbolIndex;
      int  _main_actionType;
      int  _level;
      int  _sub_actionType;
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      Decode4_Bytes((int)posMagic, _symbolIndex, _main_actionType, _level, _sub_actionType);
      if(_level > maxLevel) {
         maxLevel = _level;
      }
   }
   return maxLevel;
}

// getting the difference in days
double GetDifferenceDays(long firstDate, long lastDate = NULL) {
   if(!lastDate || lastDate == NULL) {
      lastDate = TimeCurrent();
   }
   long   timeDifferenceSeconds = (long)lastDate - (long)firstDate;
   double daysDifference        = (double)timeDifferenceSeconds / 86400.0;
   return daysDifference;
}

// get the new action type by the level
int GetActionType_byLevel(int symbolIndex, int main_actionType, int level, bool actionSelectMethod = 0) {
   int sub_actionType;
   // by checking account loss
   if(actionSelectMethod == 0) {
      return SelectWithProbability(symbolIndex, main_actionType);
   } else if(actionSelectMethod == 1) {
      // if %2 residual value, used original main_actionType
      if(level % 2 == 0) {
         sub_actionType = main_actionType;
      } else {
         sub_actionType = main_actionType == 0 ? 1 : 0;
      }
      return sub_actionType;
   } else if(actionSelectMethod == 2) {
      if(main_actionType == 0) {
         return sub_actionType = 1;
      } else {
         return 0;
      }
   }
   return 0;
}

// Return 0 or 1
// pZero: probability to select 0 (0.0 ~ 1.0), e.g., 0.1 -> 10% select 0, 90% select 1
// seed:  optional random seed; if 0 then initialize with current time
int SelectWithProbability(int symbolIndex, int main_actionType, uint seed = 0) {

   // ----- calculate the probablity
   ulong  tickets[];
   double totalLoss = 0.0;
   double buyLoss   = 0.0;
   double sellLoss  = 0.0;
   GetConditionalTickets(tickets, symbolIndex, main_actionType);
   // FIX: Check if array has elements before looping through it
   if(ArraySize(tickets) > 0) {
      for(int i = 0; i < ArraySize(tickets); i++) {
         ulong tk = tickets[i];
         if(!PositionSelectByTicket(tk)) {
            continue;
         }
         double loss       = PositionGetDouble(POSITION_PROFIT);
         ulong  actionType = PositionGetInteger(POSITION_TYPE);
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
   }

   // FIX: Check for division by zero
   double pZero = 0.5;   // Default to 50% probability if no losses
   if(totalLoss != 0.0) {
      // less sell loss -> more probablility to select sell action type
      pZero = sellLoss / totalLoss;
   }

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
      int  _sub_actionType;
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      Decode4_Bytes((int)posMagic, _symbolIndex, _main_actionType, _level, _sub_actionType);
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

// Add this new function to check if higher levels exist
bool HasHigherLevels(int symbolIndex, int main_actionType, int currentLevel) {
   ulong tickets[];
   GetConditionalTickets(tickets, symbolIndex, main_actionType);

   if(ArraySize(tickets) == 0) {
      return false;
   }

   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong tk = tickets[i];
      if(!PositionSelectByTicket(tk))
         continue;

      int  _symbolIndex;
      int  _main_actionType;
      int  _level;
      int  _sub_actionType;
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      Decode4_Bytes((int)posMagic, _symbolIndex, _main_actionType, _level, _sub_actionType);

      if(_level > currentLevel) {
         return true;   // Found a higher level
      }
   }

   return false;   // No higher levels found
}

// Update the LogTradeExecution function to use the trade log handler
void LogTradeExecution(int symbolIndex, string actionType, double lotSize, double price, int level, string comment) {
   if(tradeLogHandler == INVALID_HANDLE)
      return;

   string data[7][2];
   data[0][0] = "timestamp";
   data[0][1] = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
   data[1][0] = "symbol";
   data[1][1] = Symbols[symbolIndex];
   data[2][0] = "action";
   data[2][1] = actionType;
   data[3][0] = "lotSize";
   data[3][1] = DoubleToString(lotSize, 2);
   data[4][0] = "price";
   data[4][1] = DoubleToString(price, v_digits_numbers[symbolIndex]);
   data[5][0] = "level";
   data[5][1] = IntegerToString(level);
   data[6][0] = "comment";
   data[6][1] = comment;

   WriteCSVRecord(tradeLogHandler, data);
}

// Function to find the next valid level to open (the first missing level)
int FindNextValidLevel(int symbolIndex, int main_actionType) {
   // Get all tickets for this symbol and action type
   ulong tickets[];
   GetConditionalTickets(tickets, symbolIndex, main_actionType);

   // Create a dynamic array to store existing levels
   int existingLevels[];
   ArrayResize(existingLevels, 0);

   // Collect all existing levels
   for(int i = 0; i < ArraySize(tickets); i++) {
      if(!PositionSelectByTicket(tickets[i]))
         continue;

      int  _symbolIndex, _main_actionType, _level, _sub_actionType;
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      Decode4_Bytes((int)posMagic, _symbolIndex, _main_actionType, _level, _sub_actionType);

      // Add this level to our array if it doesn't already exist
      bool levelExists = false;
      for(int j = 0; j < ArraySize(existingLevels); j++) {
         if(existingLevels[j] == _level) {
            levelExists = true;
            break;
         }
      }

      if(!levelExists) {
         int size = ArraySize(existingLevels);
         ArrayResize(existingLevels, size + 1);
         existingLevels[size] = _level;
      }
   }

   // Sort the levels array
   ArraySort(existingLevels);

   // Find the first gap in the sequence starting from level 1
   // (Level 0 is special and should always exist)
   for(int i = 1; i < 1000; i++) {   // 1000 is just a safety limit
      bool found = false;
      for(int j = 0; j < ArraySize(existingLevels); j++) {
         if(existingLevels[j] == i) {
            found = true;
            break;
         }
      }

      if(!found) {
         return i;   // Return the first missing level
      }
   }

   // If we get here, all levels from 1 to 999 exist (extremely unlikely)
   // Return the next level after the maximum
   if(ArraySize(existingLevels) > 0) {
      return existingLevels[ArraySize(existingLevels) - 1] + 1;
   }

   // If no levels exist, start with level 1
   return 1;
}

// Add this function to check if a specific level exists
bool LevelExists(int symbolIndex, int main_actionType, int level) {
   ulong tickets[];
   GetConditionalTickets(tickets, symbolIndex, main_actionType);

   for(int i = 0; i < ArraySize(tickets); i++) {
      if(!PositionSelectByTicket(tickets[i]))
         continue;

      int  _symbolIndex, _main_actionType, _level, _sub_actionType;
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      Decode4_Bytes((int)posMagic, _symbolIndex, _main_actionType, _level, _sub_actionType);

      if(_level == level) {
         return true;
      }
   }

   return false;
}

// Get the open time of the most recently triggered level
long GetLastLevelOpenTime(int symbolIndex, int main_actionType) {
   // Get all tickets for this symbol and action type
   ulong tickets[];
   GetConditionalTickets(tickets, symbolIndex, main_actionType);

   // If no tickets found, return 0
   if(ArraySize(tickets) == 0) {
      return 0;
   }

   // Create arrays to track levels and their first open times
   int  levels[];
   long levelOpenTimes[];

   // First, collect all existing levels and their earliest open times
   for(int i = 0; i < ArraySize(tickets); i++) {
      if(!PositionSelectByTicket(tickets[i]))
         continue;

      int  _symbolIndex, _main_actionType, _level, _sub_actionType;
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      Decode4_Bytes((int)posMagic, _symbolIndex, _main_actionType, _level, _sub_actionType);

      // Check if this level is already in our array
      int levelIndex = -1;
      for(int j = 0; j < ArraySize(levels); j++) {
         if(levels[j] == _level) {
            levelIndex = j;
            break;
         }
      }

      long positionTime = PositionGetInteger(POSITION_TIME);

      if(levelIndex == -1) {
         // This is a new level, add it to our arrays
         int size = ArraySize(levels);
         ArrayResize(levels, size + 1);
         ArrayResize(levelOpenTimes, size + 1);
         levels[size]         = _level;
         levelOpenTimes[size] = positionTime;
      } else {
         // This level exists, update the open time if this position is older
         if(positionTime < levelOpenTimes[levelIndex]) {
            levelOpenTimes[levelIndex] = positionTime;
         }
      }
   }

   // If no levels were found (shouldn't happen since we checked ArraySize(tickets) earlier)
   if(ArraySize(levels) == 0) {
      return 0;
   }

   // Now find the most recently triggered level (the one with the latest first open time)
   long mostRecentOpenTime = 0;

   for(int i = 0; i < ArraySize(levelOpenTimes); i++) {
      if(levelOpenTimes[i] > mostRecentOpenTime) {
         mostRecentOpenTime = levelOpenTimes[i];
      }
   }

   return mostRecentOpenTime;
}

// New function to calculate adjusted lot size based on accumulated loss
double CalculateAdjustedLotSize(int symbolIndex, double baseLot, double levelMultiplier, double accumulatedLoss) {
   // Base calculation using level multiplier
   double lotSize = baseLot * levelMultiplier;

   // If there's significant accumulated loss, adjust the lot size further
   if(accumulatedLoss < -accumEarnedTarget[symbolIndex]) {   // Only adjust if loss is significant
      // Calculate loss factor (larger loss = larger multiplier)
      // Convert negative loss to positive factor, scaled appropriately
      double lossFactor = 1.0 + MathMin(MathAbs(accumulatedLoss) / (accumEarnedTarget[symbolIndex] * 10), 2.0);

      // Apply loss factor to lot size
      lotSize *= lossFactor;
   }

   // Ensure lot size doesn't exceed reasonable limits
   double maxLot = 10.0;   // Set appropriate maximum lot size
   return MathMin(lotSize, maxLot);
}

// New function to get accumulated loss for a symbol and main action type
double GetAccumulatedLoss(int symbolIndex, int main_actionType) {
   ulong  tickets[];
   double totalLoss = 0.0;

   // Get all tickets for this symbol and main action type
   GetConditionalTickets(tickets, symbolIndex, main_actionType);

   // Calculate total loss
   for(int i = 0; i < ArraySize(tickets); i++) {
      if(PositionSelectByTicket(tickets[i])) {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit < 0) {
            totalLoss += profit;
         }
      }
   }

   return totalLoss;
}