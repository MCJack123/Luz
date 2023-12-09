local error_mt = {}
function error_mt.__tostring(self)
    return (self.src or "unknown") .. ":" .. self.line .. ": " .. self.text
end

local function util_error(line, col, text)
    error(setmetatable({line = line, col = col, text = text}, error_mt), 0)
end

local classes = {
    operator = "^([;:=%.,%[%]%(%)%{%}%+%-%*/%^%%<>~#&|][=%.]?%.?)()",
    name = "^([%a_][%w_]*)()",
    number = "^(%d+%.?%d*)()",
    scinumber = "^(%d+%.?%d*[eE][%+%-]?%d+)()",
    hexnumber = "^(0[xX]%x+%.?%x*)()",
    scihexnumber = "^(0[xX]%x+%.?%x*[pP][%+%-]?%x+)()",
    linecomment = "^(%-%-[^\n]*)()",
    blockcomment = "^(%-%-%[(=*)%[.-%]%2%])()",
    emptyblockcomment = "^(%-%-%[(=*)%[%]%2%])()",
    blockquote = "^(%[(=*)%[.-%]%2%])()",
    emptyblockquote = "^(%[(=*)%[%]%2%])()",
    dquote = '^("[^"]*")()',
    squote = "^('[^']*')()",
    whitespace = "^(%s+)()",
    invalid = "^([^%w%s_;:=%.,%[%]%(%)%{%}%+%-%*/%^%%<>~#&|]+)()",
}

local classes_precedence = {"name", "scihexnumber", "hexnumber", "scinumber", "number", "blockcomment", "emptyblockcomment", "linecomment", "blockquote", "emptyblockquote", "operator", "dquote", "squote", "whitespace", "invalid"}

local keywords = {
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["for"] = true,
    ["function"] = true,
    ["goto"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["until"] = true,
    ["while"] = true,
}

local operators = {
    ["and"] = true,
    ["not"] = true,
    ["or"] = true,
    ["+"] = true,
    ["-"] = true,
    ["*"] = true,
    ["/"] = true,
    ["%"] = true,
    ["^"] = true,
    ["#"] = true,
    ["=="] = true,
    ["~="] = true,
    ["<="] = true,
    [">="] = true,
    ["<"] = true,
    [">"] = true,
    ["="] = true,
    ["("] = true,
    [")"] = true,
    ["{"] = true,
    ["}"] = true,
    ["["] = true,
    ["]"] = true,
    ["::"] = true,
    [";"] = true,
    [":"] = true,
    [","] = true,
    ["."] = true,
    [".."] = true,
}

local bitops = {
    ["&"] = true,
    ["~"] = true,
    ["|"] = true,
    ["<<"] = true,
    [">>"] = true,
    ["//"] = true,
}

local constants = {
    ["true"] = true,
    ["false"] = true,
    ["nil"] = true,
    ["..."] = true,
}

local function tokenize(state, text)
    local start = 1
    text = state.pending .. text
    state.pending = ""
    while true do
        local found = false
        for i, v in ipairs(classes_precedence) do
            local s, e, e2 = text:match(classes[v], start)
            if s then
                if v == "dquote" or v == "squote" then
                    local ok = true
                    while not s:gsub("\\.", ""):match(classes[v]) do
                        local s2
                        s2, e = text:match(classes[v], e - 1)
                        if not s2 then ok = false break end
                        s = s .. s2:sub(2)
                    end
                    if not ok then break end
                elseif v == "operator" and #s > 1 then
                    while not (operators[s] or s == "...") and #s > 1 do s, e = s:sub(1, -2), e - 1 end
                end
                if e2 then e = e2 end
                found = true
                state[#state+1] = {type = v, text = s, line = state.line, col = state.col}
                start = e
                local nl = select(2, s:gsub("\n", "\n"))
                if nl == 0 then
                    state.col = state.col + #s
                else
                    state.line = state.line + nl
                    state.col = #s:match("[^\n]*$")
                end
                break
            end
        end
        if not found then state.pending = text:sub(start) break end
    end
end

-- valid token types: operator, constant, keyword, string, number, name, whitespace, comment
local function reduce(state, version, trim)
    for _, v in ipairs(state) do
        if v.type == "operator" then
            if v.text == "..." then v.type = "constant"
            elseif not operators[v.text] and (version < 3 or not bitops[v.text]) then util_error(v.line, v.col, "invalid operator '" .. v.text .. "'") end
        elseif v.type == "name" then
            if keywords[v.text] then v.type = "keyword"
            elseif operators[v.text] then v.type = "operator"
            elseif constants[v.text] then v.type = "constant" end
        elseif v.type == "dquote" or v.type == "squote" or v.type == "blockquote" or v.type == "emptyblockquote" then v.type = "string"
        elseif v.type == "linecomment" or v.type == "blockcomment" or v.type == "emptyblockcomment" then v.type = "comment"
        elseif v.type == "hexnumber" or v.type == "scinumber" or v.type == "scihexnumber" then v.type = "number"
        elseif v.type == "invalid" then util_error(v.line, v.col, "invalid characters") end
    end
    if trim then
        local retval = {}
        for _, v in ipairs(state) do
            if v.type == "number" and retval[#retval].type == "operator" and retval[#retval].text == "-" then
                local op = retval[#retval-1]
                if (op.type == "operator" and op.text ~= "}" and op.text ~= "]" and op.text ~= ")") or (op.type == "keyword" and op.text ~= "end") then
                    v.text = "-" .. v.text
                    retval[#retval] = nil
                end
            end
            if v.type ~= "whitespace" and (trim ~= 2 or v.type ~= "comment") then retval[#retval+1] = v end
        end
        return retval
    end
    state.pending, state.line, state.col = nil
    return state
end

local function lex(reader, version, trim)
    if type(reader) == "string" then
        local data = reader
        function reader() local d = data data = nil return d end
    end
    local state = {pending = "", line = 1, col = 1}
    while true do
        local data = reader()
        if not data then break end
        tokenize(state, data)
    end
    if state.pending ~= "" then util_error(state.line, state.col, "unfinished string") end
    return reduce(state, version, trim)
end

return lex