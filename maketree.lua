local function leafcomp(a, b) return a.weight > b.weight end
local function sortcodes(symbolMap)
    if symbolMap then return function(a, b) if a.bits == b.bits then return symbolMap[a.symbol] < symbolMap[b.symbol] else return a.bits < b.bits end end
    else return function(a, b) if a.bits == b.bits then return a.symbol < b.symbol else return a.bits < b.bits end end end
end

local function loadcodes(node, codes, map, partial)
    if node.data then
        partial.symbol = node.data
        map[node.data] = partial
        codes[#codes+1] = partial
    else
        loadcodes(node[1], codes, map, {bits = partial.bits + 1, code = partial.code * 2})
        loadcodes(node[2], codes, map, {bits = partial.bits + 1, code = partial.code * 2 + 1})
    end
end

-- takes a list of {symbol, weight} entries
-- returns a key-value map of symbol to {bits: number, code: number}, the names and lengths of each code in the input order, and a decoding tree (1-indexed!)
-- if there are 0 entries, returns nil
-- if there is 1 entry, returns false + the index of the identifier
local function maketree(histogram, symbolMap)
    -- make initial tree
    local queue = {}
    for i, v in ipairs(histogram) do if v[2] > 0 then queue[#queue+1] = {data = v[1], weight = v[2]} end end
    if #queue == 0 then
        return nil
    elseif #queue == 1 then
        for i, v in ipairs(histogram) do if v[1] == queue[1].data then return false, i end end
        return nil
    end
    table.sort(queue, leafcomp)
    while #queue > 1 do
        local a, b = queue[#queue-1], queue[#queue]
        local n = {weight = a.weight + b.weight, a, b}
        queue[#queue] = nil
        queue[#queue] = n
        table.sort(queue, leafcomp)
    end
    -- make canonical codebook
    local codes, map = {}, {}
    loadcodes(queue[1], codes, map, {bits = 0, code = 0})
    table.sort(codes, sortcodes(symbolMap))
    codes[1].code = 0
    for i = 2, #codes do codes[i].code = bit32.lshift(codes[i-1].code + 1, codes[i].bits - codes[i-1].bits) end
    local lengths = {}
    for i, v in ipairs(histogram) do lengths[i] = map[v[1]] and map[v[1]].bits or 0 end
    -- make decoding tree
    local tree = {}
    for _, v in ipairs(codes) do
        if v.bits == 1 then
            tree[v.code + 1] = v.symbol
        else
            local node = tree
            for n = v.bits - 1, 1, -1 do
                local dir = bit32.extract(v.code, n) + 1
                node[dir] = node[dir] or {}
                node = node[dir]
            end
            local dir = bit32.extract(v.code, 0) + 1
            node[dir] = v.symbol
        end
        v.symbol = nil
    end
    return map, lengths, tree
end

return maketree