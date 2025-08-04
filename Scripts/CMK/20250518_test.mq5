//+------------------------------------------------------------------+
//|                                                20250518_test.mq5 |
//|                                  Copyright 2024, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#property script_show_inputs
//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
// enum
enum MarketType 
{
   BULLISH,
   BEARISH,
   SIDEWAYS
};
  
struct weekDay 
{
   int SUNDAY;
   int MONDAY;
   int TUESDAY;
   int WEDNESDAY;
   int THURSDAY;
   int FRIDAY;
   int SATURDAY;
};

// input (Must outside of OnStart())
input int stopLoss;

void OnStart()
  {
   // enum usage
   MarketType market = BULLISH;
  
  // storing the tick data
   MqlTick last_tick; // declare the MqlTick object first
   SymbolInfoTick(Symbol(), last_tick);
   
   // alert
   Alert("Hello World");
   
   // The predefined Variables
   Print(_Point);
   Print(_Symbol);
   
   // Ternary condition
   (10 > 5) ? Print("Condition Matched") : Print("Condition Not Matched");
   
   // switch case
   int variable = 1;
   switch(variable) 
   {
      case 1:
         Print("Expression matches case: ", variable);
         break;
      case 5:
         Print("Expression matches case: ", variable);
         break;
      case 10:
         Print("Expression matches case: ", variable);
         break;
      default:
         Print("No Expression matched.")
   }
  }
//+------------------------------------------------------------------+
// defined function
double StopLoss(string pTradingDirection, double pOpenPrice, int pStopLossPoints) {
   double stopLossPrice = 0;
   
   if (pTradingDirection == 'BUY') 
   {
      stopLossPrice = pOpenPrice - pStopLossPoints * _Point;
   }
   else if (pTradingDirection == 'SHORT')
   {
      stopLossPrice = pOpenPrice + pStopLossPoints * _Point;
   }
   return stopLossPrice;
}
//+------------------------------------------------------------------+
// Pre-defined function
//+------------------------------------------------------------------+
/*
Expert Advisor:
1. Preprocessor
2. MQL5 Event Handler
   eg: OnInit(), OnDeinit(), OnTick()

*/
 