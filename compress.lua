local lz77 = require "lz77"
local all_frequencies = require "all_frequencies"
local blockcompress = require "blockcompress"
local ansencode = require "ansencode"

local tokenlut = {}
for i, v in ipairs(all_frequencies) do tokenlut[v[1]] = i end

local function round(n) return math.floor(n + 0.5) end

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
    if num < 2^53 and num > -(2^53) and num % 1 == 0 then
        out(num < 0 and 1 or 0, 2)
        return varint(out, math.abs(num))
    else
        local m, e = math.frexp(num)
        if m == math.huge then m, e = 0.5, 0x7FF
        elseif m == -math.huge then m, e = -0.5, 0x7FF
        elseif m ~= m then m, e = 0.5 + 1/0x20000000000000, 0x7FF end
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

local function compress(tokens, level)
    local maxdist = level and (level == 0 and 0 or 2^(level+6))
    -- create master table
    local newtok = {}
    for _, v in ipairs(tokens) do
        v.text = v.text:gsub("^'", '"'):gsub("'$", '"')
        if tokenlut[v.text] or v.type == "keyword" or v.type == "operator" or v.type == "constant" then
            newtok[#newtok+1] = v.text
        else
            newtok[#newtok+1] = ":" .. v.type
            if v.type == "name" then
                for c in v.text:gmatch "[A-Za-z0-9_]" do newtok[#newtok+1] = c:byte() end
            elseif v.type == "number" then
                local numstream = bitstream()
                number(numstream, tonumber(v.text))
                numstream()
                for c in numstream.data:gmatch "." do newtok[#newtok+1] = c:byte() end
            elseif v.type == "string" then
                local data = v.text:gsub('^"', ""):gsub('"$', ""):gsub("^%[=*%[", ""):gsub("%]=*%]", "")
                for c in data:gmatch "." do newtok[#newtok+1] = c:byte() end
            end
        end
    end
    -- run LZ77 on the table
    local symbols = lz77(newtok, maxdist)
    local out = bitstream()
    out.data = "\x1bLuzA"
    -- compress block
    blockcompress(symbols, 9, all_frequencies, tokenlut, out)
    out(1, 1)
    out()
    return out.data
end

return compress