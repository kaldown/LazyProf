-- Modules/UI/Widgets/RowPool.lua
-- Reusable row frames for the side panels. WoW never frees a frame, so a
-- panel that made new rows on every update leaked frames on every craft.
-- A pool hands out rows made by its create function and takes them all back
-- at the start of the next update.
--
--   local pool = LazyProf.Widgets.RowPool.New(createFn, resetFn)
--   pool:Acquire()    -> a released row, or a new one from createFn()
--   pool:ReleaseAll() -> hides every acquired row, clears its points, calls
--                        resetFn(row) when given, and keeps it for reuse
--
-- The create function builds a row's regions once (font strings, textures,
-- child buttons and their fixed layout). Whoever acquires a row sets every
-- value it shows - size, point, texts, colours, icons, alpha, scripts - so a
-- reused row never shows what it showed before. Rows come back in the order
-- they were handed out, so an unchanged list reuses each row in its old spot.
local ADDON_NAME, LazyProf = ...

LazyProf.Widgets = LazyProf.Widgets or {}

local RowPool = {}
RowPool.__index = RowPool
LazyProf.Widgets.RowPool = RowPool

function RowPool.New(createFn, resetFn)
    return setmetatable({
        create = createFn,
        reset = resetFn,
        active = {},   -- rows handed out since the last ReleaseAll
        free = {},     -- released rows; the next one to hand out is last
        created = 0,
    }, RowPool)
end

function RowPool:Acquire()
    local free = self.free
    local row = free[#free]
    if row then
        free[#free] = nil
    else
        row = self.create()
        self.created = self.created + 1
    end
    self.active[#self.active + 1] = row
    return row
end

function RowPool:ReleaseAll()
    local active, free = self.active, self.free
    -- Release last to first so the first row is handed out first next time.
    for i = #active, 1, -1 do
        local row = active[i]
        active[i] = nil
        row:Hide()
        row:ClearAllPoints()
        if self.reset then
            self.reset(row)
        end
        free[#free + 1] = row
    end
end

-- Rows handed out since the last ReleaseAll.
function RowPool:NumActive()
    return #self.active
end

-- Rows this pool ever created.
function RowPool:NumCreated()
    return self.created
end
