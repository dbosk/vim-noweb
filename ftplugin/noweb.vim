" ftplugin/noweb.vim -- completion and navigation for noweb sources
"
" Buffer-local hooks only: the implementations live in
" autoload/noweb.vim and load on first use.

if exists('b:did_ftplugin')
  finish
endif
let b:did_ftplugin = 1

setlocal omnifunc=noweb#complete
let b:undo_ftplugin = 'setlocal omnifunc<'
if exists('+tagfunc')
  setlocal tagfunc=noweb#tagfunc
  let b:undo_ftplugin .= ' tagfunc<'
endif

command! -buffer NowebRefs call noweb#refs()

nnoremap <silent> <Plug>(noweb-next-occurrence)
      \ :<C-u>call noweb#next_occurrence(1)<CR>
nnoremap <silent> <Plug>(noweb-prev-occurrence)
      \ :<C-u>call noweb#next_occurrence(-1)<CR>
if !get(g:, 'noweb_no_maps', 0)
  if !hasmapto('<Plug>(noweb-next-occurrence)', 'n')
    nmap <buffer> ]c <Plug>(noweb-next-occurrence)
  endif
  if !hasmapto('<Plug>(noweb-prev-occurrence)', 'n')
    nmap <buffer> [c <Plug>(noweb-prev-occurrence)
  endif
endif

let b:undo_ftplugin .= ' | silent! nunmap <buffer> ]c'
      \ . ' | silent! nunmap <buffer> [c'
      \ . ' | silent! delcommand -buffer NowebRefs'

" ic / ac / iC / aC, in both the modes a text object serves.
for [s:key, s:plug, s:args] in [
      \ ['ic', 'inner-chunk', '0, 0'],
      \ ['ac', 'a-chunk', '0, 1'],
      \ ['iC', 'inner-pair', '1, 0'],
      \ ['aC', 'a-pair', '1, 1']]
  for s:mode in ['x', 'o']
    execute s:mode . 'noremap <silent> <Plug>(noweb-' . s:plug . ') '
          \ . ':<C-u>call noweb#textobj(' . s:args . ')<CR>'
    if !get(g:, 'noweb_no_maps', 0)
          \ && !hasmapto('<Plug>(noweb-' . s:plug . ')', s:mode)
      execute s:mode . 'map <buffer> ' . s:key
            \ . ' <Plug>(noweb-' . s:plug . ')'
    endif
  endfor
  let b:undo_ftplugin .= ' | silent! xunmap <buffer> ' . s:key
        \ . ' | silent! ounmap <buffer> ' . s:key
endfor

" ]] [[ ]m [m ][ [] -- structural movement, in the three modes a
" motion serves.
for [s:key, s:plug, s:args] in [
      \ [']]', 'next-chunk', "1, '', v:count1"],
      \ ['[[', 'prev-chunk', "-1, '', v:count1"],
      \ [']m', 'next-code-chunk', "1, 'code', v:count1"],
      \ ['[m', 'prev-code-chunk', "-1, 'code', v:count1"],
      \ ['][', 'next-doc-chunk', "1, 'doc', v:count1"],
      \ ['[]', 'prev-doc-chunk', "-1, 'doc', v:count1"]]
  for s:mode in ['n', 'x', 'o']
    execute s:mode . 'noremap <silent> <Plug>(noweb-' . s:plug . ') '
          \ . ':<C-u>call noweb#next_chunk(' . s:args . ')<CR>'
    if !get(g:, 'noweb_no_maps', 0)
          \ && !hasmapto('<Plug>(noweb-' . s:plug . ')', s:mode)
      execute s:mode . 'map <buffer> ' . s:key
            \ . ' <Plug>(noweb-' . s:plug . ')'
    endif
  endfor
  let b:undo_ftplugin .= ' | silent! nunmap <buffer> ' . s:key
        \ . ' | silent! xunmap <buffer> ' . s:key
        \ . ' | silent! ounmap <buffer> ' . s:key
endfor

unlet! s:key s:plug s:args s:mode

setlocal formatexpr=noweb#format()
command! -buffer NowebFillChunk call noweb#fill_chunk()
let b:undo_ftplugin .= ' | setlocal formatexpr<'
      \ . ' | silent! delcommand -buffer NowebFillChunk'

if get(g:, 'noweb_chunk_options', 1)
  augroup nowebChunkOptions
    autocmd! * <buffer>
    autocmd CursorMoved,CursorMovedI,BufEnter <buffer>
          \ call noweb#chunk_options()
  augroup END
  let b:undo_ftplugin .= ' | silent! autocmd! nowebChunkOptions * <buffer>'
        \ . ' | call noweb#chunk_options_reset()'
endif

if get(g:, 'noweb_fold', 0)
  setlocal foldmethod=expr
  setlocal foldexpr=noweb#foldexpr(v:lnum)
  setlocal foldtext=noweb#foldtext()
  let b:undo_ftplugin .= ' | setlocal foldmethod< foldexpr< foldtext<'
endif

command! -buffer -nargs=? -complete=customlist,noweb#chunk_names
      \ NowebGoto call noweb#goto(<q-args>)
command! -buffer NowebChunks call noweb#chunks()
command! -buffer -nargs=? NowebNewChunk call noweb#new_chunk(<q-args>)
let b:undo_ftplugin .= ' | silent! delcommand -buffer NowebGoto'
      \ . ' | silent! delcommand -buffer NowebChunks'
      \ . ' | silent! delcommand -buffer NowebNewChunk'

nnoremap <silent> <Plug>(noweb-hover) :<C-u>call noweb#hover()<CR>
nnoremap <silent> <Plug>(noweb-definition) :<C-u>call noweb#definition()<CR>
if !get(g:, 'noweb_no_maps', 0)
  if !hasmapto('<Plug>(noweb-hover)', 'n')
    nmap <buffer> K <Plug>(noweb-hover)
  endif
  if !hasmapto('<Plug>(noweb-definition)', 'n')
    nmap <buffer> gd <Plug>(noweb-definition)
  endif
endif
let b:undo_ftplugin .= ' | silent! nunmap <buffer> K'
      \ . ' | silent! nunmap <buffer> gd'

if has('nvim') && get(g:, 'noweb_shadow', 1) && executable('notangle')
  lua require('noweb.shadow').setup(0)
  command! -buffer -nargs=? -complete=customlist,noweb#tangled_roots
        \ NowebTangled
        \ call luaeval('require("noweb.shadow").preview(_A[1], _A[2])',
        \              [<q-args>, <q-mods>])
  command! -buffer -nargs=+ NowebMake
        \ call luaeval('require("noweb.shadow").make(_A)', <q-args>)
  let b:undo_ftplugin .= ' | silent! delcommand -buffer NowebTangled'
        \ . ' | silent! delcommand -buffer NowebMake'
endif

if get(g:, 'noweb_vimtex', 1) && !exists('b:vimtex')
      \ && !empty(globpath(&runtimepath, 'autoload/vimtex.vim'))
  let s:undo = b:undo_ftplugin
  unlet b:undo_ftplugin
  silent! call vimtex#init()
  let b:undo_ftplugin = s:undo
        \ . (empty(get(b:, 'undo_ftplugin', ''))
        \    ? '' : ' | ' . b:undo_ftplugin)
  setlocal omnifunc=noweb#complete
  if exists('+tagfunc')
    setlocal tagfunc=noweb#tagfunc
  endif
  call noweb#vimtex_syntax()
endif
