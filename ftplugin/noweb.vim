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
