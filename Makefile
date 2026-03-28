# Public Domain (-) 2026-present, The Espra Core Authors.
# See the Espra Core UNLICENSE file for details.

.PHONY: dependencies generate wgpu-native/build wgpu-native/clone wuffs/clone
.SILENT:

UNAME := $(shell uname -s 2>/dev/null)

ifeq ($(UNAME),Linux)
    WGPU_TARGET := dep/wgpu-native/target/release/libwgpu_native.a
else ifeq ($(UNAME),Darwin)
    WGPU_TARGET := dep/wgpu-native/target/release/libwgpu_native.a
else ifeq ($(OS),Windows_NT)
    WGPU_TARGET := dep/wgpu-native/target/release/wgpu_native.dll
endif

WGPU_SOURCES := $(shell find dep/wgpu-native/src -name '*.rs' 2>/dev/null)

dependencies: wgpu-native/build wuffs/clone

generate: dependencies lib/sys/locale_info.zig lib/time/tzdata.zig

lib/sys/locale_info.zig: tool/gen_sys_locale_info.py
	./tool/gen_sys_locale_info.py

lib/time/tzdata.zig: tool/gen_time_tzdata.py
	./tool/gen_time_tzdata.py

wgpu-native/build: wgpu-native/clone
	$(MAKE) -s $(WGPU_TARGET)

wgpu-native/clone:
	./tool/clone_repo.py wgpu-native https://github.com/gfx-rs/wgpu-native.git ccffe5755fac311d567131e5797ff5aa0a2b9369 --init-submodules

wuffs/clone:
	./tool/clone_repo.py wuffs https://github.com/google/wuffs.git b9145634fd0c39026a73aed601626616763f4a54

$(WGPU_TARGET): $(WGPU_SOURCES) dep/wgpu-native/Cargo.toml dep/wgpu-native/Cargo.lock
	echo ">> Building wgpu-native ...\n"
	cargo build --release --manifest-path dep/wgpu-native/Cargo.toml
	echo ""
	touch $(WGPU_TARGET)
