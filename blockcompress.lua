local ansencode = require "ansencode"
local maketree = require "maketree"

local function rle_varint(n, out)
    if n > 5461 then out(7, 3) out(n - 5462, 14)
    elseif n > 1365 then out(6, 3) out(n - 1366, 12)
    elseif n > 341 then out(5, 3) out(n - 342, 10)
    elseif n > 85 then out(4, 3) out(n - 86, 8)
    elseif n > 21 then out(3, 3) out(n - 22, 6)
    elseif n > 5 then out(2, 3) out(n - 6, 4)
    elseif n > 1 then out(1, 3) out(n - 2, 2)
    else out(0, 3) end
end

local function rle_varint_size(n)
    if n > 5461 then return 17
    elseif n > 1365 then return 15
    elseif n > 341 then return 13
    elseif n > 85 then return 11
    elseif n > 21 then return 9
    elseif n > 5 then return 7
    elseif n > 1 then return 5
    else return 3 end
end

local function rleencode(symbols, nBits, symbolMap, out, start)
    start = start or 1
    local ents = {}
    local c, n = symbols[start], 0
    local stop
    for i = start + 1, #symbols do
        if symbols[i] ~= c or n == 15 then
            ents[#ents+1] = {symbolMap[c], n}
            if #ents == 21845 then stop = i break end
            c, n = symbols[i], 0
        else
            n = n + 1
        end
    end
    if not stop then ents[#ents+1] = {symbolMap[c], n} end
    if out then
        rle_varint(#ents, out)
        for _, v in ipairs(ents) do
            out(v[2], 4)
            out(v[1], nBits)
        end
        return stop
    else
        return stop, #ents * (nBits + 4) + rle_varint_size(#ents)
    end
end

local function huffdict(LsH, symbolMap, out)
    local maxs = 0
    local lengths = {}
    for _, v in ipairs(LsH) do
        lengths[symbolMap[v[1]]] = LsH.R - select(2, math.frexp(v[2])) + 1
        maxs = math.max(symbolMap[v[1]], maxs)
    end
    local c, n = lengths[0] or 0, 0
    local nbits = 0
    --if out then print(#out.data, out.len, LsH.R, maxs) end
    if out then out(LsH.R, 5) out(maxs, 9) end
    for i = 1, maxs do
        if c ~= (lengths[i] or 0) or n == 8 then
            if out then
                if n == 0 then
                    out(0, 1)
                else
                    out(1, 1)
                    out(n - 1, 3)
                end
                --print(c, n)
                out(c, 5)
            end
            nbits = nbits + (n == 0 and 6 or 9)
            c, n = (lengths[i] or 0), 0
        else
            n = n + 1
        end
    end
    if out then
        if n == 0 then
            out(0, 1)
        else
            out(1, 1)
            out(n - 1, 3)
        end
        --print(c, n)
        out(c, 5)
        print("Dictionary size:", nbits + (n == 0 and 6 or 9), "(Huffman)")
    end
    return nbits + (n == 0 and 6 or 9)
end

local function blockcompress(symbols, nBits, defaultLs, symbolMap, out, maxBlockSize)
    if #symbols == 0 then
        -- empty string
        out(1, 1) -- first block
        out(0, 1) -- RLE
        out(0, 3) -- no symbols
        return
    end
    local start = 1
    repeat
        -- extract probabilities
        local freq = {}
        local lzcodes = {}
        local defaultMap = {}
        for _, v in ipairs(defaultLs) do defaultMap[v[1]] = true end
        for i = start, math.min(#symbols, start + 262143) do
            local s = symbols[i]
            if type(s) == "table" then
                symbols[i] = ":repeat" .. s[2].code
                lzcodes[i] = s
                s = symbols[i]
            end
            freq[s] = (freq[s] or 0) + 1
            if defaultLs and not defaultMap[s] then defaultLs = nil end
        end
        if next(freq, next(freq)) == nil then
            -- only one symbol; force RLE
            out(1, 1) -- first block
            out(0, 1) -- RLE
            assert(math.ceil(#symbols / 16) < 21846, "RLE block too long (unimplemented)")
            rle_varint(math.ceil(#symbols / 16), out)
            local s = symbolMap[symbols[1]]
            for i = 1, #symbols, 16 do
                if #symbols - i < 16 then out(#symbols - i, 4)
                else out(15, 4) end
                out(s, nBits)
            end
            return
        end
        local freqlist = {}
        for k, v in pairs(freq) do freqlist[#freqlist+1] = {k, v} end
        table.sort(freqlist, function(a, b) return symbolMap[a[1]] < symbolMap[b[1]] end)
        -- get sizes for each type
        local Ls = ansencode.makeLs(freqlist)
        local _, huffLengths = maketree(Ls, symbolMap)
        local LsH = {}
        local huffSum = 0
        for i, v in ipairs(huffLengths) do assert(v > 0) LsH[i] = {Ls[i][1], 2^(Ls.R-v+1)} huffSum = huffSum + 2^(Ls.R-v+1) end
        for i = 1, #Ls do assert(Ls[i][1] == LsH[i][1], i) end
        LsH.R = select(2, math.frexp(huffSum))-1
        local dictSize = ansencode.encodeDictionary(Ls, symbolMap, nBits)
        local _, rleSize = rleencode(symbols, nBits, symbolMap, nil, start)
        local _, dynBlockSize = ansencode.encodeSymbols(symbols, Ls, nil, start, math.huge)
        local _, huffBlockSize = ansencode.encodeSymbols(symbols, LsH, nil, start, math.huge)
        local staticSize
        if defaultLs then _, staticSize = ansencode.encodeSymbols(symbols, defaultLs, nil, start, math.huge)
        else staticSize = math.huge end
        local dynSize = dynBlockSize + dictSize + 1
        local huffSize = huffBlockSize + huffdict(LsH, symbolMap)
        staticSize = staticSize + 1
        -- intentional bug: we don't count the size of LZ77 data here, but situations
        -- where RLE wins should not be situations where LZ77 is relevant
        -- (TODO: do a mathematical proof or something idk)
        print("Size candidates:", rleSize, staticSize, huffSize, dynSize)
        if rleSize < dynSize and rleSize < staticSize and rleSize < huffSize then
            -- RLE compression blocks
            repeat
                out(start == 1 and 1 or 0, 1)
                out(0, 1)
                start = rleencode(symbols, nBits, symbolMap, out, start)
            until start == nil
            return
        elseif staticSize < dynSize and staticSize < rleSize and staticSize < huffSize then
            -- Static tree blocks
            Ls = defaultLs
        elseif huffSize < rleSize and huffSize < staticSize and huffSize < dynSize then
            -- Huffman-coded dictionary
            Ls = LsH
        end
        --print(#out.data, out.len)
        out(start == 1 and 1 or 0, 1)
        out(1, 1)
        if Ls == defaultLs then
            out(0, 1)
            print("Dictionary size: 0 (static)")
        elseif Ls == LsH then
            out(1, 1)
            out(0, 1)
            huffdict(Ls, symbolMap, out)
        else
            out(1, 1)
            out(1, 1)
            ansencode.encodeDictionary(Ls, symbolMap, nBits, out)
        end
        --print("dict", #out.data, out.len)
        local stop = ansencode.encodeSymbols(symbols, Ls, out, start, maxBlockSize)
        --print("stop", stop)
        -- get LZ77 data
        local distfreq = {}
        local lzdata = {}
        for i = #symbols - (stop and stop - 1 or #symbols) + 1, #symbols - start + 1 do
            if lzcodes[i] then
                distfreq[lzcodes[i][1].code] = (distfreq[lzcodes[i][1].code] or 0) + 1
                lzdata[#lzdata+1] = lzcodes[i]
            end
        end
        if #lzdata == 0 then
            out(0, 2)
        else
            -- compute distance tree
            local distlist = {}
            for i = 0, 31 do distlist[i+1] = {i, distfreq[i] or 0} end
            local dist = {}
            dist.map, dist.lengths = maketree(distlist)
            local distsize = 0
            if dist.map then
                -- write full distance tree
                out(1, 1)
                local c, n = dist.lengths[1], 0
                --print(dist.lengths[1])
                for i = 2, 32 do
                    --print(dist.lengths[i])
                    if c ~= dist.lengths[i] or n == 8 then
                        if n == 0 then
                            out(0, 1)
                            distsize = distsize + 5
                        else
                            out(1, 1)
                            out(n - 1, 3)
                            distsize = distsize + 8
                        end
                        out(c, 4)
                        c, n = dist.lengths[i], 0
                    else
                        n = n + 1
                    end
                end
                if n == 0 then
                    out(0, 1)
                    distsize = distsize + 5
                else
                    out(1, 1)
                    out(n - 1, 3)
                    distsize = distsize + 8
                end
                out(c, 4)
            else
                -- write single code
                out(0, 1)
                out(1, 1)
                out(dist.lengths, 5)
                distsize = 7
            end
            -- write LZ77 codes
            print("LZ distance tree size:", distsize)
            print("Number of LZ:", #lzdata)
            local lzbits = 0
            for _, v in ipairs(lzdata) do
                lzbits = lzbits + v[2].bits + v[1].bits
                out(v[2].extra, v[2].bits)
                if dist.map then out(dist.map[v[1].code].code, dist.map[v[1].code].bits) lzbits = lzbits + dist.map[v[1].code].bits end
                out(v[1].extra, v[1].bits)
            end
            print("LZ size:", lzbits)
        end
        --print(#out.data, out.len)
        start = stop
    until start == nil
end

return blockcompress