SRC = c_src/visitor_keyring_nif.c
PREFIX = $(MIX_APP_PATH)/priv
BUILD = $(MIX_APP_PATH)/obj
LIB = $(PREFIX)/visitor_keyring_nif.so
OBJ = $(BUILD)/visitor_keyring_nif.o

CFLAGS += -I"$(ERTS_INCLUDE_DIR)" -fPIC -fvisibility=hidden -O2 -Wall -Wextra -Werror

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
LDFLAGS += -dynamiclib -undefined dynamic_lookup
else
LDFLAGS += -shared
endif

all: $(LIB)

$(LIB): $(OBJ) | $(PREFIX)
	$(CC) -o $@ $^ $(LDFLAGS)

$(OBJ): $(SRC) | $(BUILD)
	$(CC) -c $(CFLAGS) -o $@ $<

$(PREFIX) $(BUILD):
	mkdir -p $@

clean:
	$(RM) $(LIB) $(OBJ)

.PHONY: all clean
