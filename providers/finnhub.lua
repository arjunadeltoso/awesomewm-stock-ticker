--------------------------------------------------------------------------------
-- Provider: Finnhub (https://finnhub.io) -- supported API, free tier 60 req/min.
--
-- Exists mainly to demonstrate the provider contract with authentication.
-- Requires an API key; supply it in the widget config as either:
--     api_key     = "xxxx"                                  -- literal
--     api_key_cmd = "cat ~/.credentials/finnhub-token"      -- read at runtime
--
-- Finnhub's /quote returns only prices, no company name or trading calendar,
-- so `name` is nil and `market_state` is UNKNOWN. The widget copes with both.
--------------------------------------------------------------------------------

-- Derive the package root from our own module name so the widget works
-- regardless of what the containing directory is called.
local ROOT = (...):match("^(.-)%.providers%.") or "awesomewm-stock-ticker"
local json = require(ROOT .. ".json")
local url  = require(ROOT .. ".url")

local P = { name = "finnhub", needs_key = true,
              quote_url = "https://finnhub.io/quote/%s" }

function P.request(symbol, opts)
    opts = opts or {}
    local host = opts.host or "https://finnhub.io/api/v1"
    return {
        url = string.format("%s/quote?symbol=%s", host, url.encode(symbol)),
        -- Sent as a header rather than a query param so the key stays out of
        -- any URL that might be logged.
        headers = { ["X-Finnhub-Token"] = opts.api_key or "" },
    }
end

function P.parse(body, symbol)
    local d, err = json.decode(body)
    if not d then return nil, "json: " .. tostring(err) end
    if type(d) ~= "table" then return nil, "unexpected response shape" end
    if d.error then return nil, tostring(d.error) end

    -- c=current, pc=previous close, d=change, dp=change %, h/l=day high/low
    local price = type(d.c) == "number" and d.c or nil
    if not price then return nil, "no price in response" end
    -- Finnhub returns all-zeros for an unknown symbol rather than an error.
    if price == 0 and (d.pc == 0 or d.pc == nil) then
        return nil, "unknown symbol '" .. tostring(symbol) .. "'"
    end

    return {
        symbol         = symbol,
        name           = nil,
        price          = price,
        previous_close = type(d.pc) == "number" and d.pc or nil,
        change         = type(d.d) == "number" and d.d or nil,
        change_percent = type(d.dp) == "number" and d.dp or nil,
        currency       = "USD",
        day_high       = type(d.h) == "number" and d.h or nil,
        day_low        = type(d.l) == "number" and d.l or nil,
        market_state   = "UNKNOWN",
        timestamp      = type(d.t) == "number" and d.t or os.time(),
    }
end

return P
