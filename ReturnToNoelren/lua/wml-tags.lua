local helper = wesnoth.require "lua/helper.lua"

-- to make code shorter. Yes, it's global.
wml_actions = wesnoth.wml_actions

--! [store_shroud]
--! melinath

-- Given side= and variable=, stores that side's shroud data in that variable
-- Example:
-- [store_shroud]
--     side=1
--     variable=shroud_data
-- [/store_shroud]

function wml_actions.store_shroud(cfg)
	local team_number = cfg.side or helper.wml_error("Missing required side= attribute in [store_shroud]")
	local variable = cfg.variable or helper.wml_error("Missing required variable= attribute in [store_shroud].")
	local side = wesnoth.get_side(team_number)
	local current_shroud = side.__cfg.shroud_data
	wesnoth.set_variable(variable, current_shroud)
end

--! [set_shroud]
--! melinath

-- Given shroud data, removes the shroud in the marked places on the map.
-- Example:
-- [set_shroud]
--     side=1
--     shroud_data=$shroud_data # stored with store_shroud, for example!
-- [/set_shroud]

function wml_actions.set_shroud(cfg)
	local team_number = cfg.side or helper.wml_error("Missing required side= attribute in [set_shroud]")
	local shroud_data = cfg.shroud_data or helper.wml_error("Missing required shroud_data= attribute in [set_shroud]")

	if shroud_data == nil then helper.wml_error("[set_shroud] was passed an empty shroud string")
	elseif string.sub(shroud_data,1,1) ~= "|" then helper.wml_error("[set_shroud] was passed an invalid shroud string")
	else
		-- yes, I prefer long variable names. I think that they make the code more understandable. E_H.
		local width, height, border = wesnoth.get_map_size()
		local shroud_x = ( 1 - border )

		-- my variation: to make code faster (hopefully), and avoid multiple callings of remove_shroud
		-- I append every location to a table, convert them as strings, and invoke remove_shroud
		-- only once, with these lists of locations. E_H.
		local rows, columns = {}, {}

		for row in string.gmatch ( shroud_data, "|(%d*)" ) do
			local shroud_y = ( 1 - border )
			for column in string.gmatch ( row, "%d" ) do
				if column == "1" then
					-- I tend to confuse them, so better specify: x are columns and y are rows. E_H.
					table.insert( rows, shroud_y ) -- appending them to the tables.
					table.insert( columns, shroud_x )
				end
				shroud_y = shroud_y + 1
			end
			shroud_x = shroud_x + 1
		end

		-- converting them to strings with separator
		local locs_x = table.concat( columns, "," )
		local locs_y = table.concat( rows, "," )

		if not wesnoth.get_side( team_number ).__cfg.shroud then
			wml_actions.modify_side { side = team_number, shroud = true } -- in case that shroud was removed by modify_side
		end

		wml_actions.place_shroud { side = team_number, x = string.format("%d-%d", 1 - border, height + border ), y = string.format("%d-%d", 1 - border, width + border ) }
		wml_actions.remove_shroud { side = team_number, x = locs_x, y = locs_y }
	end
end

--! [save_map],[load_map]
--! silene

--The [save_map] and [load_map] tags store and retrieve map data in a WML variable;
-- useful for dealing with dynamically modified yet persistent maps. They take a
-- variable=.
-- Example:
-- [save_map]
--     variable=saved_map[1].map
-- [/save_map]
-- [load_map]
--     variable=saved_map[1].map
-- [/load_map]

function wml_actions.save_map(cfg)
	local variable = cfg.variable or helper.wml_error "[save_map] missing required variable= attribute"
	local width, height, border = wesnoth.get_map_size()
	local t = {} -- not table, to avoid overriding the table library!

	for y = 1 - border, height + border do
		local row = {}

		for x = 1 - border, width + border do
			row[ x + border ] = wesnoth.get_terrain ( x, y )
		end

		t[ y + border ] = table.concat ( row, ',' )
	end

	local s = table.concat( t, '\n' ) -- not string, to avoid overriding the string library!
	wesnoth.set_variable ( variable, string.format ( "border_size=%d\nusage=map\n\n%s", border, s ) )
end

function wml_actions.load_map(cfg)
	local variable = cfg.variable or helper.wml_error "[load_map] missing required variable= attribute"
	wml_actions.replace_map { map = wesnoth.get_variable ( variable ), expand = true, shrink = true }
end


function wml_actions.nearest_hex(cfg)
	local starting_x = tonumber(cfg.starting_x) or helper.wml_error("Missing required starting_x in [nearest_hex]")
	local starting_y = tonumber(cfg.starting_y) or helper.wml_error("Missing required starting_y in [nearest_hex]")
	local filter = (helper.get_child(cfg, "filter_location")) or helper.wml_error("Missing required [filter_location] in [nearest_hex]")
	local variable = cfg.variable or "nearest_hex" -- default

	local current_distance = math.huge -- feed it the biggest value possible
	local nearest_hex_found

	for index,location in ipairs(wesnoth.get_locations(filter)) do
		local distance = helper.distance_between( starting_x, starting_y, location[1], location[2] )
		if distance < current_distance then
			current_distance = distance
			nearest_hex_found = location
		end
	end

	if nearest_hex_found then
		wesnoth.set_variable( variable, { x = nearest_hex_found[1], y = nearest_hex_found[2], terrain = wesnoth.get_terrain( nearest_hex_found[1], nearest_hex_found[2] ) })
	else wesnoth.message( "WML", "No suitable location found by [nearest_hex]" )
	end
end

--[[ [find_path]
A WML interface to the pathfinder, as described by Sapient in FutureWML.
[traveler]: SUF, only 1st matching unit
[destination]: SLF, only 1st matching hex
variable = 'path' as default
allow_multiple_turns = yes/no, no as default
ignore_visibility = yes/no, yes as default
ignore_teleport = yes/no, no as default
ignore_units = yes/no, no as default ]]

function wml_actions.find_path(cfg)
	local filter_unit = (helper.get_child(cfg, "traveler")) or helper.wml_error("[find_path] missing required [traveler] tag")
	local filter_location = (helper.get_child(cfg, "destination")) or helper.wml_error("[find_path] missing required [destination] tag")
	local variable = cfg.variable or "path"
	local ignore_units = cfg.ignore_units
	local ignore_teleport = cfg.ignore_teleport
	local allow_multiple_turns = cfg.allow_multiple_turns
	if cfg.ignore_visibility ~= false then local viewing_side = 0 end --default yes

	local unit = wesnoth.get_units(filter_unit)[1] -- only the first unit matching
	local locations = wesnoth.get_locations(filter_location) -- only the location with the lowest distance and lowest movement cost will match. If there will still be more than 1, only the 1st maching one.
	if not allow_multiple_turns then local max_cost = unit.moves end --to avoid wrong calculation on already moved units
	local current_distance, current_cost = math.huge, math.huge
	local current_location = {}

	local width,heigth,border = wesnoth.get_map_size() -- data for test below

	for index, location in ipairs(locations) do
		-- we test if location passed to pathfinder is invalid (border); if is, do nothing, do not return and continue the cycle
		if location[1] == 0 or location[1] == ( width + 1 ) or location[2] == 0 or location[2] == ( heigth + 1 ) then
		else
			local distance = helper.distance_between ( unit.x, unit.y, location[1], location[2] )
			-- if we pass an unreachable locations an high value will be returned
			local path, cost = wesnoth.find_path( unit, location[1], location[2], { max_cost = max_cost, ignore_units = ignore_units, ignore_teleport = ignore_teleport, viewing_side = viewing_side } )

			if ( distance < current_distance and cost <= current_cost ) or ( cost < current_cost and distance <= current_distance ) then -- to avoid changing the hex with one with less distance and more cost, or vice versa
				current_distance = distance
				current_cost = cost
				current_location = location
			end
		end
	end

	if #current_location == 0 then wesnoth.message( "WML", "No matching location found by [find_path]" ) else
		local path, cost = wesnoth.find_path( unit, current_location[1], current_location[2], { max_cost = max_cost, ignore_units = ignore_units, ignore_teleport = ignore_teleport, viewing_side = viewing_side } )
		local turns
		
		if cost == 0 then -- if location is the same, of course it doesn't cost any MP
			turns = 0
		else
			turns = math.ceil( ( ( cost - unit.moves ) / unit.max_moves ) + 1 )
		end

		if cost >= 42424242 then -- it's the high value returned for unwalkable or busy terrains
			wesnoth.set_variable ( string.format("%s", variable), { length = 0 } ) -- set only length, nil all other values
		return end

		if not allow_multiple_turns and turns > 1 then -- location cannot be reached in one turn
			wesnoth.set_variable ( string.format("%s", variable), { length = 0 } )
		return end -- skip the cycles below

		wesnoth.set_variable ( string.format( "%s", variable ), { length = current_distance, from_x = unit.x, from_y = unit.y, to_x = current_location[1], to_y = current_location[2], movement_cost = cost, required_turns = turns } )

		for index, path_loc in ipairs(path) do
			local sub_path, sub_cost = wesnoth.find_path( unit, path_loc[1], path_loc[2], { max_cost = max_cost, ignore_units = ignore_units, ignore_teleport = ignore_teleport, viewing_side = viewing_side } )
			local sub_turns
			
			if sub_cost == 0 then
				sub_turns = 0
			else
				sub_turns = math.ceil( ( ( sub_cost - unit.moves ) / unit.max_moves ) + 1 )
			end
			
			wesnoth.set_variable ( string.format( "%s.step[%d]", variable, index - 1 ), { x = path_loc[1], y = path_loc[2], terrain = wesnoth.get_terrain( path_loc[1], path_loc[2] ), movement_cost = sub_cost, required_turns = sub_turns } ) -- this structure takes less space in the inspection window
		end
	end
end

