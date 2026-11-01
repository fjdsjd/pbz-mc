-- Two generations are used because Windows Lua os.rename cannot replace a file.
-- flush/close protects ordinary process restarts; it is NOT FlushFileBuffers.
local M={}
function M.read(path,maximum)
  local f,err,code=io.open(path,'rb')
  if not f then
    if code==2 then return nil end
    error('read-failed: '..tostring(err))
  end
  -- The old build journal retains its limit. The paged player store explicitly
  -- passes false for its growing manifest/core, never a hidden total page cap.
  if maximum==nil then maximum=16*1024*1024 end
  -- Read once instead of seeking to EOF and back for every journal fence.
  -- A bounded read still rejects the extra byte and an empty file stays ''.
  local value,why=f:read(maximum and maximum+1 or 'a')
  if value==nil and why==nil then value='' end
  local closed,close_error=f:close()
  assert(value,why);assert(closed,close_error)
  assert(not maximum or #value<=maximum,'save-too-large')
  return value
end
function M.write(path,value)
  local f=assert(io.open(path,'wb'))
  local ok,err=pcall(function() assert(f:write(value));assert(f:flush()) end)
  local closed,close_error=f:close()
  assert(ok,err);assert(closed,close_error)
end
function M.remove(path) assert(os.remove(path)) end
function M.rename(source,destination) assert(os.rename(source,destination)) end
return M
