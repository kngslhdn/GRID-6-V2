//+------------------------------------------------------------------+
//|                  GRID SAFE 2026 - FINAL CLEAN                    |
//|        Fix MT5 + Step Trailing Lock Profit + Stable              |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//================ INPUT =================//

input group "=== SAFETY ==="
input double MaxEquityLossPercent = 15;

input group "=== TRAILING PROFIT ==="
input bool   UseTrailingProfit = true;
input double TrailingStartUSD = 8.0;
input double LockStep1 = 5.0;   // profit 10 → lock 5
input double LockStep2 = 10.0;  // profit 15 → lock 10
input double LockStep3 = 15.0;  // profit 20 → lock 15

input group "=== INDICATOR ==="
input int MA_Period = 200;
input int RSI_Period = 14;
input int RSI_Upper = 70;
input int RSI_Lower = 30;

input group "=== GRID ==="
input int    GridDistance = 5000;
input double LotSize = 0.02;
input int    MaxOrders = 12;
input double TargetProfit = 8.0;
input ulong  Magic = 88888;

//================ GLOBAL =================//

double BuyProfit=0, SellProfit=0;
int BuyCount=0, SellCount=0;

double MaxBuyProfit=0;
double MaxSellProfit=0;

//================ INIT =================//

int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   return(INIT_SUCCEEDED);
}

//================ TICK =================//

void OnTick()
{
   UpdatePositions();

   if(CheckEquityStop()) return;

   CheckEntry();

   ManageExit();
}

//================ UPDATE POSITION =================//

void UpdatePositions()
{
   BuyProfit=0;
   SellProfit=0;
   BuyCount=0;
   SellCount=0;

   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);

      if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic)
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      long type = PositionGetInteger(POSITION_TYPE);

      if(type==POSITION_TYPE_BUY)
      {
         BuyProfit += profit;
         BuyCount++;
      }
      else if(type==POSITION_TYPE_SELL)
      {
         SellProfit += profit;
         SellCount++;
      }
   }
}

//================ ENTRY =================//

void CheckEntry()
{
   if(BuyCount==0 && SellCount==0)
   {
      double ma = iMA(_Symbol,_Period,MA_Period,0,MODE_EMA,PRICE_CLOSE);
      double rsi = iRSI(_Symbol,_Period,RSI_Period,PRICE_CLOSE);

      double price = SymbolInfoDouble(_Symbol,SYMBOL_BID);

      if(price > ma && rsi < RSI_Upper)
         trade.Buy(LotSize,_Symbol);

      if(price < ma && rsi > RSI_Lower)
         trade.Sell(LotSize,_Symbol);
   }
}

//================ EXIT =================//

void ManageExit()
{
   // ===== BUY SIDE =====
   if(BuyCount > 0)
   {
      if(BuyProfit > MaxBuyProfit)
         MaxBuyProfit = BuyProfit;

      double lock = GetLockLevel(MaxBuyProfit);

      if(UseTrailingProfit && lock > 0)
      {
         if(BuyProfit <= lock)
         {
            CloseType(POSITION_TYPE_BUY);
            MaxBuyProfit = 0;
         }
      }
      else
      {
         if(BuyProfit >= TargetProfit)
         {
            CloseType(POSITION_TYPE_BUY);
            MaxBuyProfit = 0;
         }
      }
   }

   // ===== SELL SIDE =====
   if(SellCount > 0)
   {
      if(SellProfit > MaxSellProfit)
         MaxSellProfit = SellProfit;

      double lock = GetLockLevel(MaxSellProfit);

      if(UseTrailingProfit && lock > 0)
      {
         if(SellProfit <= lock)
         {
            CloseType(POSITION_TYPE_SELL);
            MaxSellProfit = 0;
         }
      }
      else
      {
         if(SellProfit >= TargetProfit)
         {
            CloseType(POSITION_TYPE_SELL);
            MaxSellProfit = 0;
         }
      }
   }
}

//================ LOCK LOGIC =================//

double GetLockLevel(double maxProfit)
{
   if(maxProfit >= 20) return LockStep3;
   if(maxProfit >= 15) return LockStep2;
   if(maxProfit >= 10) return LockStep1;
   if(maxProfit >= TrailingStartUSD) return TrailingStartUSD - 2.0;

   return 0;
}

//================ CLOSE =================//

void CloseType(long type)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket = PositionGetTicket(i);

      if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic)
         continue;

      if(PositionGetInteger(POSITION_TYPE)==type)
         trade.PositionClose(ticket);
   }
}

//================ EQUITY STOP =================//

bool CheckEquityStop()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   double dd = (balance - equity) / balance * 100.0;

   if(dd >= MaxEquityLossPercent)
   {
      CloseAll();
      return true;
   }

   return false;
}

void CloseAll()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket = PositionGetTicket(i);
      trade.PositionClose(ticket);
   }
}
