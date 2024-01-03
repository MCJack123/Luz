local LibDeflate = require "LibDeflate"
local lz77 = require "lz77"
local maketree = require "maketree"
local varint = require "number".varint
local parse = require "parse"

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

local function nametree(out, names)
    if not names or next(names) == nil then
        if out then out(0, 5) end
        return 5
    elseif names.idx then
        if out then out(0, 4) out(1, 1) end
        for _, v in ipairs(varint(names.idx - 1)) do out(v[1], v[2]) end
        return
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
    local maxlen = select(2, math.frexp(names.maxlen))
    --]]
    if out then out(maxlen, 4) end
    local bits = 4
    local c, n = lengths[1], 0
    local num, nonzero = 1, 0
    for _, v in ipairs(lengths) do
        if v ~= c or n == 85 then
            if n > 21 then if out then out(3, 2) out(n - 22, 6) end bits = bits + 8 + maxlen
            elseif n > 5 then if out then out(2, 2) out(n - 6, 4) end bits = bits + 6 + maxlen
            elseif n > 1 then if out then out(1, 2) out(n - 2, 2) end bits = bits + 4 + maxlen
            else if out then out(0, 2) end bits = bits + 2 + maxlen end
            if out then out(c, maxlen) end
            c, n = v, 0
            num = num + 1
            if c > 1 then nonzero = nonzero + 1 end
        end
        n = n + 1
    end
    --print(n, c)
    if n > 21 then if out then out(3, 2) out(n - 22, 6) end bits = bits + 8 + maxlen
    elseif n > 5 then if out then out(2, 2) out(n - 6, 4) end bits = bits + 6 + maxlen
    elseif n > 1 then if out then out(1, 2) out(n - 2, 2) end bits = bits + 4 + maxlen
    else if out then out(0, 2) end bits = bits + 2 + maxlen end
    if out then out(c, maxlen) end
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
        elseif names.map == false then return {idx = names.lengths, map = {[namelist[names.lengths][1]] = {code = 0, bits = 0, extra = 0}}} end
    end
    names.maxlen = 0
    for _, w in pairs(names.lengths) do names.maxlen = math.max(names.maxlen, w) end
    return names
end

local idmax = {[":block"] = 18, [":exp"] = 15, [":binop"] = 14}

local function compress(tokens, filename, level)
    local maxdist = level and (level == 0 and 0 or 2^(level+6))
    -- create identifier code tree
    local namecodefreq, namelist, nametable = {}, {}, {}
    for i, v in ipairs(tokens) do
        if v.type == "name" then
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
        end
    end
    local namecodelist = {}
    for i = 0, 29 do namecodelist[#namecodelist+1] = {i, namecodefreq[i] or 0} end
    local namecodetree = mktree(namecodefreq, namecodelist)
    -- parse data
    local p, repeats = parse(tokens, filename, namecodetree)
    print("bits", #p.bits)
    -- encode large identifiers as Huffman codes (:block, :exp, :binop)
    local idfreq = {[":block"] = {}, [":exp"] = {}, [":binop"] = {}}
    for _, v in ipairs(p.bits) do if v.type then idfreq[v.type][v[1]] = (idfreq[v.type][v[1]] or 0) + 1 end end
    local idtrees = {}
    for type, freq in pairs(idfreq) do
        local list = {}
        for i = 0, idmax[type] do list[#list+1] = {i, freq[i] or 0} end
        idtrees[type] = mktree(freq, list)
        for i, v in ipairs(p.bits) do
            if v.type == type then
                p.bits[i] = {idtrees[type].map[v[1]].code, idtrees[type].map[v[1]].bits, v[3]}
            end
            p.bits[i].seq = i
        end
    end
    -- create LZ77 code tree
    p.bits, repeats = lz77(p.bits, maxdist)
    local distfreq = {}
    for _, v in ipairs(repeats) do
        distfreq[v.offset.code] = (distfreq[v.offset.code] or 0) + 1
        distfreq[v.dist.code] = (distfreq[v.dist.code] or 0) + 1
        distfreq[v.len.code] = (distfreq[v.len.code] or 0) + 1
    end
    local distlist = {}
    for i = 0, 29 do distlist[i+1] = {i, distfreq[i] or 0} end
    local dist = {}
    dist.map, dist.lengths = maketree(distlist)
    if dist.map then
        dist.maxlen = 0
        for _, w in ipairs(dist.lengths) do dist.maxlen = math.max(dist.maxlen, w) end
    elseif dist.map == false then dist = {idx = dist.lengths} end
    -- write string-related data
    local out = bitstream()
    out.data = "\27LuzR" .. ("<I4"):pack(#p.stringtable)
    local identstr = table.concat(p.names, " ")
    out.data = out.data .. LibDeflate:CompressDeflate(p.stringtable .. identstr, {level = level})
    local stringsize = #out.data
    -- write trees for codes
    nametree(out, idtrees[":block"])
    nametree(out, idtrees[":exp"])
    nametree(out, idtrees[":binop"])
    nametree(out, namecodetree)
    nametree(out, dist)
    local treesize = #out.data - stringsize
    -- write repeats
    for _, v in ipairs(varint(#repeats)) do out(v[1], v[2]) end
    print(#repeats, #p.bits)
    local avglzbits, minlzbits, maxlzbits = 0, math.huge, 0
    for _, v in ipairs(repeats) do
        out(dist.map[v.offset.code].code, dist.map[v.offset.code].bits)
        out(v.offset.extra, v.offset.bits)
        out(dist.map[v.dist.code].code, dist.map[v.dist.code].bits)
        out(v.dist.extra, v.dist.bits)
        out(dist.map[v.len.code].code, dist.map[v.len.code].bits)
        out(v.len.extra, v.len.bits)
        local lzbits =
            dist.map[v.offset.code].bits + v.offset.bits +
            dist.map[v.len.code].bits + v.len.bits +
            dist.map[v.dist.code].bits + v.dist.bits
        avglzbits = avglzbits + lzbits
        minlzbits = math.min(minlzbits, lzbits)
        maxlzbits = math.max(maxlzbits, lzbits)
    end
    print("lzbits", avglzbits / #repeats, minlzbits, maxlzbits)
    local repeatsize = #out.data - treesize - stringsize
    -- write bitstream
    local file = fs.open("luz/test-bits.txt", "w")
    local ls, nr = 0, 1
    for _, v in ipairs(p.bits) do
        out(v[1], v[2])
        if v.seq ~= ls + 1 then
            file.writeLine(("--- LZ (%d, %d, %d) ---"):format(repeats[nr].offset.orig, repeats[nr].len.orig + 3, repeats[nr].dist.orig + 1))
            nr = nr + 1
            while repeats[nr] and repeats[nr].offset.orig == 0 do
                file.writeLine(("--- LZ (%d, %d, %d) ---"):format(repeats[nr].offset.orig, repeats[nr].len.orig + 3, repeats[nr].dist.orig + 1))
                nr = nr + 1
            end
        end
        ls = v.seq
        file.writeLine(v[1] .. "\t" .. v[2] .. "\t" .. (v[3] or ""))
        file.flush()
    end
    file.close()
    out()
    print(stringsize, treesize, repeatsize, #out.data - repeatsize - treesize - stringsize)
    return out.data
end

return compress