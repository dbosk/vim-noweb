-- lua/noweb/scan.lua -- the occurrence scan, Neovim fast path.
--
-- Mirrors the Vim script scan in autoload/noweb.vim construct for
-- construct; the two must produce identical results (the test suite
-- compares them).  Returns {name = {defs = {{lnum, col}, ...},
--                                   uses = {{lnum, col}, ...}}}.

return function()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local occ = {}
  local function entry(name)
    local e = occ[name]
    if not e then
      e = { defs = {}, uses = {} }
      occ[name] = e
    end
    return e
  end
  local in_code = false
  for i, line in ipairs(lines) do
    -- the s:HOT skip test: only @-lines and bracket lines can matter
    if line:byte(1) == 64 or line:find('<<', 1, true) then
      local name = line:match('^<<(.-)>>=%s*$')
      if name and name ~= '' then
        in_code = true
        table.insert(entry(name).defs, { i, 1 })
      elseif line == '@' or line:sub(1, 2) == '@ ' then
        in_code = false
      elseif in_code then
        local init = 1
	while true do
	  local s, e, ref = line:find('<<(.-)>>', init)
	  if not s then break end
	  if ref ~= '' and ref:sub(1, 1) ~= ' ' and ref:sub(-1) ~= ' '
	      and ref:sub(-1) ~= '@'
	      and (s == 1 or line:sub(s - 1, s - 1) ~= '@') then
	    table.insert(entry(ref).uses, { i, s })
	  end
	  init = e + 1
	end
      end
    end
  end
  return occ
end
