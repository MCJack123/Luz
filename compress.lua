local LibDeflate = require "LibDeflate"
local maketree = require "maketree"
local lz77 = require "lz77"
local token_encode_map = require "token_encode_map"

local b64str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
local b64lut = {}
for i, c in b64str:gmatch "()(.)" do b64lut[c] = i-1 end
local function round(n) if n % 1 >= 0.5 then return math.ceil(n) else return math.floor(n) end end

local function distcode(i)
    if i == 0 or i == 1 then return {code = i, extra = 0, bits = 0} end
    local ebits = math.max(select(2, math.frexp(i)) - 2, 0)
    local mask = 2^ebits
    return {code = ebits * 2 + (bit32.btest(i, mask) and 3 or 2), extra = bit32.band(i, mask-1), bits = ebits}
end

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
    if out then for i = #bytes, 1, -1 do out(bytes[i] + (i == 1 and 0 or 128), 8) end end
    return #bytes * 8
end

local function number(out, num)
    if num % 1 == 0 then
        if out then out(num < 0 and 1 or 0, 2) end
        return varint(out, math.abs(num))
    else
        local m, e = math.frexp(num)
        m = round((math.abs(m) - 0.5) * 0x20000000000000)
        if m > 0xFFFFFFFFFFFFF then e = e + 1 end
        if out then out((num < 0 and 6 or 4) + (e < 0 and 1 or 0), 3) end
        e = math.abs(e)
        local nibbles = {}
        while e > 7 do nibbles[#nibbles+1], e = e % 8, math.floor(e / 8) end
        nibbles[#nibbles+1] = e % 8
        if out then for i = #nibbles, 1, -1 do out(nibbles[i] + (i == 1 and 0 or 8), 4) end end
        return varint(out, m) + #nibbles * 4 + 3
    end
end

local function nametree(out, names)
    if not names or next(names) == nil then
        if out then out(0, 5) end
        return 5
    elseif names.idx then
        if out then out(1, 5) end
        return varint(out, names.idx - 1) + 5
    end
    --[=[
    names.lengths[#names.lengths+1] = -1
    local lengths = burrowsWheelerTransform(names.lengths)
    for i = 1, #lengths do lengths[i] = lengths[i] + 1 end
    lengths = moveToFront(lengths, names.maxlen+1)
    names.maxlen = select(2, math.frexp(names.maxlen+1))
    --[[]=]
    local lengths = names.lengths
    --local lengths = moveToFront(names.lengths, names.maxlen)
    names.maxlen = select(2, math.frexp(names.maxlen))
    --]]
    if out then out(names.maxlen, 4) end
    local bits = 4
    local c, n = lengths[1], 0
    local num, nonzero = 1, 0
    for _, v in ipairs(lengths) do
        if v ~= c or n == 85 then
            --print(n, c)
            if n > 21 then if out then out(3, 2) out(n - 22, 6) end bits = bits + 8 + names.maxlen
            elseif n > 5 then if out then out(2, 2) out(n - 6, 4) end bits = bits + 6 + names.maxlen
            elseif n > 1 then if out then out(1, 2) out(n - 2, 2) end bits = bits + 4 + names.maxlen
            else if out then out(0, 2) end bits = bits + 2 + names.maxlen end
            if out then out(c, names.maxlen) end
            c, n = v, 0
            num = num + 1
            if c > 1 then nonzero = nonzero + 1 end
        end
        n = n + 1
    end
    --print(n, c)
    if n > 21 then if out then out(3, 2) out(n - 22, 6) end bits = bits + 8 + names.maxlen
    elseif n > 5 then if out then out(2, 2) out(n - 6, 4) end bits = bits + 6 + names.maxlen
    elseif n > 1 then if out then out(1, 2) out(n - 2, 2) end bits = bits + 4 + names.maxlen
    else if out then out(0, 2) end bits = bits + 2 + names.maxlen end
    if out then out(c, names.maxlen) end
    if c > 1 then nonzero = nonzero + 1 end
    --print(bits / 8, names.maxlen, num, nonzero)
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

local function compress(tokens, level)
    local maxdist = level and (level == 0 and 0 or 2^(level+6))
    local namecodefreq, namelist, stringtable, nametable = {}, {}, "", {}
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
    -- generate string table and prepare identifier list
    for i, v in ipairs(tokens) do
        if v.type == "name" and not token_encode_map[v.text] then
            local code
            for j, w in ipairs(namelist) do if w == v.text then code = j break end end
            if code then
                v.code = distcode(code)
                namecodefreq[v.code.code] = (namecodefreq[v.code.code] or 0) + 1
                table.insert(namelist, 1, table.remove(namelist, code))
            else
                v.code = distcode(0)
                namecodefreq[0] = (namecodefreq[0] or 0) + 1
                nametable[#nametable+1] = v.text
                table.insert(namelist, 1, v.text)
            end
        elseif v.type == "string" and not token_encode_map[v.text] then
            v.str = load("return " .. v.text, "=string", "t", {})()
            stringtable = stringtable .. v.str
        end
    end
    --if curnametok then curnametok.names = {} end
    local namecodelist = {}
    for i = 0, 29 do namecodelist[#namecodelist+1] = {i, namecodefreq[i] or 0} end
    local namecodetree = mktree(namecodefreq, namecodelist)
    -- generate custom dictionary & compare sizes
    local freq = {}
    for _, v in ipairs(tokens) do
        if token_encode_map[v.text] then freq[v.text] = (freq[v.text] or 0) + 1
        else freq[":" .. v.type] = (freq[":" .. v.type] or 0) + 1 end
    end
    local tokenlist = {{":name", 0}, {":string", 0}, {":number", 0}}
    for i = 0, 29 do tokenlist[#tokenlist+1] = {":repeat" .. i, 0} end
    for k in pairs(token_encode_map) do tokenlist[#tokenlist+1] = {k, 0} end
    table.sort(tokenlist, function(a, b) return a[1] < b[1] end)
    local customtree = mktree(freq, tokenlist)
    local dynamicSize, staticSize = nametree(nil, customtree), 0
    for _, v in ipairs(tokens) do
        if token_encode_map[v.text] then
            staticSize = staticSize + token_encode_map[v.text].bits
            dynamicSize = dynamicSize + customtree.map[v.text].bits
        elseif v.type == "name" then
            staticSize = staticSize + token_encode_map[":name"].bits + namecodetree.map[v.code.code].bits + v.code.bits
            dynamicSize = dynamicSize + customtree.map[":name"].bits + namecodetree.map[v.code.code].bits + v.code.bits
        elseif v.type == "string" then
            staticSize = staticSize + token_encode_map[":string"].bits + varint(nil, #v.str)
            dynamicSize = dynamicSize + customtree.map[":string"].bits + varint(nil, #v.str)
        elseif v.type == "number" then
            staticSize = staticSize + token_encode_map[":number"].bits + number(nil, tonumber(v.text))
            dynamicSize = dynamicSize + customtree.map[":number"].bits + number(nil, tonumber(v.text))
        elseif v.type:find "^repeat" then
            staticSize = staticSize + token_encode_map[":" .. v.type].bits + v.len.bits + dist.map[v.dist.code].bits + v.dist.bits
            dynamicSize = dynamicSize + customtree.map[":" .. v.type].bits + v.len.bits + dist.map[v.dist.code].bits + v.dist.bits
        else error("Could not find encoding for token " .. v.type .. "(" .. v.text .. ")!") end
    end
    print(staticSize, dynamicSize)
    -- write string-related data
    local out = bitstream()
    out.data = "\27LuzQ" .. LibDeflate:CompressDeflate(stringtable, {level = level})
    local strtblsize = #out.data - 5
    --print(#namelist)
    -- build and compress identifier list
    --varint(out, #namelist)
    local identstr = ""
    for _, v in ipairs(nametable) do
        for c in v:gmatch "." do
            identstr = identstr .. string.char(b64lut[c])
        end
        identstr = identstr .. "\63"
    end
    local identdflt = LibDeflate:CompressDeflate(identstr, {level = level})
    --out()
    out.data = out.data .. identdflt
    local identlistsize = #out.data - strtblsize - 5
    -- write distance and initial identifier tree
    nametree(out, dist)
    nametree(out, namecodetree)
    local tokenmap
    if dynamicSize < staticSize then
        out(1, 1)
        nametree(out, customtree)
        tokenmap = customtree.map
    else
        out(0, 1)
        tokenmap = token_encode_map
    end
    --nametree(out, namefreq)
    print(strtblsize, identlistsize, #out.data - identlistsize - strtblsize - 5, #namelist)
    -- write tokens
    local tokenbits, namebits, stringbits, numberbits, lzbits, treebits, numlz = 0, 0, 0, 0, 0, 0, 0
    for _, v in ipairs(tokens) do
        if token_encode_map[v.text] then
            out(tokenmap[v.text].code, tokenmap[v.text].bits)
            tokenbits = tokenbits + tokenmap[v.text].bits
        elseif v.type == "name" then
            out(tokenmap[":name"].code, tokenmap[":name"].bits)
            tokenbits = tokenbits + tokenmap[":name"].bits
            --print(v.text, namemap and namemap[v.text])
            out(namecodetree.map[v.code.code].code, namecodetree.map[v.code.code].bits)
            out(v.code.extra, v.code.bits)
            namebits = namebits + namecodetree.map[v.code.code].bits + v.code.bits
        elseif v.type == "string" then
            out(tokenmap[":string"].code, tokenmap[":string"].bits)
            tokenbits = tokenbits + tokenmap[":string"].bits
            stringbits = stringbits + varint(out, #v.str)
        elseif v.type == "number" then
            out(tokenmap[":number"].code, tokenmap[":number"].bits)
            tokenbits = tokenbits + tokenmap[":number"].bits
            numberbits = numberbits + number(out, tonumber(v.text))
        elseif v.type:find "^repeat" then
            out(tokenmap[":" .. v.type].code, tokenmap[":" .. v.type].bits)
            tokenbits = tokenbits + tokenmap[":" .. v.type].bits
            out(v.len.extra, v.len.bits)
            out(dist.map[v.dist.code].code, dist.map[v.dist.code].bits)
            out(v.dist.extra, v.dist.bits)
            --print(v.len.code, v.dist.code, v.len.bits + dist.map[v.dist.code].bits + v.dist.bits)
            lzbits = lzbits + v.len.bits + dist.map[v.dist.code].bits + v.dist.bits
            numlz = numlz + 1
        else error("Could not find encoding for token " .. v.type .. "(" .. v.text .. ")!") end
    end
    out(token_encode_map[":end"].code, token_encode_map[":end"].bits)
    out()
    tokenbits = tokenbits + token_encode_map[":end"].bits
    print(tokenbits / 8, namebits / 8, stringbits / 8, numberbits / 8, lzbits / 8, treebits / 8, numlz)
    return out.data
end

return compress