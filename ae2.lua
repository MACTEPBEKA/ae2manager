local component = require('component')
local computer = require('computer')
local coroutine = require('coroutine')
local event = require('event')
local filesystem = require('filesystem')
local serialization = require('serialization')
local thread = require('thread')
local tty = require('tty')
local unicode = require('unicode')
local GUI = require('GUI')
-- local inspect = require('inspect')

-- Config --

-- Control how many CPUs to use. 0 is unlimited, negative to keep some CPU free, between 0 and 1 to reserve a share,
-- and greater than 1 to allocate a fixed  number.
local allowedCpus = -2
-- Maximum size of the crafting requests
local maxBatch = 256
-- How often to check the AE system, in second
local fullCheckInterval = 50       -- full scan
local craftingCheckInterval = 10     -- only check ongoing crafting
-- Where to save the config
local configPath = '/ae2.cfg'

-- Global State --

-- array of recipe like { item, label, wanted, [current, crafting] }
local recipes = {}
-- various system status data
local status = {}
-- AE2 proxy
local ae2

-- Functions --

function main()
    local resetBColor, resetFColor = tty.gpu().getBackground(), tty.gpu().getForeground()

    initAe2()
    loadRecipes()
    ae2Run(true)

    local app = buildGui()
    app:draw(true)

    -- Start some background tasks
    local background = {}
    table.insert(background, event.listen("key_up", function (key, address, char)
        if char == string.byte('q') then
            event.push('exit')
        end
    end))
    table.insert(background, event.listen("redraw", function (key) app:draw() end))
    table.insert(background, event.listen("save", failFast(saveRecipes)))
    table.insert(background, event.timer(craftingCheckInterval, failFast(checkCrafting), math.huge))
    table.insert(background, thread.create(failFast(ae2Loop)))
    table.insert(background, thread.create(failFast(function() app:start() end)))

    -- Block until we receive the exit signal
    local _, err = event.pull("exit")

    -- Cleanup
    app:stop()

    for _, b in ipairs(background) do
        if type(b) == 'table' and b.kill then
            b:kill()
        else
            event.cancel(b)
        end
    end

    tty.gpu().setBackground(resetBColor)
    tty.gpu().setForeground(resetFColor)
    tty.clear()

    if err then
        io.stderr:write(err)
        os.exit(1)
    else
        os.exit(0)
    end
end

function log(...)
    -- TODO: reserve a part of the screen for logs
    for i, v in ipairs{...} do
        if i > 1 then io.stderr:write(' ') end
        io.stderr:write(tostring(v))
    end
    io.stderr:write('\n')
end

function logRam(msg)
    --free, total = computer.freeMemory(), computer.totalMemory()
    --log(msg, 'RAM', (total - free) * 100 / total, '%')
end

function pretty(x)
    return serialization.serialize(x, true)
end

function failFast(fn)
    return function(...)
        local res = table.pack(xpcall(fn, debug.traceback, ...))
        if not res[1] then
            event.push('exit', res[2])
        end
        return table.unpack(res, 2)
    end
end

function initAe2()
    local function test_ae2(id)
        local proxy = component.proxy(id)
        proxy.getCpus()
        return proxy
    end

    for id, type in pairs(component.list()) do
        -- print('Testing ' .. type .. ' ' .. id)
        local ok, p = pcall(test_ae2, id)
        if ok then
            print('Component ' .. type .. ' (' .. id .. ') is suitable')
            ae2 = p
        end
    end

    if ae2 == nil then
        error('No AE2 component found')
    else
        print('Using component ' .. ae2.type .. ' (' .. ae2.address .. ')')
    end
end

function loadRecipes()
    print('Loading config from '..configPath)
    local f, err = io.open(configPath, 'r')
    if not f then
        -- usually the file does not exist, on the first run
        print('Loading failed:', err)
        return
    end

    local content = serialization.unserialize(f:read('a'))

    f:close()

    recipes = content.recipes
    print('Loaded '..#recipes..' recipes')
end

function saveRecipes()
    local tmpPath = configPath..'.tmp'
    local content = { recipes={} }

    for _, recipe in ipairs(recipes) do
        table.insert(content.recipes, {
            item = recipe.item,
            label = recipe.label,
            wanted = recipe.wanted,
        })
    end

    local f = io.open(tmpPath, 'w')
    f:write(serialization.serialize(content))
    f:close()

    filesystem.remove(configPath) -- may fail

    local ok, err = os.rename(tmpPath, configPath)
    if not ok then error(err) end
end

-- Main loop --

function ae2Loop()
    while true do
        local e1, e2 = event.pull(fullCheckInterval, 'ae2_loop')
        logRam('loop')
        --log('AE2 loop in')
        ae2Run(e2 == 'reload_recipes')
        --log('AE2 loop out')
        event.push('redraw')
    end
end


function ae2Run(learnNewRecipes)
    local start = computer.uptime()
    updateRecipes(learnNewRecipes)
    logRam('recipes')
    -- logRam('recipes (post-gc)')

    local finder = coroutine.create(findRecipeWork)
    while hasFreeCpu() do
        -- Find work
        local _, recipe, needed, craft = coroutine.resume(finder)
        if recipe then
            -- Request crafting
            local amount = math.min(needed, maxBatch)
            --log('Requesting ' .. amount .. ' ' .. recipe.label)
            recipe.crafting = craft.request(amount)
            yield('yield crafting')
            checkFuture(recipe) -- might fail very quickly (missing resource, ...)
        else
            break
        end
    end

    local duration = computer.uptime() - start
    updateStatus(duration)
end

function checkCrafting()
    for _, recipe in ipairs(recipes) do
        if checkFuture(recipe) then
            --log('checkCrafting event !')
            event.push('ae2_loop')
            return
        end
    end
end

function yield(msg)
    --local gpu = tty.gpu()
    --local _, h = gpu.getViewport()
    --gpu.set(1, h, msg)
    os.sleep()
end

function updateRecipes(learnNewRecipes)
    local start = computer.uptime()

    -- Index our recipes
    local index = {}
    for _, recipe in ipairs(recipes) do
        local key = itemKey(recipe.item, recipe.item.label ~= nil)
        index[key] = { recipe=recipe, matches={} }
    end
    --log('recipe index', computer.uptime() - start)

    -- Get all items in the network
    local items, err = ae2.getItemsInNetwork()  -- takes a full tick (to sync with the main thread?)
    if err then error(err) end
    --log('ae2.getItemsInNetwork', computer.uptime() - start, 'with', #items, 'items')

    -- Match all items with our recipes
    for _, item in ipairs(items) do
        local key = itemKey(item, item.hasTag)
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
            table.insert(recipes, recipe)
            index[key] = { recipe=recipe, matches={item} }
        end
    end
    --log('group items', computer.uptime() - start)

    -- Check the recipes
    for _, entry in pairs(index) do
        local recipe = entry.recipe
        local matches = filter(entry.matches, function(e) return contains(e, recipe.item) end)
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

function itemKey(item, withLabel)
    local key = item.name .. '$' .. math.floor(item.damage)
    if withLabel then
        --log('using label for', item.label)
        key = key .. '$' .. item.label
    end
    return key
end

function updateStatus(duration)
    status.update = {
        duration = duration
    }

    -- CPU data
    local cpus = ae2.getCpus()
    status.cpu = {
        all = #cpus,
        free = 0,
    }
    for _, cpu in ipairs(cpus) do
        status.cpu.free = status.cpu.free + (cpu.busy and 0 or 1)
    end

    -- Recipe stats
    status.recipes = {
        error = 0,
        crafting = 0,
        queue = 0,
    }
    for _, recipe in ipairs(recipes) do
        if recipe.error then
            status.recipes.error = status.recipes.error + 1
        elseif recipe.crafting then
            status.recipes.crafting = status.recipes.crafting + 1
        elseif (recipe.stored or 0) < (recipe.wanted or 0) then
            status.recipes.queue = status.recipes.queue + 1
        end
    end
end

function checkFuture(recipe)
    if not recipe.crafting then return end

    local canceled, err = recipe.crafting.isCanceled()
    if canceled or err then
        --log('Crafting of ' .. recipe.label .. ' was cancelled')
        recipe.crafting = nil
        recipe.error = err or 'canceled'
        return true
    end

    local done, err = recipe.crafting.isDone()
    if err then error('isDone ' .. err) end
    if done then
        --log('Crafting of ' .. recipe.label .. ' is done')
        recipe.crafting = nil
        return true
    end

    return false
end

function equals(t1, t2)
    if t1 == t2 then return true end
    if type(t1) ~= type(t2) or type(t1) ~= 'table' then return false end

    for k1, v1 in pairs(t1) do
        local v2 = t2[k1]
        if not equals(v1, v2) then return false end
    end

    for k2, _ in pairs(t2) do
        if t1[k2] == nil then return false end
    end

    return true
end

function filter(array, predicate)
    local res = {}
    for _, v in ipairs(array) do
        if predicate(v) then table.insert(res, v) end
    end
    return res
end

function contains(haystack, needle)
    if haystack == needle then return true end
    if type(haystack) ~= type(needle) or type(haystack) ~= 'table' then return false end

    for k, v in pairs(needle) do
        if not contains(haystack[k], v) then return false end
    end

    return true
end

function hasFreeCpu()
    local cpus = ae2.getCpus()
    local free = 0
    for i, cpu in ipairs(cpus) do
        if not cpu.busy then free = free + 1 end
    end
    local ongoing = 0
    for _, recipe in ipairs(recipes) do
        if recipe.crafting then ongoing = ongoing + 1 end
    end

    if enoughCpus(#cpus, ongoing, free) then
        return true
    else
        --log('No CPU available')
        return false
    end
end

function enoughCpus(available, ongoing, free)
    if free == 0 then return false end
    if ongoing == 0 then return true end
    if allowedCpus == 0 then return true end
    if allowedCpus > 0 and allowedCpus < 1 then
        return  (ongoing + 1) / available <= allowedCpus
    end
    if allowedCpus >= 1 then
        return ongoing < allowedCpus
    end
    if allowedCpus > -1 then
        return (free - 1) / available <= -allowedCpus
    end
    return free > -allowedCpus
end

function findRecipeWork() --> yield (recipe, needed, craft)
    for i, recipe in ipairs(recipes) do
        if recipe.error or recipe.crafting then goto continue end

        local needed = recipe.wanted - recipe.stored
        if needed <= 0 then goto continue end

        yield('yield '..i)
        local craftables, err = ae2.getCraftables(recipe.item)
        --log('get_craftable', inspect(craftables))
        if err then
            recipe.error = 'ae2.getCraftables ' .. tostring(err)
        elseif #craftables == 0 then
            recipe.error = 'No crafting pattern found'
        elseif #craftables == 1 then
            coroutine.yield(recipe, needed, craftables[1])
        else
            recipe.error = 'Multiple crafting patterns'
        end

        ::continue::
    end
end

function override(object, method, fn)
    local super = object[method] or function() end
    object[method] = function(...)
        fn(super, ...)
    end
end

function numberValidator(str)
    n = tonumber(str, 10)
    return n and math.floor(n) == n
end

-- Stay close to the 16 Minecraft colors in order to work on gold GPU/screen
local C_BACKGROUND = 0x0F2231 -- фон
local C_STATUS_BAR = 0x0F2231 -- фон пбс
local C_STATUS_TEXT = 0xC4D0E0 -- текст
local C_STATUS_PRESSED = 0xFF0000 -- активный текст
local C_BADGE = 0x0F2231 -- фон скроллбара через одну
local C_BADGE_ERR = 0x445565 -- ошибка элементов
local C_BADGE_BUSY = 0x445565 -- корректные элементов
local C_BADGE_SELECTED = 0x445565 -- выделение элементов скроллбара
local C_BADGE_TEXT = 0xC4D0E0 -- цвет текста
local C_INPUT = 0xFFFFFF -- поиск
local C_INPUT_TEXT = 0x1E1E1E
local C_SCROLLBAR = 0x99CCBB -- скролл полоска
local C_SCROLLBAR_BACKGROUND = 0xFFFFFF -- фон скролбара

function buildGui()
    local app = GUI.application()
    local statusBar = app:addChild(GUI.container(1, 1, app.width, 1))
    local window = app:addChild(GUI.container(1, 1 + statusBar.height, app.width, app.height - statusBar.height))

    window:addChild(GUI.panel(1, 1, window.width, window.height, C_BACKGROUND))
    local columns = math.floor(window.width / 60) + 1

    -- Crating queue view
    local craftingQueueView = window:addChild(GUI.layout(1, 1, window.width-1, window.height, columns, 1))
    for i = 1, columns do
        craftingQueueView:setAlignment(i, 1, GUI.ALIGNMENT_HORIZONTAL_CENTER, GUI.ALIGNMENT_VERTICAL_TOP)
        craftingQueueView:setMargin(i, 1, .5, 1)
    end

    override(craftingQueueView, 'draw', function(super, self, ...)
        self.children = {}

        local added = 0
        for _, recipe in ipairs(recipes) do
            local color =
            recipe.error and C_BADGE_ERR or
                    recipe.crafting and C_BADGE_BUSY or
                    (recipe.stored or 0) < recipe.wanted and C_BADGE

            if color then
                local badge = GUI.container(1, 1, math.floor(self.width / columns - 1), 4)
                self:setPosition(1 + added % columns, 1, self:addChild(badge))
                badge:addChild(GUI.panel(1, 1, badge.width, 4, color))
                badge:addChild(GUI.text(2, 2, C_BADGE_TEXT, recipe.label)) -- TODO: include the item icon ?
                badge:addChild(GUI.text(2, 3, C_BADGE_TEXT, string.format('%s / %s', recipe.stored or '?', recipe.wanted)))
                if recipe.error then
                    badge:addChild(GUI.text(2, 4, C_BADGE_TEXT, tostring(recipe.error)))
                    badge:moveToFront()
                end

                added = added + 1
            end
        end

        super(self, ...)
    end)

    -- Configuration view
    local SYMBOL_CONFIG_RECIPE = {}
    local configView = window:addChild(GUI.container(1, 1, window.width, window.height))
    configView:addChild(GUI.panel(1, 1, configView.width, configView.height, C_BACKGROUND))
    configView.hidden = true

    -- left panel (item select)
    local itemListSearch = configView:addChild(GUI.input(2, 2, configView.width/2-1, 3,
            C_INPUT, C_INPUT_TEXT, C_INPUT_TEXT, C_STATUS_PRESSED, C_INPUT_TEXT, '', 'Поиск'))

    local itemListPanel = configView:addChild(GUI.list(
            itemListSearch.x, itemListSearch.y + itemListSearch.height + 1, itemListSearch.width, configView.height-itemListSearch.height-3,
            1, 0, C_BADGE, C_BADGE_TEXT, C_STATUS_BAR, C_STATUS_TEXT, C_BADGE_SELECTED, C_BADGE_TEXT
    ))
    itemListPanel.selectedItem = -1
    --itemListPanel:setAlignment(GUI.ALIGNMENT_HORIZONTAL_LEFT, GUI.ALIGNMENT_VERTICAL_TOP)
    -- attachScrollbar(itemListPanel)
	
	local sbWidth = (itemListPanel.width > 60) and 2 or 1
	itemListPanel.width = itemListPanel.width - sbWidth
    local itemListScrollBar = GUI.scrollBar(itemListPanel.x+itemListPanel.width, itemListPanel.y, sbWidth, itemListPanel.height, C_SCROLLBAR_BACKGROUND, C_SCROLLBAR,
            0, 1, 0, 1, 4, false)
	itemListPanel.parent:addChild(itemListScrollBar)
	itemListPanel.scrollBar = itemListScrollBar
	
	override(itemListPanel, 'eventHandler', function (super, app, self, key, ...)
        if key == 'scroll' then -- forward scrolls on the main object to the scrollbar
            itemListScrollBar.eventHandler(app, itemListScrollBar, key, ...)
        end
        super(app, self, key, ...)
    end)
	
	override(itemListScrollBar, 'eventHandler', function (super, app, self, key, ...)
        if key == 'touch' then
			GUI.alert("Теперь эта кривая хуйня не крашит. //мастер") --Если не нужно оповещение удалите)
			return
		end
        super(app, self, key, ...)
    end)
	
	override(itemListPanel, 'draw', function (super, self, ...)
		self.selectedItem = -1
		self.children = {}
		
		local selection = recipes
		local filter = itemListSearch.text
		
		if filter and filter ~= '' then
			filter = unicode.lower(filter)
			selection = {}
			self.scrollBar.value = self.scrollBar.minimumValue
			for _, recipe in ipairs(recipes) do
				-- Patterns seem very limited, no case-insensitive option
				if unicode.lower(recipe.label):find(filter) then
					table.insert(selection, recipe)
				end
			end
		end
		
		self.scrollBar.maximumValue = math.max(0, #selection - self.height)
		self.scrollBar.shownValueCount =  self.scrollBar.maximumValue / (self.scrollBar.maximumValue + 1)

		local offset = self.scrollBar.value
		for i = 1, math.min(self.height, #selection) do
			local recipe = selection[offset + i]
			local choice = self:addItem(recipe.label)
			--choice.colors.default.background = (recipe.error ~= nil) and C_BADGE_ERR or recipe.wanted > 0 and C_BADGE_BUSY or C_BADGE
			if recipe == configView[SYMBOL_CONFIG_RECIPE] then
				self.selectedItem = i
			end
			choice.onTouch = function(app, object)
				configView[SYMBOL_CONFIG_RECIPE] = recipe
				event.push('config_recipe_change')
			end
		end

		super(self, ...)
	end)

    -- right panel (item details)
    local reloadBtn = configView:addChild(GUI.button(configView.width/2+2, 2, configView.width/2-2, 3,
                                                     C_BADGE, C_BADGE_TEXT, C_BADGE, C_STATUS_PRESSED, "Перезагрузка рецептов"))
    reloadBtn.onTouch = function(app, self)
        event.push('ae2_loop', 'reload_recipes')
    end
    local itemConfigPanel = configView:addChild(GUI.layout(reloadBtn.x, reloadBtn.y + reloadBtn.height + 1, reloadBtn.width, configView.height-reloadBtn.height-7, 1, 1))
    configView:addChild(GUI.panel(itemConfigPanel.x, itemConfigPanel.y, itemConfigPanel.width, itemConfigPanel.height, C_BADGE)):moveBackward()
    itemConfigPanel:setAlignment(1, 1, GUI.ALIGNMENT_HORIZONTAL_CENTER, GUI.ALIGNMENT_VERTICAL_TOP)
    itemConfigPanel:setMargin(1, 1, .5, 1)

    override(itemConfigPanel, 'eventHandler', function(super, app, self, key, ...)
        if key == "config_recipe_change" then
            local recipe = configView[SYMBOL_CONFIG_RECIPE]

            self.children = {}
            self:addChild(GUI.text(1, 1, C_BADGE_TEXT, '[ '..recipe.label..' ]'))
            self:addChild(GUI.text(1, 1, C_BADGE_TEXT, "Хранится: "..tostring(recipe.stored)))
            self:addChild(GUI.text(1, 1, C_BADGE_TEXT, "Поддерживать"))
            local wantedInput = self:addChild(GUI.input(1, 1, 10, 3,
                    C_INPUT, C_INPUT_TEXT, 0, C_STATUS_PRESSED, C_INPUT_TEXT, tostring(recipe.wanted)))
            wantedInput.validator = numberValidator
            wantedInput.onInputFinished = function(app, object)
                recipe.wanted = tonumber(object.text) or error('cannot parse '..object.text)
                event.push('ae2_loop')
                event.push('save')
            end

            -- TODO: add remove/hide option

            -- self:draw()
            event.push('redraw') -- There is probably a more elegant way to do it ¯\_(ツ)_/¯
        end
        super(app, self, key, ...)
    end)

    local resetRecipeBtn = configView:addChild(GUI.button(itemConfigPanel.x, itemConfigPanel.y + itemConfigPanel.height + 1, itemConfigPanel.width, 3,
                                                          C_BADGE, C_BADGE_TEXT, C_BADGE, C_STATUS_PRESSED, "Не нажимать, будет cum. Русифицировано ananaslox ОнЖе AnalAnus"))
    resetRecipeBtn.onTouch = function(app, self)
        local recipe = configView[SYMBOL_CONFIG_RECIPE]
        if not recipe then return end
        for i, candidate in ipairs(recipes) do
            if (candidate == recipe) then
                table.remove(recipes, i)
                return
            end
        end
    end

    -- Status bar
    statusBar:addChild(GUI.panel(1, 1, statusBar.width, statusBar.height, C_STATUS_BAR))
    local statusText = statusBar:addChild(GUI.text(2, 1, C_STATUS_TEXT, ''))
    statusText.eventHandler = function(app, self)
        self.text = string.format('%d процессоров свободно из %d.  %d ошибок, %d текущее, %d запланировано.  Задержка: %.0f ms.',
            status.cpu.free, status.cpu.all, status.recipes.error, status.recipes.crafting, status.recipes.queue, status.update.duration * 1000)
    end
    statusText.eventHandler(app, statusText)
    local cfgBtn = statusBar:addChild(GUI.button(statusBar.width - 16, 1, 8, 1, C_STATUS_BAR, C_STATUS_TEXT, C_STATUS_BAR, C_STATUS_PRESSED, '[Настройки]'))
    cfgBtn.switchMode = true
    cfgBtn.animationDuration = .1
    cfgBtn.onTouch = function(app, object)
        configView.hidden = not object.pressed
    end
	
    statusBar:addChild(GUI.button(statusBar.width - 6, 1, 8, 1, C_STATUS_BAR, C_STATUS_TEXT, C_STATUS_BAR, C_STATUS_PRESSED, '[Выход]')).onTouch = function(app, object)
        event.push('exit')
    end
	statusBar:addChild(GUI.button(statusBar.width - 30, 1, 8, 1, C_STATUS_BAR, C_STATUS_TEXT, C_STATUS_BAR, C_STATUS_PRESSED, '[Перезагрузка]')).onTouch = function(app, object)
        computer.shutdown(true)
    end
	
    return app
end

-- Start the program
main()
