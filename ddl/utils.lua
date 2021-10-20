local ffi = require('ffi')
local bit = require('bit')
local uuid = require('uuid')

local db = require('ddl.db')

-- copy from LuaJIT lj_char.c
local lj_char_bits = {
    0,
    1,  1,  1,  1,  1,  1,  1,  1,  1,  3,  3,  3,  3,  3,  1,  1,
    1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,
    2,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,
    152,152,152,152,152,152,152,152,152,152,  4,  4,  4,  4,  4,  4,
    4,176,176,176,176,176,176,160,160,160,160,160,160,160,160,160,
    160,160,160,160,160,160,160,160,160,160,160,  4,  4,  4,  4,132,
    4,208,208,208,208,208,208,192,192,192,192,192,192,192,192,192,
    192,192,192,192,192,192,192,192,192,192,192,  4,  4,  4,  4,  1,
    128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,
    128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,
    128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,
    128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,
    128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,
    128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,
    128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,
    128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128
}

local LJ_CHAR_IDENT = 0x80
local LJ_CHAR_DIGIT = 0x08

local LUA_KEYWORDS = {
    ['and'] = true,
    ['end'] = true,
    ['in'] = true,
    ['repeat'] = true,
    ['break'] = true,
    ['false'] = true,
    ['local'] = true,
    ['return'] = true,
    ['do'] = true,
    ['for'] = true,
    ['nil'] = true,
    ['then'] = true,
    ['else'] = true,
    ['function'] = true,
    ['not'] = true,
    ['true'] = true,
    ['elseif'] = true,
    ['if'] = true,
    ['or'] = true,
    ['until'] = true,
    ['while'] = true,
}

local function deepcmp(got, expected, extra)
    if extra == nil then
        extra = {}
    end

    if type(expected) == "number" or type(got) == "number" then
        extra.got = got
        extra.expected = expected
        if got ~= got and expected ~= expected then
            return true -- nan
        end
        return got == expected
    end

    if ffi.istype('bool', got) then got = (got == 1) end
    if ffi.istype('bool', expected) then expected = (expected == 1) end
    if got == nil and expected == nil then return true end

    if type(got) ~= type(expected) then
        extra.got = type(got)
        extra.expected = type(expected)
        return false
    end

    if type(got) ~= 'table' then
        extra.got = got
        extra.expected = expected
        return got == expected
    end

    local path = extra.path or '/'

    for i, v in pairs(got) do
        extra.path = path .. '/' .. i
        if not deepcmp(v, expected[i], extra) then
            return false
        end
    end

    for i, v in pairs(expected) do
        extra.path = path .. '/' .. i
        if not deepcmp(got[i], v, extra) then
            return false
        end
    end

    extra.path = path

    return true
end

local function find_first_duplicate(arr_objects, object_field)
    local key_map = {}
    for _, object in ipairs(arr_objects) do
        local key = object[object_field]
        if key_map[key] ~= nil then
            return key
        end
        key_map[key] = true
    end
    return nil
end

local function table_find(table, value)
    for k, v in pairs(table) do
        if v == value then
            return k
        end
    end

    return nil
end

local function is_array(data)
    if type(data) ~= 'table' then
        return false
    end

    local i = 0
    for _, _ in pairs(data) do
        i = i + 1
        if type(data[i]) == 'nil' then
            return false
        end
    end

    return true
end

local function redundant_key(tbl, known_keys)
    for k, _ in pairs(tbl) do
        if not table_find(known_keys, k) then
            return k
        end
    end

    return nil
end

local function lj_char_isident(n)
    return bit.band(lj_char_bits[n + 2], LJ_CHAR_IDENT) == LJ_CHAR_IDENT
end

local function lj_char_isdigit(n)
    return bit.band(lj_char_bits[n + 2], LJ_CHAR_DIGIT) == LJ_CHAR_DIGIT
end

local function is_callable(object)
    if type(object) == 'function' then
        return true
    end

    -- all objects with type `cdata` are allowed
    -- because there is no easy way to get
    -- metatable.__call of object with type `cdata`
    if type(object) == 'cdata' then
        return true
    end

    local object_metatable = getmetatable(object)
    if (type(object) == 'table' or type(object) == 'userdata') then
        -- if metatable type is not `table` -> metatable is protected ->
        -- cannot detect metamethod `__call` exists
        if object_metatable and type(object_metatable) ~= 'table' then
            return true
        end

        -- `__call` metamethod can be only the `function`
        -- and cannot be a `table` | `userdata` | `cdata`
        -- with `__call` methamethod on its own
        if object_metatable and object_metatable.__call then
            return type(object_metatable.__call) == 'function'
        end
    end

    return false
end

local field_type_sample ={
    any = 0,
    array = {1, 2, 3, 4, 5},
    boolean = true,
    double = 1.2345,
    integer = 12345,
    map = {a = 5, b = 6},
    number = tonumber64('18446744073709551615'),
    scalar = 12345,
    string = 'string',
    unsigned = 12345,
    uuid = uuid.new(),
    --varbinary = , -- is it possible to create a varbinary sample?
}
if db.decimal_allowed() then
    field_type_sample.decimal = require('decimal').new(1)
end

-- Build a map with field names as a keys and fieldno's
-- as a values using space format as a source.
local function get_format_field_map(space_format)
    local field_map = {}
    for _, field_param in ipairs(space_format) do
        field_map[field_param.name] = field_param
    end
    return field_map
end

-- Generate sharding key sample using space format.
-- Return a sharding key (array) or nil.
local function generate_sharding_key(space_format, sharding_key_def)
    if space_format == nil then
        return nil
    end
    local space_format_field_map = get_format_field_map(space_format)
    local sharding_key = {}
    for _, field_name in ipairs(sharding_key_def) do
        -- Do we need process is_nullable?
        local field_param = space_format_field_map[field_name]
        local field_type = field_param.type
        local sample = field_type_sample[field_type]
        if sample == nil then
            -- Not enough samples to generate sharding key.
            return nil
        end
        table.insert(sharding_key, sample)
    end

    return sharding_key
end

return {
    deepcmp = deepcmp,
    is_array = is_array,
    is_callable = is_callable,
    redundant_key = redundant_key,
    find_first_duplicate = find_first_duplicate,
    lj_char_isident = lj_char_isident,
    lj_char_isdigit = lj_char_isdigit,
    LUA_KEYWORDS = LUA_KEYWORDS,
    generate_sharding_key = generate_sharding_key,
}
