local lex = require "lex"
local minify = require "minify"
local compress = require "compress"
local decompress = require "decompress"

local function printUsage()
    print[[Usage: luz [options] <input> [output]
Options:
  -c       Force compression
  -d       Force decompression
  -l <num> Compression level (0-15)
  -m       Minify before compression (experimental)
  -r       Run compressed file
  --help   Show this help
]]
end

local args, input, output = {}
local mode, level
local min = false
local nextArg
for _, arg in ipairs{...} do
    if nextArg then
        if nextArg == 1 then level = 2^tonumber(arg) end
        nextArg = nil
    elseif arg:sub(1, 2) == "--" then
        if arg == "--help" then return printUsage() end
    elseif arg:sub(1, 1) == "-" then
        for c in arg:sub(2):gmatch(".") do
            if c == "c" then mode = 1
            elseif c == "d" then mode = 2
            elseif c == "l" then nextArg = 1
            elseif c == "r" then mode = 3
            elseif c == "m" then min = true end
        end
    elseif not input then input = arg
    elseif not output then output = arg
    else args[#args+1] = arg end
end
if not input then return printUsage() end
if mode == 3 then table.insert(args, 1, output) output = nil end

if shell then input, output = shell.resolve(input), output and shell.resolve(output) end

local file = assert(io.open(input, "rb"))
local data = file:read("*a")
file:close()
if not mode then mode = data:sub(1, 5) == "\27LuzQ" and 2 or 1 end
local canload = pcall(load, "")

if mode == 3 then
    local decomp = decompress(data)
    return assert((canload and load or loadstring)(decomp, "@" .. input, "t", _ENV))((table.unpack or unpack)(args))
elseif mode == 2 then
    output = output or (input .. ".lua")
    local decomp = decompress(data)
    file = assert(io.open(output, "w"))
    file:write(decomp)
    file:close()
else
    output = output or (input .. ".luz")
    assert((canload and load or loadstring)(data))
    local tokens = lex(data, 1, 2)
    if min then tokens = minify(tokens) end
    local compressed = compress(tokens, level)
    file = assert(io.open(output, "wb"))
    file:write(compressed)
    file:close()
    print(input .. ": " .. #data .. " => " .. #compressed)
end