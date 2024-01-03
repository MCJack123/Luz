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
        local name = table.remove(state.namelist, id)
        push(name)
        table.insert(state.namelist, 1, name)
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

return function(p)
    local str = ""
    p.stringpos = 1
    p.namepos = 1
    p.namelist = {}
    local readpos = 1
    local function read(n)
        if (p.bits[readpos][2] == 13 or p.bits[readpos][2] == 7) then
            if n == 1 then return bit32.rshift(p.bits[readpos][1], p.bits[readpos][2] - 1)
            elseif n == 6 then n = 7
            elseif n == 12 then
                assert(p.bits[readpos][2] == 13, debug.traceback("bad read at " .. readpos .. " (expected " .. p.bits[readpos][2] .. ", got 13)"))
                local retval = bit32.band(p.bits[readpos][1], 0xFFF)
                readpos = readpos + 1
                return retval
            end
        end
        assert(p.bits[readpos][2] == n, debug.traceback("bad read at " .. readpos .. " (expected " .. p.bits[readpos][2] .. ", got " .. n .. ")"))
        local retval = p.bits[readpos][1]
        readpos = readpos + 1
        return retval
    end
    local function push(s)
        print(s)
        str = str .. s .. " "
    end
    trees[":block"](p, read, push)
    return str
end