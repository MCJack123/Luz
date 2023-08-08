-- Tabled Asymmetrical Numeral Systems (aka Finite State Entropy) for Lua 5.2
--
-- MIT License
--
-- Copyright (c) 2023 JackMacWindows
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

local ans = {}

local math_floor, math_max = math.floor, math.max
local bit32_band, bit32_rshift, bit32_lshift = bit32.band, bit32.rshift, bit32.lshift

local function round(n) return math_floor(n + 0.5) end
--local function log2(n) local _, r = math_frexp(n) return r-1 end
local function log2(n) return math_floor(math.log(n, 2)) end

function ans.encodeRaw(symbols, requestedR)
    -- extract probabilities
    local freq = {}
    if type(symbols) == "string" then for v in symbols:gmatch "." do freq[v] = (freq[v] or 0) + 1 end
    else for _, v in ipairs(symbols) do freq[v] = (freq[v] or 0) + 1 end end
    -- calculate approximate integer probabilities
    local L = 0
    for _ in pairs(freq) do L = L + 16 end
    local R = math_max(math_floor(log2(L) + 1), requestedR or 1)
    L = 2^R
    local Ls = {}
    local freqsum, sumLs = 0, 0
    for s, v in pairs(freq) do
        freqsum = freqsum + v / #symbols
        Ls[s] = round(freqsum * L) - sumLs
        --print(s, Ls[s])
        sumLs = sumLs + Ls[s]
    end
    assert(sumLs == L, sumLs)
    -- prepare encoding
    local k, nb, start, next, symbol, order = {}, {}, {}, {}, {}, {}
    local X, step = 0, 0.625 * L + 3
    sumLs = 0
    for s in pairs(freq) do
        k[s] = R - log2(Ls[s])
        nb[s] = bit32_lshift(k[s], R+1) - bit32_lshift(Ls[s], k[s])
        start[s] = sumLs - Ls[s]
        next[s] = Ls[s]
        order[#order+1] = s
        for _ = 1, Ls[s] do
            symbol[X] = s
            X = (X + step) % L
        end
        sumLs = sumLs + Ls[s]
    end
    -- create encoding and decoding tables
    local encodingTable, decodingTable = {}, {R = R}
    for x = L, 2*L - 1 do
        local s = symbol[x - L]
        encodingTable[start[s] + next[s]] = x
        local t = {}
        t.symbol = s
        t.nbBits = R - log2(next[s])
        t.newX = bit32_lshift(next[s], t.nbBits) - L
        decodingTable[x-L] = t
        next[s] = next[s] + 1
    end
    -- encode symbols
    local retval = ""
    local partial, bits = 0, 0
    local x = L
    local iter, state, init
    if type(symbols) == "string" then iter, state, init = symbols:reverse():gmatch "()(.)"
    else iter, state, init = function(t, i) if t[i-1] then return i - 1, t[i - 1] end end, symbols, #symbols + 1 end
    for _, s in iter, state, init do
        local nbBits = bit32_rshift(x + nb[s], R + 1)
        partial = partial + bit32_lshift(bit32_band(x, 2^nbBits-1), bits)
        --print(partial, bits, bit32_band(x, 2^nbBits-1))
        bits = bits + nbBits
        while bits >= 8 do
            retval = retval .. string.char(bit32_band(partial, 0xFF))
            partial = bit32_rshift(partial, 8)
            bits = bits - 8
        end
        print(s, x, #retval, nbBits, start[s], nb[s])
        x = encodingTable[start[s] + bit32_rshift(x, nbBits)]
        assert(symbol[x-L] == s, symbol[x-L])
    end
    --print(x)
    partial = partial + bit32_lshift(x - L, bits)
    --print(partial, bits, bit32_band(x, 2^nbBits-1))
    bits = bits + R
    while bits >= 8 do
        retval = retval .. string.char(bit32_band(partial, 0xFF))
        partial = bit32_rshift(partial, 8)
        bits = bits - 8
    end
    if bits > 0 then retval = retval .. string.char(bit32_band(partial, 0xFF)) end
    return retval, decodingTable, bits, Ls, symbol, order
end

function ans.generateDecodeTable(Ls, symbol, R)
    local decodingTable = {R = R}
    local L = 2^R
    local next = {}
    for s in pairs(Ls) do next[s] = Ls[s] end
    for X = 0, L - 1 do
        local s = symbol[X]
        local t = {}
        t.symbol = s
        t.nbBits = R - log2(next[s])
        t.newX = bit32_lshift(next[s], t.nbBits) - L
        decodingTable[X] = t
        next[s] = next[s] + 1
    end
    return decodingTable
end

function ans.decodeRaw(str, nsym, bits, decodingTable)
    local partial, pos = str:byte(-1), #str - 1
    local function readbits(n)
        if n == 0 then return 0 end
        while bits < n do
            partial = bit32_lshift(partial, 8) + str:byte(pos)
            pos = pos - 1
            bits = bits + 8
        end
        local retval = bit32_band(bit32_rshift(partial, bits-n), 2^n-1)
        bits = bits - n
        return retval
    end
    --local X = decodingTable[0].newX + readbits(decodingTable[0].nbBits) --readbits(decodingTable.R)
    local X = readbits(decodingTable.R)
    local retval = {}
    for i = 1, nsym do
        local t = decodingTable[X]
        retval[i] = t.symbol
        --print(i, t.symbol, X)
        if i < nsym then X = t.newX + readbits(t.nbBits) end
    end
    return retval
end

--- Compresses a string or table of symbols using asymmetrical numeral systems.
---@param symbols string|number[] A string or list of number symbols to encode
---@param symbits? number The number of bits to use per symbol
---@return string res The compressed result
function ans.encode(symbols, symbits)
    if type(symbols) ~= "string" and type(symbols) ~= "table" then error("bad argument #1 (string or table expected, got " .. type(symbols) .. ")", 2) end
    if symbits ~= nil and type(symbits) ~= "number" then error("bad argument #2 (number expected, got " .. type(symbits) .. ")", 2) end
    local retval, decodingTable, raw_bits, Ls, _, order = ans.encodeRaw(symbols, symbits + 5)
    local R = decodingTable.R
    local L = 2^R
    local tbl = ""
    local partial, bits = 0, 0
    local function writebits(n, b)
        partial = partial + bit32_lshift(n, bits)
        bits = bits + b
        while bits >= 8 do
            tbl = tbl .. string.char(bit32_band(partial, 0xFF))
            partial = bit32_rshift(partial, 8)
            bits = bits - 8
        end
    end
    writebits(R, 4)
    local nfreq = 0
    for _ in pairs(Ls) do nfreq = nfreq + 1 end
    writebits(nfreq, symbits or 8)
    --print(R, nfreq)
    for _, s in ipairs(order) do
        if type(s) == "string" then writebits(s:byte(), symbits or 8)
        else writebits(s, symbits or 8) end
        writebits(Ls[s], R)
    end
    writebits(#symbols, 28)
    writebits(raw_bits, 3)
    --print(#symbols, raw_bits)
    if bits > 0 then tbl = tbl .. string.char(bit32_band(partial, 0xFF)) end
    return tbl .. retval
end

--- Decompresses a string previously compressed by ans.encode.
---@param str string The string to decompress
---@param tostr? boolean Whether to return a string instead of a table of symbols
---@param symbits? number The number of bits used per symbol
---@return string|number[] res The original uncompressed text
function ans.decode(str, tostr, symbits)
    if type(str) ~= "string" then error("bad argument #1 (string expected, got " .. type(str) .. ")", 2) end
    if symbits ~= nil and type(symbits) ~= "number" then error("bad argument #3 (number expected, got " .. type(symbits) .. ")", 2) end
    local partial, bits, pos = 0, 0, 1
    local function readbits(n)
        if n == 0 then return 0 end
        while bits < n do
            partial = partial + bit32_lshift(str:byte(pos), bits)
            pos = pos + 1
            bits = bits + 8
        end
        local retval = bit32_band(partial, 2^n-1)
        partial = bit32_rshift(partial, n)
        bits = bits - n
        return retval
    end
    local R = readbits(4)
    local L = 2^R
    local nfreq = readbits(symbits or 8)
    local Ls = {}
    local symbol = {}
    local X, step = 0, 0.625 * L + 3
    --print(R, nfreq)
    for _ = 1, nfreq do
        local s = readbits(symbits or 8)
        ---@diagnostic disable-next-line
        if tostr then s = string.char(s) end
        Ls[s] = readbits(R)
        for _ = 1, Ls[s] do
            symbol[X] = s
            X = (X + step) % L
        end
        --print(s, Ls[s])
    end
    local nsym = readbits(28)
    local dbits = readbits(3)
    --print(nsym, dbits)
    local retval = ans.decodeRaw(str:sub(pos), nsym, dbits, ans.generateDecodeTable(Ls, symbol, R))
    if tostr then return table.concat(retval)
    else return retval end
end

return ans
