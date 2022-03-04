##############################################################
## THIS MAKEFILE IS A PORTABILITY STUB. IT IS ONLY USED ON  ##
## PLATFORMS WHERE THE SYSTEM "make" IS NOT GNU-COMPATIBLE. ##
## SEE GNUmakefile INSTEAD.                                 ##
##############################################################
all:
	MAKEFLAGS='' gmake

$(.TARGETS):
	MAKEFLAGS='' gmake $(.TARGETS)
