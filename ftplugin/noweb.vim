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

" YCM fires the omnifunc on a per-filetype trigger sequence and has no
" default for noweb; register << unless the user chose their own.
let g:ycm_semantic_triggers = get(g:, 'ycm_semantic_triggers', {})
if !has_key(g:ycm_semantic_triggers, 'noweb')
  let g:ycm_semantic_triggers.noweb = ['<<']
endif
