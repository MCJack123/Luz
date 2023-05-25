local combined_tokens = {
    {"}", ",", "{"},
    {"+", "1"},
    {"-", "1"},
    {"{", "}"},
    {"(", ")"},
    {"[", "0", "]", "="},
    {"]", "="},
    {"function", "("},
    {"local", "function", space = true},
    {"=", "nil"},
    {"==", "nil"},
    {"~=", "nil"},
    {"...", ")"},
    {"then", "return", space = true},
    {"then", "error", space = true},
    {"for", "_", ",", space = true},
    {"break", "end", space = true},
    {"end", "end", space = true},
    {"while", "true", "do", space = true}
}

local function reduce(tokens)
    local retval = {}
    local i = 1
    while i <= #tokens do
        local found = false
        for _, v in ipairs(combined_tokens) do
            if i <= #tokens - #v + 1 then
                local ok, locals = true, nil
                for j, t in ipairs(v) do if tokens[i+j-1].text ~= t then ok = false break elseif tokens[i+j-1].locals then locals = tokens[i+j-1].locals end end
                if ok then
                    found = true
                    retval[#retval+1] = {type = "combined", text = table.concat(v, v.space and " " or ""), locals = locals}
                    i = i + #v
                    break
                end
            end
        end
        if not found then
            -- look back/forward for #(name)[(name)+1]=
            -- a . b [ # a . b + 1 ] =
            if tokens[i].type == "operator" and tokens[i].text == "[" and tokens[i+1].type == "operator" and tokens[i+1].text == "#" then
                for j = 1, 16 do
                    if not tokens[i+j+5] then break end
                    if tokens[i+j+2].type == "operator" and tokens[i+j+2].text == "+" and
                        tokens[i+j+3].type == "number" and tokens[i+j+3].text == "1" and
                        tokens[i+j+4].type == "operator" and tokens[i+j+4].text == "]" and
                        tokens[i+j+5].type == "operator" and tokens[i+j+5].text == "=" then
                        local ok = true
                        for k = 1, j do
                            --print(tokens[i+k+1].text, tokens[i-j+k-1].text)
                            if tokens[i+k+1].type ~= tokens[i-j+k-1].type or tokens[i+k+1].text ~= tokens[i-j+k-1].text then ok = false break end
                        end
                        if ok then
                            retval[#retval+1] = {type = "append", text = "", len = j-1}
                            i = i + j + 6
                            found = true
                            break
                        end
                    end
                end
            end
            if not found then
                retval[#retval+1] = tokens[i]
                i = i + 1
            end
        end
    end
    return retval
end

return reduce