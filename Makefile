# Makefile — Akmon
#
# Build pipeline:
#   1. deps        : verify build/runtime tools (Debian/Ubuntu: installs missing apt packages by default)
#   2. gen-vmlinux : generate bpf/vmlinux.h from running kernel BTF
#   3. bpf         : compile monitor.bpf.c → monitor.bpf.o (eBPF bytecode)
#   4. ui          : build React dashboard (Vite) → internal/graphapi/static/
#   5. build       : deps + gen-vmlinux + bpf + ui + Go binary
#   6. install     : install binary, BPF object, templates from akmon-templates + systemd unit
#
# Targets:
#   make deps          — check deps; on Debian/Ubuntu installs missing apt packages (INSTALL_DEPS=0 to skip)
#   make gen-vmlinux   — generate bpf/vmlinux.h (run once per kernel upgrade)
#   make bpf           — compile only the eBPF C programs
#   make ui            — build the React dashboard (requires Node.js ≥ 18)
#   make build         — full build (deps + gen-vmlinux + bpf + ui + go binary)
#   make build-no-ui   — build without rebuilding the React UI
#   make clean         — remove all generated files
#   make clean-deps    — remove ui/node_modules + Akmon build apt/snap toolchain (see scripts/clean_deps.sh)
#   make run           — build and run as root (requires root)
#   make fmt           — format Go and C source files
#   make install       — install as systemd service (then: sudo make enable)
#                      — set TEMPLATES_SRC=../akmon-templates (default) to find YAML bundles
#   make uninstall     — stop, disable and remove all installed files
#   make enable        — systemctl enable --now akmon
#   make disable       — systemctl disable --now akmon

# ── Tool configuration ────────────────────────────────────────────────────────
CLANG           ?= clang
LLVM_STRIP      ?= llvm-strip
GO              ?= go
BPFTOOL         ?= bpftool

# ── Paths ─────────────────────────────────────────────────────────────────────
BPF_SRC         := bpf/monitor.bpf.c
BPF_OBJ         := bpf/monitor.bpf.o
BPF_VMLINUX     := bpf/vmlinux.h
BINARY          := bin/akmon
CMD_DIR         := cmd/monitor

# ── Architecture ──────────────────────────────────────────────────────────────
# Detect host arch and map to BPF target arch name.
# This sets __TARGET_ARCH_<arch> which vmlinux.h uses to select
# the correct register definitions.
ARCH            := $(shell uname -m | sed 's/x86_64/x86/;s/aarch64/arm64/')
BPF_ARCH_DEFINE := __TARGET_ARCH_$(ARCH)

# ── Clang BPF compiler flags ──────────────────────────────────────────────────
# -g                  : emit BTF (required for CO-RE; NOT debug symbols)
# -O2                 : optimize (eBPF verifier rejects unoptimized code)
# -target bpf         : compile for BPF architecture
# -D__TARGET_ARCH_... : select register layout in vmlinux.h
# -I./bpf             : find common.h and vmlinux.h
# -I/usr/include/bpf  : find bpf_helpers.h, bpf_core_read.h etc.
# -Wall -Wno-unused   : catch bugs, suppress noisy unused-variable warnings
BPF_CFLAGS := \
    -g \
    -O2 \
    -target bpf \
    -D$(BPF_ARCH_DEFINE) \
    -I./bpf \
    -I/usr/include/bpf \
    -Wall \
    -Wno-unused-variable \
    -Wno-unused-function

# ── Default target ────────────────────────────────────────────────────────────
.PHONY: all
all: build

# ── Dependency check ─────────────────────────────────────────────────────────
# INSTALL_DEPS=1 (default): on Debian/Ubuntu, `make deps` runs apt-get for missing
# build packages (requires sudo). Check only: `make deps INSTALL_DEPS=0`.
# Use `=` (not `?=`) so an empty INSTALL_DEPS in the environment does not disable apt.
INSTALL_DEPS = 1

.PHONY: deps
deps:
	@echo "==> Checking dependencies (INSTALL_DEPS=$(INSTALL_DEPS))..."
	@INSTALL_DEPS=$(INSTALL_DEPS) bash scripts/check_deps.sh || { \
		echo ""; \
		echo "==> deps failed: fix remaining issues above (kernel/BTF, Go version, or sudo for apt)."; \
		exit 1; \
	}

# ── Generate vmlinux.h ───────────────────────────────────────────────────────
# Must be run on the target machine (needs /sys/kernel/btf/vmlinux).
# Re-run after every kernel upgrade.
.PHONY: gen-vmlinux
gen-vmlinux:
	@echo "==> Generating bpf/vmlinux.h from kernel BTF..."
	@bash scripts/gen_vmlinux.sh || { \
		echo ""; \
		echo "==> gen-vmlinux failed: need /sys/kernel/btf/vmlinux and bpftool (see script output above)."; \
		echo "    Re-run after installing bpftool or switching to a BTF-enabled kernel."; \
		exit 1; \
	}
	@echo "==> vmlinux.h generated."

# ── Compile eBPF C programs ───────────────────────────────────────────────────
# Depends on vmlinux.h — run 'make gen-vmlinux' first if it doesn't exist.
.PHONY: bpf
bpf: $(BPF_OBJ)

$(BPF_OBJ): $(BPF_SRC) bpf/common.h $(BPF_VMLINUX)
	@echo "==> Compiling eBPF programs: $< → $@"
	@mkdir -p $(dir $@)
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@
	@echo "==> Stripping DWARF debug info (keeping BTF)..."
	$(LLVM_STRIP) -g $@
	@echo "==> eBPF object ready: $@"

# ── Build React dashboard ─────────────────────────────────────────────────────
# Requires Node.js ≥ 18 and npm. Output is embedded into the Go binary via
# go:embed in internal/graphapi/server.go.
.PHONY: ui
ui:
	@echo "==> Building React dashboard (Vite)..."
	cd ui && npm install --silent && npm run build
	@echo "==> UI assets written to internal/graphapi/static/"

# ── Build Go binary ───────────────────────────────────────────────────────────
# The Go loader reads monitor.bpf.o from disk (no bpf2go code generation step).
# We copy the compiled BPF object next to the binary so they deploy together.
# `build` is the one-shot target: deps → gen-vmlinux → bpf → UI → Go binary (+ bundled BPF).
.PHONY: build-banner
build-banner:
	@echo "==> make build — deps -> gen-vmlinux -> bpf -> ui -> Go (one command)"

.PHONY: build
build: build-banner deps gen-vmlinux bpf ui
	@echo "==> Building Go daemon..."
	@mkdir -p bin
	CGO_ENABLED=0 $(GO) build \
	    -ldflags="-s -w -X main.Version=$(shell git describe --tags --always --dirty 2>/dev/null || echo dev)" \
	    -o $(BINARY) \
	    ./$(CMD_DIR)/...
	@echo "==> Copying BPF object next to binary..."
	cp $(BPF_OBJ) bin/monitor.bpf.o
	@echo "==> Build complete: $(BINARY) + bin/monitor.bpf.o"

# ── Build Go binary only (skip UI rebuild) ───────────────────────────────────
.PHONY: build-no-ui
build-no-ui: deps gen-vmlinux bpf
	@echo "==> Building Go daemon (skipping UI rebuild)..."
	@mkdir -p bin
	CGO_ENABLED=0 $(GO) build \
	    -ldflags="-s -w -X main.Version=$(shell git describe --tags --always --dirty 2>/dev/null || echo dev)" \
	    -o $(BINARY) \
	    ./$(CMD_DIR)/...
	cp $(BPF_OBJ) bin/monitor.bpf.o
	@echo "==> Build complete: $(BINARY) + bin/monitor.bpf.o"

# ── Build only the eBPF object (no Go) ───────────────────────────────────────
.PHONY: bpf-only
bpf-only: deps gen-vmlinux $(BPF_OBJ)
	@echo "==> eBPF-only build complete."

# ── Verify the eBPF object (dry-run load) ────────────────────────────────────
# Uses bpftool to verify the program without actually loading it.
# The trap ensures the pinned path is cleaned up even if bpftool is interrupted.
.PHONY: verify
verify: deps gen-vmlinux $(BPF_OBJ)
	@echo "==> Verifying eBPF program with bpftool..."
	@trap 'rm -f /sys/fs/bpf/akmon_verify' EXIT INT TERM; \
	 $(BPFTOOL) prog load $(BPF_OBJ) /sys/fs/bpf/akmon_verify type tracepoint 2>&1 \
	    && echo "  [+] Verification passed." \
	    || { echo "  [!] Verification failed. Check verifier output above."; exit 1; }

# ── Run (requires root) ───────────────────────────────────────────────────────
.PHONY: run
run: build
	@echo "==> Starting monitor (requires root)..."
	sudo $(BINARY)

# ── Install paths ─────────────────────────────────────────────────────────────
SVC_NAME     := akmon
SVC_BINARY   := /usr/local/bin/$(SVC_NAME)
SVC_LIB      := /usr/lib/$(SVC_NAME)
SVC_ETC      := /etc/$(SVC_NAME)
SVC_LOG      := /var/log/$(SVC_NAME)
SVC_UNIT     := /etc/systemd/system/$(SVC_NAME).service
SVC_ROTATE   := /etc/logrotate.d/$(SVC_NAME)

# Checkout of https://github.com/ClawGuard-Labs/akmon-templates
TEMPLATES_SRC ?= ../akmon-templates

# ── Install ───────────────────────────────────────────────────────────────────
# Installs binary, BPF object, YAML templates from TEMPLATES_SRC, systemd unit, logrotate.
# Requires: $(TEMPLATES_SRC)/behavioral-templates and $(TEMPLATES_SRC)/nuclei-templates
# After install: sudo systemctl enable --now akmon
.PHONY: install
install: build
	@test -d "$(TEMPLATES_SRC)/behavioral-templates" || ( \
		echo "ERROR: $(TEMPLATES_SRC)/behavioral-templates not found."; \
		echo "  Clone akmon-templates next to akmon, or run: sudo make install TEMPLATES_SRC=/path/to/akmon-templates"; \
		exit 1)
	@test -d "$(TEMPLATES_SRC)/nuclei-templates" || ( \
		echo "ERROR: $(TEMPLATES_SRC)/nuclei-templates not found."; \
		echo "  Clone akmon-templates next to akmon, or run: sudo make install TEMPLATES_SRC=/path/to/akmon-templates"; \
		exit 1)
	@echo "==> Creating directories..."
	sudo install -d -m 0755 $(SVC_LIB)
	sudo install -d -m 0755 $(SVC_ETC)/behavioral-templates
	sudo install -d -m 0755 $(SVC_ETC)/nuclei-templates
	sudo install -d -m 0750 $(SVC_LOG)
	@echo "==> Installing binary and BPF object..."
	sudo install -m 0755 $(BINARY)   $(SVC_BINARY)
	sudo install -m 0644 bin/monitor.bpf.o $(SVC_LIB)/monitor.bpf.o
	@echo "==> Installing config.yaml..."
	sudo install -m 0644 config.yaml $(SVC_ETC)/config.yaml
	@echo "==> Installing templates from $(TEMPLATES_SRC)..."
	sudo cp -r "$(TEMPLATES_SRC)"/behavioral-templates/* $(SVC_ETC)/behavioral-templates/
	sudo cp -r "$(TEMPLATES_SRC)"/nuclei-templates/* $(SVC_ETC)/nuclei-templates/
	@echo "==> Installing systemd unit..."
	sudo install -m 0644 scripts/$(SVC_NAME).service $(SVC_UNIT)
	@echo "==> Installing logrotate config..."
	sudo install -m 0644 scripts/logrotate.d/$(SVC_NAME) $(SVC_ROTATE)
	sudo systemctl daemon-reload
	@echo ""
	@echo "==> Install complete."
	@echo "    Enable and start : sudo make enable"
	@echo "    Follow logs      : journalctl -u $(SVC_NAME) -f"
	@echo "    Log file         : tail -f $(SVC_LOG)/monitor.log"

# ── Uninstall ─────────────────────────────────────────────────────────────────
# Stops, disables, and removes the service and all installed files.
# Logs at $(SVC_LOG) are preserved — remove manually if desired.
.PHONY: uninstall
uninstall:
	@echo "==> Stopping and disabling service..."
	-sudo systemctl stop    $(SVC_NAME) 2>/dev/null
	-sudo systemctl disable $(SVC_NAME) 2>/dev/null
	sudo rm -f $(SVC_UNIT)
	sudo systemctl daemon-reload
	@echo "==> Removing installed files..."
	sudo rm -f  $(SVC_BINARY)
	sudo rm -rf $(SVC_LIB)
	sudo rm -rf $(SVC_ETC)
	sudo rm -f  $(SVC_ROTATE)
	@echo ""
	@echo "==> Uninstall complete. Logs preserved at $(SVC_LOG)"
	@echo "    To also remove logs: sudo rm -rf $(SVC_LOG)"

# ── Enable / disable ──────────────────────────────────────────────────────────
.PHONY: enable
enable:
	sudo systemctl enable --now $(SVC_NAME)

.PHONY: disable
disable:
	sudo systemctl disable --now $(SVC_NAME)

# ── Test ─────────────────────────────────────────────────────────────────────
# Runs template detection unit tests. Detailed logs go to tests/logs/*.log.
.PHONY: test
test:
	@echo "==> Running template detection tests..."
	cd tests && $(GO) test ./...
	@echo "==> Detailed logs: tests/logs/"

# ── Format ───────────────────────────────────────────────────────────────────
.PHONY: fmt
fmt:
	@echo "==> Formatting Go sources..."
	$(GO) fmt ./...
	@echo "==> Formatting C sources with clang-format (if available)..."
	@command -v clang-format >/dev/null 2>&1 && \
	    clang-format -i bpf/*.c bpf/*.h || \
	    echo "  [~] clang-format not found, skipping C formatting."

# ── Lint (requires golangci-lint on PATH) ────────────────────────────────────
.PHONY: lint
lint:
	@echo "==> Running golangci-lint..."
	@command -v golangci-lint >/dev/null 2>&1 || { \
	    echo "  [!] golangci-lint not installed. Install: https://golangci-lint.run/welcome/install/"; \
	    exit 1; }
	golangci-lint run ./...

# ── Clean ────────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	@echo "==> Cleaning build artifacts..."
	rm -f $(BPF_OBJ)
	rm -f $(BINARY) bin/monitor.bpf.o
	rm -rf internal/graphapi/static/assets
	@echo "==> Clean complete. (vmlinux.h and ui/node_modules preserved)"

# ── Deep clean (including vmlinux.h) ─────────────────────────────────────────
.PHONY: distclean
distclean: clean
	rm -f $(BPF_VMLINUX)
	@echo "==> dist-clean complete."

.PHONY: clean-deps
clean-deps:
	@bash scripts/clean_deps.sh

# ── Help ─────────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "Akmon — eBPF agent security monitor"
	@echo ""
	@echo "Targets:"
	@echo "  deps          Check all build and runtime dependencies"
	@echo "  gen-vmlinux   Generate bpf/vmlinux.h from kernel BTF (run once per kernel)"
	@echo "  bpf           Compile eBPF C programs to bpf/monitor.bpf.o"
	@echo "  ui            Build React dashboard (requires Node.js ≥ 18)"
	@echo "  build         Full build: eBPF + UI + Go binary → bin/ (default)"
	@echo "  build-no-ui   Full build skipping React rebuild (faster iteration)"
	@echo "  verify        Dry-run verify eBPF program with bpftool"
	@echo "  run           Build and run as root"
	@echo "  install       Install binary, BPF, YAML from TEMPLATES_SRC (../akmon-templates), systemd + logrotate"
	@echo "  uninstall     Stop, disable, and remove all installed files"
	@echo "  enable        systemctl enable --now akmon"
	@echo "  disable       systemctl disable --now akmon"
	@echo "  test          Run template detection tests (logs in tests/logs/)"
	@echo "  fmt           Format Go and C source files"
	@echo "  lint          Run golangci-lint"
	@echo "  clean         Remove build artifacts"
	@echo "  clean-deps    Remove ui/node_modules + Akmon build apt/snap toolchain (destructive)"
	@echo "  distclean     Remove all generated files including vmlinux.h"
	@echo ""
	@echo "Quick start:"
	@echo "  make deps"
	@echo "  make gen-vmlinux"
	@echo "  make build"
	@echo "  sudo ./bin/akmon --ui :9090"
