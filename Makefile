KERNEL_NAME := $(shell uname -s)
PREFIX = $(MIX_APP_PATH)/priv
BUILD = $(MIX_APP_PATH)/obj
SOURCE = c_src/cursor_signing_native.c
OBJECT = $(BUILD)/cursor_signing_native.o
LIBRARY = $(PREFIX)/cursor_signing_native.so

CFLAGS += -O2 -Wall -Wextra -Werror -fPIC -fvisibility=hidden
ERL_CFLAGS ?= -I"$(ERL_EI_INCLUDE_DIR)"

ifeq ($(KERNEL_NAME),Darwin)
LDFLAGS += -dynamiclib -undefined dynamic_lookup
else
LDFLAGS += -shared
endif

all: $(LIBRARY)

$(LIBRARY): $(OBJECT) | $(PREFIX)
	$(CC) -o $@ $^ $(LDFLAGS)

$(OBJECT): $(SOURCE) | $(BUILD)
	$(CC) -c $(ERL_CFLAGS) $(CFLAGS) -o $@ $<

$(PREFIX) $(BUILD):
	mkdir -p $@

clean:
	rm -f $(OBJECT) $(LIBRARY)

.PHONY: all clean
