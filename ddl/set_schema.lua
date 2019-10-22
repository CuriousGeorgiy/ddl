#!/usr/bin/env tarantool

local ddl_check_schema = require('ddl.check_schema')

local function _set_index(box_space, ddl_index)
    if ddl_index.func ~= nil then
        box.schema.func.create(ddl_index.func.name, {
            body = ddl_index.func.body,
            is_deterministic = ddl_index.func.is_deterministic,
            is_sandboxed = ddl_index.is_sandboxed,
            opts = ddl_index.func.opts,
        })
    end

    if ddl_index.parts == nil then
        error('Error: index parts is nil', 0)
    end

    local index_parts = {}
    for _, ddl_index_part in ipairs(ddl_index.parts) do
        local index_part = {
            ddl_index_part.path, ddl_index_part.type,
            is_nullable = ddl_index_part.is_nullable, collation = ddl_index_part.collation,
        }
        table.insert(index_parts, index_part)
    end

    local sequence_name = nil
    if ddl_index.sequence ~= nil then
        local sequence = box.schema.sequence.create(ddl_index.sequence)
        sequence_name = sequence.name
    end

    box_space:create_index(ddl_index.name, {
        type = ddl_index.type,
        unique = ddl_index.unique,
        parts = index_parts,
        seuence = sequence_name,
        dimension = ddl_index.dimension,
        distance = ddl_index.distance,
        func = ddl_index.func and ddl_index.func.name,
    })
    return true
end

local function _set_space(space_name, space)
    local box_space = box.schema.space.create(space_name, {
        engine = space.engine,
        is_local = space.is_local,
        temporary = space.temporary,
        format = space.format,
    })

    if space.indexes == nil then
        error('Error: Index fields is nil', 0)
    end

    for _, index in ipairs(space.indexes) do
        _set_index(box_space, index)
    end
    return true
end

local function transactional_apply_v2(spaces)
    box.begin()
    for space_name, space in pairs(spaces) do
        local status, data = pcall(_set_space, space_name, space)
        if not status then
            box.rollback()
            return nil, tostring(data)
        end
    end

    if box.is_in_txn() then
        box.commit()
    end

    return true
end

local function transactional_apply_v1(spaces)
    local boxes_drop = function(space_names)
        for _, space_name in ipairs(space_names) do
            box.space[space_name]:drop()
        end
    end

    local applied_spaces = {}
    for space_name, space in pairs(spaces) do
        local status, err = pcall(_set_space, space_name, space)
        if not status then
            boxes_drop(applied_spaces)
            return nil, err
        end
        table.insert(applied_spaces, space_name)
    end
end

local function set_schema(schema)
    if type(schema) ~= 'table' then
        error('Bad argument #1 to ddl.set_schema' ..
            ' (table expected, got ' .. type(schema) .. ')',
        2)
    end

    local res, err = ddl_check_schema.check_schema(schema)
    if not res then
        return nil, err
    end

    -- local version = require('tarantool').version

    -- local t_major = version:match('^(%d+)%.')
    -- t_major = tonumber(t_major)

    -- if t_major >= 2 then
        -- return transactional_apply_v2(spaces)
    -- else
        return transactional_apply_v1(schema)
    -- end
end


return {
    -- set_space = _set_space,
    set_schema = set_schema,
}
