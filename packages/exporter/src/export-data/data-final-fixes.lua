-- start util functions
local function table_merge(t1, t2)
    for k, v in pairs(t2) do
        t1[k] = v
    end
end

local function list_iter(t)
    local i = 0
    local n = #t
    return function()
        i = i + 1
        if i <= n then
            return t[i]
        end
    end
end

local function list_includes(t, v)
    for value in list_iter(t) do
        if value == v then
            return true
        end
    end
    return false
end

local function table_filter(t, blacklist)
    for key in pairs(t) do
        if list_includes(blacklist, key) then
            t[key] = nil
        end
    end
end

local function char_generator()
    local nextIndex = 0
    return function()
        local char = string.char(string.byte('a') + nextIndex)
        nextIndex = nextIndex + 1
        return char
    end
end

local function deep_copy(obj, seen)
    -- Handle non-tables and previously-seen tables.
    if type(obj) ~= 'table' then return obj end
    if seen and seen[obj] then return seen[obj] end

    -- New table; mark it as seen and copy recursively.
    local s = seen or {}
    local res = {}
    s[obj] = res
    for k, v in pairs(obj) do res[deep_copy(k, s)] = deep_copy(v, s) end
    return setmetatable(res, getmetatable(obj))
end

-- end util functions

local locale = require('locale')

local function localise(obj)
    local function resolve_key(key)
        if key == nil then
            log("nil string")
            log(serpent.block(obj))
        end
        local i = string.find(key, "%.")
        if i == nil then
            local s = locale[key]
            if s == nil then
                return key
            end
            return s
        end
        local section = string.sub(key, 1, i - 1)
        local item_key = string.sub(key, i + 1)
        return locale[section .. '.' .. item_key]
    end

    local function localiseWithSection(suffix)
        local locale_sections = { "item", "fluid", "virtual-signal", "recipe", "entity", "tile", "item-group",
            "equipment", "space-location", "surface" }
        local result = nil
        for _, prefix in ipairs(locale_sections) do
            local test = string.format("%s-%s.%s", prefix, suffix, obj.name)
            result = locale[test]
            if result ~= nil then
                break
            end
        end
        if result == nil then
            log(string.format("localizing '%s' failed:\n%s", suffix, serpent.block(obj)))
            -- error(string.format("something went wrong"))
        else
            return result
        end
    end

    local function localiseTemplate(t)
        local template_key = t[1]
        local args = t[2]
        local template = resolve_key(template_key)
        local literal = false
        if args == nil then
            return template;
        elseif type(args) ~= "table" then
            literal = true
            local new_args = {}
            for i = 2, #t do
                table.insert(new_args, t[i])
            end
            args = new_args
        end
        local format = string.gsub(template, "__(%d+)__", function(d)
            local key = args[tonumber(d)]
            if literal then
                return key
            else
                return resolve_key(key)
            end
        end)

        return format
    end

    if obj.localised_name ~= nil then
        obj.localised_name = localiseTemplate(obj.localised_name)
    else
        local str = localiseWithSection('name')
        if str ~= nil then
            obj.localised_name = str
        else
            --log(string.format("localized failed:\n%s", serpent.block(obj)))
            obj.localised_name = obj.name:gsub('^%l', string.upper):gsub('-', ' ')
        end
    end

    if obj.localised_description ~= nil then
        obj.localised_description = localiseTemplate(obj.localised_description)
    else
        local str = localiseWithSection('description')
        if str ~= nil then
            obj.localised_description = str
        end
    end

    if obj.limitation_message_key ~= nil then
        local str = localiseWithSection('limitation')
        if str ~= nil then
            obj.limitation_message = str
        end
        obj.limitation_message_key = nil
    end
end

local creativeEntities = {
    'loader',
    'fast-loader',
    'express-loader',
    'infinity-chest',
    'heat-interface',
    'infinity-pipe',
    'electric-energy-interface'
}

local output = {}

-- ITEMS
do
    local items = {}

    -- https://lua-api.factorio.com/latest/prototypes/ItemPrototype.html
    local itemPrototypes = {
        'ammo',
        'armor',
        'blueprint-book',
        'blueprint',
        'capsule',
        'copy-paste-tool',
        'deconstruction-item',
        'gun',
        'item-with-entity-data',
        'item',
        'module',
        'rail-planner',
        'repair-tool',
        'space-platform-starter-pack',
        'spidertron-remote',
        'tool',
        'upgrade-item',
    }

    local itemKeyBlacklist = {
        'ammo_type',
        'attack_parameters',
        'capsule_action',
        'durability_description_key',
        'durability_description_value',
        'flags',
        'pictures',
        'resistances',
        'robot_action'
    }

    local getOrder = char_generator()

    for proto in list_iter(itemPrototypes) do
        for _, item in pairs(deep_copy(data.raw[proto])) do
            if list_includes(creativeEntities, item.name) then
                item.subgroup = 'creative'
                item.order = getOrder()
                item.flags = nil
            end

            if (item.icon ~= nil or item.icons ~= nil) and not (item.flags ~= nil and list_includes(item.flags, 'hidden')) then
                localise(item, 'item')
                table_filter(item, itemKeyBlacklist)
                items[item.name] = item
            end
        end
    end

    output.items = items
end

-- FLUIDS
do
    local fluids = {}

    local fluidKeyBlacklist = {
        'auto_barrel'
    }

    for _, fluid in pairs(deep_copy(data.raw.fluid)) do
        localise(fluid, 'fluid')
        table_filter(fluid, fluidKeyBlacklist)
        fluids[fluid.name] = fluid
    end

    output.fluids = fluids
end

-- SIGNALS
do
    local signals = {}

    for _, signal in pairs(deep_copy(data.raw['virtual-signal'])) do
        localise(signal, 'virtual-signal')
        signals[signal.name] = signal
    end

    output.signals = signals
end

-- RECIPES
do
    local recipes = {}

    for _, recipe in pairs(deep_copy(data.raw.recipe)) do
        if not list_includes(creativeEntities, recipe.name) and not recipe.parameter then
            if recipe.normal ~= nil then
                table_merge(recipe, recipe.normal)
            end

            local ingredients = {}
            local results = {}

            local function process_items(input, output)
                if input == nil then
                    log("no ingredients for " .. recipe.name)
                end
                for _, val in pairs(input) do
                    if #val > 0 then
                        table.insert(output, {
                            name = val[1],
                            amount = val[2]
                        })
                    else
                        table.insert(output, val)
                    end
                end
            end

            process_items(recipe.ingredients, ingredients)

            if recipe.result ~= nil then
                results = {
                    {
                        name = recipe.result,
                        amount = recipe.result_count or 1
                    }
                }
            else
                process_items(recipe.results, results)
            end

            local outRecipe = {
                name = recipe.name,
                icon = recipe.icon,
                icons = recipe.icons,
                icon_size = recipe.icon_size,
                icon_mipmaps = recipe.icon_mipmaps,
                category = recipe.category or 'crafting',
                hidden = recipe.hidden,
                time = recipe.energy_required or 0.5,
                ingredients = ingredients,
                results = results,
                requester_paste_multiplier = recipe.requester_paste_multiplier,
                crafting_machine_tint = recipe.crafting_machine_tint
            }

            localise(outRecipe, 'recipe')
            recipes[recipe.name] = outRecipe
        end
    end

    output.recipes = recipes
end

--ENTITIES
do
    local entities = {}

    -- https://lua-api.factorio.com/latest/prototypes/EntityWithOwnerPrototype.html
    local placeableEntityPrototypes = {
        'accumulator',
        'agricultural-tower',
        'artillery-turret',
        'asteroid-collector',
        'asteroid',
        'beacon',
        'boiler',
        'burner-generator',
        'cargo-bay',
        'cargo-landing-pad',
        'cargo-pod',
        'character',
        'arithmetic-combinator',
        'decider-combinator',
        'selector-combinator',
        'constant-combinator',
        'container',
        'logistic-container',
        'infinity-container',
        'temporary-container',
        'assembling-machine',
        'rocket-silo',
        'furnace',
        'display-panel',
        'electric-energy-interface',
        'electric-pole',
        'unit-spawner',
        'capture-robot',
        'combat-robot',
        'construction-robot',
        'logistic-robot',
        'fusion-generator',
        'fusion-reactor',
        'gate',
        'generator',
        'heat-interface',
        'heat-pipe',
        'inserter',
        'lab',
        'lamp',
        'land-mine',
        'lightning-attractor',
        'linked-container',
        'market',
        'mining-drill',
        'offshore-pump',
        'pipe',
        'infinity-pipe',
        'pipe-to-ground',
        'power-switch',
        'programmable-speaker',
        'pump',
        'radar',
        'curved-rail-a',
        'elevated-curved-rail-a',
        'curved-rail-b',
        'elevated-curved-rail-b',
        'half-diagonal-rail',
        'elevated-half-diagonal-rail',
        'legacy-curved-rail',
        'legacy-straight-rail',
        'rail-ramp',
        'straight-rail',
        'elevated-straight-rail',
        'rail-chain-signal',
        'rail-signal',
        'rail-support',
        'reactor',
        'roboport',
        'segment',
        'segmented-unit',
        'simple-entity-with-owner',
        'simple-entity-with-force',
        'solar-panel',
        'space-platform-hub',
        'spider-leg',
        'spider-unit',
        'storage-tank',
        'thruster',
        'train-stop',
        'lane-splitter',
        'linked-belt',
        'loader-1x1',
        'loader',
        'splitter',
        'transport-belt',
        'underground-belt',
        'turret',
        'ammo-turret',
        'electric-turret',
        'fluid-turret',
        'unit',
        'car',
        'artillery-wagon',
        'cargo-wagon',
        'fluid-wagon',
        'locomotive',
        'spider-vehicle',
        'wall',
    }

    local entityBlacklist = {
        'bait-chest',
        'compilatron-chest',
        'crash-site-chest-1',
        'crash-site-chest-2',
        'big-ship-wreck-1',
        'big-ship-wreck-2',
        'big-ship-wreck-3',
        'red-chest',
        'blue-chest',
        'compi-logistics-chest',
        'crash-site-assembling-machine-1-repaired',
        'crash-site-assembling-machine-2-repaired',
        'crash-site-generator',
        'hidden-electric-energy-interface',
        'crash-site-electric-pole',
        'crash-site-lab-repaired',
        'compi-roboport',
        'small-worm-turret',
        'medium-worm-turret',
        'big-worm-turret',
        'behemoth-worm-turret',
        'cutscene-gun-turret',
        'dummy-elevated-curved-rail-a',
        'dummy-elevated-curved-rail-b',
        'dummy-elevated-half-diagonal-rail',
        'dummy-rail-ramp',
        'dummy-elevated-straight-rail',
        'dummy-rail-support',
        'dummy-spider-unit',
    }

    local entityKeyBlacklist = {
        'subgroup',
        'repair_sound',
        'vehicle_impact_sound',
        'resistances',
        'action',
        'meltdown_action',
        'ammo_type',
        'attack_parameters',
        'fluid_wagon_connector_graphics',
        'cannon_base_shiftings',
        'cannon_barrel_recoil_shiftings',
        'folded_muzzle_animation_shift',
        'preparing_muzzle_animation_shift',
        'prepared_muzzle_animation_shift',
        'attacking_muzzle_animation_shift',
        'ending_attack_muzzle_animation_shift',
        'folding_muzzle_animation_shift'
    }

    for proto in list_iter(placeableEntityPrototypes) do
        for _, entity in pairs(deep_copy(data.raw[proto])) do
            if not list_includes(entityBlacklist, entity.name) then
                -- add size
                entity.size = {
                    width = math.ceil(math.abs(entity.selection_box[1][1]) + math.abs(entity.selection_box[2][1])),
                    height = math.ceil(math.abs(entity.selection_box[1][2]) + math.abs(entity.selection_box[2][2]))
                }

                -- add possible_rotations
                if list_includes({
                        'pipe-to-ground',
                        'train-stop',
                        'arithmetic-combinator',
                        'decider-combinator',
                        'constant-combinator',
                        'artillery-turret',
                        'flamethrower-turret',
                        'offshore-pump',
                        'pump'
                    }, entity.name) or list_includes({
                        'underground-belt',
                        'transport-belt',
                        'splitter',
                        'inserter',
                        'boiler',
                        'mining-drill',
                        'assembling-machine',
                        'loader'
                    }, entity.type) then
                    entity.possible_rotations = { 0, 2, 4, 6 }
                elseif list_includes({
                        'storage-tank',
                        'gate',
                    }, entity.name) or list_includes({
                        'generator'
                    }, entity.type) then
                    entity.possible_rotations = { 0, 2 }
                elseif list_includes({
                        'curved-rail',
                        'rail-signal',
                        'rail-chain-signal'
                    }, entity.name) then
                    entity.possible_rotations = { 0, 1, 2, 3, 4, 5, 6, 7 }
                elseif list_includes({
                        'straight-rail'
                    }, entity.name) then
                    entity.possible_rotations = { 0, 1, 2, 3, 5, 7 }
                end

                -- modify fast_replaceable_group
                if entity.type == 'splitter' then
                    entity.fast_replaceable_group = 'splitter'
                elseif entity.type == 'underground-belt' then
                    entity.fast_replaceable_group = 'underground-belt'
                end

                -- move off_when_no_fluid_recipe outside of fluid_boxes props
                if entity.fluid_boxes ~= nil and entity.fluid_boxes.off_when_no_fluid_recipe ~= nil then
                    entity.fluid_boxes_off_when_no_fluid_recipe = entity.fluid_boxes.off_when_no_fluid_recipe
                    entity.fluid_boxes.off_when_no_fluid_recipe = nil
                end

                localise(entity, 'entity')
                table_filter(entity, entityKeyBlacklist)
                entities[entity.name] = entity
            end
        end
    end

    entities['offshore-pump'].size = { width = 1, height = 1 }
    -- entities['curved-rail'].size = { width = 4, height = 8 }

    entities['centrifuge'].possible_directions = nil
    entities['assembling-machine-1'].possible_directions = nil

    -- fix shifts
    entities['storage-tank'].pictures.window_background.shift = { 0, 1 }

    -- fix inconsistent radius
    entities.beacon.supply_area_distance = entities.beacon.supply_area_distance + 1

    local function add_to_Y_shift(y_shift, layer)
        layer.shift[2] = layer.shift[2] + y_shift
    end

    add_to_Y_shift(-0.6875, entities['artillery-turret'].cannon_barrel_pictures.layers[1])
    add_to_Y_shift(-0.6875, entities['artillery-turret'].cannon_base_pictures.layers[1])

    -- keep pictures consistent
    entities['pipe-to-ground'].pictures = {
        north = entities['pipe-to-ground'].pictures.up,
        east = entities['pipe-to-ground'].pictures.right,
        south = entities['pipe-to-ground'].pictures.down,
        west = entities['pipe-to-ground'].pictures.left
    }

    output.entities = entities
end

-- TILES
do
    local tiles = {}

    local tileKeyBlacklist = {
        'autoplace'
    }

    for _, tile in pairs(deep_copy(data.raw.tile)) do
        if tile.minable ~= nil or tile.name == 'landfill' then
            localise(tile, 'tile')
            table_filter(tile, tileKeyBlacklist)
            tiles[tile.name] = tile
        end
    end

    output.tiles = tiles
end

-- INVENTORY LAYOUT
do
    local inventoryLayout = {}

    local groupBlacklist = {
        'environment',
        'enemies',
        'effects',
        'tiles',
        'other'
    }

    local function comp_func(a, b)
        return a.order < b.order
    end

    local subgroups = {
        creative = {
            name = 'creative',
            group = 'creative',
            order = 'z',
            items = {}
        }
    }

    for _, subgroup in pairs(deep_copy(data.raw['item-subgroup'])) do
        subgroups[subgroup.name] = {
            name = subgroup.name,
            group = subgroup.group,
            order = subgroup.order,
            items = {}
        }
    end

    local function addEntriesToSubroups(t, defaultSubgroup)
        for _, entry in pairs(t) do
            local subgroup = entry.subgroup or defaultSubgroup
            if subgroup ~= nil and entry.order ~= nil and subgroups[subgroup] ~= nil then
                -- some fluid recipes are missing their icon and order
                -- local fluid = data.raw.fluid[entry.name] or {}
                table.insert(subgroups[subgroup].items, {
                    name = entry.name,
                    icon = entry.icon, -- or fluid.icon,
                    icons = entry.icons,
                    icon_size = entry.icon_size,
                    icon_mipmaps = entry.icon_mipmaps,
                    order = entry.order -- or fluid.order
                })
            end
        end
    end

    addEntriesToSubroups(output.items)
    addEntriesToSubroups(deep_copy(data.raw.recipe))
    addEntriesToSubroups(deep_copy(data.raw.fluid), 'fluid')
    addEntriesToSubroups(deep_copy(data.raw['virtual-signal']))

    local infinityChest = output.items['infinity-chest']
    local groups = {
        creative = {
            name = 'creative',
            icon = infinityChest.icon,
            icons = infinityChest.icons,
            icon_size = infinityChest.icon_size,
            icon_mipmaps = infinityChest.icon_mipmaps,
            order = 'z',
            subgroups = {}
        }
    }

    for _, group in pairs(deep_copy(data.raw['item-group'])) do
        if not list_includes(groupBlacklist, group.name) then
            groups[group.name] = {
                name = group.name,
                icon = group.icon,
                icons = group.icons,
                icon_size = group.icon_size,
                icon_mipmaps = group.icon_mipmaps,
                order = group.order,
                subgroups = {}
            }
        end
    end

    for _, subgroup in pairs(subgroups) do
        if groups[subgroup.group] ~= nil and #subgroup.items ~= 0 then
            table.sort(subgroup.items, comp_func)
            table.insert(groups[subgroup.group].subgroups, subgroup)
        end
    end

    for _, group in pairs(groups) do
        localise(group, 'item-group')
        table.sort(group.subgroups, comp_func)
        table.insert(inventoryLayout, group)
    end

    table.sort(inventoryLayout, comp_func)

    output.inventoryLayout = inventoryLayout
end

-- UTILITY SPRITES
do
    local utilitySprites = deep_copy(data.raw['utility-sprites'].default)
    utilitySprites.type = nil
    utilitySprites.name = nil
    output.utilitySprites = utilitySprites
end

-- PASSTROUGH OUTPUT DATA
do
    local serialized = serpent.dump(output)

    -- workaround Factorio's limitation of 200 characters per string
    -- by splitting the serialized data into chunks and embedding it
    -- into dummy entities

    local function embed_data(key, value)
        data:extend({ {
            type = "simple-entity",
            name = key,
            icon = "-",
            icon_size = 1,
            picture = {
                filename = "-",
                width = 1,
                height = 1
            },
            localised_name = tostring(value)
        } })
    end

    local l = string.len(serialized)
    local total_parts = 0
    for i = 1, l, 200 do
        total_parts = total_parts + 1
        embed_data('FBE-DATA-' .. tostring(total_parts), string.sub(serialized, i, i + 199))
    end

    embed_data('FBE-DATA-COUNT', total_parts)
end
