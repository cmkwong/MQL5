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
input int    TakeProfit       = 400;
input int    StopLoss         = 150;
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
   StrategyCheck_FirstLeg_Exit();
   StrategyCheck_SecondLeg_Exit();
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
   // getting indicator parameter
   double upper    = upperBand[0];
   double lower    = lowerBand[0];
   double middle   = middleBand[0];
   double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // looping for each position pairs
   for(int r = 0; r < ArrayRange(myTickets, 0); r++) {
      ulong longTicket  = myTickets[r][0];
      ulong shortTicket = myTickets[r][1];
      // if not hold position for both pair
      if(!longTicket && !shortTicket) {
         if(askPrice >= upper) {
            myTickets[r][0] = OpenInitialPosition(_Symbol, LotSize, 0);
            // fill another leg
            if(!shortTicket) {
               myTickets[r][1] = OpenInitialPosition(_Symbol, LotSize, 1);
            }
         } else if(bidPrice <= lower) {
            myTickets[r][1] = OpenInitialPosition(_Symbol, LotSize, 1);
            // fill another leg
            if(!longTicket) {
               myTickets[r][0] = OpenInitialPosition(_Symbol, LotSize, 0);
            }
         }
      }
   }
}

// exit the first leg positions
void StrategyCheck_FirstLeg_Exit() {
   // looping for each position pairs
   for(int r = 0; r < ArrayRange(myTickets, 0); r++) {
      ulong longTicket  = myTickets[r][0];
      ulong shortTicket = myTickets[r][1];
      if(!longTicket || !shortTicket) {
         continue;
      }
      // check if position need to exit
      if(PositionSelectByTicket(longTicket) && PositionGetDouble(POSITION_PROFIT) >= TakeProfit) {
         // close position
         trade.PositionClose(longTicket, ULONG_MAX);
         Print("Take profit: ", DoubleToString(PositionGetDouble(POSITION_PROFIT)));
         // fill the leg
         myTickets[r][0] = false;
         // Print("Filling the type ", PositionGetInteger(POSITION_TYPE), " leg at: ", PositionGetDouble(POSITION_PRICE_OPEN));
      } else if(PositionSelectByTicket(shortTicket) && PositionGetDouble(POSITION_PROFIT) >= TakeProfit) {
         // close position
         trade.PositionClose(shortTicket, ULONG_MAX);
         Print("Take profit: ", DoubleToString(PositionGetDouble(POSITION_PROFIT)));
         // fill the leg
         myTickets[r][1] = false;
         // Print("Filling the type ", PositionGetInteger(POSITION_TYPE), " leg at: ", PositionGetDouble(POSITION_PRICE_OPEN));
      }
   }
}

// exit the first leg positions
void StrategyCheck_SecondLeg_Exit() {
   // ------------- getting info from indicator
   double upperBand[], lowerBand[], middleBand[];
   if(
       CopyBuffer(Bb_Handle, 0, 0, 1, upperBand) <= 0 ||
       CopyBuffer(Bb_Handle, 1, 0, 1, middleBand) <= 0 ||
       CopyBuffer(Bb_Handle, 2, 0, 1, lowerBand) <= 0) {
      Print("Error copying band values");
      return;
   }
   // getting indicator parameter
   double upper    = upperBand[0];
   double lower    = lowerBand[0];
   double middle   = middleBand[0];
   double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   // MqlTick tick;
   // SymbolInfoTick(_Symbol, tick);
   // double tick_askPrice            = tick.ask;
   // double tick_bidPrice            = tick.bid;
   // Print("Different ask price: askPrice / tick_askPrice: ", askPrice, " / ", askPrice);
   // Print("Different ask price: bidPrice / tick_bidPrice: ", bidPrice, " / ", bidPrice);

   // looping for each position pairs
   for(int r = 0; r < ArrayRange(myTickets, 0); r++) {
      ulong longTicket  = myTickets[r][0];
      ulong shortTicket = myTickets[r][1];
      // only one leg in pair will be executed
      if(longTicket && shortTicket) {
         continue;
      }
      // long ticket left
      if(longTicket && PositionSelectByTicket(longTicket)) {
         if(bidPrice >= upper || PositionGetDouble(POSITION_PROFIT) <= -StopLoss) {
            trade.PositionClose(longTicket, ULONG_MAX);
            myTickets[r][0] = false;
         }
         // short ticket left
      } else if(shortTicket && PositionSelectByTicket(shortTicket)) {
         if(askPrice <= lower || PositionGetDouble(POSITION_PROFIT) <= -StopLoss) {
            trade.PositionClose(shortTicket, ULONG_MAX);
            myTickets[r][1] = false;
         }
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