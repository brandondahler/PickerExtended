-------------------------------------------------------------------------------
--[Picker Dolly]--
-------------------------------------------------------------------------------

local Event = require('stdlib/event/event')
local Player = require('stdlib/event/player')
local Area = require('stdlib/area/area')
local Position = require('stdlib/area/position')
local lib = require('scripts/lib')
local interface = require('interface')
local table = require('stdlib/utils/table')

Event.generate_event_name('dolly_moved')
interface['dolly_moved_entity_id'] = function()
    return Event.generate_event_name('dolly_moved')
end

--[[
Event table returned with the event
    player_index = player_index, --The index of the player who moved the entity
    moved_entity = entity, --The entity that was moved
    start_pos = position --The position that the entity was moved from
}

--In your mods on_load and on_init, create an event handler for the dolly_moved_entity_id
--Adding the event registration in on_load and on_init you should not have to add picker as an optional dependency

if remote.interfaces["picker"] and remote.interfaces["picker"]["dolly_moved_entity_id"] then
    script.on_event(remote.call("picker", "dolly_moved_entity_id"), function_to_update_positions)
end
--]]

local function blacklist(entity)
    local types = {
        ['item-request-proxy'] = true,
        ['rocket-silo-rocket'] = true,
        ['player'] = true,
        ['resource'] = true,
        ['car'] = true,
        ['construction-robot'] = true,
        ['logistic-robot'] = true,
        ['rocket'] = true
    }
    local names = {}
    return types[entity.type] or names[entity.name]
end

local input_to_direction = {
    ['dolly-move-north'] = defines.direction.north,
    ['dolly-move-east'] = defines.direction.east,
    ['dolly-move-south'] = defines.direction.south,
    ['dolly-move-west'] = defines.direction.west
}

local oblong_combinators = {
    ['arithmetic-combinator'] = true,
    ['decider-combinator'] = true
}

local wire_distance_types = {
    ['electric-pole'] = true,
    --['power-switch'] = true -- ! API PR made
}

local function get_saved_entity(player, pdata, tick)
    if player.selected and player.selected.force == player.force and not blacklist(player.selected) then
        return player.selected
    elseif pdata.dolly and pdata.dolly.valid then
        if tick <= (pdata.dolly_tick or 0) + defines.time.second * 5 then
            return pdata.dolly
        else
            pdata.dolly = nil
            return
        end
    end
end

local function _get_distance(entity)
    if wire_distance_types[entity.type] then
        return entity.prototype.max_wire_distance
    elseif entity.circuit_connected_entities then
        return entity.prototype.max_circuit_wire_distance
    end
end

local function move_combinator(event)
    local player, pdata = Player.get(event.player_index)
    local entity = get_saved_entity(player, pdata, event.tick)

    if entity then
        if player.can_reach_entity(entity) then
            --Direction to move the source
            local direction = event.direction or input_to_direction[event.input_name]
            --The entities direction
            local ent_direction = entity.direction
            --Distance to move the source, defaults to 1
            local distance = event.distance or 1

            --Where we started from in case we have to return it
            local start_pos = Position(event.start_pos or entity.position)
            --Where we want to go too
            local target_pos = Position(entity.position):translate(direction, distance)

            --Wire distance for the source
            local source_distance = _get_distance(entity)

            --returns true if the wires can't reach
            local _cant_reach =
                function(neighbours)
                return table.any(
                    neighbours,
                    function(neighbour)
                        local dist = Position(neighbour.position):distance(target_pos)
                        return entity ~= neighbour and (dist > source_distance or dist > _get_distance(neighbour))
                    end
                )
            end

            local out_of_the_way = Position(entity.position):translate(Position.opposite_direction(direction), event.tiles_away or 20)

            local sel_area = Area(entity.selection_box)
            local item_area = Area(entity.bounding_box):non_zero():translate(direction, distance)

            local update = entity.surface.find_entities_filtered {area = sel_area:copy():expand(32), force = entity.force}
            local items_on_ground = entity.surface.find_entities_filtered {type = 'item-entity', area = item_area}
            local proxy = entity.surface.find_entities_filtered {name = 'item-request-proxy', area = sel_area:non_zero(), force = player.force}[1]

            --Update everything after teleporting
            local function teleport_and_update(ent, pos, raise)
                if ent.last_user then
                    ent.last_user = player
                end
                ent.teleport(pos)
                table.each(
                    items_on_ground,
                    function(item)
                        if item.valid and not player.mine_entity(item) then
                            item.teleport(entity.surface.find_non_colliding_position('item-on-ground', ent.position, 0, .20))
                        end
                    end
                )
                if proxy and proxy.valid then
                    proxy.teleport(ent.position)
                end
                table.each(
                    update,
                    function(e)
                        e.update_connections()
                    end
                )
                if raise then
                    script.raise_event(Event.generate_event_name('dolly_moved'), {player_index = player.index, moved_entity = ent, start_pos = start_pos})
                else
                    player.play_sound({path = 'utility/cannot_build', position = player.position, volume = 1})
                end
                return raise
            end

            --teleport the entity out of the way.
            if entity.teleport(out_of_the_way) then
                if proxy and proxy.proxy_target == entity then
                    proxy.teleport(entity.position)
                else
                    proxy = false
                end

                table.each(
                    items_on_ground,
                    function(item)
                        item.teleport(out_of_the_way)
                    end
                )

                pdata.dolly = entity
                pdata.dolly_tick = event.tick
                entity.direction = ent_direction

                local ghost = entity.name == 'entity-ghost' and entity.ghost_name

                local params = {name = ghost or entity.name, position = target_pos, direction = ent_direction, force = entity.force}
                if entity.surface.can_place_entity(params) and not entity.surface.find_entity('entity-ghost', target_pos) then
                    --We can place the entity here, check for wire distance
                    if entity.circuit_connected_entities then
                        if wire_distance_types[entity.type] and not table.any(entity.neighbours, _cant_reach) then
                            return teleport_and_update(entity, target_pos, true)
                        elseif not wire_distance_types[entity.type] and not table.any(entity.circuit_connected_entities, _cant_reach) then
                            if entity.type == 'mining-drill' and lib.find_resources(entity) == 0 then
                                local name = entity.mining_target and entity.mining_target.localised_name or {'picker-dollies.generic-ore-patch'}
                                player.print({'picker-dollies.off-ore-patch', entity.localised_name, name})
                                return teleport_and_update(entity, start_pos, false)
                            else
                                return teleport_and_update(entity, target_pos, true)
                            end
                        else
                            player.print({'picker-dollies.wires-maxed'})
                            return teleport_and_update(entity, start_pos, false)
                        end
                    else --All others
                        return teleport_and_update(entity, target_pos, true)
                    end
                else --Ent can't won't fit, restore position.
                    return teleport_and_update(entity, start_pos, false)
                end
            else --Entity can't be teleported
                player.print({'picker-dollies.cant-be-teleported', entity.localised_name})
            end
        else
            player.play_sound({path = 'utility/cannot_build', position = player.position, volume = 1})
        end
    end
end
Event.register({'dolly-move-north', 'dolly-move-east', 'dolly-move-south', 'dolly-move-west'}, move_combinator)

local function try_rotate_combinator(event)
    local player, pdata = Player.get(event.player_index)
    if not player.cursor_stack.valid_for_read then
        local entity = get_saved_entity(player, pdata, event.tick)

        if entity and oblong_combinators[entity.name] then
            if player.can_reach_entity(entity) then
                pdata.dolly = entity
                local diags = {
                    [defines.direction.north] = defines.direction.northeast,
                    [defines.direction.south] = defines.direction.northeast,
                    [defines.direction.west] = defines.direction.southwest,
                    [defines.direction.east] = defines.direction.southwest
                }

                event.start_pos = entity.position
                event.start_direction = entity.direction

                event.distance = .5
                entity.direction = entity.direction == 6 and 0 or entity.direction + 2

                event.direction = diags[entity.direction]

                if not move_combinator(event) then
                    entity.direction = event.start_direction
                end
            end
        end
    end
end
Event.register('dolly-rotate-rectangle', try_rotate_combinator)

local function rotate_saved_dolly(event)
    local player, pdata = Player.get(event.player_index)
    if not player.cursor_stack.valid_for_read and not player.selected then
        local entity = get_saved_entity(player, pdata, event.tick)

        if entity and entity.supports_direction then
            pdata.dolly = entity
            entity.rotate {reverse = event.input_name == 'dolly-rotate-saved-reverse', by_player = player}
        end
    end
end
Event.register({'dolly-rotate-saved', 'dolly-rotate-saved-reverse'}, rotate_saved_dolly)

--   "name": "ghost-pipette",
--   "title": "Ghost Pipette",
--   "author": "blueblue",
--   "contact": "deep.blueeee@yahoo.de",
--   "description": "Adds ghost-related functionality like pipette, rotation, selection.",
local function rotate_ghost(event)
    local player, pdata = Player.get(event.player_index)
    if not player.cursor_stack.valid_for_read then
        local ghost = get_saved_entity(player, pdata, event.tick)
        if ghost and ghost.name == 'entity-ghost' then
            local left = event.input_name == 'picker-rotate-ghost-reverse'
            local prototype = game.entity_prototypes[ghost.ghost_name]
            local value = prototype.has_flag('building-direction-8-way') and 1 or 2

            if prototype.type == 'offshore-pump' then
                return
            end

            if value ~= 1 then
                local box = prototype.collision_box
                local lt = box.left_top
                local rb = box.right_bottom
                local dx = rb.x - lt.x
                local dy = rb.y - lt.y
                if dx ~= dy and dx <= 2 and dy <= 2 then
                    value = 4
                elseif dx ~= dy then
                    return
                end
            end
            ghost.direction = (ghost.direction + ((left and -value) or value)) % 8
            pdata.dolly = ghost
        end
    end
end
Event.register({'dolly-rotate-ghost', 'dolly-rotate-ghost-reverse'}, rotate_ghost)

local function mass_moving(event)
    if event.item == 'picker-dolly' and #event.entities > 0 then
        local player, pdata = Player.get(event.player_index)
        pdata.dolly_movers = {}
        pdata.dolly_movers_time = event.tick
        local tiles_away = Area(event.area):size()
        for _, ent in ipairs(event.entities) do
            local out_of_the_way = Position(ent.position):translate(Position.opposite_direction(ent.direction), tiles_away)
            local pos = ent.position
            if ent.teleport(out_of_the_way) then
                ent.teleport(pos)
            else
                player.print('Selection does not fully support moving')
                return
            end
        end
        pdata.dolly_movers = event.entities
        player.print('Entities stored')
    end
end
Event.register({defines.events.on_player_selected_area, defines.events.on_player_alt_selected_area}, mass_moving)

return move_combinator
