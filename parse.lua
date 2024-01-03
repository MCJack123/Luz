local number = require "number"
local function append(tab, ext) for _, v in ipairs(ext) do tab[#tab+1] = v end return tab end

local function distcode(i)
    if i == 0 or i == 1 then return {code = i, extra = 0, bits = 0} end
    local ebits = math.max(select(2, math.frexp(i)) - 2, 0)
    local mask = 2^ebits
    return {code = ebits * 2 + (bit32.btest(i, mask) and 3 or 2), extra = bit32.band(i, mask-1), bits = ebits}
end

---@class (exact) State
---@field new function
---@field readName function
---@field readString function
---@field consume function
---@field next function
---@field back function
---@field peek function
---@field error function
---@field stringtable string
---@field pos number
local State = {}

function State.new(tokens)
    return setmetatable({
        tokens = tokens,
        names = {},
        namelist = {},
        stringtable = "",
        pos = 1,
        filename = "?",
        numsize = 0
    }, {__index = State})
end

function State:readName()
    local tok = self:peek()
    if not (tok and tok.type == "name") then self:error("expected name near '" .. (tok and tok.text or "<eof>") .. "'") end
    local id
    for i, v in ipairs(self.namelist) do if v == tok.text then id = i break elseif #tok.text == 1 and i > 512 then break end end
    if id then
        table.insert(self.namelist, 1, table.remove(self.namelist, id))
        self:next()
        if self.namecodetree then
            local code = distcode(id)
            local huff = self.namecodetree.map[code.code]
            return {bit32.bor(bit32.lshift(huff.code, code.bits), code.extra), huff.bits + code.bits, tok.text}
        else
            if id > 63 then return {id - 64 + 4096, 13, tok.text}
            else return {id, 7, tok.text} end
        end
    else
        self.names[#self.names+1] = tok.text
        table.insert(self.namelist, 1, tok.text)
        self:next()
        if self.namecodetree then
            local code = distcode(0)
            local huff = self.namecodetree.map[code.code]
            return {bit32.bor(bit32.lshift(huff.code, code.bits), code.extra), huff.bits + code.bits, tok.text}
        else return {0, 7, tok.text} end
    end
end

function State:readString()
    local tok = self:peek()
    if not (tok and tok.type == "string") then self:error("expected string near '" .. (tok and tok.text or "<eof>") .. "'") end
    local str = assert(load("return " .. tok.text, "=string", "t", {}))()
    self.stringtable = self.stringtable .. str
    self:next()
    -- TODO
    local code = distcode(#str)
    return {bit32.bor(bit32.lshift(code.code, code.bits), code.extra), 5 + code.bits, str}
end

function State:readNumber()
    local tok = self:peek()
    if not (tok and tok.type == "number") then self:error("expected number near '" .. (tok and tok.text or "<eof>") .. "'") end
    local num = tonumber(tok.text)
    if not num then self:error("malformed number near '" .. tok.text .. "'") end
    self:next()
    local insts = number.number(num)
    for _, v in ipairs(insts) do self.numsize = self.numsize + v[2] end
    return insts
end

function State:consume(type, token)
    local tok = self:peek()
    if not tok then self:error("expected '" .. token .. "' near '<eof>'") end
    if tok.type ~= type or tok.text ~= token then self:error("expected '" .. token .. "' near '" .. tok.text .. "'") end
    self:next()
end

function State:next()
    self.pos = self.pos + 1
end

function State:back()
    self.pos = self.pos - 1
end

function State:peek()
    return self.tokens[self.pos]
end

function State:error(msg)
    local tok = self:peek()
    if tok then error(debug.traceback(self.filename .. ":" .. tok.line .. ":" .. tok.col .. ": " .. msg), 0)
    else error(msg, 0) end
end

local reader = {}

---@param state State
---@return table
---@nodiscard
function reader.block(state)
    local insts = {}
    while true do
        --print(":block stat", state.pos)
        local tok = state:peek()
        if not tok then insts[#insts+1] = {15, 4, "<eof>", type = ":block"} return insts end
        if tok.type == "operator" then
            if tok.text == "::" then
                insts[#insts+1] = {2, 4, "::", type = ":block"}
                state:next()
                insts[#insts+1] = state:readName()
                state:consume("operator", "::")
            elseif tok.text == ";" then state:next()
            elseif tok.text == "(" then append(insts, reader.callorassign(state))
            else state:error("unexpected token '" .. tok.text .. "'") end
        elseif tok.type == "keyword" then
            if tok.text == "until" or tok.text == "end" or tok.text == "elseif" or tok.text == "else" then
                insts[#insts+1] = {15, 4, "<end>", type = ":block"}
                return insts
            elseif tok.text == "break" then
                insts[#insts+1] = {3, 4, "break", type = ":block"}
                state:next()
            elseif tok.text == "goto" then
                insts[#insts+1] = {4, 4, "goto", type = ":block"}
                state:next()
                insts[#insts+1] = state:readName()
            elseif tok.text == "do" then
                insts[#insts+1] = {5, 4, "do", type = ":block"}
                state:next()
                append(insts, reader.block(state))
                state:consume("keyword", "end")
            elseif tok.text == "while" then
                insts[#insts+1] = {6, 4, "while", type = ":block"}
                state:next()
                append(insts, reader.exp(state))
                state:consume("keyword", "do")
                append(insts, reader.block(state))
                state:consume("keyword", "end")
            elseif tok.text == "repeat" then
                insts[#insts+1] = {7, 4, "repeat", type = ":block"}
                state:next()
                append(insts, reader.block(state))
                state:consume("keyword", "until")
                append(insts, reader.exp(state))
            elseif tok.text == "if" then
                insts[#insts+1] = {8, 4, "if", type = ":block"}
                state:next()
                append(insts, reader.exp(state))
                state:consume("keyword", "then")
                append(insts, reader.block(state))
                while true do
                    tok = state:peek()
                    if not tok then state:error("expected 'end' near '<eof>'") end
                    if tok.type == "keyword" then
                        if tok.text == "elseif" then
                            insts[#insts+1] = {2, 2, "elseif"}
                            state:next()
                            append(insts, reader.exp(state))
                            state:consume("keyword", "then")
                            append(insts, reader.block(state))
                        elseif tok.text == "else" then
                            insts[#insts+1] = {3, 2, "else"}
                            state:next()
                            append(insts, reader.block(state))
                            state:consume("keyword", "end")
                            break
                        elseif tok.text == "end" then
                            insts[#insts+1] = {0, 1, "end"}
                            state:next()
                            break
                        else state:error("expected 'end' near '" .. tok.text .. "'") end
                    else state:error("expected 'end' near '" .. tok.text .. "'") end
                end
            elseif tok.text == "for" then
                state:next()
                state:next() -- skip name for now
                tok = state:peek()
                if tok.type == "operator" and tok.text == "=" then
                    insts[#insts+1] = {9, 4, "for (range)", type = ":block"}
                    state:back()
                    insts[#insts+1] = state:readName()
                    state:next() -- skip `=`
                    append(insts, reader.exp(state))
                    state:consume("operator", ",")
                    append(insts, reader.exp(state))
                    tok = state:peek()
                    if tok and tok.type == "operator" and tok.text == "," then
                        insts[#insts+1] = {0, 1, ","}
                        state:next()
                        append(insts, reader.exp(state))
                    else insts[#insts+1] = {1, 1, "do"} end
                    state:consume("keyword", "do")
                    append(insts, reader.block(state))
                    state:consume("keyword", "end")
                elseif (tok.type == "operator" and tok.text == ",") or (tok.type == "keyword" and tok.text == "in") then
                    insts[#insts+1] = {10, 4, "for (iter)", type = ":block"}
                    state:back()
                    insts[#insts+1] = state:readName()
                    tok = state:peek()
                    while tok and tok.type == "operator" and tok.text == "," do
                        insts[#insts+1] = {0, 1, ","}
                        state:next()
                        insts[#insts+1] = state:readName()
                        tok = state:peek()
                    end
                    insts[#insts+1] = {1, 1, "in"}
                    state:consume("keyword", "in")
                    append(insts, reader.exp(state))
                    tok = state:peek()
                    while tok and tok.type == "operator" and tok.text == "," do
                        insts[#insts+1] = {0, 1, ","}
                        state:next()
                        append(insts, reader.exp(state))
                        tok = state:peek()
                    end
                    insts[#insts+1] = {1, 1, "do"}
                    state:consume("keyword", "do")
                    append(insts, reader.block(state))
                    state:consume("keyword", "end")
                else state:error("expected 'in' near '" .. tok.text .. "'") end
            elseif tok.text == "function" then
                insts[#insts+1] = {11, 4, "function", type = ":block"}
                state:next()
                insts[#insts+1] = state:readName()
                while true do
                    tok = state:peek()
                    if tok and tok.type == "operator" then
                        if tok.text == "." then
                            insts[#insts+1] = {3, 2, "."}
                            state:next()
                            insts[#insts+1] = state:readName()
                        elseif tok.text == ":" then
                            insts[#insts+1] = {2, 2, ":"}
                            state:next()
                            insts[#insts+1] = state:readName()
                            break
                        elseif tok.text == "(" then
                            insts[#insts+1] = {0, 1, "("}
                            break
                        else state:error("expected '(' near '" .. tok.text .. "'") end
                    else state:error("expected '(' near '" .. tok.text .. "'") end
                end
                append(insts, reader.funcbody(state))
            elseif tok.text == "local" then
                state:next()
                tok = state:peek()
                if tok and tok.type == "keyword" and tok.text == "function" then
                    insts[#insts+1] = {12, 4, "local function", type = ":block"}
                    state:next()
                    insts[#insts+1] = state:readName()
                    append(insts, reader.funcbody(state))
                else
                    insts[#insts+1] = {13, 4, "local", type = ":block"}
                    local start = #insts
                    local local1 = true
                    insts[#insts+1] = state:readName()
                    tok = state:peek()
                    while tok and tok.type == "operator" and tok.text == "," do
                        insts[#insts+1] = {2, 2, ","}
                        local1 = false
                        state:next()
                        insts[#insts+1] = state:readName()
                        tok = state:peek()
                    end
                    tok = state:peek()
                    if tok and tok.type == "operator" and tok.text == "=" then
                        insts[#insts+1] = {0, 1, "="}
                        state:next()
                        append(insts, reader.exp(state))
                        tok = state:peek()
                        while tok and tok.type == "operator" and tok.text == "," do
                            insts[#insts+1] = {0, 1, ","}
                            local1 = false
                            state:next()
                            append(insts, reader.exp(state))
                            tok = state:peek()
                        end
                        insts[#insts+1] = {1, 1, "<done>"}
                    else insts[#insts+1] = {3, 2, "<done>"} local1 = false end
                    if local1 then
                        insts[start] = {17, 4, "local1", type = ":block"}
                        table.remove(insts, start + 2)
                        insts[#insts] = nil
                    end
                end
            elseif tok.text == "return" then
                insts[#insts+1] = {14, 4, "return", type = ":block"}
                state:next()
                tok = state:peek()
                if not tok or (tok.type == "keyword" and (tok.text == "until" or tok.text == "end" or tok.text == "elseif" or tok.text == "else")) then
                    insts[#insts+1] = {1, 1, "<done>"}
                else
                    local start = #insts
                    local return1 = true
                    insts[#insts+1] = {0, 1, "(values)"}
                    append(insts, reader.exp(state))
                    tok = state:peek()
                    while tok and tok.type == "operator" and tok.text == "," do
                        insts[#insts+1] = {0, 1, ","}
                        return1 = false
                        state:next()
                        append(insts, reader.exp(state))
                        tok = state:peek()
                    end
                    if return1 and tok.type == "keyword" and (tok.text == "until" or tok.text == "end" or tok.text == "elseif" or tok.text == "else") then
                        insts[start][1] = 18
                        table.remove(insts, start+1)
                        return insts
                    end
                    insts[#insts+1] = {1, 1, "<done>"}
                end
            else state:error("unexpected token '" .. tok.text .. "'") end
        elseif tok.type == "name" then append(insts, reader.callorassign(state))
        else state:error("unexpected token '" .. tok.text .. "'") end
    end
end

---@param state State
---@return table
---@nodiscard
function reader.callorassign(state)
    --print(":callorassign", state.pos)
    local count = 0
    local function next()
        count = count + 1
        return state:next()
    end
    local function brackets(s, e)
        local pc = 1
        while pc > 0 do
            next()
            local tok = state:peek()
            if tok and tok.type == "operator" then
                if tok.text == s then pc = pc + 1
                elseif tok.text == e then pc = pc - 1 end
            end
        end
        next()
    end
    -- skip first part
    local tok = state:peek()
    if tok and tok.type == "operator" and tok.text == "(" then
        brackets("(", ")")
        tok = state:peek()
    elseif tok and tok.type == "name" then
        next()
        tok = state:peek()
    end
    -- find which comes first: parentheses/string/table following a prefixexp, or an equals sign
    local iscall
    while true do
        if tok and tok.type == "operator" then
            if tok.text == "." then
                -- skip .Name
                next() next()
            elseif tok.text == "[" then
                -- skip [:exp]
                brackets("[", "]")
            elseif tok.text == ":" then
                -- this is a call (self-call)
                iscall = 1
                break
            elseif tok.text == "(" then
                -- this is a call
                iscall = true
                break
            elseif tok.text == "{" then
                -- this is a call (table call)
                iscall = true
                break
            elseif tok.text == "=" then
                -- this is an assignment
                iscall = false
                break
            elseif tok.text == "," then
                -- this is an assignment (calls cannot have lists)
                iscall = false
                break
            else state:error("expected '=' near '" .. tok.text .. "'") end
        elseif tok and tok.type == "string" then
            -- this is a call (string call)
            iscall = true
            break
        else state:error("expected '=' near '" .. (tok and tok.text or "<eof>") .. "'")end
        tok = state:peek()
    end
    -- rewind to the start, and execute reader
    for _ = 1, count do state:back() end
    local insts = {}
    if iscall then
        insts[#insts+1] = {1, 4, ":call", type = ":block"}
        append(insts, reader.call(state))
        --print(":callorassign done", state.pos)
        return insts
    else
        local i, i1 = reader.assign(state)
        if i1 then
            insts[#insts+1] = {16, 4, ":assign1", type = ":block"}
            append(insts, i1)
        else
            insts[#insts+1] = {0, 4, ":assign", type = ":block"}
            append(insts, i)
        end
        return insts
    end
end

---@param state State
---@return table
---@nodiscard
function reader.call(state)
    return reader.prefixexp(state)
end

---@param state State
---@return table
---@return table|nil
---@nodiscard
function reader.assign(state)
    --print(":assign", state.pos)
    local insts = reader.var(state)
    local insts1 = {}
    for i, v in ipairs(insts) do insts1[i] = v end
    local tok = state:peek()
    while tok and tok.type == "operator" and tok.text == "," do
        insts[#insts+1] = {0, 1, ","}
        insts1 = nil
        state:next()
        append(insts, reader.var(state))
        tok = state:peek()
    end
    insts[#insts+1] = {1, 1, "="}
    state:consume("operator", "=")
    local exp = reader.exp(state)
    append(insts, exp)
    if insts1 then append(insts1, exp) end
    tok = state:peek()
    while tok and tok.type == "operator" and tok.text == "," do
        insts[#insts+1] = {0, 1, ","}
        insts1 = nil
        state:next()
        append(insts, reader.exp(state))
        tok = state:peek()
    end
    insts[#insts+1] = {1, 1, "<done>"}
    return insts, insts1
end

---@param state State
---@return table
---@nodiscard
function reader.var(state)
    --print(":var", state.pos)
    local insts = {state:readName()}
    while true do
        local tok = state:peek()
        if tok and tok.type == "operator" then
            if tok.text == "." then
                state:next()
                insts[#insts+1] = {3, 2, "."}
                insts[#insts+1] = state:readName()
            elseif tok.text == "[" then
                state:next()
                insts[#insts+1] = {2, 2, "["}
                append(insts, reader.exp(state))
                state:consume("operator", "]")
            else
                insts[#insts+1] = {0, 1, "<done>"}
                return insts
            end
        else
            insts[#insts+1] = {0, 1, "<done>"}
            return insts
        end
    end
end

---@param state State
---@return table
---@nodiscard
function reader.args(state)
    --print(":args", state.pos)
    local tok = state:peek()
    if tok and tok.type == "string" then
        return {{3, 2, ":args :String"}, state:readString()}
    elseif tok and tok.type == "operator" then
        if tok.text == "{" then
            local insts = reader.table(state)
            table.insert(insts, 1, {2, 2, ":args {"})
            return insts
        elseif tok.text == "(" then
            local insts = {{0, 1, ":args"}}
            state:next()
            tok = state:peek()
            if tok and tok.type == "operator" and tok.text == ")" then
                insts[2] = {1, 1, "()"}
                state:next()
                return insts
            end
            insts[2] = {0, 1, "("}
            append(insts, reader.exp(state))
            tok = state:peek()
            while tok and tok.type == "operator" and tok.text == "," do
                insts[#insts+1] = {0, 1, ","}
                state:next()
                append(insts, reader.exp(state))
                tok = state:peek()
            end
            insts[#insts+1] = {1, 1, ")"}
            state:consume("operator", ")")
            --print(":args done", state.pos)
            return insts
        else state:error("expected '(' near '" .. (tok and tok.text or "<eof>") .. "'") end
    else state:error("expected '(' near '" .. (tok and tok.text or "<eof>") .. "'") end
end

---@param state State
---@return table
---@nodiscard
function reader.prefixexp(state)
    --print(":var", state.pos)
    local tok = state:peek()
    local insts
    if tok and tok.type == "operator" and tok.text == "(" then
        state:next()
        insts = reader.exp(state)
        table.insert(insts, 1, {1, 1, "(:exp)"})
        state:consume("operator", ")")
    elseif tok and tok.type == "name" then
        insts = {{0, 1, ":Name"}, state:readName()}
    else state:error("expected name near '" .. (tok and tok.text or "<eof>") .. "'") end
    while true do
        tok = state:peek()
        if tok and tok.type == "operator" then
            if tok.text == "." then
                state:next()
                insts[#insts+1] = {6, 3, "."}
                insts[#insts+1] = state:readName()
            elseif tok.text == "[" then
                state:next()
                insts[#insts+1] = {14, 4, "["}
                append(insts, reader.exp(state))
                state:consume("operator", "]")
                if insts[#insts][3] == "<done>" then insts[#insts][3] = "]" end
            elseif tok.text == "(" or tok.text == "{" then
                insts[#insts+1] = {2, 2, "("}
                append(insts, reader.args(state))
            elseif tok.text == ":" then
                state:next()
                insts[#insts+1] = {15, 4, ":"}
                insts[#insts+1] = state:readName()
                append(insts, reader.args(state))
            else
                insts[#insts+1] = {0, 1, "<done>"}
                return insts
            end
        elseif tok and tok.type == "string" then
            insts[#insts+1] = {2, 2, "("}
            append(insts, reader.args(state))
        else
            insts[#insts+1] = {0, 1, "<done>"}
            return insts
        end
    end
end

local binop = {
    ["+"] = 0,
    ["-"] = 1,
    ["*"] = 2,
    ["/"] = 3,
    ["^"] = 4,
    ["%"] = 5,
    [".."] = 6,
    ["<"] = 7,
    ["<="] = 8,
    [">"] = 9,
    [">="] = 10,
    ["=="] = 11,
    ["~="] = 12,
    ["and"] = 13,
    ["or"] = 14
}

---@param state State
---@return table
---@nodiscard
function reader.exp(state)
    --print(":exp", state.pos)
    local insts
    local tok = state:peek()
    if tok then
        if tok.type == "constant" then
            if tok.text == "nil" then insts = {{0, 4, "nil", type = ":exp"}}
            elseif tok.text == "false" then insts = {{1, 4, "false", type = ":exp"}}
            elseif tok.text == "true" then insts = {{2, 4, "true", type = ":exp"}}
            elseif tok.text == "..." then insts = {{5, 4, "...", type = ":exp"}} end
            state:next()
        elseif tok.type == "number" then
            local num = tonumber(tok.text)
            if num == 0 then insts = {{11, 4, "0", type = ":exp"}} state:next()
            elseif num == 1 then insts = {{12, 4, "1", type = ":exp"}} state:next()
            elseif num == 2 then insts = {{13, 4, "2", type = ":exp"}} state:next()
            elseif num == -1 then insts = {{14, 4, "-1", type = ":exp"}} state:next()
            else insts = append({{3, 4, ":Number", type = ":exp"}}, state:readNumber()) end
        elseif tok.type == "string" then insts = {{4, 4, ":String", type = ":exp"}, state:readString()}
        elseif tok.type == "keyword" then
            if tok.text == "function" then
                state:next()
                insts = reader.funcbody(state)
                table.insert(insts, 1, {6, 4, "function()", type = ":exp"})
            else state:error("unexpected '" .. tok.text .. "'") end
        elseif tok.type == "operator" then
            if tok.text == "(" then
                insts = reader.prefixexp(state)
                table.insert(insts, 1, {7, 4, "(", type = ":exp"})
            elseif tok.text == "{" then
                insts = reader.table(state)
                table.insert(insts, 1, {8, 4, "{", type = ":exp"})
            elseif tok.text == "-" then
                insts = {{10, 4, ":unop", type = ":exp"}, {2, 2, "-"}}
                state:next()
                append(insts, reader.exp(state))
            elseif tok.text == "not" then
                insts = {{10, 4, ":unop", type = ":exp"}, {3, 2, "not"}}
                state:next()
                append(insts, reader.exp(state))
            elseif tok.text == "#" then
                insts = {{10, 4, ":unop", type = ":exp"}, {0, 1, "#"}}
                state:next()
                append(insts, reader.exp(state))
            else state:error("unexpected '" .. tok.text .. "'") end
        elseif tok.type == "name" then
            insts = reader.prefixexp(state)
            if #insts == 3 and insts[1][1] == 0 and insts[1][2] == 1 and insts[3][1] == 0 and insts[3][2] == 1 then
                insts = {{15, 4, ":Name", type = ":exp"}, insts[2]}
            else table.insert(insts, 1, {7, 4, ":prefixexp", type = ":exp"}) end
        else state:error("expected expression near '" .. tok.text .. "'") end
    else state:error("expected expression near '<eof>'") end
    tok = state:peek()
    if tok and (tok.type == "operator" or tok.type == "keyword") and binop[tok.text] then
        table.insert(insts, 1, {9, 4, ":binop", type = ":exp"})
        insts[#insts+1] = {binop[tok.text], 4, tok.text, type = ":binop"}
        state:next()
        append(insts, reader.exp(state))
    end
    --print(":exp done", state.pos)
    return insts
end

function reader.funcbody(state)
    --print(":funcbody", state.pos)
    local insts = {}
    state:consume("operator", "(")
    local tok = state:peek()
    if tok and tok.type == "operator" and tok.text == ")" then
        insts[#insts+1] = {2, 2, "()"}
        state:next()
    elseif tok and tok.type == "constant" and tok.text == "..." then
        insts[#insts+1] = {3, 2, "(...)"}
        state:next()
        state:consume("operator", ")")
    else
        insts[#insts+1] = {0, 1, "("}
        insts[#insts+1] = state:readName()
        tok = state:peek()
        local vararg = false
        while tok and tok.type == "operator" and tok.text == "," do
            state:next()
            tok = state:peek()
            if tok and tok.type == "constant" and tok.text == "..." then
                insts[#insts+1] = {1, 1, ","}
                insts[#insts+1] = {0, 1, "...)"}
                state:next()
                vararg = true
                break
            end
            insts[#insts+1] = {0, 1, ","}
            insts[#insts+1] = state:readName()
            tok = state:peek()
        end
        if not vararg then
            insts[#insts+1] = {1, 1, ""}
            insts[#insts+1] = {1, 1, ")"}
        end
        state:consume("operator", ")")
    end
    append(insts, reader.block(state))
    state:consume("keyword", "end")
    return insts
end

function reader.table(state)
    --print(":table", state.pos)
    local insts = {}
    state:consume("operator", "{")
    while true do
        local tok = state:peek()
        insts[#insts+1] = {2, 2, ","}
        local pos = #insts
        if tok then
            if tok.type == "operator" then
                if tok.text == "[" then
                    insts[#insts+1] = {2, 2, "[] ="}
                    state:next()
                    append(insts, reader.exp(state))
                    state:consume("operator", "]")
                    state:consume("operator", "=")
                    append(insts, reader.exp(state))
                elseif tok.text == "}" then
                    insts[pos] = {3, 2, "}"}
                    state:next()
                    return insts
                else
                    insts[#insts+1] = {0, 1, ":exp"}
                    append(insts, reader.exp(state))
                end
            elseif tok.type == "name" then
                state:next()
                tok = state:peek()
                if tok and tok.type == "operator" and tok.text == "=" then
                    state:back()
                    insts[#insts+1] = {3, 2, "="}
                    insts[#insts+1] = state:readName()
                    state:next()
                    append(insts, reader.exp(state))
                else
                    state:back()
                    insts[#insts+1] = {0, 1, ":exp"}
                    append(insts, reader.exp(state))
                end
            else
                insts[#insts+1] = {0, 1, ":exp"}
                append(insts, reader.exp(state))
            end
        else state:error("expected '}' near '<eof>'") end
        tok = state:peek()
        if tok and tok.type == "operator" and tok.text == "}" then
            insts[pos] = {0, 1, "...}"}
            state:next()
            return insts
        elseif tok and tok.type == "operator" and (tok.text == "," or tok.text == ";") then
            state:next()
        else state:error("expected '}' near '" .. (tok and tok.text or "<eof>") .. "'") end
    end
end

return function(tokens, filename, namecodetree)
    local state = State.new(tokens)
    state.filename = filename or state.filename
    state.namecodetree = namecodetree
    local insts = reader.block(state)
    if state:peek() then state:error("expected '<eof>' near '" .. state:peek().text .. "'") end
    local size = 0
    for _, v in ipairs(insts) do size = size + v[2] end
    print("numsize", state.numsize / 8)
    return {
        bits = insts,
        size = size,
        names = state.names,
        stringtable = state.stringtable
    }
end
