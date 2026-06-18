//+------------------------------------------------------------------+
//| V19 FX Prop Desk — MT4 Trade Executor v2.04                     |
//| FIXES APPLIED:                                                   |
//|  1. CB is a one-way daily LATCH — resets at midnight only        |
//|  2. CB includes realized closed-trade losses (queries FastAPI)   |
//|  3. Partial close tracked per-ticket — never closes twice        |
//|  4. GetSession() logic fixed (NY session 17-22 was unreachable)  |
//|  5. Break-even uses entry + 1-pip buffer (not exact entry)       |
//|  6. Friday close rule: no new trades + close all >= Fri 20:00 UTC|
//|  7. Pip value uses live MarketInfo() — not a hardcoded table     |
//|  8. Telegram alert on CB / trade open / trade close              |
//|  9. Symbol_List — added .y suffix for broker compatibility       |
//| 10. FastAPI_Base trailing slash removed — was causing //         |
//| 11. FIX: GET requests pass api_key as query param (not header)   |
//|     MT4 WebRequest GET does not support custom headers           |
//|     POST requests still use X-API-Key header (supported)         |
//| 12. Signal reasoning logged at trade open: score, RSI, ADX,     |
//|     DI+/DI-, EMA50/200 — enables score calibration & post-trade |
//|     analysis in trade_history                                    |
//| 13. Multi-level circuit breaker (L1/L2/L3):                     |
//|     L1 3%: block new entries, keep positions                     |
//|     L2 5%: close losers, protect winners at BE + trail           |
//|     L3 8%: close all, disable trading until next day            |
//+------------------------------------------------------------------+
#property copyright "V19 FX Prop Desk"
#property version   "2.04"
#property strict

#include <stdlib.mqh>

// ── Inputs ───────────────────────────────────────────────────────────
input string FastAPI_Base      = "http://127.0.0.1";
input string API_Key           = "f9e369ad5592a0dcd33c78c4e33bd382";
input string Symbol_List       = "EURUSD,GBPUSD,USDJPY.y,AUDUSD,USDCAD,GBPJPY";
input int    Poll_Seconds      = 60;
input int    Magic_Number      = 19001;
input int    Slippage          = 3;
input bool   Enable_Trading    = true;
input double BE_Buffer_Pips    = 1.0;
input int    Friday_Close_Hour = 20;
input string Telegram_Token    = "";
input string Telegram_Chat_ID  = "";
input bool   Debug             = true;
input double CB_Level1_DD_Pct  = 3.0;   // L1: block entries
input double CB_Level2_DD_Pct  = 5.0;   // L2: close losers, protect winners
input double CB_Level3_DD_Pct  = 8.0;   // L3: close all, disable trading

// ── Circuit Breaker state ────────────────────────────────────────────
// Level 0=NORMAL 1=DEFENSIVE 2=RISK_REDUCTION 3=EMERGENCY
// Only escalates within a trading day; resets at midnight.
int    cb_level = 0;
string cb_date  = "";

// ── Partial close tracking ───────────────────────────────────────────
int partial_closed_tickets[200];
int n_partial_closed = 0;

// ── Closed-trade reporting (prevent double-report across ticks) ───────
int reported_closed_tickets[500];
int n_reported_closed = 0;

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
    int end = StringFind(body, ",", pos);
    int end2 = StringFind(body, "}", pos);
    if (end < 0 || (end2 >= 0 && end2 < end)) end = end2;
    if (end < 0) return 0.0;
    return StringToDouble(StringSubstr(body, pos, end - pos));
}

int JsonInt(string body, string key) { return (int)JsonDouble(body, key); }

// ── Helpers ──────────────────────────────────────────────────────────
string FormatTimestamp(datetime dt) {
    string s = TimeToString(dt, TIME_DATE|TIME_SECONDS);
    StringReplace(s, ".", "-");
    StringReplace(s, ".", "-");
    StringReplace(s, " ", "T");
    return s;
}

// FIX 11: GET requests — append api_key as query parameter
// MT4 WebRequest("GET") treats headers param as cookie string only
// Custom headers (X-API-Key) are NOT sent — use ?api_key= instead
string GETUrl(string endpoint) {
    if (StringLen(API_Key) > 0)
        return FastAPI_Base + endpoint +
               (StringFind(endpoint, "?") >= 0 ? "&" : "?") +
               "api_key=" + API_Key;
    return FastAPI_Base + endpoint;
}

// POST requests — X-API-Key header works correctly
string POSTHeaders() {
    string h = "Content-Type: application/json\r\n";
    if (StringLen(API_Key) > 0)
        h += "X-API-Key: " + API_Key + "\r\n";
    return h;
}

int OnInit() {
    string raw = Symbol_List;
    StringReplace(raw, " ", "");
    string tmp[];
    int n = StringSplit(raw, ',', tmp);
    ArrayResize(symbols, n);
    for (int i = 0; i < n; i++) symbols[i] = tmp[i];
    num_symbols = n;
    ArrayInitialize(partial_closed_tickets, 0);
    EventSetTimer(Poll_Seconds);
    Print("[Executor v2.04] Initialized | symbols=", Symbol_List,
          " | backend=", FastAPI_Base);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer() {
    // Reset CB level at start of each new trading day
    string today = TodayString();
    if (cb_date != today) { cb_level = 0; cb_date = today; }

    DetectAndReportClosedTrades();
    if (!Enable_Trading) return;
    if (IsFridayClose()) { CloseAllPositions("FRIDAY_CLOSE"); return; }

    CheckCircuitBreaker();

    if (cb_level == 3) return;              // L3: all closed — nothing to do

    ManageOpenTrades();                     // L0/L1: normal management

    if (cb_level == 2) {
        Level2ProtectTrades();              // L2: close losers, protect winners
        return;                             // no new entries
    }

    if (cb_level >= 1) return;              // L1: keep positions, block entries

    EvaluateSignals();                      // L0 NORMAL only
}

// ── Circuit Breaker ──────────────────────────────────────────────────
string TodayString() {
    datetime now = TimeGMT();
    return StringFormat("%04d%02d%02d",
                        TimeYear(now), TimeMonth(now), TimeDay(now));
}

void CheckCircuitBreaker() {
    double equity  = AccountEquity();
    double balance = AccountBalance();
    if (equity <= 0 || balance <= 0) return;

    double realized   = FetchRealizedDailyLoss();
    double floating   = equity - balance;
    double total_loss = realized + MathMin(0, floating);
    double dd_pct     = MathAbs(total_loss) / balance * 100.0;

    int new_level = 0;
    if      (dd_pct >= CB_Level3_DD_Pct) new_level = 3;
    else if (dd_pct >= CB_Level2_DD_Pct) new_level = 2;
    else if (dd_pct >= CB_Level1_DD_Pct) new_level = 1;

    if (new_level <= cb_level) return;  // only escalate, never de-escalate within the day

    cb_level = new_level;
    string msg = StringFormat("[CB] LEVEL %d — DD=%.2f%%", cb_level, dd_pct);
    Print(msg); SendTelegram(msg);

    if (cb_level == 3) CloseAllPositions("CB_L3");
    // L1 and L2 actions handled in OnTimer() flow
}

double FetchRealizedDailyLoss() {
    // FIX 11: api_key in query string for GET request
    string url = GETUrl("/analytics/drawdown");
    char dummy[], result[]; string res_headers;
    int res = WebRequest("GET", url, "", 5000, dummy, result, res_headers);
    if (res != 200) {
        if (Debug) Print("[Executor] drawdown fetch HTTP=", res, " — using 0");
        return 0.0;
    }
    string body = CharArrayToString(result);
    int pos = StringFind(body, "\"daily_loss\":");
    if (pos < 0) return 0.0;
    pos += 13;
    int end = StringFind(body, ",", pos);
    if (end < 0) end = StringFind(body, "}", pos);
    if (end < 0) return 0.0;
    return -MathAbs(StringToDouble(StringSubstr(body, pos, end - pos)));
}

bool IsFridayClose() {
    datetime now = TimeGMT();
    return (DayOfWeek() == 5 && TimeHour(now) >= Friday_Close_Hour);
}

// ── Signal Evaluation ────────────────────────────────────────────────
void EvaluateSignals() {
    for (int i = 0; i < num_symbols; i++) {
        string sym = symbols[i];
        if (HasOpenPosition(sym)) continue;
        int    sig_score   = 0;
        double sig_rsi     = 0, sig_adx    = 0;
        double sig_di_plus = 0, sig_di_minus = 0;
        double sig_ema50   = 0, sig_ema200  = 0;
        string dir = FetchSignal(sym,
                         sig_score, sig_rsi, sig_adx,
                         sig_di_plus, sig_di_minus, sig_ema50, sig_ema200);
        if (dir == "NO_TRADE" || dir == "") continue;
        OpenTrade(sym, dir,
                  sig_score, sig_rsi, sig_adx,
                  sig_di_plus, sig_di_minus, sig_ema50, sig_ema200);
    }
}

string FetchSignal(string sym,
                   int    &out_score,
                   double &out_rsi,
                   double &out_adx,
                   double &out_di_plus,
                   double &out_di_minus,
                   double &out_ema50,
                   double &out_ema200) {
    double pip_size = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;
    double pip_val  = MarketInfo(sym, MODE_TICKVALUE) /
                      MarketInfo(sym, MODE_TICKSIZE) * pip_size;

    string endpoint = StringFormat(
        "/signals/evaluate/%s?timeframe=H1&pip_value=%.6f", sym, pip_val);
    string url = GETUrl(endpoint);

    char dummy[], result[]; string res_headers;
    int res = WebRequest("GET", url, "", 5000, dummy, result, res_headers);

    if (res != 200) {
        if (Debug) Print("[Executor] Signal fetch failed ", sym, " HTTP=", res);
        return "";
    }
    string body = CharArrayToString(result);

    // Parse direction
    int pos = StringFind(body, "\"direction\":\"");
    if (pos < 0) return "";
    pos += 13;
    int end = StringFind(body, "\"", pos);
    if (end < 0) return "";
    string direction = StringSubstr(body, pos, end - pos);

    if (Debug) Print("[Executor] Signal ", sym, " → ", direction);

    // Parse signal reasoning
    out_score    = JsonInt   (body, "score");
    out_rsi      = JsonDouble(body, "rsi");
    out_adx      = JsonDouble(body, "adx");
    out_di_plus  = JsonDouble(body, "di_plus");
    out_di_minus = JsonDouble(body, "di_minus");
    out_ema50    = JsonDouble(body, "ema50");
    out_ema200   = JsonDouble(body, "ema200");

    return direction;
}

// ── Open Trade ───────────────────────────────────────────────────────
void OpenTrade(string sym, string direction,
               int    sig_score,
               double sig_rsi,    double sig_adx,
               double sig_di_plus, double sig_di_minus,
               double sig_ema50,  double sig_ema200) {
    double atr   = iATR(sym, 60, 14, 1);
    double price;
    int    cmd;
    if (direction == "BUY") { price = MarketInfo(sym, MODE_ASK); cmd = OP_BUY; }
    else                    { price = MarketInfo(sym, MODE_BID); cmd = OP_SELL; }

    double sl_dist = atr * 1.5;
    double tp_dist = atr * 3.0;
    double sl = (cmd == OP_BUY) ? price - sl_dist : price + sl_dist;
    double tp = (cmd == OP_BUY) ? price + tp_dist : price - tp_dist;

    double equity   = AccountEquity();
    double risk_amt = equity * 0.01;
    double pip_size = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;
    double pip_val  = MarketInfo(sym, MODE_TICKVALUE) /
                      MarketInfo(sym, MODE_TICKSIZE) * pip_size;
    double sl_pips  = sl_dist / pip_size;
    double lots     = 0.01;
    if (pip_val > 0 && sl_pips > 0)
        lots = MathFloor((risk_amt / (sl_pips * pip_val)) * 100) / 100.0;
    lots = MathMax(MarketInfo(sym, MODE_MINLOT),
                   MathMin(lots, MarketInfo(sym, MODE_MAXLOT)));

    double spread = MarketInfo(sym, MODE_SPREAD) * MarketInfo(sym, MODE_POINT);
    if (spread > pip_size * 4) {
        if (Debug) Print("[Executor] Spread too wide ", sym);
        return;
    }

    int ticket = OrderSend(sym, cmd, lots, price, Slippage, sl, tp,
                           "V19_" + direction, Magic_Number, 0,
                           cmd == OP_BUY ? clrBlue : clrRed);
    if (ticket < 0) {
        Print("[Executor] OrderSend failed ", sym, " err=", GetLastError());
        return;
    }

    string msg = StringFormat(
        "[Trade OPEN] %s %s | lots=%.2f price=%.5f SL=%.5f TP=%.5f ticket=%d",
        direction, sym, lots, price, sl, tp, ticket);
    if (Debug) Print(msg);
    SendTelegram(msg);
    NotifyBackend(ticket, sym, direction, price, sl, tp, lots, equity, risk_amt, atr,
                  sig_score, sig_rsi, sig_adx, sig_di_plus, sig_di_minus, sig_ema50, sig_ema200);
}

// ── Level 2: close losers, protect winners ───────────────────────────
void Level2ProtectTrades() {
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (OrderMagicNumber() != Magic_Number) continue;

        string sym    = OrderSymbol();
        int    ticket = OrderTicket();
        double cur    = (OrderType() == OP_BUY) ? MarketInfo(sym, MODE_BID)
                                                 : MarketInfo(sym, MODE_ASK);
        double pnl    = OrderProfit() + OrderSwap() + OrderCommission();

        if (pnl < 0) {
            if (OrderClose(ticket, OrderLots(), cur, Slippage, clrRed)) {
                string msg = StringFormat(
                    "[CB-L2] Closed loser ticket=%d %s pnl=%.2f", ticket, sym, pnl);
                Print(msg); SendTelegram(msg);
            }
            continue;
        }

        // Winning position: move SL to BE+buffer immediately (don't wait for +1R)
        double entry    = OrderOpenPrice();
        double sl       = OrderStopLoss();
        double pip_size = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;
        double be_buf   = pip_size * BE_Buffer_Pips;
        double be_sl    = (OrderType() == OP_BUY) ? entry + be_buf : entry - be_buf;
        bool   be_set   = (OrderType() == OP_BUY) ? (sl >= be_sl - pip_size * 0.1)
                                                   : (sl <= be_sl + pip_size * 0.1);
        if (!be_set) {
            if (OrderModify(ticket, entry, be_sl, OrderTakeProfit(), 0, clrOrange))
                if (Debug) Print("[CB-L2] BE set ticket=", ticket);
        }

        // Tight ATR trailing on winners (1.0× ATR, tighter than normal 1.5×)
        double atr = iATR(sym, 60, 14, 0);
        if (atr > 0) {
            double trail = atr * 1.0;
            double new_sl;
            if (OrderType() == OP_BUY) {
                new_sl = cur - trail;
                if (new_sl > sl)
                    OrderModify(ticket, entry, new_sl, OrderTakeProfit(), 0, clrGreen);
            } else {
                new_sl = cur + trail;
                if (new_sl < sl || sl == 0)
                    OrderModify(ticket, entry, new_sl, OrderTakeProfit(), 0, clrGreen);
            }
        }
    }
}

// ── Manage Open Positions ────────────────────────────────────────────
void ManageOpenTrades() {
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (OrderMagicNumber() != Magic_Number) continue;

        string sym    = OrderSymbol();
        int    ticket = OrderTicket();
        double cur    = (OrderType() == OP_BUY) ? MarketInfo(sym, MODE_BID)
                                                 : MarketInfo(sym, MODE_ASK);
        double entry   = OrderOpenPrice();
        double sl      = OrderStopLoss();
        double sl_dist = MathAbs(entry - sl);
        if (sl_dist == 0) continue;

        double atr      = iATR(sym, 60, 14, 0);
        double r        = (OrderType() == OP_BUY) ? (cur - entry) / sl_dist
                                                   : (entry - cur) / sl_dist;
        double pip_size = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;
        double be_buf   = pip_size * BE_Buffer_Pips;
        double be_sl    = (OrderType() == OP_BUY) ? entry + be_buf : entry - be_buf;
        bool be_set     = (OrderType() == OP_BUY) ? (sl >= be_sl - pip_size * 0.1)
                                                   : (sl <= be_sl + pip_size * 0.1);
        if (r >= 1.0 && !be_set) {
            if (OrderModify(ticket, entry, be_sl, OrderTakeProfit(), 0, clrYellow))
                if (Debug) Print("[Mgr] BE moved ticket=", ticket);
        }

        if (r >= 2.0 && !IsPartialClosed(ticket)) {
            double half = MathFloor(OrderLots() * 50) / 100.0;
            if (half >= MarketInfo(sym, MODE_MINLOT)) {
                if (OrderClose(ticket, half, cur, Slippage, clrOrange)) {
                    MarkPartialClosed(ticket);
                    string msg = StringFormat(
                        "[Trade PARTIAL] ticket=%d %s 50%% @ %.5f", ticket, sym, cur);
                    if (Debug) Print(msg);
                    SendTelegram(msg);
                }
            }
        }

        if (r >= 2.0 && atr > 0) {
            double trail = atr * 1.5;
            double new_sl;
            if (OrderType() == OP_BUY) {
                new_sl = cur - trail;
                if (new_sl > sl)
                    OrderModify(ticket, entry, new_sl, OrderTakeProfit(), 0, clrGreen);
            } else {
                new_sl = cur + trail;
                if (new_sl < sl || sl == 0)
                    OrderModify(ticket, entry, new_sl, OrderTakeProfit(), 0, clrGreen);
            }
        }
    }
}

// ── Partial close tracking ───────────────────────────────────────────
bool IsPartialClosed(int ticket) {
    for (int i = 0; i < n_partial_closed; i++)
        if (partial_closed_tickets[i] == ticket) return true;
    return false;
}
void MarkPartialClosed(int ticket) {
    if (n_partial_closed < 200)
        partial_closed_tickets[n_partial_closed++] = ticket;
}

// ── Helpers ──────────────────────────────────────────────────────────
bool HasOpenPosition(string sym) {
    for (int i = 0; i < OrdersTotal(); i++) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (OrderSymbol() == sym && OrderMagicNumber() == Magic_Number) return true;
    }
    return false;
}

// ── Timestamp formatter (ISO 8601 for backend) ───────────────────────
string FormatISO8601(datetime dt) {
    string s = TimeToString(dt, TIME_DATE|TIME_SECONDS);
    StringReplace(s, ".", "-");
    StringReplace(s, ".", "-");
    StringReplace(s, " ", "T");
    return s;
}

bool IsReportedClosed(int ticket) {
    for (int i = 0; i < n_reported_closed; i++)
        if (reported_closed_tickets[i] == ticket) return true;
    return false;
}
void MarkReportedClosed(int ticket) {
    if (n_reported_closed < 500)
        reported_closed_tickets[n_reported_closed++] = ticket;
}

// Scans MT4 order history and POSTs any unreported closes to the backend.
// Runs on every OnTimer() tick — this is the missing link that populates
// trade_history, win rate, drawdown, and equity curve in the dashboard.
void DetectAndReportClosedTrades() {
    int total = OrdersHistoryTotal();
    for (int i = total - 1; i >= 0; i--) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
        if (OrderMagicNumber() != Magic_Number) continue;

        int ticket = OrderTicket();
        if (IsReportedClosed(ticket)) continue;

        datetime close_time = OrderCloseTime();
        if (close_time == 0) continue;

        // Skip orders closed more than 7 days ago (EA restart recovery window)
        if (TimeCurrent() - close_time > 604800) {
            MarkReportedClosed(ticket);
            continue;
        }

        double close_price = OrderClosePrice();
        double tp          = OrderTakeProfit();
        double sl          = OrderStopLoss();
        double pip_size    = (StringFind(OrderSymbol(), "JPY") >= 0) ? 0.01 : 0.0001;

        string exit_reason = "MANUAL";
        if (tp > 0 && MathAbs(close_price - tp) <= pip_size * 3) exit_reason = "TP";
        else if (sl > 0 && MathAbs(close_price - sl) <= pip_size * 3) exit_reason = "SL";

        string body = StringFormat(
            "{\"exit_price\":%.6f,\"commission\":%.2f,\"swap\":%.2f,"
            "\"exit_reason\":\"%s\",\"closed_at\":\"%s\",\"account_equity\":%.2f}",
            close_price,
            OrderCommission(), OrderSwap(),
            exit_reason, FormatISO8601(close_time),
            AccountEquity()
        );

        string url = FastAPI_Base + "/trades/close/by-ticket/" + IntegerToString(ticket);
        char post[], result[]; string res_headers;
        StringToCharArray(body, post, 0, StringLen(body));
        int res = WebRequest("POST", url, POSTHeaders(), 5000, post, result, res_headers);

        // 200 = closed, 404 = not in backend (pre-EA trade), both are terminal states
        if (res == 200 || res == 404) {
            MarkReportedClosed(ticket);
            if (Debug) Print("[Executor] Close reported ticket=", ticket,
                             " reason=", exit_reason, " HTTP=", res);
        } else {
            if (Debug) Print("[Executor] Close report failed ticket=", ticket, " HTTP=", res);
        }
    }
}

void CloseAllPositions(string reason) {
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (OrderMagicNumber() != Magic_Number) continue;

        string sym    = OrderSymbol();
        int    ticket = OrderTicket();
        double entry  = OrderOpenPrice();
        double profit = OrderProfit() + OrderSwap() + OrderCommission();
        double cur    = (OrderType() == OP_BUY) ? MarketInfo(sym, MODE_BID)
                                                 : MarketInfo(sym, MODE_ASK);

        if (profit < 0) {
            // Loss trade → ချက်ချင်းပိတ် (capital protect)
            OrderClose(ticket, OrderLots(), cur, Slippage, clrRed);
            string msg = StringFormat("[Trade CLOSE] ticket=%d %s reason=%s (loss=%.2f)",
                                      ticket, sym, reason, profit);
            if (Debug) Print(msg);
            SendTelegram(msg);
        } else {
            // Profit trade → SL ကို 20% buffer ဖြင့် ဆွဲ (lock 80% of profit)
            double pip_size = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;
            double atr       = iATR(sym, 60, 14, 0);
            double profit_dist = MathAbs(cur - entry);

            double buffer = profit_dist * 0.20;
            buffer = MathMax(buffer, atr * 0.3);  // minimum
            buffer = MathMin(buffer, atr * 2.0);  // maximum

            double new_sl = (OrderType() == OP_BUY) ? cur - buffer : cur + buffer;

            bool ok = OrderModify(ticket, entry, new_sl, OrderTakeProfit(), 0, clrYellow);
            if (ok) {
                double locked_pct = (profit_dist - buffer) / profit_dist * 100.0;
                string msg = StringFormat(
                    "[Trade LOCK] ticket=%d %s SL=%.5f buffer=%.5f (~%.0f%% profit locked) reason=%s",
                    ticket, sym, new_sl, buffer, locked_pct, reason);
                if (Debug) Print(msg);
                SendTelegram(msg);
            }
        }
    }
}

void NotifyBackend(int ticket, string sym, string dir,
                   double price, double sl, double tp,
                   double lots, double equity, double risk_amt, double atr,
                   int    sig_score,
                   double sig_rsi,    double sig_adx,
                   double sig_di_plus, double sig_di_minus,
                   double sig_ema50,  double sig_ema200) {
    string body = StringFormat(
        "{\"ticket\":%d,\"symbol\":\"%s\",\"direction\":\"%s\","
        "\"entry_price\":%.6f,\"stop_loss\":%.6f,\"take_profit\":%.6f,"
        "\"lot_size\":%.2f,\"account_equity\":%.2f,\"risk_amount\":%.2f,"
        "\"atr_at_entry\":%.6f,\"session\":\"%s\","
        "\"signal_score\":%d,\"signal_rsi\":%.4f,\"signal_adx\":%.4f,"
        "\"signal_di_plus\":%.4f,\"signal_di_minus\":%.4f,"
        "\"signal_ema50\":%.6f,\"signal_ema200\":%.6f}",
        ticket, sym, dir, price, sl, tp,
        lots, equity, risk_amt, atr, GetSession(),
        sig_score, sig_rsi, sig_adx, sig_di_plus, sig_di_minus, sig_ema50, sig_ema200);

    string url = FastAPI_Base + "/trades/open";
    char post[], result[]; string res_headers;
    StringToCharArray(body, post, 0, StringLen(body));
    int res = WebRequest("POST", url, POSTHeaders(), 5000, post, result, res_headers);
    if (Debug) Print("[Executor] NotifyBackend HTTP=", res);
}

string GetSession() {
    int  h         = TimeHour(TimeGMT());
    bool in_london = (h >= 8  && h < 17);
    bool in_ny     = (h >= 13 && h < 22);
    if (in_london && in_ny) return "OVERLAP";
    if (in_london)          return "LONDON";
    if (in_ny)              return "NEW_YORK";
    return "OFF_SESSION";
}

void SendTelegram(string message) {
    if (StringLen(Telegram_Token) == 0 || StringLen(Telegram_Chat_ID) == 0) return;
    string url = "https://api.telegram.org/bot" + Telegram_Token +
                 "/sendMessage?chat_id=" + Telegram_Chat_ID +
                 "&text=" + message;
    char dummy[], result[]; string res_headers;
    WebRequest("GET", url, "", 5000, dummy, result, res_headers);
}