" Vim syntax file
" Language:		NOWEB
" Author:		Xun GONG <minus273@BonBon.net>, Dirk Baechle <dl9obn@darc.de>
" Maintainer:		Daniel Bosk <dbosk@kth.se>
" Date:			2026-08-10
" Version:		1.7
" Inspired by:		cweb.vim (Andreas Scherer) -> nw.vim -> vim-noweb

" History
"
" Versions 1.3 and 1.4 together amount to a complete rewrite:
" virtually no code from v1.2 or earlier remains.
"
" v1.7: Language intelligence in chunks (Neovim): invisible tangled
"       shadow buffers (notangle -filter linemark) with language
"       servers attached -- diagnostics, completion, K hover and gd
"       goto-def inside code chunks, mapped back into the .nw; the
"       omnifunc routes between chunk names, the LSP and VimTeX,
"       which now initializes for the prose; :NowebTangled lockstep
"       preview; :NowebMake through nolinemap.  Name-pattern language
"       rules mirror noweave's -langrule (test [[x.py]] chunks etc.;
"       g:noweb_langrules).  Chunk references highlight inside the
"       included languages' own constructs (a sh here-doc rule used
"       to swallow them), and mid-line chunk splices are rejoined so
"       shadows match the real tangle.
" v1.6.1: Register the YCM trigger at startup (plugin/noweb.vim) --
"       YCM snapshots its options at VimEnter, so the ftplugin was
"       too late for files opened mid-session.  Order candidates by
"       context (undefined names first when defining), memoize the
"       occurrence scan on b:changedtick and run it in Lua on Neovim
"       (lua/noweb/scan.lua; 2 ms where Vim script needs 100 on a
"       15k-line source).
" v1.6: Editing support: chunk names complete through the buffer's
"       omnifunc (picked up by YCM and friends), definitions resolve
"       as tags (CTRL-] jumps, :tnext steps through appends), ]c/[c
"       step through occurrences and :NowebRefs surveys them.
" v1.5: Seed chunk languages from the editor's own filetype database
"       (vim.filetype.match on Neovim; the filetypedetect autocommands
"       run against a scratch buffer on Vim); the fixed tables remain
"       as a last resort.
" v1.4: Make highlighting reliable: sync from start (included language
"       syntaxes used to hijack the buffer's sync rules), matchgroup on
"       chunk headers (sh here-docs used to eat chunk bodies), implicit
"       chunk termination at the next <<name>>=, oneline [[...]], and
"       unconditional hi def links (they survive :syntax off/on now).
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

" containedin=tex.* lets these match even when a tex region has swallowed
" the surrounding prose (e.g. an unclosed optional-argument [ ... ), which
" vimtex can open across lines via nextgroup chains.
syn region  nowebTT     start="\[\["hs=s+2 end="\]\]"he=e-2 oneline containedin=tex.*
syn region  nowebName   start="<<" end=">>" oneline contains=nowebTT containedin=tex.*

" When [[...]] quoting follows a tex command taking an optional argument
" (\begin{env}, \item, ...), the tex syntax claims the first [ as the
" argument's opening delimiter via a nextgroup chain, which has priority
" over any ordinary item -- and a % inside the quoting then comments out
" the ]], leaving the option region open for the rest of the file.
" Recover from inside the stolen bracket: consume the orphaned [content]
" (which only exists in [X]] shapes, hence the lookahead) so the trailing
" ] closes the option region on the same line.
syn match nowebTTOrphan /\[[^][]*\]\]\@=/hs=s+1,he=e-1 contained containedin=tex.*Opt,tex.*Label

" NOWEB code chunks are defined by <<chunk_name>>= and ended by the next
" "@" (not a "@@"!) in the first column of a line, or implicitly by the
" next chunk definition.  Both ends use me=s-1 so the terminator itself is
" left for the following item (nowebStartText or the next chunk region).
" The header is highlighted via matchgroup, which also keeps items of an
" included language syntax from matching inside it.  This is the fallback
" region for chunks whose language could not be inferred: its body is
" left unhighlighted (chunk references are still marked).  Language-aware
" regions are layered on top of it by noweb#refresh() below, which is why
" they take priority -- they are defined later.  nowebChunkRef is also
" defined there, after the language includes, so that it outranks them.
" containedin=tex.* guarantees a chunk header always starts a chunk, even
" inside a runaway tex region (see nowebTT above); the tex regions lack
" keepend, so a contained chunk safely obscures their end patterns.
syntax region nowebCode
      \ matchgroup=nowebName start=/^<<.\{-}>>=\s*$/
      \ matchgroup=NONE
      \ end=/^@\%( \|$\)/me=s-1
      \ end=/^<<.\{-}>>=\s*$/me=s-1
      \ keepend
      \ contains=nowebChunkRef,@NoSpell
      \ containedin=tex.*

" Here, we mark the beginning of a new text chunk.
syntax match nowebStartText /^@\%( \|$\)/ containedin=tex.*

" The default methods for highlighting. Can be overridden later.
hi def link nowebStartText Constant
hi def link nowebTT     Constant
hi def link nowebTTOrphan nowebTT
hi def link nowebName     Type
hi def link nowebChunkRef nowebName

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
