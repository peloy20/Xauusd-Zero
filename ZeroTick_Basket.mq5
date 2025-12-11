//+------------------------------------------------------------------+
//|                                          ZeroTick_Basket.mq5     |
//|  Akun ZERO: Basket Scalper (multi posisi) + EMA + OF + BOS + FVG |
//|  Exit berdasarkan Basket TP/SL + Basket Trailing (tanpa SL/TP)   |
//+------------------------------------------------------------------+
#property strict
#property copyright "sansan x ChatGPT"
#property version   "1.00"
#property description "Basket scalper akun ZERO: multi entry, basket TP/SL, EMA+Orderflow+BOS+FVG+ATR"

#include <Trade/Trade.mqh>

CTrade trade;

//--- input utama
input string   InpSymbol            = "XAUUSD";   // Symbol
input ulong    InpMagic             = 889001;     // Magic number

// Money management (per entry)
input bool     InpUseRiskPercent    = false;      // kalau false -> pakai lot fix
input double   InpFixedLot          = 0.10;       // lot tetap
input double   InpRiskPercent       = 1.0;        // % equity per posisi (ingat: basket multi entry)

// Spread filter (points)
input double   InpMaxSpreadPoints   = 300;        // contoh 300 = 3 pip

// EMA microtrend
input ENUM_TIMEFRAMES InpTF         = PERIOD_M1;
input int      InpEmaFast1          = 3;
input int      InpEmaFast2          = 6;
input int      InpEmaFast3          = 12;
input int      InpEmaSlow           = 20;

// Basket config
input int      InpMaxTrades         = 5;          // maksimal posisi dalam 1 basket
input int      InpGridStepPoints    = 200;        // jarak minimal antar entry (points)
input double   InpBasketTPMoney     = 10.0;       // TP basket (USD)
input double   InpBasketSLMoney     = -20.0;      // SL basket (USD)

// Basket trailing (opsional)
input bool     InpUseBasketTrail    = true;
input double   InpBasketTrailStart  = 15.0;       // mulai trail kalau profit basket >= ini (USD)
input double   InpBasketTrailStep   = 5.0;        // kalau mundur >= ini dari puncak -> close (USD)

// Orderflow
input bool     InpUseOrderflow      = true;
input int      InpOF_VolumeLookback = 20;
input double   InpOF_VolumeFactor   = 1.2;        // volume sekarang ≥ 1.2x rata2

// Micro BOS / CHoCH
input bool     InpUseMicroStructure = true;
input int      InpBOS_Lookback      = 10;

// Mini FVG
input bool     InpUseFVG            = true;
input double   InpFVG_MaxDistancePts= 200;        // max jarak dari zona FVG ke harga (points)

// Volatility Engine (ATR)
input bool     InpUseVolatility     = true;
input int      InpATR_Period        = 14;
input double   InpATR_MinPoints     = 150;
input double   InpATR_MaxPoints     = 800;

//--- indikator handle
int handleEma1, handleEma2, handleEma3, handleEmaSlow;
int handleATR;

//--- basket trailing state
static double g_bestBasketProfit = 0.0;
static bool   g_basketTrailActive = false;

//--- helper micro
int sign(double x){ if(x>0) return 1; if(x<0) return -1; return 0; }

//+------------------------------------------------------------------+
int OnInit()
  {
   string sym = (InpSymbol=="" || InpSymbol==NULL) ? _Symbol : InpSymbol;

   handleEma1   = iMA(sym, InpTF, InpEmaFast1, 0, MODE_EMA, PRICE_CLOSE);
   handleEma2   = iMA(sym, InpTF, InpEmaFast2, 0, MODE_EMA, PRICE_CLOSE);
   handleEma3   = iMA(sym, InpTF, InpEmaFast3, 0, MODE_EMA, PRICE_CLOSE);
   handleEmaSlow= iMA(sym, InpTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);

   if(InpUseVolatility)
      handleATR = iATR(sym, InpTF, InpATR_Period);
   else
      handleATR = INVALID_HANDLE;

   if(handleEma1==INVALID_HANDLE || handleEma2==INVALID_HANDLE ||
      handleEma3==INVALID_HANDLE || handleEmaSlow==INVALID_HANDLE)
     {
      Print("Error: gagal membuat handle EMA");
      return(INIT_FAILED);
     }

   if(InpUseVolatility && handleATR==INVALID_HANDLE)
     {
      Print("Error: gagal membuat handle ATR");
      return(INIT_FAILED);
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(handleEma1   != INVALID_HANDLE) IndicatorRelease(handleEma1);
   if(handleEma2   != INVALID_HANDLE) IndicatorRelease(handleEma2);
   if(handleEma3   != INVALID_HANDLE) IndicatorRelease(handleEma3);
   if(handleEmaSlow!= INVALID_HANDLE) IndicatorRelease(handleEmaSlow);
   if(handleATR    != INVALID_HANDLE) IndicatorRelease(handleATR);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   string sym = (InpSymbol=="" || InpSymbol==NULL) ? _Symbol : InpSymbol;

   // --- SPREAD CHECK (penting utk ZERO) ---
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick))
      return;

   double spreadPoints = (tick.ask - tick.bid) / _Point;
   if(spreadPoints > InpMaxSpreadPoints)
      return;

   // --- BACA EMA ---
   double ema1[2], ema2[2], ema3[2], emaSlow[2];
   if(CopyBuffer(handleEma1,0,0,2,ema1)   < 2) return;
   if(CopyBuffer(handleEma2,0,0,2,ema2)   < 2) return;
   if(CopyBuffer(handleEma3,0,0,2,ema3)   < 2) return;
   if(CopyBuffer(handleEmaSlow,0,0,2,emaSlow)<2) return;

   double ema1_curr   = ema1[0];
   double ema2_curr   = ema2[0];
   double ema3_curr   = ema3[0];
   double emaSlowCurr = emaSlow[0];

   // --- VOLATILITY FILTER (ATR) ---
   if(InpUseVolatility && !CheckVolatility(sym))
      return;

   // --- BASKET INFO (SEMUA POSISI MAGIC INI) ---
   int    basketCount;
   double basketProfit;
   double basketVolume;
   double basketAvgPrice;
   long   basketDirection;     // POSITION_TYPE_BUY / SELL / -1 jika none
   double lastEntryPrice;

   GetBasketInfo(sym, InpMagic, basketCount, basketProfit, basketVolume,
                 basketAvgPrice, basketDirection, lastEntryPrice);

   // --- HANDLE BASKET EXIT (TP / SL / TRAIL) ---
   if(basketCount > 0)
     {
      if(HandleBasketExit(sym, basketProfit))
         return;  // basket sudah ditutup semua

      // --- TAMBAH POSISI DALAM BASKET (SCALE-IN) ---
      if(basketCount < InpMaxTrades)
        {
         // arah basket: BUY/SELL
         bool wantBuy  = (basketDirection == POSITION_TYPE_BUY);
         bool wantSell = (basketDirection == POSITION_TYPE_SELL);

         // trend micro
         bool trendBull = (ema1_curr > ema2_curr && ema2_curr > ema3_curr &&
                           ema3_curr > emaSlowCurr && tick.bid > ema1_curr);
         bool trendBear = (ema1_curr < ema2_curr && ema2_curr < ema3_curr &&
                           ema3_curr < emaSlowCurr && tick.bid < ema1_curr);

         // filter lain (orderflow, BOS, FVG)
         bool ofBuy  = CheckOrderflow(sym, true);
         bool ofSell = CheckOrderflow(sym, false);

         bool bosBuy  = CheckMicroStructure(sym, true);
         bool bosSell = CheckMicroStructure(sym, false);

         bool fvgBuy  = CheckMiniFVG(sym, true, tick.bid, tick.ask);
         bool fvgSell = CheckMiniFVG(sym, false, tick.bid, tick.ask);

         // jarak dari last entry
         double distFromLast = 0.0;
         if(wantBuy)
            distFromLast = MathAbs((tick.bid - lastEntryPrice) / _Point);
         else if(wantSell)
            distFromLast = MathAbs((lastEntryPrice - tick.ask) / _Point);

         double lot = CalculateLot(sym);
         if(lot <= 0) return;

         trade.SetExpertMagicNumber(InpMagic);
         trade.SetTypeFillingBySymbol(sym);

         if(wantBuy)
           {
            // mode basket BUY: tambah posisi Jika trend & filter searah, dan jarak sudah cukup
            if(trendBull && ofBuy && bosBuy && fvgBuy && distFromLast >= InpGridStepPoints)
              {
               bool result = trade.Buy(lot, sym, tick.ask, 0.0, 0.0, "Basket BUY add");
               if(result)
                  Print("Basket BUY tambah posisi. Total=", basketCount+1);
              }
           }
         else if(wantSell)
           {
            if(trendBear && ofSell && bosSell && fvgSell && distFromLast >= InpGridStepPoints)
              {
               bool result = trade.Sell(lot, sym, tick.bid, 0.0, 0.0, "Basket SELL add");
               if(result)
                  Print("Basket SELL tambah posisi. Total=", basketCount+1);
              }
           }
        }

      return; // sudah handle basket, tidak buka basket baru
     }
   else
     {
      // kalau tidak ada basket, reset state trailing
      g_bestBasketProfit  = 0.0;
      g_basketTrailActive = false;
     }

   // --- BUKA BASKET BARU (ENTRY PERTAMA) ---
   // trend micro
   bool trendBull2 = (ema1_curr > ema2_curr && ema2_curr > ema3_curr &&
                      ema3_curr > emaSlowCurr && tick.bid > ema1_curr);
   bool trendBear2 = (ema1_curr < ema2_curr && ema2_curr < ema3_curr &&
                      ema3_curr < emaSlowCurr && tick.bid < ema1_curr);

   bool ofBuy2  = CheckOrderflow(sym, true);
   bool ofSell2 = CheckOrderflow(sym, false);

   bool bosBuy2  = CheckMicroStructure(sym, true);
   bool bosSell2 = CheckMicroStructure(sym, false);

   bool fvgBuy2  = CheckMiniFVG(sym, true, tick.bid, tick.ask);
   bool fvgSell2 = CheckMiniFVG(sym, false, tick.bid, tick.ask);

   bool canBuyBasket  = (trendBull2 && ofBuy2 && bosBuy2 && fvgBuy2);
   bool canSellBasket = (trendBear2 && ofSell2 && bosSell2 && fvgSell2);

   double lotFirst = CalculateLot(sym);
   if(lotFirst <= 0)
      return;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(sym);

   if(canBuyBasket && !canSellBasket)
     {
      bool res = trade.Buy(lotFirst, sym, tick.ask, 0.0, 0.0, "Basket BUY first");
      if(res) Print("Basket BUY dimulai.");
     }
   else if(canSellBasket && !canBuyBasket)
     {
      bool res = trade.Sell(lotFirst, sym, tick.bid, 0.0, 0.0, "Basket SELL first");
      if(res) Print("Basket SELL dimulai.");
     }
  }

//+------------------------------------------------------------------+
//| Hitung lot per entry                                             |
//+------------------------------------------------------------------+
double CalculateLot(string sym)
  {
   if(!InpUseRiskPercent)
      return(InpFixedLot);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0) return(0);

   // risk per trade (ingat ini per entry, basket bisa multi)
   double riskMoney = equity * (InpRiskPercent / 100.0);
   if(riskMoney <= 0) return(InpFixedLot);

   double tickValue    = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize     = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double pointPerTick = tickSize / _Point;

   double valuePerPointPerLot = (tickValue / pointPerTick);
   if(valuePerPointPerLot <= 0)
      return(InpFixedLot);

   // asumsikan SL virtual 200 points hanya untuk hitung lot (bukan SL beneran)
   double slPoints = 200.0;
   double lot = riskMoney / (slPoints * valuePerPointPerLot);

   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   lot = MathFloor(lot/step)*step;

   return(lot);
  }

//+------------------------------------------------------------------+
//| Volatility Engine (ATR filter)                                  |
//+------------------------------------------------------------------+
bool CheckVolatility(string sym)
  {
   if(!InpUseVolatility || handleATR==INVALID_HANDLE)
      return(true);

   double atrBuf[1];
   if(CopyBuffer(handleATR,0,0,1,atrBuf) < 1)
      return(true);

   double atrPoints = atrBuf[0] / _Point;
   if(atrPoints < InpATR_MinPoints) return(false);
   if(atrPoints > InpATR_MaxPoints) return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Orderflow: volume + body                                        |
//+------------------------------------------------------------------+
bool CheckOrderflow(string sym, bool isBuy)
  {
   if(!InpUseOrderflow)
      return(true);

   int needBars = InpOF_VolumeLookback + 1;
   if(Bars(sym, InpTF) <= needBars)
      return(true);

   double vol[];
   if(CopyTickVolume(sym, InpTF, 0, needBars, vol) < needBars)
      return(true);

   double currentVol = vol[0];
   double sum = 0.0;
   for(int i=1; i<needBars; i++)
      sum += vol[i];

   double avg = sum / (needBars-1);
   if(avg <= 0) return(true);

   if(currentVol < avg * InpOF_VolumeFactor)
      return(false);

   double closeBuf[3], openBuf[3];
   if(CopyClose(sym, InpTF, 0, 3, closeBuf) < 3) return(true);
   if(CopyOpen(sym, InpTF, 0, 3, openBuf)  < 3) return(true);

   double bodyNow = closeBuf[0] - openBuf[0];
   if(isBuy  && bodyNow <= 0) return(false);
   if(!isBuy && bodyNow >= 0) return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Micro BOS/CHoCH                                                 |
//+------------------------------------------------------------------+
bool CheckMicroStructure(string sym, bool isBuy)
  {
   if(!InpUseMicroStructure)
      return(true);

   int needBars = InpBOS_Lookback + 3;
   if(Bars(sym, InpTF) <= needBars)
      return(true);

   double highBuf[], lowBuf[], closeBuf[3];
   if(CopyHigh(sym, InpTF, 0, needBars, highBuf) < needBars) return(true);
   if(CopyLow(sym, InpTF, 0, needBars, lowBuf)   < needBars) return(true);
   if(CopyClose(sym, InpTF, 0, 3, closeBuf)      < 3)        return(true);

   double currentClose = closeBuf[0];
   int dirPrev = sign(closeBuf[1] - closeBuf[2]);
   int dirNow  = sign(closeBuf[0] - closeBuf[1]);

   double highest = highBuf[1];
   double lowest  = lowBuf[1];
   for(int i=2; i<InpBOS_Lookback+1; i++)
     {
      if(highBuf[i] > highest) highest = highBuf[i];
      if(lowBuf[i]  < lowest)  lowest  = lowBuf[i];
     }

   if(isBuy)
     {
      bool bos  = (currentClose > highest);
      bool choch= (dirPrev < 0 && dirNow > 0);
      if(!bos || !choch) return(false);
     }
   else
     {
      bool bos  = (currentClose < lowest);
      bool choch= (dirPrev > 0 && dirNow < 0);
      if(!bos || !choch) return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Mini FVG (3 candle)                                             |
//+------------------------------------------------------------------+
bool CheckMiniFVG(string sym, bool isBuy, double bid, double ask)
  {
   if(!InpUseFVG)
      return(true);

   if(Bars(sym, InpTF) < 3)
      return(true);

   double highBuf[3], lowBuf[3];
   if(CopyHigh(sym, InpTF, 0, 3, highBuf) < 3) return(true);
   if(CopyLow(sym, InpTF, 0, 3, lowBuf)   < 3) return(true);

   double high2 = highBuf[2];
   double low2  = lowBuf[2];
   double high1 = highBuf[1];
   double low1  = lowBuf[1];

   double price = isBuy ? bid : ask;

   if(isBuy)
     {
      // Bullish FVG: Low[1] > High[2]
      if(low1 <= high2)
         return(false);

      double fvgLow  = high2;
      double fvgHigh = low1;

      double distPts = MathAbs((price - fvgHigh) / _Point);
      if(distPts > InpFVG_MaxDistancePts) return(false);

      if(price < fvgLow || price > fvgHigh + InpFVG_MaxDistancePts*_Point)
         return(false);
     }
   else
     {
      // Bearish FVG: High[1] < Low[2]
      if(high1 >= low2)
         return(false);

      double fvgHigh = low2;
      double fvgLow  = high1;

      double distPts = MathAbs((price - fvgLow) / _Point);
      if(distPts > InpFVG_MaxDistancePts) return(false);

      if(price > fvgHigh || price < fvgLow - InpFVG_MaxDistancePts*_Point)
         return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Ambil info basket (semua posisi symbol+magic)                   |
//+------------------------------------------------------------------+
void GetBasketInfo(string sym, ulong magic,
                   int &count, double &totalProfit, double &totalVolume,
                   double &avgPrice, long &direction, double &lastEntryPrice)
  {
   count = 0;
   totalProfit = 0.0;
   totalVolume = 0.0;
   avgPrice = 0.0;
   direction = -1;
   lastEntryPrice = 0.0;

   datetime lastTime = 0;

   int total = PositionsTotal();
   for(int i=0; i<total; i++)
     {
      if(!PositionSelectByIndex(i))
         continue;

      ulong  ticket = PositionGetInteger(POSITION_TICKET);
      string psym   = PositionGetString(POSITION_SYMBOL);
      long   pmag   = PositionGetInteger(POSITION_MAGIC);
      if(ticket==0 || psym != sym || pmag != (long)magic)
         continue;

      double   vol   = PositionGetDouble(POSITION_VOLUME);
      double   pOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      double   prof  = PositionGetDouble(POSITION_PROFIT);
      long     pType = PositionGetInteger(POSITION_TYPE);
      datetime t     = (datetime)PositionGetInteger(POSITION_TIME);

      count++;
      totalProfit += prof;
      totalVolume += vol;
      avgPrice    += pOpen * vol;
      direction    = pType;

      if(t > lastTime)
        {
         lastTime = t;
         lastEntryPrice = pOpen;
        }
     }

   if(totalVolume > 0.0)
      avgPrice /= totalVolume;
  }

//+------------------------------------------------------------------+
//| Handle Basket Exit (TP, SL, Trail)                              |
//+------------------------------------------------------------------+
bool HandleBasketExit(string sym, double basketProfit)
  {
   // hard TP/SL uang
   if(basketProfit >= InpBasketTPMoney)
     {
      CloseAllBasket(sym, "BasketTP");
      return(true);
     }

   if(basketProfit <= InpBasketSLMoney)
     {
      CloseAllBasket(sym, "BasketSL");
      return(true);
     }

   // trailing basket
   if(!InpUseBasketTrail)
      return(false);

   if(basketProfit >= InpBasketTrailStart)
     {
      if(!g_basketTrailActive)
        {
         g_basketTrailActive = true;
         g_bestBasketProfit  = basketProfit;
        }
      else
        {
         if(basketProfit > g_bestBasketProfit)
            g_bestBasketProfit = basketProfit;

         double retrace = g_bestBasketProfit - basketProfit;
         if(retrace >= InpBasketTrailStep)
           {
            CloseAllBasket(sym, "BasketTrail");
            return(true);
           }
        }
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Close semua posisi dalam basket                                 |
//+------------------------------------------------------------------+
void CloseAllBasket(string sym, string reason)
  {
   trade.SetExpertMagicNumber(InpMagic);

   int total = PositionsTotal();
   for(int i=total-1; i>=0; i--)
     {
      if(!PositionSelectByIndex(i))
         continue;

      string psym = PositionGetString(POSITION_SYMBOL);
      long   pmag = PositionGetInteger(POSITION_MAGIC);
      if(psym != sym || pmag != (long)InpMagic)
         continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      if(ticket==0)
         continue;

      bool closed = trade.PositionClose(ticket);

      if(closed)
         Print("Close basket ticket=", ticket, " reason=", reason);
      else
         Print("Gagal close basket ticket=", ticket, " reason=", reason,
               " err=", GetLastError());
     }

   g_bestBasketProfit  = 0.0;
   g_basketTrailActive = false;
  }
//+------------------------------------------------------------------+
