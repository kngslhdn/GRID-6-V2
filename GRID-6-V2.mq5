// Expert Advisor: GRID 06.V02 - TREND & RISK EDITION 2026
// Regime-aligned directional entries + ATR risk sizing + protected runner exits
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "7.00"

#include <Trade/Trade.mqh>
CTrade trade;

enum Type {Open_Buy_And_Sell, Open__Only_Buy, Open__Only_Sell};

//--- Safety / account risk
input string SafeParameters          = "||========== SAFETY & RISK ==========||";
input double RiskPerTradePercent     = 0.40;
input double MaxRiskPerTradePercent  = 0.60;
input double MaxEquityLossPercent    = 12.0;
input double MaxDailyLossPercent     = 3.0;
input int    MaxConsecutiveLosses    = 3;
input int    CooldownMinutes         = 60;

//--- Regime / trend engine
input string RegimeSettings           = "||========== REGIME ENGINE ==========||";
input bool   UseRegimeFilter          = true;
input ENUM_TIMEFRAMES RegimeTF        = PERIOD_H1;
input int    FastMAPeriod             = 50;
input int    SlowMAPeriod             = 200;
input int    ADXPeriod                = 14;
input double ADXMinTrend              = 20.0;
input double ADXStrongTrend           = 25.0;
input bool   AllowRangeTrading        = false;

//--- Entry engine
input string EntrySettings            = "||========== ENTRY ENGINE ==========||";
input ENUM_TIMEFRAMES EntryTF         = PERIOD_M15;
input int    BreakoutLookback         = 12;
input int    PullbackMAPeriod         = 20;
input int    RSIPeriod                = 14;
input double BuyRSIMin                = 45.0;
input double BuyRSIMax                = 68.0;
input double SellRSIMin               = 32.0;
input double SellRSIMax               = 55.0;
input double MinBodyATR               = 0.25;

//--- Volatility / sizing
input string VolatilitySettings       = "||========== ATR / POSITION SIZING ==========||";
input int    ATRPeriod                = 14;
input double InitialSL_ATR            = 1.80;
input double MinSL_ATR                = 1.35;
input double MaxSL_ATR                = 2.60;
input double MinATRPrice              = 0.30;
input double MaxSpreadATRPercent      = 12.0;
input double MaxLotSize               = 0.20;

//--- Trade management
input string ExitSettings             = "||========== TRADE MANAGEMENT ==========||";
input double BreakEven_R              = 1.00;
input double BreakEvenLock_R          = 0.05;
input double ProfitLock_R             = 1.50;
input double ProfitLockValue_R        = 0.75;
input double RunnerStart_R            = 2.00;
input double RunnerATRMultiplier      = 2.20;
input double MaxTradeHours            = 18.0;
input double StaleTradeHours          = 4.0;
input double StaleMinR                = 0.20;

//--- Trading hours
input string TradingHourSettings      = "||========== TRADING HOURS ==========||";
input bool   UseTradingHour           = true;
input int    StartHour                = 7;
input int    EndHour                  = 22;

//--- General
input Type   TypeOrdersPlace          = Open_Buy_And_Sell;
input int    MagicNumber              = 88888;
input string CommentsOrders           = "GRID V7 TREND";

string SymbolTrade;
int OrdersID, HandleFastMA, HandleSlowMA, HandleADX, HandleATR, HandleRSI, HandleEntryMA;
datetime LastEntryTime = 0;
datetime DayStartTime = 0;
double DayStartBalance = 0;
int ConsecutiveLosses = 0;
double HighWaterMark = 0;
bool IsTerminated = false;

bool IsTradingHour()
{
   if(!UseTradingHour) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(StartHour < EndHour) return dt.hour >= StartHour && dt.hour < EndHour;
   return dt.hour >= StartHour || dt.hour < EndHour;
}

void ResetDailyState()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   datetime d=StructToTime(dt);
   if(DayStartTime!=d)
   {
      DayStartTime=d;
      DayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
      ConsecutiveLosses=0;
   }
}

bool GetBufferValue(int handle,int shift,double &value)
{
   double b[]; ArraySetAsSeries(b,true);
   if(handle==INVALID_HANDLE) return false;
   if(CopyBuffer(handle,0,shift,1,b)<1) return false;
   value=b[0]; return true;
}

double GetATR(ENUM_TIMEFRAMES tf=PERIOD_CURRENT,int shift=1)
{
   int h = (tf==EntryTF ? HandleATR : INVALID_HANDLE);
   if(h==INVALID_HANDLE)
   {
      h=iATR(SymbolTrade,tf,ATRPeriod);
      if(h==INVALID_HANDLE) return 0.0;
      double v=0; bool ok=GetBufferValue(h,shift,v); IndicatorRelease(h); return ok?v:0.0;
   }
   double v=0; return GetBufferValue(h,shift,v)?v:0.0;
}

double HighestHigh(int bars,int start)
{
   double hi=-DBL_MAX;
   for(int i=start;i<start+bars;i++) hi=MathMax(hi,iHigh(SymbolTrade,EntryTF,i));
   return hi;
}

double LowestLow(int bars,int start)
{
   double lo=DBL_MAX;
   for(int i=start;i<start+bars;i++) lo=MathMin(lo,iLow(SymbolTrade,EntryTF,i));
   return lo;
}

int RegimeDirection()
{
   double fast,slow,adx,plusDI,minusDI;
   if(!GetBufferValue(HandleFastMA,1,fast) || !GetBufferValue(HandleSlowMA,1,slow)) return 0;
   if(!GetBufferValue(HandleADX,1,adx)) return 0;
   double di[]; ArraySetAsSeries(di,true);
   if(CopyBuffer(HandleADX,1,1,1,di)<1) return 0; plusDI=di[0];
   if(CopyBuffer(HandleADX,2,1,1,di)<1) return 0; minusDI=di[0];
   double price=iClose(SymbolTrade,RegimeTF,1);
   if(price<=0) return 0;
   if(adx<ADXMinTrend)
      return AllowRangeTrading ? 0 : 99;
   if(price>fast && fast>slow && plusDI>minusDI) return 1;
   if(price<fast && fast<slow && minusDI>plusDI) return -1;
   return 99;
}

bool SpreadOK(double atr)
{
   if(atr<=0) return false;
   double spread=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK)-SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   return spread <= atr*(MaxSpreadATRPercent/100.0);
}

double NormalizeVolume(double lots)
{
   double minLot=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_STEP);
   double cap=MathMin(MaxLotSize,maxLot);
   lots=MathMin(lots,cap);
   if(step<=0) return NormalizeDouble(MathMax(minLot,lots),2);
   lots=MathFloor(lots/step)*step;
   return NormalizeDouble(MathMax(minLot,lots),2);
}

double CalculateLot(double stopDistance)
{
   if(stopDistance<=0) return 0;
   double riskPct=MathMin(RiskPerTradePercent,MaxRiskPerTradePercent);
   if(ConsecutiveLosses>=2) riskPct*=0.50;
   double riskMoney=AccountInfoDouble(ACCOUNT_EQUITY)*riskPct/100.0;
   double tickSize=SymbolInfoDouble(SymbolTrade,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(SymbolTrade,SYMBOL_TRADE_TICK_VALUE);
   if(tickSize<=0 || tickValue<=0) return NormalizeVolume(SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MIN));
   double lossPerLot=(stopDistance/tickSize)*tickValue;
   if(lossPerLot<=0) return NormalizeVolume(SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MIN));
   return NormalizeVolume(riskMoney/lossPerLot);
}

bool DailyRiskBlocked()
{
   if(DayStartBalance<=0) return true;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double dd=((DayStartBalance-eq)/DayStartBalance)*100.0;
   return dd>=MaxDailyLossPercent || ConsecutiveLosses>=MaxConsecutiveLosses;
}

bool HasOpenPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) &&
         PositionGetInteger(POSITION_MAGIC)==OrdersID &&
         PositionGetString(POSITION_SYMBOL)==SymbolTrade)
         return true;
   }
   return false;
}

ulong FindOurPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) &&
         PositionGetInteger(POSITION_MAGIC)==OrdersID &&
         PositionGetString(POSITION_SYMBOL)==SymbolTrade)
         return ticket;
   }
   return 0;
}

bool PlaceDirectionalTrade(int direction)
{
   if(direction==0 || direction==99 || HasOpenPosition()) return false;
   if(DailyRiskBlocked() || !IsTradingHour()) return false;
   if(TimeCurrent()-LastEntryTime<CooldownMinutes*60) return false;
   if(TypeOrdersPlace==Open__Only_Buy && direction<0) return false;
   if(TypeOrdersPlace==Open__Only_Sell && direction>0) return false;

   double atr=GetATR(EntryTF,1);
   if(atr<MinATRPrice || !SpreadOK(atr)) return false;

   double close1=iClose(SymbolTrade,EntryTF,1);
   double open1=iOpen(SymbolTrade,EntryTF,1);
   double body=MathAbs(close1-open1);
   if(body<atr*MinBodyATR) return false;

   double hi=HighestHigh(BreakoutLookback,2);
   double lo=LowestLow(BreakoutLookback,2);
   double entry=(direction>0)?SymbolInfoDouble(SymbolTrade,SYMBOL_ASK):SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   if(direction>0 && close1<=hi) return false;
   if(direction<0 && close1>=lo) return false;

   double rsi; if(!GetBufferValue(HandleRSI,1,rsi)) return false;
   if(direction>0 && (rsi<BuyRSIMin || rsi>BuyRSIMax)) return false;
   if(direction<0 && (rsi<SellRSIMin || rsi>SellRSIMax)) return false;

   double entryMA; if(!GetBufferValue(HandleEntryMA,1,entryMA)) return false;
   if(direction>0 && close1<entryMA) return false;
   if(direction<0 && close1>entryMA) return false;

   double slDist=MathMax(MinSL_ATR*atr,MathMin(MaxSL_ATR*atr,InitialSL_ATR*atr));
   double sl=(direction>0)?entry-slDist:entry+slDist;
   double lots=CalculateLot(slDist);
   if(lots<=0) return false;

   trade.SetExpertMagicNumber(OrdersID);
   trade.SetDeviationInPoints(20);
   bool ok=(direction>0)?trade.Buy(lots,SymbolTrade,entry,sl,0,CommentsOrders):trade.Sell(lots,SymbolTrade,entry,sl,0,CommentsOrders);
   if(ok) LastEntryTime=TimeCurrent();
   return ok;
}

void ManageOpenPosition()
{
   ulong ticket=FindOurPosition();
   if(ticket==0) return;
   if(!PositionSelectByTicket(ticket)) return;

   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double open=PositionGetDouble(POSITION_PRICE_OPEN);
   double sl=PositionGetDouble(POSITION_SL);
   double price=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(SymbolTrade,SYMBOL_BID):SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   double riskDistance=MathAbs(open-sl);
   if(riskDistance<=0) return;
   double r=(type==POSITION_TYPE_BUY)?(price-open)/riskDistance:(open-price)/riskDistance;
   double atr=GetATR(EntryTF,1);
   datetime openTime=(datetime)PositionGetInteger(POSITION_TIME);
   double ageH=(double)(TimeCurrent()-openTime)/3600.0;

   if(ageH>=MaxTradeHours)
   {
      trade.PositionClose(ticket); return;
   }
   if(ageH>=StaleTradeHours && r<StaleMinR)
   {
      int regime=RegimeDirection();
      if((type==POSITION_TYPE_BUY && regime<=0) || (type==POSITION_TYPE_SELL && regime>=0))
      {
         trade.PositionClose(ticket); return;
      }
   }

   double newSL=sl;
   if(r>=BreakEven_R)
   {
      double lock=type==POSITION_TYPE_BUY?open+riskDistance*BreakEvenLock_R:open-riskDistance*BreakEvenLock_R;
      if((type==POSITION_TYPE_BUY && (sl==0 || lock>newSL)) || (type==POSITION_TYPE_SELL && (sl==0 || lock<newSL))) newSL=lock;
   }
   if(r>=ProfitLock_R)
   {
      double lock=type==POSITION_TYPE_BUY?open+riskDistance*ProfitLockValue_R:open-riskDistance*ProfitLockValue_R;
      if((type==POSITION_TYPE_BUY && lock>newSL) || (type==POSITION_TYPE_SELL && lock<newSL)) newSL=lock;
   }
   if(r>=RunnerStart_R && atr>0)
   {
      double trail=type==POSITION_TYPE_BUY?price-RunnerATRMultiplier*atr:price+RunnerATRMultiplier*atr;
      if((type==POSITION_TYPE_BUY && trail>newSL) || (type==POSITION_TYPE_SELL && trail<newSL)) newSL=trail;
   }

   double point=SymbolInfoDouble(SymbolTrade,SYMBOL_POINT);
   int digits=(int)SymbolInfoInteger(SymbolTrade,SYMBOL_DIGITS);
   if(type==POSITION_TYPE_BUY && newSL>0 && newSL>sl+point) trade.PositionModify(ticket,NormalizeDouble(newSL,digits),0);
   if(type==POSITION_TYPE_SELL && newSL>0 && (sl==0 || newSL<sl-point)) trade.PositionModify(ticket,NormalizeDouble(newSL,digits),0);
}

void UpdateClosedTradeStats()
{
   static datetime lastScan=0;
   datetime from=lastScan>0?lastScan:DayStartTime;
   if(from<=0) from=TimeCurrent()-86400*30;
   if(!HistorySelect(from,TimeCurrent())) return;
   int total=HistoryDealsTotal();
   for(int i=total-1;i>=0;i--)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0) continue;
      if((long)HistoryDealGetInteger(deal,DEAL_MAGIC)!=OrdersID) continue;
      if(HistoryDealGetString(deal,DEAL_SYMBOL)!=SymbolTrade) continue;
      datetime t=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);
      if(t<=lastScan) break;
      long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
      {
         double p=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_COMMISSION);
         if(p<0) ConsecutiveLosses++; else if(p>0) ConsecutiveLosses=0;
      }
      if(t>lastScan) lastScan=t;
   }
}

int OnInit()
{
   SymbolTrade=_Symbol;
   OrdersID=(MagicNumber==0)?101010:MagicNumber;
   trade.SetExpertMagicNumber(OrdersID);
   HandleFastMA=iMA(SymbolTrade,RegimeTF,FastMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   HandleSlowMA=iMA(SymbolTrade,RegimeTF,SlowMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   HandleADX=iADX(SymbolTrade,RegimeTF,ADXPeriod);
   HandleATR=iATR(SymbolTrade,EntryTF,ATRPeriod);
   HandleRSI=iRSI(SymbolTrade,EntryTF,RSIPeriod,PRICE_CLOSE);
   HandleEntryMA=iMA(SymbolTrade,EntryTF,PullbackMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   DayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   HighWaterMark=DayStartBalance;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); dt.hour=0;dt.min=0;dt.sec=0;DayStartTime=StructToTime(dt);
   if(HandleFastMA==INVALID_HANDLE || HandleSlowMA==INVALID_HANDLE || HandleADX==INVALID_HANDLE || HandleATR==INVALID_HANDLE || HandleRSI==INVALID_HANDLE || HandleEntryMA==INVALID_HANDLE)
      return INIT_FAILED;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(HandleFastMA!=INVALID_HANDLE) IndicatorRelease(HandleFastMA);
   if(HandleSlowMA!=INVALID_HANDLE) IndicatorRelease(HandleSlowMA);
   if(HandleADX!=INVALID_HANDLE) IndicatorRelease(HandleADX);
   if(HandleATR!=INVALID_HANDLE) IndicatorRelease(HandleATR);
   if(HandleRSI!=INVALID_HANDLE) IndicatorRelease(HandleRSI);
   if(HandleEntryMA!=INVALID_HANDLE) IndicatorRelease(HandleEntryMA);
   Comment("");
}

void OnTick()
{
   if(IsTerminated) return;
   ResetDailyState();
   UpdateClosedTradeStats();

   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance>HighWaterMark) HighWaterMark=balance;
   double dd=HighWaterMark>0?((HighWaterMark-equity)/HighWaterMark)*100.0:0;
   if(dd>=MaxEquityLossPercent)
   {
      ulong t=FindOurPosition(); if(t>0) trade.PositionClose(t);
      IsTerminated=true; return;
   }

   ManageOpenPosition();
   if(HasOpenPosition()) return;

   if(!UseTradingHour || IsTradingHour())
   {
      int regime=UseRegimeFilter?RegimeDirection():0;
      if(regime==99) return;
      if(regime==1) PlaceDirectionalTrade(1);
      if(regime==-1) PlaceDirectionalTrade(-1);
   }

   Comment("GRID 6 V2 | v7.00\n",
           "Balance: ",DoubleToString(balance,2)," Equity: ",DoubleToString(equity,2),"\n",
           "DD: ",DoubleToString(dd,2),"%  Consecutive Losses: ",ConsecutiveLosses,"\n",
           "Regime: ",RegimeDirection());
}
