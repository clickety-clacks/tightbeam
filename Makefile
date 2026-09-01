KERNEL_NAME := $(shell uname -s)
PREFIX = $(MIX_APP_PATH)/priv
BUILD = $(MIX_APP_PATH)/obj

CURSOR_SOURCE = c_src/cursor_signing_native.c
CURSOR_OBJECT = $(BUILD)/cursor_signing_native.o
CURSOR_LIBRARY = $(PREFIX)/cursor_signing_native.so

VISITOR_SOURCE = c_src/visitor_keyring_nif.c
VISITOR_OBJECT = $(BUILD)/visitor_keyring_nif.o
VISITOR_LIBRARY = $(PREFIX)/visitor_keyring_nif.so

CFLAGS += -O2 -Wall -Wextra -Werror -fPIC -fvisibility=hidden
ERL_CFLAGS ?= -I"$(ERL_EI_INCLUDE_DIR)"
ERTS_CFLAGS ?= -I"$(ERTS_INCLUDE_DIR)"

ifeq ($(KERNEL_NAME),Darwin)
LDFLAGS += -dynamiclib -undefined dynamic_lookup
else
LDFLAGS += -shared
endif

all: $(CURSOR_LIBRARY) $(VISITOR_LIBRARY)

$(CURSOR_LIBRARY): $(CURSOR_OBJECT) | $(PREFIX)
	$(CC) -o $@ $^ $(LDFLAGS)

$(CURSOR_OBJECT): $(CURSOR_SOURCE) | $(BUILD)
	$(CC) -c $(ERL_CFLAGS) $(CFLAGS) -o $@ $<

$(VISITOR_LIBRARY): $(VISITOR_OBJECT) | $(PREFIX)
	$(CC) -o $@ $^ $(LDFLAGS)

$(VISITOR_OBJECT): $(VISITOR_SOURCE) | $(BUILD)
	$(CC) -c $(ERTS_CFLAGS) $(CFLAGS) -o $@ $<

$(PREFIX) $(BUILD):
	mkdir -p $@

clean:
	rm -f $(CURSOR_OBJECT) $(CURSOR_LIBRARY) $(VISITOR_OBJECT) $(VISITOR_LIBRARY)

.PHONY: all clean
