.default: build
.PHONY: build docs

DOCS=docs/api

build:
	cd sample; dub

docs:
	dmd -Dd$(DOCS) -o- lib/src/nfnitloop/fcgid/application.d

