local lex = require "lex"
local lz77 = require "lz77"
local freq = {
    ["\"\""] = 0,
    ["\"string\""] = 0,
    ["\"number\""] = 0,
    ["\"boolean\""] = 0,
    ["\"nil\""] = 0,
    ["\"function\""] = 0,
    ["\"table\""] = 0,
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
    ["0"] = 0,
    ["1"] = 0,
    ["2"] = 0,
    ["-1"] = 0,
    [":end"] = 1,
}
local function scan(dir)
    for _, p in ipairs(fs.list(dir)) do
        local path = fs.combine(dir, p)
        if fs.isDir(path) then scan(path)
        elseif path:match "%.lua$" then
            local file = assert(fs.open(path, "r"))
            local data = file.readAll()
            file.close()
            if load(data) then
                local ok, res = pcall(lex, data, 1, 2)
                if ok then
                    print(path, #res)
                    res = lz77(res)
                    print(path, #res)
                    for _, v in ipairs(res) do
                        v.text = v.text:gsub("'", '"')
                        if freq[v.text] or v.type == "keyword" or v.type == "operator" or v.type == "constant" then
                            freq[v.text] = (freq[v.text] or 0) + 1
                        else
                            freq[":" .. v.type] = (freq[":" .. v.type] or 0) + 1
                        end
                    end
                end
            end
        end
    end
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
local map, lengths, tree = require "maketree"(out)
file = fs.open(shell.resolve("token_encode_map.lua"), "w")
file.write(("-- AUTOGENERATED\nreturn %s"):format(textutils.serialize(map)))
file.close()
file = fs.open(shell.resolve("token_decode_tree.lua"), "w")
file.write(("-- AUTOGENERATED\nreturn %s"):format(textutils.serialize(tree, {compact = true}):gsub(",}", "}")))
file.close()
