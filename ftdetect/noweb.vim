" setfiletype yields if the filetype is already set, so this coexists with
" any user autocmd doing the same.
autocmd BufRead,BufNewFile *.nw setfiletype noweb
