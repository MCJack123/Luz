local function distcode(i)
    if i == 0 or i == 1 then return {code = i, extra = 0, bits = 0, orig = i} end
    local ebits = math.max(select(2, math.frexp(i)) - 2, 0)
    local mask = 2^ebits
    return {code = ebits * 2 + (bit32.btest(i, mask) and 3 or 2), extra = bit32.band(i, mask-1), bits = ebits, orig = i}
end

local function lz77(insts, maxdist)
    maxdist = math.min(maxdist or 1024, 32768)
    local retval, repeats = {}, {}
    local lookback = {}
    local lastrep = 1
    local i = 1
    while i <= #insts do
        local v = insts[i]
        if not v.names and lookback[v[1]] and lookback[v[1]][v[2]] then
            local lblist = lookback[v[1]][v[2]]
            local max, pos, weight = 0, nil, 0
            for n = #lblist, 1, -1 do
                local l = lblist[n]
                local w = insts[i][2]
                if i - l > maxdist then break end
                for j = 1, math.min(#insts - i, 129) do
                    local lj = (j - 1) % (i - l) + 1
                    if insts[i+j][1] == insts[l+lj][1] and insts[i+j][2] == insts[l+lj][2] then
                        w = w + insts[i+j][2]
                        if w > weight then max, pos, weight = j, l, w end
                    else break end
                end
            end
            if weight >= 27 and max >= 3 then
                local len = distcode(max - 3)
                local dist = distcode(i - pos - 1)
                local offset = distcode(#retval - lastrep)
                repeats[#repeats+1] = {offset = offset, dist = dist, len = len}
                lastrep = #retval
                for j = 0, max do
                    v = insts[i+j]
                    lookback[v[1]][v[2]][#lookback[v[1]][v[2]]+1] = i+j
                end
                i = i + max + 1
                v = nil
            end
        end
        if v then
            retval[#retval+1] = v
            lookback[v[1]] = lookback[v[1]] or {}
            lookback[v[1]][v[2]] = lookback[v[1]][v[2]] or {}
            lookback[v[1]][v[2]][#lookback[v[1]][v[2]]+1] = i
            i = i + 1
        end
    end
    return retval, repeats
end

return lz77