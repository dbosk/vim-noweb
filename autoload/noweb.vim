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
" Memoized on b:changedtick, like the occurrence scan
" (\cref{sec:occurrences}): until v1.7 the only callers were the
" syntax refresh and the shadow sync, both rare, but the per-chunk
" editing options (\cref{sec:chunkopts}) and the fold text
" (\cref{sec:folding}) ask on every cursor movement and every fold,
" and a full buffer scan each time is a full buffer scan too many.
" noweb#refresh clears the memo, so :NowebSyncLang re-infers even
" when nothing has been edited.
function! s:infer_languages() abort
  if get(b:, 'noweb_langs_tick', -1) == b:changedtick
    return b:noweb_langs
  endif
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
  let b:noweb_langs = l:langs
  let b:noweb_langs_tick = b:changedtick
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

  " A refresh is the one place that must not trust the inference memo:
  " :NowebSyncLang exists to re-infer after something outside the buffer
  " changed -- g:noweb_langrules, a newly installed syntax file -- with
  " b:changedtick untouched.
  unlet! b:noweb_langs_tick
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

" Where chunks begin and end.  s:DEFLINE starts a code chunk,
" s:TEXTLINE a documentation chunk; together (s:HEAD) they are every
" line a chunk can start on.  s:PCTDEF is noweb's index declaration:
" it ends the code but belongs to the chunk, so s:BOUND -- where a
" code body must stop -- includes it while s:HEAD does not.
let s:DEFLINE = '^<<.\{-1,}>>=\s*$'
let s:PCTDEF = '^@ %def\%( \|$\)'
let s:TEXTLINE = '^@\%( %def\)\@!\%( \|$\)'
let s:HEAD = s:DEFLINE . '\|' . s:TEXTLINE
let s:BOUND = s:HEAD . '\|' . s:PCTDEF

" One-entry memo for s:chunk_bounds; see s:chunk_options.
let s:memo = {}

" The chunk containing line lnum, as
"   kind  'code' or 'doc'
"   name  the chunk's name; '' for a documentation chunk
"   head  its <<name>>= or @ line; 0 before the file's first marker
"   body  its first line of content
"   last  its last line of content
"   end   its last line, "@ %def" declarations included
" 'last' and 'end' differ only for a code chunk with declarations:
" 'ic' stops at 'last', 'ac' runs to 'end'.
function! s:chunk_bounds(lnum) abort
  if get(s:memo, 'buf', -1) == bufnr('%') && s:memo.tick == b:changedtick
        \ && a:lnum >= max([s:memo.bounds.head, 1])
        \ && a:lnum <= s:memo.bounds.end
    return s:memo.bounds
  endif
  let l:view = winsaveview()
  try
    call cursor(a:lnum, 1)
    let l:head = search(s:HEAD, 'bcnW')
    call cursor(max([l:head, 1]), 1)
    let l:next = search(s:HEAD, 'nW')
    let l:stop = search(s:BOUND, 'nW')
  finally
    call winrestview(l:view)
  endtry
  let l:code = l:head > 0 && getline(l:head) =~# s:DEFLINE
  let l:end = l:next > 0 ? l:next - 1 : line('$')
  let l:bounds = {
        \ 'kind': l:code ? 'code' : 'doc',
        \ 'name': l:code ? matchstr(getline(l:head), s:DEF) : '',
        \ 'head': l:head,
        \ 'body': l:head == 0 || (!l:code && getline(l:head) !~# '^@\s*$')
        \         ? max([l:head, 1]) : l:head + 1,
        \ 'last': l:stop > 0 ? min([l:stop - 1, l:end]) : l:end,
        \ 'end': l:end,
        \ }
  let s:memo = {'buf': bufnr('%'), 'tick': b:changedtick, 'bounds': l:bounds}
  return l:bounds
endfunction

" Extend a chunk to its documentation/code pair: back over the prose
" that introduces a code chunk, or forward to the code a documentation
" chunk introduces (Emacs's noweb-chunk-pair-region).
function! s:pair_bounds(c) abort
  if a:c.kind ==# 'code'
    if a:c.head <= 1
      return a:c
    endif
    let l:doc = s:chunk_bounds(a:c.head - 1)
    return extend(copy(a:c), {'head': l:doc.head, 'body': l:doc.body})
  endif
  let l:code = a:c
  while l:code.kind !=# 'code' && l:code.end < line('$')
    let l:code = s:chunk_bounds(l:code.end + 1)
  endwhile
  return extend(copy(a:c), {'last': l:code.last, 'end': l:code.end})
endfunction

" The ic / ac / iC / aC text objects.  Linewise, and defined for both
" operator-pending and visual mode by the same function.
function! noweb#textobj(pair, around) abort
  let l:c = s:chunk_bounds(line('.'))
  if a:pair
    let l:c = s:pair_bounds(l:c)
  endif
  let l:first = a:around ? max([l:c.head, 1]) : l:c.body
  let l:last = a:around ? l:c.end : l:c.last
  if l:last < l:first
    " An empty chunk has no inside to select.
    return
  endif
  call cursor(l:first, 1)
  normal! V
  call cursor(l:last, 1)
endfunction

" The ]] / [[ / ]m / [m / ][ / [] motions: the count'th next (dir > 0)
" or previous chunk of the given kind, wrapping.
function! noweb#next_chunk(dir, kind, count) abort
  let l:pat = a:kind ==# 'code' ? s:DEFLINE
        \ : a:kind ==# 'doc' ? s:TEXTLINE : s:HEAD
  normal! m'
  for l:i in range(max([a:count, 1]))
    call search(l:pat, a:dir > 0 ? 'w' : 'bw')
  endfor
endfunction

" A [[...]] quote, and the private-use characters we borrow to stand
" in for the blanks inside one while the formatter runs.
let s:QUOTE = '\[\[.\{-}\]\]'
let s:FILLERS = [nr2char(0xe000), nr2char(0xe001), nr2char(0xe002)]

" A stand-in appearing in none of these lines, or '' if every
" candidate somehow does -- then the fill still happens, just without
" the protection.
function! s:free_filler(lines) abort
  for l:c in s:FILLERS
    if match(a:lines, l:c) < 0
      return l:c
    endif
  endfor
  return ''
endfunction

" Replace the blanks inside every [[...]] quote on the line with the
" stand-in, leaving each quote a single unbreakable word.
function! s:hide_quotes(line, filler) abort
  let l:out = ''
  let l:rest = a:line
  while 1
    let l:mp = matchstrpos(l:rest, s:QUOTE)
    if l:mp[1] < 0
      return l:out . l:rest
    endif
    let l:out .= strpart(l:rest, 0, l:mp[1])
          \ . substitute(l:mp[0], '[ \t]', a:filler, 'g')
    let l:rest = strpart(l:rest, l:mp[2])
  endwhile
endfunction

" Does the line leave a [[...]] quote unclosed?  Complete quotes are
" struck out first, so the doubled brackets that write a literal
" bracket do not read as an opening one.
function! s:quote_open(line) abort
  return substitute(a:line, s:QUOTE, '', 'g') =~# '\[\['
endfunction

" Vim's own formatter over first..last, with 'formatexpr' (this file)
" unset so that gq does not call us back.
function! s:internal_format(first, last) abort
  let l:save = &l:formatexpr
  try
    let &l:formatexpr = ''
    call s:normal_over(a:first, a:last, 'gq')
  finally
    let &l:formatexpr = l:save
  endtry
endfunction

" Apply a linewise operator to exactly first..last, with folding off:
" a closed fold would extend the operator over the whole fold.
function! s:normal_over(first, last, op) abort
  let l:foldenable = &l:foldenable
  try
    setlocal nofoldenable
    call cursor(a:first, 1)
    execute 'normal! V'
          \ . (a:last > a:first ? (a:last - a:first) . 'j' : '') . a:op
  finally
    let &l:foldenable = l:foldenable
  endtry
endfunction

" Re-indent through the tangled shadow, which has the language's own
" indent script; 0 when no shadow covers these lines and the caller
" should fall back to a plain '='.
function! s:shadow_indent(first, last) abort
  if !has('nvim') || !get(g:, 'noweb_shadow', 1)
    return 0
  endif
  return luaeval('require("noweb.shadow").indent(0, _A[1], _A[2])',
        \ [a:first, a:last])
endfunction

" Re-indent first..last with the indent script of filetype ft, run in
" a throwaway buffer of that filetype -- the fallback for when no
" shadow covers the chunk.  Returns 0 if ft has no indenter.
function! s:scratch_indent(ft, first, last) abort
  let l:lines = getline(a:first, a:last)
  let l:done = []
  let l:conventions = [&l:expandtab, &l:shiftwidth, &l:tabstop, &l:softtabstop]
  let l:eventignore = &eventignore
  set eventignore=all
  try
    silent keepalt new
    setlocal buftype=nofile noswapfile
    set eventignore=Syntax
    execute 'setfiletype' a:ft
    if &l:indentexpr ==# '' && &l:equalprg ==# '' && !&l:cindent && !&l:lisp
      return 0
    endif
    let [&l:expandtab, &l:shiftwidth, &l:tabstop, &l:softtabstop]
          \ = l:conventions
    call setline(1, l:lines)
    silent normal! gg=G
    let l:done = getline(1, '$')
  catch
    let l:done = []
  finally
    set eventignore=all
    silent! bwipeout!
    let &eventignore = l:eventignore
  endtry
  if len(l:done) != len(l:lines)
    return 0
  endif
  call setline(a:first, l:done)
  return 1
endfunction

" Fill one piece of one chunk.  Each step can change how many lines
" the piece occupies, so its end is carried along rather than reread.
function! s:format_piece(p) abort
  if a:p.kind ==# 'code'
    call s:internal_format(a:p.from, a:p.to)
    return
  endif
  let l:to = a:p.to
  let l:n = a:p.from
  while l:n < l:to
    if s:quote_open(getline(l:n)) && getline(l:n + 1) !~# '^\s*$'
      call setline(l:n, getline(l:n) . ' '
            \ . substitute(getline(l:n + 1), '^\s*', '', ''))
      execute 'silent ' . (l:n + 1) . 'delete _'
      let l:to -= 1
    else
      let l:n += 1
    endif
  endwhile
  let l:lines = getline(a:p.from, l:to)
  let l:filler = s:free_filler(l:lines)
  if l:filler !=# ''
    let l:hidden = []
    for l:line in l:lines
      call add(l:hidden, s:hide_quotes(l:line, l:filler))
    endfor
    call setline(a:p.from, l:hidden)
  endif
  let l:before = line('$')
  call s:internal_format(a:p.from, l:to)
  let l:to += line('$') - l:before
  if l:filler !=# ''
    let l:shown = []
    for l:line in getline(a:p.from, l:to)
      call add(l:shown, substitute(l:line, l:filler, ' ', 'g'))
    endfor
    call setline(a:p.from, l:shown)
  endif
endfunction

" 'formatexpr': fill v:lnum..v:lnum+v:count-1, chunk by chunk.
function! noweb#format() abort
  if v:char !=# ''
    " Auto-wrapping as you type, one character at a time; the built-in
    " formatter already stops at the chunk's blank lines.
    return 1
  endif
  let l:last = v:lnum + v:count - 1
  let l:pieces = []
  let l:n = v:lnum
  while l:n <= l:last
    let l:c = s:chunk_bounds(l:n)
    " Never below the chunk's body: a range that starts on a header line
    " must not invite the formatter to join the header to the code.
    let l:from = max([l:n, l:c.body])
    let l:to = min([l:c.last, l:last])
    if l:to >= l:from
      call add(l:pieces, {'kind': l:c.kind, 'from': l:from, 'to': l:to})
    endif
    let l:n = max([l:c.end, l:n]) + 1
  endwhile
  " Later pieces first: filling one piece moves everything below it.
  call reverse(l:pieces)
  if len(l:pieces) > 1
    call filter(l:pieces, {_, p -> p.kind ==# 'doc'})
  endif
  for l:piece in l:pieces
    call s:format_piece(l:piece)
  endfor
  return 0
endfunction

" :NowebFillChunk -- Emacs's M-n q: fill the prose or re-indent the
" code, according to the chunk the cursor is in.
function! noweb#fill_chunk() abort
  let l:c = s:chunk_bounds(line('.'))
  if l:c.last < l:c.body
    return
  endif
  let l:view = winsaveview()
  try
    if l:c.kind ==# 'code'
      let l:ft = get(noweb#languages(), l:c.name, '')
      if s:shadow_indent(l:c.body, l:c.last)
        " The shadow's indenter had the whole tangle to work with.
      elseif l:ft !=# ''
        call s:scratch_indent(l:ft, l:c.body, l:c.last)
      else
        call s:normal_over(l:c.body, l:c.last, '=')
      endif
    else
      call s:format_piece({'kind': 'doc', 'from': l:c.body, 'to': l:c.last})
    endif
  finally
    call winrestview(l:view)
  endtry
endfunction

" The buffer-local options a chunk's language should own.  Not
" 'textwidth': ftplugins mostly leave it alone and users mostly do
" not, so it belongs to the user, not to the chunk.
let s:CHUNK_OPTIONS = ['commentstring', 'comments', 'iskeyword',
      \ 'matchpairs', 'suffixesadd', 'formatoptions']
let s:optcache = {}

" The chunk options a filetype's ftplugin sets, read out of a
" throwaway buffer of that filetype.  An empty ft gives the values a
" buffer has when no filetype has spoken for it, which is how
" s:doc_options tells a deliberate value from a factory one.  Cached:
" this runs once per language per session.
function! s:options_for(ft) abort
  if has_key(s:optcache, a:ft)
    return s:optcache[a:ft]
  endif
  let l:opts = {}
  let l:eventignore = &eventignore
  set eventignore=all
  try
    silent keepalt new
    setlocal buftype=nofile noswapfile
    set eventignore=Syntax
    if a:ft !=# ''
      execute 'setfiletype' a:ft
    endif
    for l:o in s:CHUNK_OPTIONS
      let l:opts[l:o] = getbufvar('%', '&' . l:o)
    endfor
  catch
    let l:opts = {}
  finally
    set eventignore=all
    silent! bwipeout!
    let &eventignore = l:eventignore
  endtry
  let s:optcache[a:ft] = l:opts
  return l:opts
endfunction

" The prose's own options.  An option still holding the value a
" filetype-less buffer would have is one nothing has claimed, and
" takes filetype tex's instead -- the prose is TeX, and no ftplugin
" says so on a bare Vim.  Everything else was set deliberately (by
" VimTeX, or by the user) and stands.  Captured on first use, after
" every other ftplugin has had its say.
function! s:doc_options() abort
  if !exists('b:noweb_doc_options')
    let l:bare = s:options_for('')
    let l:tex = s:options_for('tex')
    let b:noweb_doc_options = {}
    for l:o in s:CHUNK_OPTIONS
      let l:v = getbufvar('%', '&' . l:o)
      let b:noweb_doc_options[l:o] =
            \ l:v ==# get(l:bare, l:o, l:v) ? get(l:tex, l:o, l:v) : l:v
    endfor
  endif
  return b:noweb_doc_options
endfunction

" Give the buffer the editing options of the chunk under the cursor.
" Called on every cursor movement, so the unchanged case must be
" nearly free.
function! noweb#chunk_options() abort
  if !get(g:, 'noweb_chunk_options', 1)
    return
  endif
  let l:c = s:chunk_bounds(line('.'))
  let l:ft = l:c.kind ==# 'code'
        \ ? get(noweb#languages(), l:c.name, '') : ''
  if get(b:, 'noweb_applied', v:null) is# l:ft
    return
  endif
  call s:doc_options()
  let l:opts = l:ft ==# '' ? {} : s:options_for(l:ft)
  " An unknown language is no reason to leave TeX's idea of a comment
  " in place, but it is no reason to invent one either: fall back to
  " the prose's options, which is where we came from.
  for [l:o, l:v] in items(empty(l:opts) ? b:noweb_doc_options : l:opts)
    call setbufvar('%', '&' . l:o, l:v)
  endfor
  let b:noweb_applied = l:ft
endfunction

" Put the prose's options back; b:undo_ftplugin calls this.
function! noweb#chunk_options_reset() abort
  for [l:o, l:v] in items(get(b:, 'noweb_doc_options', {}))
    call setbufvar('%', '&' . l:o, l:v)
  endfor
  unlet! b:noweb_doc_options b:noweb_applied
endfunction

" 'foldexpr': one fold per chunk.  Runs per line and looks at nothing
" but the line; "@ %def" is not a head, so it folds with its chunk.
function! noweb#foldexpr(lnum) abort
  return getline(a:lnum) =~# s:HEAD ? '>1' : '1'
endfunction

" 'foldtext': the chunk's name and inferred language, or the prose's
" first real line.
function! noweb#foldtext() abort
  let l:head = getline(v:foldstart)
  let l:count = v:foldend - v:foldstart + 1
  if l:head =~# s:DEFLINE
    let l:name = matchstr(l:head, s:DEF)
    let l:lang = get(noweb#languages(), l:name, '')
    let l:what = '<<' . l:name . '>>=' . (l:lang ==# '' ? '' : '  ' . l:lang)
  else
    let l:what = ''
    for l:n in range(v:foldstart, min([v:foldend, v:foldstart + 4]))
      let l:text = substitute(getline(l:n), '^@\s*', '', '')
      if l:text !~# '^\s*$'
        let l:what = l:text
        break
      endif
    endfor
    if l:what ==# ''
      let l:what = '@'
    endif
  endif
  return printf('%s  [%d lines]', l:what, l:count)
endfunction

" Chunk names starting with 'lead', each trimmed to the part Vim will
" substitute for a:arglead.  Names may contain blanks while a:arglead
" is only the text since the last one, so the two must be given
" separately or completing "greet body" would insert "greet greet
" body".
function! s:name_completions(lead, arglead) abort
  let l:drop = len(a:lead) - len(a:arglead)
  let l:names = sort(filter(keys(s:chunk_occurrences()),
        \ {_, n -> stridx(n, a:lead) == 0}))
  return map(l:names, {_, n -> strpart(n, l:drop)})
endfunction

" Completion for :NowebGoto: the command's own name comes first.
function! noweb#chunk_names(arglead, cmdline, cursorpos) abort
  return s:name_completions(
        \ matchstr(a:cmdline, '^\s*\S\+\s\+\zs.*'), a:arglead)
endfunction

" Completion for input(): the whole line is the name.
function! noweb#chunk_name_input(arglead, cmdline, cursorpos) abort
  return s:name_completions(a:cmdline, a:arglead)
endfunction

" :NowebGoto -- jump to a chunk's first definition by name, defaulting
" to the one under the cursor.  Emacs lands on the last chunk of the
" name, an accident of how it builds its alist; the first definition
" is what anyone means.
function! noweb#goto(name) abort
  let l:name = a:name ==# '' ? s:chunk_at_cursor() : a:name
  if l:name ==# ''
    call s:no_chunk()
    return
  endif
  let l:defs = get(s:chunk_occurrences(), l:name, {'defs': []}).defs
  if empty(l:defs)
    echohl WarningMsg
    echomsg 'noweb: no definition of <<' . l:name . '>>'
    echohl None
    return
  endif
  normal! m'
  if exists('*settagstack')
    call settagstack(win_getid(), {'items': [{'tagname': l:name,
          \ 'from': [bufnr('%'), line('.'), col('.'), 0]}]}, 'a')
  endif
  call cursor(l:defs[0][0], 1)
endfunction

" :NowebChunks -- every chunk definition in file order, in the
" location list.
function! noweb#chunks() abort
  let l:occ = s:chunk_occurrences()
  let l:items = []
  for l:name in keys(l:occ)
    for l:def in l:occ[l:name].defs
      call add(l:items, {'bufnr': bufnr('%'), 'lnum': l:def[0],
            \ 'col': l:def[1], 'text': '<<' . l:name . '>>='})
    endfor
  endfor
  if empty(l:items)
    echohl WarningMsg
    echomsg 'noweb: no chunks in this buffer'
    echohl None
    return
  endif
  call sort(l:items, {a, b -> a.lnum - b.lnum})
  call setloclist(0, [], ' ', {'title': 'noweb chunks', 'items': l:items})
  lopen
endfunction

" :NowebNewChunk -- open a chunk below the cursor, with the cursor on
" its first body line.  With no name, prompt for one with completion,
" so appending to an existing chunk is the same gesture.
function! noweb#new_chunk(name) abort
  let l:name = a:name
  if l:name ==# ''
    let l:name = input('Chunk name: ', '',
          \ 'customlist,noweb#chunk_name_input')
    redraw
  endif
  if l:name ==# ''
    return
  endif
  let l:at = line('.')
  let l:lines = s:chunk_bounds(l:at).kind ==# 'code' ? ['@', ''] : []
  call append(l:at, l:lines + ['<<' . l:name . '>>=', '', '@'])
  call cursor(l:at + len(l:lines) + 2, 1)
endfunction
