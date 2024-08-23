-- we store the data from the host quickly from the data handler interrupt
-- and wait for the main loop to pick it up for processing/drawing
-- app_data.text is the current chunk of text for display

-- Frame to phone flags
BATTERY_LEVEL_FLAG = 0x0c
--TODO BATTERY_LEVEL_FLAG = "\x0c"

-- Phone to Frame flags
TEXT_FLAG = 0x0a

local app_data_raw = {}
local app_data = {}

-- Data Handler: called when data arrives, must execute quickly.
-- Update the app_data_raw item based on the contents of the current packet
-- The first byte of the packet indicates the message type, and the item's key
-- If the key is not present, initialise a new app data item
-- Accumulate chunks of data of the specified type, for later processing
function update_app_data_raw(data)
    local item = app_data_raw[string.byte(data, 1)]
    if item == nil or next(item) == nil then
        item = { chunk_table = {}, size = 0, recv_bytes = 0 }
        app_data_raw[string.byte(data, 1)] = item
    end

    if #item.chunk_table == 0 then
        -- first chunk of new data contains size (Uint16)
        item.size = string.byte(data, 2) << 8 | string.byte(data, 3)
        item.chunk_table[1] = string.sub(data, 4)
        item.recv_bytes = string.len(data) - 3
    else
        item.chunk_table[#item.chunk_table + 1] = string.sub(data, 2)
        item.recv_bytes = string.len(data) - 1
    end
end

-- Works through app_data_raw and if any items are ready, run the corresponding parser
function process_raw_items()
    local processed = 0

    for flag, item in pairs(app_data_raw) do
        if item.size > 0 and item.recv_bytes == item.size then
            -- parse the app_data_raw item into an app_data item
            app_data[flag] = parsers[flag](table.concat(item.chunk_table))

            -- then clear out the raw data
            for k, v in pairs(item.chunk_table) do item.chunk_table[k] = nil end
            item.size = 0
            item.recv_bytes = 0
            processed = processed + 1
        end
    end

    return processed
end

-- Parse the text message raw data. If the message had more structure (layout etc.)
-- we would parse that out here. In this case the data only contains the string
function parse_text(data)
    local text = {}
    text.data = data
    return text
end

-- draw the current text on the display
function print_text()
    local i = 0
    for line in app_data[TEXT_FLAG].data:gmatch("([^\n]*)\n?") do
        if line ~= "" then
            frame.display.text(line, 1, i * 60 + 1)
            i = i + 1
        end
    end

end

-- Main app loop
function app_loop()
    local last_batt_update = 0
    while true do
        rc, err = pcall(
            function()
                -- process any raw items, if ready (parse into text, then clear raw)
                local items_ready = process_raw_items()

                -- TODO little sleep? (maybe data_handler is even called again, that's okay)
                frame.sleep(0.02)

                -- only need to print it once when it's ready, it will stay there
                if items_ready > 0 then
                    if (app_data[TEXT_FLAG] ~= nil and app_data[TEXT_FLAG].data ~= nil) then
                        print_text()
                    end
                    frame.display.show()
                end

                frame.sleep(0.02)

                -- periodic battery level updates
                local t = frame.time.utc()
                if (last_batt_update == 0 or (t - last_batt_update) > 180) then
                    pcall(frame.bluetooth.send, string.char(BATTERY_LEVEL_FLAG) .. string.char(math.floor(frame.battery_level())))
                    last_batt_update = t
                end

                -- TODO clear display after an amount of time?
            end
        )
        -- Catch the break signal here and clean up the display
        if rc == false then
            -- send the error back on the stdout stream
            print(err)
            frame.display.text(" ", 1, 1)
            frame.display.show()
            frame.sleep(0.04)
            break
        end
    end
end

-- register the respective message parsers
local parsers = { TEXT_FLAG = parse_text }

-- register the handler as a callback for all data sent from the host
frame.bluetooth.receive_callback(update_app_data_raw)

-- run the main app loop
app_loop()