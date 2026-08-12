" autoload/noweb.vim -- per-chunk language inference for noweb sources
"
" Ports the algorithm of the "autolang" filter from noweb's tominted.nw:
" every code chunk is seeded with a language from a filename-like chunk
" name or a #! line, and those languages then propagate along <<use>>
" edges (a worklist with conflict detection), so a descriptively-named
" chunk used by a typed root inherits the root's language.  On Neovim
" the seeds come from the editor's own filetype database
" (vim.filetype.match); fixed tables remain as the fallback.  The result
" drives one :syntax region per language, each including that language's
" own syntax file on demand.

" Chunk name (verbatim basename) -> Vim syntax name.
let s:lexers_by_name = {
      \ 'Makefile': 'make', 'makefile': 'make', 'GNUmakefile': 'make',
      \ }

" Chunk name extension -> Vim syntax name (the canonical language key).
let s:lexers_by_ext = {
      \ '.py': 'python', '.pyw': 'python',
      \ '.c': 'c', '.h': 'c',
      \ '.cpp': 'cpp', '.cc': 'cpp', '.cxx': 'cpp', '.C': 'cpp',
      \ '.hpp': 'cpp', '.hh': 'cpp', '.hxx': 'cpp',
      \ '.sh': 'sh', '.bash': 'sh', '.zsh': 'sh', '.ksh': 'sh',
      \ '.ml': 'ocaml', '.mli': 'ocaml',
      \ '.mk': 'make',
      \ '.pl': 'perl', '.pm': 'perl',
      \ '.rb': 'ruby', '.lua': 'lua', '.php': 'php',
      \ '.js': 'javascript', '.mjs': 'javascript', '.ts': 'typescript',
      \ '.java': 'java', '.r': 'r', '.R': 'r',
      \ '.vim': 'vim', '.awk': 'awk', '.sed': 'sed',
      \ '.hs': 'haskell', '.go': 'go', '.rs': 'rust',
      \ '.sql': 'sql', '.html': 'html', '.css': 'css',
      \ '.tex': 'tex', '.yml': 'yaml', '.yaml': 'yaml',
      \ }

" Interpreter basename from a #! line -> Vim syntax name.
let s:interpreters = {
      \ 'python': 'python', 'python2': 'python', 'python3': 'python',
      \ 'sh': 'sh', 'bash': 'sh', 'dash': 'sh', 'ksh': 'sh', 'zsh': 'sh',
      \ 'perl': 'perl', 'ruby': 'ruby', 'lua': 'lua', 'php': 'php',
      \ 'node': 'javascript', 'nodejs': 'javascript',
      \ 'awk': 'awk', 'gawk': 'awk', 'sed': 'sed', 'Rscript': 'r',
      \ }

let s:CONFLICT = "\x00conflict\x00"

" Name-pattern rules, checked before everything else (mirrors
" autolang's -langrule, values as Vim filetypes).  The defaults track
" the makefiles repository's default weave; g:noweb_langrules
" prepends user rules, first match wins.
let s:LANGRULES = [
      \ ['^test \[\[.*\.py\]\]', 'python'],
      \ ['^test \[\[.*\.sh\]\]', 'sh'],
      \ ['^test \[\[Makefile\]\]', 'make'],
      \ ]

" Ask the editor's filetype database for ARGS, e.g. {'filename': ...}
" or {'filename': ..., 'contents': [...]}.  Returns '' when there is
" no answer or no database to ask.
let s:ft_cache = {}
function! s:filetype_match(args) abort
  let l:key = string(a:args)
  if !has_key(s:ft_cache, l:key)
    if has('nvim')
      let s:ft_cache[l:key] = luaeval('vim.filetype.match(_A) or ""', a:args)
    elseif exists('#filetypedetect#BufRead')
      let s:ft_cache[l:key] = s:detect_in_scratch(a:args)
    else
      let s:ft_cache[l:key] = ''
    endif
  endif
  return s:ft_cache[l:key]
endfunction

" Vim's counterpart of vim.filetype.match: run the filetypedetect
" autocommands against a throwaway buffer with the candidate name and
" contents, and read the &filetype they assign.
let s:scratch_dir = tempname()
function! s:detect_in_scratch(args) abort
  let l:ft = ''
  let l:eventignore = &eventignore
  set eventignore=all
  try
    silent execute 'keepalt new'
          \ fnameescape(s:scratch_dir . '/' . get(a:args, 'filename', 'noweb-chunk'))
    setlocal buftype=nofile noswapfile
    if has_key(a:args, 'contents')
      call setline(1, a:args['contents'])
    endif
    set eventignore=FileType
    silent doautocmd filetypedetect BufRead
    let l:ft = &l:filetype
  finally
    set eventignore=all
    silent! bwipeout!
    let &eventignore = l:eventignore
  endtry
  return l:ft
endfunction

" Return the Vim syntax name for chunk NAME, or '' if its name says nothing.
" A g:noweb_langrules/s:LANGRULES rule matching the whole name wins;
" otherwise the name may use noweb's [[...]] quoting and may contain
" directory separators, and only the basename decides (mirrors
" autolang's lexer_for_chunk).
function! s:lexer_for_chunk(name) abort
  for l:rule in get(g:, 'noweb_langrules', []) + s:LANGRULES
    if a:name =~# l:rule[0]
      return l:rule[1]
    endif
  endfor
  let l:name = a:name
  if l:name =~# '^\[\[.*\]\]$'
    let l:name = l:name[2:-3]
  endif
  let l:base = matchstr(l:name, '[^/]*$')
  let l:ft = s:filetype_match({'filename': l:base})
  if l:ft !=# ''
    return l:ft
  endif
  if has_key(s:lexers_by_name, l:base)
    return s:lexers_by_name[l:base]
  endif
  let l:dot = strridx(l:base, '.')
  if l:dot >= 0
    let l:ext = strpart(l:base, l:dot)
    if has_key(s:lexers_by_ext, l:ext)
      return s:lexers_by_ext[l:ext]
    endif
  endif
  return ''
endfunction

" Return the language a #! line names, or '' if it is not a #! line.
function! s:shebang_lang(line) abort
  if a:line !~# '^#!'
    return ''
  endif
  let l:ft = s:filetype_match({'filename': 'noweb-chunk', 'contents': [a:line]})
  if l:ft !=# ''
    return l:ft
  endif
  " Follow the env indirection: the interesting token is env's argument.
  let l:toks = split(a:line[2:])
  if empty(l:toks)
    return ''
  endif
  let l:interp = matchstr(l:toks[0], '[^/]*$')
  if l:interp ==# 'env' && len(l:toks) > 1
    let l:interp = matchstr(l:toks[1], '[^/]*$')
  endif
  return get(s:interpreters, l:interp, '')
endfunction

" Escape a chunk name for literal use inside a /.../ (magic) pattern.
function! s:re_escape(name) abort
  return escape(a:name, '\/.*$^~[]')
endfunction

" Scan the buffer and return {chunk name -> Vim syntax name}.
function! s:infer_languages() abort
  let l:lines = getline(1, '$')
  let l:uses = {}
  let l:langs = {}
  let l:explicit = {}
  let l:current = ''
  let l:in_code = 0
  let l:body_started = 0
  for l:line in l:lines
    if l:line =~# '^<<.\{-}>>=\s*$'
      let l:current = matchstr(l:line, '^<<\zs.\{-}\ze>>=\s*$')
      let l:in_code = 1
      let l:body_started = 0
      if !has_key(l:uses, l:current)
        let l:uses[l:current] = {}
      endif
      if !has_key(l:explicit, l:current)
        let l:lx = s:lexer_for_chunk(l:current)
        if l:lx !=# ''
          let l:langs[l:current] = l:lx
          let l:explicit[l:current] = 1
        endif
      endif
    elseif l:in_code && l:line =~# '^@\($\| \)'
      let l:in_code = 0
      let l:current = ''
    elseif l:in_code && l:current !=# ''
      if !l:body_started && l:line !~# '^\s*$'
        let l:body_started = 1
        if !has_key(l:explicit, l:current)
          let l:sb = s:shebang_lang(l:line)
          if l:sb !=# ''
            let l:langs[l:current] = l:sb
            let l:explicit[l:current] = 1
          endif
        endif
      endif
      " Collect <<use>> references (a << ... >> not followed by '=').
      let l:start = 0
      while 1
        let l:mp = matchstrpos(l:line, '<<.\{-}>>', l:start)
        if l:mp[1] < 0
          break
        endif
        let l:mend = l:mp[2]
        if l:mend < len(l:line) && l:line[l:mend] ==# '='
          let l:start = l:mend
          continue
        endif
        let l:uses[l:current][l:mp[0][2:-3]] = 1
        let l:start = l:mend
      endwhile
    endif
  endfor
  " Propagate languages along use edges (worklist with conflict marking).
  let l:worklist = keys(l:langs)
  while !empty(l:worklist)
    let l:parent = remove(l:worklist, -1)
    let l:lang = l:langs[l:parent]
    if l:lang ==# s:CONFLICT
      continue
    endif
    for l:child in keys(get(l:uses, l:parent, {}))
      if has_key(l:explicit, l:child) || s:lexer_for_chunk(l:child) !=# ''
        continue
      endif
      if !has_key(l:langs, l:child)
        let l:langs[l:child] = l:lang
        call add(l:worklist, l:child)
      elseif l:langs[l:child] !=# s:CONFLICT && l:langs[l:child] !=# l:lang
        let l:langs[l:child] = s:CONFLICT
      endif
    endfor
  endwhile
  return l:langs
endfunction

" Include LANG's syntax under cluster @nowebLang_<lang>, once per buffer.
" Returns the cluster name, or '' if Vim ships no such syntax.
function! s:include_lang(lang) abort
  let l:cluster = 'nowebLang_' . substitute(a:lang, '[^A-Za-z0-9]', '_', 'g')
  if has_key(b:noweb_included, a:lang)
    return b:noweb_included[a:lang]
  endif
  if empty(globpath(&runtimepath, 'syntax/' . a:lang . '.vim'))
    let b:noweb_included[a:lang] = ''
    return ''
  endif
  let l:saved = exists('b:current_syntax') ? b:current_syntax : ''
  if l:saved !=# ''
    unlet b:current_syntax
  endif
  execute 'silent! syntax include @' . l:cluster . ' syntax/' . a:lang . '.vim'
  if l:saved !=# ''
    let b:current_syntax = l:saved
  elseif exists('b:current_syntax')
    unlet b:current_syntax
  endif
  let b:noweb_included[a:lang] = l:cluster
  return l:cluster
endfunction

" The minted languages this buffer uses, in the shape vimtex's minted
" syntax expects.  The patterns are vimtex's own, read from the buffer
" instead of from a project's file tree.  \inputminted is deliberately
" not scanned: its code lives in another file, so a region for its
" language could never match anything here.
function! s:minted_db() abort
  let l:db = {}
  let l:in_opt = 0
  for l:line in getline(1, '$')
    " This runs on every write, and almost no line of a document is a
    " minted construct: the substring test keeps the regexes off them.
    " A line continuing an option list is exempt -- the language may
    " well be all that is left of the construct on it.
    if !l:in_opt && stridx(l:line, 'mint') < 0
      continue
    endif
    if l:in_opt
      " An option list left open on the line before: the language
      " follows whichever ] closes it.
      if s:minted_register(l:db, matchstr(l:line, '\]\s*{\zs\w\+\ze}'))
        let l:in_opt = 0
      endif
      continue
    endif
    if l:line =~# '\\begin{minted}\s*\[[^\]]*$'
      let l:in_opt = 1
      continue
    endif
    call s:minted_register(l:db, matchstr(l:line,
          \ '\\begin{minted}\%(\s*\[[^\]]*\]\)\?\s*{\zs\w\+\ze}'))
    call s:minted_register(l:db, matchstr(l:line,
          \ '\\mint\%(inline\)\?\%(\s*\[[^\]]*\]\)\?\s*{\zs\w\+\ze}'))
  endfor
  return l:db
endfunction

" Register one language in the database, if there is one.  Dashes go
" because vimtex builds group names out of the language name and a
" dash cannot appear in one.  Returns whether a language was added.
function! s:minted_register(db, lang) abort
  if empty(a:lang)
    return 0
  endif
  let a:db[substitute(a:lang, '-', '', 'g')]
        \ = {'environments': [], 'commands': []}
  return 1
endfunction

" Give vimtex the buffer state its minted and pythontex syntax need:
" it looks for packages in a project main file, which a .nw buffer
" does not have (see the documentation).  Returns 1 when the syntax
" had to be reloaded for that state to take effect, in which case the
" caller's own syntax work has already been redone.
function! noweb#vimtex_syntax() abort
  if !get(g:, 'noweb_vimtex', 1) || !exists('b:vimtex')
    return 0
  endif
  if !has_key(b:vimtex, 'syntax')
    let b:vimtex.syntax = {}
  endif
  let l:changed = 0

  let l:db = s:minted_db()
  if !empty(l:db)
    if get(b:vimtex.syntax, 'minted', {}) !=# l:db
      let b:vimtex.syntax.minted = l:db
      let l:changed = 1
    endif
    if !has_key(b:vimtex.packages, 'minted')
      let b:vimtex.packages.minted = {}
      let l:changed = 1
    endif
  endif

  " pythontex's loader includes the whole Python syntax unconditionally,
  " so only buffers that really use it should pay for it.  The inline
  " commands count only with their argument attached, so that prose
  " *about* \py does not trigger the include -- as it would in the
  " document this very function is written in.
  if !has_key(b:vimtex.packages, 'pythontex')
        \ && search('\C\\begin{py\%(code\|block\)}\|\C\\py[bsc]\?[{#@]', 'cnw')
    let b:vimtex.packages.pythontex = {}
    let l:changed = 1
  endif

  " vimtex's dispatcher runs inside `runtime! syntax/tex.vim`, i.e. inside
  " our own syntax file.  Before that has happened, the pending load will
  " pick the state up by itself; afterwards, the only way back into a
  " syntax load is to start one.  Loading the packages by hand here
  " instead would re-impose vimtex's syn sync over ours (see refresh) and
  " leave b:current_syntax reading "tex".
  if l:changed && exists('b:current_syntax') && !empty(&l:syntax)
    let &l:syntax = &l:syntax
    return 1
  endif

  return 0
endfunction

" Re-infer chunk languages and (re)build the per-language syntax regions.
function! noweb#refresh() abort
  " May reload the syntax -- and so re-enter this function -- when the
  " set of minted languages in the prose changed; the reload redoes
  " everything below, so this run has nothing left to do.
  if noweb#vimtex_syntax()
    return
  endif

  if !exists('b:noweb_included')
    let b:noweb_included = {}
  endif
  if !exists('b:noweb_lang_groups')
    let b:noweb_lang_groups = []
  endif
  for l:grp in b:noweb_lang_groups
    execute 'silent! syntax clear ' . l:grp
  endfor
  let b:noweb_lang_groups = []

  let l:langs = s:infer_languages()
  let l:bylang = {}
  for [l:name, l:lang] in items(l:langs)
    " 'tex' is skipped: the buffer's outer syntax already is tex, and
    " re-including it as a cluster re-runs its sync/spell setup mid-refresh.
    if l:lang ==# s:CONFLICT || l:lang ==# 'text' || l:lang ==# 'tex'
      continue
    endif
    let l:bylang[l:lang] = get(l:bylang, l:lang, []) + [l:name]
  endfor

  let l:i = 0
  for [l:lang, l:names] in items(l:bylang)
    let l:cluster = s:include_lang(l:lang)
    if l:cluster ==# ''
      continue
    endif
    let l:i += 1
    let l:grp = 'nowebCodeLang' . l:i
    let l:alt = join(map(copy(l:names), 's:re_escape(v:val)'), '\|')
    " matchgroup= keeps included items (e.g. sh.vim's here-doc rule, which
    " matches <<word) from ever firing on the header line; me=s-1 on both
    " ends leaves the terminator unconsumed, so a following chunk header
    " both ends this region and starts the next one.
    execute 'syntax region ' . l:grp
          \ . ' matchgroup=nowebName start=/^<<\%(' . l:alt . '\)>>=\s*$/'
          \ . ' matchgroup=NONE'
          \ . ' end=/^@\%( \|$\)/me=s-1'
          \ . ' end=/^<<.\{-}>>=\s*$/me=s-1'
          \ . ' keepend'
          \ . ' contains=@' . l:cluster . ',nowebChunkRef,@NoSpell'
          \ . ' containedin=tex.*'
    call add(b:noweb_lang_groups, l:grp)
  endfor

  " Must be (re)defined after every :syntax include above: at the same
  " start position the last-defined item wins (:h syn-priority), which is
  " what lets chunk refs beat e.g. shHereDoc's <<-pattern inside sh chunks.
  " containedin= lets that tie happen anywhere inside the included
  " languages' own items: the cluster admits the ref in a language's
  " top-level items, the name pattern (lang.*) in its contained ones
  " (sh's function bodies, strings, ...).  A pattern matching no group
  " is E409 and aborts the definition, hence the guard.  First/last name
  " chars must be non-space, so `cat <<EOF >> log` stays a here-doc.
  " syntax clear keeps the group id (contains= refs stay valid) while
  " preventing pattern accumulation across refreshes.
  silent! syntax clear nowebChunkRef
  let l:incl = []
  for [l:lang, l:cluster] in items(b:noweb_included)
    if l:cluster ==# ''
      continue
    endif
    call add(l:incl, '@' . l:cluster)
    if l:lang =~# '^\w\+$' && !empty(getcompletion(l:lang, 'highlight'))
      call add(l:incl, l:lang . '.*')
    endif
  endfor
  let l:incl = join(sort(l:incl), ',')
  execute 'syntax match nowebChunkRef'
        \ '/<<\%([^ ]\|[^ ].\{-}[^ ]\)>>/'
        \ 'contained contains=nowebTT'
        \ (l:incl ==# '' ? '' : 'containedin=' . l:incl)

  " Included syntax files install buffer-global sync rules (pythonSync
  " grouphere on ^def, make's groupthere on ^[^\t#], small minlines) that
  " re-sync this buffer wrongly while scrolling.  Drop them and parse from
  " the top; noweb sources are small.
  syntax sync clear
  syntax sync fromstart
endfunction

" A chunk definition (nonempty name) alone on its line, and a chunk
" reference; both capture the name via \zs / \ze.  The @-escape
" exclusion is NOT in the reference pattern -- look-behinds are slow
" -- but tested by s:refs_on_line beside each match.  s:HOT matches
" every line the occurrence scan cannot skip.
let s:DEF = '^<<\zs.\{-1,}\ze>>=\s*$'
let s:REF = '<<\zs\%([^ ]\|[^ ].\{-}[^ ]\)\ze>>'
let s:HOT = '<<\|^@\%( \|$\)'

let s:route = ''

" Chunk references on one line as [name, start, end] triples, with
" 0-based byte indices of the name between the brackets.  The @-escape
" tests live here as string comparisons; see s:REF.
function! s:refs_on_line(line) abort
  let l:refs = []
  let l:start = 0
  while 1
    let l:mp = matchstrpos(a:line, s:REF, l:start)
    if l:mp[1] < 0
      return l:refs
    endif
    if (l:mp[1] < 3 || a:line[l:mp[1] - 3] !=# '@') && l:mp[0][-1:] !=# '@'
      call add(l:refs, [l:mp[0], l:mp[1], l:mp[2]])
    endif
    let l:start = l:mp[2] + 2
  endwhile
endfunction

" Scan the buffer and return {chunk name -> {'defs': [...], 'uses': [...]}}
" where every entry is a [lnum, col] pair (1-based, at the first <).
" A chunk defined n times has n defs -- appends are definitions too.
" Memoized on b:changedtick: the scan only re-runs after an edit.
" On Neovim the scan runs in Lua (lua/noweb/scan.lua); the Vim script
" loop is the fallback.  Both must produce identical results.
function! s:chunk_occurrences() abort
  if get(b:, 'noweb_occ_tick', -1) == b:changedtick
    return b:noweb_occ
  endif
  if has('nvim') && !get(g:, 'noweb_scan_vimscript', 0)
    let l:occ = luaeval('require("noweb.scan")()')
    " luaeval cannot tell an empty Lua map from an empty list and
    " returns a list for both, so a buffer with no chunks arrives as []
    " where a dict is expected -- values() on it is E1206.
    if type(l:occ) != v:t_dict
      let l:occ = {}
    endif
    for l:e in values(l:occ)
      if type(l:e.defs) != v:t_list
        let l:e.defs = []
      endif
      if type(l:e.uses) != v:t_list
        let l:e.uses = []
      endif
    endfor
  else
    let l:occ = {}
    let l:lines = getline(1, '$')
    let l:in_code = 0
    let l:i = match(l:lines, s:HOT)
    while l:i >= 0
      let l:line = l:lines[l:i]
      let l:lnum = l:i + 1
      if l:line =~# s:DEF
        let l:in_code = 1
        call add(s:entry(l:occ, matchstr(l:line, s:DEF)).defs, [l:lnum, 1])
      elseif l:line =~# '^@\%( \|$\)'
        let l:in_code = 0
      elseif l:in_code
        for l:ref in s:refs_on_line(l:line)
	  call add(s:entry(l:occ, l:ref[0]).uses, [l:lnum, l:ref[1] - 1])
	endfor
      endif
      let l:i = match(l:lines, s:HOT, l:i + 1)
    endwhile
  endif
  let b:noweb_occ = l:occ
  let b:noweb_occ_tick = b:changedtick
  return l:occ
endfunction

function! s:entry(occ, name) abort
  if !has_key(a:occ, a:name)
    let a:occ[a:name] = {'defs': [], 'uses': []}
  endif
  return a:occ[a:name]
endfunction

" The chunk definition or reference under the cursor, or ''.
function! s:chunk_at_cursor() abort
  let l:line = getline('.')
  let l:name = matchstr(l:line, s:DEF)
  if l:name !=# ''
    return l:name
  endif
  let l:cur = col('.') - 1
  for l:ref in s:refs_on_line(l:line)
    if l:cur >= l:ref[1] - 2 && l:cur < l:ref[2] + 2
      return l:ref[0]
    endif
  endfor
  return ''
endfunction

" Omnifunc routing by context (:h complete-functions): chunk names
" after <<, the shadow's language server inside a code chunk,
" VimTeX in prose.  See the routing chunks in the language-
" intelligence section.
function! noweb#complete(findstart, base) abort
  if a:findstart
    let l:before = strpart(getline('.'), 0, col('.') - 1)
    let l:start = matchend(l:before, '.*@\@1<!<<')
    if l:start >= 0 && stridx(l:before, '>', l:start) < 0
      let s:route = 'chunk'
      return l:start
    endif
    if has('nvim') && get(g:, 'noweb_shadow', 1)
          \ && luaeval('require("noweb.shadow").locate(0, _A) ~= nil', line('.'))
      let s:route = 'lsp'
      return col('.') - 1 - len(matchstr(l:before, '\k*$'))
    endif
    if exists('b:vimtex')
      let s:route = 'tex'
      return vimtex#complete#omnifunc(a:findstart, a:base)
    endif
    let s:route = ''
    return -3
  endif
  if s:route ==# 'lsp'
    return luaeval('require("noweb.shadow").complete(_A)', a:base)
  elseif s:route ==# 'tex'
    return vimtex#complete#omnifunc(a:findstart, a:base)
  elseif s:route !=# 'chunk'
    return []
  endif
  let l:occ = s:chunk_occurrences()
  let l:close = getline('.')[col('.') - 1] ==# '>' ? '' : '>>'
  " At a definition position (the << opens the line) the likely target
  " is a name still lacking its definition; completing a use, defined
  " names lead instead.
  let l:defining = strpart(getline('.'), 0, col('.') - 1) =~# '^<<[^>]*$'
  let l:defined = []
  let l:undefined = []
  for l:name in sort(keys(l:occ))
    if stridx(l:name, a:base) != 0
      continue
    endif
    let l:n = len(l:occ[l:name].defs)
    call add(l:n == 0 ? l:undefined : l:defined, {
          \ 'word': l:name . l:close,
          \ 'abbr': l:name,
          \ 'menu': l:n == 0 ? 'undefined' : l:n == 1 ? 'def' : 'def+' . (l:n - 1),
          \ })
  endfor
  return l:defining ? l:undefined + l:defined : l:defined + l:undefined
endfunction

" Tagfunc resolving chunk names: every definition of the chunk is one
" tag match, in file order, so CTRL-] jumps to the first definition
" and :tnext steps through the appends.  Invoked by a normal-mode
" command ('c' in a:flags), the name comes from the cursor rather
" than a:pattern, which cannot hold the blanks chunk names may have.
function! noweb#tagfunc(pattern, flags, info) abort
  let l:name = stridx(a:flags, 'c') >= 0 ? s:chunk_at_cursor() : a:pattern
  let l:occ = s:chunk_occurrences()
  if l:name ==# ''
    return v:null
  endif
  if !has_key(l:occ, l:name)
    return stridx(a:flags, 'c') >= 0 ? [] : v:null
  endif
  let l:tags = []
  for l:def in l:occ[l:name].defs
    " The cmd is the definition's line number: appends share identical
    " header lines, so a search pattern could not tell them apart.
    call add(l:tags, {'name': l:name, 'filename': expand('%:p'),
          \ 'cmd': string(l:def[0]), 'kind': 'd'})
  endfor
  return l:tags
endfunction

" The ]c / [c motion: the next (dir > 0) or previous occurrence --
" definition or use -- of the chunk under the cursor, wrapping.
function! noweb#next_occurrence(dir) abort
  let l:name = s:chunk_at_cursor()
  if l:name ==# ''
    call s:no_chunk()
    return
  endif
  normal! m'
  call search('@\@1<!<<' . s:re_escape(l:name) . '>>',
        \ a:dir > 0 ? 'w' : 'bw')
endfunction

" Fill the location list with every definition and use of the chunk
" under the cursor, in file order, and open it.
function! noweb#refs() abort
  let l:name = s:chunk_at_cursor()
  if l:name ==# ''
    call s:no_chunk()
    return
  endif
  let l:occ = get(s:chunk_occurrences(), l:name, {'defs': [], 'uses': []})
  let l:places = sort(l:occ.defs + l:occ.uses,
        \ {a, b -> a[0] == b[0] ? a[1] - b[1] : a[0] - b[0]})
  let l:items = []
  for l:place in l:places
    call add(l:items, {'bufnr': bufnr('%'), 'lnum': l:place[0],
          \ 'col': l:place[1], 'text': getline(l:place[0])})
  endfor
  call setloclist(0, [], ' ', {'title': '<<' . l:name . '>>',
        \ 'items': l:items})
  lopen
endfunction

function! s:no_chunk() abort
  echohl WarningMsg
  echomsg 'noweb: no chunk name under the cursor'
  echohl None
endfunction

" Accessors for the Lua shadow module (lua/noweb/shadow.lua): the
" occurrence inventory and the chunk-language map of this buffer.
function! noweb#occurrences() abort
  return s:chunk_occurrences()
endfunction

function! noweb#languages() abort
  return s:infer_languages()
endfunction

" Command completion for :NowebTangled: the shadow root names.
function! noweb#tangled_roots(arglead, cmdline, cursorpos) abort
  return filter(luaeval('require("noweb.shadow").roots()'),
        \ 'stridx(v:val, a:arglead) >= 0')
endfunction

" K / gd with shadow-LSP answers inside code chunks, falling back to
" the built-in behaviour elsewhere.
function! noweb#hover() abort
  if !s:shadowed() || !luaeval('require("noweb.shadow").hover()')
    normal! K
  endif
endfunction

function! noweb#definition() abort
  if !s:shadowed() || !luaeval('require("noweb.shadow").definition()')
    normal! gd
  endif
endfunction

function! s:shadowed() abort
  return has('nvim') && get(g:, 'noweb_shadow', 1)
        \ && luaeval('require("noweb.shadow").locate(0, _A) ~= nil', line('.'))
endfunction
