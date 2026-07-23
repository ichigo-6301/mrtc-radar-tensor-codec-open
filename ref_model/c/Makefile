CC ?= gcc
CFLAGS ?= -std=c99 -Wall -Wextra -Werror -O2 -Iinclude
GCC_FORMAT_TRUNCATION_FLAG := $(shell $(CC) -dumpversion 2>/dev/null | awk -F. '{if ($$1 >= 7) print "-Wno-error=format-truncation"}')
CFLAGS += $(GCC_FORMAT_TRUNCATION_FLAG)
BUILD := build
RESULTS := ../results
SRC := src/mrtc_block_header.c src/mrtc_rice.c src/mrtc_rdtc_encode.c src/mrtc_rdtc_decode.c src/mrtc_crc32.c
OBJ := $(patsubst src/%.c,$(BUILD)/%.o,$(SRC))

.PHONY: all test demo clean dirs

all: dirs $(BUILD)/test_rice $(BUILD)/test_header $(BUILD)/test_rdtc_ref $(BUILD)/test_cross_vectors

dirs:
	mkdir -p $(BUILD) $(RESULTS)

$(BUILD)/%.o: src/%.c | dirs
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/test_rice: test/test_rice.c $(OBJ)
	$(CC) $(CFLAGS) $^ -o $@

$(BUILD)/test_header: test/test_header.c $(OBJ)
	$(CC) $(CFLAGS) $^ -o $@

$(BUILD)/test_rdtc_ref: test/test_rdtc_ref.c $(OBJ)
	$(CC) $(CFLAGS) $^ -o $@

$(BUILD)/test_cross_vectors: test/test_cross_vectors.c $(OBJ)
	$(CC) $(CFLAGS) $^ -o $@

$(BUILD)/showcase_codec_demo: test/showcase_codec_demo.c $(OBJ)
	$(CC) $(CFLAGS) $^ -o $@

test: all
	@echo test_name,codec_mode,num_samples,raw_bytes,compressed_bytes,raw_bypass,selected_k,decode_equal,pass_flag > $(RESULTS)/summary_c_ref_tests.csv
	$(BUILD)/test_rice
	$(BUILD)/test_header
	$(BUILD)/test_rdtc_ref $(RESULTS)/summary_c_ref_tests.csv
	$(BUILD)/test_cross_vectors ../../vectors/rdtc_v1 $(RESULTS)/summary_matlab_c_crosscheck.csv

demo: dirs $(BUILD)/showcase_codec_demo
	mkdir -p ../../build/showcase_codec_demo
	$(BUILD)/showcase_codec_demo \
		../../build/showcase_codec_demo/input_iq_le.bin \
		../../build/showcase_codec_demo/packet.bin \
		../../build/showcase_codec_demo/decoded_iq_le.bin \
		../../build/showcase_codec_demo/result.csv

clean:
	rm -rf $(BUILD)
