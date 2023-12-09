local token_decode_tree = require "token_decode_tree"

local rshift, lshift, band = bit32.rshift, bit32.lshift, bit32.band
local byte, char = string.byte, string.char
local concat, unpack = table.concat, unpack or table.unpack
local min = math.min

local ORDER = {17, 18, 19, 1, 9, 8, 10, 7, 11, 6, 12, 5, 13, 4, 14, 3, 15, 2, 16}
local NBT = {2, 3, 7}
local CNT  = {144, 112, 24, 8}
local DPT = {8, 9, 7, 8}
local STATIC_HUFFMAN = {[0] = 5, 261, 133, 389, 69, 325, 197, 453, 37, 293, 165, 421, 101, 357, 229, 485, 21, 277, 149, 405, 85, 341, 213, 469, 53, 309, 181, 437, 117, 373, 245, 501}
local STATIC_BITS = 5
local b64str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"

-- bitstream

local function flushBits(stream, int)
    stream.bits = rshift(stream.bits, int)
    stream.count = stream.count - int
end

local function peekBits(stream, int)
    local buffer, bits, count, position = stream.buffer, stream.bits, stream.count, stream.position
    while count < int do
        if position > #buffer then return nil end
        bits = bits + lshift(byte(buffer, position), count)
        position = position + 1
        count = count + 8
    end
    stream.bits = bits
    stream.position = position
    stream.count = count
    return band(bits, lshift(1, int) - 1)
end

local function getBits(stream, int)
    local result = peekBits(stream, int)
    stream.bits = rshift(stream.bits, int)
    stream.count = stream.count - int
    return result
end

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

-- syntax trees

local function varint(read)
    local num = 0
    repeat
        local n = read(8)
        num = num * 128 + n % 128
    until n < 128
    return num
end

local function number(read)
    local type = read(2)
    if type >= 2 then
        local esign = read(1)
        local e = 0
        repeat
            local n = read(4)
            e = bit32.lshift(e, 3) + bit32.band(n, 7)
        until n < 8
        if esign == 1 then e = -e end
        local m = varint(read) / 0x20000000000000 + 0.5
        return math.ldexp(m, e) * (type == 2 and 1 or -1)
    else
        return varint(read) * (type == 0 and 1 or -1)
    end
end

local trees
local function union(...)
    local args = {...}
    local bits = math.ceil(math.log(#args, 2))
    return function(state, read, push) return args[read(bits)+1](state, read, push) end
end
local function arr(...)
    local args = {...}
    local bits = math.ceil(math.log(#args, 2))
    return function(state, read, push) repeat local ok = args[read(bits)+1](state, read, push) until ok end
end
local function terminate(fn) return function(...) if fn then fn(...) end return true end end
local function lit(name) return function(state, read, push) push(name) end end
local function ref(name) return function(...) return trees[name](...) end end
local function seq(...)
    local args = {...}
    return function(state, read, push) for _, fn in ipairs(args) do fn(state, read, push) end end
end
local function Name(state, read, push)
    local id
    if read(1) == 1 then id = read(12) + 64 else id = read(6) end
    if id == 0 then
        local name = state.names[state.namepos]
        state.namepos = state.namepos + 1
        table.insert(state.namelist, 1, name)
        push(name)
    else
        push(state.namelist[id])
        table.insert(state.namelist, 1, table.remove(state.namelist, id))
    end
end
local function String(state, read, push)
    local len = read(8)
    push(("%q"):format(state.stringtable:sub(state.stringpos, state.stringpos + len - 1)))
    state.stringpos = state.stringpos + len
end
local function Number(state, read, push)
    push(("%d"):format(number(read)))
end

local binops = {[0] = "+", "-", "*", "/", "^", "%", "..", "<", "<=", ">", ">=", "==", "~=", "and", "or"}
trees = {
    [":block"] = arr(
        seq(ref ":var", arr(seq(lit ",", ref ":var"), terminate(lit "=")), ref ":exp", arr(seq(lit ",", ref ":exp"), terminate())), -- assign
        ref ":call",
        seq(lit "::", Name, lit "::"), -- label
        lit "break",
        seq(lit "goto", Name), -- goto
        seq(lit "do", ref ":block", lit "end"), -- do/end
        seq(lit "while", ref ":exp", lit "do", ref ":block", lit "end"), -- while
        seq(lit "repeat", ref ":block", lit "until", ref ":exp"), -- repeat
        seq(lit "if", ref ":exp", lit "then", ref ":block", arr(seq(lit "elseif", ref ":exp", lit "then", ref ":block"), terminate(seq(lit "else", ref ":block", lit "end")), terminate(lit "end"))), -- if
        seq(lit "for", Name, lit "=", ref ":exp", lit ",", ref ":exp", union(seq(lit ",", ref ":exp", lit "do"), seq(lit "do")), ref ":block", lit "end"), -- for range
        seq(lit "for", Name, arr(seq(lit ",", Name), terminate(lit "in")), ref ":exp", arr(seq(lit ",", ref ":exp"), terminate(lit "do")), ref ":block", lit "end"), -- for iter
        seq(lit "function", Name, arr(seq(lit ".", Name), terminate(seq(lit ":", Name, ref ":funcbody")), terminate(ref ":funcbody"))), -- function statement
        seq(lit "local", lit "function", Name, ref ":funcbody"), -- local function
        seq(lit "local", Name, arr(seq(lit ",", Name), terminate()), union(seq(lit "=", ref ":exp", arr(seq(lit ",", ref ":exp"), terminate())), lit "")), -- local definition
        union(seq(lit "return", ref ":exp", arr(seq(lit ",", ref ":exp"), terminate())), lit "return"),
        terminate()
    ),
    [":call"] = union(seq(ref ":prefixexp", ref ":args"), seq(ref ":prefixexp", lit ":", Name, ref ":args")),
    [":var"] = union(Name, seq(ref ":prefixexp", lit "[", ref ":exp", lit "]"), seq(ref ":prefixexp", lit ".", Name)),
    [":prefixexp"] = union(ref ":var", ref ":call", seq(lit "(", ref ":exp", lit ")")),
    [":args"] = union(seq(lit "(", union(seq(ref ":exp", arr(seq(lit ",", ref ":exp"), terminate(lit ")"))), lit ")")), ref ":table", String),
    [":funcbody"] = seq(lit "(", union(lit ")", seq(lit "...", lit ")"), seq(Name, arr(seq(lit ",", Name), terminate()), union(seq(lit ",", lit "...", lit ")"), lit ")"))), ref ":block", lit "end"),
    [":exp"] = union(lit "nil", lit "false", lit "true", Number, String, lit "...", seq(lit "function", ref ":funcbody"), ref ":prefixexp", ref ":table", seq(ref ":exp", ref ":binop", ref ":exp"), seq(ref ":unop", ref ":exp")),
    [":binop"] = function(state, read, push) push(binops[read(4)]) end,
    [":unop"] = union(lit "-", lit "not", lit "#"),
    [":table"] = seq(lit "{", arr(seq(union(seq(lit "[", ref ":exp", lit "]", lit "=", ref ":exp"), seq(Name, lit "=", ref ":exp"), ref ":exp"), lit ","), terminate(seq(union(seq(lit "[", ref ":exp", lit "]", lit "=", ref ":exp"), seq(Name, lit "=", ref ":exp"), ref ":exp"), lit "}")), terminate(lit "}")))
}

-- deflate

local function getElement(stream, hufftable, int)
    local element = hufftable[peekBits(stream, int)]
    if not element then return nil end
    local length = band(element, 15)
    local result = rshift(element, 4)
    stream.bits = rshift(stream.bits, length)
    stream.count = stream.count - length
    return result
end

local function huffman(depths)
    local size = #depths
    local blocks, codes, hufftable = {[0] = 0}, {}, {}
    local bits, code = 1, 0
    for i = 1, size do
        local depth = depths[i]
        if depth > bits then
            bits = depth
        end
        blocks[depth] = (blocks[depth] or 0) + 1
    end
    for i = 1, bits do
        code = (code + (blocks[i - 1] or 0)) * 2
        codes[i] = code
    end
    for i = 1, size do
        local depth = depths[i]
        if depth > 0 then
            local element = (i - 1) * 16 + depth
            local rcode = 0
            for j = 1, depth do
                rcode = rcode + lshift(band(1, rshift(codes[depth], j - 1)), depth - j)
            end
            for j = 0, 2 ^ bits - 1, 2 ^ depth do
                hufftable[j + rcode] = element
            end
            codes[depth] = codes[depth] + 1
        end
    end
    return hufftable, bits
end

local function loop(output, stream, litTable, litBits, distTable, distBits)
    local index = #output + 1
    local lit
    repeat
        lit = getElement(stream, litTable, litBits)
        if not lit then return nil end
        if lit < 256 then
            output[index] = lit
            index = index + 1
        elseif lit > 256 then
            local bits, size, dist = 0, 3, 1
            if lit < 265 then
                size = size + lit - 257
            elseif lit < 285 then
                bits = rshift(lit - 261, 2)
                size = size + lshift(band(lit - 261, 3) + 4, bits)
            else
                size = 258

            end
            if bits > 0 then
                size = size + getBits(stream, bits)
            end
            local element = getElement(stream, distTable, distBits)
            if element < 4 then
                dist = dist + element
            else
                bits = rshift(element - 2, 1)
                dist = dist + lshift(band(element, 1) + 2, bits) + getBits(stream, bits)
            end
            local position = index - dist
            repeat
                output[index] = output[position] or 0
                index = index + 1
                position = position + 1
                size = size - 1
            until size == 0
        end
    until lit == 256
end

local function dynamic(output, stream)
    local n = getBits(stream, 5)
    if not n then return nil end
    local lit, dist, length = 257 + n, 1 + getBits(stream, 5), 4 + getBits(stream, 4)
    local depths = {}
    for i = 1, length do
        depths[ORDER[i]] = getBits(stream, 3)
    end
    for i = length + 1, 19 do
        depths[ORDER[i]] = 0
    end
    local lengthTable, lengthBits = huffman(depths)
    local i = 1
    local total = lit + dist + 1
    repeat
        local element = getElement(stream, lengthTable, lengthBits)
        if element < 16 then
            depths[i] = element
            i = i + 1
        elseif element < 19 then
            local int = NBT[element  - 15]
            local count = 0
            local num = 3 + getBits(stream, int)
            if element == 16 then
                count = depths[i - 1]
            elseif element == 18 then
                num = num + 8
            end
            for _ = 1, num do
                depths[i] = count
                i = i + 1
            end
        end
    until i == total
    local litDepths, distDepths = {}, {}
    for j = 1, lit do
        litDepths[j] = depths[j]
    end
    for j = lit + 1, #depths do
        distDepths[#distDepths + 1] = depths[j]
    end
    local litTable, litBits = huffman(litDepths)
    local distTable, distBits = huffman(distDepths)
    loop(output, stream, litTable, litBits, distTable, distBits)
end

local function static(output, stream)
    local depths = {}
    for i = 1, 4 do
        local depth = DPT[i]
        for _ = 1, CNT[i] do
            depths[#depths + 1] = depth
        end
    end
    local litTable, litBits = huffman(depths)
    loop(output, stream, litTable, litBits, STATIC_HUFFMAN, STATIC_BITS)
end

local function uncompressed(output, stream)
    flushBits(stream, band(stream.count, 7))
    local length = getBits(stream, 16); getBits(stream, 16)
    if not length then return nil end
    local buffer, position = stream.buffer, stream.position
    for i = position, position + length - 1 do
        output[#output + 1] = byte(buffer, i, i)
    end
    stream.position = position + length
end

local function decompress(data)
    if data:sub(1, 5) ~= "\27LuzR" then error("invalid format", 2) end
    -- deflate string table
    local self = {buffer = data, position = 6, bits = 0, count = 0}
    local output, buffer = {}, {}
    local last, typ
    repeat
        last, typ = getBits(self, 1), getBits(self, 2)
        if not last or not typ then break end
        typ = typ == 0 and uncompressed(output, self) or typ == 1 and static(output, self) or typ == 2 and dynamic(output, self)
    until last == 1
    local size = #output
    for i = 1, size, 4096 do
        buffer[#buffer + 1] = char(unpack(output, i, min(i + 4095, size)))
    end
    local stringtable = concat(buffer)
    if self.count % 8 > 0 then flushBits(self, self.count % 8) end
    -- read identifier list
    local function read(n)
        return getBitsR(self, n)
    end
    local numident = varint(read)
    local identifiers = {}
    for i = 1, numident do
        local s = ""
        while true do
            local n = getBitsR(self, 6)
            if n == 63 then break end
            s = s .. b64str:sub(n+1, n+1)
        end
        identifiers[i] = s
    end
    -- read tokens
    local p = {
        stringpos = 1,
        stringtable = stringtable,
        names = identifiers,
        namepos = 1,
        namelist = {}
    }
    local tokens = {}
    local function push(s)
        if s == "" then return end
        tokens[#tokens+1] = s
    end
    assert(xpcall(trees[":block"], debug.traceback, p, read, push))
    -- create source
    local retval = ""
    local lastchar, lastdot = false, false
    for _, v in ipairs(tokens) do
        if (lastchar and v:match "^[A-Za-z0-9_]") or (lastdot and v:match "^%.") then retval = retval .. " " end
        retval = retval .. v
        lastchar, lastdot = v:match "[A-Za-z0-9_]$", v:match "%.$"
    end
    return retval
end

return decompress