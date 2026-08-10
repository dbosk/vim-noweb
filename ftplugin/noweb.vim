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
