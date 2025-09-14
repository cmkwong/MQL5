//+------------------------------------------------------------------+
//|                                                  MartingaleMA.mq5|
//|                        Copyright 2025, YourName                  |
//|                                      https://www.yourwebsite.com |
//+------------------------------------------------------------------+
#include <CMK/Helper.mqh>
#include <CMK/String.mqh>
#include <CMK/Time.mqh>
#include <Trade/AccountInfo.mqh>
#include <Trade/Trade.mqh>
// CTrade              trade;
// static CAccountInfo accountInfo;

// parameters
input double LotSize          = 1.0;
input int    MaxPositionCount = 1;
input int    TakeProfit       = 200;
input int    BandPeriod       = 30;
input double BandDeviation    = 2.0;
// variables
// for summary files writing
string filename;
int    digits_number;   // 4 / 5
int    csvSheetHandler;
// for strategy setting
int    Bb_Handle;
ulong  myTickets[][2];   // [Long, Short]
double myProfits[][2];   // [Long, Short]

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   // get the digit number
   digits_number = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   // create storage array
   ArrayResize(myTickets, MaxPositionCount);
   ArrayResize(myProfits, MaxPositionCount);
   // create indicator
   Bb_Handle = iBands(_Symbol, _Period, BandPeriod, 0, BandDeviation, PRICE_CLOSE);
   if(Bb_Handle == INVALID_HANDLE) {
      Print("Error creating Bollinger Bands indicator");
      return (INIT_FAILED);
   }
   // init file writing
   filename = "logFile_" + getCurrentTimeString() + "_" + getRandomString(5) + ".csv";
   // write file
   csvSheetHandler = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   // write header
   FileSeek(csvSheetHandler, 0, SEEK_END);
   FileWrite(csvSheetHandler, "totalBuyCost", "totalBuyVolume", "totalBuyCost / totalBuyVolume", "breakEvenTP");
   return (INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   // Release the Bollinger Bands indicator hande
   IndicatorRelease(Bb_Handle);
}
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   InitializeVariables();
   StrategyCheck_Entry();
   StrategyCheck_Exit();
}
//+------------------------------------------------------------------+
//| Function to execute trades                                        |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
void InitializeVariables() {
}

void StrategyCheck_Entry() {
   // ------------- getting info from indicator
   double upperBand[], lowerBand[], middleBand[];
   if(
       CopyBuffer(Bb_Handle, 0, 0, 1, upperBand) <= 0 ||
       CopyBuffer(Bb_Handle, 1, 0, 1, middleBand) <= 0 ||
       CopyBuffer(Bb_Handle, 2, 0, 1, lowerBand) <= 0) {
      Print("Error copying band values");
      return;
   }
   // getting variables
   double upper    = upperBand[0];
   double lower    = lowerBand[0];
   double middle   = middleBand[0];
   double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // looping for each position pairs
   for(int r = 0; r < ArrayRange(myTickets, 0); r++) {
      ulong longTicket  = myTickets[r][0];
      ulong shortTicket = myTickets[r][1];
      // if not hold position
      if(!longTicket && askPrice >= upper) {
         myTickets[r][0] = OpenInitialPosition(_Symbol, LotSize, 0);
         // fill another leg
         if(!shortTicket) {
            myTickets[r][1] = OpenInitialPosition(_Symbol, LotSize, 1);
         }
      }
      if(!shortTicket && bidPrice <= lower) {
         myTickets[r][1] = OpenInitialPosition(_Symbol, LotSize, 1);
         // fill another leg
         if(!longTicket) {
            myTickets[r][0] = OpenInitialPosition(_Symbol, LotSize, 0);
         }
      }
   }
}

// exit the positions
void StrategyCheck_Exit() {
   // looping for each position pairs
   for(int r = 0; r < ArrayRange(myTickets, 0); r++) {
      ulong longTicket  = myTickets[r][0];
      ulong shortTicket = myTickets[r][1];
      // check if position need to exit
      if(PositionSelectByTicket(longTicket) && PositionGetDouble(POSITION_PROFIT) >= TakeProfit) {
         // close position
         trade.PositionClose(longTicket, ULONG_MAX);
         // fill the leg
         myTickets[r][0] = OpenInitialPosition(_Symbol, LotSize, 0);
         Print("Take profit: ", DoubleToString(PositionGetDouble(POSITION_PROFIT)));
         Print("Filling the type ", PositionGetInteger(POSITION_TYPE), " leg at: ", PositionGetDouble(POSITION_PRICE_OPEN));
      } else if(PositionSelectByTicket(shortTicket) && PositionGetDouble(POSITION_PROFIT) >= TakeProfit) {
         // close position
         trade.PositionClose(shortTicket, ULONG_MAX);
         // fill the leg
         myTickets[r][1] = OpenInitialPosition(_Symbol, LotSize, 1);
         Print("Take profit: ", DoubleToString(PositionGetDouble(POSITION_PROFIT)));
         Print("Filling the type ", PositionGetInteger(POSITION_TYPE), " leg at: ", PositionGetDouble(POSITION_PRICE_OPEN));
      }
   }
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

double lotExp(int nr_buy_positions) {
   return 0.1 * exp(nr_buy_positions / 25) + 1;
}