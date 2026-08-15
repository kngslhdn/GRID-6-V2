// Expert Advisor: GRID 06.V02 - TREND & RISK EDITION 2026
// v7.10 - Risk Guard + Directional Asymmetry + Fixed-R Exit Engine
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "7.10"

#include <Trade/Trade.mqh>
CTrade trade;

enum Type {Open_Buy_And_Sell, Open__Only_Buy, Open__Only_Sell};

input string SafeParameters          = "||========== SAFETY & RISK ==========||";
input double RiskPerTradePercent     = 0.40;
input double MaxRiskPerTradePercent  = 0.60;
input double MaxEquityLossPercent    = 12.0;
input double MaxDailyLossPercent     = 3.0;
input int    MaxConsecutiveLosses    = 3;
input int    CooldownMinutes         = 60;

input string RegimeSettings          = "||========== REGIME ENGINE ==========||";
input bool   UseRegimeFilter         = true;
input ENUM_TIMEFRAMES RegimeTF       = PERIOD_H1;
input int    FastMAPeriod            = 50;
input int    SlowMAPeriod            = 200;
input int    ADXPeriod               = 14;
input double ADXMinTrend             = 20.0;
input double ADXStrongTrend          = 25.0;
input double SellExtraADX            = 25.0;
input bool   RequireADXExpansion     = true;
input bool   AllowRangeTrading       = false;

input string EntrySettings           = "||========== ENTRY ENGINE ==========||";
input ENUM_TIMEFRAMES EntryTF        = PERIOD_M15;
input int    BreakoutLookback        = 12;
input double BreakoutBufferATR       = 0.10;
input int    PullbackMAPeriod        = 20;
input int    RSIPeriod               = 14;
input double BuyRSIMin               = 45.0;
input double BuyRSIMax               = 68.0;
input double SellRSIMin              = 32.0;
input double SellRSIMax              = 55.0;
input double MinBodyATR              = 0.35;

input string VolatilitySettings      = "||========== ATR / POSITION SIZING ==========||";
input int    ATRPeriod               = 14;
input double InitialSL_ATR           = 1.80;
input double MinSL_ATR               = 1.35;
input double MaxSL_ATR               = 2.60;
input double MinATRPrice             = 0.30;
input double MaxSpreadATRPercent     = 12.0;
input double MaxLotSize              = 0.20;
input bool   RejectIfMinLotOverRisk  = true;

input string ExitSettings            = "||========== TRADE MANAGEMENT ==========||";
input double BreakEven_R             = 1.20;
input double BreakEvenLock_R         = 0.05;
input double ProfitLock_R             = 2.00;
input double ProfitLockValue_R       = 0.75;
input double RunnerStart_R            = 2.50;
input double RunnerATRMultiplier      = 2.40;
input double MaxTradeHours            = 18.0;
input double StaleTradeHours          = 4.0;
input double StaleMinR                = 0.20;

input string TradingHourSettings      = "||========== TRADING HOURS ==========||";
input bool   UseTradingHour           = true;
input int    StartHour                = 7;
input int    EndHour                  = 22;

input Type   TypeOrdersPlace          = Open_Buy_And_Sell;
input int    MagicNumber              = 88888;
input string CommentsOrders            = "GRID V7.10 TREND";

string SymbolTrade;
int OrdersID, HandleFastMA, HandleSlowMA, HandleADX, HandleATR, HandleRSI, HandleEntryMA;
datetime LastEntryTime = 0;
datetime LastExitTime = 0;
datetime DayStartTime = 0;
double DayStartBalance = 0;
int ConsecutiveLosses = 0;
int DailyLossCount = 0;
double HighWaterMark = 0;
bool IsTerminated = false;

ulong PositionTicketState = 0;
double InitialRiskDistance = 0.0;
double EntryPriceState = 0.0;
double PeakPriceState = 0.0;

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
      DailyLossCount=0;
   }
}

bool GetBufferValue(int handle,int buffer,int shift,double &value)
{
   double b[]; ArraySetAsSeries(b,true);
   if(handle==INVALID_HANDLE) return false;
   if(CopyBuffer(handle,buffer,shift,1,b)<1) return false;
   value=b[0]; return true;
}

double GetATR(int shift=1)
{
   double v=0;
   return GetBufferValue(HandleATR,0,shift,v)?v:0.0;
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
   double fast,slow,adx,adxPrev,plusDI,minusDI;
   if(!GetBufferValue(HandleFastMA,0,1,fast) || !GetBufferValue(HandleSlowMA,0,1,slow) ||
      !GetBufferValue(HandleADX,0,1,adx) || !GetBufferValue(HandleADX,0,2,adxPrev) ||
      !GetBufferValue(HandleADX,1,1,plusDI) || !GetBufferValue(HandleADX,2,1,minusDI)) return 99;

   double price=iClose(SymbolTrade,RegimeTF,1);
   if(price<=0) return 99;
   if(adx<ADXMinTrend) return AllowRangeTrading ? 0 : 99;
   if(RequireADXExpansion && adx<adxPrev) return 99;

   if(price>fast && fast>slow && plusDI>minusDI) return 1;
   if(price<fast && fast<slow && minusDI>plusDI) return -1;
   return 99;
}

bool StrongTrendForDirection(int direction)
{
   double adx;
   if(!GetBufferValue(HandleADX,0,1,adx)) return false;
   if(direction<0) return adx>=SellExtraADX;
   return adx>=ADXMinTrend;
}

bool SpreadOK(double atr)
{
   if(atr<=0) return false;
   double spread=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK)-SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   return spread<=atr*(MaxSpreadATRPercent/100.0);
}

double NormalizeVolume(double lots)
{
   double minLot=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_STEP);
   double cap=MathMin(MaxLotSize,maxLot);

   if(lots<minLot)
   {
      if(RejectIfMinLotOverRisk) return 0.0;
      lots=minLot;
   }
   lots=MathMin(lots,cap);
   if(step<=0) return NormalizeDouble(lots,2);
   lots=MathFloor(lots/step)*step;
   if(lots<minLot) return RejectIfMinLotOverRisk ? 0.0 : NormalizeDouble(minLot,2);
   return NormalizeDouble(lots,2);
}

double EstimateLossMoney(ENUM_ORDER_TYPE orderType,double volume,double stopDistance)
{
   if(volume<=0 || stopDistance<=0) return 0.0;
   double entry=(orderType==ORDER_TYPE_BUY)?SymbolInfoDouble(SymbolTrade,SYMBOL_ASK):SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   double stop=(orderType==ORDER_TYPE_BUY)?entry-stopDistance:entry+stopDistance;
   double profit=0.0;
   if(!OrderCalcProfit(orderType,SymbolTrade,volume,entry,stop,profit)) return 0.0;
   return MathAbs(profit);
}

double CalculateLot(ENUM_ORDER_TYPE orderType,double stopDistance)
{
   if(stopDistance<=0) return 0.0;
   double riskPct=MathMin(RiskPerTradePercent,MaxRiskPerTradePercent);
   if(ConsecutiveLosses>=2) riskPct*=0.50;
   double riskMoney=AccountInfoDouble(ACCOUNT_EQUITY)*riskPct/100.0;
   if(riskMoney<=0) return 0.0;

   double minLot=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MIN);
   double minLotLoss=EstimateLossMoney(orderType,minLot,stopDistance);
   if(RejectIfMinLotOverRisk && minLotLoss>riskMoney*1.02) return 0.0;

   double tickSize=SymbolInfoDouble(SymbolTrade,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(SymbolTrade,SYMBOL_TRADE_TICK_VALUE);
   if(tickSize<=0 || tickValue<=0) return RejectIfMinLotOverRisk ? 0.0 : NormalizeVolume(minLot);

   double lossPerLot=(stopDistance/tickSize)*tickValue;
   if(lossPerLot<=0) return 0.0;
   double lots=NormalizeVolume(riskMoney/lossPerLot);
   if(lots<=0) return 0.0;

   double actualRisk=EstimateLossMoney(orderType,lots,stopDistance);
   if(actualRisk>riskMoney*1.02) return 0.0;
   return lots;
}

bool DailyRiskBlocked()
{
   if(DayStartBalance<=0) return true;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double dd=((DayStartBalance-eq)/DayStartBalance)*100.0;
   return dd>=MaxDailyLossPercent || DailyLossCount>=MaxConsecutiveLosses;
}

bool HasOpenPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC)==OrdersID && PositionGetString(POSITION_SYMBOL)==SymbolTrade) return true;
   }
   return false;
}

ulong FindOurPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC)==OrdersID && PositionGetString(POSITION_SYMBOL)==SymbolTrade) return ticket;
   }
   return 0;
}

void ResetPositionStateIfNeeded()
{
   ulong ticket=FindOurPosition();
   if(ticket==0)
   {
      PositionTicketState=0; InitialRiskDistance=0.0; EntryPriceState=0.0; PeakPriceState=0.0; return;
   }
   if(!PositionSelectByTicket(ticket)) return;
   if(PositionTicketState!=ticket)
   {
      PositionTicketState=ticket;
      EntryPriceState=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      InitialRiskDistance=MathAbs(EntryPriceState-sl);
      PeakPriceState=EntryPriceState;
   }
}

bool PlaceDirectionalTrade(int direction)
{
   if(direction==0 || direction==99 || HasOpenPosition()) return false;
   if(DailyRiskBlocked() || !IsTradingHour()) return false;
   if(TimeCurrent()-LastEntryTime<CooldownMinutes*60 || TimeCurrent()-LastExitTime<CooldownMinutes*60) return false;
   if(TypeOrdersPlace==Open__Only_Buy && direction<0) return false;
   if(TypeOrdersPlace==Open__Only_Sell && direction>0) return false;
   if(!StrongTrendForDirection(direction)) return false;

   double atr=GetATR(1);
   if(atr<MinATRPrice || !SpreadOK(atr)) return false;
   double close1=iClose(SymbolTrade,EntryTF,1), open1=iOpen(SymbolTrade,EntryTF,1);
   if(close1<=0 || open1<=0) return false;
   if(MathAbs(close1-open1)<atr*MinBodyATR) return false;

   double hi=HighestHigh(BreakoutLookback,2), lo=LowestLow(BreakoutLookback,2);
   if(direction>0 && close1<=hi+atr*BreakoutBufferATR) return false;
   if(direction<0 && close1>=lo-atr*BreakoutBufferATR) return false;

   double rsi; if(!GetBufferValue(HandleRSI,0,1,rsi)) return false;
   if(direction>0 && (rsi<BuyRSIMin || rsi>BuyRSIMax)) return false;
   if(direction<0 && (rsi<SellRSIMin || rsi>SellRSIMax)) return false;

   double entryMA; if(!GetBufferValue(HandleEntryMA,0,1,entryMA)) return false;
   if(direction>0 && close1<entryMA) return false;
   if(direction<0 && close1>entryMA) return false;

   double slDist=MathMax(MinSL_ATR*atr,MathMin(MaxSL_ATR*atr,InitialSL_ATR*atr));
   ENUM_ORDER_TYPE orderType=(direction>0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double entry=(direction>0)?SymbolInfoDouble(SymbolTrade,SYMBOL_ASK):SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   double sl=(direction>0)?entry-slDist:entry+slDist;
   double lots=CalculateLot(orderType,slDist);
   if(lots<=0) return false;

   trade.SetExpertMagicNumber(OrdersID);
   trade.SetDeviationInPoints(20);
   bool ok=(direction>0)?trade.Buy(lots,SymbolTrade,entry,sl,0,CommentsOrders):trade.Sell(lots,SymbolTrade,entry,sl,0,CommentsOrders);
   if(ok){ LastEntryTime=TimeCurrent(); PositionTicketState=0; }
   return ok;
}

void ManageOpenPosition()
{
   ulong ticket=FindOurPosition();
   if(ticket==0 || !PositionSelectByTicket(ticket)) return;
   ResetPositionStateIfNeeded();

   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double open=PositionGetDouble(POSITION_PRICE_OPEN), sl=PositionGetDouble(POSITION_SL);
   double price=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(SymbolTrade,SYMBOL_BID):SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   if(InitialRiskDistance<=0) InitialRiskDistance=MathAbs(open-sl);
   double riskDistance=InitialRiskDistance;
   if(riskDistance<=0) return;

   if(type==POSITION_TYPE_BUY) PeakPriceState=MathMax(PeakPriceState,price);
   else PeakPriceState=(PeakPriceState==0)?price:MathMin(PeakPriceState,price);

   double r=(type==POSITION_TYPE_BUY)?(price-open)/riskDistance:(open-price)/riskDistance;
   double atr=GetATR(1);
   datetime openTime=(datetime)PositionGetInteger(POSITION_TIME);
   double ageH=(double)(TimeCurrent()-openTime)/3600.0;

   if(ageH>=MaxTradeHours){ if(trade.PositionClose(ticket)) LastExitTime=TimeCurrent(); return; }
   if(ageH>=StaleTradeHours && r<StaleMinR)
   {
      int regime=RegimeDirection();
      if((type==POSITION_TYPE_BUY && regime!=1) || (type==POSITION_TYPE_SELL && regime!=-1))
      { if(trade.PositionClose(ticket)) LastExitTime=TimeCurrent(); return; }
   }

   double newSL=sl;
   if(r>=BreakEven_R)
   {
      double lock=(type==POSITION_TYPE_BUY)?open+riskDistance*BreakEvenLock_R:open-riskDistance*BreakEvenLock_R;
      if(type==POSITION_TYPE_BUY) newSL=MathMax(newSL,lock); else newSL=(newSL==0)?lock:MathMin(newSL,lock);
   }
   if(r>=ProfitLock_R)
   {
      double lock=(type==POSITION_TYPE_BUY)?open+riskDistance*ProfitLockValue_R:open-riskDistance*ProfitLockValue_R;
      if(type==POSITION_TYPE_BUY) newSL=MathMax(newSL,lock); else newSL=(newSL==0)?lock:MathMin(newSL,lock);
   }
   if(r>=RunnerStart_R && atr>0)
   {
      double trail=(type==POSITION_TYPE_BUY)?PeakPriceState-RunnerATRMultiplier*atr:PeakPriceState+RunnerATRMultiplier*atr;
      if(type==POSITION_TYPE_BUY) newSL=MathMax(newSL,trail); else newSL=(newSL==0)?trail:MathMin(newSL,trail);
   }

   double point=SymbolInfoDouble(SymbolTrade,SYMBOL_POINT); int digits=(int)SymbolInfoInteger(SymbolTrade,SYMBOL_DIGITS);
   if(type==POSITION_TYPE_BUY && newSL>0 && newSL>sl+point) trade.PositionModify(ticket,NormalizeDouble(newSL,digits),0);
   if(type==POSITION_TYPE_SELL && newSL>0 && (sl==0 || newSL<sl-point)) trade.PositionModify(ticket,NormalizeDouble(newSL,digits),0);
}

void UpdateClosedTradeStats()
{
   static datetime lastScan=0;
   datetime from=lastScan>0?lastScan:DayStartTime;
   if(from<=0) from=TimeCurrent()-86400;
   if(!HistorySelect(from,TimeCurrent())) return;
   int total=HistoryDealsTotal();
   for(int i=total-1;i>=0;i--)
   {
      ulong deal=HistoryDealGetTicket(i); if(deal==0) continue;
      if((long)HistoryDealGetInteger(deal,DEAL_MAGIC)!=OrdersID) continue;
      if(HistoryDealGetString(deal,DEAL_SYMBOL)!=SymbolTrade) continue;
      datetime t=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);
      if(t<=lastScan) break;
      long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
      {
         double p=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_COMMISSION);
         if(p<0){ ConsecutiveLosses++; DailyLossCount++; LastExitTime=t; }
         else if(p>0) ConsecutiveLosses=0;
      }
      if(t>lastScan) lastScan=t;
   }
}

int OnInit()
{
   SymbolTrade=_Symbol; OrdersID=(MagicNumber==0)?101010:MagicNumber; trade.SetExpertMagicNumber(OrdersID);
   HandleFastMA=iMA(SymbolTrade,RegimeTF,FastMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   HandleSlowMA=iMA(SymbolTrade,RegimeTF,SlowMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   HandleADX=iADX(SymbolTrade,RegimeTF,ADXPeriod);
   HandleATR=iATR(SymbolTrade,EntryTF,ATRPeriod);
   HandleRSI=iRSI(SymbolTrade,EntryTF,RSIPeriod,PRICE_CLOSE);
   HandleEntryMA=iMA(SymbolTrade,EntryTF,PullbackMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   DayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE); HighWaterMark=DayStartBalance;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); dt.hour=0; dt.min=0; dt.sec=0; DayStartTime=StructToTime(dt);
   if(HandleFastMA==INVALID_HANDLE || HandleSlowMA==INVALID_HANDLE || HandleADX==INVALID_HANDLE || HandleATR==INVALID_HANDLE || HandleRSI==INVALID_HANDLE || HandleEntryMA==INVALID_HANDLE) return INIT_FAILED;
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
   ResetDailyState(); UpdateClosedTradeStats(); ResetPositionStateIfNeeded();

   double balance=AccountInfoDouble(ACCOUNT_BALANCE), equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance>HighWaterMark) HighWaterMark=balance;
   double dd=HighWaterMark>0?((HighWaterMark-equity)/HighWaterMark)*100.0:0.0;
   if(dd>=MaxEquityLossPercent)
   {
      ulong t=FindOurPosition(); if(t>0) trade.PositionClose(t);
      IsTerminated=true; return;
   }

   ManageOpenPosition();
   if(HasOpenPosition()) return;
   if(DailyRiskBlocked() || !IsTradingHour()) return;

   int regime=UseRegimeFilter?RegimeDirection():0;
   if(regime==1) PlaceDirectionalTrade(1);
   else if(regime==-1) PlaceDirectionalTrade(-1);

   Comment("GRID 6 V2 | v7.10\n",
           "Balance: ",DoubleToString(balance,2)," Equity: ",DoubleToString(equity,2),"\n",
           "DD: ",DoubleToString(dd,2),"% Global Loss Streak: ",IntegerToString(ConsecutiveLosses),
           " Daily Losses: ",IntegerToString(DailyLossCount),"\n",
           "Regime: ",IntegerToString(regime));
}
