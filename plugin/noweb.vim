" plugin/noweb.vim -- startup-time configuration for noweb sources
"
" Runs before VimEnter, in particular before YCM snapshots its
" options for the ycmd server; buffer-local setup lives in
" ftplugin/noweb.vim instead.

if exists('g:loaded_noweb')
  finish
endif
let g:loaded_noweb = 1

" YCM fires the omnifunc on per-filetype trigger sequences and has no
" default for noweb; register ours unless the user chose their own.
" This must run before VimEnter: YCM reads the option once, at startup.
" << opens a chunk reference, . fires the language servers behind the
" shadow tangles, and VimTeX's own trigger regex covers the prose
" (accessing the autoload variable loads it; silent! tolerates a
" missing VimTeX).
let g:ycm_semantic_triggers = get(g:, 'ycm_semantic_triggers', {})
if !has_key(g:ycm_semantic_triggers, 'noweb')
  let g:ycm_semantic_triggers.noweb = ['<<', '.']
  silent! let g:ycm_semantic_triggers.noweb += [g:vimtex#re#youcompleteme]
endif
