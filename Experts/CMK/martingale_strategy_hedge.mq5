//+------------------------------------------------------------------+
//|                                                  MartingaleMA.mq5|
//|                                         Copyright 2025, YourName |
//|                    Added operation for offset the idle positions |
//+------------------------------------------------------------------+

#include <CMK/Helper.mqh>
#include <CMK/String.mqh>
#include <CMK/Time.mqh>
#include <Trade/AccountInfo.mqh>
#include <Trade/Trade.mqh>
CTrade              trade;
static CAccountInfo accountInfo;

// grid parameters
input double i_initialLotSize     = 0.01;
input double i_lotMultiplier      = 1.1;
input int    i_gridStepPoints     = 50;
input double i_gridStepMultiplier = 1.25;
input int    i_breakEvenTPPoints  = 200;
input int    i_stopLossMoney      = 2500;   // set to 0 means it is no stop loss
input int    i_sleepDays          = 120;    // after stop loss / no margin, the currency will be resume trading after this day passed

// strategy constant
string Symbols[]                = {"AUDNZD", "AUDUSD", "GBPUSD", "EURGBP"};   // , "AUDUSD", "GBPUSD", "EURGBP"
int    RSIPeriod[]              = {14, 14, 14, 14};
int    HedgingAfterDays[]       = {30, 30, 30, 30};       // doing hedging after these day being hold
double HedgingLevelMultiplier[] = {1.2, 1.2, 1.2, 1.2};   // The hedging mechanism will operate at this multiple in order to accelerate the completion of a position that has been maintained for a long time.
int    SymbolTotal              = ArraySize(Symbols);

// strategy variables
double   v_breakEvenTPs[ArraySize(Symbols)];
int      v_BuyMagicNumbers[ArraySize(Symbols)];    // magic number for first strategy
datetime v_backToTradeUntil[ArraySize(Symbols)];   // continue to trade after this date
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
      v_BuyMagicNumbers[symbolIndex]  = symbolIndex;
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
      InitializeVariables(symbolIndex);
      RunTradingStrategy(symbolIndex);
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

void RunTradingStrategy(int symbolIndex) {
   // check if buy position holding
   int nr_buy_positions = CountAllPositions(Symbols[symbolIndex], 0);
   // Open inital buy position if no buy positions
   // Print("nr_buy_positions: ", nr_buy_positions, " - Symbol: ", Symbols[symbolIndex]);
   // Print("TimeCurrent() >= v_backToTradeUntil[symbolIndex]: ", TimeCurrent() >= v_backToTradeUntil[symbolIndex]);
   if(nr_buy_positions == 0 && TimeCurrent() >= v_backToTradeUntil[symbolIndex]) {
      OpenInitialPosition(Symbols[symbolIndex], i_initialLotSize, 0);
   }
   // check if sell position holding
   int nr_sell_positions = CountAllPositions(Symbols[symbolIndex], 1);
   // Print("nr_sell_positions: ", nr_sell_positions, " - Symbol: ", Symbols[symbolIndex]);
   // Print("TimeCurrent() >= v_backToTradeUntil[symbolIndex]: ", TimeCurrent() >= v_backToTradeUntil[symbolIndex]);
   // Open inital sell position if no sell positions
   if(nr_sell_positions == 0 && TimeCurrent() >= v_backToTradeUntil[symbolIndex]) {
      OpenInitialPosition(Symbols[symbolIndex], i_initialLotSize, 1);
   }
   CheckSymbolStopLoss(v_BuyMagicNumbers[symbolIndex]);
   CheckGridLevels(symbolIndex, 0);   // check buy
   CheckGridLevels(symbolIndex, 1);   // check sell
   SetBreakEvenTP(symbolIndex, 0);
   SetBreakEvenTP(symbolIndex, 1);
}

// get how many position being hold (position type: buy / sell / all)
// int CountBuyPositions(int symbolIndex, string positionType) {
//    int count = 0;
//    for(int i = 0; i < PositionsTotal(); i++) {
//       ulong ticket = PositionGetTicket(i);
//       if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == Symbols[symbolIndex]) {
//          if(positionType == "buy" && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
//             count++;
//          } else if(positionType == "sell" && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
//             count++;
//          } else {
//             count++;
//          }
//       }
//    }
//    return count;
// }

// void OpenInitialBuyPosition(int symbolIndex) {
//    // get current ask price
//    double askPrice = SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_ASK);
//    // double lotSize  = NormalizeLotSize(i_initialLotSize);
//    double requiredMargin = accountInfo.MarginCheck(Symbols[symbolIndex], ORDER_TYPE_BUY, i_initialLotSize, askPrice);
//    // check if enough of margin to buy
//    if(requiredMargin > accountInfo.FreeMargin()) {
//       Print("Not enough margin for initial buy! Required: ", requiredMargin, " Free: ", accountInfo.FreeMargin());
//       return;
//    }
//    // trigger the action for buy
//    if(!trade.Buy(i_initialLotSize, Symbols[symbolIndex], askPrice, 0, 0, "Initial Buy")) {
//       Print("Initial buy error: ", GetLastError());
//    } else {
//       Print("Initial buy position opened at ", askPrice, " with lot size ", i_initialLotSize);
//    }
// }

// check the grid level and if good to buy, 0 = buy; 1 = sell
void CheckGridLevels(int symbolIndex, int actionType = 0) {
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
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      // select the position and with the same symbol
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == Symbols[symbolIndex]) {
         // same as BUY type
         if(PositionGetInteger(POSITION_TYPE) == positionType) {
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
   }

   if(nr_positions > 0) {
      double nextGridPrice;
      double currentPrice;
      // setting the magic number for position
      trade.SetExpertMagicNumber(v_BuyMagicNumbers[symbolIndex]);
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

      if((actionType == 0 && currentPrice <= nextGridPrice) || (actionType == 1 && currentPrice >= nextGridPrice)) {
         // new lot size
         double newLotSize = i_initialLotSize * MathPow(i_lotMultiplier, nr_positions);
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
            if(!trade.Buy(newLotSize, Symbols[symbolIndex], currentPrice, 0, 0, "Grid Buy")) {
               Print("Grid buy error: ", GetLastError());
            }
         } else {
            if(!trade.Sell(newLotSize, Symbols[symbolIndex], currentPrice, 0, 0, "Grid Sell")) {
               Print("Grid sell error: ", GetLastError());
            }
         }
      }
   }
}

// check if the balance excced the stop loss
void CheckSymbolStopLoss(int symbolIndex) {
   int    magicNumber  = v_BuyMagicNumbers[symbolIndex];
   double magicBalance = GetMagicBalance(magicNumber);
   // set to 0 means it is no stop loss
   if(i_stopLossMoney != 0 && magicBalance * -1 >= i_stopLossMoney) {
      // clase all the position for this symbol
      CloseAllPositions(Symbols[symbolIndex], -1);
      datetime currDatetime = TimeCurrent();
      // stop the trading until below the date passed
      v_backToTradeUntil[symbolIndex] = AddDate(currDatetime, i_sleepDays);
      Print("==============> Stopped Loss at ", TimeToString(currDatetime), " - ", magicBalance * -1, " until ", TimeToString(v_backToTradeUntil[symbolIndex]), "<==============");
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

      if((actionType == 0 && current_bidAsk >= breakEvenPrice) || (actionType == 1 && current_bidAsk <= breakEvenPrice)) {
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

// close all positions
void CloseAllBuyPositions(string requiredSymbol) {
   // getting all position tickets
   ulong tickets[];
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == requiredSymbol) {
         int currentSize = ArraySize(tickets);
         ArrayResize(tickets, currentSize + 1);
         tickets[currentSize] = PositionGetTicket(i);
         Print("------------------------------ Closing Ticket / i: ", tickets[currentSize], " / ", i, " ------------------------------");
      }
   }
   // looping for each of tickets array
   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong readyClosedticket = tickets[i];
      trade.PositionClose(readyClosedticket, ULONG_MAX);
      Sleep(100);   // Relax for 100 ms
   }
   Print("------------------------------ Completed ------------------------------");
}

// write the csv file
// void WriteCsv(string filename, string &cols[], string &values[]) {
//    // open file for reading and writing, as CSV format, ANSI mode
//    int spreadSheetHandler = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
//    Print("TERMINAL_COMMONDATA_PATH: ", TerminalInfoString(TERMINAL_COMMONDATA_PATH));

//    // building parameters
//    string datas[];
//    int    currentSize;
//    for(int i = 0; i < ArraySize(cols); i++) {
//       currentSize = ArraySize(datas);
//       ArrayResize(datas, currentSize + 1);
//       datas[currentSize] = cols[i];
//       currentSize        = ArraySize(datas);
//       ArrayResize(datas, currentSize + 1);
//       datas[currentSize] = values[i];
//    }
//    ArrayPrint(datas);
//    // go to the end of file
//    FileSeek(spreadSheetHandler, 0, SEEK_END);
//    // FileWriteArray(spreadSheetHandler, datas, 0, WHOLE_ARRAY);
//    // FileWrite(spreadSheetHandler, "a1", 1);

//    // close the file
//    FileClose(spreadSheetHandler);
// }

double lotExp(int nr_buy_positions) {
   return 0.1 * exp(nr_buy_positions / 25) + 1;
}