//+------------------------------------------------------------------+
//| V19 FX Prop Desk — MT5 Trade Executor v1.00                     |
//| Ported from MT4 TradeExecutor v2.10                             |
//|                                                                  |
//| MQL4→MQL5 key changes:                                          |
//|  - OrdersTotal/OrderSelect → PositionsTotal/PositionGetTicket   |
//|  - OrderSend (old) → MqlTradeRequest + OrderSend                |
//|  - MarketInfo → SymbolInfoDouble/Integer                        |
//|  - AccountBalance/Equity → AccountInfoDouble                    |
//|  - iATR(…,bar) → iATR handle + CopyBuffer                      |
//|  - OrdersHistoryTotal → HistorySelect + HistoryDealsTotal       |
//|  - Partial close: same ticket survives (no remainder ticket)    |
//|  - DEAL_REASON_SL/TP for exit reason (cleaner than price cmp)  |
//|  - ulong tickets (64-bit)                                       |
//+------------------------------------------------------------------+
#property copyright "V19 FX Prop Desk"
#property version   "1.00"

// ── Inputs ──────────────────────────────────────────────────────────
input string FastAPI_Base           = "http://127.0.0.1";
input string API_Key                = "f9e369ad5592a0dcd33c78c4e33bd382";
input string Symbol_List            = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,GBPJPY,EURJPY";
input int    Poll_Seconds           = 60;
input long   Magic_Number           = 19001;
input int    Slippage               = 3;
input bool   Enable_Trading         = true;
input double BE_Buffer_Pips         = 1.0;
input int    Friday_Close_Hour      = 20;
input string Telegram_Token         = "";
input string Telegram_Chat_ID       = "";
input bool   Debug                  = true;

input int    Max_Open_Positions     = 5;
input double Portfolio_Max_Risk_Pct = 6.0;
input double Risk_Per_Trade_Pct     = 1.0;
input bool   Enable_Session_Filter  = false;
input bool   Log_Reject_Reasons     = true;

input double TP_R_Multiple          = 3.0;
input double Partial_Close_At_R     = 2.0;
input double Partial_Close_Ratio    = 0.30;

input double CB_Level1_DD_Pct       = 3.0;
input double CB_Level2_DD_Pct       = 5.0;
input double CB_Level3_DD_Pct       = 8.0;
input double CB_Reset_Ratio         = 0.5;

// ── State ────────────────────────────────────────────────────────────
int    cb_level = 0;
string cb_date  = "";

ulong  reported_closed_tickets[500];
int    n_reported_closed = 0;

string g_opened_symbols[50];
int    g_opened_count = 0;

string symbols[];
int    num_symbols = 0;
int    atr_handles[];   // one per symbol, created in OnInit

// ── Utility helpers ──────────────────────────────────────────────────
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

// Partial-close flag per symbol (stored in Global Variables)
string GV_PC(string sym) { return "PC_" + sym + "_" + IntegerToString(Magic_Number); }
bool IsSymbolPartialClosed(string sym) { return GlobalVariableCheck(GV_PC(sym)); }
void MarkSymbolPartialClosed(string sym) { GlobalVariableSet(GV_PC(sym), (double)TimeCurrent()); }
void ClearSymbolPartialClosed(string sym) {
    if (GlobalVariableCheck(GV_PC(sym))) GlobalVariableDel(GV_PC(sym));
}

// ── Indicator helpers ─────────────────────────────────────────────────
int SymbolIndex(string sym) {
    for (int i = 0; i < num_symbols; i++)
        if (symbols[i] == sym) return i;
    return -1;
}
double GetATR(string sym) {
    int idx = SymbolIndex(sym);
    if (idx < 0 || atr_handles[idx] == INVALID_HANDLE) return 0.0;
    double buf[1];
    if (CopyBuffer(atr_handles[idx], 0, 1, 1, buf) != 1) return 0.0;
    return buf[0];
}

// ── JSON helpers ──────────────────────────────────────────────────────
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

// ── Time / session helpers ────────────────────────────────────────────
string FormatTimestamp(datetime dt) {
    string s = TimeToString(dt, TIME_DATE|TIME_SECONDS);
    StringReplace(s, ".", "-");
    StringReplace(s, ".", "-");
    StringReplace(s, " ", "T");
    return s;
}
string FormatISO8601(datetime dt) { return FormatTimestamp(dt); }
// Broker server time != UTC — convert before reporting closed_at (see mt4/TradeExecutor.mq4).
datetime ServerToGMT(datetime server_time) {
    return server_time + (TimeGMT() - TimeCurrent());
}

string TodayString() {
    MqlDateTime tm;
    TimeToStruct(TimeGMT(), tm);
    return StringFormat("%04d%02d%02d", tm.year, tm.mon, tm.day);
}
string GetSession() {
    MqlDateTime tm;
    TimeToStruct(TimeGMT(), tm);
    int h = tm.hour;
    bool lo = (h >= 8 && h < 17), ny = (h >= 13 && h < 22);
    if (lo && ny) return "OVERLAP";
    if (lo)       return "LONDON";
    if (ny)       return "NEW_YORK";
    return "OFF_SESSION";
}
bool IsFridayClose() {
    MqlDateTime tm;
    TimeToStruct(TimeGMT(), tm);
    return (tm.day_of_week == 5 && tm.hour >= Friday_Close_Hour);
}

// ── HTTP helpers ──────────────────────────────────────────────────────
string GETUrl(string ep) {
    if (StringLen(API_Key) > 0)
        return FastAPI_Base + ep +
               (StringFind(ep, "?") >= 0 ? "&" : "?") + "api_key=" + API_Key;
    return FastAPI_Base + ep;
}
string POSTHeaders() {
    string h = "Content-Type: application/json\r\n";
    if (StringLen(API_Key) > 0) h += "X-API-Key: " + API_Key + "\r\n";
    return h;
}

// ── Account / position helpers ────────────────────────────────────────
int GetOpenCount() {
    int n = 0;
    for (int i = 0; i < PositionsTotal(); i++) {
        if (PositionGetTicket(i) > 0 &&
            PositionGetInteger(POSITION_MAGIC) == Magic_Number) n++;
    }
    return n;
}
bool HasOpenPosition(string sym) {
    for (int i = 0; i < PositionsTotal(); i++) {
        if (PositionGetTicket(i) == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) == sym &&
            PositionGetInteger(POSITION_MAGIC) == Magic_Number) return true;
    }
    return false;
}
double GetTotalOpenRiskPct() {
    double total = 0, bal = AccountInfoDouble(ACCOUNT_BALANCE);
    if (bal <= 0) return 0;
    for (int i = 0; i < PositionsTotal(); i++) {
        if (PositionGetTicket(i) == 0) continue;
        if (PositionGetInteger(POSITION_MAGIC) != Magic_Number) continue;
        double sl = PositionGetDouble(POSITION_SL);
        if (sl == 0) continue;
        string sym    = PositionGetString(POSITION_SYMBOL);
        double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
        double sd     = MathAbs(entry - sl);
        double ps     = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;
        double tv     = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
        double ts     = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
        double pv     = (ts > 0) ? tv / ts * ps : 0.0;
        double lots   = PositionGetDouble(POSITION_VOLUME);
        total += (sd / ps) * pv * lots;
    }
    return total / bal * 100.0;
}

// ── History helpers ───────────────────────────────────────────────────
bool IsReportedClosed(ulong ticket) {
    for (int i = 0; i < n_reported_closed; i++)
        if (reported_closed_tickets[i] == ticket) return true;
    return false;
}
void MarkReportedClosed(ulong ticket) {
    if (n_reported_closed < 500) reported_closed_tickets[n_reported_closed++] = ticket;
}

// ── Trade execution helpers ───────────────────────────────────────────
ENUM_ORDER_TYPE_FILLING GetFilling(string sym) {
    int modes = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
    if ((modes & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
    if ((modes & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
    return ORDER_FILLING_RETURN;
}
bool ModifySLTP(ulong ticket, string sym, double sl, double tp) {
    MqlTradeRequest req = {}; MqlTradeResult res = {};
    req.action   = TRADE_ACTION_SLTP;
    req.position = ticket;
    req.symbol   = sym;
    req.sl       = sl;
    req.tp       = tp;
    return OrderSend(req, res) && (res.retcode == TRADE_RETCODE_DONE ||
                                   res.retcode == TRADE_RETCODE_PLACED);
}

// ── OnInit / OnDeinit ─────────────────────────────────────────────────
int OnInit() {
    string raw = Symbol_List;
    StringReplace(raw, " ", "");
    string tmp[];
    int n = StringSplit(raw, ',', tmp);
    ArrayResize(symbols, n);
    for (int i = 0; i < n; i++) symbols[i] = tmp[i];
    num_symbols = n;
    g_opened_count = 0;
    for (int j = 0; j < ArraySize(g_opened_symbols); j++) g_opened_symbols[j] = "";

    // Create ATR handles for each symbol
    ArrayResize(atr_handles, num_symbols);
    for (int i = 0; i < num_symbols; i++) {
        atr_handles[i] = iATR(symbols[i], PERIOD_H1, 14);
        if (atr_handles[i] == INVALID_HANDLE)
            Print("[Executor] WARNING: ATR handle failed for ", symbols[i]);
    }

    EventSetTimer(Poll_Seconds);
    Print("[Executor MT5 v1.00] Initialized"
          " | symbols=", Symbol_List, " | magic=", Magic_Number,
          " | max_pos=", Max_Open_Positions, " | portfolio=", Portfolio_Max_Risk_Pct, "%"
          " | risk=", Risk_Per_Trade_Pct, "% | TP=", TP_R_Multiple, "R"
          " | partial=", Partial_Close_Ratio*100, "% @+", Partial_Close_At_R, "R"
          " | CB_reset=", CB_Reset_Ratio);
    return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) {
    EventKillTimer();
    for (int i = 0; i < num_symbols; i++)
        if (atr_handles[i] != INVALID_HANDLE) IndicatorRelease(atr_handles[i]);
}

// ── OnTimer (main loop) ───────────────────────────────────────────────
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

// ── Circuit breaker ───────────────────────────────────────────────────
double FetchRealizedDailyLoss() {
    string url = GETUrl("/analytics/drawdown");
    uchar dummy[], result[]; string rh;
    int res = WebRequest("GET", url, "", 5000, dummy, result, rh);
    if (res != 200) { if (Debug) Print("[Executor] drawdown HTTP=", res); return 0.0; }
    string body = CharArrayToString(result);
    int pos = StringFind(body, "\"daily_loss\":"); if (pos < 0) return 0.0;
    pos += 13;
    int end = StringFind(body, ",", pos); if (end < 0) end = StringFind(body, "}", pos);
    if (end < 0) return 0.0;
    return -MathAbs(StringToDouble(StringSubstr(body, pos, end - pos)));
}
void CheckCircuitBreaker() {
    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    if (equity <= 0 || balance <= 0) return;

    double realized   = FetchRealizedDailyLoss();
    double total_loss = realized + MathMin(0, equity - balance);
    double dd_pct     = MathAbs(total_loss) / balance * 100.0;

    int new_level = 0;
    if      (dd_pct >= CB_Level3_DD_Pct) new_level = 3;
    else if (dd_pct >= CB_Level2_DD_Pct) new_level = 2;
    else if (dd_pct >= CB_Level1_DD_Pct) new_level = 1;

    if (cb_level == 2 && dd_pct < CB_Level2_DD_Pct * CB_Reset_Ratio) new_level = 1;
    if (cb_level == 1 && dd_pct < CB_Level1_DD_Pct * CB_Reset_Ratio) new_level = 0;
    if (cb_level == 3) new_level = 3;

    if (new_level != cb_level) {
        string msg = StringFormat("[CB] LEVEL %d -> %d | DD=%.2f%%", cb_level, new_level, dd_pct);
        cb_level = new_level;
        Print(msg); SendTelegram(msg);
        if (cb_level == 3) CloseAllPositions("CB_L3");
    }
}

// ── Signal evaluation ─────────────────────────────────────────────────
void EvaluateSignals() {
    for (int i = 0; i < num_symbols; i++) {
        string sym = symbols[i];
        if (HasOpenPosition(sym)) continue;
        if (IsOpenedSymbol(sym)) {
            if (!HasOpenPosition(sym)) ClearOpenedSymbol(sym); else continue;
        }
        if (GetOpenCount() >= Max_Open_Positions) {
            if (Debug) Print("[Executor] Max pos (", Max_Open_Positions, ") — stop"); break;
        }
        double cr = GetTotalOpenRiskPct();
        if (cr + Risk_Per_Trade_Pct > Portfolio_Max_Risk_Pct) {
            if (Debug) Print("[Executor] Portfolio cap — stop"); break;
        }
        int sc = 0; double rsi = 0, adx = 0, dip = 0, dim = 0, e50 = 0, e200 = 0;
        string rej = "";
        string dir = FetchSignal(sym, sc, rsi, adx, dip, dim, e50, e200, rej);
        if (dir == "NO_TRADE" || dir == "") {
            if (Log_Reject_Reasons && dir == "NO_TRADE") LogRejectReason(sym, sc, rej);
            continue;
        }
        if (Enable_Session_Filter && GetSession() == "OFF_SESSION") {
            if (Log_Reject_Reasons) LogRejectReason(sym, sc, "OFF_SESSION");
            continue;
        }
        OpenTrade(sym, dir, sc, rsi, adx, dip, dim, e50, e200);
    }
}
string FetchSignal(string sym, int &sc, double &rsi, double &adx,
                   double &dip, double &dim, double &e50, double &e200, string &rej) {
    double ps = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;
    double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
    double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
    double pv = (ts > 0) ? tv / ts * ps : 0.0;
    string url = GETUrl(StringFormat("/signals/evaluate/%s?timeframe=H1&pip_value=%.6f", sym, pv));
    uchar dummy[], result[]; string rh;
    int res = WebRequest("GET", url, "", 5000, dummy, result, rh);
    if (res != 200) { if (Debug) Print("[Executor] Signal HTTP=", res, " ", sym); return ""; }
    string body = CharArrayToString(result);
    int pos = StringFind(body, "\"direction\":\""); if (pos < 0) return "";
    pos += 13; int end = StringFind(body, "\"", pos); if (end < 0) return "";
    string dir = StringSubstr(body, pos, end - pos);
    sc  = JsonInt(body, "score");    rsi = JsonDouble(body, "rsi");
    adx = JsonDouble(body, "adx");   dip = JsonDouble(body, "di_plus");
    dim = JsonDouble(body, "di_minus"); e50  = JsonDouble(body, "ema50");
    e200 = JsonDouble(body, "ema200");  rej  = JsonString(body, "reject_reason");
    if (Debug) Print("[Executor] Signal ", sym, " → ", dir, " score=", sc, " reject=", rej);
    return dir;
}
void LogRejectReason(string sym, int score, string reason) {
    string body = StringFormat(
        "{\"symbol\":\"%s\",\"timeframe\":\"H1\",\"direction\":\"NO_TRADE\","
        "\"score\":%d,\"reject_reason\":\"%s\",\"timestamp\":\"%s\"}",
        sym, score, reason, FormatTimestamp(TimeCurrent()));
    string url = FastAPI_Base + "/signals/log";
    uchar post_data[], result[]; string rh;
    StringToCharArray(body, post_data, 0, StringLen(body));
    int res = WebRequest("POST", url, POSTHeaders(), 5000, post_data, result, rh);
    if (Debug && res != 200 && res != 201 && res != 404)
        Print("[Executor] LogReject HTTP=", res, " ", sym);
}

// ── Open trade ────────────────────────────────────────────────────────
void OpenTrade(string sym, string dir, int sc, double rsi, double adx,
               double dip, double dim, double e50, double e200) {
    double atr = GetATR(sym);
    double atr_min = (StringFind(sym, "JPY") >= 0) ? 0.050 : 0.0005;
    double atr_max = (StringFind(sym, "JPY") >= 0) ? 0.500 : 0.0050;
    if (atr <= 0 || atr < atr_min || atr > atr_max) {
        Print("[Executor] ATR abnormal ", sym, " atr=", DoubleToString(atr, 6),
              " valid=", DoubleToString(atr_min, 6), "-", DoubleToString(atr_max, 6), " — skip");
        return;
    }

    double price;
    ENUM_ORDER_TYPE cmd;
    if (dir == "BUY") { price = SymbolInfoDouble(sym, SYMBOL_ASK); cmd = ORDER_TYPE_BUY; }
    else              { price = SymbolInfoDouble(sym, SYMBOL_BID);  cmd = ORDER_TYPE_SELL; }

    double sl_dist = atr * 1.5;
    double sl = (cmd == ORDER_TYPE_BUY) ? price - sl_dist : price + sl_dist;
    double tp = (cmd == ORDER_TYPE_BUY) ? price + sl_dist * TP_R_Multiple
                                        : price - sl_dist * TP_R_Multiple;

    double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
    double risk_amt = equity * (Risk_Per_Trade_Pct / 100.0);
    double ps       = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;
    double tv       = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
    double ts_val   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
    double pv       = (ts_val > 0) ? tv / ts_val * ps : 0.0;
    double sl_pips  = sl_dist / ps;
    double lots     = 0.01;
    if (pv > 0 && sl_pips > 0) lots = MathFloor((risk_amt / (sl_pips * pv)) * 100) / 100.0;
    double min_lot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
    double max_lot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
    lots = MathMax(min_lot, MathMin(lots, max_lot));

    double spread = SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT);
    if (spread > ps * 4) { if (Debug) Print("[Executor] Spread wide ", sym); return; }

    MqlTradeRequest req = {}; MqlTradeResult res = {};
    req.action       = TRADE_ACTION_DEAL;
    req.symbol       = sym;
    req.volume       = lots;
    req.type         = cmd;
    req.price        = price;
    req.sl           = sl;
    req.tp           = tp;
    req.deviation    = Slippage;
    req.magic        = Magic_Number;
    req.comment      = "V19_" + dir;
    req.type_filling = GetFilling(sym);

    if (!OrderSend(req, res)) {
        Print("[Executor] OrderSend failed ", sym, " err=", GetLastError(),
              " retcode=", res.retcode);
        return;
    }

    ulong ticket = res.order; // position ticket = opening order ticket
    MarkOpenedSymbol(sym);

    string msg = StringFormat("[Trade OPEN] %s %s | lots=%.2f price=%.5f SL=%.5f TP=%.5f"
                              " (%.1fR) atr=%.5f risk=%.1f%% ticket=%lld",
                              dir, sym, lots, price, sl, tp, TP_R_Multiple, atr,
                              Risk_Per_Trade_Pct, (long)ticket);
    if (Debug) Print(msg); SendTelegram(msg);
    NotifyBackend(ticket, sym, dir, price, sl, tp, lots, equity, risk_amt, atr,
                  sc, rsi, adx, dip, dim, e50, e200);
}

// ── Trade management ──────────────────────────────────────────────────
void ManageOpenTrades() {
    for (int i = PositionsTotal()-1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetInteger(POSITION_MAGIC) != Magic_Number) continue;

        string sym     = PositionGetString(POSITION_SYMBOL);
        ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double entry   = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl      = PositionGetDouble(POSITION_SL);
        double tp      = PositionGetDouble(POSITION_TP);
        double lots    = PositionGetDouble(POSITION_VOLUME);
        double cur     = (pos_type == POSITION_TYPE_BUY) ?
                         SymbolInfoDouble(sym, SYMBOL_BID) :
                         SymbolInfoDouble(sym, SYMBOL_ASK);
        double sl_dist = MathAbs(entry - sl);
        if (sl_dist == 0) continue;
        double r  = (pos_type == POSITION_TYPE_BUY) ? (cur - entry) / sl_dist : (entry - cur) / sl_dist;
        double ps = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;

        // Breakeven
        double be_sl = (pos_type == POSITION_TYPE_BUY) ?
                       entry + ps * BE_Buffer_Pips : entry - ps * BE_Buffer_Pips;
        bool be_set = (pos_type == POSITION_TYPE_BUY) ?
                      (sl >= be_sl - ps * 0.1) : (sl <= be_sl + ps * 0.1);
        if (r >= 1.0 && !be_set)
            if (ModifySLTP(ticket, sym, be_sl, tp) && Debug)
                Print("[Mgr] BE moved ticket=", ticket);

        // Partial close at +2R
        if (r >= Partial_Close_At_R && !IsSymbolPartialClosed(sym)) {
            double min_lot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
            if (lots <= min_lot * 1.5) {
                MarkSymbolPartialClosed(sym);
                if (Debug) Print("[Mgr] Lot too small, skip partial — ", sym);
            } else {
                double close_lot = NormalizeDouble(lots * Partial_Close_Ratio, 2);
                close_lot = MathMax(close_lot, min_lot);
                MarkSymbolPartialClosed(sym);

                MqlTradeRequest req = {}; MqlTradeResult res = {};
                req.action       = TRADE_ACTION_DEAL;
                req.position     = ticket;
                req.symbol       = sym;
                req.volume       = close_lot;
                req.type         = (pos_type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
                req.price        = cur;
                req.deviation    = Slippage;
                req.magic        = Magic_Number;
                req.type_filling = GetFilling(sym);

                if (OrderSend(req, res)) {
                    // MT5: position ticket unchanged after partial close — no remainder registration needed
                    double sl_1r = (pos_type == POSITION_TYPE_BUY) ?
                                   entry + sl_dist : entry - sl_dist;
                    bool sl_ok = (pos_type == POSITION_TYPE_BUY) ? (sl_1r > sl) : (sl_1r < sl || sl == 0);
                    if (sl_ok)
                        if (ModifySLTP(ticket, sym, sl_1r, tp) && Debug)
                            Print("[Mgr] Partial 30% SL→+1R ticket=", ticket,
                                  " sl_1r=", DoubleToString(sl_1r, 5));
                    string msg = StringFormat("[Trade PARTIAL] ticket=%lld %s 30%% @ %.5f | SL→+1R",
                                              (long)ticket, sym, cur);
                    if (Debug) Print(msg); SendTelegram(msg);
                } else {
                    Print("[Mgr] Partial failed ", sym, " ticket=", ticket, " err=", GetLastError());
                    ClearSymbolPartialClosed(sym);
                }
            }
        }

        // 0.5R step-trail after partial close
        if (IsSymbolPartialClosed(sym) && r >= Partial_Close_At_R) {
            // Re-read SL/TP in case they were just modified above
            if (PositionSelectByTicket(ticket)) {
                sl = PositionGetDouble(POSITION_SL);
                tp = PositionGetDouble(POSITION_TP);
            }
            double r_step = MathFloor(r * 2.0) / 2.0;
            if (r_step < Partial_Close_At_R) r_step = Partial_Close_At_R;

            double target_sl = (pos_type == POSITION_TYPE_BUY) ?
                               entry + (r_step - 1.0) * sl_dist :
                               entry - (r_step - 1.0) * sl_dist;
            bool should_move = (pos_type == POSITION_TYPE_BUY) ?
                               (target_sl > sl) : (target_sl < sl || sl == 0);
            if (should_move) {
                if (ModifySLTP(ticket, sym, target_sl, tp) && Debug)
                    Print("[Mgr] 0.5R step-trail ticket=", ticket,
                          " r=", DoubleToString(r, 2),
                          " step=", DoubleToString(r_step, 1),
                          " → SL=", DoubleToString(target_sl, 5));
                sl = target_sl;
            }

            // TP extension
            double cur_tp  = tp;
            double new_tp  = (pos_type == POSITION_TYPE_BUY) ?
                             entry + (r_step + 0.5) * sl_dist :
                             entry - (r_step + 0.5) * sl_dist;
            bool tp_behind = (pos_type == POSITION_TYPE_BUY) ?
                             (cur >= cur_tp - ps) : (cur <= cur_tp + ps);
            if (tp_behind && MathAbs(new_tp - cur_tp) > ps) {
                if (ModifySLTP(ticket, sym, sl, new_tp) && Debug)
                    Print("[Mgr] TP extended ticket=", ticket,
                          " new_tp=", DoubleToString(new_tp, 5));
            }
        }
    }
}

// ── Circuit breaker protection ────────────────────────────────────────
void Level2ProtectTrades() {
    for (int i = PositionsTotal()-1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetInteger(POSITION_MAGIC) != Magic_Number) continue;

        string sym   = PositionGetString(POSITION_SYMBOL);
        ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double entry = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl    = PositionGetDouble(POSITION_SL);
        double tp    = PositionGetDouble(POSITION_TP);
        double lots  = PositionGetDouble(POSITION_VOLUME);
        double pnl   = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        double cur   = (pos_type == POSITION_TYPE_BUY) ?
                       SymbolInfoDouble(sym, SYMBOL_BID) :
                       SymbolInfoDouble(sym, SYMBOL_ASK);

        if (pnl < 0) {
            MqlTradeRequest req = {}; MqlTradeResult res = {};
            req.action       = TRADE_ACTION_DEAL;
            req.position     = ticket;
            req.symbol       = sym;
            req.volume       = lots;
            req.type         = (pos_type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            req.price        = cur;
            req.deviation    = Slippage;
            req.magic        = Magic_Number;
            req.type_filling = GetFilling(sym);
            if (OrderSend(req, res)) {
                string msg = StringFormat("[CB-L2] Closed loser ticket=%lld %s pnl=%.2f",
                                          (long)ticket, sym, pnl);
                Print(msg); SendTelegram(msg);
            }
            continue;
        }
        double ps = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;
        double be_sl = (pos_type == POSITION_TYPE_BUY) ?
                       entry + ps * BE_Buffer_Pips : entry - ps * BE_Buffer_Pips;
        bool be_set = (pos_type == POSITION_TYPE_BUY) ?
                      (sl >= be_sl - ps * 0.1) : (sl <= be_sl + ps * 0.1);
        if (!be_set)
            if (ModifySLTP(ticket, sym, be_sl, tp) && Debug)
                Print("[CB-L2] BE set ticket=", ticket);
    }
}

void CloseAllPositions(string reason) {
    for (int i = PositionsTotal()-1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetInteger(POSITION_MAGIC) != Magic_Number) continue;

        string sym   = PositionGetString(POSITION_SYMBOL);
        ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double entry = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl    = PositionGetDouble(POSITION_SL);
        double tp    = PositionGetDouble(POSITION_TP);
        double lots  = PositionGetDouble(POSITION_VOLUME);
        double pnl   = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        double cur   = (pos_type == POSITION_TYPE_BUY) ?
                       SymbolInfoDouble(sym, SYMBOL_BID) :
                       SymbolInfoDouble(sym, SYMBOL_ASK);

        if (pnl < 0) {
            MqlTradeRequest req = {}; MqlTradeResult res = {};
            req.action       = TRADE_ACTION_DEAL;
            req.position     = ticket;
            req.symbol       = sym;
            req.volume       = lots;
            req.type         = (pos_type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            req.price        = cur;
            req.deviation    = Slippage;
            req.magic        = Magic_Number;
            req.type_filling = GetFilling(sym);
            if (OrderSend(req, res)) {
                string msg = StringFormat("[Trade CLOSE] ticket=%lld %s reason=%s (loss=%.2f)",
                                          (long)ticket, sym, reason, pnl);
                if (Debug) Print(msg); SendTelegram(msg);
            } else if (Debug)
                Print("[Trade CLOSE] failed ticket=", ticket, " err=", GetLastError());
        } else {
            double sl_dist = MathAbs(entry - sl);
            double atr = GetATR(sym);
            double buf = MathMax(sl_dist * 0.20, atr * 0.3);
            buf = MathMin(buf, atr * 2.0);
            double new_sl = (pos_type == POSITION_TYPE_BUY) ? cur - buf : cur + buf;
            if (ModifySLTP(ticket, sym, new_sl, tp)) {
                double pct = sl_dist > 0 ? (sl_dist - buf) / sl_dist * 100 : 0;
                string msg = StringFormat("[Trade LOCK] ticket=%lld %s SL=%.5f (~%.0f%% locked) reason=%s",
                                          (long)ticket, sym, new_sl, pct, reason);
                if (Debug) Print(msg); SendTelegram(msg);
            }
        }
    }
}

// ── Detect and report closed trades ──────────────────────────────────
// In MT5, partial closes do NOT create a new ticket (unlike MT4).
// So we wait until the position is fully gone before reporting to backend.
// We aggregate P&L from ALL DEAL_ENTRY_OUT deals for the position.
void DetectAndReportClosedTrades() {
    datetime from = TimeCurrent() - 604800; // 1 week look-back
    HistorySelect(from, TimeCurrent());
    int total = HistoryDealsTotal();

    for (int i = total - 1; i >= 0; i--) {
        ulong deal_ticket = HistoryDealGetTicket(i);
        if (deal_ticket == 0) continue;
        if (HistoryDealGetInteger(deal_ticket, DEAL_MAGIC) != Magic_Number) continue;
        if (HistoryDealGetInteger(deal_ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

        ulong pos_id = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
        if (IsReportedClosed(pos_id)) continue;

        datetime close_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
        if (close_time == 0) continue;
        if (TimeCurrent() - close_time > 604800) { MarkReportedClosed(pos_id); continue; }

        // Skip if position still open (partial close scenario — wait for full close)
        if (PositionSelectByTicket(pos_id)) continue;

        string sym = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
        if (!HasOpenPosition(sym)) { ClearSymbolPartialClosed(sym); ClearOpenedSymbol(sym); }

        // Aggregate ALL out-deals for this position (handles partial closes)
        double total_profit = 0, total_commission = 0, total_swap = 0;
        double last_price = 0;
        datetime last_time = 0;
        long last_reason = DEAL_REASON_CLIENT;

        for (int j = 0; j < total; j++) {
            ulong d = HistoryDealGetTicket(j);
            if ((ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID) != pos_id) continue;
            if (HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
            total_profit     += HistoryDealGetDouble(d, DEAL_PROFIT);
            total_commission += HistoryDealGetDouble(d, DEAL_COMMISSION);
            total_swap       += HistoryDealGetDouble(d, DEAL_SWAP);
            datetime dt = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
            if (dt >= last_time) {
                last_time   = dt;
                last_price  = HistoryDealGetDouble(d, DEAL_PRICE);
                last_reason = HistoryDealGetInteger(d, DEAL_REASON);
            }
        }

        string reason = "MANUAL";
        if (last_reason == DEAL_REASON_SL) reason = "SL";
        else if (last_reason == DEAL_REASON_TP) reason = "TP";

        string body = StringFormat(
            "{\"exit_price\":%.6f,\"commission\":%.2f,\"swap\":%.2f,\"profit\":%.2f,"
            "\"exit_reason\":\"%s\",\"closed_at\":\"%s\",\"account_equity\":%.2f}",
            last_price, total_commission, total_swap, total_profit,
            reason, FormatISO8601(ServerToGMT(last_time)), AccountInfoDouble(ACCOUNT_EQUITY));

        string url = FastAPI_Base + "/trades/close/by-ticket/" + IntegerToString((long)pos_id);
        uchar post_data[], result[]; string rh;
        StringToCharArray(body, post_data, 0, StringLen(body));
        int res = WebRequest("POST", url, POSTHeaders(), 5000, post_data, result, rh);

        if (res == 200 || res == 404) {
            MarkReportedClosed(pos_id);
            if (Debug) Print("[Executor] Close reported ticket=", pos_id,
                             " reason=", reason, " HTTP=", res);
        } else {
            if (Debug) Print("[Executor] Close report failed ticket=", pos_id, " HTTP=", res);
        }
    }
}

// ── Notify backend of new open trade ─────────────────────────────────
void NotifyBackend(ulong ticket, string sym, string dir,
                   double price, double sl, double tp, double lots,
                   double equity, double risk_amt, double atr,
                   int sc, double rsi, double adx, double dip, double dim,
                   double e50, double e200) {
    string body = StringFormat(
        "{\"ticket\":%lld,\"symbol\":\"%s\",\"direction\":\"%s\","
        "\"entry_price\":%.6f,\"stop_loss\":%.6f,\"take_profit\":%.6f,"
        "\"lot_size\":%.2f,\"account_equity\":%.2f,\"risk_amount\":%.2f,"
        "\"atr_at_entry\":%.6f,\"session\":\"%s\","
        "\"signal_score\":%d,\"signal_rsi\":%.4f,\"signal_adx\":%.4f,"
        "\"signal_di_plus\":%.4f,\"signal_di_minus\":%.4f,"
        "\"signal_ema50\":%.6f,\"signal_ema200\":%.6f}",
        (long)ticket, sym, dir, price, sl, tp, lots, equity, risk_amt, atr, GetSession(),
        sc, rsi, adx, dip, dim, e50, e200);
    string url = FastAPI_Base + "/trades/open";
    uchar post_data[], result[]; string rh;
    StringToCharArray(body, post_data, 0, StringLen(body));
    int res = WebRequest("POST", url, POSTHeaders(), 5000, post_data, result, rh);
    if (Debug) Print("[Executor] NotifyBackend HTTP=", res);
}

// ── Telegram ──────────────────────────────────────────────────────────
void SendTelegram(string message) {
    if (StringLen(Telegram_Token) == 0 || StringLen(Telegram_Chat_ID) == 0) return;
    string url = "https://api.telegram.org/bot" + Telegram_Token +
                 "/sendMessage?chat_id=" + Telegram_Chat_ID + "&text=" + message;
    uchar dummy[], result[]; string rh;
    WebRequest("GET", url, "", 5000, dummy, result, rh);
}
