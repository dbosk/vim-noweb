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
" The name may use noweb's [[...]] quoting and may contain directory
" separators; only the basename decides (mirrors lexer_for_chunk).
function! s:lexer_for_chunk(name) abort
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

" Re-infer chunk languages and (re)build the per-language syntax regions.
function! noweb#refresh() abort
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
  " First/last name chars must be non-space, so `cat <<EOF >> log` stays a
  " here-doc.  syntax clear keeps the group id (contains= refs stay valid)
  " while preventing pattern accumulation across refreshes.
  silent! syntax clear nowebChunkRef
  syntax match nowebChunkRef /<<\%([^ ]\|[^ ].\{-}[^ ]\)>>/ contained contains=nowebTT

  " Included syntax files install buffer-global sync rules (pythonSync
  " grouphere on ^def, make's groupthere on ^[^\t#], small minlines) that
  " re-sync this buffer wrongly while scrolling.  Drop them and parse from
  " the top; noweb sources are small.
  syntax sync clear
  syntax sync fromstart
endfunction

" A chunk definition alone on its line, and a chunk reference whose
" brackets are not @-escaped; both capture the name via \zs / \ze.
let s:DEF = '^<<\zs.\{-}\ze>>=\s*$'
let s:REF = '@\@1<!<<\zs\%([^ ]\|[^ ].\{-}[^ ]\)\ze@\@1<!>>'

" Scan the buffer and return {chunk name -> {'defs': [...], 'uses': [...]}}
" where every entry is a [lnum, col] pair (1-based, at the first <).
" A chunk defined n times has n defs -- appends are definitions too.
function! s:chunk_occurrences() abort
  let l:occ = {}
  let l:in_code = 0
  let l:lnum = 0
  for l:line in getline(1, '$')
    let l:lnum += 1
    if l:line =~# s:DEF
      let l:in_code = 1
      call add(s:entry(l:occ, matchstr(l:line, s:DEF)).defs, [l:lnum, 1])
    elseif l:in_code && l:line =~# '^@\($\| \)'
      let l:in_code = 0
    elseif l:in_code
      let l:start = 0
      while 1
        let l:mp = matchstrpos(l:line, s:REF, l:start)
        if l:mp[1] < 0
          break
        endif
        call add(s:entry(l:occ, l:mp[0]).uses, [l:lnum, l:mp[1] - 1])
        let l:start = l:mp[2] + 2
      endwhile
    endif
  endfor
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
  let l:start = 0
  while 1
    let l:mp = matchstrpos(l:line, s:REF, l:start)
    if l:mp[1] < 0
      return ''
    endif
    if l:cur >= l:mp[1] - 2 && l:cur < l:mp[2] + 2
      return l:mp[0]
    endif
    let l:start = l:mp[2] + 2
  endwhile
endfunction

" Omnifunc completing chunk names after << (:h complete-functions).
function! noweb#complete(findstart, base) abort
  if a:findstart
    let l:before = strpart(getline('.'), 0, col('.') - 1)
    let l:start = matchend(l:before, '.*@\@1<!<<')
    if l:start < 0 || stridx(l:before, '>', l:start) >= 0
      return -3
    endif
    return l:start
  endif
  let l:occ = s:chunk_occurrences()
  let l:close = getline('.')[col('.') - 1] ==# '>' ? '' : '>>'
  let l:items = []
  for l:name in sort(keys(l:occ))
    if stridx(l:name, a:base) != 0
      continue
    endif
    let l:n = len(l:occ[l:name].defs)
    call add(l:items, {
          \ 'word': l:name . l:close,
          \ 'abbr': l:name,
          \ 'menu': l:n == 0 ? 'undefined' : l:n == 1 ? 'def' : 'def+' . (l:n - 1),
          \ })
  endfor
  return l:items
endfunction
