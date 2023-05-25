local maketree = require "maketree"
local Gtokens = require "tokens"

local function findname(token, locals, upvalues, globals)
    local name = token.text
    if Gtokens[name] then return
    elseif locals[name] then
        locals[name] = locals[name] + 1
        token.type = "local"
    else
        for i, v in ipairs(upvalues) do
            if v[name] then
                v[name] = v[name] + 1
                if i == 1 or i == 2 or i == 3 then token.type = "upvalue" .. i
                else token.type, token.level = "upvalue", i end
                return
            end
        end
        globals[name] = (globals[name] or 0) + 1
        token.type = "global"
    end
end

local body, func, tbl, exp

function func(tokens, locals, upvalues, globals, fields, functions, start, v)
    table.insert(upvalues, 1, locals)
    if tokens[start+1].type == "name" then
        start = start + 1
        findname(tokens[start], {}, upvalues, globals)
        while tokens[start+1].type == "operator" and (tokens[start+1].text == "." or tokens[start+1].text == ":" or tokens[start+1].text == "[") do
            if tokens[start+1].text == "[" then
                start = exp(tokens, locals, upvalues, globals, fields, functions, start + 2, {["]"] = true})
            else
                start = start + 2
                if tokens[start-2].type == "global" and (tokens[start-2].text == "_G" or tokens[start-2].text == "_ENV") then
                    globals[tokens[start].text] = (globals[tokens[start].text] or 0) + 1
                    tokens[start].type = "global"
                else
                    fields[tokens[start].text] = (fields[tokens[start].text] or 0) + 1
                    tokens[start].type = "field"
                end
            end
        end
    end
    start = start + 2
    local params = {}
    while tokens[start].type ~= "operator" or tokens[start].text ~= ")" do
        if tokens[start].type == "name" then
            params[tokens[start].text] = 1
            tokens[start].type = "local"
        end
        start = start + 1
    end
    --print("enter", v.line)
    local s = body(tokens, params, upvalues, globals, fields, functions, start + 1)
    --print("exit", tokens[s].line)
    table.remove(upvalues, 1)
    local freq = {}
    for k, w in pairs(params) do freq[#freq+1] = {k, w} end
    if #freq > 0 then
        v.locals = {list = freq}
        functions[#functions+1] = v
    end
    return s
end

function tbl(tokens, locals, upvalues, globals, fields, functions, start)
    while start <= #tokens do
        local v = tokens[start]
        --print("tbl", #upvalues, v.type, v.text, v.line)
        if v.type == "name" then
            if tokens[start+1].type == "operator" and tokens[start+1].text == "=" then
                fields[v.text] = (fields[v.text] or 0) + 1
                v.type = "field"
            else
                start = exp(tokens, locals, upvalues, globals, fields, functions, start, {[","] = true, [";"] = true, ["}"] = true})
                if tokens[start].type == "operator" and tokens[start].text == "}" then return start end
            end
        elseif v.type == "operator" then
            if v.text == "[" then start = exp(tokens, locals, upvalues, globals, fields, functions, start + 1, {["]"] = true})
            elseif v.text == "{" then start = tbl(tokens, locals, upvalues, globals, fields, functions, start + 1)
            elseif v.text == "}" then return start
            elseif v.text ~= "," and v.text ~= ";" then
                start = exp(tokens, locals, upvalues, globals, fields, functions, start, {[","] = true, [";"] = true, ["}"] = true})
                if tokens[start].type == "operator" and tokens[start].text == "}" then return start end
            end
        elseif v.type == "keyword" and v.text ~= "function" then error("unexpected keyword " .. v.text)
        else
            start = exp(tokens, locals, upvalues, globals, fields, functions, start, {[","] = true, [";"] = true, ["}"] = true})
            if tokens[start].type == "operator" and tokens[start].text == "}" then return start end
        end
        start = start + 1
    end
    return #tokens
end

function exp(tokens, locals, upvalues, globals, fields, functions, start, stop)
    while start <= #tokens do
        local v = tokens[start]
        --print("exp", #upvalues, v.type, v.text, v.line)
        if stop[v.text] then return start
        elseif v.type == "name" then findname(v, locals, upvalues, globals)
        elseif v.type == "operator" then
            if v.text == "(" then start = exp(tokens, locals, upvalues, globals, fields, functions, start + 1, {[")"] = true})
            elseif v.text == "[" then start = exp(tokens, locals, upvalues, globals, fields, functions, start + 1, {["]"] = true})
            elseif v.text == "{" then start = tbl(tokens, locals, upvalues, globals, fields, functions, start + 1)
            elseif v.text == "." or v.text == ":" then
                start = start + 1
                if tokens[start-2].type == "global" and (tokens[start-2].text == "_G" or tokens[start-2].text == "_ENV") then
                    globals[tokens[start].text] = (globals[tokens[start].text] or 0) + 1
                    tokens[start].type = "global"
                else
                    fields[tokens[start].text] = (fields[tokens[start].text] or 0) + 1
                    tokens[start].type = "field"
                end
            end
        elseif v.type == "keyword" then
            if v.text == "function" then start = func(tokens, locals, upvalues, globals, fields, functions, start, v)
            else return start - 1 end
        end
        start = start + 1
    end
    return #tokens
end

function body(tokens, locals, upvalues, globals, fields, functions, start)
    --if #upvalues == 100 then error(debug.traceback("too many levels")) end
    local state = 1
    local numends = 1
    while start <= #tokens do
        local v = tokens[start]
        --print("body", #upvalues, numends, state, v.type, v.text, v.line)
        if state == 1 then -- normal
            if v.type == "keyword" then
                if v.text == "do" or v.text == "then" then
                    numends = numends + 1
                elseif v.text == "for" then
                    state = 2
                elseif v.text == "function" then
                    start = func(tokens, locals, upvalues, globals, fields, functions, start, v)
                elseif v.text == "local" then
                    state = 3
                elseif v.text == "end" or v.text == "elseif" then
                    numends = numends - 1
                    if numends <= 0 then return start end
                end
            elseif v.type == "name" then
                findname(v, locals, upvalues, globals)
            elseif v.type == "operator" then
                if v.text == "." or v.text == ":" then
                    start = start + 1
                    fields[tokens[start].text] = (fields[tokens[start].text] or 0) + 1
                    tokens[start].type = "field"
                elseif v.text == "(" then start = exp(tokens, locals, upvalues, globals, fields, functions, start + 1, {[")"] = true})
                elseif v.text == "[" then start = exp(tokens, locals, upvalues, globals, fields, functions, start + 1, {["]"] = true})
                elseif v.text == "{" then start = tbl(tokens, locals, upvalues, globals, fields, functions, start + 1) end
            end
        elseif state == 2 then -- for
            if v.type == "name" then
                locals[v.text] = 1
                v.type = "local"
            elseif (v.type == "operator" and v.text == "=") or (v.type == "keyword" and v.text == "in") then
                state = 1
            elseif v.type ~= "operator" or v.text ~= "," then error("invalid for statement (" .. v.line .. ":" .. v.col .. ")") end
        elseif state == 3 then -- local
            if v.type == "keyword" and v.text == "function" then
                locals[tokens[start+1].text] = 1
                start = func(tokens, locals, upvalues, globals, fields, functions, start, v)
                state = 1
            elseif v.type == "name" then
                locals[v.text] = 1
                v.type = "local"
                state = 4
            else error("invalid local statement") end
        elseif state == 4 then -- local follow
            if v.type == "operator" and v.text == "," then
                state = 3
            else
                state = 1
                start = start - 1
            end
        end
        start = start + 1
    end
    return #tokens
end

return function(tokens)
    local retval, freq, globals, fields, locals, functions = {}, {}, {}, {}, {}, {}
    body(tokens, locals, {}, globals, fields, functions, 1)
    -- reduce common locals into global names
    for _, v in ipairs(functions) do for _, w in ipairs(v.locals.list) do freq[w[1]] = (freq[w[1]] or 0) + 1 end end
    local locallist = {}
    for k, v in pairs(freq) do locallist[#locallist+1] = {k, v} end
    table.sort(locallist, function(a, b) return a[2] > b[2] end)
    local numremoved = 0
    for _, x in ipairs(locallist) do
        local k, n = x[1], x[2]
        if n > 10 + numremoved then
            local count = 0
            for _, v in ipairs(functions) do for i, w in ipairs(v.locals.list) do if w[1] == k then
                count = count + w[2]
                table.remove(v.locals.list, i)
                break
            end end end
            for _, v in ipairs(tokens) do if v.text == k and (v.type == "local" or v.type:find "^upvalue") then v.type = "global" end end
            globals[k] = count
            numremoved = numremoved + 1
        end
    end
    for _, v in ipairs(functions) do
        if #v.locals.list > 0 then
            v.locals.map, v.locals.len = maketree(v.locals.list)
            v.locals.maxlen = 0
            for _, w in ipairs(v.locals.len) do v.locals.maxlen = math.max(v.locals.maxlen, w) end
            v.locals.maxlen = select(2, math.frexp(v.locals.maxlen))
        else v.locals = nil end
    end
    freq = {}
    for k, w in pairs(globals) do freq[#freq+1] = {k, w} end
    if #freq > 0 then
        retval.globals = {list = freq}
        retval.globals.map, retval.globals.len = maketree(freq)
        retval.globals.maxlen = 0
        for _, v in ipairs(retval.globals.len) do retval.globals.maxlen = math.max(retval.globals.maxlen, v) end
        retval.globals.maxlen = select(2, math.frexp(retval.globals.maxlen))
    end
    freq = {}
    for k, w in pairs(fields) do freq[#freq+1] = {k, w} end
    if #freq > 0 then
        retval.fields = {list = freq}
        retval.fields.map, retval.fields.len = maketree(freq)
        retval.fields.maxlen = 0
        for _, v in ipairs(retval.fields.len) do retval.fields.maxlen = math.max(retval.fields.maxlen, v) end
        retval.fields.maxlen = select(2, math.frexp(retval.fields.maxlen))
    end
    freq = {}
    for k, w in pairs(locals) do freq[#freq+1] = {k, w} end
    if #freq > 0 then
        retval.locals = {list = freq}
        retval.locals.map, retval.locals.len = maketree(freq)
        retval.locals.maxlen = 0
        for _, v in ipairs(retval.locals.len) do retval.locals.maxlen = math.max(retval.locals.maxlen, v) end
        retval.locals.maxlen = select(2, math.frexp(retval.locals.maxlen))
    end
    return retval
end