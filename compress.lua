local LibDeflate = require "LibDeflate"
local parse = require "parse"

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
        e = math.abs(e)
        local nibbles = {}
        while e > 7 do nibbles[#nibbles+1], e = e % 8, math.floor(e / 8) end
        nibbles[#nibbles+1] = e % 8
        for i = #nibbles, 1, -1 do out(nibbles[i] + (i == 1 and 0 or 8), 4) end
        return varint(out, m)
    end
end

local function compress(tokens, filename)
    -- parse data
    local p = parse(tokens, filename)
    --require "syntree"(p)
    -- write string-related data
    local out = bitstream()
    out.data = "\27LuzR" .. LibDeflate:CompressDeflate(p.stringtable)
    varint(out, #p.names)
    for _, v in ipairs(p.names) do
        for c in v:gmatch "." do out(b64lut[c], 6) end
        out(63, 6)
    end
    -- write bitstream
    local file = fs.open("luz/test-bits.txt", "w")
    for _, v in ipairs(p.bits) do out(v[1], v[2]) file.writeLine(v[1] .. "\t" .. v[2]) end
    file.close()
    out()
    return out.data
end

return compress