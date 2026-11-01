-- P08/P22/P29: synchronous game-thread placement transaction.
-- Native handles never enter the durable candidate. Adapters must fail explicitly.
local M = {}
local state = require('storage.state')
local function copy(value)local out={};for k,v in pairs(value or {})do out[k]=v end;return out end
local function building_candidate(data)
    local candidate=copy(data);candidate.buildings=copy(data.buildings)
    return candidate
end
function M.place(session, request, host, store)
    if session.quarantined then return false, 'cleanup-required' end
    if session.busy then return false, 'transaction-in-progress' end
    if request.generation ~= session.generation then return false, 'stale-scene' end
    if type(session.world)~='string' or session.world=='' then return false,'missing-world' end
    if type(request.content_id) ~= 'string' or not request.content_id:match('^pbzmc:[a-z0-9_]+$') then
        return false, 'invalid-content-id'
    end
    if type(request.instance_id) ~= 'string' or request.instance_id == '' then return false, 'invalid-instance-id' end
    if session.data.buildings[request.instance_id] then return false, 'duplicate-instance' end
    local cost = request.cost
    if cost ~= 0 and cost ~= 1 then return false, 'invalid-cost' end
    local quantity = session.data.inventory[request.content_id] or 0
    if quantity < cost then return false, 'insufficient-items' end
    for _, key in ipairs({'x','y','z','yaw'}) do
        local n = request[key]
        if type(n) ~= 'number' or n ~= n or math.abs(n) == math.huge then return false, 'invalid-transform' end
    end
    local properties_ok,properties=pcall(require('rules.block_properties').copy,request.properties)
    if not properties_ok then return false,'invalid-block-properties' end
    session.busy = true
    local handle
    local candidate = building_candidate(session.data)
    local record = {id=request.instance_id, content_id=request.content_id,world=session.world,
        x=request.x,y=request.y,z=request.z,yaw=request.yaw,properties=properties}
    local ok, err = pcall(function()
        assert(host:can_place(record), 'occupied-or-unavailable')
        -- create must self-clean partial construction before throwing.
        handle = host:create(record)
        assert(handle and handle.rendered and handle.colliding, 'incomplete-native-object')
        assert(session.generation == request.generation, 'scene-changed')
        candidate.buildings[record.id] = record
        if request.grid then
            candidate.building_grids=copy(candidate.building_grids)
            candidate.building_grids[session.world]=state.clone(request.grid)
        end
        if cost>0 then candidate.inventory=copy(candidate.inventory);candidate.inventory[record.content_id] = quantity-cost end
        -- Atomic durable commit includes BOTH inventory and building state.
        -- false/throw must mean no commit. Ambiguous IO belongs in store recovery.
        local committed, why = store:commit(candidate,cost==0 and {{after=record}}or nil)
        assert(committed, why or 'durable-commit-failed')
    end)
    if not ok then
        if type(err)=='table' and err.cleanup_handle then
            session.quarantined=true
            session.pending_cleanup=err.cleanup_handle
            session.pending_action='destroy'
            err=err.reason or 'partial-construction-cleanup-failed'
        elseif handle then
            local clean, removed = pcall(host.destroy,host,handle)
            if not clean or removed ~= true then
                session.quarantined = true
                session.pending_cleanup = handle
                session.pending_action='destroy'
                err = tostring(err)..'; native-cleanup-pending: '..tostring(removed)
            end
        end
        session.busy = false
        return false, tostring(err)
    end
    session.data = candidate
    session.handles[record.id] = handle
    session.busy = false
    if session.notify then session:notify({{after=record}})end
    return true, record.id
end

-- Disable native interaction first; keep the object available for rollback.
-- The irreversible native destruction happens only after the durable commit.
function M.remove(session, request, host, store)
    if session.quarantined then return false,'cleanup-required' end
    if session.busy then return false,'transaction-in-progress' end
    if request.generation~=session.generation then return false,'stale-scene' end
    local record=session.data.buildings[request.instance_id]
    local handle=session.handles[request.instance_id]
    if not record or not handle then return false,'unknown-or-unrestored-instance' end
    if record.world~=session.world then return false,'wrong-world' end
    if request.refund~=0 and request.refund~=1 then return false,'invalid-refund' end
    session.busy=true
    local candidate=building_candidate(session.data)
    local attempted=false
    local ok,err=pcall(function()
        attempted=true
        assert(host:set_active(handle,false),'deactivate-failed')
        assert(session.generation==request.generation,'scene-changed')
        candidate.buildings[record.id]=nil
        if request.refund>0 then
            candidate.inventory=copy(candidate.inventory)
            candidate.inventory[record.content_id]=(candidate.inventory[record.content_id] or 0)+request.refund
        end
        local committed,why=store:commit(candidate,request.refund==0 and {{before=record}}or nil)
        assert(committed,why or 'durable-commit-failed')
    end)
    if not ok then
        if attempted then
            local restored,active=pcall(host.set_active,host,handle,true)
            if not restored or active~=true then
                session.quarantined=true;session.pending_cleanup=handle
                session.pending_action='activate'
                err=tostring(err)..'; native-reactivation-failed'
            end
        end
        session.busy=false
        return false,tostring(err)
    end
    session.data=candidate;session.handles[record.id]=nil;session.busy=false
    if session.notify then session:notify({{before=record}})end
    local clean,removed=pcall(host.destroy,host,handle)
    if not clean or removed~=true then
        session.quarantined=true;session.pending_cleanup=handle
        session.pending_action='destroy'
        return true,'committed-cleanup-pending'
    end
    return true,record.id
end
return M
