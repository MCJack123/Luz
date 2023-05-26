local LibDeflate = require "LibDeflate"
local token_decode_tree = require "token_decode_tree"

local rshift, lshift, band = bit32.rshift, bit32.lshift, bit32.band
local byte, char = string.byte, string.char
local concat, unpack = table.concat, unpack or table.unpack
local min = math.min

local b64str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
local b64lut = {}
for i = 1, #b64str do b64lut[string.char(i-1)] = b64str:sub(i, i) end

local function peekBitsR(stream, int)
    local buffer, bits, count, position = stream.buffer, stream.bits, stream.count, stream.position
    while count < int do
        if position > #buffer then return nil end
        bits = lshift(bits, 8) + byte(buffer, position)
        position = position + 1
        count = count + 8
    end
    stream.bits = bits
    stream.position = position
    stream.count = count
    return band(rshift(bits, count - int), lshift(1, int) - 1)
end

local function getBitsR(stream, int)
    local result = peekBitsR(stream, int)
    --stream.bits = rshift(stream.bits, int)
    stream.count = stream.count - int
    return result
end

local function varint(stream)
    local num = 0
    repeat
        local n = getBitsR(stream, 8)
        num = num * 128 + n % 128
    until n < 128
    return num
end

local function number(stream)
    local type = getBitsR(stream, 2)
    if type >= 2 then
        local esign = getBitsR(stream, 1)
        local e = 0
        repeat
            local n = getBitsR(stream, 4)
            e = lshift(e, 3) + band(n, 7)
        until n < 8
        if esign == 1 then e = -e end
        local m = varint(stream) / 0x20000000000000 + 0.5
        return math.ldexp(m, e) * (type == 2 and 1 or -1)
    else
        return varint(stream) * (type == 0 and 1 or -1)
    end
end

local rlemap = {2, 6, 22, 86, 342, 1366, 5462}

local function readrle(stream, len)
    local bits = getBitsR(stream, 3)
    if bits == 0 then return 1, getBitsR(stream, len) end
    local rep = getBitsR(stream, bits * 2) + rlemap[bits]
    return rep, getBitsR(stream, len)
end

local function nametree(stream, list)
    -- read identifier code lengths
    local maxlen = getBitsR(stream, 4)
    if maxlen == 0 then
        if getBitsR(stream, 1) == 0 then return nil
        else return varint(stream) end
    end
    local bitlen = {}
    local n, c = 0
    for i = 1, #list do
        if n == 0 then
            n, c = readrle(stream, maxlen)
            --print(n, c)
        end
        if c > 0 then bitlen[#bitlen+1] = {s = list[i], l = c} end
        n = n - 1
    end
    assert(n == 0, n)
    table.sort(bitlen, function(a, b) if a.l == b.l then return a.s < b.s else return a.l < b.l end end)
    bitlen[1].c = 0
    for j = 2, #bitlen do bitlen[j].c = bit32.lshift(bitlen[j-1].c + 1, bitlen[j].l - bitlen[j-1].l) end
    -- create tree from codes
    local codetree = {}
    for j = 1, #bitlen do
        local c = bitlen[j].c
        if bitlen[j].s == "PHOENIX_VERSION" then print(("%x"):format(c), bitlen[j].l, bitlen[j].s) end
        local node = codetree
        for k = bitlen[j].l - 1, 1, -1 do
            local n = bit32.extract(c, k, 1)
            if not node[n+1] then node[n+1] = {} end
            node = node[n+1]
        end
        local n = bit32.extract(c, 0, 1)
        node[n+1] = bitlen[j].s
    end
    return codetree
end

local function binstr(num, bits)
    local str = ""
    for i = bits, 0, -1 do str = str .. (bit32.btest(num, 2^i) and "1" or "0") end
    return str
end

local path = ...
if not path then error("Usage: inspect <file.luz>") end
local file = assert(fs.open(shell.resolve(path), "rb"))
assert(file.read(5) == "\27LuzQ", "invalid file format")
local data = file.readAll()
file.close()
file = assert(fs.open(shell.resolve(path .. ".txt"), "w"))
local origlen = #data + 5
local stringtable, rest1 = LibDeflate:DecompressDeflate(data)
local stringpos = 1
file.writeLine("[String table]")
file.writeLine(("%q"):format(stringtable):gsub("[%z\1-\31\127-\255]", function(c) return ("\\x%02X"):format(c:byte()) end))
file.flush()
data = data:sub(-rest1-0)
local identliststr, rest2 = LibDeflate:DecompressDeflate(data)
local off = origlen - rest2
local identlist = {}
file.writeLine("[Identifier list]")
for ident in identliststr:gmatch "([%z\1-\62]+)\63" do identlist[#identlist+1] = ident:gsub(".", b64lut) file.writeLine(identlist[#identlist]) end
file.flush()
data = data:sub(-rest2-0)
local self = {buffer = data, position = 1, bits = 0, count = 0}
local disttree = nametree(self, {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29})
local codetree = nametree(self, identlist)
file.writeLine("[Tokens]")
print(self.position + off)
while true do
    local node = token_decode_tree
    local code, n = 0, 0
    while type(node) == "table" do
        local b = getBitsR(self, 1)
        node = node[b+1]
        code, n = code * 2 + b, n + 1
    end
    file.write("(" .. binstr(code, n) .. ") ")
    if node == ":end" then break
    elseif node == ":name" then
        node = codetree
        code, n = 0, 0
        while type(node) == "table" do
            local b = getBitsR(self, 1)
            node = node[b+1]
            code, n = code * 2 + b, n + 1
        end
        file.writeLine(":name (" .. binstr(code, n) .. ") " .. node)
    elseif node == ":string" then
        local len = varint(self)
        file.writeLine(":string " .. ("%q"):format(stringtable:sub(stringpos, stringpos + len - 1)):gsub("\\?\n", "\\n"):gsub("\t", "\\t"):gsub("[%z\1-\31\127-\255]", function(n) return ("\\%03d"):format(n:byte()) end))
        stringpos = stringpos + len
    elseif node == ":number" then
        file.writeLine(":number " .. tostring(number(self)))
    elseif node:find "^:repeat" then
        local lencode = tonumber(node:match "^:repeat(%d+)")
        local ebits = math.max(math.floor(lencode / 2) - 1, 0)
        if ebits > 0 then
            local extra = getBitsR(self, ebits)
            lencode = bit32.bor(extra, bit32.lshift(bit32.band(lencode, 1) + 2, ebits)) + 3
        else lencode = lencode + 3 end
        node = disttree
        while type(node) == "table" do node = node[getBitsR(self, 1)+1] end
        local distcode
        ebits = math.max(math.floor(node / 2) - 1, 0)
        if ebits > 0 then
            local extra = getBitsR(self, ebits)
            distcode = bit32.bor(extra, bit32.lshift(bit32.band(node, 1) + 2, ebits)) + 1
        else distcode = node + 1 end
        file.writeLine(":repeat len=" .. lencode .. " dist=" .. distcode)
    else file.writeLine(node) end
end
file.close()
print("Success")
