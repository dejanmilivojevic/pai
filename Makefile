EMACS ?= emacs
LISP_DIR := lisp
TEST_DIR := test
EXTENSION_DIR := extensions
VENDOR_LOAD := -L vendor/vui

# Core test files.
CORE_TESTS := $(wildcard $(TEST_DIR)/*-test.el)
# Extensions are optional (a separate repository cloned into extensions/).
# Each lives in its own subdirectory, with its tests in <ext>/test/.
EXTENSION_DIRS := $(patsubst %/,%,$(wildcard $(EXTENSION_DIR)/*/))
EXTENSION_FILES := $(wildcard $(EXTENSION_DIR)/*/*.el)
EXTENSION_TEST_DIRS := $(wildcard $(EXTENSION_DIR)/*/test)
EXTENSION_TESTS := $(wildcard $(EXTENSION_DIR)/*/test/*-test.el)
EXTENSION_LOAD := $(foreach d,$(EXTENSION_DIRS) $(EXTENSION_TEST_DIRS),-L $(d))
TESTS := $(CORE_TESTS) $(EXTENSION_TESTS)

.PHONY: test test-core test-extensions compile clean lint

# Run the ERT suite in batch mode: the core tests, plus the extension tests
# when extensions/ is present.  `make test-core' runs only the core tests
# (without loading any extension), `make test-extensions' only the others.
# Tests run with a throw-away HOME, so nothing they do can reach the real
# ~/.pai (settings, sessions, memory) even when a test forgets to bind
# `pai-directory'.
test:
	@test_home=$$(mktemp -d); trap 'rm -rf "$$test_home"' EXIT; \
	HOME="$$test_home" $(EMACS) -Q --batch \
	  -L $(LISP_DIR) -L $(TEST_DIR) $(EXTENSION_LOAD) $(VENDOR_LOAD) \
	  --eval "(setq ert-batch-backtrace-right-margin 200)" \
	  $(foreach t,$(TESTS),-l $(t)) \
	  -f ert-run-tests-batch-and-exit

test-core:
	@$(MAKE) --no-print-directory test EXTENSION_DIR=/nonexistent

test-extensions:
	@test -n "$(EXTENSION_TESTS)" || { echo "No extension tests: clone pai-extensions into $(EXTENSION_DIR)/"; exit 1; }
	@$(MAKE) --no-print-directory test CORE_TESTS=

# Byte-compile all lisp files, treating warnings as errors.
compile:
	$(EMACS) -Q --batch \
	  -L $(LISP_DIR) $(VENDOR_LOAD) \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  --eval "(setq byte-compile-warnings '(not docstrings))" \
	  -f batch-byte-compile $(LISP_DIR)/*.el
ifneq ($(EXTENSION_FILES),)
	$(EMACS) -Q --batch \
	  -L $(LISP_DIR) $(EXTENSION_LOAD) $(VENDOR_LOAD) \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  --eval "(setq byte-compile-warnings '(not docstrings))" \
	  -f batch-byte-compile $(EXTENSION_FILES)
endif

clean:
	rm -f $(LISP_DIR)/*.elc $(TEST_DIR)/*.elc $(EXTENSION_DIR)/*.elc $(EXTENSION_DIR)/*/*.elc $(EXTENSION_DIR)/*/test/*.elc
