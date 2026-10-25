# goosedex: `make` builds out/goosedex, `make test` runs the unit tests,
# `make run ARGS="pikachu --shiny"` runs it.

GOOSE ?= goose
CC ?= cc
CFLAGS ?= -O2
OUT := out
GEN := src/gen

SPRITES := $(GEN)/embedded_sprites.goose
ASSETS := assets/pokemon.json $(shell find assets/colorscripts -type f)
SOURCES := src/main.goose src/args.goose src/sprites.goose src/inflate.goose

all: $(OUT)/goosedex

$(OUT):
	mkdir -p $@

$(OUT)/generate_sprites: tools/generate_sprites.goose tools/deflate.goose | $(OUT)
	$(GOOSE) build -o $@ $<

# Writes data.bin beside the module that embeds it.
$(SPRITES): $(OUT)/generate_sprites $(ASSETS)
	$(OUT)/generate_sprites assets/pokemon.json assets/colorscripts $(GEN)

# --standalone puts the runtime in the same C file, so the C compiler drops
# the parts goosedex does not use: a smaller binary that binds a third as
# many symbols at launch as `goose build` links in.
$(OUT)/goosedex.c: $(SOURCES) $(SPRITES) | $(OUT)
	$(GOOSE) --standalone -o $@ $<

$(OUT)/goosedex: $(OUT)/goosedex.c
	$(CC) $(CFLAGS) $< -o $@ -lm -pthread
	strip $@

$(OUT)/tests: src/tests.goose $(SOURCES) $(SPRITES) | $(OUT)
	$(GOOSE) build -o $@ $<

test: $(OUT)/tests
	$(OUT)/tests

run: $(OUT)/goosedex
	$(OUT)/goosedex $(ARGS)

clean:
	rm -rf $(OUT) $(GEN)

.PHONY: all test run clean
