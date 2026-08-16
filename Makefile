ELEMENT_VERSION := v1.12.25
ELEMENT_SHA256  := 14d7f2671eb1fbccc690e7f176042d72ed2b4e34f7326a007e8b1540b1e748bb
ELEMENT_URL     := https://github.com/element-hq/element-web/releases/download/$(ELEMENT_VERSION)/element-$(ELEMENT_VERSION).tar.gz
ELEMENT_TARBALL := element-source/element-$(ELEMENT_VERSION).tar.gz

GET_DEPENDENCIES_WITH := corral fetch
LINT_WITH := corral run -- pony-lint

config ?= release
ifdef config
  ifeq (,$(filter $(config),debug release))
    $(error Unknown configuration "$(config)")
  endif
endif

ifeq ($(config),release)
  PONYC_FLAGS :=
else
  PONYC_FLAGS := --debug
endif

# `ssl` names the C SSL library `stallion` links against, via `ponylang/ssl`.
# Option names match hobby's and stallion's; unlike those libraries this
# defaults, so `make` works on a machine with OpenSSL 3.
ssl ?= 3.0.x
ifeq ($(ssl), 3.0.x)
  PONYC_FLAGS := $(PONYC_FLAGS) -Dopenssl_3.0.x
else ifeq ($(ssl), 1.1.x)
  PONYC_FLAGS := $(PONYC_FLAGS) -Dopenssl_1.1.x
else ifeq ($(ssl), libressl)
  PONYC_FLAGS := $(PONYC_FLAGS) -Dlibressl
else
  $(error Unknown SSL version "$(ssl)". Must set using 'ssl=FOO')
endif

SOURCES := $(wildcard marilwyd/*.pony)
TEST_SOURCES := $(wildcard marilwyd_test/*.pony)

.PHONY: all build test lint run clean realclean
all: build

build: build/marilwyd

build/marilwyd: $(SOURCES)
	mkdir -p build
	$(GET_DEPENDENCIES_WITH)
	corral run -- ponyc $(PONYC_FLAGS) -o build marilwyd

build/marilwyd_test: $(SOURCES) $(TEST_SOURCES)
	mkdir -p build
	$(GET_DEPENDENCIES_WITH)
	corral run -- ponyc $(PONYC_FLAGS) -o build marilwyd_test

test: build/marilwyd_test
	build/marilwyd_test

# No ssl= needed: pony-lint reads the sources and does not link. It runs
# through corral so it can resolve the dependency packages.
lint:
	$(GET_DEPENDENCIES_WITH)
	$(LINT_WITH) marilwyd
	$(LINT_WITH) marilwyd_test

# Element is a release artifact, not source. The checksum is what makes an
# untracked 40MB tarball reproducible; the extract is atomic so an interrupted
# run cannot leave a partial tree that looks up to date to make.
$(ELEMENT_TARBALL):
	mkdir -p element-source
	curl -fL --proto '=https' --tlsv1.2 -o $@.tmp $(ELEMENT_URL)
	mv $@.tmp $@

build/element: $(ELEMENT_TARBALL)
	echo "$(ELEMENT_SHA256)  $(ELEMENT_TARBALL)" | sha256sum -c -
	rm -rf $@ $@.tmp
	mkdir -p $@.tmp
	tar xzf $(ELEMENT_TARBALL) --strip-components=1 -C $@.tmp
	mv $@.tmp $@

# marilwyd binds loopback and advertises the same port it listens on, so the
# generated Element config points back at this process.
#
# CREDENTIALS is a file of password hashes; generate entries with
#   printf '%s' "$$PASSWORD" | build/marilwyd hash-password alice
CREDENTIALS ?= credentials.json

run: build/marilwyd build/element
	build/marilwyd serve \
	  --server-name localhost:8008 \
	  --asset-root build/element \
	  --credentials $(CREDENTIALS)

clean:
	rm -rf build/marilwyd build/marilwyd_test build/marilwyd.o \
	  build/marilwyd_test.o build/test-asset-root build/test-credentials*.json

realclean:
	rm -rf build
