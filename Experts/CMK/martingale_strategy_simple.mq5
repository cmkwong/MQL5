//+------------------------------------------------------------------+
//|                                                  MartingaleMA.mq5|
//|                        Copyright 2025, YourName                  |
//|                                      https://www.yourwebsite.com |
//+------------------------------------------------------------------+
#include <Trade/AccountInfo.mqh>
#include <Trade/Trade.mqh>
CTrade              trade;
static CAccountInfo accountInfo;

// grid parameters
input double i_initialLotSize     = 0.01;
input double i_lotMultiplier      = 1.05;
input int    i_gridStepPoints     = 50;
input double i_gridStepMultiplier = 1.05;
input int    i_breakEvenTPPoints  = 20;
input int    i_stopLossMoney      = 2500;   // set to 0 means it is no stop loss
input int    i_sleepDays          = 120;

// double gridStep    = i_gridStepPoints * _Point;
// double breakEvenTP = i_breakEvenTPPoints * _Point;

// strategy constant
string Symbols[]   = {"AUDNZD"};   // , "AUDUSD", "GBPUSD", "EURGBP"
int    RSIPeriod[] = {14, 14, 14, 14};
int    SymbolTotal = ArraySize(Symbols);

// strategy variables
double   v_breakEvenTPs[ArraySize(Symbols)];
int      BuyMagicNumbers[ArraySize(Symbols)];      // magic number for first strategy
datetime v_backToTradeUntil[ArraySize(Symbols)];   // continue to trade after this date
double   v_currentBuyGridSteps[ArraySize(Symbols)];
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
      v_handle_rsi[symbolIndex]          = iRSI(Symbols[symbolIndex], PERIOD_M30, RSIPeriod[symbolIndex], PRICE_CLOSE);
      v_currentBuyGridSteps[symbolIndex] = 0;
      v_backToTradeUntil[symbolIndex]    = 0;
      BuyMagicNumbers[symbolIndex]       = symbolIndex;
      // set the digit number
      v_digits_numbers[symbolIndex] = (int)SymbolInfoInteger(Symbols[symbolIndex], SYMBOL_DIGITS);
   }
   // filename   = "logFile_" + getCurrentTimeString() + ".csv";
   filename = "logFile_" + getCurrentTimeString() + "_" + getRandomString(5) + ".csv";
   // write file
   spreadSheetHandler = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   // write header
   FileSeek(spreadSheetHandler, 0, SEEK_END);
   FileWrite(spreadSheetHandler, "totalBuyCost", "totalBuyVolume", "totalBuyCost / totalBuyVolume", "breakEvenTP");
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
   if(v_currentBuyGridSteps[symbolIndex] == 0) {
      v_currentBuyGridSteps[symbolIndex] = i_gridStepPoints * SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_POINT);
      v_breakEvenTPs[symbolIndex]        = i_breakEvenTPPoints * SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_POINT);
   }
}

void RunTradingStrategy(int symbolIndex) {
   // check if position holding
   int nr_buy_positions = CountBuyPositions(symbolIndex, "buy");
   // Open inital buy position if no buy positions
   if(nr_buy_positions == 0 && TimeCurrent() >= v_backToTradeUntil[symbolIndex]) {
      OpenInitialBuyPosition(symbolIndex);
   }
   CheckMagicBalance(BuyMagicNumbers[symbolIndex]);
   CheckBuyGridLevels(symbolIndex);
   SetBreakEvenTP(symbolIndex);
}

// get how many position being hold (position type: buy / sell / all)
int CountBuyPositions(int symbolIndex, string positionType) {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == Symbols[symbolIndex]) {
         if(positionType == "buy" && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
            count++;
         } else if(positionType == "sell" && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
            count++;
         } else {
            count++;
         }
      }
   }
   return count;
}

void OpenInitialBuyPosition(int symbolIndex) {
   // get current ask price
   double askPrice = SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_ASK);
   // double lotSize  = NormalizeLotSize(i_initialLotSize);
   double requiredMargin = accountInfo.MarginCheck(Symbols[symbolIndex], ORDER_TYPE_BUY, i_initialLotSize, askPrice);
   // check if enough of margin to buy
   if(requiredMargin > accountInfo.FreeMargin()) {
      Print("Not enough margin for initial buy! Required: ", requiredMargin, " Free: ", accountInfo.FreeMargin());
      return;
   }
   // trigger the action for buy
   if(!trade.Buy(i_initialLotSize, Symbols[symbolIndex], askPrice, 0, 0, "Initial Buy")) {
      Print("Initial buy error: ", GetLastError());
   } else {
      Print("Initial buy position opened at ", askPrice, " with lot size ", i_initialLotSize);
   }
}

// check the grid level and if good to buy
void CheckBuyGridLevels(int symbolIndex) {
   double minBuyPrice      = DBL_MAX;
   int    nr_buy_positions = 0;

   // calculate how many level to be concat
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      // select the position and with the same symbol
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == Symbols[symbolIndex]) {
         // same as BUY type
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
            // get the position entry price
            double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            if(entryPrice < minBuyPrice) {
               minBuyPrice = entryPrice;
            }
            // level of positions
            nr_buy_positions++;
         }
      }
   }

   if(nr_buy_positions > 0) {
      // setting the magic number for position
      trade.SetExpertMagicNumber(BuyMagicNumbers[symbolIndex]);
      // calculate the next grid buying price
      double nextGridBuyPrice = NormalizeDouble(minBuyPrice - (v_currentBuyGridSteps[symbolIndex]) * MathPow(i_gridStepMultiplier, nr_buy_positions), v_digits_numbers[symbolIndex]);
      // get normalized ask price
      double currentAsk = NormalizeDouble(SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_ASK), v_digits_numbers[symbolIndex]);

      if(currentAsk <= nextGridBuyPrice) {
         // new lot size
         double newLotSize = i_initialLotSize * MathPow(i_lotMultiplier, nr_buy_positions);
         newLotSize        = NormalizeLot(newLotSize);

         // check required margin
         double requiredMargin = accountInfo.MarginCheck(Symbols[symbolIndex], ORDER_TYPE_BUY, newLotSize, currentAsk);
         if(requiredMargin > accountInfo.FreeMargin()) {
            Print("Not enough margin for grid buy! Required Margin / Free Margin: ", DoubleToString(requiredMargin), " / ", DoubleToString(accountInfo.FreeMargin()));
            CloseAllBuyPositions(symbolIndex);
            datetime currDatetime           = TimeCurrent();
            v_backToTradeUntil[symbolIndex] = AddDate(currDatetime, i_sleepDays);
            Print("==============> Restarted ", TimeToString(currDatetime), " until ", TimeToString(v_backToTradeUntil[symbolIndex]), " <==============");
            return;
         }

         // take action
         if(!trade.Buy(newLotSize, Symbols[symbolIndex], currentAsk, 0, 0, "Grid Buy")) {
            Print("Grid buy error: ", GetLastError());
         }
      }
   }
}

// check if the balance excced the stop loss
void CheckMagicBalance(int symbolIndex) {
   int    magicNumber  = BuyMagicNumbers[symbolIndex];
   double magicBalance = GetMagicBalance(magicNumber);
   // set to 0 means it is no stop loss
   if(i_stopLossMoney != 0 && magicBalance * -1 >= i_stopLossMoney) {
      CloseAllBuyPositions(symbolIndex);
      datetime currDatetime = TimeCurrent();
      // stop the trading until below the date passed
      v_backToTradeUntil[symbolIndex] = AddDate(currDatetime, i_sleepDays);
      Print("==============> Stopped Loss at ", TimeToString(currDatetime), " - ", magicBalance * -1, " until ", TimeToString(v_backToTradeUntil[symbolIndex]), "<==============");
   }
}

// calculate the break even point account with profit token
void SetBreakEvenTP(int symbolIndex) {
   double totalBuyVolume = 0;
   double totalBuyCost   = 0;

   // calculate the buy cost
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      // select the position and with the same symbol
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == Symbols[symbolIndex]) {
         double volume      = PositionGetDouble(POSITION_VOLUME);
         double entryPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
         totalBuyVolume    += volume;
         totalBuyCost      += entryPrice * volume;
      }
   }

   if(totalBuyVolume > 0) {
      double buyCost           = totalBuyCost / totalBuyVolume;
      double breakEvenBuyPrice = NormalizeDouble(buyCost + v_breakEvenTPs[symbolIndex], v_digits_numbers[symbolIndex]);
      double currentBid        = NormalizeDouble(SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_BID), v_digits_numbers[symbolIndex]);

      if(currentBid >= breakEvenBuyPrice) {
         Print("-------------------------------");
         Print("totalBuyCost: ", totalBuyCost, " totalBuyVolume: ", totalBuyVolume, " (totalBuyCost / totalBuyVolume): ", (totalBuyCost / totalBuyVolume), " breakEvenTP: ", v_breakEvenTPs[symbolIndex]);
         // string nowStr = TimeToString(TimeCurrent());
         // string filename = "logFile" + "_" + nowStr + ".csv";

         Print("TERMINAL_COMMONDATA_PATH: ", TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "/" + filename);
         FileSeek(spreadSheetHandler, 0, SEEK_END);
         FileWrite(spreadSheetHandler, DoubleToString(totalBuyCost), DoubleToString(totalBuyVolume), DoubleToString((totalBuyCost / totalBuyVolume)), DoubleToString(v_breakEvenTPs[symbolIndex]));

         // WriteCsv(filename, cols, values);
         CloseAllBuyPositions(symbolIndex);
         Print("-------------------------------");
      }
   }
}

// close all positions
void CloseAllBuyPositions(int symbolIndex) {
   // getting all position tickets
   ulong tickets[];
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == Symbols[symbolIndex]) {
         int currentSize = ArraySize(tickets);
         ArrayResize(tickets, currentSize + 1);
         tickets[currentSize] = PositionGetTicket(i);
         Print("+++++++++++++++++ Closing Ticket / i: ", tickets[currentSize], " / ", i, " +++++++++++++++++");
      }
   }
   // looping for each of tickets array
   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong readyClosedticket = tickets[i];
      trade.PositionClose(readyClosedticket, ULONG_MAX);
      Sleep(100);   // Relax for 100 ms
   }
   Print("++++++++++++++++++++++++++++++++++");
}

// get the total balance from same magic number
double GetMagicBalance(int magicNum) {
   double positionBalance = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == magicNum) {
         positionBalance += PositionGetDouble(POSITION_PROFIT);
      }
   }
   return positionBalance;
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

// normalized into valid lot size corresponding to the Symbol
double NormalizeLot(double rawLot) {
   // new lot size
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return (int)(rawLot / lotStep) * lotStep;
}

// get the current time string, eg: 20250829_095605
string getCurrentTimeString() {
   MqlDateTime tm = {};
   // Get the current time as datetime
   datetime time_server = TimeLocal(tm);
   string   monS        = (string)tm.mon;
   if(StringLen(monS) == 1) {
      monS = "0" + monS;
   }
   string dayS = (string)tm.day;
   if(StringLen(dayS) == 1) {
      dayS = "0" + dayS;
   }
   string hourS = (string)tm.hour;
   if(StringLen(hourS) == 1) {
      hourS = "0" + hourS;
   }
   string minS = (string)tm.min;
   if(StringLen(minS) == 1) {
      minS = "0" + minS;
   }
   string secS = (string)tm.sec;
   if(StringLen(secS) == 1) {
      secS = "0" + secS;
   }
   return (string)tm.year + monS + dayS + "_" + hourS + minS + secS;
}

// add days
datetime AddDate(datetime currDate, int daysToChange) {
   datetime newDate = currDate + (daysToChange * 86400);   // Add 5 days
   return newDate;
}

// random string
string getRandomString(int strLen, int min = 1, int max = 9) {
   string randStr = "";
   for(int i = 0; i < strLen; i++) {
      int randomIntInRange  = (int)(MathRand() * (max - min + 1) / 32767.0) + min;
      randStr              += (string)(randomIntInRange);
   }
   return randStr;
}

double lotExp(int nr_buy_positions) {
   return 0.1 * exp(nr_buy_positions / 25) + 1;
}