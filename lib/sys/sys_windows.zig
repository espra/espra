// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

const std = @import("std");

const DWORD = u32;
const WINAPI = std.os.windows.WINAPI;

extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: DWORD) callconv(WINAPI) DWORD;

extern "kernel32" fn GetTempPathW(nBufferLength: u32, lpBuffer: [*]u16) callconv(WINAPI) DWORD;
