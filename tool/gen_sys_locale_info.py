#!/usr/bin/env python3

# Public Domain (-) 2026-present, The Espra Core Authors.
# See the Espra Core UNLICENSE file for details.

import csv
import io
import json
import xml.etree.ElementTree as ET

from common import DEBUG, exit, fetch, write_file, zig_file

BUILD_DIR = "build/sys_locale_info"
OUTPUT_FILE = "lib/sys/locale_info.zig"

CLDR_LIST_JSON = "https://api.github.com/repos/unicode-org/cldr/git/trees/main:common/main"
TZDATA = "https://data.iana.org/time-zones/tzdb/tzdata.zi"
WINDOWS_ZONES_XML = "https://raw.githubusercontent.com/unicode-org/cldr/main/common/supplemental/windowsZones.xml"

languages = set()
regions = set(["001", "ZZ"])
scripts = set()
skipped_regions = set()
timezones = set()

# NOTE(Tav): We swap UTC and Etc/UTC around as it's the most common timezone.
tz_aliases = {}


def add_language(subtag):
    if subtag != subtag.lower():
        exit(f"Found invalid language subtag {json.dumps(subtag)} in the CLDR directory listing")
    languages.add(subtag)


def add_script_or_region(subtag):
    if subtag == subtag.upper():
        if all(c.isdigit() for c in subtag):
            if DEBUG and subtag not in skipped_regions and subtag not in regions:
                print(f".. Skipping numeric region subtag {json.dumps(subtag)}")
            skipped_regions.add(subtag)
        elif len(subtag) != 2:
            if DEBUG and subtag not in skipped_regions:
                print(f".. Skipping long region subtag {json.dumps(subtag)}")
            skipped_regions.add(subtag)
        else:
            regions.add(subtag)
    else:
        scripts.add(subtag)


def process_cldr():
    data = fetch(CLDR_LIST_JSON, BUILD_DIR, "cldr-list.json", leading_newline=False)
    items = json.loads(data)["tree"]
    tags = [item["path"][:-4] for item in items if item["path"].endswith(".xml")]
    if DEBUG:
        print("")
    for tag in tags:
        split = tag.split("_")
        if len(split) == 1:
            add_language(split[0])
        elif len(split) == 2:
            add_language(split[0])
            add_script_or_region(split[1])
        elif len(split) == 3:
            add_language(split[0])
            add_script_or_region(split[1])
            add_script_or_region(split[2])
        else:
            exit(f"Found invalid tag {json.dumps(tag)} in the CLDR directory listing")
    if DEBUG:
        print(f"\n.. Found {len(languages)} languages, {len(scripts)} scripts, and {len(regions)} regions in the CLDR directory listing\n")
        print(f".. Languages: {sorted(languages)}\n")
        print(f".. Scripts: {sorted(scripts)}\n")
        print(f".. Regions: {sorted(regions)}")


def process_iso_3166_1():
    data = fetch("https://raw.githubusercontent.com/lukes/ISO-3166-Countries-with-Regional-Codes/refs/heads/master/all/all.csv", BUILD_DIR, "iso-3166-1.csv")
    reader = csv.DictReader(io.StringIO(data))
    if DEBUG:
        print("")
    for row in reader:
        region = row["alpha-2"]
        if region not in regions:
            if DEBUG:
                print(f".. Found unknown region {json.dumps(region)} ({row['name']}) in the iso-3166-1.csv file")
            regions.add(region)


def process_languages(out):
    out("pub const Language = enum(u16) {")
    for code in sorted(languages):
        if code == "or":
            out('    @"or",')
        else:
            out(f"    {code},")
    out("")
    out("    pub fn parse(s: []const u8) ?Language {")
    out("        return std.meta.stringToEnum(Language, s);")
    out("    }")
    out("};\n")


def process_regions(out):
    out("pub const Region = enum(u16) {")
    for code in sorted(regions):
        if code == "001":
            out('    @"001",')
        else:
            out(f"    {code},")
    out("")
    out("    pub fn parse(s: []const u8) ?Region {")
    out("        return std.meta.stringToEnum(Region, s);")
    out("    }")
    out("};\n")


def process_scripts(out):
    out("pub const Script = enum(u8) {")
    for code in sorted(scripts):
        out(f"    {code},")
    out("")
    out("    pub fn parse(s: []const u8) ?Script {")
    out("        return std.meta.stringToEnum(Script, s);")
    out("    }")
    out("};\n")


def process_timezones(out):
    tzdata = fetch(TZDATA, BUILD_DIR)
    for line in tzdata.splitlines():
        if line.startswith("Z "):
            split = line.split()
            name = split[1]
            if name == "Factory":
                continue
            if name in timezones:
                exit(f"Found duplicate timezone {json.dumps(name)} in the tzdata file")
            if name == "Etc/UTC":
                name = "UTC"
            timezones.add(name)
        elif line.startswith("L "):
            split = line.split()
            name = split[1]
            if name == "Etc/UTC":
                name = "UTC"
            if name not in timezones:
                exit(f"Found unknown timezone {json.dumps(name)} in the tzdata file")
            alias = split[2]
            if alias == "UTC":
                alias = "Etc/UTC"
            if alias in tz_aliases:
                exit(f"Found duplicate alias for {json.dumps(alias)} in the tzdata file")
            tz_aliases[alias] = name

    data = fetch(WINDOWS_ZONES_XML, BUILD_DIR)
    root = ET.fromstring(data)
    windows = {}
    for zone in root.iter("mapZone"):
        windows_name = zone.attrib["other"]
        region = zone.attrib["territory"]
        iana = zone.attrib["type"].split()[0]
        if iana not in timezones:
            if iana in tz_aliases:
                iana = tz_aliases[iana]
            else:
                exit(f"Found unknown timezone {json.dumps(iana)} in the windowsZones.xml file")
        if windows_name not in windows:
            windows[windows_name] = {"mapping": None, "regional": {}}
        if region == "001":
            windows[windows_name]["mapping"] = iana
        else:
            if region not in regions:
                exit(f"Found unknown region {json.dumps(region)} in the windowsZones.xml file")
            windows[windows_name]["regional"][region] = iana
    if DEBUG:
        print("")
    for entry in windows.values():
        mapping = entry["mapping"]
        for region, iana in list(sorted(entry["regional"].items())):
            if iana == mapping:
                entry["regional"].pop(region)
                if DEBUG:
                    print(f".. Removed redundant override for {region} -> {iana}")

    out("const old_timezones = std.StaticStringMap(Timezone).initComptime(.{")
    for name in sorted(tz_aliases):
        alias = tz_aliases[name]
        if alias == "UTC":
            out(f'    .{{ "{name}", .UTC }},')
        else:
            out(f'    .{{ "{name}", .@"{alias}" }},')
    out("});")
    out("")
    out("const WindowsTimezone = struct {")
    out("    name: []const u8,")
    out("    mapping: Timezone,")
    out("    overrides: []const struct {")
    out("        region: Region,")
    out("        mapping: Timezone,")
    out("    },")
    out("};")
    out("")
    out("const windows_timezones = [_]WindowsTimezone{")
    for name, entry in windows.items():
        mapping = entry["mapping"]
        if mapping != "UTC":
            mapping = f'@"{mapping}"'
        out("    .{")
        out(f'        .name = "{name}",')
        out(f"        .mapping = .{mapping},")
        if len(entry["regional"]) > 0:
            out("        .overrides = &.{")
            for region, mapping in sorted(entry["regional"].items()):
                if mapping != "UTC":
                    mapping = f'@"{mapping}"'
                out(f"            .{{ .region = .{region}, .mapping = .{mapping} }},")
            out("        },")
        else:
            out("        .overrides = &.{},")
        out("    },")
    out("};")
    out("")
    out("pub const Timezone = enum(u16) {")
    out("    UTC,")
    for name in sorted(timezones):
        if name == "UTC":
            continue
        out(f'    @"{name}",')
    out("")
    out("    pub fn parse(s: []const u8) ?Timezone {")
    out("        return std.meta.stringToEnum(Timezone, s) orelse old_timezones.get(s);")
    out("    }")
    out("")
    out("    pub const from_windows_name = if (builtin.os.tag == .windows)")
    out("        _from_windows_name")
    out("    else")
    out('        @compileError("from_windows_name is only available on Windows");')
    out("")
    out("    fn _from_windows_name(s: []const u8, region: ?Region) ?Timezone {")
    out("        for (windows_timezones) |entry| {")
    out("            if (std.mem.eql(u8, s, entry.name)) {")
    out("                if (region) |r| {")
    out("                    for (entry.overrides) |override| {")
    out("                        if (r == override.region) {")
    out("                            return override.mapping;")
    out("                        }")
    out("                    }")
    out("                }")
    out("                return entry.mapping;")
    out("            }")
    out("        }")
    out("        return null;")
    out("    }")
    out("};\n")

    print(f"\n.. Found {len(languages)} languages, {len(regions)} regions, and {len(scripts)} scripts")
    print(f".. Found {len(timezones)} timezones, {len(tz_aliases)} aliases, and {len(windows)} windows mappings")


def main():
    lines, out = zig_file("builtin", "std")
    process_cldr()
    process_languages(out)
    process_iso_3166_1()
    process_regions(out)
    process_scripts(out)
    process_timezones(out)
    write_file(lines, OUTPUT_FILE)


if __name__ == "__main__":
    main()
