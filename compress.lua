local LibDeflate = require "LibDeflate"
local maketree = require "maketree"
local marknames = require "marknames"
local reduce = require "reduce"
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
        return varint(out, m)
    end
end

local function nametree(out, data, isLocal)
    --print(data and #data.len)
    if not data then
        out(0, 5)
        return 5
    end
    local num
    if isLocal then
        if #data.len > 15 then out(#data.len + 256, 9) num = 9
        else out(#data.len, 5) num = 5 end
    else
        num = varint(out, #data.len)
    end
    for _, v in ipairs(data.list) do
        for c in v[1]:gmatch "." do out(b64lut[c], 6) end
        out(63, 6)
        num = num + #v * 6 + 6
    end
    out(data.maxlen, 4)
    for _, v in ipairs(data.len) do out(v, data.maxlen) end
    return num + #data.len * data.maxlen + 4
end

local function compress(tokens)
    local names = marknames(tokens)
    tokens = reduce(tokens)
    local stringtable = ""
    -- generate string table
    for _, v in ipairs(tokens) do
        if v.type == "string" and not token_encode_map[v.text] then
            v.str = load("return " .. v.text, "=string", "t", {})()
            stringtable = stringtable .. v.str
        end
    end
    -- write string-related data
    local out = bitstream()
    out.data = "\27LuzQ" .. LibDeflate:CompressDeflate(stringtable)
    local stlen = #out.data - 5
    --print(#namelist)
    nametree(out, names.globals, false)
    local globallistlen = #out.data - stlen - 5
    nametree(out, names.fields, false)
    local fieldlistlen = #out.data - globallistlen - stlen - 5
    nametree(out, names.locals, true)
    local locallistlen = #out.data - fieldlistlen - globallistlen - stlen - 5
    local namebits, strbits, funcbits = 0, 0, 0
    -- write tokens
    local upvalues = {}
    local localstate = {level = 1, locals = names.locals}
    for _, v in ipairs(tokens) do
        --print(v.type, v.text)
        if v.type == "keyword" or v.type == "combined" then
            out(token_encode_map[v.text].code, token_encode_map[v.text].bits)
            if v.text:find "then" or v.text:find "do" then
                localstate.level = localstate.level + 1
                --print(localstate.level)
            elseif v.text:find "end" or v.text:find "elseif" then
                if v.text == "end end" then localstate.level = localstate.level - 2
                else localstate.level = localstate.level - 1 end
                --print(localstate.level)
                while localstate.level <= 0 do
                    local diff = localstate.level
                    localstate = table.remove(upvalues, 1)
                    localstate.level = localstate.level + diff
                    --print("exit", #upvalues)
                end
            elseif v.text:find "function" then
                --print("enter", #upvalues)
                funcbits = funcbits + nametree(out, v.locals, true)
                table.insert(upvalues, 1, localstate)
                localstate = {level = 1, locals = v.locals}
            end
        elseif token_encode_map[v.text] then
            out(token_encode_map[v.text].code, token_encode_map[v.text].bits)
        elseif v.type == "global" then
            out(token_encode_map[":global"].code, token_encode_map[":global"].bits)
            out(names.globals.map[v.text].code, names.globals.map[v.text].bits)
            namebits = namebits + names.globals.map[v.text].bits
        elseif v.type == "field" then
            out(token_encode_map[":field"].code, token_encode_map[":field"].bits)
            out(names.fields.map[v.text].code, names.fields.map[v.text].bits)
            namebits = namebits + names.fields.map[v.text].bits
        elseif v.type == "local" then
            out(token_encode_map[":local"].code, token_encode_map[":local"].bits)
            --print(v.text, localstate.locals)
            out(localstate.locals.map[v.text].code, localstate.locals.map[v.text].bits)
            namebits = namebits + localstate.locals.map[v.text].bits
        elseif v.type:match "^upvalue" then
            out(token_encode_map[":" .. v.type].code, token_encode_map[":" .. v.type].bits)
            local map
            local num = v.type:match "^upvalue(%d+)"
            if not num then
                num = v.level
                if num >= 20 then error("too many levels of upvalues") end
                out(num - 4, 4)
            end
            --print(num, upvalues[num])
            map = upvalues[tonumber(num)].locals.map
            out(map[v.text].code, map[v.text].bits)
            namebits = namebits + map[v.text].bits
        elseif v.type == "string" then
            out(token_encode_map[":string"].code, token_encode_map[":string"].bits)
            if #v.str < 8 then
                out(#v.str, 4)
                strbits = strbits + 5
            else
                out(1, 1)
                strbits = strbits + varint(out, #v.str) + 1
            end
        elseif v.type == "number" then
            out(token_encode_map[":number"].code, token_encode_map[":number"].bits)
            number(out, tonumber(v.text))
        elseif v.type == "append" then
            out(token_encode_map[":append"].code, token_encode_map[":append"].bits)
            out(v.len, 4)
        else error("Could not find encoding for token " .. v.type .. "(" .. v.text .. ")!") end
    end
    out(token_encode_map[":end"].code, token_encode_map[":end"].bits)
    out()
    print(#tokens, #stringtable, stlen, globallistlen, fieldlistlen, locallistlen, #out.data - locallistlen - fieldlistlen - globallistlen - stlen - 5, namebits / 8, strbits / 8, funcbits / 8)
    return out.data
end

return compress