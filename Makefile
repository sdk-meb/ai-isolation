# Build the seccomp exec supervisor.
# Needs the headers:  sudo apt install libseccomp-dev
CC     ?= cc
CFLAGS ?= -O2 -Wall -Wextra

aisup: aisup.c
	$(CC) $(CFLAGS) -o $@ $< -lseccomp

clean:
	rm -f aisup

.PHONY: clean
