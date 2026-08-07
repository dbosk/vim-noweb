# Everything in this repository tangles from vim-noweb.nw; this Makefile
# is committed only because it cannot tangle itself.  The tangled .vim
# files are committed too, so the plugin works from a bare clone --
# plugin managers do not run notangle.

NWSRC=	vim-noweb.nw
TANGLED=	syntax/noweb.vim autoload/noweb.vim ftdetect/noweb.vim

.PHONY: all
all: ${TANGLED}

# -t8 keeps the tabs in the syntax file's header comment; cpif only
# touches a file when its content actually changed.
${TANGLED}: ${NWSRC}
	notangle -t8 -R"[[$@]]" ${NWSRC} | cpif $@

vim-noweb.tex: ${NWSRC}
	noweave -n -delay -t8 -autolang -index -filter tominted $< > $@

vim-noweb.pdf: vim-noweb.tex
	latexmk -pdf -shell-escape vim-noweb.tex

.PHONY: check
check: all
	noroots ${NWSRC}
	git diff --exit-code -- syntax autoload ftdetect

.PHONY: clean
clean:
	-latexmk -C vim-noweb.tex 2>/dev/null
	${RM} vim-noweb.tex
