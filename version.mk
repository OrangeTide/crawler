# version.mk - the single source of truth for the project version.
# Bump PROJ_VERSION, commit, then tag that commit v$(PROJ_VERSION). The build
# derives the full version string from this plus git describe, so a tarball or
# a tagless checkout still reports a sane version. See docs on the release
# process, and the release-check target in the Makefile.
PROJ_VERSION := 0.29.1
