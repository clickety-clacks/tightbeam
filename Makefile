KERNEL_NAME := $(shell uname -s)
PREFIX = $(MIX_APP_PATH)/priv
BUILD = $(MIX_APP_PATH)/obj

VISITOR_SOURCE = c_src/visitor_keyring_nif.c
VISITOR_OBJECT = $(BUILD)/visitor_keyring_nif.o
VISITOR_LIBRARY = $(PREFIX)/visitor_keyring_nif.so

CFLAGS += -O2 -Wall -Wextra -Werror -fPIC -fvisibility=hidden
ERTS_CFLAGS ?= -I"$(ERTS_INCLUDE_DIR)"

ifeq ($(KERNEL_NAME),Darwin)
LDFLAGS += -dynamiclib -undefined dynamic_lookup
else
LDFLAGS += -shared
endif

all: $(VISITOR_LIBRARY)

$(VISITOR_LIBRARY): $(VISITOR_OBJECT) | $(PREFIX)
	$(CC) -o $@ $^ $(LDFLAGS)

$(VISITOR_OBJECT): $(VISITOR_SOURCE) | $(BUILD)
	$(CC) -c $(ERTS_CFLAGS) $(CFLAGS) -o $@ $<

$(PREFIX) $(BUILD):
	mkdir -p $@

clean:
	rm -f $(VISITOR_OBJECT) $(VISITOR_LIBRARY)

.PHONY: all clean
