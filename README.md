# vim-noweb

Vim syntax highlighting for [noweb](https://github.com/nrnrnr/noweb)
literate programs (`.nw` files): the prose is highlighted as TeX, the
noweb markup (chunk headers, chunk references, `[[...]]` quotes) is
marked, and each code chunk's body is highlighted in the chunk's own
language, inferred the same way noweb's `autolang` filter does it
(filename-like chunk names, `#!` lines, and propagation along
`<<use>>` edges).  The name and shebang lookups ask the editor's own
filetype database — `vim.filetype.match()` on Neovim, the
`filetypedetect` autocommands run against a scratch buffer on Vim —
covering every language the editor can detect; a small fixed table
remains as last resort.

Originally a mirror of <http://www.vim.org/scripts/script.php?script_id=2129>.

## Installation

The tangled plugin files are committed, so any plugin manager works
from a bare clone, e.g. with vim-plug:

```vim
Plug 'dbosk/vim-noweb'
```

The language-aware highlighting refreshes on every write; `:NowebSyncLang`
refreshes it on demand.

## Completion and navigation

Chunk names complete after `<<`: `<C-x><C-o>` in plain Vim, and
automatically with YCM (the plugin registers the `<<` trigger for
you at startup; other completion frameworks pick the same function
up through their omnifunc bridges).  Completion always reflects the
live buffer — no write needed.  It closes the `>>` unless it is
already there, and the menu marks referenced-but-undefined chunks —
handy for spotting typos.  At a definition position (the `<<` opens
the line) the not-yet-defined names sort first, matching the
use-first-define-later workflow.

Chunk definitions resolve as tags: `<C-]>` on a reference jumps to
the definition, `:tnext` steps through the appends (a chunk defined
several times has several tag matches), `<C-t>` jumps back and `g]`
lists them all.  `]c` / `[c` step through every occurrence
(definitions and uses) of the chunk under the cursor, and
`:NowebRefs` collects them in the location list.  Set
`g:noweb_no_maps` to keep the bracket maps unmapped, or bind the
`<Plug>(noweb-next-occurrence)` / `<Plug>(noweb-prev-occurrence)`
maps to keys of your own.

## Language intelligence in chunks (Neovim)

On Neovim, every *typed root chunk* (a chunk named like a file,
defined but never used) gets an **invisible tangled shadow buffer**,
kept in sync with the live `.nw` and served to a language server.
Results map back into the noweb source:

- **diagnostics** appear on the offending chunk lines as you type —
  no write needed;
- **completion** inside a chunk comes from the language server
  (through the same omnifunc, so YCM and friends pick it up; `.`
  triggers it);
- **`K`** shows hover documentation, **`gd`** jumps to a definition —
  landing in the right chunk of the `.nw`, even across chunks;
- **`:NowebTangled`** opens the tangled code read-only in a split,
  cursor-synced in both directions with the source (toggle to
  close);
- **`:NowebMake {cmd}`** tangles the root under the cursor, runs
  `{cmd}` (`%` = the tangled file) through noweb's `nolinemap`, and
  fills the quickfix list with positions in the `.nw`.

The prose gets the full [VimTeX](https://github.com/lervag/vimtex)
treatment when VimTeX is installed: motions, text objects, TOC, and
`\cite`/`\ref` completion routed through the same omnifunc.  Set
`g:noweb_vimtex = 0` to opt out.

Chunk languages come from the same inference the `autolang` weave
filter uses, including its name-pattern rules: chunks named like
`test [[foo.py]]`, `test [[foo.sh]]` or `test [[Makefile]]` are
typed by default (matching the makefiles repository's default
`-langrule` weave flags), and `g:noweb_langrules` prepends your own
`[pattern, filetype]` pairs — first match wins:

```vim
let g:noweb_langrules = [['^check \[\[.*\.py\]\]', 'python']]
```

This needs the `linemark`/`nolinemap` tools from the
[dbosk/noweb](https://github.com/dbosk/noweb) fork (`contrib/dbosk`)
on `PATH` alongside `notangle`, and a language server per language:
`jedi-language-server` is the Python default (`pipx install
jedi-language-server`); Lean works through lean.nvim's own setup by
filetype.  Configure languages via `g:noweb_languages`, e.g.

```vim
let g:noweb_languages = #{ python: #{ lsp: ['pyright-langserver', '--stdio'] } }
```

Set `g:noweb_shadow = 0` to disable the machinery entirely; plain
Vim keeps the v1.6.1 feature set.

## Hacking

The source of truth is `vim-noweb.nw` — a literate program from which
everything under `syntax/`, `autoload/`, `ftdetect/`, `ftplugin/`,
`plugin/` and `lua/` tangles.  Do
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
