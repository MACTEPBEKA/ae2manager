local tools = require('tools')
local component = require('component')
local computer = require('computer')
local event = require('event')
serialization = require('serialization')

function Manager(configPath,fullCheckInterval,craftingCheckInterval,allowedCpus,maxBatch)
    local self = {}
    self.api = component['me_interface']
    self.configPath=configPath or '/ae2.cfg'
    self.fullCheckInterval = fullCheckInterval or 50
    self.craftingCheckInterval = craftingCheckInterval or 10
    self.allowedCpus = allowedCpus or -2
    self.maxBatch = maxBatch or 128
    self.loadRecipes()
    
    function self.loadRecipes()
        print('Loading config from '..self.configPath)
        local f, err = io.open(self.configPath, 'r')
        if not f then
            -- usually the file does not exist, on the first run
            print('Loading failed:', err)
            self.recipes={}
            return false
        end 
    
        local content = serialization.unserialize(f:read('a'))
    
        f:close()
    
        self.recipes = content.recipes
        print('Loaded '..#recipes..' recipes')
    end
    
    function self.saveRecipes()
        local tmpPath = self.configPath..'.tmp'
        for _, recipe in ipairs(self.recipes) do
            table.insert(content.recipes, {
                item = recipe.item,
                label = recipe.label,
                wanted = recipe.wanted,
            })
        end
    
        local f = io.open(tmpPath, 'w')
        f:write(serialization.serialize(content))
        f:close()
    
        filesystem.remove(configPath) -- may        fail
    
        local ok, err = os.rename(tmpPath, configPath)
        if not ok then error(err) end
    end
    
    function self.MainLoop()
        while true do
            local e1, e2 = event.pull(fullCheckInterval, 'ae2_loop')
            --log('AE2 loop in')
            self.ae2Run(e2 == 'reload_recipes')
            --log('AE2 loop out')
            --event.push('redraw')
        end
    end
    
    function self.ae2Run(learnNewRecipes)
        local start = computer.uptime()
        updateRecipes(learnNewRecipes)
    
        local finder = coroutine.create(self.findRecipeWork)
        while self.hasFreeCpu() do
            -- Find work
            local _, recipe, needed, craft = coroutine.resume(finder)
            if recipe then
                -- Request crafting
                local amount = math.min(needed, maxBatch)
                --log('Requesting ' .. amount .. ' ' .. recipe.label)
                recipe.crafting = craft.request(amount)
                print(amount)
                checkFuture(recipe) -- might fail very quickly (missing resource, ...)
            else
                break
            end
        end
    
        local duration = computer.uptime() - start
        updateStatus(duration)
    end
    
    function self.findRecipeWork() --> yield (recipe, needed, craft)
        for i, recipe in ipairs(self.recipes) do
            if not(recipe.error or recipe.crafting) then
    
                local needed = recipe.wanted - recipe.stored
                if needed <= 0 then
    
                    local craftables, err = self.api.getCraftables(recipe.item)
                    --log('get_craftable', inspect(craftables))
                    if err then
                        recipe.error = 'ae2.getCraftables ' .. tostring(err)
                    elseif #craftables == 0 then
                        recipe.error = 'Рецепт не найден'
                    elseif #craftables == 1 then
                        coroutine.yield(recipe, needed, craftables[1])
                    else
                        recipe.error = 'Найдено несколько рецептов'
                    end
                end
            end
        end
    end
    
    function self.hasFreeCpu()
        self.cpus = self.api.getCpus()
        print(self.api.getCpus())
        local free = 0
        for _, cpu in ipairs(self.cpus) do
            if not cpu.busy then free = free + 1 end
        end
        end
        local ongoing = 0
        for _, recipe in ipairs(self.recipes) do
            if recipe.crafting then ongoing = ongoing + 1 end
        end
    
        if tools.enoughCpus(#cpus, ongoing, free) then
            return true
        else
            --log('No CPU available')
            return false
        end
    end
    
    function self.updateRecipes(learnNewRecipes)
        local start = computer.uptime()
    
        -- Index our recipes
        local index = {}
        for _, recipe in ipairs(self.recipes) do
            local key = tools.itemKey(recipe.item, recipe.item.label ~= nil)
            index[key] = { recipe=recipe, matches={} }
        end
        --log('recipe index', computer.uptime() - start)
    
        -- Get all items in the network
        local items, err = self.api.getItemsInNetwork()  -- takes a full tick (to sync with the main thread?)
        if err then error(err) end
    
        -- Match all items with our recipes
        for _, item in ipairs(items) do
            local key = tools.itemKey(item, item.hasTag)
            local indexed = index[key]
            if indexed then
                table.insert(indexed.matches, item)
            elseif learnNewRecipes and item.isCraftable then
                local recipe = {
                    item = {
                        name = item.name,
                        damage = math.floor(item.damage)
                    },
                    label = item.label,
                    wanted = 0,
                }
                if item.hasTag then
                    -- By default, OC doesn't expose items NBT, so as a workaround we use the label as
                    -- an additional discriminant. This is not perfect (still some collisions, and locale-dependent)
                    recipe.item.label = recipe.label
                end
                table.insert(self.recipes, recipe)
                index[key] = { recipe=recipe, matches={item} }
            end
        end
        --log('group items', computer.uptime() - start)
    
        -- Check the recipes
        for _, entry in pairs(index) do
            local recipe = entry.recipe
            local matches = filter(entry.matches, function(e) return tools.contains(e, recipe.item) end)
            --log(recipe.label, 'found', #matches, 'matches')
            local craftable = false
            recipe.error = nil
    
            checkFuture(recipe)
    
            if #matches == 0 then
                recipe.stored = 0
            elseif #matches == 1 then
                local item = matches[1]
                recipe.stored = math.floor(item.size)
                craftable = item.isCraftable
            else
                local id = recipe.item.name .. ':' .. recipe.item.damage
                recipe.stored = 0
                recipe.error = id .. ' match ' .. #matches .. ' items'
                -- log('Recipe', recipe.label, 'matches:', pretty(matches))
            end
    
            if not recipe.error and recipe.wanted > 0 and not craftable then
                -- Warn the user as soon as an item is not craftable rather than wait to try
                recipe.error = 'Нет рецепта'
            end
        end
        --log('recipes check', computer.uptime() - start)
    
        if learnNewRecipes then
            event.push('save')
        end
    end
    return self
end

--return Manager