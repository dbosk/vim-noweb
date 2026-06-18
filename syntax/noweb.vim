
" Vim syntax file
" Language:		NOWEB
" Author:		Xun GONG <minus273@BonBon.net>, Dirk Baechle <dl9obn@darc.de>
" Maintainer:		Daniel Bosk <daniel@bosk.se>
" Date:			2008-01-26
" Version:		1.3
" Derived from: 	cweb.vim by Andreas Scherer

" History
"
" v1.3: Detect each code chunk's language (autolang-style: filename-like
"       chunk names, #! lines, and propagation along <<use>> edges) and
"       highlight chunk bodies in that language.  See autoload/noweb.vim.
" v1.2: Major revision, fixed bug with modern "tex.vim"
" v1.1: Corrected `current_syntax = "noweb"' to
"                 `current_syntax = "nw"'
"
" v1.0: Initial version

" NOWEB is a collection of tools for "Literate Programming". 
" Unlike WEB or CWEB it is not bound to a specific programming
" language like PASCAL or C.
" For more informations about NOWEB, the sources or binary distributions
" have a look at 
"
" http://www.eecs.harvard.edu/~nr/noweb
"

" For informations about "Literate Programming" in general
"
" http://www.literateprogramming.com
"
" could be a place to start.
"

" Remove any old syntax stuff hanging around
if version < 600
  syntax clear
elseif exists("b:current_syntax")
  finish
endif


" Like in CWEB, a NOWEB source file is treated as a TeX file
" including code chunks in between.
if version < 600
  source <sfile>:p:h/tex.vim
else
  runtime! syntax/tex.vim
  unlet b:current_syntax
endif

" The reference to a chunk of code in another code chunk.
syntax match nowebCodeRef contained /<<.>>\|<<[^ ].*[^ ]>>/

syn region  nowebTT     start="\[\["hs=s+2 end="\]\]"he=e-2
syn region  nowebName   start="<<" end=">>" oneline contains=nowebTT

" NOWEB code chunks are defined by <<chunk_name>>= and ended by the next
" "@" (not a "@@"!) in the first column of a line.  This is the fallback
" region for chunks whose language could not be inferred: its body is
" left unhighlighted (chunk references are still marked).  Language-aware
" regions are layered on top of it by noweb#refresh() below, which is why
" they take priority -- they are defined later.
syntax region nowebCode start=/^<<.\{-}>>=/ end=/^@ \|^@$/me=e-3 contains=nowebName containedin=tex.*Zone

" Here, we mark the beginning of a new text chunk.
" syntax match nowebStartText /<<.>>=\|<<[^ ].*[^ ]>>=/
syntax match nowebStartText /^@ \|^@$/

if !exists("did_noweb_syntax_inits")
  let did_noweb_syntax_inits = 1
  " The default methods for highlighting. Can be overridden later.
  hi def link nowebCodeRef Type
  hi def link nowebStartText Constant
  hi def link nowebTT     Constant
  hi def link nowebName     Type
endif

let b:current_syntax = "noweb"

" Infer chunk languages and build the per-language regions, then keep them
" up to date: on every load (here), after each write, and on demand via
" :NowebSyncLang.  A full re-source (e.g. :edit) wipes included clusters,
" so reset the bookkeeping before the initial inference.
let b:noweb_included = {}
let b:noweb_lang_groups = []
call noweb#refresh()

command! -buffer NowebSyncLang call noweb#refresh()

augroup nowebLangSync
  autocmd! * <buffer>
  autocmd BufWritePost <buffer> call noweb#refresh()
augroup END

" vim: ts=8
