local lex = require "lex"
local lz77 = require "lz77"
local maketree = require "maketree"
local freq = {
    ["\"\""] = 0,
    ["\"string\""] = 0,
    ["\"number\""] = 0,
    ["\"boolean\""] = 0,
    ["\"nil\""] = 0,
    ["\"function\""] = 0,
    ["\"table\""] = 0,
    ["\"r\""] = 0,
    ["\"w\""] = 0,
    ["_G"] = 0,
    ["_ENV"] = 0,
    ["_"] = 0,
    ["error"] = 0,
    ["getmetatable"] = 0,
    ["ipairs"] = 0,
    ["load"] = 0,
    ["pairs"] = 0,
    ["pcall"] = 0,
    ["print"] = 0,
    ["select"] = 0,
    ["setmetatable"] = 0,
    ["tonumber"] = 0,
    ["tostring"] = 0,
    ["type"] = 0,
    ["unpack"] = 0,
    ["coroutine"] = 0,
    ["require"] = 0,
    ["package"] = 0,
    ["string"] = 0,
    ["table"] = 0,
    ["math"] = 0,
    ["bit32"] = 0,
    ["io"] = 0,
    ["os"] = 0,
    ["debug"] = 0,
    ["self"] = 0,
    ["__index"] = 0,
    ["__newindex"] = 0,
    ["__call"] = 0,
    ["open"] = 0,
    ["read"] = 0,
    ["write"] = 0,
    ["close"] = 0,
    ["find"] = 0,
    ["gsub"] = 0,
    ["match"] = 0,
    ["sub"] = 0,
    ["0"] = 0,
    ["1"] = 0,
    ["2"] = 0,
    ["-1"] = 0,
    [":end"] = 1,
}
local namefreq, strfreq, numfreq = {}, {}, {}
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
local function scan(dir)
    for _, p in ipairs(fs.list(dir)) do
        local path = fs.combine(dir, p)
        if fs.isDir(path) and not path:find "luz" then scan(path)
        elseif path:match "%.lua$" then
            local file = assert(fs.open(path, "r"))
            local data = file.readAll()
            file.close()
            if load(data) then
                local ok, res = pcall(lex, data, 1, 2)
                if ok then
                    print(path, #res)
                    local strtab = {}
                    for _, v in ipairs(res) do
                        if v.type == "string" then
                            local data = v.text:gsub('^"', ""):gsub('"$', ""):gsub("^%[=*%[", ""):gsub("%]=*%]", "")
                            for c in data:gmatch "[\32-\126]" do strtab[#strtab+1] = c end
                            strtab[#strtab+1] = ":end"
                        end
                    end
                    strtab = lz77(strtab)
                    for _, c in ipairs(strtab) do
                        if type(c) == "table" then c = ":repeat" .. c[2].code end
                        strfreq[c] = (strfreq[c] or 0) + 1
                    end
                    res = lz77(res)
                    print(path, #res)
                    local numstream = bitstream()
                    for _, v in ipairs(res) do
                        v.text = v.text:gsub("^'", '"'):gsub("'$", '"')
                        if freq[v.text] or v.type == "keyword" or v.type == "operator" or v.type == "constant" then
                            freq[v.text] = (freq[v.text] or 0) + 1
                        else
                            freq[":" .. v.type] = (freq[":" .. v.type] or 0) + 1
                        end
                        if v.type == "name" then
                            for c in v.text:gmatch "[A-Za-z0-9_]" do namefreq[c] = (namefreq[c] or 0) + 1 end
                            namefreq["\0"] = (namefreq["\0"] or 0) + 1
                        elseif v.type == "number" then
                            number(numstream, tonumber(v.text))
                        end
                    end
                    numstream()
                    for c in numstream.data:gmatch "." do numfreq[c] = (numfreq[c] or 0) + 1 end
                end
            end
        end
    end
end
local b64str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_\0"
local b64lut = {}
for i, c in b64str:gmatch "()(.)" do b64lut[c] = i-1 end
for i = 0, 11 do b64lut[":repeat" .. i] = i + 64 end

local strlut = setmetatable({[":end"] = 256}, {__index = function(_, c) return c:byte() end})
for i = 0, 15 do strlut[":repeat" .. i] = i + 257 end
local function makeLs(freq, lut)
    local nL = 16
    local Ls
    repeat
        nL = nL * 2
        local L, total = 0, 0
        for _, v in pairs(freq) do L = L + nL total = total + v end
        local R = math.max(math.floor(math.floor(math.log(L, 2)) + 1), 1)
        L = 2^R
        Ls = {R = R}
        local freqsum, sumLs = 0, 0
        local fail = false
        for s, v in pairs(freq) do
            freqsum = freqsum + v / total
            Ls[#Ls+1] = {s, math.floor(freqsum * L + 0.5) - sumLs}
            if Ls[#Ls][2] == 0 then fail = true end
            --print(s, Ls[s])
            sumLs = sumLs + Ls[#Ls][2]
        end
    until not fail
    table.sort(Ls, function(a, b) return lut[a[1]] < lut[b[1]] end)
    return Ls
end
scan("/")
local out = {}
for k, v in pairs(freq) do out[#out+1] = {k, v} end
table.sort(out, function(a, b) return a[2] > b[2] end)
local file = fs.open(shell.resolve("hist.json"), "w")
file.write(textutils.serializeJSON(out))
file.close()
local list = {}
for i, v in ipairs(out) do list[i] = v[1] end
file = fs.open(shell.resolve("hist.txt"), "w")
file.write(textutils.serialize(list))
file.close()
local Ls = makeLs(freq, setmetatable({}, {__index = function(_, v) return v end}))
file = fs.open(shell.resolve("token_frequencies.lua"), "w")
file.write(("-- AUTOGENERATED\nreturn %s"):format(textutils.serialize(Ls, {compact = true})))
file.close()

local nameout = {}
for k, v in pairs(namefreq) do nameout[#nameout+1] = {k, v} end
table.sort(nameout, function(a, b) return a[2] > b[2] end)
namefreq[":repeat0"] = math.floor(nameout[1][2] / 4)
namefreq[":repeat1"] = math.floor(nameout[1][2] / 8)
namefreq[":repeat2"] = math.floor(nameout[1][2] / 16)
namefreq[":repeat3"] = math.floor(nameout[1][2] / 32)
namefreq[":repeat4"] = math.floor(nameout[1][2] / 64)
namefreq[":repeat5"] = math.floor(nameout[1][2] / 128)
namefreq[":repeat6"] = math.floor(nameout[1][2] / 256)
namefreq[":repeat7"] = math.floor(nameout[1][2] / 512)
namefreq[":repeat8"] = math.floor(nameout[1][2] / 1024)
namefreq[":repeat9"] = math.floor(nameout[1][2] / 2048)
namefreq[":repeat10"] = math.floor(nameout[1][2] / 4096)
namefreq[":repeat11"] = math.floor(nameout[1][2] / 8192)
Ls = makeLs(namefreq, b64lut)
file = fs.open(shell.resolve("name_frequencies.lua"), "w")
file.write(("-- AUTOGENERATED\nreturn %s"):format(textutils.serialize(Ls, {compact = true})))
file.close()

Ls = makeLs(strfreq, strlut)
file = fs.open(shell.resolve("string_frequencies.lua"), "w")
file.write(("-- AUTOGENERATED\nreturn %s"):format(textutils.serialize(Ls, {compact = true})))
file.close()

nameout = {}
for k, v in pairs(numfreq) do nameout[#nameout+1] = {k, v} end
table.sort(nameout, function(a, b) return a[2] > b[2] end)
for i = 0, 15 do numfreq[":repeat" .. i] = math.floor(nameout[1][2] / (2^(i/2+4))) end
Ls = makeLs(numfreq, strlut)
file = fs.open(shell.resolve("number_frequencies.lua"), "w")
file.write(("-- AUTOGENERATED\nreturn %s"):format(textutils.serialize(Ls, {compact = true}):gsub("\\\n", "\\n"):gsub("[\128-\255]", function(c) return "\\" .. tonumber(c:byte()) end)))
file.close()
