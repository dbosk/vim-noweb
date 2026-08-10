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

-- NB: the skeleton splices a few chunks in dependency order rather
-- than the document's presentation order: a closure captures a local
-- as an upvalue only if the local exists at definition time, so
-- forward_diagnostics precedes ensure_shadow's autocmd, and the
-- preview state precedes sync's view refresh.

-- A language without an lsp entry still earns its shadow: the
-- preview, :NowebMake and the pattern-based gd all work for any
-- typed root.  definitions are Lua patterns over tangled lines;
-- @NAME@ stands for the (escaped) identifier.
local defaults = {
  python = { leader = '#', filetype = 'python',
             lsp = { 'jedi-language-server' },
             definitions = { '^%s*def%s+@NAME@%s*%(',
                             '^%s*class%s+@NAME@%f[%W]',
                             '^%s*@NAME@%s*=',
                             '%f[%w]for%s+@NAME@%f[%W]' } },
  lean   = { leader = '--', filetype = 'lean',
             definitions = { '%f[%w]def%s+@NAME@%f[%W]',
                             '%f[%w]theorem%s+@NAME@%f[%W]',
                             '%f[%w]lemma%s+@NAME@%f[%W]',
                             '%f[%w]structure%s+@NAME@%f[%W]' } },
  lua    = { leader = '--', filetype = 'lua',
             definitions = { 'function%s+@NAME@%f[%W]',
                             'local%s+function%s+@NAME@%f[%W]',
                             'local%s+@NAME@%f[%W]',
                             '^%s*@NAME@%s*=',
                             '%f[%w]for%s+@NAME@%f[%W]' } },
  sh     = { leader = '#', filetype = 'sh',
             definitions = { '^%s*@NAME@%s*%(%s*%)',
                             '^%s*function%s+@NAME@%f[%W]',
                             '^%s*@NAME@=', '^%s*@NAME@%+=',
                             '^%s*local%s[^=]*%f[%w]@NAME@%f[%W]',
                             '^%s*export%s[^=]*%f[%w]@NAME@%f[%W]',
                             '^%s*typeset%s[^=]*%f[%w]@NAME@%f[%W]',
                             '^%s*declare%s[^=]*%f[%w]@NAME@%f[%W]',
                             '^%s*readonly%s[^=]*%f[%w]@NAME@%f[%W]',
                             '%f[%w]for%s+@NAME@%f[%W]',
                             '%f[%w]read%s+@NAME@%f[%W]',
                             '%f[%w]@NAME@=', '%f[%w]@NAME@%+=' } },
  make   = { leader = '#', filetype = 'make',
             definitions = { '^@NAME@%s*:' } },
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

local function tangle(nwbuf, root, cfg)
  local lines = vim.api.nvim_buf_get_lines(nwbuf, 0, -1, false)
  local argv = { 'notangle' }
  vim.list_extend(argv, cfg.tangle or {})
  vim.list_extend(argv, {
    '-filter', "linemark -c '" .. cfg.leader .. "'",
    '-R' .. root,
  })
  local res = vim.system(argv,
    { stdin = table.concat(lines, '\n') .. '\n', text = true }):wait(5000)
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

local preview = {}  -- preview[nwbuf] = { win, nwwin, sh, group }
local syncing = false

local function preview_close(nwbuf)
  local p = preview[nwbuf]
  if not p then
    return
  end
  preview[nwbuf] = nil
  pcall(vim.api.nvim_del_augroup_by_id, p.group)
  if vim.api.nvim_win_is_valid(p.win) then
    pcall(vim.api.nvim_win_close, p.win, true)
  end
  if p.pbuf ~= p.sh.buf and vim.api.nvim_buf_is_valid(p.pbuf) then
    pcall(vim.api.nvim_buf_delete, p.pbuf, { force = true })
  end
end

-- The marker-free view of a shadow: fill pbuf with the non-marker
-- lines and return the two composition maps (view line <-> tangled
-- line; a marker maps forward to the next kept line).
local function refresh_view(pbuf, sh)
  local lines = vim.api.nvim_buf_get_lines(sh.buf, 0, -1, false)
  local view, pv2t, t2pv = {}, {}, {}
  for t, line in ipairs(lines) do
    if sh.marker[t] then
      t2pv[t] = #view + 1
    else
      table.insert(view, line)
      pv2t[#view] = t
      t2pv[t] = #view
    end
  end
  for t, pv in pairs(t2pv) do
    if pv > #view then
      t2pv[t] = #view
    end
  end
  vim.bo[pbuf].modifiable = true
  vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, view)
  vim.bo[pbuf].modifiable = false
  return pv2t, t2pv
end

local function strip_quotes(name)
  return (name:gsub('%[%[', ''):gsub('%]%]', ''))
end

local function preview_pick(st, root, lnum)
  if root and root ~= '' then
    if st.roots[root] then
      return st.roots[root]
    end
    for name, sh in pairs(st.roots) do
      if name == '[[' .. root .. ']]' or strip_quotes(name) == root then
        return sh
      end
    end
    return nil
  end
  local only, n, holder = nil, 0, nil
  for _, sh in pairs(st.roots) do
    n = n + 1
    only = sh
    if sh.fwd[lnum] or sh.fwd[lnum + 1] then
      holder = sh
    end
  end
  return holder or (n == 1 and only or nil)
end

-- Root names of the current buffer's shadows, for command completion.
function M.roots()
  local st = M.sync(vim.api.nvim_get_current_buf())
  local out = {}
  for name in pairs(st and st.roots or {}) do
    table.insert(out, name)
  end
  table.sort(out)
  return out
end

function M.preview(root, mods)
  local nwbuf = vim.api.nvim_get_current_buf()
  if preview[nwbuf] then
    preview_close(nwbuf)
    return
  end
  local st = M.sync(nwbuf)
  if not st then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local sh = preview_pick(st, root, lnum)
  if not sh then
    vim.notify('noweb: name the root: :NowebTangled <root>  ('
      .. table.concat(M.roots(), ', ') .. ')', vim.log.levels.WARN)
    return
  end
  local show, pv2t, t2pv = sh.buf, nil, nil
  if vim.g.noweb_tangled_markers ~= 1 then
    show = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(show,
      shadow_name(nwbuf, sh.root) .. ' (tangled)')
    pv2t, t2pv = refresh_view(show, sh)
    vim.bo[show].filetype = sh.cfg.filetype
  else
    vim.bo[show].modifiable = false
  end
  local nwwin = vim.api.nvim_get_current_win()
  if mods and mods ~= '' then
    vim.cmd(mods .. ' split')
  else
    vim.cmd(vim.g.noweb_tangled_split or 'rightbelow split')
  end
  local pwin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(pwin, show)
  vim.wo[pwin].cursorline = true
  local group = vim.api.nvim_create_augroup('noweb-preview:' .. nwbuf, {})
  preview[nwbuf] = { win = pwin, nwwin = nwwin, sh = sh, group = group,
                     pbuf = show, pv2t = pv2t, t2pv = t2pv }
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = nwbuf,
    callback = function()
      local p = preview[nwbuf]
      if syncing or not p or not vim.api.nvim_win_is_valid(p.win) then
        return
      end
      local t = p.sh.fwd[vim.api.nvim_win_get_cursor(0)[1]]
      if t then
        syncing = true
        vim.api.nvim_win_set_cursor(p.win, { p.t2pv and p.t2pv[t] or t, 0 })
        vim.api.nvim_win_call(p.win, function() vim.cmd('normal! zz') end)
        syncing = false
      end
    end,
  })
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = show,
    callback = function()
      local p = preview[nwbuf]
      if syncing or not p or not vim.api.nvim_win_is_valid(p.nwwin) then
        return
      end
      local l = vim.api.nvim_win_get_cursor(0)[1]
      local s = p.sh.src[p.pv2t and p.pv2t[l] or l]
      if s then
        syncing = true
        vim.api.nvim_win_set_cursor(p.nwwin, { s, 0 })
        vim.api.nvim_win_call(p.nwwin, function() vim.cmd('normal! zz') end)
        syncing = false
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(pwin),
    callback = function()
      preview_close(nwbuf)
    end,
  })
  local t = sh.fwd[lnum]
  if t then
    vim.api.nvim_win_set_cursor(pwin, { t2pv and t2pv[t] or t, 0 })
    vim.api.nvim_win_call(pwin, function() vim.cmd('normal! zz') end)
  end
  vim.api.nvim_set_current_win(nwwin)
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
    local lines = tangle(nwbuf, root, info.cfg)
    if lines then
      local sh = ensure_shadow(nwbuf, root, info.lang, info.cfg)
      sh.src, sh.fwd, sh.marker = parse_maps(lines, info.cfg.leader)
      local old = vim.api.nvim_buf_get_lines(sh.buf, 0, -1, false)
      if not vim.deep_equal(old, lines) then
        -- the preview marks the shadow nomodifiable; lift it briefly
        local mod = vim.bo[sh.buf].modifiable
        vim.bo[sh.buf].modifiable = true
        vim.api.nvim_buf_set_lines(sh.buf, 0, -1, false, lines)
        vim.bo[sh.buf].modifiable = mod
      end
      forward_diagnostics(nwbuf, sh)
      local p = preview[nwbuf]
      if p and p.sh == sh and p.pbuf ~= sh.buf
          and vim.api.nvim_buf_is_valid(p.pbuf) then
        p.pv2t, p.t2pv = refresh_view(p.pbuf, sh)
      end
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

local function cursor_params(nwbuf)
  local lnum, col = unpack(vim.api.nvim_win_get_cursor(0))
  local sh, t, delta = M.locate(nwbuf, lnum)
  if not sh or #vim.lsp.get_clients({ bufnr = sh.buf }) == 0 then
    return nil
  end
  return sh, {
    textDocument = { uri = vim.uri_from_bufnr(sh.buf) },
    position = { line = t - 1, character = col + delta },
  }
end

function M.complete(base)
  local nwbuf = vim.api.nvim_get_current_buf()
  local sh, params = cursor_params(nwbuf)
  if not sh then
    return {}
  end
  local results = vim.lsp.buf_request_sync(
    sh.buf, 'textDocument/completion', params, 3000)
  local items = {}
  for _, res in pairs(results or {}) do
    for _, it in ipairs((res.result and (res.result.items or res.result)) or {}) do
      -- Servers may offer snippet insertText ($0 placeholders); an
      -- omnifunc inserts plain text, so those fall back to the label.
      local word = it.label
      if (it.insertTextFormat or 1) == 1 then
        word = (it.textEdit and it.textEdit.newText)
          or it.insertText or it.label
      end
      if vim.startswith(it.filterText or it.label, base)
          or vim.startswith(word, base) then
        local doc = it.documentation
        table.insert(items, {
          word = word,
          abbr = it.label,
          menu = vim.lsp.protocol.CompletionItemKind[it.kind] or '',
          info = type(doc) == 'table' and doc.value or doc or '',
          icase = 0,
          dup = 0,
        })
      end
    end
  end
  return items
end
function M.hover()
  local sh, params = cursor_params(vim.api.nvim_get_current_buf())
  if not sh then
    return false
  end
  local results = vim.lsp.buf_request_sync(
    sh.buf, 'textDocument/hover', params, 3000)
  for _, res in pairs(results or {}) do
    if res.result and res.result.contents then
      local lines = vim.lsp.util.convert_input_to_markdown_lines(
        res.result.contents)
      if #lines > 0 then
        vim.lsp.util.open_floating_preview(lines, 'markdown',
          { border = 'rounded' })
        return true
      end
    end
  end
  return false
end

function M.definition()
  local nwbuf = vim.api.nvim_get_current_buf()
  local sh, params = cursor_params(nwbuf)
  if sh then
    local results = vim.lsp.buf_request_sync(
      sh.buf, 'textDocument/definition', params, 3000)
    for _, res in pairs(results or {}) do
      local locs = res.result or {}
      if locs.uri or locs.targetUri then
        locs = { locs }
      end
      for _, loc in ipairs(locs) do
        local uri = loc.uri or loc.targetUri
        local range = loc.range or loc.targetSelectionRange
        vim.cmd([[normal! m']])
        if uri == vim.uri_from_bufnr(sh.buf) then
          local nl = sh.src[range.start.line + 1]
          if nl then
            local d = col_delta(sh, range.start.line + 1, nwbuf)
            vim.api.nvim_win_set_cursor(0,
              { nl, math.max(0, range.start.character - d) })
            return true
          end
        else
          local client = vim.lsp.get_clients({ bufnr = sh.buf })[1]
          vim.lsp.util.show_document(loc, client.offset_encoding,
            { focus = true })
          return true
        end
      end
    end
  end
  return M.pattern_definition(nwbuf)
end

-- The serverless fallback: search the shadow for a line matching one
-- of the language's definition patterns for the identifier under the
-- cursor, and jump to its source line in the .nw.
function M.pattern_definition(nwbuf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local sh = M.locate(nwbuf, lnum)
  if not sh or not sh.cfg.definitions then
    return false
  end
  local name = vim.fn.expand('<cword>')
  if name == '' then
    return false
  end
  -- pesc's % escapes are themselves magic in a gsub replacement
  local escaped = vim.pesc(name):gsub('%%', '%%%%')
  local pats = {}
  for _, p in ipairs(sh.cfg.definitions) do
    table.insert(pats, (p:gsub('@NAME@', escaped)))
  end
  local lines = vim.api.nvim_buf_get_lines(sh.buf, 0, -1, false)
  for t, line in ipairs(lines) do
    if not sh.marker[t] and sh.src[t] then
      for _, pat in ipairs(pats) do
        local s = line:find(pat)
        if s then
          vim.cmd([[normal! m']])
          local d = col_delta(sh, t, nwbuf)
          vim.api.nvim_win_set_cursor(0,
            { sh.src[t], math.max(0, s - 1 - d) })
          return true
        end
      end
    end
  end
  return false
end

function M.make(cmd)
  local nwbuf = vim.api.nvim_get_current_buf()
  if vim.bo[nwbuf].modified then
    vim.notify('noweb: save the buffer first; :NowebMake builds the file',
      vim.log.levels.WARN)
    return
  end
  local st = M.sync(nwbuf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local sh = st and preview_pick(st, nil, lnum)
  if not sh then
    vim.notify('noweb: no typed root here', vim.log.levels.WARN)
    return
  end
  local nwfile = vim.api.nvim_buf_get_name(nwbuf)
  local tmp = vim.fn.tempname() .. (sh.root:match('%.%w+$') or '')
  local tangle = vim.system({ 'sh', '-c', string.format(
    'notangle %s -filter "linemark -c \'%s\'" -R\'%s\' \'%s\' > \'%s\'',
    table.concat(sh.cfg.tangle or {}, ' '),
    sh.cfg.leader, sh.root, nwfile, tmp) }):wait()
  if tangle.code ~= 0 then
    vim.notify('noweb: tangling failed: ' .. (tangle.stderr or ''),
      vim.log.levels.ERROR)
    return
  end
  local run = vim.system(
    { 'sh', '-c', 'nolinemap ' .. cmd:gsub('%%', tmp) .. ' 2>&1' },
    { text = true }):wait()
  vim.fn.setqflist({}, ' ', {
    title = 'NowebMake: ' .. cmd,
    lines = vim.split(run.stdout or '', '\n'),
    efm = '%*[ ]File "%f"\\, line %l%.%#,'
      .. '%f:%l:%c: %m,%f:%l: %m,%-G%.%#',
  })
  vim.cmd('copen | wincmd p')
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
