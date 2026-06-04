# Build the vthread trace JVMTI agent as a shared library.
#
# Usage:
#   source ../config/env.sh   # exports JAVA_HOME pointing to the patched JDK
#   make
#
# Output: libvthread_trace_agent.so
#
# Load it with: java -agentpath:/path/to/libvthread_trace_agent.so ...

TARGET   := libvthread_trace_agent.so
SRC      := vthread_trace_agent.c

CC       ?= gcc
CFLAGS   := -shared -fPIC -O2 -Wall -Wextra
INCLUDES := -I$(JAVA_HOME)/include -I$(JAVA_HOME)/include/linux

$(TARGET): $(SRC)
	@if [ -z "$(JAVA_HOME)" ]; then \
		echo "ERROR: JAVA_HOME not set. Run 'source ../config/env.sh' first."; \
		exit 1; \
	fi
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $<
	@echo "built $@"

clean:
	rm -f $(TARGET)

.PHONY: clean