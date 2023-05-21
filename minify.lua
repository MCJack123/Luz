local nametext = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
local function mkname(n)
    local s = ""
    while n >= 52 do s, n = s .. nametext:sub(n % 52 + 1, n % 52 + 1), math.floor(n / 52) end
    return nametext:sub(n % 52 + 1, n % 52 + 1) .. s:reverse()
end

local function parseexp(tokens, upvalues, start, retval)
    -- local v = tokens[start]
    -- if v.type == "constant" or v.type == "string" or v.type == "number" then
    --     retval[start] = v
        
    -- end
    error("Not implemented yet")
    return retval, start
end

local function minify(tokens, upvalues, start, nextname)
    start = start or 1
    nextname = nextname or 0
    local locals = setmetatable({}, {__index = upvalues or {}})
    local state = 1
    local retval = {}
    while start <= #tokens do
        local v = tokens[start]
        if state == 1 then -- normal
            if v.type == "keyword" then
                retval[start] = v
                if v.text == "do" or v.text == "then" then
                    local t, s = minify(tokens, locals, start + 1, nextname)
                    for i = start + 1, s do retval[i] = t[i] end
                    start = s
                elseif v.text == "until" then
                    return parseexp(tokens, locals, start + 1, retval)
                elseif v.text == "function" then
                    local onn = nextname
                    if tokens[start+1].type == "name" then
                        start = start + 1
                        if locals[tokens[start].text] then retval[start] = {col = v.col, line = v.line, type = "name", text = locals[tokens[start].text]}
                        else retval[start] = tokens[start] end
                    end
                    start = start + 1
                    retval[start] = tokens[start]
                    start = start + 1
                    v = tokens[start]
                    local params = setmetatable({}, {__index = locals})
                    while v.type ~= "operator" or v.text ~= ")" do
                        if v.type == "name" then
                            params[v.text] = mkname(nextname)
                            nextname = nextname + 1
                            retval[start] = {col = v.col, line = v.line, type = "name", text = params[v.text]}
                        else retval[start] = v end
                        start = start + 1
                        v = tokens[start]
                    end
                    retval[start] = v
                    local t, s = minify(tokens, params, start + 1, nextname)
                    for i = start + 1, s do retval[i] = t[i] end
                    start = s
                    nextname = onn
                elseif v.text == "local" or v.text == "for" then
                    state = 3
                elseif v.text == "end" then
                    return retval, start
                end
            elseif v.type == "name" then
                if locals[v.text] then retval[start] = {col = v.col, line = v.line, type = "name", text = locals[v.text]}
                else retval[start] = v end
            elseif v.type == "operator" then
                retval[start] = v
                if v.text == "." or v.text == ":" then state = 2 end
            else
                retval[start] = v
            end
        elseif state == 2 then -- prefixexp
            retval[start] = v
            if not ((v.type == "operator" and (v.text == "." or v.text == ":") or v.type == "name")) then state = 1 end
        elseif state == 3 then -- local
            if v.type == "keyword" and v.text == "function" then
                v = retval[start + 1]
                locals[v.text] = mkname(nextname)
                nextname = nextname + 1
                retval[start] = {col = v.col, line = v.line, type = "name", text = locals[v.text]}
                local onn = nextname
                start = start + 2
                retval[start] = tokens[start]
                start = start + 1
                v = tokens[start]
                local params = setmetatable({}, {__index = locals})
                while v.type ~= "operator" or v.text ~= ")" do
                    if v.type == "name" then
                        params[v.text] = mkname(nextname)
                        nextname = nextname + 1
                        retval[start] = {col = v.col, line = v.line, type = "name", text = params[v.text]}
                    else retval[start] = v end
                    start = start + 1
                    v = tokens[start]
                end
                retval[start] = v
                local t, s = minify(tokens, params, start + 1, nextname)
                for i = start + 1, s do retval[i] = t[i] end
                start = s
                nextname = onn
            elseif v.type == "name" then
                locals[v.text] = mkname(nextname)
                nextname = nextname + 1
                retval[start] = {col = v.col, line = v.line, type = "name", text = locals[v.text]}
                state = 4
            else error("invalid local statement") end
        elseif state == 4 then -- local follow
            if v.type == "operator" and v.text == "," then
                state = 3
                retval[start] = v
            else
                state = 1
                start = start - 1
            end
        end
        start = start + 1
    end
    return retval, #tokens
end

return minify