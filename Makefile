# Public Domain (-) 2026-present, The Espra Core Authors.
# See the Espra Core UNLICENSE file for details.

.PHONY: generate

generate: lib/sys/locale_info.zig lib/time/tzdata.zig

lib/sys/locale_info.zig: tool/gen_sys_locale_info.py
	./tool/gen_sys_locale_info.py

lib/time/tzdata.zig: tool/gen_time_tzdata.py
	./tool/gen_time_tzdata.py
