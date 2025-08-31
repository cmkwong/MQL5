//+------------------------------------------------------------------+
//|                                                  MartingaleMA.mq5|
//|                        Copyright 2025, YourName                  |
//|                                      https://www.yourwebsite.com |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>
CTrade trade;
#include <Trade/AccountInfo.mqh>
static CAccountInfo accountInfo;

// grid parameters
input double initialLotSize     = 0.01;
input double lotMultiplier      = 1.5;
input int    gridStepPoints     = 100;
input double gridStepMultiplier = 1.05;
input int    breakEvenTPPoints  = 400;

double gridStep    = gridStepPoints * _Point;
double breakEvenTP = breakEvenTPPoints * _Point;
int    digits_number;

// Grid tracking variable
double currentBuyGridStep = 0;

int    handle_rsi;
double rsi_array[3];
string filename;
int    spreadSheetHandler;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   // create the RSI handler
   handle_rsi = iRSI(_Symbol, PERIOD_M30, 14, PRICE_CLOSE);
   filename   = "logFile_" + getCurrentTimeString() + ".csv";
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

   // CopyBuffer(handle_rsi, 0, 0, 3, rsi_array);
   InitializeVariables();
   RunTradingStrategy();
}
//+------------------------------------------------------------------+
//| Function to execute trades                                        |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
void InitializeVariables() {
   digits_number = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // never do the any trading yet
   if(currentBuyGridStep == 0) {
      currentBuyGridStep = gridStep;
   }
}

void RunTradingStrategy() {
   int    nr_buy_positions = CountBuyPositions();
   double askPrice         = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Open inital buy position if no buy positions
   if(nr_buy_positions == 0) {
      OpenInitialBuyPosition();
   }

   CheckBuyGridLevels();
   SetBreakEvenTP();
}

// get how many position being hold
int CountBuyPositions() {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
         count++;
      }
   }
   return count;
}

void OpenInitialBuyPosition() {
   double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);   // Get current ask price
   //  double lotSize  = NormalizeLotSize(initialLotSize);
   double requiredMargin = accountInfo.MarginCheck(_Symbol, ORDER_TYPE_BUY, initialLotSize, askPrice);

   // check if enough of margin to buy
   if(requiredMargin > accountInfo.FreeMargin()) {
      Print("Not enough margin for initial buy! Required: ", requiredMargin, " Free: ", accountInfo.FreeMargin());
      return;
   }
   // trigger the action for buy
   if(!trade.Buy(initialLotSize, _Symbol, askPrice, 0, 0, "Initial Buy")) {
      Print("Initial buy error: ", GetLastError());
   } else {
      Print("Initial buy position opened at ", askPrice, " with lot size ", initialLotSize);
   }
}

void CheckBuyGridLevels() {
   double minBuyPrice      = DBL_MAX;
   int    nr_buy_positions = 0;

   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      // select the position and with the same symbol
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == _Symbol) {
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
      double nextGridBuyPrice = NormalizeDouble(minBuyPrice - (currentBuyGridStep)*MathPow(gridStepMultiplier, nr_buy_positions), digits_number);
      // get normalized ask price
      double currentAsk = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK), digits_number);

      if(currentAsk <= nextGridBuyPrice) {
         // new lot size
         double newLotSize = initialLotSize * MathPow(lotMultiplier, nr_buy_positions);
         newLotSize        = normalizeLot(newLotSize);

         // check required margin
         double requiredMargin = accountInfo.MarginCheck(_Symbol, ORDER_TYPE_BUY, newLotSize, currentAsk);
         if(requiredMargin > accountInfo.FreeMargin()) {
            Print("Not enough margin for grid buy!");
            return;
         }

         // take action
         if(!trade.Buy(newLotSize, _Symbol, currentAsk, 0, 0, "Grid Buy")) {
            Print("Grid buy error: ", GetLastError());
         }
      }
   }
}

// calculate the break even point account with profit token
void SetBreakEvenTP() {
   double totalBuyVolume = 0;
   double totalBuyCost   = 0;

   // calculate the buy cost
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      // select the position and with the same symbol
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == _Symbol) {
         double volume      = PositionGetDouble(POSITION_VOLUME);
         double entryPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
         totalBuyVolume    += volume;
         totalBuyCost      += entryPrice * volume;
      }
   }

   if(totalBuyVolume > 0) {
      double buyCost           = totalBuyCost / totalBuyVolume;
      double breakEvenBuyPrice = NormalizeDouble(buyCost + breakEvenTP, digits_number);
      double currentBid        = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID), digits_number);

      if(currentBid >= breakEvenBuyPrice) {
         Print("-------------------------------");
         Print("totalBuyCost: ", totalBuyCost, " totalBuyVolume: ", totalBuyVolume, " (totalBuyCost / totalBuyVolume): ", (totalBuyCost / totalBuyVolume), " breakEvenTP: ", breakEvenTP);
         // string nowStr = TimeToString(TimeCurrent());
         // string filename = "logFile" + "_" + nowStr + ".csv";

         Print("TERMINAL_COMMONDATA_PATH: ", TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "/" + filename);
         FileSeek(spreadSheetHandler, 0, SEEK_END);
         FileWrite(spreadSheetHandler, DoubleToString(totalBuyCost), DoubleToString(totalBuyVolume), DoubleToString((totalBuyCost / totalBuyVolume)), DoubleToString(breakEvenTP));

         // WriteCsv(filename, cols, values);
         CloseAllBuyPositions();
         Print("-------------------------------");
      }
   }
}

// close all positions
void CloseAllBuyPositions() {
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == _Symbol) {
         if(!trade.PositionClose(ticket, 20)) {
            Print("There is error when close position - ", ticket, "with error - ", GetLastError());
         }
      }
   }
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
double normalizeLot(double rawLot) {
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

double lotExp(int nr_buy_positions) {
   return 0.1 * exp(nr_buy_positions / 25) + 1;
}