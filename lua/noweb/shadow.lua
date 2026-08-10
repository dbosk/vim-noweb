-- lua/noweb/shadow.lua -- invisible tangled buffers backing language
-- intelligence (diagnostics, completion, hover, goto) in code chunks.
--
-- One shadow per typed root chunk: a hidden buffer holding
--   notangle -t8 -filter "linemark -c <leader>" -R<root>
-- of the live .nw buffer.  The linemark markers stay in the buffer
-- and provide the line maps; language servers attach to the shadow
-- and results map back into the .nw buffer.

local M = {}

-- state[nwbuf] = { tick = changedtick, roots = { [root] = shadow } }
-- shadow = { buf, root, lang, cfg, ns,
--            src = { tangled line -> source line },
--            fwd = { source line -> first tangled line },
--            marker = { tangled line -> true } }
local state = {}

-- NB: the skeleton splices the diagnostics chunk before the buffer
-- chunk, although the document presents them the other way around:
-- the autocmd closure in ensure_shadow captures forward_diagnostics
-- as an upvalue, which requires the local to exist first.

local defaults = {
  python = { leader = '#', filetype = 'python',
             lsp = { 'jedi-language-server' } },
  lean   = { leader = '--', filetype = 'lean' },
  lua    = { leader = '--', filetype = 'lua' },
}

local function language_config()
  return vim.tbl_deep_extend('force', defaults, vim.g.noweb_languages or {})
end

local function typed_roots(nwbuf)
  local occ, langs
  vim.api.nvim_buf_call(nwbuf, function()
    occ = vim.fn['noweb#occurrences']()
    langs = vim.fn['noweb#languages']()
  end)
  local cfg = language_config()
  local roots = {}
  for name, entry in pairs(occ) do
    if #entry.defs > 0 and #entry.uses == 0 then
      local lang = langs[name]
      if lang and cfg[lang] then
        roots[name] = { lang = lang, cfg = cfg[lang] }
      end
    end
  end
  return roots
end

local function tangle(nwbuf, root, leader)
  local lines = vim.api.nvim_buf_get_lines(nwbuf, 0, -1, false)
  local res = vim.system({
    'notangle', '-t8',
    '-filter', "linemark -c '" .. leader .. "'",
    '-R' .. root,
  }, { stdin = table.concat(lines, '\n') .. '\n', text = true }):wait(5000)
  if not res or res.code ~= 0 then
    return nil
  end
  local out = vim.split(res.stdout or '', '\n')
  if out[#out] == '' then
    table.remove(out)
  end
  return out
end

local function parse_maps(lines, leader)
  local pat = '^%s*' .. vim.pesc(leader) .. ' (%d+) "'
  local src, fwd, marker = {}, {}, {}
  local cur = nil
  for t, line in ipairs(lines) do
    local announced = line:match(pat)
    if announced then
      cur = tonumber(announced)
      marker[t] = true
      src[t] = cur
    elseif cur then
      src[t] = cur
      if not fwd[cur] then
        fwd[cur] = t
      end
      cur = cur + 1
    end
  end
  return src, fwd, marker
end

local function indent_width(line)
  return #(line:match('^%s*') or '')
end

local function col_delta(sh, t, nwbuf)
  local tline = (vim.api.nvim_buf_get_lines(sh.buf, t - 1, t, false)[1]) or ''
  local nline = (vim.api.nvim_buf_get_lines(
    nwbuf, sh.src[t] - 1, sh.src[t], false)[1]) or ''
  return indent_width(tline) - indent_width(nline)
end

local function forward_diagnostics(nwbuf, sh)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(sh.buf)) do
    local t = d.lnum + 1
    if sh.src[t] and not sh.marker[t] then
      local delta = col_delta(sh, t, nwbuf)
      local nd = vim.tbl_extend('force', {}, d)
      nd.bufnr = nwbuf
      nd.lnum = sh.src[t] - 1
      nd.col = math.max(0, d.col - delta)
      if nd.end_lnum and sh.src[nd.end_lnum + 1] then
        nd.end_lnum = sh.src[nd.end_lnum + 1] - 1
        nd.end_col = math.max(0, (nd.end_col or 0) - delta)
      else
        nd.end_lnum = nd.lnum
        nd.end_col = nd.col
      end
      table.insert(out, nd)
    end
  end
  vim.diagnostic.set(sh.ns, nwbuf, out)
end

local function shadow_name(nwbuf, root)
  local nwname = vim.api.nvim_buf_get_name(nwbuf)
  return nwname .. '.shadow/' .. root:gsub('[%[%]]', '')
end

local function ensure_shadow(nwbuf, root, lang, cfg)
  local st = state[nwbuf]
  local sh = st.roots[root]
  if not (sh and vim.api.nvim_buf_is_valid(sh.buf)) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, shadow_name(nwbuf, root))
    sh = { buf = buf, root = root, lang = lang, cfg = cfg,
           ns = vim.api.nvim_create_namespace('noweb-shadow:' .. root) }
    st.roots[root] = sh
    vim.bo[buf].filetype = cfg.filetype
    if cfg.lsp then
      vim.lsp.start({
        name = 'noweb-' .. lang,
        cmd = cfg.lsp,
        root_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(nwbuf)),
      }, { bufnr = buf })
    end
    vim.api.nvim_create_autocmd('DiagnosticChanged', {
      buffer = sh.buf,
      callback = function()
        if vim.api.nvim_buf_is_valid(nwbuf) then
          forward_diagnostics(nwbuf, sh)
        end
      end,
    })
  end
  return sh
end

function M.sync(nwbuf)
  nwbuf = (nwbuf and nwbuf ~= 0) and nwbuf or vim.api.nvim_get_current_buf()
  local st = state[nwbuf]
  if not st then
    return nil
  end
  local tick = vim.api.nvim_buf_get_changedtick(nwbuf)
  if st.tick == tick then
    return st
  end
  st.tick = tick
  local roots = typed_roots(nwbuf)
  for root, sh in pairs(st.roots) do
    if not roots[root] then
      vim.diagnostic.reset(sh.ns, nwbuf)
      pcall(vim.api.nvim_buf_delete, sh.buf, { force = true })
      st.roots[root] = nil
    end
  end
  for root, info in pairs(roots) do
    local lines = tangle(nwbuf, root, info.cfg.leader)
    if lines then
      local sh = ensure_shadow(nwbuf, root, info.lang, info.cfg)
      sh.src, sh.fwd, sh.marker = parse_maps(lines, info.cfg.leader)
      local old = vim.api.nvim_buf_get_lines(sh.buf, 0, -1, false)
      if not vim.deep_equal(old, lines) then
        vim.api.nvim_buf_set_lines(sh.buf, 0, -1, false, lines)
      end
      forward_diagnostics(nwbuf, sh)
    end
  end
  return st
end

-- Locate source line lnum: returns shadow, tangled line, column delta.
function M.locate(nwbuf, lnum)
  nwbuf = (nwbuf and nwbuf ~= 0) and nwbuf or vim.api.nvim_get_current_buf()
  local st = M.sync(nwbuf)
  if not st then
    return nil
  end
  for _, sh in pairs(st.roots) do
    local t = sh.fwd[lnum]
    if t then
      return sh, t, col_delta(sh, t, nwbuf)
    end
  end
  return nil
end

function M.setup(nwbuf)
  nwbuf = (nwbuf and nwbuf ~= 0) and nwbuf or vim.api.nvim_get_current_buf()
  if state[nwbuf] then
    return
  end
  state[nwbuf] = { tick = -1, roots = {} }
  local group = vim.api.nvim_create_augroup('noweb-shadow:' .. nwbuf, {})
  local pending = false
  vim.api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave' }, {
    group = group,
    buffer = nwbuf,
    callback = function()
      if not pending then
        pending = true
        vim.defer_fn(function()
          pending = false
          if vim.api.nvim_buf_is_valid(nwbuf) then
            M.sync(nwbuf)
          end
        end, 300)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = nwbuf,
    callback = function()
      for _, sh in pairs(state[nwbuf].roots) do
        pcall(vim.api.nvim_buf_delete, sh.buf, { force = true })
      end
      state[nwbuf] = nil
      vim.api.nvim_del_augroup_by_id(group)
    end,
  })
  M.sync(nwbuf)
end

return M
