// Expert Advisor: GRID 06.V02 - ADAPTIVE XAU TREND ENGINE
// v8.00 - Trend + Momentum + Pullback + Volatility Scaling + Asymmetric Risk
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "8.00"

#include <Trade/Trade.mqh>
CTrade trade;

enum Type {Open_Buy_And_Sell, Open__Only_Buy, Open__Only_Sell};

input string SafeParameters          = "||========== SAFETY & RISK ==========||";
input double RiskPerTradePercent     = 0.30;
input double MaxRiskPerTradePercent  = 0.45;
input double SellRiskMultiplier      = 1.15;
input double BuyRiskMultiplier       = 0.90;
input double MaxEquityLossPercent    = 12.0;
input double MaxDailyLossPercent     = 3.0;
input int    MaxConsecutiveLosses    = 3;
input int    CooldownMinutes         = 60;

input string RegimeSettings          = "||========== MULTI-TF REGIME ENGINE ==========||";
input bool   UseRegimeFilter         = true;
input ENUM_TIMEFRAMES RegimeTF       = PERIOD_H1;
input int    FastMAPeriod             = 50;
input int    SlowMAPeriod             = 200;
input int    ADXPeriod               = 14;
input double ADXMinTrend             = 22.0;
input double ADXStrongTrend          = 25.0;
input double ADXSlopeTolerance       = 0.12;
input bool   RequireADXExpansion     = false;
input bool   AllowRangeTrading       = false;
input bool   UseH4Confirmation       = true;
input int    H4FastMAPeriod          = 50;
input int    H4SlowMAPeriod          = 200;

input string EntrySettings           = "||========== ADAPTIVE ENTRY ENGINE ==========||";
input ENUM_TIMEFRAMES EntryTF        = PERIOD_M15;
input int    BreakoutLookback        = 20;
input int    PullbackLookback        = 6;
input double BreakoutBufferATR       = 0.05;
input double PullbackZoneATR         = 0.35;
input int    PullbackMAPeriod        = 20;
input int    RSIPeriod               = 14;
input double BuyRSIMin               = 48.0;
input double BuyRSIMax               = 64.0;
input double SellRSIMin              = 28.0;
input double SellRSIMax              = 55.0;
input double MinBodyATR              = 0.30;
input double StrongBodyATR           = 0.65;
input int    MinBuyScore             = 7;
input int    MinSellScore            = 6;

input string VolatilitySettings      = "||========== ATR / VOLATILITY POSITION SIZING ==========||";
input int    ATRPeriod               = 14;
input int    VolatilityBaselineBars  = 48;
input double LowVolFactor            = 0.70;
input double HighVolFactor           = 1.35;
input double ExtremeVolFactor        = 1.80;
input double InitialSL_ATR_Buy       = 1.60;
input double InitialSL_ATR_Sell      = 1.80;
input double MinSL_ATR               = 1.25;
input double MaxSL_ATR               = 2.80;
input double MinATRPrice             = 0.30;
input double MaxSpreadATRPercent     = 12.0;
input double MaxLotSize              = 0.20;
input bool   RejectIfMinLotOverRisk  = true;

input string ExitSettings            = "||========== DYNAMIC R-MULTIPLE RUNNER ==========||";
input double BreakEven_R             = 1.20;
input double BreakEvenLock_R         = 0.05;
input double ProfitLock_R            = 2.20;
input double ProfitLockValue_R       = 0.80;
input double RunnerStart_R           = 3.00;
input double RunnerLock_R            = 1.50;
input double RunnerATRMultiplier     = 2.40;
input double RunnerATRMultiplierStrong = 2.80;
input double MaxTradeHours           = 18.0;
input double StaleTradeHours         = 4.0;
input double StaleMinR               = 0.20;

input string TradingHourSettings     = "||========== TRADING HOURS ==========||";
input bool   UseTradingHour          = true;
input int    StartHour               = 7;
input int    EndHour                 = 22;

input Type   TypeOrdersPlace         = Open_Buy_And_Sell;
input int    MagicNumber              = 88888;
input string CommentsOrders           = "GRID V8 XAU TREND";

string SymbolTrade;
int OrdersID, HandleFastMA, HandleSlowMA, HandleADX, HandleATR, HandleRSI, HandleEntryMA;
int HandleH4FastMA, HandleH4SlowMA;
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

double AverageATR(int bars,int start=1)
{
   if(bars<=0) return 0.0;
   double sum=0.0; int count=0;
   for(int i=start;i<start+bars;i++)
   {
      double v=GetATR(i);
      if(v>0){ sum+=v; count++; }
   }
   return count>0?sum/count:0.0;
}

double VolatilityRatio(double atr)
{
   double base=AverageATR(VolatilityBaselineBars,2);
   if(atr<=0 || base<=0) return 1.0;
   return atr/base;
}

int VolatilityRegime(double atr)
{
   double vr=VolatilityRatio(atr);
   if(vr>=ExtremeVolFactor) return 2;
   if(vr>=HighVolFactor) return 1;
   if(vr<=LowVolFactor) return -1;
   return 0;
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

bool H4Aligned(int direction)
{
   if(!UseH4Confirmation) return true;
   double fast,slow;
   if(!GetBufferValue(HandleH4FastMA,0,1,fast) || !GetBufferValue(HandleH4SlowMA,0,1,slow)) return false;
   double price=iClose(SymbolTrade,PERIOD_H4,1);
   if(price<=0) return false;
   if(direction>0) return price>fast && fast>slow;
   return price<fast && fast<slow;
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

   // ADX may pull back modestly during a healthy trend. Reject only a meaningful collapse.
   if(RequireADXExpansion && adx < adxPrev*(1.0-ADXSlopeTolerance)) return 99;

   if(price>fast && fast>slow && plusDI>minusDI && H4Aligned(1)) return 1;
   if(price<fast && fast<slow && minusDI>plusDI && H4Aligned(-1)) return -1;
   return 99;
}

bool StrongTrendForDirection(int direction)
{
   double adx;
   if(!GetBufferValue(HandleADX,0,1,adx)) return false;
   if(direction<0) return adx>=ADXStrongTrend;
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
   if(lots<minLot) return RejectIfMinLotOverRisk?0.0:NormalizeDouble(minLot,2);
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

double CalculateLot(ENUM_ORDER_TYPE orderType,double stopDistance,int direction,double score,double atr)
{
   if(stopDistance<=0) return 0.0;
   double riskPct=MathMin(RiskPerTradePercent,MaxRiskPerTradePercent);
   riskPct*=direction>0?BuyRiskMultiplier:SellRiskMultiplier;
   if(ConsecutiveLosses>=2) riskPct*=0.50;
   double vr=VolatilityRatio(atr);
   if(vr>=ExtremeVolFactor) return 0.0;
   if(vr>1.0) riskPct*=MathMax(0.50,1.0/vr);
   if(score>=9) riskPct*=1.05;
   riskPct=MathMin(riskPct,MaxRiskPerTradePercent);

   double riskMoney=AccountInfoDouble(ACCOUNT_EQUITY)*riskPct/100.0;
   if(riskMoney<=0) return 0.0;
   double minLot=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MIN);
   double minLotLoss=EstimateLossMoney(orderType,minLot,stopDistance);
   if(RejectIfMinLotOverRisk && minLotLoss>riskMoney*1.02) return 0.0;

   double tickSize=SymbolInfoDouble(SymbolTrade,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(SymbolTrade,SYMBOL_TRADE_TICK_VALUE);
   if(tickSize<=0 || tickValue<=0) return 0.0;
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

int EntryScore(int direction,double atr,bool &isBreakout,bool &isPullback)
{
   isBreakout=false; isPullback=false;
   double close1=iClose(SymbolTrade,EntryTF,1), open1=iOpen(SymbolTrade,EntryTF,1);
   double close2=iClose(SymbolTrade,EntryTF,2);
   if(close1<=0 || open1<=0 || close2<=0 || atr<=0) return 0;

   double body=MathAbs(close1-open1);
   double hi=HighestHigh(BreakoutLookback,2), lo=LowestLow(BreakoutLookback,2);
   double breakoutLevel=(direction>0)?hi:lo;
   if(direction>0) isBreakout=close1>hi+atr*BreakoutBufferATR;
   else isBreakout=close1<lo-atr*BreakoutBufferATR;

   double ma; if(!GetBufferValue(HandleEntryMA,0,1,ma)) return 0;
   bool maAligned=(direction>0)?close1>=ma:close1<=ma;
   double rsi; if(!GetBufferValue(HandleRSI,0,1,rsi)) return 0;
   bool rsiOK=(direction>0)?(rsi>=BuyRSIMin && rsi<=BuyRSIMax):(rsi>=SellRSIMin && rsi<=SellRSIMax);
   double adx; if(!GetBufferValue(HandleADX,0,1,adx)) return 0;
   double plusDI,minusDI;
   if(!GetBufferValue(HandleADX,1,1,plusDI) || !GetBufferValue(HandleADX,2,1,minusDI)) return 0;
   bool diAligned=(direction>0)?plusDI>minusDI:minusDI>plusDI;

   // Pullback: price remains on trend side of EMA and has recently interacted with EMA/previous breakout zone.
   double recentHigh=HighestHigh(PullbackLookback,2), recentLow=LowestLow(PullbackLookback,2);
   bool touchedMA=false;
   for(int i=2;i<2+PullbackLookback;i++)
   {
      double h=iHigh(SymbolTrade,EntryTF,i), l=iLow(SymbolTrade,EntryTF,i);
      double m=0;
      if(GetBufferValue(HandleEntryMA,0,i,m))
      {
         if(l<=m+atr*PullbackZoneATR && h>=m-atr*PullbackZoneATR) { touchedMA=true; break; }
      }
   }
   bool continuation=(direction>0)?close1>close2:close1<close2;
   bool nearBreakoutZone=(direction>0)?recentLow<=hi+atr*PullbackZoneATR:recentHigh>=lo-atr*PullbackZoneATR;
   isPullback=maAligned && touchedMA && continuation && nearBreakoutZone;

   int score=0;
   int regime=RegimeDirection();
   if(regime==direction) score+=2;
   if(H4Aligned(direction)) score+=1;
   if(adx>=(direction<0?ADXStrongTrend:ADXMinTrend)) score+=2;
   if(diAligned) score+=1;
   if(isBreakout) score+=2;
   if(isPullback) score+=2;
   if(maAligned) score+=1;
   if(rsiOK) score+=1;
   if(body>=atr*MinBodyATR) score+=1;
   if(body>=atr*StrongBodyATR) score+=1;

   return score;
}

bool PlaceDirectionalTrade(int direction)
{
   if(direction==0 || direction==99 || HasOpenPosition()) return false;
   if(DailyRiskBlocked() || !IsTradingHour()) return false;
   if(TimeCurrent()-LastEntryTime<CooldownMinutes*60 || TimeCurrent()-LastExitTime<CooldownMinutes*60) return false;
   if(TypeOrdersPlace==Open__Only_Buy && direction<0) return false;
   if(TypeOrdersPlace==Open__Only_Sell && direction>0) return false;
   if(!StrongTrendForDirection(direction)) return false;
   if(!H4Aligned(direction)) return false;

   double atr=GetATR(1);
   if(atr<MinATRPrice || !SpreadOK(atr)) return false;
   if(VolatilityRatio(atr)>=ExtremeVolFactor) return false;

   bool isBreakout=false,isPullback=false;
   int score=EntryScore(direction,atr,isBreakout,isPullback);
   int required=direction>0?MinBuyScore:MinSellScore;
   if(score<required) return false;
   if(!isBreakout && !isPullback) return false;

   double body=MathAbs(iClose(SymbolTrade,EntryTF,1)-iOpen(SymbolTrade,EntryTF,1));
   if(body<atr*MinBodyATR) return false;

   double slATR=direction>0?InitialSL_ATR_Buy:InitialSL_ATR_Sell;
   double vr=VolatilityRatio(atr);
   if(vr>1.25) slATR*=1.10;
   slATR=MathMax(MinSL_ATR,MathMin(MaxSL_ATR,slATR));
   double slDist=slATR*atr;

   ENUM_ORDER_TYPE orderType=(direction>0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double entry=(direction>0)?SymbolInfoDouble(SymbolTrade,SYMBOL_ASK):SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   double sl=(direction>0)?entry-slDist:entry+slDist;
   double lots=CalculateLot(orderType,slDist,direction,score,atr);
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
   int direction=(type==POSITION_TYPE_BUY)?1:-1;
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
      if(regime!=direction){ if(trade.PositionClose(ticket)) LastExitTime=TimeCurrent(); return; }
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
   if(r>=RunnerStart_R)
   {
      double lock=(type==POSITION_TYPE_BUY)?open+riskDistance*RunnerLock_R:open-riskDistance*RunnerLock_R;
      if(type==POSITION_TYPE_BUY) newSL=MathMax(newSL,lock); else newSL=(newSL==0)?lock:MathMin(newSL,lock);
      if(atr>0)
      {
         double adx=0; GetBufferValue(HandleADX,0,1,adx);
         double mult=(adx>=ADXStrongTrend)?RunnerATRMultiplierStrong:RunnerATRMultiplier;
         double trail=(type==POSITION_TYPE_BUY)?PeakPriceState-mult*atr:PeakPriceState+mult*atr;
         if(type==POSITION_TYPE_BUY) newSL=MathMax(newSL,trail); else newSL=(newSL==0)?trail:MathMin(newSL,trail);
      }
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
   HandleH4FastMA=iMA(SymbolTrade,PERIOD_H4,H4FastMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   HandleH4SlowMA=iMA(SymbolTrade,PERIOD_H4,H4SlowMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   DayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE); HighWaterMark=DayStartBalance;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); dt.hour=0; dt.min=0; dt.sec=0; DayStartTime=StructToTime(dt);
   if(HandleFastMA==INVALID_HANDLE || HandleSlowMA==INVALID_HANDLE || HandleADX==INVALID_HANDLE || HandleATR==INVALID_HANDLE ||
      HandleRSI==INVALID_HANDLE || HandleEntryMA==INVALID_HANDLE || HandleH4FastMA==INVALID_HANDLE || HandleH4SlowMA==INVALID_HANDLE) return INIT_FAILED;
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
   if(HandleH4FastMA!=INVALID_HANDLE) IndicatorRelease(HandleH4FastMA);
   if(HandleH4SlowMA!=INVALID_HANDLE) IndicatorRelease(HandleH4SlowMA);
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

   double atr=GetATR(1), vr=VolatilityRatio(atr);
   Comment("GRID 6 V2 | v8.00 ADAPTIVE XAU TREND\n",
           "Balance: ",DoubleToString(balance,2)," Equity: ",DoubleToString(equity,2),"\n",
           "DD: ",DoubleToString(dd,2),"% Loss Streak: ",IntegerToString(ConsecutiveLosses),
           " Daily Losses: ",IntegerToString(DailyLossCount),"\n",
           "Regime: ",IntegerToString(regime)," ATR: ",DoubleToString(atr,2)," VolRatio: ",DoubleToString(vr,2));
}
