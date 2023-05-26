local function distcode(i)
    if i == 0 or i == 1 then return {code = i, extra = 0, bits = 0} end
    local ebits = math.max(select(2, math.frexp(i)) - 2, 0)
    local mask = 2^ebits
    return {code = ebits * 2 + (bit32.btest(i, mask) and 3 or 2), extra = bit32.band(i, mask-1), bits = ebits}
end

local function lz77(tokens, maxdist)
    maxdist = math.min(maxdist or 1024, 32768)
    local retval = {}
    local lookback = {}
    local i = 1
    while i <= #tokens do
        local v = tokens[i]
        if not v.names and lookback[v.type] and lookback[v.type][v.text] then
            local lblist = lookback[v.type][v.text]
            local max, pos = 0
            for n = #lblist, 1, -1 do
                local l = lblist[n]
                if i - l > maxdist then break end
                for j = 1, math.min(i - l, #tokens - i, 129) do
                    if tokens[i+j].type == tokens[l+j].type and tokens[i+j].text == tokens[l+j].text then
                        if j > max then max, pos = j, l end
                        if tokens[l+j].names then break end
                    else break end
                end
            end
            if max >= 2 then
                local len = distcode(max - 2)
                local dist = distcode(i - pos - 1)
                retval[#retval+1] = {type = "repeat" .. len.code, text = "", dist = dist, len = len}
                for j = 0, max do
                    v = tokens[i+j]
                    lookback[v.type][v.text][#lookback[v.type][v.text]+1] = i+j
                end
                if tokens[i+max].names then retval[#retval].names = tokens[i+max].names end
                i = i + max + 1
                v = nil
            end
        end
        if v then
            retval[#retval+1] = v
            lookback[v.type] = lookback[v.type] or {}
            lookback[v.type][v.text] = lookback[v.type][v.text] or {}
            lookback[v.type][v.text][#lookback[v.type][v.text]+1] = i
            i = i + 1
        end
    end
    return retval
end

return lz77