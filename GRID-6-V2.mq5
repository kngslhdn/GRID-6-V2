//+------------------------------------------------------------------+
//| GRID-6-V2 PROTECTION ENGINE                                      |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

input group "=== ACCOUNT SAFETY ==="
input double MaxEquityLossPercent=15.0;
input double MaxCycleLossPercent=7.5;
input int MaxHoldingHours=24;
input int CooldownAfterStopMinutes=60;

input group "=== PROFIT ENGINE ==="
input bool UseTrailingProfit=true;
input double TrailingStartUSD=8.0;
input double LockStep1=5.0;
input double LockStep2=10.0;
input double LockStep3=15.0;
input bool UseHardTarget=false;
input double TargetProfit=8.0;

input group "=== ENTRY ENGINE ==="
input int MA_Period=200;
input int RSI_Period=14;
input int RSI_Upper=70;
input int RSI_Lower=30;
input double RSI_Mid=50.0;
input int MinSecondsBetweenEntries=300;
input int MaxSpreadPoints=0;

input group "=== GRID RECOVERY ==="
input bool UseGridRecovery=true;
input int GridDistance=5000;
input double LotSize=0.02;
input int MaxOrders=12;
input bool AddOnlyWithTrend=false;

input group "=== EXECUTION ==="
input ulong Magic=88888;
input int DeviationPoints=50;

int maHandle=INVALID_HANDLE;
int rsiHandle=INVALID_HANDLE;
double BuyProfit=0.0,SellProfit=0.0;
int BuyCount=0,SellCount=0;
double MaxBuyProfit=0.0,MaxSellProfit=0.0;
datetime CycleStartTime=0,LastEntryTime=0,NextEntryAllowed=0;
double PeakEquity=0.0;
bool TradingLocked=false;

int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   maHandle=iMA(_Symbol,_Period,MA_Period,0,MODE_EMA,PRICE_CLOSE);
   rsiHandle=iRSI(_Symbol,_Period,RSI_Period,PRICE_CLOSE);
   if(maHandle==INVALID_HANDLE || rsiHandle==INVALID_HANDLE)
   {
      Print("[INIT] Indicator handle creation failed. Error=",GetLastError());
      return INIT_FAILED;
   }
   PeakEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   UpdatePositions();
   if(BuyCount==0 && SellCount==0) ResetCycleState();
   else if(CycleStartTime==0) CycleStartTime=GetOldestOpenTime();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(maHandle!=INVALID_HANDLE) IndicatorRelease(maHandle);
   if(rsiHandle!=INVALID_HANDLE) IndicatorRelease(rsiHandle);
}

void OnTick()
{
   UpdatePositions();
   if(CheckEquityStop()) return;
   if(TradingLocked) return;
   if(BuyCount==0 && SellCount==0)
   {
      ResetCycleState();
      CheckEntry();
      return;
   }
   if(CheckCycleProtection()) return;
   if(ManageExit()) return;
   UpdatePositions();
   if((BuyCount>0 || SellCount>0) && UseGridRecovery) ManageGridRecovery();
}

void UpdatePositions()
{
   BuyProfit=0.0; SellProfit=0.0; BuyCount=0; SellCount=0;
   datetime oldest=0,newest=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      datetime t=(datetime)PositionGetInteger(POSITION_TIME);
      if(oldest==0 || t<oldest) oldest=t;
      if(newest==0 || t>newest) newest=t;
      double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      long type=PositionGetInteger(POSITION_TYPE);
      if(type==POSITION_TYPE_BUY){BuyProfit+=p;BuyCount++;}
      else if(type==POSITION_TYPE_SELL){SellProfit+=p;SellCount++;}
   }
   if(oldest>0)
   {
      if(CycleStartTime==0 || CycleStartTime>oldest) CycleStartTime=oldest;
      if(LastEntryTime==0 && newest>0) LastEntryTime=newest;
   }
   else CycleStartTime=0;
}

bool GetIndicators(double &ma,double &rsi)
{
   double a[1],b[1];
   if(CopyBuffer(maHandle,0,1,1,a)!=1) return false;
   if(CopyBuffer(rsiHandle,0,1,1,b)!=1) return false;
   ma=a[0]; rsi=b[0];
   return(ma>0.0 && rsi>=0.0 && rsi<=100.0);
}

void CheckEntry()
{
   if(!CanOpenNewEntry()) return;
   if(!SpreadOK()) return;
   double ma=0.0,rsi=0.0;
   if(!GetIndicators(ma,rsi)) return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   bool buy=(bid>ma && rsi>=RSI_Mid && rsi<RSI_Upper);
   bool sell=(bid<ma && rsi<=RSI_Mid && rsi>RSI_Lower);
   if(buy) OpenPosition(ORDER_TYPE_BUY,LotSize);
   else if(sell) OpenPosition(ORDER_TYPE_SELL,LotSize);
}

void ManageGridRecovery()
{
   if(BuyCount>0 && SellCount>0) return;
   if(BuyCount>0)
   {
      if(BuyCount>=MaxOrders || !CanOpenNewEntry()) return;
      if(AddOnlyWithTrend && !TrendAllows(POSITION_TYPE_BUY)) return;
      double last=GetLatestOpenPrice(POSITION_TYPE_BUY);
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      if(last>0.0 && bid<=last-GridDistance*_Point) OpenPosition(ORDER_TYPE_BUY,LotSize);
   }
   else if(SellCount>0)
   {
      if(SellCount>=MaxOrders || !CanOpenNewEntry()) return;
      if(AddOnlyWithTrend && !TrendAllows(POSITION_TYPE_SELL)) return;
      double last=GetLatestOpenPrice(POSITION_TYPE_SELL);
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      if(last>0.0 && ask>=last+GridDistance*_Point) OpenPosition(ORDER_TYPE_SELL,LotSize);
   }
}

bool ManageExit()
{
   if(BuyCount>0)
   {
      if(BuyProfit>MaxBuyProfit) MaxBuyProfit=BuyProfit;
      if(UseHardTarget && TargetProfit>0.0 && BuyProfit>=TargetProfit){CloseType(POSITION_TYPE_BUY);return true;}
      double lock=GetLockLevel(MaxBuyProfit);
      if(UseTrailingProfit && lock>0.0 && BuyProfit<=lock){CloseType(POSITION_TYPE_BUY);return true;}
   }
   if(SellCount>0)
   {
      if(SellProfit>MaxSellProfit) MaxSellProfit=SellProfit;
      if(UseHardTarget && TargetProfit>0.0 && SellProfit>=TargetProfit){CloseType(POSITION_TYPE_SELL);return true;}
      double lock=GetLockLevel(MaxSellProfit);
      if(UseTrailingProfit && lock>0.0 && SellProfit<=lock){CloseType(POSITION_TYPE_SELL);return true;}
   }
   return false;
}

// Lock is monotonic: 5 -> 10 -> 15 as profit peak grows.
double GetLockLevel(double peak)
{
   if(peak>=20.0) return LockStep3;
   if(peak>=15.0) return LockStep2;
   if(peak>=10.0) return LockStep1;
   if(peak>=TrailingStartUSD) return LockStep1;
   return 0.0;
}

bool CheckCycleProtection()
{
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance<=0.0) return false;
   double cycleProfit=BuyProfit+SellProfit;
   double limit=balance*MaxCycleLossPercent/100.0;
   if(limit>0.0 && cycleProfit<=-limit)
   {
      PrintFormat("[CYCLE STOP] P/L %.2f limit -%.2f",cycleProfit,limit);
      CloseAllManaged();
      NextEntryAllowed=TimeCurrent()+CooldownAfterStopMinutes*60;
      ResetCycleState();
      return true;
   }
   if(MaxHoldingHours>0 && CycleStartTime>0)
   {
      long held=(long)(TimeCurrent()-CycleStartTime);
      if(held>=(long)MaxHoldingHours*3600)
      {
         PrintFormat("[TIME STOP] Holding %d hours",held/3600);
         CloseAllManaged();
         NextEntryAllowed=TimeCurrent()+CooldownAfterStopMinutes*60;
         ResetCycleState();
         return true;
      }
   }
   return false;
}

bool CheckEquityStop()
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity>PeakEquity) PeakEquity=equity;
   if(PeakEquity<=0.0 || MaxEquityLossPercent<=0.0) return false;
   double dd=(PeakEquity-equity)/PeakEquity*100.0;
   if(dd>=MaxEquityLossPercent)
   {
      PrintFormat("[EQUITY STOP] Peak %.2f Equity %.2f DD %.2f%%",PeakEquity,equity,dd);
      CloseAllManaged();
      TradingLocked=true;
      ResetCycleState();
      return true;
   }
   return false;
}

bool OpenPosition(ENUM_ORDER_TYPE type,double volume)
{
   volume=NormalizeVolume(volume);
   if(volume<=0.0 || !SpreadOK()) return false;
   bool ok=false;
   if(type==ORDER_TYPE_BUY) ok=trade.Buy(volume,_Symbol,0.0,0.0,0.0,"GRID-6-V2 BUY");
   else if(type==ORDER_TYPE_SELL) ok=trade.Sell(volume,_Symbol,0.0,0.0,0.0,"GRID-6-V2 SELL");
   if(!ok)
   {
      PrintFormat("[ORDER ERROR] type=%d retcode=%u %s",type,trade.ResultRetcode(),trade.ResultRetcodeDescription());
      return false;
   }
   datetime now=TimeCurrent();
   LastEntryTime=now;
   if(CycleStartTime==0) CycleStartTime=now;
   return true;
}

void CloseType(long type)
{
   bool attempted=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE)!=type) continue;
      attempted=true;
      if(!trade.PositionClose(ticket)) PrintFormat("[CLOSE ERROR] %I64u %u %s",ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription());
   }
   if(attempted)
   {
      if(type==POSITION_TYPE_BUY) MaxBuyProfit=0.0;
      else MaxSellProfit=0.0;
   }
}

void CloseAllManaged()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(!trade.PositionClose(ticket)) PrintFormat("[CLOSE ALL ERROR] %I64u %u %s",ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription());
   }
}

bool TrendAllows(long type)
{
   double ma=0.0,rsi=0.0;
   if(!GetIndicators(ma,rsi)) return false;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(type==POSITION_TYPE_BUY) return bid>ma;
   if(type==POSITION_TYPE_SELL) return bid<ma;
   return false;
}

double GetLatestOpenPrice(long type)
{
   datetime latest=0;
   ulong latestTicket=0;
   double price=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE)!=type) continue;
      datetime t=(datetime)PositionGetInteger(POSITION_TIME);
      if(t>latest || (t==latest && ticket>latestTicket)){latest=t;latestTicket=ticket;price=PositionGetDouble(POSITION_PRICE_OPEN);}
   }
   return price;
}

datetime GetOldestOpenTime()
{
   datetime oldest=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      datetime t=(datetime)PositionGetInteger(POSITION_TIME);
      if(oldest==0 || t<oldest) oldest=t;
   }
   return oldest;
}

bool CanOpenNewEntry()
{
   if(TradingLocked) return false;
   if(TimeCurrent()<NextEntryAllowed) return false;
   if(MinSecondsBetweenEntries<=0 || LastEntryTime==0) return true;
   return((long)(TimeCurrent()-LastEntryTime)>=MinSecondsBetweenEntries);
}

bool SpreadOK()
{
   if(MaxSpreadPoints<=0) return true;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0.0 || bid<=0.0) return false;
   return((ask-bid)/_Point<=MaxSpreadPoints);
}

void ResetCycleState()
{
   MaxBuyProfit=0.0;
   MaxSellProfit=0.0;
   CycleStartTime=0;
}

double NormalizeVolume(double volume)
{
   double minVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0.0) return 0.0;
   volume=MathMax(minVol,MathMin(maxVol,volume));
   volume=MathFloor(volume/step+1e-8)*step;
   int digits=0; double s=step;
   while(s<1.0 && digits<8){s*=10.0;digits++;}
   return NormalizeDouble(volume,digits);
}
//+------------------------------------------------------------------+
