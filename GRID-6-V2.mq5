//+------------------------------------------------------------------+
//| GRID-6-V2 - PROTECTION / PROFIT ENGINE                          |
//| Controlled Grid Recovery + Basket Exit + Equity Protection      |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//================ ACCOUNT SAFETY =================//
input group "=== ACCOUNT SAFETY ==="
input double MaxEquityLossPercent=15.0;
input double MaxCycleLossPercent=7.5;
input int MaxHoldingHours=24;
input int CooldownAfterStopMinutes=60;

//================ PROFIT ENGINE =================//
input group "=== PROFIT ENGINE ==="
input bool UseTrailingProfit=true;
input double TrailingStartUSD=8.0;
input double LockStep1=5.0;
input double LockStep2=10.0;
input double LockStep3=15.0;
input bool UseHardTarget=false;
input double TargetProfit=8.0;

//================ ENTRY ENGINE =================//
input group "=== ENTRY ENGINE ==="
input int MA_Period=200;
input int RSI_Period=14;
input int RSI_Upper=70;
input int RSI_Lower=30;
input double RSI_Mid=50.0;
input int MinSecondsBetweenEntries=300;
input int MaxSpreadPoints=0;

//================ GRID RECOVERY =================//
input group "=== GRID RECOVERY ==="
input bool UseGridRecovery=true;
input int GridDistance=5000;
input double LotSize=0.02;
input int MaxOrders=12;
input bool AddOnlyWithTrend=false;

//================ EXECUTION =================//
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

string StatePrefix()
{
   return "GRID6V2_"+IntegerToString((int)Magic)+"_"+_Symbol+"_";
}

//================ INIT =================//
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

   LoadPersistentState();
   UpdatePositions();
   if(BuyCount==0 && SellCount==0)
   {
      CycleStartTime=0;
      MaxBuyProfit=0.0;
      MaxSellProfit=0.0;
   }
   else if(CycleStartTime==0)
      CycleStartTime=GetOldestOpenTime();

   SavePersistentState();
   return INIT_SUCCEEDED;
}

//================ DEINIT =================//
void OnDeinit(const int reason)
{
   SavePersistentState();
   if(maHandle!=INVALID_HANDLE) IndicatorRelease(maHandle);
   if(rsiHandle!=INVALID_HANDLE) IndicatorRelease(rsiHandle);
}

//================ MAIN TICK =================//
void OnTick()
{
   UpdatePositions();
   if(CheckEquityStop()) return;
   if(TradingLocked) return;

   if(BuyCount==0 && SellCount==0)
   {
      ResetCyclePeaks();
      CheckEntry();
      return;
   }

   if(CheckCycleProtection()) return;

   // Exit before recovery; never add a grid order on the same tick as an exit.
   if(ManageExit())
   {
      UpdatePositions();
      SavePersistentState();
      return;
   }

   UpdatePositions();
   if(BuyCount>0 || SellCount>0) ManageGridRecovery();
   SavePersistentState();
}

//================ POSITION ACCOUNTING =================//
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

      datetime openTime=(datetime)PositionGetInteger(POSITION_TIME);
      if(oldest==0 || openTime<oldest) oldest=openTime;
      if(newest==0 || openTime>newest) newest=openTime;

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

//================ ENTRY =================//
void CheckEntry()
{
   if(!CanOpenNewEntry() || !SpreadOK()) return;

   double ma=0.0,rsi=0.0;
   if(!GetIndicators(ma,rsi)) return;

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(bid<=0.0) return;

   bool buySignal=(bid>ma && rsi>=RSI_Mid && rsi<RSI_Upper);
   bool sellSignal=(bid<ma && rsi<=RSI_Mid && rsi>RSI_Lower);

   if(buySignal) OpenPosition(ORDER_TYPE_BUY,LotSize);
   else if(sellSignal) OpenPosition(ORDER_TYPE_SELL,LotSize);
}

//================ GRID RECOVERY =================//
void ManageGridRecovery()
{
   if(!UseGridRecovery || GridDistance<=0 || MaxOrders<=1) return;
   if(BuyCount>0 && SellCount>0)
   {
      Print("[SAFETY] Mixed BUY/SELL basket detected. Grid expansion suspended.");
      return;
   }

   if(BuyCount>0)
   {
      if(BuyCount>=MaxOrders || !CanOpenNewEntry() || !SpreadOK()) return;
      if(AddOnlyWithTrend && !TrendAllows(POSITION_TYPE_BUY)) return;
      double last=GetLatestOpenPrice(POSITION_TYPE_BUY);
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      if(last>0.0 && bid>0.0 && bid<=last-GridDistance*_Point)
         OpenPosition(ORDER_TYPE_BUY,LotSize);
   }
   else if(SellCount>0)
   {
      if(SellCount>=MaxOrders || !CanOpenNewEntry() || !SpreadOK()) return;
      if(AddOnlyWithTrend && !TrendAllows(POSITION_TYPE_SELL)) return;
      double last=GetLatestOpenPrice(POSITION_TYPE_SELL);
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      if(last>0.0 && ask>0.0 && ask>=last+GridDistance*_Point)
         OpenPosition(ORDER_TYPE_SELL,LotSize);
   }
}

//================ EXIT ENGINE =================//
bool ManageExit()
{
   bool closed=false;

   if(BuyCount>0)
   {
      if(BuyProfit>MaxBuyProfit) MaxBuyProfit=BuyProfit;
      if(UseHardTarget && TargetProfit>0.0 && BuyProfit>=TargetProfit)
         closed=CloseType(POSITION_TYPE_BUY) || closed;
      else if(UseTrailingProfit)
      {
         double lock=GetLockLevel(MaxBuyProfit);
         if(lock>0.0 && BuyProfit<=lock)
            closed=CloseType(POSITION_TYPE_BUY) || closed;
      }
   }

   UpdatePositions();

   if(SellCount>0)
   {
      if(SellProfit>MaxSellProfit) MaxSellProfit=SellProfit;
      if(UseHardTarget && TargetProfit>0.0 && SellProfit>=TargetProfit)
         closed=CloseType(POSITION_TYPE_SELL) || closed;
      else if(UseTrailingProfit)
      {
         double lock=GetLockLevel(MaxSellProfit);
         if(lock>0.0 && SellProfit<=lock)
            closed=CloseType(POSITION_TYPE_SELL) || closed;
      }
   }
   return closed;
}

double GetLockLevel(double peak)
{
   if(peak>=20.0) return MathMax(LockStep3,LockStep2);
   if(peak>=15.0) return MathMax(LockStep2,LockStep1);
   if(peak>=TrailingStartUSD) return LockStep1;
   return 0.0;
}

//================ CYCLE PROTECTION =================//
bool CheckCycleProtection()
{
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance<=0.0) return false;

   double cycleProfit=BuyProfit+SellProfit;
   double maxLoss=balance*MaxCycleLossPercent/100.0;
   if(maxLoss>0.0 && cycleProfit<=-maxLoss)
   {
      PrintFormat("[CYCLE STOP] Floating P/L %.2f reached limit -%.2f",cycleProfit,maxLoss);
      bool closed=CloseAllManaged();
      if(closed) NextEntryAllowed=TimeCurrent()+CooldownAfterStopMinutes*60;
      ResetCyclePeaks();
      SavePersistentState();
      return true;
   }

   if(MaxHoldingHours>0 && CycleStartTime>0)
   {
      long held=(long)(TimeCurrent()-CycleStartTime);
      if(held>=(long)MaxHoldingHours*3600)
      {
         PrintFormat("[TIME STOP] Cycle held %d hours",held/3600);
         bool closed=CloseAllManaged();
         if(closed) NextEntryAllowed=TimeCurrent()+CooldownAfterStopMinutes*60;
         ResetCyclePeaks();
         SavePersistentState();
         return true;
      }
   }
   return false;
}

//================ EQUITY PROTECTION =================//
bool CheckEquityStop()
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity<=0.0) return false;
   if(PeakEquity<=0.0) PeakEquity=equity;
   if(equity>PeakEquity) PeakEquity=equity;
   if(MaxEquityLossPercent<=0.0) return false;

   double dd=(PeakEquity-equity)/PeakEquity*100.0;
   if(dd>=MaxEquityLossPercent)
   {
      PrintFormat("[EQUITY STOP] Peak %.2f Equity %.2f DD %.2f%%",PeakEquity,equity,dd);
      bool fullyClosed=CloseAllManaged();
      if(fullyClosed)
      {
         TradingLocked=true;
         NextEntryAllowed=TimeCurrent()+CooldownAfterStopMinutes*60;
      }
      SavePersistentState();
      return fullyClosed;
   }

   SavePersistentState();
   return false;
}

//================ ORDER EXECUTION =================//
bool OpenPosition(ENUM_ORDER_TYPE type,double volume)
{
   if(TradingLocked || !CanOpenNewEntry() || !SpreadOK()) return false;
   if(type==ORDER_TYPE_BUY && SellCount>0) return false;
   if(type==ORDER_TYPE_SELL && BuyCount>0) return false;
   if(MaxOrders>0 && type==ORDER_TYPE_BUY && BuyCount>=MaxOrders) return false;
   if(MaxOrders>0 && type==ORDER_TYPE_SELL && SellCount>=MaxOrders) return false;

   volume=NormalizeVolume(volume);
   if(volume<=0.0) return false;

   bool ok=false;
   if(type==ORDER_TYPE_BUY) ok=trade.Buy(volume,_Symbol,0.0,0.0,0.0,"GRID-6-V2 BUY");
   else if(type==ORDER_TYPE_SELL) ok=trade.Sell(volume,_Symbol,0.0,0.0,0.0,"GRID-6-V2 SELL");

   if(!ok)
   {
      PrintFormat("[ORDER ERROR] type=%d retcode=%u %s",type,trade.ResultRetcode(),trade.ResultRetcodeDescription());
      return false;
   }

   LastEntryTime=TimeCurrent();
   if(CycleStartTime==0) CycleStartTime=LastEntryTime;
   SavePersistentState();
   return true;
}

//================ CLOSE TYPE =================//
bool CloseType(long type)
{
   bool attempted=false;
   bool allSucceeded=true;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE)!=type) continue;

      attempted=true;
      if(!trade.PositionClose(ticket))
      {
         allSucceeded=false;
         PrintFormat("[CLOSE ERROR] ticket=%I64u retcode=%u %s",ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription());
      }
   }

   if(attempted && allSucceeded)
   {
      if(type==POSITION_TYPE_BUY) MaxBuyProfit=0.0;
      else MaxSellProfit=0.0;
   }
   return attempted;
}

//================ CLOSE ALL =================//
bool CloseAllManaged()
{
   bool attempted=false;
   bool allSucceeded=true;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;

      attempted=true;
      if(!trade.PositionClose(ticket))
      {
         allSucceeded=false;
         PrintFormat("[CLOSE ALL ERROR] ticket=%I64u retcode=%u %s",ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription());
      }
   }

   // Verify the actual terminal state. A successful request is not enough.
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      allSucceeded=false;
      break;
   }
   return(!attempted || allSucceeded);
}

//================ INDICATORS =================//
bool GetIndicators(double &ma,double &rsi)
{
   double a[1],b[1];
   if(CopyBuffer(maHandle,0,1,1,a)!=1) return false;
   if(CopyBuffer(rsiHandle,0,1,1,b)!=1) return false;
   ma=a[0]; rsi=b[0];
   return(ma>0.0 && rsi>=0.0 && rsi<=100.0);
}

bool TrendAllows(long type)
{
   double ma=0.0,rsi=0.0;
   if(!GetIndicators(ma,rsi)) return false;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(bid<=0.0) return false;
   if(type==POSITION_TYPE_BUY) return bid>ma;
   if(type==POSITION_TYPE_SELL) return bid<ma;
   return false;
}

//================ POSITION HELPERS =================//
double GetLatestOpenPrice(long type)
{
   datetime latestTime=0;
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
      if(t>latestTime || (t==latestTime && ticket>latestTicket))
      {
         latestTime=t;
         latestTicket=ticket;
         price=PositionGetDouble(POSITION_PRICE_OPEN);
      }
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

//================ CYCLE STATE =================//
void ResetCyclePeaks()
{
   MaxBuyProfit=0.0;
   MaxSellProfit=0.0;
   if(BuyCount==0 && SellCount==0) CycleStartTime=0;
}

//================ PERSISTENT STATE =================//
void LoadPersistentState()
{
   string p=StatePrefix();
   if(GlobalVariableCheck(p+"PeakEquity")) PeakEquity=GlobalVariableGet(p+"PeakEquity");
   if(GlobalVariableCheck(p+"TradingLocked")) TradingLocked=(GlobalVariableGet(p+"TradingLocked")>0.5);
   if(GlobalVariableCheck(p+"NextEntryAllowed")) NextEntryAllowed=(datetime)GlobalVariableGet(p+"NextEntryAllowed");
   if(GlobalVariableCheck(p+"LastEntryTime")) LastEntryTime=(datetime)GlobalVariableGet(p+"LastEntryTime");
   if(GlobalVariableCheck(p+"CycleStartTime")) CycleStartTime=(datetime)GlobalVariableGet(p+"CycleStartTime");
}

void SavePersistentState()
{
   string p=StatePrefix();
   GlobalVariableSet(p+"PeakEquity",PeakEquity);
   GlobalVariableSet(p+"TradingLocked",TradingLocked?1.0:0.0);
   GlobalVariableSet(p+"NextEntryAllowed",(double)NextEntryAllowed);
   GlobalVariableSet(p+"LastEntryTime",(double)LastEntryTime);
   GlobalVariableSet(p+"CycleStartTime",(double)CycleStartTime);
}

//================ VOLUME =================//
double NormalizeVolume(double volume)
{
   double minVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxVol=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0.0) return 0.0;

   volume=MathMax(minVol,MathMin(maxVol,volume));
   volume=MathFloor(volume/step+1e-8)*step;

   int digits=0;
   double s=step;
   while(s<1.0 && digits<8){s*=10.0;digits++;}
   return NormalizeDouble(volume,digits);
}
//+------------------------------------------------------------------+
