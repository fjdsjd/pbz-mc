-- Two generations are used because Windows Lua os.rename cannot replace a file.
-- flush/close protects ordinary process restarts; it is NOT FlushFileBuffers.
local M={}
local windows=package.config:sub(1,1)=='\\'
-- Lua uses CRT fopen/rename/remove, whose ordinary paths still depend on the
-- host EXE manifest and the user's Windows policy. Immutable checkpoint names
-- already reach MAX_PATH in a normal Steam library. Keep their on-disk names
-- and hashes, but pass absolute Windows paths through the extended namespace.
local function native_path(path)
  if not windows then return path end
  local p=path:gsub('/','\\')
  if p:sub(1,4)=='\\\\?\\' then return p end
  local root,tail=p:match('^(%a:\\)(.*)$')
  if not root then
    local server,share,rest=p:match('^\\\\([^\\]+)\\([^\\]+)\\?(.*)$')
    if server and server~='.' then root='UNC\\'..server..'\\'..share..'\\';tail=rest end
  end
  if not root then return path end -- Relative test paths retain CRT semantics.
  local parts={}
  for part in tail:gmatch('[^\\]+')do
    if part=='..' then parts[#parts]=nil elseif part~='.'then parts[#parts+1]=part end
  end
  return '\\\\?\\'..root..table.concat(parts,'\\')
end
local function failure(operation,path,why,code)
  error(('PBZMC-IO: %s failed (path_chars=%d, errno=%s): %s; path=%s')
    :format(operation,#path,tostring(code or '?'),tostring(why),path),0)
end
function M.is_error(why) return tostring(why):find('PBZMC-IO:',1,true)~=nil end
function M.read(path,maximum)
  local f,err,code=io.open(native_path(path),'rb')
  if not f then
    if code==2 then return nil end
    failure('read/open',path,err,code)
  end
  -- The old build journal retains its limit. The paged player store explicitly
  -- passes false for its growing manifest/core, never a hidden total page cap.
  if maximum==nil then maximum=16*1024*1024 end
  -- Read once instead of seeking to EOF and back for every journal fence.
  -- A bounded read still rejects the extra byte and an empty file stays ''.
  local value,why=f:read(maximum and maximum+1 or 'a')
  if value==nil and why==nil then value='' end
  local closed,close_error=f:close()
  if not value then failure('read',path,why)end
  if not closed then failure('read/close',path,close_error)end
  assert(not maximum or #value<=maximum,'save-too-large')
  return value
end
function M.write(path,value)
  local f,why,code=io.open(native_path(path),'wb')
  if not f then failure('write/open',path,why,code)end
  local ok,err=pcall(function() assert(f:write(value));assert(f:flush()) end)
  local closed,close_error=f:close()
  if not ok then failure('write/flush',path,err)end
  if not closed then failure('write/close',path,close_error)end
end
function M.remove(path)
  local ok,why,code=os.remove(native_path(path));if not ok then failure('remove',path,why,code)end
end
function M.rename(source,destination)
  local ok,why,code=os.rename(native_path(source),native_path(destination))
  if not ok then failure('rename from '..source,destination,why,code)end
end
return M
