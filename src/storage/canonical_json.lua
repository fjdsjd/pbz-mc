-- Deterministic JSON for content addresses. Intern repeated scalar encodings
-- within this call (world paths, field names, coordinates); never cache a table
-- across transactions. This retains the existing byte format and validation.
local json=require('dkjson')
local state=require('storage.state')
return function(value)
  state.validate_value(value)
  local buffer,atoms={},{}
  local function atom(v)
    if type(v)=='number' and v%1==0 then v=math.tointeger(v) or v end
    local encoded=atoms[v]
    if not encoded then
      encoded=type(v)=='string' and json.quotestring(v) or json.encode(v)
      atoms[v]=encoded
    end
    return encoded
  end
  local function write(v)
    if type(v)~='table' or v==json.null then buffer[#buffer+1]=atom(v);return end
    if state.json_kind(v)=='array' then
      buffer[#buffer+1]='['
      for i,child in ipairs(v) do if i>1 then buffer[#buffer+1]=',' end;write(child) end
      buffer[#buffer+1]=']'
    else
      local keys={};for key in pairs(v) do keys[#keys+1]=key end;table.sort(keys)
      buffer[#buffer+1]='{'
      for i,key in ipairs(keys) do
        if i>1 then buffer[#buffer+1]=',' end
        buffer[#buffer+1]=atom(key);buffer[#buffer+1]=':';write(v[key])
      end
      buffer[#buffer+1]='}'
    end
  end
  write(value);return table.concat(buffer)
end
