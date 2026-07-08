//+------------------------------------------------------------------+
//| V19 FX Prop Desk — DataCollector                                |
//| Sends H1 candle + indicator data to FastAPI backend             |
//| FIX: Added ema10/ema20 calculation and JSON output              |
//+------------------------------------------------------------------+
#property strict

input string FastAPI_URL        = "http://127.0.0.1/data/candle";
input string FastAPI_AccountURL = "http://127.0.0.1/data/account";
input string API_Key            = "f9e369ad5592a0dcd33c78c4e33bd382";
input string Symbol_List        = "EURUSD,GBPUSD,USDJPY.y,AUDUSD,USDCAD,GBPJPY,EURJPY";
input int    Timeframe          = 60;
input int    CollectOnTick      = 1;
input bool   Debug              = true;

datetime last_bar_time[];
string   symbols[];
int      num_symbols = 0;

string FormatTimestamp(datetime dt) {
    string s = TimeToString(dt, TIME_DATE|TIME_SECONDS);
    StringReplace(s, ".", "-");
    StringReplace(s, ".", "-");
    StringReplace(s, " ", "T");
    return s;
}

int OnInit() {
    string raw = Symbol_List;
    StringReplace(raw, " ", "");
    string tmp[];
    int n = StringSplit(raw, ',', tmp);
    ArrayResize(symbols, n);
    ArrayResize(last_bar_time, n);
    for (int i = 0; i < n; i++) {
        symbols[i]       = tmp[i];
        last_bar_time[i] = 0;
    }
    num_symbols = n;
    EventSetTimer(60);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer() {
    CollectAll();
    SendAccountSnapshot();
}

void OnTick() {
    if (CollectOnTick == 1)
        CollectAll();
}

void SendAccountSnapshot() {
    string body = StringFormat(
        "{\"equity\":%.2f,\"balance\":%.2f}",
        AccountEquity(), AccountBalance());
    string headers = "Content-Type: application/json\r\n";
    if (StringLen(API_Key) > 0)
        headers += "X-API-Key: " + API_Key + "\r\n";
    char post_data[], result[];
    string result_headers;
    StringToCharArray(body, post_data, 0, StringLen(body));
    int res = WebRequest("POST", FastAPI_AccountURL, headers, 5000, post_data, result, result_headers);
    if (Debug) {
        if (res == 200)
            Print("[DataCollector] AccountSnapshot OK equity=", AccountEquity());
        else
            Print("[DataCollector] AccountSnapshot FAIL HTTP=", res,
                  " body=", CharArrayToString(result));
    }
}

void CollectAll() {
    for (int i = 0; i < num_symbols; i++) {
        string   sym  = symbols[i];
        datetime bar0 = iTime(sym, Timeframe, 0);
        if (bar0 <= last_bar_time[i]) continue;
        last_bar_time[i] = bar0;
        CollectAndSend(sym, bar0);
    }
}

void CollectAndSend(string sym, datetime ts) {
    // OHLCV — bar 1 = last closed bar (confirmed, no repaint)
    double o = iOpen  (sym, Timeframe, 1);
    double h = iHigh  (sym, Timeframe, 1);
    double l = iLow   (sym, Timeframe, 1);
    double c = iClose (sym, Timeframe, 1);
    long   v = iVolume(sym, Timeframe, 1);

    // Indicators — bar 1 = closed, confirmed
    // FIX: ema10/ema20 added for EMA_SHORT_COUNTER filter in signal engine
    double ema10       = iMA(sym, Timeframe,  10, 0, MODE_EMA, PRICE_CLOSE, 1);
    double ema20       = iMA(sym, Timeframe,  20, 0, MODE_EMA, PRICE_CLOSE, 1);
    double ema50       = iMA(sym, Timeframe,  50, 0, MODE_EMA, PRICE_CLOSE, 1);
    double ema200      = iMA(sym, Timeframe, 200, 0, MODE_EMA, PRICE_CLOSE, 1);
    // FIX: ema50_prev/ema200_prev (bar 2) for EMA slope filter in signal engine
    // slope = ema50(bar1) > ema50(bar2) → rising; else falling
    double ema50_prev  = iMA(sym, Timeframe,  50, 0, MODE_EMA, PRICE_CLOSE, 2);
    double ema200_prev = iMA(sym, Timeframe, 200, 0, MODE_EMA, PRICE_CLOSE, 2);
    double rsi    = iRSI(sym, Timeframe, 14, PRICE_CLOSE, 1);
    double adx    = iADX(sym, Timeframe, 14, PRICE_CLOSE, MODE_MAIN,    1);
    double di_p   = iADX(sym, Timeframe, 14, PRICE_CLOSE, MODE_PLUSDI,  1);
    double di_m   = iADX(sym, Timeframe, 14, PRICE_CLOSE, MODE_MINUSDI, 1);
    double atr    = iATR(sym, Timeframe, 14, 1);

    // Build JSON — ISO 8601 timestamp
    string body = StringFormat(
        "{"
        "\"symbol\":\"%s\","
        "\"timeframe\":\"H1\","
        "\"timestamp\":\"%s\","
        "\"open\":%.6f,"
        "\"high\":%.6f,"
        "\"low\":%.6f,"
        "\"close\":%.6f,"
        "\"volume\":%I64d,"
        "\"ema10\":%.6f,"
        "\"ema20\":%.6f,"
        "\"ema50\":%.6f,"
        "\"ema200\":%.6f,"
        "\"ema50_prev\":%.6f,"
        "\"ema200_prev\":%.6f,"
        "\"rsi14\":%.4f,"
        "\"adx14\":%.4f,"
        "\"di_plus\":%.4f,"
        "\"di_minus\":%.4f,"
        "\"atr14\":%.6f"
        "}",
        sym,
        FormatTimestamp(iTime(sym, Timeframe, 1)),
        o, h, l, c, v,
        ema10, ema20, ema50, ema200,
        ema50_prev, ema200_prev,
        rsi, adx, di_p, di_m, atr
    );

    string headers = "Content-Type: application/json\r\n";
    if (StringLen(API_Key) > 0)
        headers += "X-API-Key: " + API_Key + "\r\n";

    char   post_data[], result[];
    string result_headers;
    StringToCharArray(body, post_data, 0, StringLen(body));

    int res = WebRequest("POST", FastAPI_URL, headers, 5000, post_data, result, result_headers);

    if (Debug) {
        if (res == 200 || res == 201)
            Print("[DataCollector] OK ", sym, " | ",
                  FormatTimestamp(iTime(sym, Timeframe, 1)),
                  " ema10=", DoubleToStr(ema10,5),
                  " ema20=", DoubleToStr(ema20,5),
                  " ema50_slope=", DoubleToStr(ema50-ema50_prev,6),
                  " ema200_slope=", DoubleToStr(ema200-ema200_prev,6));
        else
            Print("[DataCollector] FAIL ", sym, " HTTP=", res,
                  " body=", CharArrayToString(result));
    }
}