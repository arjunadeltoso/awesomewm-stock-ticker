--------------------------------------------------------------------------------
-- url.lua -- percent-encoding for building request URLs.
--
-- Providers interpolate a symbol into a URL. Most tickers are harmless, but
-- "^GSPC", "EURUSD=X" and anything containing & # ? or a space will either
-- change the meaning of the URL or produce an invalid one. Encoding is safe for
-- ordinary symbols too: servers decode before matching, so "%5EGSPC" and
-- "^GSPC" resolve identically.
--------------------------------------------------------------------------------

local M = {}

--- Percent-encode a string for use in a URL path segment or query value.
-- Unreserved characters (RFC 3986 §2.3: A-Z a-z 0-9 - . _ ~) pass through;
-- everything else, including non-ASCII bytes, is encoded.
-- @tparam string s
-- @treturn string
function M.encode(s)
    return (tostring(s):gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

return M
