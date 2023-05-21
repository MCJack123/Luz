local LibDeflate = require "LibDeflate"
local maketree = require "maketree"
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
        local nibbles = {}
        while e > 7 do nibbles[#nibbles+1], e = e % 8, math.floor(e / 8) end
        nibbles[#nibbles+1] = e % 8
        for i = #nibbles, 1, -1 do out(nibbles[i] + (i == 1 and 0 or 8), 4) end
        return varint(out, m)
    end
end

local function compress(tokens)
    local namefreq, stringtable = {}, ""
    -- generate identifier tree and string table
    for _, v in ipairs(tokens) do
        if v.type == "name" and not token_encode_map[v.text] then
            namefreq[v.text] = (namefreq[v.text] or 0) + 1
        elseif v.type == "string" and not token_encode_map[v.text] then
            v.str = load("return " .. v.text, "=string", "t", {})()
            stringtable = stringtable .. v.str
        end
    end
    local namelist = {}
    for k, v in pairs(namefreq) do namelist[#namelist+1] = {k, v} end
    local namemap, namelengths, nametree = maketree(namelist)
    local maxnamelen = 0
    for _, v in ipairs(namelengths) do maxnamelen = math.max(maxnamelen, v) end
    -- write string-related data
    local out = bitstream()
    out.data = "\27LuzQ" .. LibDeflate:CompressDeflate(stringtable)
    print(#namelist)
    varint(out, #namelist)
    for _, v in ipairs(namelist) do
        for c in v[1]:gmatch "." do out(b64lut[c], 6) end
        out(63, 6)
    end
    maxnamelen = select(2, math.frexp(maxnamelen))
    out(maxnamelen, 4)
    for _, v in ipairs(namelengths) do out(v, maxnamelen) end
    -- write tokens
    for _, v in ipairs(tokens) do
        if token_encode_map[v.text] then
            out(token_encode_map[v.text].code, token_encode_map[v.text].bits)
        elseif v.type == "name" then
            out(token_encode_map[":name"].code, token_encode_map[":name"].bits)
            out(namemap[v.text].code, namemap[v.text].bits)
        elseif v.type == "string" then
            out(token_encode_map[":string"].code, token_encode_map[":string"].bits)
            varint(out, #v.str)
        elseif v.type == "number" then
            out(token_encode_map[":number"].code, token_encode_map[":number"].bits)
            number(out, tonumber(v.text))
        else error("Could not find encoding for token " .. v.type .. "(" .. v.text .. ")!") end
    end
    out(token_encode_map[":end"].code, token_encode_map[":end"].bits)
    out()
    return out.data
end

return compress