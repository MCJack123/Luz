local token_frequencies = require "token_frequencies"
local name_frequencies = require "name_frequencies"
local string_frequencies = require "string_frequencies"

local bit32_band, bit32_rshift, bit32_lshift, math_frexp = bit32.band, bit32.rshift, bit32.lshift, math.frexp
local function log2(n) local _, r = math_frexp(n) return r-1 end

local b64str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_\0"
local b64lut = {}
for i, c in b64str:gmatch "()(.)" do b64lut[i-1] = c end
for i = 0, 7 do b64lut[i + 64] = ":repeat" .. i end

local strlut = setmetatable({[256] = ":end"}, {__index = function(_, c) return string.char(c) end})
for i = 0, 15 do strlut[i + 257] = ":repeat" .. i end

local tokenlut = {}
for i, v in ipairs(token_frequencies) do tokenlut[i] = v[1] end

local rlemap = {2, 6, 22, 86, 342, 1366, 5462}

local function makeReader(str)
    local partial, bits, pos = 0, 0, 1
    local function readbits(n)
        if not n then return print(pos, bits, ("%02X"):format(partial % 256)) end
        if n == 0 then return 0 end
        while bits < n do
            partial = bit32_lshift(partial, 8) + str:byte(pos)
            pos = pos + 1
            bits = bits + 8
        end
        local retval = bit32_band(bit32_rshift(partial, bits-n), 2^n-1)
        bits = bits - n
        return retval
    end
    return readbits
end

local function generateDecodeTable(Ls)
    local R = Ls.R
    local L = 2^R
    local X, step = 0, 0.625 * L + 3
    local decodingTable, next, symbol = {R = R}, {}, {}
    for _, p in ipairs(Ls) do
        next[p[1]] = p[2]
        --print(p[1], p[2])
        for _ = 1, p[2] do
            symbol[X] = p[1]
            X = (X + step) % L
        end
    end
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

local function ansdecode(readbits, nbits, decodingTable)
    local X = readbits(decodingTable.R)
    nbits = nbits - decodingTable.R
    local retval = {}
    while nbits > 0 do
        local t = decodingTable[X]
        retval[#retval+1] = t.symbol
        --print(t.symbol, X, nbits)
        --readbits()
        --if nbits == 0 then break end
        X = t.newX + readbits(t.nbBits)
        nbits = nbits - t.nbBits
    end
    --retval[#retval+1] = decodingTable[X].symbol
    --print(decodingTable[X].symbol, X)
    return retval
end

local function blockdecompress(readbits, nBits, defaultLs, symbolMap)
    local retval = {}
    repeat
        print("loop", #retval)
        readbits()
        if readbits(1) == 0 then
            -- decode RLE
            local bits = readbits(3)
            local nEntries
            if bits == 0 then nEntries = 1
            else nEntries = readbits(bits * 2) + rlemap[bits] end
            print(nEntries)
            readbits()
            for i = 1, nEntries do
                local n, c = readbits(4), readbits(nBits)
                for j = 0, n do retval[#retval+1] = symbolMap[c] end
            end
            readbits()
            error()
        else
            -- check dictionary
            local Ls
            if readbits(1) == 1 then
                -- dynamic dictionary
                local R = readbits(4)
                print(R)
                Ls = {R = R}
                if readbits(1) == 1 then
                    -- range-based dictionary
                    print("range")
                    readbits()
                    local nRange = readbits(5)
                    for i = 1, nRange do
                        local low, high = readbits(nBits), readbits(nBits)
                        --print(low, high)
                        for j = low, high do Ls[#Ls+1] = {symbolMap[j], readbits(R)} end
                    end
                else
                    -- list-based dictionary
                    print("list")
                    local nSym = readbits(nBits) + 1
                    for i = 1, nSym do Ls[#Ls+1] = {symbolMap[readbits(nBits)], readbits(R)} end
                end
            else
                -- static dictionary
                if not defaultLs then error("invalid file (dictionary required but not supplied)", 2) end
                Ls = defaultLs
            end
            -- decode ANS block
            readbits()
            local decodingTable = generateDecodeTable(Ls)
            local ansbits = readbits(18)
            print("bits", ansbits)
            local ansdata = ansdecode(readbits, ansbits, decodingTable)
            -- substitute LZ77
            local codetree
            readbits()
            if readbits(1) == 1 then
                -- full distance tree
                local bitlen = {}
                local bitidx = 0
                while bitidx < 30 do
                    if readbits(1) == 1 then
                        local n, c = readbits(3) + 2, readbits(4)
                        for _ = 1, n do
                            if c > 0 then bitlen[#bitlen+1] = {s = bitidx, l = c} end
                            bitidx = bitidx + 1
                        end
                    else
                        local l = readbits(4)
                        if l > 0 then bitlen[#bitlen+1] = {s = bitidx, l = l} end
                        bitidx = bitidx + 1
                    end
                end
                table.sort(bitlen, function(a, b) if a.l == b.l then return a.s < b.s else return a.l < b.l end end)
                bitlen[1].c = 0
                for j = 2, #bitlen do bitlen[j].c = bit32.lshift(bitlen[j-1].c + 1, bitlen[j].l - bitlen[j-1].l) end
                -- create tree from codes
                codetree = {}
                for j = 1, #bitlen do
                    local c = bitlen[j].c
                    --print(j, c)
                    local node = codetree
                    for k = bitlen[j].l - 1, 1, -1 do
                        local n = bit32.extract(c, k, 1)
                        if not node[n+1] then node[n+1] = {} end
                        node = node[n+1]
                    end
                    local n = bit32.extract(c, 0, 1)
                    node[n+1] = bitlen[j].s
                end
            elseif readbits(1) == 1 then
                -- single distance code
                codetree = readbits(5)
            end
            local numlz = 0
            for _, v in ipairs(ansdata) do
                if string.match(v, "^:repeat") then
                    local lencode = tonumber(v:match "^:repeat(%d+)")
                    local ebits = math.max(math.floor(lencode / 2) - 1, 0)
                    if ebits > 0 then
                        local extra = readbits(ebits)
                        lencode = bit32.bor(extra, bit32.lshift(bit32.band(lencode, 1) + 2, ebits)) + 3
                    else lencode = lencode + 3 end
                    local node = codetree
                    while type(node) == "table" do node = node[readbits(1)+1] end
                    local distcode
                    local ebits2 = ebits
                    ebits = math.max(math.floor(node / 2) - 1, 0)
                    if ebits > 0 then
                        local extra = readbits(ebits)
                        distcode = bit32.bor(extra, bit32.lshift(bit32.band(node, 1) + 2, ebits)) + 1
                    else distcode = node + 1 end
                    for _ = 1, lencode do retval[#retval+1] = retval[#retval-distcode+1] end
                    numlz = numlz + 1
                else
                    retval[#retval+1] = v
                end
            end
            print("number of LZ:", numlz)
        end
    until readbits(1) == 1
    return retval
end

local function decompress(data)
    if data:sub(1, 5) ~= "\27LuzA" then error("invalid format", 2) end
    local readbits = makeReader(data:sub(6))
    readbits(1)
    -- read all tables
    local stringtab = blockdecompress(readbits, 9, string_frequencies, strlut)
    local identtab = blockdecompress(readbits, 7, name_frequencies, b64lut)
    local identbits = readbits(6)
    local maxident = readbits(identbits)
    readbits(1)
    local identcodes = blockdecompress(readbits, identbits, nil, setmetatable({}, {__index = function(_, v)
        if v > maxident then return ":repeat" .. (v - maxident - 1) end
        return v
    end}))
    readbits()
    local numtab = blockdecompress(readbits, 9, nil, strlut)
    local tokentab = blockdecompress(readbits, 7, token_frequencies, tokenlut)
    -- recombine tables
    local identifiers, strings = {}, {}
    local numbers = {("d"):rep(#numtab / 8):unpack(table.concat(numtab))}
    local partial = ""
    for _, v in ipairs(stringtab) do
        if v == ":end" then
            strings[#strings+1] = partial
            partial = ""
        else partial = partial .. v end
    end
    partial = ""
    for _, v in ipairs(identtab) do
        if v == "\0" then
            identifiers[#identifiers+1] = partial
            partial = ""
        else partial = partial .. v end
    end
    identifiers[0] = table.remove(identifiers, 1)
    -- read tokens
    local tokens, stringpos, identpos, numpos = {}, 1, 1, 1
    for i, node in ipairs(tokentab) do
        if node == ":end" then break
        elseif node == ":name" then
            if identpos < 16 then print(#tokens, identpos, identcodes[identpos], identifiers[identcodes[identpos]]) end
            tokens[#tokens+1] = identifiers[identcodes[identpos]]
            identpos = identpos + 1
        elseif node == ":string" then
            tokens[#tokens+1] = ("%q"):format(strings[stringpos]):gsub("\\?\n", "\\n"):gsub("\t", "\\t"):gsub("[%z\1-\31\127-\255]", function(n) return ("\\%03d"):format(n:byte()) end)
            stringpos = stringpos + 1
        elseif node == ":number" then
            tokens[#tokens+1] = tostring(numbers[numpos])
            numpos = numpos + 1
        else tokens[#tokens+1] = node end
    end
    -- create source
    local retval = ""
    local lastchar, lastdot = false, false
    for _, v in ipairs(tokens) do
        if (lastchar and v:match "^[A-Za-z0-9_]") or (lastdot and v:match "^%.") then retval = retval .. " " end
        retval = retval .. v
        lastchar, lastdot = v:match "[A-Za-z0-9_]$", v:match "%.$"
    end
    return retval
end

return decompress
