//+------------------------------------------------------------------+
//| V19 FX Prop Desk — MT4 Trade Executor v2.07                     |
//| FIXES APPLIED:                                                   |
//|  1-16. (see v2.06 header)                                        |
//| ──────────────────────────────────────────────────────────────── |
//| v2.07 CRITICAL FIX:                                             |
//| 17. Duplicate symbol entry fix (v2.06)                          |
//| 18. FIX: Partial close loop bug                                 |
//|     Root cause: MarkPartialClosed() stored in RAM array —       |
//|     array resets on EA reinit/reattach, so same ticket could    |
//|     be partially closed many times across restarts.             |
//|     Also: r >= 2.0 check ran every tick even after partial,     |
//|     causing 0.72→0.36→0.18→0.09→... cascade.                   |
//|     Fix A: GlobalVariable "PC_{ticket}" — persists across       |
//|             EA restart, MT4 restart, until explicitly deleted.  |
//|     Fix B: min lot guard — skip partial if OrderLots() <= 0.02  |
//|     Fix C: after partial close, move SL to entry−20% profit     |
//|             so worst case = locked profit, not 0                |
//|     Fix D: Partial_Close_At_R input (default 2.0) — user can   |
//|             change trigger without recompile                    |
//|     Fix E: Partial_Close_Ratio input (default 0.5 = 50%)       |
//+------------------------------------------------------------------+
#property copyright "V19 FX Prop Desk"
#property version   "2.08"
#property strict

#include <stdlib.mqh>

// ── Inputs ───────────────────────────────────────────────────────────
input string FastAPI_Base           = "http://127.0.0.1";
input string API_Key                = "f9e369ad5592a0dcd33c78c4e33bd382";
input string Symbol_List            = "EURUSD,GBPUSD,USDJPY.y,AUDUSD,USDCAD,GBPJPY";
input int    Poll_Seconds           = 60;
input int    Magic_Number           = 19001;
input int    Slippage               = 3;
input bool   Enable_Trading         = true;
input double BE_Buffer_Pips         = 1.0;
input int    Friday_Close_Hour      = 20;
input string Telegram_Token         = "";
input string Telegram_Chat_ID       = "";
input bool   Debug                  = true;

// ── Position / Risk controls ─────────────────────────────────────────
input int    Max_Open_Positions     = 5;
input double Portfolio_Max_Risk_Pct = 6.0;
input double Risk_Per_Trade_Pct     = 1.0;
input bool   Enable_Session_Filter  = false;
input bool   Log_Reject_Reasons     = true;

// ── FIX 18D/E: Partial close inputs ─────────────────────────────────
input double Partial_Close_At_R     = 2.0;   // trigger at +N × R
input double Partial_Close_Ratio    = 0.5;   // fraction to close (0.5 = 50%)

// ── Circuit breaker ──────────────────────────────────────────────────
input double CB_Level1_DD_Pct       = 3.0;
input double CB_Level2_DD_Pct       = 5.0;
input double CB_Level3_DD_Pct       = 8.0;

// ── CB state ─────────────────────────────────────────────────────────
int    cb_level = 0;
string cb_date  = "";

// ── Closed-trade reporting ───────────────────────────────────────────
int reported_closed_tickets[500];
int n_reported_closed = 0;

// ── FIX 17B: In-memory opened symbols (broker delay guard) ───────────
string g_opened_symbols[50];
int    g_opened_count = 0;

bool IsOpenedSymbol(string sym) {
    for (int i = 0; i < g_opened_count; i++)
        if (g_opened_symbols[i] == sym) return true;
    return false;
}
void MarkOpenedSymbol(string sym) {
    if (!IsOpenedSymbol(sym) && g_opened_count < 50)
        g_opened_symbols[g_opened_count++] = sym;
}
void ClearOpenedSymbol(string sym) {
    for (int i = 0; i < g_opened_count; i++) {
        if (g_opened_symbols[i] == sym) {
            for (int j = i; j < g_opened_count - 1; j++)
                g_opened_symbols[j] = g_opened_symbols[j+1];
            g_opened_symbols[--g_opened_count] = "";
            return;
        }
    }
}

// ── FIX 18A: GlobalVariable-based partial close tracking ─────────────
// "PC_{ticket}" persists across EA reinit / MT4 restart
// Unlike RAM arrays which reset on reattach
string GV_PC(int ticket) { return "PC_" + IntegerToString(ticket); }

bool IsPartialClosed(int ticket) {
    return GlobalVariableCheck(GV_PC(ticket));
}
void MarkPartialClosed(int ticket) {
    GlobalVariableSet(GV_PC(ticket), (double)TimeCurrent());
}
void CleanupPartialGV(int ticket) {
    // Call when trade fully closed — removes stale GV
    string gv = GV_PC(ticket);
    if (GlobalVariableCheck(gv)) GlobalVariableDel(gv);
}

// ── State ────────────────────────────────────────────────────────────
string symbols[];
int    num_symbols = 0;

// ── JSON helpers ─────────────────────────────────────────────────────
double JsonDouble(string body, string key) {
    string search = "\"" + key + "\":";
    int pos = StringFind(body, search);
    if (pos < 0) return 0.0;
    pos += StringLen(search);
    if (StringSubstr(body, pos, 4) == "null") return 0.0;
    int end  = StringFind(body, ",", pos);
    int end2 = StringFind(body, "}", pos);
    if (end < 0 || (end2 >= 0 && end2 < end)) end = end2;
    if (end < 0) return 0.0;
    return StringToDouble(StringSubstr(body, pos, end - pos));
}
string JsonString(string body, string key) {
    string search = "\"" + key + "\":\"";
    int pos = StringFind(body, search);
    if (pos < 0) return "";
    pos += StringLen(search);
    int end = StringFind(body, "\"", pos);
    if (end < 0) return "";
    return StringSubstr(body, pos, end - pos);
}
int JsonInt(string body, string key) { return (int)JsonDouble(body, key); }

// ── Helpers ──────────────────────────────────────────────────────────
string FormatTimestamp(datetime dt) {
    string s = TimeToString(dt, TIME_DATE|TIME_SECONDS);
    StringReplace(s, ".", "-"); StringReplace(s, ".", "-");
    StringReplace(s, " ", "T");
    return s;
}
string GETUrl(string ep) {
    if (StringLen(API_Key) > 0)
        return FastAPI_Base + ep +
               (StringFind(ep,"?") >= 0 ? "&" : "?") +
               "api_key=" + API_Key;
    return FastAPI_Base + ep;
}
string POSTHeaders() {
    string h = "Content-Type: application/json\r\n";
    if (StringLen(API_Key) > 0) h += "X-API-Key: " + API_Key + "\r\n";
    return h;
}

int GetOpenCount() {
    int n = 0;
    for (int i = 0; i < OrdersTotal(); i++) {
        if (!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
        if (OrderMagicNumber() == Magic_Number) n++;
    }
    return n;
}

double GetTotalOpenRiskPct() {
    double total = 0, bal = AccountBalance();
    if (bal <= 0) return 0;
    for (int i = 0; i < OrdersTotal(); i++) {
        if (!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
        if (OrderMagicNumber() != Magic_Number) continue;
        double sl = OrderStopLoss();
        if (sl == 0) continue;
        double sl_dist  = MathAbs(OrderOpenPrice() - sl);
        double pip_size = (StringFind(OrderSymbol(),"JPY") >= 0) ? 0.01 : 0.0001;
        double pip_val  = MarketInfo(OrderSymbol(),MODE_TICKVALUE) /
                          MarketInfo(OrderSymbol(),MODE_TICKSIZE) * pip_size;
        total += (sl_dist / pip_size) * pip_val * OrderLots();
    }
    return total / bal * 100.0;
}

bool HasOpenPosition(string sym) {
    for (int i = 0; i < OrdersTotal(); i++) {
        if (!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
        if (OrderSymbol()==sym && OrderMagicNumber()==Magic_Number) return true;
    }
    return false;
}

string GetSession() {
    int  h  = TimeHour(TimeGMT());
    bool lo = (h >= 8  && h < 17);
    bool ny = (h >= 13 && h < 22);
    if (lo && ny) return "OVERLAP";
    if (lo)       return "LONDON";
    if (ny)       return "NEW_YORK";
    return "OFF_SESSION";
}

string TodayString() {
    datetime now = TimeGMT();
    return StringFormat("%04d%02d%02d",TimeYear(now),TimeMonth(now),TimeDay(now));
}

// ── Init / Deinit ────────────────────────────────────────────────────
int OnInit() {
    string raw = Symbol_List;
    StringReplace(raw, " ", "");
    string tmp[];
    int n = StringSplit(raw, ',', tmp);
    ArrayResize(symbols, n);
    for (int i = 0; i < n; i++) symbols[i] = tmp[i];
    num_symbols   = n;
    g_opened_count = 0;
    for (int j = 0; j < ArraySize(g_opened_symbols); j++) g_opened_symbols[j] = "";
    EventSetTimer(Poll_Seconds);
    Print("[Executor v2.07] Initialized"
          " | symbols=", Symbol_List,
          " | max_pos=", Max_Open_Positions,
          " | portfolio=", Portfolio_Max_Risk_Pct, "%"
          " | risk/trade=", Risk_Per_Trade_Pct, "%"
          " | partial_at=+", Partial_Close_At_R, "R x", Partial_Close_Ratio);
    return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { EventKillTimer(); }

// ── Timer ────────────────────────────────────────────────────────────
void OnTimer() {
    string today = TodayString();
    if (cb_date != today) { cb_level = 0; cb_date = today; }

    DetectAndReportClosedTrades();
    if (!Enable_Trading) return;
    if (IsFridayClose()) { CloseAllPositions("FRIDAY_CLOSE"); return; }

    CheckCircuitBreaker();
    if (cb_level == 3) return;

    ManageOpenTrades();
    if (cb_level == 2) { Level2ProtectTrades(); return; }
    if (cb_level >= 1) return;

    EvaluateSignals();
}

// ── Circuit Breaker ──────────────────────────────────────────────────
bool IsFridayClose() {
    datetime now = TimeGMT();
    return (DayOfWeek()==5 && TimeHour(now) >= Friday_Close_Hour);
}

void CheckCircuitBreaker() {
    double equity = AccountEquity(), balance = AccountBalance();
    if (equity <= 0 || balance <= 0) return;
    double realized   = FetchRealizedDailyLoss();
    double total_loss = realized + MathMin(0, equity - balance);
    double dd_pct     = MathAbs(total_loss) / balance * 100.0;
    int new_level = 0;
    if      (dd_pct >= CB_Level3_DD_Pct) new_level = 3;
    else if (dd_pct >= CB_Level2_DD_Pct) new_level = 2;
    else if (dd_pct >= CB_Level1_DD_Pct) new_level = 1;
    if (new_level <= cb_level) return;
    cb_level = new_level;
    string msg = StringFormat("[CB] LEVEL %d — DD=%.2f%%", cb_level, dd_pct);
    Print(msg); SendTelegram(msg);
    if (cb_level == 3) CloseAllPositions("CB_L3");
}

double FetchRealizedDailyLoss() {
    string url = GETUrl("/analytics/drawdown");
    char dummy[], result[]; string rh;
    int res = WebRequest("GET", url, "", 5000, dummy, result, rh);
    if (res != 200) { if (Debug) Print("[Executor] drawdown HTTP=",res); return 0.0; }
    string body = CharArrayToString(result);
    int pos = StringFind(body, "\"daily_loss\":");
    if (pos < 0) return 0.0;
    pos += 13;
    int end = StringFind(body, ",", pos);
    if (end < 0) end = StringFind(body, "}", pos);
    if (end < 0) return 0.0;
    return -MathAbs(StringToDouble(StringSubstr(body, pos, end-pos)));
}

// ── Signal Evaluation ────────────────────────────────────────────────
void EvaluateSignals() {
    for (int i = 0; i < num_symbols; i++) {
        string sym = symbols[i];

        // FIX 17A: HasOpenPosition first
        if (HasOpenPosition(sym)) continue;

        // FIX 17B: broker-delay guard
        if (IsOpenedSymbol(sym)) {
            if (!HasOpenPosition(sym)) ClearOpenedSymbol(sym);
            else continue;
        }

        // FIX 14: position count cap
        if (GetOpenCount() >= Max_Open_Positions) {
            if (Debug) Print("[Executor] Max pos (", Max_Open_Positions, ") — stop");
            break;
        }

        // FIX 15: portfolio exposure cap
        double cur_risk = GetTotalOpenRiskPct();
        if (cur_risk + Risk_Per_Trade_Pct > Portfolio_Max_Risk_Pct) {
            if (Debug) Print("[Executor] Portfolio cap (",
                             DoubleToStr(cur_risk,2),"% + ",Risk_Per_Trade_Pct,
                             "% > ",Portfolio_Max_Risk_Pct,"%) — stop");
            break;
        }

        int    sc=0; double rsi=0,adx=0,dip=0,dim=0,e50=0,e200=0;
        string rej="";
        string dir = FetchSignal(sym, sc, rsi, adx, dip, dim, e50, e200, rej);

        if (dir == "NO_TRADE" || dir == "") {
            if (Log_Reject_Reasons && dir == "NO_TRADE") LogRejectReason(sym,sc,rej);
            continue;
        }
        if (Enable_Session_Filter && GetSession()=="OFF_SESSION") {
            if (Log_Reject_Reasons) LogRejectReason(sym,sc,"OFF_SESSION");
            continue;
        }
        OpenTrade(sym, dir, sc, rsi, adx, dip, dim, e50, e200);
    }
}

string FetchSignal(string sym,
                   int &sc, double &rsi, double &adx,
                   double &dip, double &dim, double &e50, double &e200,
                   string &rej) {
    double ps  = (StringFind(sym,"JPY")>=0) ? 0.01 : 0.0001;
    double pv  = MarketInfo(sym,MODE_TICKVALUE)/MarketInfo(sym,MODE_TICKSIZE)*ps;
    string ep  = StringFormat("/signals/evaluate/%s?timeframe=H1&pip_value=%.6f",sym,pv);
    string url = GETUrl(ep);
    char dummy[], result[]; string rh;
    int res = WebRequest("GET", url, "", 5000, dummy, result, rh);
    if (res != 200) { if(Debug) Print("[Executor] Signal HTTP=",res," ",sym); return ""; }
    string body = CharArrayToString(result);
    int pos = StringFind(body,"\"direction\":\"");
    if (pos<0) return "";
    pos += 13;
    int end = StringFind(body,"\"",pos);
    if (end<0) return "";
    string dir = StringSubstr(body,pos,end-pos);
    sc   = JsonInt   (body,"score");
    rsi  = JsonDouble(body,"rsi");
    adx  = JsonDouble(body,"adx");
    dip  = JsonDouble(body,"di_plus");
    dim  = JsonDouble(body,"di_minus");
    e50  = JsonDouble(body,"ema50");
    e200 = JsonDouble(body,"ema200");
    rej  = JsonString(body,"reject_reason");
    if (Debug) Print("[Executor] Signal ",sym," → ",dir," score=",sc," reject=",rej);
    return dir;
}

void LogRejectReason(string sym, int score, string reason) {
    string body = StringFormat(
        "{\"symbol\":\"%s\",\"timeframe\":\"H1\","
        "\"direction\":\"NO_TRADE\",\"score\":%d,"
        "\"reject_reason\":\"%s\",\"timestamp\":\"%s\"}",
        sym, score, reason, FormatTimestamp(TimeCurrent()));
    string url = FastAPI_Base + "/signals/log";
    char post[], result[]; string rh;
    StringToCharArray(body, post, 0, StringLen(body));
    int res = WebRequest("POST", url, POSTHeaders(), 5000, post, result, rh);
    if (Debug && res!=200 && res!=201 && res!=404)
        Print("[Executor] LogReject HTTP=",res," ",sym);
}

// ── Open Trade ───────────────────────────────────────────────────────
void OpenTrade(string sym, string dir,
               int sc, double rsi, double adx,
               double dip, double dim, double e50, double e200) {
    double atr = iATR(sym,60,14,1);
    if (atr <= 0) { Print("[Executor] ATR=0 for ",sym); return; }

    double price; int cmd;
    if (dir=="BUY") { price=MarketInfo(sym,MODE_ASK); cmd=OP_BUY; }
    else            { price=MarketInfo(sym,MODE_BID); cmd=OP_SELL; }

    double sl_dist = atr*1.5, tp_dist = atr*3.0;
    double sl = (cmd==OP_BUY) ? price-sl_dist : price+sl_dist;
    double tp = (cmd==OP_BUY) ? price+tp_dist : price-tp_dist;

    double equity   = AccountEquity();
    double risk_amt = equity * (Risk_Per_Trade_Pct/100.0);
    double ps       = (StringFind(sym,"JPY")>=0) ? 0.01 : 0.0001;
    double pv       = MarketInfo(sym,MODE_TICKVALUE)/MarketInfo(sym,MODE_TICKSIZE)*ps;
    double sl_pips  = sl_dist/ps;
    double lots     = 0.01;
    if (pv>0 && sl_pips>0) lots = MathFloor((risk_amt/(sl_pips*pv))*100)/100.0;
    lots = MathMax(MarketInfo(sym,MODE_MINLOT), MathMin(lots,MarketInfo(sym,MODE_MAXLOT)));

    double spread = MarketInfo(sym,MODE_SPREAD)*MarketInfo(sym,MODE_POINT);
    if (spread > ps*4) { if(Debug) Print("[Executor] Spread wide ",sym); return; }

    int ticket = OrderSend(sym,cmd,lots,price,Slippage,sl,tp,
                           "V19_"+dir,Magic_Number,0,
                           cmd==OP_BUY?clrBlue:clrRed);
    if (ticket < 0) {
        Print("[Executor] OrderSend failed ",sym," err=",GetLastError()); return;
    }

    MarkOpenedSymbol(sym);  // FIX 17B
    string msg = StringFormat(
        "[Trade OPEN] %s %s | lots=%.2f price=%.5f SL=%.5f TP=%.5f risk=%.1f%% ticket=%d",
        dir,sym,lots,price,sl,tp,Risk_Per_Trade_Pct,ticket);
    if (Debug) Print(msg); SendTelegram(msg);
    NotifyBackend(ticket,sym,dir,price,sl,tp,lots,equity,risk_amt,atr,sc,rsi,adx,dip,dim,e50,e200);
}

// ── Manage Open Positions ────────────────────────────────────────────
void ManageOpenTrades() {
    for (int i = OrdersTotal()-1; i >= 0; i--) {
        if (!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
        if (OrderMagicNumber() != Magic_Number) continue;

        string sym    = OrderSymbol();
        int    ticket = OrderTicket();
        double cur    = (OrderType()==OP_BUY) ? MarketInfo(sym,MODE_BID)
                                              : MarketInfo(sym,MODE_ASK);
        double entry   = OrderOpenPrice();
        double sl      = OrderStopLoss();
        double sl_dist = MathAbs(entry-sl);
        if (sl_dist == 0) continue;

        double atr     = iATR(sym,60,14,0);
        double r       = (OrderType()==OP_BUY) ? (cur-entry)/sl_dist
                                               : (entry-cur)/sl_dist;
        double ps      = (StringFind(sym,"JPY")>=0) ? 0.01 : 0.0001;
        double be_sl   = (OrderType()==OP_BUY) ? entry+ps*BE_Buffer_Pips
                                               : entry-ps*BE_Buffer_Pips;

        // ── Break-even at +1R ───────────────────────────────────────
        bool be_set = (OrderType()==OP_BUY) ? (sl >= be_sl-ps*0.1)
                                            : (sl <= be_sl+ps*0.1);
        if (r >= 1.0 && !be_set)
            if (OrderModify(ticket,entry,be_sl,OrderTakeProfit(),0,clrYellow))
                if (Debug) Print("[Mgr] BE moved ticket=",ticket);

        // ── FIX 18: Partial close — once only via GlobalVariable ────
        if (r >= Partial_Close_At_R && !IsPartialClosed(ticket)) {
            // FIX 18B: skip if position already too small
            if (OrderLots() <= 0.02) {
                MarkPartialClosed(ticket);  // prevent future attempts
                if (Debug) Print("[Mgr] Lot too small for partial — skip ticket=",ticket);
            } else {
                double close_lot = NormalizeDouble(OrderLots()*Partial_Close_Ratio, 2);
                close_lot = MathMax(close_lot, MarketInfo(sym,MODE_MINLOT));

                // FIX 18A: mark BEFORE close attempt — prevents repeat on broker error
                MarkPartialClosed(ticket);

                bool ok = OrderClose(ticket, close_lot, cur, Slippage, clrOrange);
                if (ok) {
                    string msg = StringFormat(
                        "[Trade PARTIAL] ticket=%d %s %.0f%% @ %.5f",
                        ticket, sym, Partial_Close_Ratio*100, cur);
                    if (Debug) Print(msg); SendTelegram(msg);

                    // FIX 18C: move SL to lock 80% of profit after partial close
                    // new_sl = entry + (cur-entry)*0.8  (lock 80% of profit distance)
                    double profit_dist = MathAbs(cur - entry);
                    double lock_dist   = profit_dist * 0.80;
                    double new_sl;
                    if (OrderType()==OP_BUY)
                        new_sl = entry + lock_dist;
                    else
                        new_sl = entry - lock_dist;

                    // Ensure new_sl is better than current sl
                    bool sl_ok = (OrderType()==OP_BUY) ? (new_sl > sl) : (new_sl < sl || sl==0);
                    if (sl_ok) {
                        if (OrderModify(ticket, entry, new_sl, OrderTakeProfit(), 0, clrGreen))
                            if (Debug) Print("[Mgr] SL locked at 80% profit ticket=",ticket,
                                             " new_sl=",DoubleToStr(new_sl,5));
                    }
                } else {
                    Print("[Mgr] Partial close failed ticket=",ticket," err=",GetLastError());
                    // Note: already marked — will NOT retry (intentional)
                }
            }
        }

        // ── Trailing stop (only after partial close, ATR×1.5) ───────
        if (r >= Partial_Close_At_R && IsPartialClosed(ticket) && atr > 0) {
            double trail  = atr*1.5;
            double new_sl = (OrderType()==OP_BUY) ? cur-trail : cur+trail;
            if (OrderType()==OP_BUY && new_sl > sl)
                if (!OrderModify(ticket,entry,new_sl,OrderTakeProfit(),0,clrGreen) && Debug)

                    Print("[OrderModify] failed ticket=",ticket," err=",GetLastError());
            else if (OrderType()!=OP_BUY && (new_sl < sl || sl==0))
                if (!OrderModify(ticket,entry,new_sl,OrderTakeProfit(),0,clrGreen) && Debug)

                    Print("[OrderModify] failed ticket=",ticket," err=",GetLastError());
        }
    }
}

// ── Level 2: close losers, protect winners ───────────────────────────
void Level2ProtectTrades() {
    for (int i = OrdersTotal()-1; i >= 0; i--) {
        if (!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
        if (OrderMagicNumber() != Magic_Number) continue;
        string sym    = OrderSymbol();
        int    ticket = OrderTicket();
        double cur    = (OrderType()==OP_BUY)?MarketInfo(sym,MODE_BID):MarketInfo(sym,MODE_ASK);
        double pnl    = OrderProfit()+OrderSwap()+OrderCommission();
        if (pnl < 0) {
            if (OrderClose(ticket,OrderLots(),cur,Slippage,clrRed)) {
                string msg=StringFormat("[CB-L2] Closed loser ticket=%d %s pnl=%.2f",ticket,sym,pnl);
                Print(msg); SendTelegram(msg);
            }
            continue;
        }
        double entry  = OrderOpenPrice();
        double sl     = OrderStopLoss();
        double ps     = (StringFind(sym,"JPY")>=0)?0.01:0.0001;
        double be_sl  = (OrderType()==OP_BUY)?entry+ps*BE_Buffer_Pips:entry-ps*BE_Buffer_Pips;
        bool be_set   = (OrderType()==OP_BUY)?(sl>=be_sl-ps*0.1):(sl<=be_sl+ps*0.1);
        if (!be_set)
            if (OrderModify(ticket,entry,be_sl,OrderTakeProfit(),0,clrOrange))
                if (Debug) Print("[CB-L2] BE set ticket=",ticket);
        double atr = iATR(sym,60,14,0);
        if (atr > 0) {
            double new_sl=(OrderType()==OP_BUY)?cur-atr:cur+atr;
            if (OrderType()==OP_BUY && new_sl>sl)
                if (!OrderModify(ticket,entry,new_sl,OrderTakeProfit(),0,clrGreen) && Debug)

                    Print("[OrderModify] failed ticket=",ticket," err=",GetLastError());
            else if (OrderType()!=OP_BUY && (new_sl<sl||sl==0))
                if (!OrderModify(ticket,entry,new_sl,OrderTakeProfit(),0,clrGreen) && Debug)

                    Print("[OrderModify] failed ticket=",ticket," err=",GetLastError());
        }
    }
}

// ── Detect and report closed trades ─────────────────────────────────
string FormatISO8601(datetime dt) {
    string s=TimeToString(dt,TIME_DATE|TIME_SECONDS);
    StringReplace(s,".","_"); StringReplace(s,"_","-");
    StringReplace(s,".","-"); StringReplace(s," ","T");
    return s;
}

bool IsReportedClosed(int ticket) {
    for (int i=0;i<n_reported_closed;i++) if(reported_closed_tickets[i]==ticket) return true;
    return false;
}
void MarkReportedClosed(int ticket) {
    if (n_reported_closed<500) reported_closed_tickets[n_reported_closed++]=ticket;
}

void DetectAndReportClosedTrades() {
    int total = OrdersHistoryTotal();
    for (int i = total-1; i >= 0; i--) {
        if (!OrderSelect(i,SELECT_BY_POS,MODE_HISTORY)) continue;
        if (OrderMagicNumber() != Magic_Number) continue;
        int ticket = OrderTicket();
        if (IsReportedClosed(ticket)) continue;
        datetime close_time = OrderCloseTime();
        if (close_time==0) continue;
        if (TimeCurrent()-close_time > 604800) { MarkReportedClosed(ticket); continue; }

        // FIX 17B + 18A: cleanup on close
        ClearOpenedSymbol(OrderSymbol());
        CleanupPartialGV(ticket);

        double cp=OrderClosePrice(), tp=OrderTakeProfit(), sl=OrderStopLoss();
        double ps=(StringFind(OrderSymbol(),"JPY")>=0)?0.01:0.0001;
        string reason="MANUAL";
        if (tp>0 && MathAbs(cp-tp)<=ps*3) reason="TP";
        else if (sl>0 && MathAbs(cp-sl)<=ps*3) reason="SL";

        string body=StringFormat(
            "{\"exit_price\":%.6f,\"commission\":%.2f,\"swap\":%.2f,"
            "\"exit_reason\":\"%s\",\"closed_at\":\"%s\",\"account_equity\":%.2f}",
            cp,OrderCommission(),OrderSwap(),reason,FormatISO8601(close_time),AccountEquity());

        string url=FastAPI_Base+"/trades/close/by-ticket/"+IntegerToString(ticket);
        char post[],result[]; string rh;
        StringToCharArray(body,post,0,StringLen(body));
        int res=WebRequest("POST",url,POSTHeaders(),5000,post,result,rh);
        if (res==200||res==404) {
            MarkReportedClosed(ticket);
            if (Debug) Print("[Executor] Close reported ticket=",ticket," reason=",reason," HTTP=",res);
        } else {
            if (Debug) Print("[Executor] Close report failed ticket=",ticket," HTTP=",res);
        }
    }
}

// ── Close All / Protect ───────────────────────────────────────────────
void CloseAllPositions(string reason) {
    for (int i=OrdersTotal()-1;i>=0;i--) {
        if (!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
        if (OrderMagicNumber()!=Magic_Number) continue;
        string sym=OrderSymbol(); int ticket=OrderTicket();
        double entry=OrderOpenPrice();
        double profit=OrderProfit()+OrderSwap()+OrderCommission();
        double cur=(OrderType()==OP_BUY)?MarketInfo(sym,MODE_BID):MarketInfo(sym,MODE_ASK);
        if (profit < 0) {
            bool closed = OrderClose(ticket,OrderLots(),cur,Slippage,clrRed);
            if (closed) {
                string msg=StringFormat("[Trade CLOSE] ticket=%d %s reason=%s (loss=%.2f)",ticket,sym,reason,profit);
                if(Debug)Print(msg); SendTelegram(msg);
            } else if (Debug) {
                Print("[Trade CLOSE] failed ticket=",ticket," err=",GetLastError());
            }
        } else {
            double atr=iATR(sym,60,14,0);
            double dist=MathAbs(cur-entry);
            double buf=MathMax(dist*0.20,atr*0.3);
            buf=MathMin(buf,atr*2.0);
            double new_sl=(OrderType()==OP_BUY)?cur-buf:cur+buf;
            if (OrderModify(ticket,entry,new_sl,OrderTakeProfit(),0,clrYellow)) {
                double pct=dist>0?(dist-buf)/dist*100:0;
                string msg=StringFormat("[Trade LOCK] ticket=%d %s SL=%.5f (~%.0f%% locked) reason=%s",ticket,sym,new_sl,pct,reason);
                if(Debug)Print(msg); SendTelegram(msg);
            }
        }
    }
}

// ── Notify Backend ────────────────────────────────────────────────────
void NotifyBackend(int ticket,string sym,string dir,
                   double price,double sl,double tp,
                   double lots,double equity,double risk_amt,double atr,
                   int sc,double rsi,double adx,double dip,double dim,double e50,double e200) {
    string body=StringFormat(
        "{\"ticket\":%d,\"symbol\":\"%s\",\"direction\":\"%s\","
        "\"entry_price\":%.6f,\"stop_loss\":%.6f,\"take_profit\":%.6f,"
        "\"lot_size\":%.2f,\"account_equity\":%.2f,\"risk_amount\":%.2f,"
        "\"atr_at_entry\":%.6f,\"session\":\"%s\","
        "\"signal_score\":%d,\"signal_rsi\":%.4f,\"signal_adx\":%.4f,"
        "\"signal_di_plus\":%.4f,\"signal_di_minus\":%.4f,"
        "\"signal_ema50\":%.6f,\"signal_ema200\":%.6f}",
        ticket,sym,dir,price,sl,tp,lots,equity,risk_amt,atr,GetSession(),
        sc,rsi,adx,dip,dim,e50,e200);
    string url=FastAPI_Base+"/trades/open";
    char post[],result[]; string rh;
    StringToCharArray(body,post,0,StringLen(body));
    int res=WebRequest("POST",url,POSTHeaders(),5000,post,result,rh);
    if (Debug) Print("[Executor] NotifyBackend HTTP=",res);
}

void SendTelegram(string message) {
    if (StringLen(Telegram_Token)==0||StringLen(Telegram_Chat_ID)==0) return;
    string url="https://api.telegram.org/bot"+Telegram_Token+
               "/sendMessage?chat_id="+Telegram_Chat_ID+"&text="+message;
    char dummy[],result[]; string rh;
    WebRequest("GET",url,"",5000,dummy,result,rh);
}