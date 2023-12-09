local function append(tab, ext) for _, v in ipairs(ext) do tab[#tab+1] = v end return tab end
local function round(n) if n % 1 >= 0.5 then return math.ceil(n) else return math.floor(n) end end

local function varint(num)
    local bytes = {}
    while num > 127 do bytes[#bytes+1], num = num % 128, math.floor(num / 128) end
    bytes[#bytes+1] = num % 128
    local insts = {}
    for i = #bytes, 1, -1 do insts[#insts+1] = {bytes[i] + (i == 1 and 0 or 128), 8} end
    return insts
end

local function number(num)
    if num % 1 == 0 then
        local insts = {{num < 0 and 1 or 0, 2}}
        return append(insts, varint(math.abs(num)))
    else
        local m, e = math.frexp(num)
        m = round((math.abs(m) - 0.5) * 0x20000000000000)
        if m > 0xFFFFFFFFFFFFF then e = e + 1 end
        local insts = {{(num < 0 and 3 or 2), 2}, {e < 0 and 1 or 0, 1}}
        e = math.abs(e)
        local nibbles = {}
        while e > 7 do nibbles[#nibbles+1], e = e % 8, math.floor(e / 8) end
        nibbles[#nibbles+1] = e % 8
        for i = #nibbles, 1, -1 do insts[#insts+1] = {nibbles[i] + (i == 1 and 0 or 8), 4} end
        return append(insts, varint(m))
    end
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
        filename = "?"
    }, {__index = State})
end

function State:readName()
    local tok = self:peek()
    if not (tok and tok.type == "name") then self:error("expected name near '" .. (tok and tok.text or "<eof>") .. "'") end
    local id
    for i, v in ipairs(self.namelist) do if v == tok.text then id = i break end end
    if id then
        table.insert(self.namelist, 1, table.remove(self.namelist, id))
        self:next()
        if id > 63 then return {id - 64 + 4096, 13}
        else return {id, 7} end
    else
        self.names[#self.names+1] = tok.text
        table.insert(self.namelist, 1, tok.text)
        self:next()
        return {0, 7}
    end
end

function State:readString()
    local tok = self:peek()
    if not (tok and tok.type == "string") then self:error("expected string near '" .. (tok and tok.text or "<eof>") .. "'") end
    local str = assert(load("return " .. tok.text, "=string", "t", {}))()
    self.stringtable = self.stringtable .. str
    self:next()
    -- TODO
    return {#str, 8}
end

function State:readNumber()
    local tok = self:peek()
    if not (tok and tok.type == "number") then self:error("expected number near '" .. (tok and tok.text or "<eof>") .. "'") end
    local num = tonumber(tok.text)
    if not num then self:error("malformed number near '" .. tok.text .. "'") end
    self:next()
    return number(num)
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
        if not tok then insts[#insts+1] = {15, 4} return insts end
        if tok.type == "operator" then
            if tok.text == "::" then
                insts[#insts+1] = {2, 4}
                state:next()
                insts[#insts+1] = state:readName()
                state:consume("operator", "::")
            elseif tok.text == ";" then state:next()
            elseif tok.text == "(" then append(insts, reader.callorassign(state, 1, 0, 4))
            else state:error("unexpected token '" .. tok.text .. "'") end
        elseif tok.type == "keyword" then
            if tok.text == "until" or tok.text == "end" or tok.text == "elseif" or tok.text == "else" then
                insts[#insts+1] = {15, 4}
                return insts
            elseif tok.text == "break" then
                insts[#insts+1] = {3, 4}
                state:next()
            elseif tok.text == "goto" then
                insts[#insts+1] = {4, 4}
                state:next()
                insts[#insts+1] = state:readName()
            elseif tok.text == "do" then
                insts[#insts+1] = {5, 4}
                state:next()
                append(insts, reader.block(state))
                state:consume("keyword", "end")
            elseif tok.text == "while" then
                insts[#insts+1] = {6, 4}
                state:next()
                append(insts, reader.exp(state))
                state:consume("keyword", "do")
                append(insts, reader.block(state))
                state:consume("keyword", "end")
            elseif tok.text == "repeat" then
                insts[#insts+1] = {7, 4}
                state:next()
                append(insts, reader.block(state))
                state:consume("keyword", "until")
                append(insts, reader.exp(state))
            elseif tok.text == "if" then
                insts[#insts+1] = {8, 4}
                state:next()
                append(insts, reader.exp(state))
                state:consume("keyword", "then")
                append(insts, reader.block(state))
                while true do
                    tok = state:peek()
                    if not tok then state:error("expected 'end' near '<eof>'") end
                    if tok.type == "keyword" then
                        if tok.text == "elseif" then
                            insts[#insts+1] = {0, 2}
                            state:next()
                            append(insts, reader.exp(state))
                            state:consume("keyword", "then")
                            append(insts, reader.block(state))
                        elseif tok.text == "else" then
                            insts[#insts+1] = {1, 2}
                            state:next()
                            append(insts, reader.block(state))
                            state:consume("keyword", "end")
                            break
                        elseif tok.text == "end" then
                            insts[#insts+1] = {2, 2}
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
                    insts[#insts+1] = {9, 4}
                    state:back()
                    insts[#insts+1] = state:readName()
                    state:next() -- skip `=`
                    append(insts, reader.exp(state))
                    state:consume("operator", ",")
                    append(insts, reader.exp(state))
                    tok = state:peek()
                    if tok and tok.type == "operator" and tok.text == "," then
                        insts[#insts+1] = {0, 1}
                        state:next()
                        append(insts, reader.exp(state))
                    else insts[#insts+1] = {1, 1} end
                    state:consume("keyword", "do")
                    append(insts, reader.block(state))
                    state:consume("keyword", "end")
                elseif (tok.type == "operator" and tok.text == ",") or (tok.type == "keyword" and tok.text == "in") then
                    insts[#insts+1] = {10, 4}
                    state:back()
                    insts[#insts+1] = state:readName()
                    tok = state:peek()
                    while tok and tok.type == "operator" and tok.text == "," do
                        insts[#insts+1] = {0, 1}
                        state:next()
                        insts[#insts+1] = state:readName()
                        tok = state:peek()
                    end
                    insts[#insts+1] = {1, 1}
                    state:consume("keyword", "in")
                    append(insts, reader.exp(state))
                    tok = state:peek()
                    while tok and tok.type == "operator" and tok.text == "," do
                        insts[#insts+1] = {0, 1}
                        state:next()
                        append(insts, reader.exp(state))
                        tok = state:peek()
                    end
                    insts[#insts+1] = {1, 1}
                    state:consume("keyword", "do")
                    append(insts, reader.block(state))
                    state:consume("keyword", "end")
                else state:error("expected 'in' near '" .. tok.text .. "'") end
            elseif tok.text == "function" then
                insts[#insts+1] = {11, 4}
                insts[#insts+1] = state:readName()
                tok = state:peek()
                while true do
                    if tok and tok.type == "operator" then
                        if tok.text == "." then
                            insts[#insts+1] = {0, 2}
                            state:next()
                            insts[#insts+1] = state:readName()
                        elseif tok.text == ":" then
                            insts[#insts+1] = {1, 2}
                            state:next()
                            insts[#insts+1] = state:readName()
                            break
                        end
                    else
                        insts[#insts+1] = {2, 2}
                        break
                    end
                end
                append(insts, reader.funcbody(state))
            elseif tok.text == "local" then
                state:next()
                tok = state:peek()
                if tok and tok.type == "keyword" and tok.text == "function" then
                    insts[#insts+1] = {12, 4}
                    state:next()
                    insts[#insts+1] = state:readName()
                    append(insts, reader.funcbody(state))
                else
                    insts[#insts+1] = {13, 4}
                    insts[#insts+1] = state:readName()
                    tok = state:peek()
                    while tok and tok.type == "operator" and tok.text == "," do
                        insts[#insts+1] = {0, 1}
                        state:next()
                        insts[#insts+1] = state:readName()
                        tok = state:peek()
                    end
                    insts[#insts+1] = {1, 1}
                    tok = state:peek()
                    if tok and tok.type == "operator" and tok.text == "=" then
                        insts[#insts+1] = {0, 1}
                        state:next()
                        append(insts, reader.exp(state))
                        tok = state:peek()
                        while tok and tok.type == "operator" and tok.text == "," do
                            insts[#insts+1] = {0, 1}
                            state:next()
                            append(insts, reader.exp(state))
                            tok = state:peek()
                        end
                        insts[#insts+1] = {1, 1}
                    else insts[#insts+1] = {1, 1} end
                end
            elseif tok.text == "return" then
                insts[#insts+1] = {14, 4}
                state:next()
                tok = state:peek()
                if not tok or (tok.type == "keyword" and (tok.text == "until" or tok.text == "end" or tok.text == "elseif" or tok.text == "else")) then
                    insts[#insts+1] = {1, 1}
                else
                    insts[#insts+1] = {0, 1}
                    append(insts, reader.exp(state))
                    tok = state:peek()
                    while tok and tok.type == "operator" and tok.text == "," do
                        insts[#insts+1] = {0, 1}
                        state:next()
                        append(insts, reader.exp(state))
                        tok = state:peek()
                    end
                    insts[#insts+1] = {1, 1}
                end
            else state:error("unexpected token '" .. tok.text .. "'") end
        elseif tok.type == "name" then append(insts, reader.callorassign(state, 1, 0, 4))
        else state:error("unexpected token '" .. tok.text .. "'") end
    end
end

---@param state State
---@return table
---@nodiscard
function reader.callorassign(state, callopt, assignopt, bits)
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
        if callopt then insts[#insts+1] = {callopt, bits} end
        append(insts, reader.call(state))
        --print(":callorassign done", state.pos)
        return insts
    else
        if assignopt then insts[#insts+1] = {assignopt, bits} end
        append(insts, reader.assign(state))
        return insts
    end
end

---@param state State
---@return table
---@nodiscard
function reader.call(state)
    --print(":call", state.pos)
    local insts, isprefix = reader.var(state, true) -- this processes the entire call
    if not isprefix then state:error("expected '(' near '" .. (state:peek() or {text = "<eof>"}).text .. "'") end
    table.remove(insts, 1) -- remove prefixexp wrapper
    --print(":call done", state.pos)
    return insts
end

---@param state State
---@return table
---@nodiscard
function reader.assign(state)
    --print(":assign", state.pos)
    local insts = reader.var(state)
    local tok = state:peek()
    while tok and tok.type == "operator" and tok.text == "," do
        insts[#insts+1] = {0, 1}
        state:next()
        append(insts, reader.var(state))
        tok = state:peek()
    end
    insts[#insts+1] = {1, 1}
    state:consume("operator", "=")
    append(insts, reader.exp(state))
    tok = state:peek()
    while tok and tok.type == "operator" and tok.text == "," do
        insts[#insts+1] = {0, 1}
        state:next()
        append(insts, reader.exp(state))
        tok = state:peek()
    end
    insts[#insts+1] = {1, 1}
    return insts
end

---@param state State
---@return table
---@return boolean
---@nodiscard
function reader.var(state, allowPrefix)
    --print(":var", state.pos)
    local tok = state:peek()
    local insts = {}
    local lastprefix = false
    if tok and tok.type == "operator" and tok.text == "(" then
        -- starts with a prefixexp
        state:next()
        insts = reader.exp(state)
        table.insert(insts, 1, {2, 2})
        state:consume("operator", ")")
        lastprefix = true
    elseif tok and tok.type == "name" then
        insts = {{0, 2}, state:readName()}
    else state:error("expected name near '" .. (tok and tok.text or "<eof>") .. "'") end
    while true do
        tok = state:peek()
        if tok and tok.type == "operator" then
            if tok.text == "." then
                state:next()
                if not lastprefix then table.insert(insts, 1, {0, 2}) end -- :prefixexp(:var)
                table.insert(insts, 1, {2, 2}) -- :var(:prefixexp . :Name)
                insts[#insts+1] = state:readName()
                lastprefix = false
            elseif tok.text == "[" then
                state:next()
                if not lastprefix then table.insert(insts, 1, {0, 2}) end -- :prefixexp(:var)
                table.insert(insts, 1, {1, 2}) -- :var(:prefixexp [ :exp ])
                append(insts, reader.exp(state))
                state:consume("operator", "]")
                lastprefix = false
            elseif tok.text == "(" or tok.text == "{" then
                local newinsts = reader.args(state)
                if not lastprefix then table.insert(insts, 1, {0, 2}) end -- :prefixexp(:var)
                table.insert(insts, 1, {0, 1}) -- :call(:prefixexp :args)
                table.insert(insts, 1, {1, 2}) -- :prefixexp(:call)
                append(insts, newinsts)
                lastprefix = true
            elseif tok.text == ":" then
                state:next()
                local name = state:readName()
                local newinsts = reader.args(state)
                if not lastprefix then table.insert(insts, 1, {0, 2}) end -- :prefixexp(:var)
                table.insert(insts, 1, {1, 1}) -- :call(:prefixexp : :Name :args)
                table.insert(insts, 1, {1, 2}) -- :prefixexp(:call)
                insts[#insts+1] = name
                append(insts, newinsts)
                lastprefix = true
            else
                if lastprefix and not allowPrefix then state:error("syntax error near '" .. tok.text .. "'") end
                return insts, lastprefix
            end
        elseif tok and tok.type == "string" then
            local newinsts = reader.args(state)
            if not lastprefix then table.insert(insts, 1, {0, 2}) end -- :prefixexp(:var)
            table.insert(insts, 1, {0, 1}) -- :call(:prefixexp :args)
            table.insert(insts, 1, {1, 2}) -- :prefixexp(:call)
            append(insts, newinsts)
            lastprefix = true
        else
            if lastprefix and not allowPrefix then state:error("syntax error near '" .. (tok and tok.text or "<eof>") .. "'") end
            return insts, lastprefix
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
        return {{2, 2}, state:readString()}
    elseif tok and tok.type == "operator" then
        if tok.text == "{" then
            local insts = reader.table(state)
            table.insert(insts, 1, {1, 2})
            return insts
        elseif tok.text == "(" then
            local insts = {{0, 2}}
            state:next()
            tok = state:peek()
            if tok and tok.type == "operator" and tok.text == ")" then
                insts[2] = {1, 1}
                state:next()
                return insts
            end
            insts[2] = {0, 1}
            append(insts, reader.exp(state))
            tok = state:peek()
            while tok and tok.type == "operator" and tok.text == "," do
                insts[#insts+1] = {0, 1}
                state:next()
                append(insts, reader.exp(state))
                tok = state:peek()
            end
            insts[#insts+1] = {1, 1}
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
    --print(":prefixexp", state.pos)
    local insts, isprefix = reader.var(state, true) -- this processes everything
    if not isprefix then table.insert(insts, 1, {0, 2}) end
    return insts
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
            if tok.text == "nil" then insts = {{0, 4}}
            elseif tok.text == "false" then insts = {{1, 4}}
            elseif tok.text == "true" then insts = {{2, 4}}
            elseif tok.text == "..." then insts = {{5, 4}} end
            state:next()
        elseif tok.type == "number" then insts = append({{3, 4}}, state:readNumber())
        elseif tok.type == "string" then insts = {{4, 4}, state:readString()}
        elseif tok.type == "keyword" then
            if tok.text == "function" then
                state:next()
                insts = reader.funcbody(state)
                table.insert(insts, 1, {6, 4})
            else state:error("unexpected '" .. tok.text .. "'") end
        elseif tok.type == "operator" then
            if tok.text == "(" then
                insts = reader.prefixexp(state)
                table.insert(insts, 1, {7, 4})
            elseif tok.text == "{" then
                insts = reader.table(state)
                table.insert(insts, 1, {8, 4})
            elseif tok.text == "-" then
                insts = {{10, 4}, {0, 2}}
                state:next()
                append(insts, reader.exp(state))
            elseif tok.text == "not" then
                insts = {{10, 4}, {1, 2}}
                state:next()
                append(insts, reader.exp(state))
            elseif tok.text == "#" then
                insts = {{10, 4}, {2, 2}}
                state:next()
                append(insts, reader.exp(state))
            else state:error("unexpected '" .. tok.text .. "'") end
        elseif tok.type == "name" then
            insts = reader.prefixexp(state)
            table.insert(insts, 1, {7, 4})
        else state:error("expected expression near '" .. tok.text .. "'") end
    else state:error("expected expression near '<eof>'") end
    tok = state:peek()
    if tok and (tok.type == "operator" or tok.type == "keyword") and binop[tok.text] then
        table.insert(insts, 1, {9, 4})
        insts[#insts+1] = {binop[tok.text], 4}
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
        insts[#insts+1] = {0, 2}
        state:next()
    elseif tok and tok.type == "constant" and tok.text == "..." then
        insts[#insts+1] = {1, 2}
        state:next()
        state:consume("operator", ")")
    else
        insts[#insts+1] = {2, 2}
        insts[#insts+1] = state:readName()
        tok = state:peek()
        local vararg = false
        while tok and tok.type == "operator" and tok.text == "," do
            state:next()
            tok = state:peek()
            if tok and tok.type == "constant" and tok.text == "..." then
                insts[#insts+1] = {1, 1}
                insts[#insts+1] = {0, 1}
                state:next()
                vararg = true
                break
            end
            insts[#insts+1] = {0, 1}
            insts[#insts+1] = state:readName()
            tok = state:peek()
        end
        if not vararg then
            insts[#insts+1] = {1, 1}
            insts[#insts+1] = {1, 1}
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
        insts[#insts+1] = {0, 2}
        local pos = #insts
        if tok then
            if tok.type == "operator" then
                if tok.text == "[" then
                    insts[#insts+1] = {0, 2}
                    state:next()
                    append(insts, reader.exp(state))
                    state:consume("operator", "]")
                    state:consume("operator", "=")
                    append(insts, reader.exp(state))
                elseif tok.text == "}" then
                    insts[pos] = {2, 2}
                    state:next()
                    return insts
                else
                    insts[#insts+1] = {2, 2}
                    append(insts, reader.exp(state))
                end
            elseif tok.type == "name" then
                state:next()
                tok = state:peek()
                if tok and tok.type == "operator" and tok.text == "=" then
                    state:back()
                    insts[#insts+1] = {1, 2}
                    insts[#insts+1] = state:readName()
                    state:next()
                    append(insts, reader.exp(state))
                else
                    state:back()
                    insts[#insts+1] = {2, 2}
                    append(insts, reader.exp(state))
                end
            else
                insts[#insts+1] = {2, 2}
                append(insts, reader.exp(state))
            end
        else state:error("expected '}' near '<eof>'") end
        tok = state:peek()
        if tok and tok.type == "operator" and tok.text == "}" then
            insts[pos][1] = 1
            state:next()
            return insts
        elseif tok and tok.type == "operator" and (tok.text == "," or tok.text == ";") then
            state:next()
        else state:error("expected '}' near '" .. (tok and tok.text or "<eof>") .. "'") end
    end
end

return function(tokens, filename)
    local state = State.new(tokens)
    state.filename = filename or state.filename
    local insts = reader.block(state)
    if state:peek() then state:error("expected '<eof>' near '" .. state:peek().text .. "'") end
    local size = 0
    for _, v in ipairs(insts) do size = size + v[2] end
    return {
        bits = insts,
        size = size,
        names = state.names,
        stringtable = state.stringtable
    }
end
