//+------------------------------------------------------------------+
//|                  GRID-6-V2 - PROTECTION EDITION                 |
//|        Trend Grid + Recovery Exit + Equity Protection            |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//================ INPUT =================//
input group "=== ACCOUNT SAFETY ==="
input double MaxEquityLossPercent = 15.0;   // Hard trailing equity DD from peak
input double MaxCycleLossPercent  = 7.5;    // Max loss for one grid cycle
input int    MaxHoldingHours      = 24;     // Force-close stale cycles

input group "=== PROFIT ENGINE ==="
input bool   UseTrailingProfit = true;
input double TargetProfit      = 8.0;
input double TrailingStartUSD  = 8.0;
input double LockStep1         = 5.0;       // Peak >= 10 -> lock 5
input double LockStep2         = 10.0;      // Peak >= 15 -> lock 10
input double LockStep3         = 15.0;      // Peak >= 20 -> lock 15

input group "=== ENTRY ENGINE ==="
input int    MA_Period = 200;
input int    RSI_Period = 14;
input int    RSI_Upper = 70;
input int    RSI_Lower = 30;
input double RSI_Mid = 50.0;
input int    MinSecondsBetweenEntries = 300;

input group "=== GRID RECOVERY ==="
input bool   UseGridRecovery = true;
input int    GridDistance = 5000;            // points
input double LotSize = 0.02;
input int    MaxOrders = 12;
input bool   AddOnlyWithTrend = true;

input group "=== EXECUTION ==="
input ulong  Magic = 88888;
input int    DeviationPoints = 50;

//================ GLOBAL =================//
int maHandle = INVALID_HANDLE;
int rsiHandle = INVALID_HANDLE;

double BuyProfit = 0.0, SellProfit = 0.0;
int BuyCount = 0, SellCount = 0;

double MaxBuyProfit = 0.0;
double MaxSellProfit = 0.0;

datetime CycleStartTime = 0;
datetime LastEntryTime = 0;
double PeakEquity = 0.0;
bool TradingLocked = false;

//================ INIT =================//
int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   maHandle = iMA(_Symbol, _Period, MA_Period, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);

   if(maHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
   {
      Print("[INIT] Failed to create indicator handles. Error=", GetLastError());
      return INIT_FAILED;
   }

   PeakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   LoadCycleState();

   return INIT_SUCCEEDED;
}

//================ DEINIT =================//
void OnDeinit(const int reason)
{
   if(maHandle != INVALID_HANDLE)
      IndicatorRelease(maHandle);
   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);
}

//================ TICK =================//
void OnTick()
{
   UpdatePositions();

   if(CheckEquityStop())
      return;

   if(TradingLocked)
      return;

   if(BuyCount == 0 && SellCount == 0)
   {
      ResetCycleState();
      CheckEntry();
      return;
   }

   if(CheckCycleProtection())
      return;

   if(ManageExit())
      return;

   UpdatePositions();

   if(BuyCount > 0 || SellCount > 0)
      ManageGridRecovery();
}

//================ UPDATE POSITION =================//
void UpdatePositions()
{
   BuyProfit = 0.0;
   SellProfit = 0.0;
   BuyCount = 0;
   SellCount = 0;

   datetime oldest = 0;
   datetime newest = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(oldest == 0 || openTime < oldest)
         oldest = openTime;
      if(openTime > newest)
         newest = openTime;

      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      long type = PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY)
      {
         BuyProfit += profit;
         BuyCount++;
      }
      else if(type == POSITION_TYPE_SELL)
      {
         SellProfit += profit;
         SellCount++;
      }
   }

   if(oldest > 0)
   {
      if(CycleStartTime == 0 || CycleStartTime > oldest)
         CycleStartTime = oldest;
   }
   else
   {
      CycleStartTime = 0;
   }

   if(newest > 0 && LastEntryTime == 0)
      LastEntryTime = newest;
}

//================ ENTRY =================//
void CheckEntry()
{
   if(!CanOpenNewEntry())
      return;

   double ma = 0.0;
   double rsi = 0.0;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(!GetIndicators(ma, rsi))
      return;

   bool buySignal = (price > ma && rsi >= RSI_Mid && rsi < RSI_Upper);
   bool sellSignal = (price < ma && rsi <= RSI_Mid && rsi > RSI_Lower);

   if(buySignal)
   {
      if(OpenPosition(ORDER_TYPE_BUY, LotSize))
         StartCycle();
   }
   else if(sellSignal)
   {
      if(OpenPosition(ORDER_TYPE_SELL, LotSize))
         StartCycle();
   }
}

//================ GRID RECOVERY =================//
void ManageGridRecovery()
{
   if(!UseGridRecovery)
      return;

   if(BuyCount > 0 && SellCount > 0)
   {
      Print("[SAFETY] Both BUY and SELL positions detected. No grid expansion.");
      return;
   }

   if(BuyCount > 0)
   {
      if(BuyCount >= MaxOrders)
         return;
      if(!CanOpenNewEntry())
         return;
      if(AddOnlyWithTrend && !TrendAllows(POSITION_TYPE_BUY))
         return;

      double lastPrice = GetLatestOpenPrice(POSITION_TYPE_BUY);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double trigger = lastPrice - GridDistance * _Point;

      if(lastPrice > 0.0 && bid <= trigger)
         OpenPosition(ORDER_TYPE_BUY, LotSize);
   }
   else if(SellCount > 0)
   {
      if(SellCount >= MaxOrders)
         return;
      if(!CanOpenNewEntry())
         return;
      if(AddOnlyWithTrend && !TrendAllows(POSITION_TYPE_SELL))
         return;

      double lastPrice = GetLatestOpenPrice(POSITION_TYPE_SELL);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double trigger = lastPrice + GridDistance * _Point;

      if(lastPrice > 0.0 && ask >= trigger)
         OpenPosition(ORDER_TYPE_SELL, LotSize);
   }
}

//================ EXIT ENGINE =================//
bool ManageExit()
{
   if(BuyCount > 0)
   {
      if(BuyProfit > MaxBuyProfit)
         MaxBuyProfit = BuyProfit;

      if(TargetProfit > 0.0 && BuyProfit >= TargetProfit)
      {
         CloseType(POSITION_TYPE_BUY);
         return true;
      }

      double lock = GetLockLevel(MaxBuyProfit);
      if(UseTrailingProfit && lock > 0.0 && BuyProfit <= lock)
      {
         CloseType(POSITION_TYPE_BUY);
         return true;
      }
   }

   if(SellCount > 0)
   {
      if(SellProfit > MaxSellProfit)
         MaxSellProfit = SellProfit;

      if(TargetProfit > 0.0 && SellProfit >= TargetProfit)
      {
         CloseType(POSITION_TYPE_SELL);
         return true;
      }

      double lock = GetLockLevel(MaxSellProfit);
      if(UseTrailingProfit && lock > 0.0 && SellProfit <= lock)
      {
         CloseType(POSITION_TYPE_SELL);
         return true;
      }
   }

   return false;
}

//================ LOCK LOGIC =================//
double GetLockLevel(double maxProfit)
{
   if(maxProfit >= 20.0) return LockStep3;
   if(maxProfit >= 15.0) return LockStep2;
   if(maxProfit >= 10.0) return LockStep1;
   if(maxProfit >= TrailingStartUSD) return MathMax(0.0, TrailingStartUSD - 2.0);
   return 0.0;
}

//================ CYCLE PROTECTION =================//
bool CheckCycleProtection()
{
   double cycleProfit = BuyProfit + SellProfit;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(balance <= 0.0)
      return false;

   double maxLoss = balance * MaxCycleLossPercent / 100.0;
   if(maxLoss > 0.0 && cycleProfit <= -maxLoss)
   {
      PrintFormat("[CYCLE STOP] Cycle loss %.2f reached limit %.2f", cycleProfit, -maxLoss);
      CloseAllManaged();
      ResetCycleState();
      return true;
   }

   if(MaxHoldingHours > 0 && CycleStartTime > 0)
   {
      long heldSeconds = (long)(TimeCurrent() - CycleStartTime);
      if(heldSeconds >= (long)MaxHoldingHours * 3600)
      {
         PrintFormat("[TIME STOP] Cycle held %d hours. Closing cycle.", heldSeconds / 3600);
         CloseAllManaged();
         ResetCycleState();
         return true;
      }
   }

   return false;
}

//================ EQUITY STOP =================//
bool CheckEquityStop()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > PeakEquity)
      PeakEquity = equity;

   if(PeakEquity <= 0.0 || MaxEquityLossPercent <= 0.0)
      return false;

   double ddPercent = (PeakEquity - equity) / PeakEquity * 100.0;

   if(ddPercent >= MaxEquityLossPercent)
   {
      PrintFormat("[EQUITY STOP] Peak %.2f Equity %.2f DD %.2f%%", PeakEquity, equity, ddPercent);
      CloseAllManaged();
      TradingLocked = true;
      ResetCycleState();
      return true;
   }

   return false;
}

//================ ORDER HELPERS =================//
bool OpenPosition(ENUM_ORDER_TYPE type, double volume)
{
   volume = NormalizeVolume(volume);
   if(volume <= 0.0)
      return false;

   bool result = false;

   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(volume, _Symbol, 0.0, 0.0, 0.0, "GRID-6-V2 BUY");
   else if(type == ORDER_TYPE_SELL)
      result = trade.Sell(volume, _Symbol, 0.0, 0.0, 0.0, "GRID-6-V2 SELL");

   if(!result)
   {
      PrintFormat("[ORDER ERROR] type=%d retcode=%u %s", type, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }

   LastEntryTime = TimeCurrent();
   if(CycleStartTime == 0)
      CycleStartTime = TimeCurrent();

   return true;
}

//================ CLOSE =================//
void CloseType(long type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;

      if(!trade.PositionClose(ticket))
         PrintFormat("[CLOSE ERROR] ticket=%I64u retcode=%u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }

   if(type == POSITION_TYPE_BUY)
      MaxBuyProfit = 0.0;
   else if(type == POSITION_TYPE_SELL)
      MaxSellProfit = 0.0;
}

void CloseAllManaged()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(!trade.PositionClose(ticket))
         PrintFormat("[CLOSE ALL ERROR] ticket=%I64u retcode=%u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//================ INDICATORS =================//
bool GetIndicators(double &ma, double &rsi)
{
   double maBuffer[1];
   double rsiBuffer[1];

   if(CopyBuffer(maHandle, 0, 1, 1, maBuffer) != 1)
      return false;
   if(CopyBuffer(rsiHandle, 0, 1, 1, rsiBuffer) != 1)
      return false;

   ma = maBuffer[0];
   rsi = rsiBuffer[0];

   return (ma > 0.0 && rsi >= 0.0 && rsi <= 100.0);
}

bool TrendAllows(long type)
{
   double ma = 0.0;
   double rsi = 0.0;
   if(!GetIndicators(ma, rsi))
      return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(type == POSITION_TYPE_BUY)
      return (bid > ma);
   if(type == POSITION_TYPE_SELL)
      return (bid < ma);

   return false;
}

//================ POSITION HELPERS =================//
double GetLatestOpenPrice(long type)
{
   datetime latestTime = 0;
   double latestPrice = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openTime >= latestTime)
      {
         latestTime = openTime;
         latestPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }

   return latestPrice;
}

bool CanOpenNewEntry()
{
   if(TradingLocked)
      return false;

   if(MinSecondsBetweenEntries <= 0 || LastEntryTime == 0)
      return true;

   return ((long)(TimeCurrent() - LastEntryTime) >= MinSecondsBetweenEntries);
}

//================ CYCLE STATE =================//
void StartCycle()
{
   CycleStartTime = TimeCurrent();
   LastEntryTime = TimeCurrent();
   MaxBuyProfit = 0.0;
   MaxSellProfit = 0.0;
}

void ResetCycleState()
{
   MaxBuyProfit = 0.0;
   MaxSellProfit = 0.0;
   CycleStartTime = 0;
   // Keep LastEntryTime so a freshly closed cycle still respects entry cooldown.
}

void LoadCycleState()
{
   UpdatePositions();

   if(BuyCount == 0 && SellCount == 0)
      ResetCycleState();
   else if(CycleStartTime == 0)
      CycleStartTime = TimeCurrent();
}

//================ VOLUME =================//
double NormalizeVolume(double volume)
{
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      return 0.0;

   volume = MathMax(minVol, MathMin(maxVol, volume));
   volume = MathFloor(volume / step + 1e-8) * step;

   int digits = 0;
   double s = step;
   while(s < 1.0 && digits < 8)
   {
      s *= 10.0;
      digits++;
   }

   return NormalizeDouble(volume, digits);
}
//+------------------------------------------------------------------+
