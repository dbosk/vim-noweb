# vim-noweb

Vim syntax highlighting for [noweb](https://github.com/nrnrnr/noweb)
literate programs (`.nw` files): the prose is highlighted as TeX, the
noweb markup (chunk headers, chunk references, `[[...]]` quotes) is
marked, and each code chunk's body is highlighted in the chunk's own
language, inferred the same way noweb's `autolang` filter does it
(filename-like chunk names, `#!` lines, and propagation along
`<<use>>` edges).  On Neovim the name and shebang lookups use the
editor's own filetype database (`vim.filetype.match()`), covering
every language Neovim can detect; on other Vims a small fixed table
serves as fallback.

Originally a mirror of <http://www.vim.org/scripts/script.php?script_id=2129>.

## Installation

The tangled plugin files are committed, so any plugin manager works
from a bare clone, e.g. with vim-plug:

```vim
Plug 'dbosk/vim-noweb'
```

The language-aware highlighting refreshes on every write; `:NowebSyncLang`
refreshes it on demand.

## Hacking

The source of truth is `vim-noweb.nw` — a literate program from which
everything under `syntax/`, `autoload/` and `ftdetect/` tangles.  Do
not edit the `.vim` files directly; edit the `.nw`, run `make`, and
commit the `.nw` together with the re-tangled `.vim` files.  `make
check` must pass: it verifies the root chunks and that the tangled
files match the working tree.

Two conventions keep the tangle exact (details in the woven document):
every literal `<<` or `>>` inside a code chunk is escaped as `@<<` /
`@>>`, and tangling uses `-t8` to preserve tabs.

Building needs [noweb](https://github.com/dbosk/noweb) (the fork
providing `autolang` and `tominted` for the weave); `make
vim-noweb.pdf` additionally needs `latexmk` and minted.

## License

MIT (see `LICENSE`, which also tangles from `vim-noweb.nw`).  The
plugin descends from the `nw.vim` of Xun Gong and Dirk Baechle
(vim.org script 2129).
