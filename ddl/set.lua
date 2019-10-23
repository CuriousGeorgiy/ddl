#!/usr/bin/env tarantool

local function create_index(box_space, ddl_index)
    -- if ddl_index.func ~= nil then
    --     box.schema.func.create(ddl_index.func.name, {
    --         body = ddl_index.func.body,
    --         is_deterministic = ddl_index.func.is_deterministic,
    --         is_sandboxed = ddl_index.is_sandboxed,
    --         opts = ddl_index.func.opts,
    --     })
    -- end

    if ddl_index.parts == nil then
        error('index parts is nil')
    end

    local index_parts = {}
    for _, ddl_index_part in ipairs(ddl_index.parts) do
        local index_part = {
            ddl_index_part.path, ddl_index_part.type,
            is_nullable = ddl_index_part.is_nullable,
            collation = ddl_index_part.collation,
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

local function create_space(space_name, space_schema)
    local box_space = box.schema.space.create(space_name, {
        engine = space_schema.engine,
        is_local = space_schema.is_local,
        temporary = space_schema.temporary,
        format = space_schema.format,
    })

    if space_schema.indexes == nil then
        error('Index fields is nil')
    end

    for _, index in ipairs(space_schema.indexes) do
        create_index(box_space, index)
    end
    return true
end

return {
    create_space = create_space,
}