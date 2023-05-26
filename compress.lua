local LibDeflate = require "LibDeflate"
local maketree = require "maketree"
local lz77 = require "lz77"
local token_encode_map = require "token_encode_map"

local b64str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
local b64lut = {}
for i, c in b64str:gmatch "()(.)" do b64lut[c] = i-1 end
local function round(n) if n % 1 >= 0.5 then return math.ceil(n) else return math.floor(n) end end

local function bitstream()
    return setmetatable({data = "", partial = 0, len = 0}, {__call = function(self, bits, len)
        if not bits then bits, len = 0, 8 - self.len end
        self.partial = bit32.bor(bit32.lshift(self.partial, len), bits)
        self.len = self.len + len
        while self.len >= 8 do
            local byte = bit32.extract(self.partial, self.len - 8, 8)
            self.data = self.data .. string.char(byte)
            self.len = self.len - 8
        end
    end})
end

local function varint(out, num)
    local bytes = {}
    while num > 127 do bytes[#bytes+1], num = num % 128, math.floor(num / 128) end
    bytes[#bytes+1] = num % 128
    for i = #bytes, 1, -1 do out(bytes[i] + (i == 1 and 0 or 128), 8) end
    return #bytes * 8
end

local function number(out, num)
    if num % 1 == 0 then
        out(num < 0 and 1 or 0, 2)
        return varint(out, math.abs(num))
    else
        local m, e = math.frexp(num)
        m = round((math.abs(m) - 0.5) * 0x20000000000000)
        if m > 0xFFFFFFFFFFFFF then e = e + 1 end
        out((num < 0 and 6 or 4) + (e < 0 and 1 or 0), 3)
        e = math.abs(e)
        local nibbles = {}
        while e > 7 do nibbles[#nibbles+1], e = e % 8, math.floor(e / 8) end
        nibbles[#nibbles+1] = e % 8
        for i = #nibbles, 1, -1 do out(nibbles[i] + (i == 1 and 0 or 8), 4) end
        return varint(out, m) + #nibbles * 4 + 3
    end
end

local function nametree(out, names)
    --print(textutils.serialize(names, {compact = true}))
    if not names then
        out(0, 5)
        return 5
    elseif names.idx then
        out(1, 5)
        return varint(out, names.idx - 1) + 5
    end
    names.maxlen = select(2, math.frexp(names.maxlen))
    out(names.maxlen, 4)
    local bits = 4
    local c, n = names.lengths[1], 0
    for _, v in ipairs(names.lengths) do
        if v ~= c or n == 21845 then
            if n > 5461 then out(7, 3) out(n - 5462, 14) bits = bits + 17 + names.maxlen
            elseif n > 1365 then out(6, 3) out(n - 1366, 12) bits = bits + 15 + names.maxlen
            elseif n > 341 then out(5, 3) out(n - 342, 10) bits = bits + 13 + names.maxlen
            elseif n > 85 then out(4, 3) out(n - 86, 8) bits = bits + 11 + names.maxlen
            elseif n > 21 then out(3, 3) out(n - 22, 6) bits = bits + 9 + names.maxlen
            elseif n > 5 then out(2, 3) out(n - 6, 4) bits = bits + 7 + names.maxlen
            elseif n > 1 then out(1, 3) out(n - 2, 2) bits = bits + 5 + names.maxlen
            else out(0, 3) bits = bits + 3 + names.maxlen end
            out(v, names.maxlen)
            c, n = v, 0
        end
        n = n + 1
    end
    if n > 21 then out(3, 2) out(n - 22, 6) bits = bits + 8 + names.maxlen
    elseif n > 5 then out(2, 2) out(n - 6, 4) bits = bits + 6 + names.maxlen
    elseif n > 1 then out(1, 2) out(n - 2, 2) bits = bits + 4 + names.maxlen
    else out(0, 2) bits = bits + 2 + names.maxlen end
    out(c, names.maxlen)
    return bits
end

local function mktree(freq, namelist)
    local names = {list = {}}
    for i, w in pairs(namelist) do names.list[i] = {w[1], freq[w[1]] or 0} end
    names.map, names.lengths = maketree(names.list)
    if not names.map then
        if names.map == nil then return nil
        elseif names.map == false then return {idx = names.lengths} end
    end
    names.maxlen = 0
    for _, w in ipairs(names.lengths) do names.maxlen = math.max(names.maxlen, w) end
    return names
end

local function compress(tokens, maxdist)
    local namefreq, stringtable = {}, ""
    local curnamefreq, curnametok, lasttok = {}, nil, 1
    -- generate string table and prepare identifier list
    for i, v in ipairs(tokens) do
        if v.type == "name" and not token_encode_map[v.text] then
            namefreq[v.text] = (namefreq[v.text] or 0) + 1
        elseif v.type == "keyword" and v.text == "function" and i > lasttok + 2048 then
            --if curnametok then curnametok.names = {} end
            curnametok, lasttok = v, i
        elseif v.type == "string" and not token_encode_map[v.text] then
            v.str = load("return " .. v.text, "=string", "t", {})()
            stringtable = stringtable .. v.str
        end
    end
    --if curnametok then curnametok.names = {} end
    local namelist = {}
    for k, v in pairs(namefreq) do namelist[#namelist+1] = {k, v} end
    table.sort(namelist, function(a, b) return a[2] > b[2] end)
    local _nametree = mktree(namefreq, namelist)
    -- run LZ77 and compute distance tree
    tokens = lz77(tokens, maxdist)
    local distfreq = {}
    for _, v in ipairs(tokens) do if v.type:find "^repeat" then distfreq[v.dist.code] = (distfreq[v.dist.code] or 0) + 1 end end
    local distlist = {}
    for i = 0, 29 do distlist[i+1] = {i, distfreq[i] or 0} end
    local dist = {}
    dist.map, dist.lengths = maketree(distlist)
    if dist.map then
        dist.maxlen = 0
        for _, w in ipairs(dist.lengths) do dist.maxlen = math.max(dist.maxlen, w) end
    elseif dist.map == false then dist = {idx = dist.lengths} end
    -- compute identifier trees from LZ77'd frequency data
    curnametok, lasttok = nil, 1
    for i, v in ipairs(tokens) do
        if v.type == "name" and not token_encode_map[v.text] then
            curnamefreq[v.text] = (curnamefreq[v.text] or 0) + 1
        elseif v.names then
            local names = mktree(curnamefreq, namelist)
            if curnametok then curnametok.names = names
            else namefreq = names end
            curnamefreq, curnametok, lasttok = {}, v, i
        end
    end
    do
        local names = mktree(curnamefreq, namelist)
        if curnametok then curnametok.names = names
        else namefreq = names end
    end
    -- write string-related data
    local out = bitstream()
    out.data = "\27LuzQ" .. LibDeflate:CompressDeflate(stringtable)
    local strtblsize = #out.data - 5
    --print(#namelist)
    -- build and compress identifier list
    varint(out, #namelist)
    local identstr = ""
    for _, v in ipairs(namelist) do
        for c in v[1]:gmatch "." do
            identstr = identstr .. string.char(b64lut[c])
        end
        identstr = identstr .. "\63"
    end
    local identdflt = LibDeflate:CompressDeflate(identstr)
    out()
    out.data = out.data .. identdflt
    local identlistsize = #out.data - strtblsize - 5
    -- write distance and initial identifier tree
    nametree(out, dist)
    nametree(out, _nametree)
    --nametree(out, namefreq)
    print(strtblsize, identlistsize, #out.data - identlistsize - strtblsize - 5)
    -- write tokens
    local tokenbits, namebits, stringbits, numberbits, lzbits, treebits, numlz = 0, 0, 0, 0, 0, 0, 0
    -- local namemap = namefreq and namefreq.map
    local namemap = namefreq and namefreq.map
    for _, v in ipairs(tokens) do
        if token_encode_map[v.text] then
            out(token_encode_map[v.text].code, token_encode_map[v.text].bits)
            tokenbits = tokenbits + token_encode_map[v.text].bits
        elseif v.type == "name" then
            out(token_encode_map[":name"].code, token_encode_map[":name"].bits)
            tokenbits = tokenbits + token_encode_map[":name"].bits
            --print(v.text, namemap and namemap[v.text])
            if namemap then
                out(namemap[v.text].code, namemap[v.text].bits)
                namebits = namebits + namemap[v.text].bits
            end
        elseif v.type == "string" then
            out(token_encode_map[":string"].code, token_encode_map[":string"].bits)
            tokenbits = tokenbits + token_encode_map[":string"].bits
            stringbits = stringbits + varint(out, #v.str)
        elseif v.type == "number" then
            out(token_encode_map[":number"].code, token_encode_map[":number"].bits)
            tokenbits = tokenbits + token_encode_map[":number"].bits
            numberbits = numberbits + number(out, tonumber(v.text))
        elseif v.type:find "^repeat" then
            out(token_encode_map[":" .. v.type].code, token_encode_map[":" .. v.type].bits)
            tokenbits = tokenbits + token_encode_map[":" .. v.type].bits
            out(v.len.extra, v.len.bits)
            out(dist.map[v.dist.code].code, dist.map[v.dist.code].bits)
            out(v.dist.extra, v.dist.bits)
            --print(v.len.code, v.dist.code, v.len.bits + dist.map[v.dist.code].bits + v.dist.bits)
            lzbits = lzbits + v.len.bits + dist.map[v.dist.code].bits + v.dist.bits
            numlz = numlz + 1
        else error("Could not find encoding for token " .. v.type .. "(" .. v.text .. ")!") end
        if v.names then
            local b = nametree(out, v.names)
            print(b / 8)
            treebits = treebits + b
            namemap = v.names and v.names.map
        end
    end
    out(token_encode_map[":end"].code, token_encode_map[":end"].bits)
    out()
    tokenbits = tokenbits + token_encode_map[":end"].bits
    print(tokenbits / 8, namebits / 8, stringbits / 8, numberbits / 8, lzbits / 8, treebits / 8, numlz)
    return out.data
end

return compress