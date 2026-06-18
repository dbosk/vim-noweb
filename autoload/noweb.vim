" autoload/noweb.vim -- per-chunk language inference for noweb sources
"
" Ports the core of the "autolang" filter from noweb's tominted.nw:
" every code chunk is seeded with a language from a filename-like chunk
" name or a #! line, and those languages then propagate along <<use>>
" edges (a worklist with conflict detection), so a descriptively-named
" chunk used by a typed root inherits the root's language.  The result
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

" Return the Vim syntax name for chunk NAME, or '' if its name says nothing.
" The name may use noweb's [[...]] quoting and may contain directory
" separators; only the basename decides (mirrors lexer_for_chunk).
function! s:lexer_for_chunk(name) abort
  let l:name = a:name
  if l:name =~# '^\[\[.*\]\]$'
    let l:name = l:name[2:-3]
  endif
  let l:base = matchstr(l:name, '[^/]*$')
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

" Return the language a #! line names, following the env indirection.
function! s:shebang_lang(line) abort
  if a:line !~# '^#!'
    return ''
  endif
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
    if l:lang ==# s:CONFLICT || l:lang ==# 'text'
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
    execute 'syntax region ' . l:grp
          \ . ' start=/^<<\%(' . l:alt . '\)>>=/'
          \ . ' end=/^@ \|^@$/me=e-3 keepend'
          \ . ' contains=@' . l:cluster . ',nowebName'
          \ . ' containedin=tex.*Zone'
    call add(b:noweb_lang_groups, l:grp)
  endfor
endfunction
