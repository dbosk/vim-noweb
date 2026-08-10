" plugin/noweb.vim -- startup-time configuration for noweb sources
"
" Runs before VimEnter, in particular before YCM snapshots its
" options for the ycmd server; buffer-local setup lives in
" ftplugin/noweb.vim instead.

if exists('g:loaded_noweb')
  finish
endif
let g:loaded_noweb = 1

" YCM fires the omnifunc on a per-filetype trigger sequence and has no
" default for noweb; register << unless the user chose their own.
" This must run before VimEnter: YCM reads the option once, at startup.
let g:ycm_semantic_triggers = get(g:, 'ycm_semantic_triggers', {})
if !has_key(g:ycm_semantic_triggers, 'noweb')
  let g:ycm_semantic_triggers.noweb = ['<<']
endif
