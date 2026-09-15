--------------------------------------------------------------------------------
-- json.lua -- minimal JSON decoder (decode only), pure Lua 5.1+.
--
-- Vendored so the stocks widget has zero external dependencies: awesome already
-- ships everything else it needs. Decode-only on purpose -- the widget never
-- serialises JSON, and leaving encode out keeps this small enough to audit.
--
-- decode(str) -> value, nil   on success
--             -> nil, errmsg  on failure  (never raises)
--
-- JSON null decodes to the sentinel M.null, not nil, so that a present-but-null
-- field can be told apart from a missing one.
--------------------------------------------------------------------------------

local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })

local escapes = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
    f = '\f', n = '\n', r = '\r', t = '\t',
}

local function skip_ws(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

-- Encode a unicode codepoint as UTF-8 (Lua 5.3 has utf8.char; keep it portable).
local function utf8_char(cp)
    if utf8 and utf8.char then return utf8.char(cp) end
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
    end
    return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
end

local parse_value

local function parse_string(s, i)
    -- i points at the opening quote
    local buf, j = {}, i + 1
    while true do
        local c = s:sub(j, j)
        if c == "" then return nil, nil, "unterminated string" end
        if c == '"' then return table.concat(buf), j + 1 end
        if c == "\\" then
            local e = s:sub(j + 1, j + 1)
            if escapes[e] then
                buf[#buf + 1] = escapes[e]
                j = j + 2
            elseif e == "u" then
                local hex = s:sub(j + 2, j + 5)
                if not hex:match("^%x%x%x%x$") then
                    return nil, nil, "bad \\u escape"
                end
                local cp = tonumber(hex, 16)
                -- surrogate pair
                if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j + 6, j + 7) == "\\u" then
                    local lo = tonumber(s:sub(j + 8, j + 11), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                        j = j + 6
                    end
                end
                buf[#buf + 1] = utf8_char(cp)
                j = j + 6
            else
                return nil, nil, "bad escape \\" .. e
            end
        else
            -- consume a run of ordinary characters at once
            local _, stop = s:find('^[^"\\]+', j)
            buf[#buf + 1] = s:sub(j, stop)
            j = stop + 1
        end
    end
end

local function parse_number(s, i)
    local num = s:match("^%-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if not num or num == "" then return nil, nil, "bad number" end
    local v = tonumber(num)
    if not v then return nil, nil, "bad number '" .. num .. "'" end
    return v, i + #num
end

local function parse_array(s, i)
    local arr, j = {}, skip_ws(s, i + 1)
    if s:sub(j, j) == "]" then return arr, j + 1 end
    while true do
        local v, nj, err = parse_value(s, j)
        if err then return nil, nil, err end
        arr[#arr + 1] = v
        j = skip_ws(s, nj)
        local c = s:sub(j, j)
        if c == "," then j = skip_ws(s, j + 1)
        elseif c == "]" then return arr, j + 1
        else return nil, nil, "expected ',' or ']' at " .. j end
    end
end

local function parse_object(s, i)
    local obj, j = {}, skip_ws(s, i + 1)
    if s:sub(j, j) == "}" then return obj, j + 1 end
    while true do
        if s:sub(j, j) ~= '"' then return nil, nil, "expected key string at " .. j end
        local k, nj, err = parse_string(s, j)
        if err then return nil, nil, err end
        j = skip_ws(s, nj)
        if s:sub(j, j) ~= ":" then return nil, nil, "expected ':' at " .. j end
        local v, nj2, err2 = parse_value(s, skip_ws(s, j + 1))
        if err2 then return nil, nil, err2 end
        obj[k] = v
        j = skip_ws(s, nj2)
        local c = s:sub(j, j)
        if c == "," then j = skip_ws(s, j + 1)
        elseif c == "}" then return obj, j + 1
        else return nil, nil, "expected ',' or '}' at " .. j end
    end
end

parse_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "" then return nil, nil, "unexpected end of input" end
    if c == "{" then return parse_object(s, i) end
    if c == "[" then return parse_array(s, i) end
    if c == '"' then return parse_string(s, i) end
    if c == "t" then
        if s:sub(i, i + 3) == "true" then return true, i + 4 end
        return nil, nil, "invalid literal at " .. i
    end
    if c == "f" then
        if s:sub(i, i + 4) == "false" then return false, i + 5 end
        return nil, nil, "invalid literal at " .. i
    end
    if c == "n" then
        if s:sub(i, i + 3) == "null" then return M.null, i + 4 end
        return nil, nil, "invalid literal at " .. i
    end
    return parse_number(s, i)
end

--- Decode a JSON document.
-- @tparam string str
-- @return value on success, or nil plus an error message
function M.decode(str)
    if type(str) ~= "string" then return nil, "expected string, got " .. type(str) end
    local ok, v, i, err = pcall(parse_value, str, 1)
    if not ok then return nil, "decoder error: " .. tostring(v) end
    if err then return nil, err end
    if i then
        local j = skip_ws(str, i)
        if j <= #str then return nil, "trailing garbage at " .. j end
    end
    return v
end

return M
