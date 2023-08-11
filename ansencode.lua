local math_floor, math_max, math_frexp = math.floor, math.max, math.frexp
local bit32_band, bit32_rshift, bit32_lshift = bit32.band, bit32.rshift, bit32.lshift

local function round(n) return math_floor(n + 0.5) end
local function log2(n) local _, r = math_frexp(n) return r-1 end
--local function log2(n) return math_floor(math.log(n, 2)) end

local ansencode = {}

function ansencode.makeLs(freq)
    local nL = 4
    local Ls
    repeat
        nL = nL * 2
        local L, total = 0, 0
        for _, v in ipairs(freq) do L = L + nL total = total + v[2] end
        local R = math_max(math_floor(log2(L) + 1), 1)
        L = 2^R
        Ls = {R = R}
        local freqsum, sumLs = 0, 0
        local fail = false
        for _, p in ipairs(freq) do
            local s, v = p[1], p[2]
            freqsum = freqsum + v / total
            Ls[#Ls+1] = {s, round(freqsum * L) - sumLs}
            if Ls[#Ls][2] == 0 then fail = true end
            --print(s, Ls[s])
            sumLs = sumLs + Ls[#Ls][2]
        end
    until not fail
    --table.sort(Ls, function(a, b) return a[1] < b[1] end)
    return Ls
end

function ansencode.encodeSymbols(symbols, Ls, out, startPos, maxBlockSize)
    startPos = startPos or 1
    maxBlockSize = maxBlockSize or 262144
    local R = Ls.R
    local L = 2^R
    -- prepare encoding
    local k, nb, start, next, symbol, order = {}, {}, {}, {}, {}, {}
    local X, step = 0, 0.625 * L + 3
    local sumLs = 0
    for _, p in ipairs(Ls) do
        local s, v = p[1], p[2]
        k[s] = R - log2(v)
        nb[s] = bit32_lshift(k[s], R+1) - bit32_lshift(v, k[s])
        start[s] = sumLs - v
        next[s] = v
        order[#order+1] = s
        for _ = 1, v do
            symbol[X] = s
            X = (X + step) % L
        end
        sumLs = sumLs + v
    end
    -- create encoding table
    local encodingTable = {}
    for x = L, 2*L - 1 do
        local s = symbol[x - L]
        encodingTable[start[s] + next[s]] = x
        next[s] = next[s] + 1
    end
    -- encode symbols
    local bitbuf = {}
    local x = L
    local iter, state, init
    local bitcount, stop, nproc = 0, nil, 0
    if type(symbols) == "string" then iter, state, init = symbols:reverse():sub(startPos):gmatch "()(.)"
    else iter, state, init = function(t, i) if t[i-1] then return i - 1, t[i - 1] end end, symbols, #symbols + 2 - startPos end
    for _, s in iter, state, init do
        local nbBits = bit32_rshift(x + nb[s], R + 1)
        if nproc + 1 >= maxBlockSize then
            stop = startPos + nproc
            break
        end
        bitbuf[#bitbuf+1] = {bit32_band(x, 2^nbBits-1), nbBits}
        bitcount = bitcount + nbBits
        nproc = nproc + 1
        --print(s, x, #bitbuf, nbBits, start[s], nb[s])
        x = encodingTable[start[s] + bit32_rshift(x, nbBits)]
        assert(symbol[x-L] == s, symbol[x-L])
    end
    --print(x)
    -- write out
    if out then
        out(nproc, 18)
        print("Size of block:", bitcount + R, nproc)
        out(x - L, R)
        for i = #bitbuf, 1, -1 do out(bitbuf[i][1], bitbuf[i][2]) end
        return stop
    else
        return stop, bitcount + R + 18
    end
end

function ansencode.encodeDictionary(Ls, symbolMap, nBits, out)
    -- calculate size
    local maxL = 0
    for i, v in ipairs(Ls) do
        maxL = math_max(maxL, v[2])
    end
    maxL = math_max(math_floor(log2(maxL) + 1), 1)
    local listSize = nBits + 8
    local totalL = 2^Ls.R - 1
    local lastn = -1
    for _, v in ipairs(Ls) do
        local nbits = math.min(select(2, math_frexp(totalL)), maxL)
        if v[2] < 2^math.floor(nbits/2) then listSize = listSize + math.floor(nbits/2) + 2
        else listSize = listSize + nbits + 2 end
        if symbolMap[v[1]] - lastn ~= 1 then listSize = listSize + nBits end
        lastn = symbolMap[v[1]]
        totalL = totalL - v[2]
    end
    -- encode list-based dictionary
    if not out then return listSize + 8 end
    out(Ls.R - 5, 4)
    out(maxL - 5, 4)
    out(#Ls, nBits)
    print("Dictionary size:", listSize + 8, "(ANS)", Ls.R)
    totalL = 2^Ls.R - 1
    lastn = -1
    for _, v in ipairs(Ls) do
        local nbits = math.min(select(2, math_frexp(totalL)), maxL)
        if symbolMap[v[1]] - lastn ~= 1 then
            out(1, 1)
            out(symbolMap[v[1]], nBits)
        else out(0, 1) end
        --print(nbits, v[2], totalL)
        if v[2] < 2^math.floor(nbits/2) then
            out(0, 1)
            out(v[2], math.floor(nbits/2))
        else
            out(1, 1)
            out(v[2], nbits)
        end
        totalL = totalL - v[2]
        lastn = symbolMap[v[1]]
    end
end

return ansencode
