local lz77 = require "lz77"
local token_frequencies = require "token_frequencies"
local name_frequencies = require "name_frequencies"
local string_frequencies = require "string_frequencies"
local number_frequencies = require "number_frequencies"
local blockcompress = require "blockcompress"
local ansencode = require "ansencode"

local b64str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_\0"
local b64lut = {}
for i, c in b64str:gmatch "()(.)" do b64lut[c] = i-1 end
for i = 0, 7 do b64lut[":repeat" .. i] = i + 64 end

local strlut = setmetatable({[":end"] = 256}, {__index = function(_, c) return c:byte() end})
for i = 0, 15 do strlut[":repeat" .. i] = i + 257 end

local tokenlut = {}
for i, v in ipairs(token_frequencies) do tokenlut[v[1]] = i end

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

local function compress(tokens, level)
    local maxdist = level and (level == 0 and 0 or 2^(level+6))
    -- create input string and identifier tables
    local strtab, identtab, identlut, identcodes, numberlist = {}, {}, {}, {}, {}
    local canUseStaticString, maxident = true, 0
    for _, v in ipairs(tokens) do
        if v.type == "string" and not tokenlut[v.text] then
            local data = v.text:gsub('^[\'"]', ""):gsub('[\'"]$', ""):gsub("^%[=*%[", ""):gsub("%]=*%]", "")
            if data:match "[^\32-\126]" then canUseStaticString = false end
            for c in data:gmatch "." do strtab[#strtab+1] = c end
            strtab[#strtab+1] = ":end"
        elseif v.type == "name" and not tokenlut[v.text] then
            if not identlut[v.text] then
                for c in v.text:gmatch "[0-9A-Za-z_]" do identtab[#identtab+1] = c end
                identtab[#identtab+1] = "\0"
                identlut[v.text] = maxident
                maxident = maxident + 1
            end
            identcodes[#identcodes+1] = identlut[v.text]
        elseif v.type == "number" and not tokenlut[v.text] then
            numberlist[#numberlist+1] = tonumber(v.text)
        end
    end
    maxident = maxident - 1
    --print("maxident", maxident)
    local numberdata = ("d"):rep(#numberlist):pack(table.unpack(numberlist))
    local numtab = {}
    for i, c in numberdata:gmatch "()(.)" do numtab[i] = c end
    -- run LZ77 on all tables
    strtab = lz77(strtab, maxdist)
    identtab = lz77(identtab, maxdist)
    identcodes = lz77(identcodes, maxdist)
    numtab = lz77(numtab, maxdist)
    tokens = lz77(tokens, maxdist)
    -- create token symbols
    local symbols = {}
    for i, v in ipairs(tokens) do
        if v.type:match "^repeat" then symbols[i] = {v.dist, v.len}
        elseif tokenlut[v.text] and not v.type:match "^repeat" then symbols[i] = v.text
        else symbols[i] = ":" .. v.type end
    end
    local identcodemap = setmetatable({}, {__index = function(_, v) return v end})
    for i = 0, 19 do identcodemap[":repeat" .. i] = maxident + i + 1 end
    local out = bitstream()
    out.data = "\x1bLuzA"
    -- compress blocks
    print("-- String table --")
    blockcompress(strtab, 9, canUseStaticString and string_frequencies or nil, strlut, out)
    local strtabsize = #out.data - 5
    print("-- Identifier table --")
    blockcompress(identtab, 7, name_frequencies, b64lut, out)
    local identtabsize = #out.data - strtabsize - 5
    local identnbits = math.floor(math.log(maxident + 20, 2)) + 1
    out(1, 1)
    out(identnbits, 6)
    out(maxident, identnbits)
    local identfreq = {}
    for i = 0, maxident do identfreq[#identfreq+1] = {i, 1} end
    for i = 0, 10 do identfreq[#identfreq+1] = {":repeat" .. i, 2} end
    for i = 11, 29 do identfreq[#identfreq+1] = {":repeat" .. i, 1} end
    print("-- Identifier codes --")
    blockcompress(identcodes, identnbits, ansencode.makeLs(identfreq), identcodemap, out)
    local identcodesize = #out.data - identtabsize - strtabsize - 5
    print("-- Number list --")
    blockcompress(numtab, 9, number_frequencies, strlut, out)
    local numtabsize = #out.data - identcodesize - identtabsize - strtabsize - 5
    print("-- Tokens --")
    blockcompress(symbols, 7, token_frequencies, tokenlut, out)
    out(1, 1)
    out()
    local tokenlistsize = #out.data - numtabsize - identcodesize - identtabsize - strtabsize - 5
    print(strtabsize, identtabsize, identcodesize, numtabsize, tokenlistsize)
    return out.data
end

return compress