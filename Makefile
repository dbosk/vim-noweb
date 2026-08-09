# Everything in this repository tangles from vim-noweb.nw; this Makefile
# is committed only because it cannot tangle itself.  The tangled .vim
# files are committed too, so the plugin works from a bare clone --
# plugin managers do not run notangle.

NWSRC=	vim-noweb.nw
TANGLED=	syntax/noweb.vim autoload/noweb.vim ftdetect/noweb.vim
TANGLED+=	ftplugin/noweb.vim plugin/noweb.vim
TANGLED+=	LICENSE

.PHONY: all
all: ${TANGLED}

# -t8 keeps the tabs in the syntax file's header comment; cpif only
# touches a file when its content actually changed.
${TANGLED}: ${NWSRC}
	mkdir -p ${@D}
	notangle -t8 -R"[[$@]]" ${NWSRC} | cpif $@

vim-noweb.tex: ${NWSRC}
	noweave -n -delay -t8 -autolang -index -filter tominted $< > $@

# mkdir _minted: minted v3's latexminted writes its highlight cache
# there but does not create the directory when kpsewhich finds another
# _minted elsewhere on the TeX path; without it every chunk renders as
# a literal <MINTED> placeholder.
vim-noweb.pdf: vim-noweb.tex LICENSE
	mkdir -p _minted
	latexmk -pdf -shell-escape vim-noweb.tex

.PHONY: check
check: all
	noroots ${NWSRC}
	git diff --exit-code -- syntax autoload ftdetect ftplugin plugin LICENSE

.PHONY: clean
clean:
	-latexmk -C vim-noweb.tex 2>/dev/null
	${RM} vim-noweb.tex
