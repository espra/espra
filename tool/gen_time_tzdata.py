#!/usr/bin/env python3

# Public Domain (-) 2026-present, The Espra Core Authors.
# See the Espra Core UNLICENSE file for details.

"""
General tzdata format conventions:

* Days and months are referred to using the shortest unique prefix, e.g. `M`,
  `Tu`, `W`, `Th`, `F`, `Sa`, `Su` for the days of the week.

* A value of `-` indicates that the field doesn't have a value.

The tzdata file has 5 different types of lines.

  # Comments
  L Timezone Aliases
  R DST Rules
  Z Timezone Definition Start
  Timezone Definition Updates

L <new_name> <old_name>

R <dst_rule_id> <start_year> <end_year> - <dst_month> <dst_day> <dst_time> <dst_offset> <substitution_chars>

* `end_year` can also be the special values of `o` (only for that year) or `ma`
  (max, i.e. still applies for the current year).

* `dst_day` can also be special values like `lastSu` (last Sunday of the month),
  `F>=8` (first Friday on or after the 8th), `Th<=25` (last Thursday on or
  before the 25th), etc.

* `dst_time` can be one of `H`, `HH`, `H:M`, `H:MM`, or `HH:MM`. `H` and `M`
  represent the hour, which can exceed 24 hours, and minute after midnight when
  the transition happens.

  These values can also have one of the following suffixes:

  * `s` indicates that the time is in the timezone's standard time.
  * `u` indicates that the time is in UTC.

  No suffix indicates that the time is in the timezone's local clock time at
  that point in time.

* `dst_offset` can be an offset of the form `H` or `H:MM`. A value of `0`
  indicates when the timezone comes off of DST. A value of `-1` makes DST the
  "default" time, so that they go "back" during winter.

* `substitution_chars` is used to replace a placeholder `%s` within the
  timezone's format string.

Z <name> <utc_offset> <dst_rule> <extra_info> [<end_year> [<end_month> [<end_day> [<end_time>]]]]

Update lines: <utc_offset> <dst_rule> <extra_info> [<end_year> [<end_month> [<end_day> [<end_time>]]]]

* `utc_offset` is formatted as `H:M:S` where the hours, minutes, and seconds can
  be either one or two digits. A prefix of `-` indicates a negative offset.

* `dst_rule` can be one of:

  * `-` to indicate that the timezone doesn't use DST.

  * A fixed DST offset like `-1`, `0:20`, etc. that's applied to the base
    timezone.

  * A reference to a `dst_rule_id` defined in a previous `R` line.

* `extra_info` typically specifies how to represent the timezone, with any `%s`
  replaced according to the `substitution_chars` in the matching `dst_rule`. But
  it also has a few special values:

  * `LMT` indicates that the UTC offset is derived from the timezone's historic
    local mean time.

  * `-00` indicates that it's not been possible to determine the historical UTC
    offset.

  * `%z` indicates that the name should use the UTC offset, e.g. `+01:00`.

* `end_year` is optional and can be used to specify the last year for which the
  definition is valid.

"""

import json

from common import DEBUG, exit, fetch, write_file, zig_file

BUILD_DIR = "build/sys_locale_info"
OUTPUT_FILE = "lib/time/tzdata.zig"

TZDATA = "https://data.iana.org/time-zones/tzdb/tzdata.zi"

MINUTE = 60
HOUR = 3600

# NOTE(tav): Our tests are linked to this value. So, if we update this value,
# e.g. to minimize historic data, we'd need to update the tests too.
NOW_YEAR = 2025

WEEKDAY_ENUM = {
    0: "sunday",
    1: "monday",
    2: "tuesday",
    3: "wednesday",
    4: "thursday",
    5: "friday",
    6: "saturday",
}

WEEKDAYS = {
    "Su": 0,
    "M": 1,
    "Tu": 2,
    "W": 3,
    "Th": 4,
    "F": 5,
    "Sa": 6,
}

MONTH_ENUM = {
    1: "january",
    2: "february",
    3: "march",
    4: "april",
    5: "may",
    6: "june",
    7: "july",
    8: "august",
    9: "september",
    10: "october",
    11: "november",
    12: "december",
}

MONTHS = {
    "Ja": 1,
    "F": 2,
    "Mar": 3,
    "Ap": 4,
    "May": 5,
    "Jun": 6,
    "Jul": 7,
    "Au": 8,
    "S": 9,
    "O": 10,
    "N": 11,
    "D": 12,
}

TRANSITION_ENUM = {
    "standard": "standard_time",
    "utc": "utc",
    "wall": "wall_time",
}


def fmt_dayspec(spec):
    typ = spec[0]
    if typ == "fixed":
        return f".specific_day = {spec[1]}"
    elif typ == "last":
        return f".last_weekday_of_month = .{WEEKDAY_ENUM[spec[1]]}"
    elif typ == "ge":
        return f".at_or_after = .{{ .day = {spec[2]}, .weekday = .{WEEKDAY_ENUM[spec[1]]} }}"
    elif typ == "le":
        return f".at_or_before = .{{ .day = {spec[2]}, .weekday = .{WEEKDAY_ENUM[spec[1]]} }}"


def generate_file(out, rules, timezones, version):
    out(f'pub const tzdata_version = "{version}";')
    out("""
pub const DST = union(enum) {
    continuous: []const ContinuousDST,
    oscillating: [2]OscillatingDST,
};

pub const DaySpec = union(enum) {
    at_or_after: struct { day: u8, weekday: Weekday },
    at_or_before: struct { day: u8, weekday: Weekday },
    last_weekday_of_month: Weekday,
    specific_day: u8,
};
""")
    out("pub const Month = enum(u8) {")
    for month in sorted(MONTH_ENUM):
        out(f"    {MONTH_ENUM[month]} = {month},")
    out("};")
    out("""
pub const ContinuousDST = struct {
    day: DaySpec,
    end_year: ?u16,
    month: Month,
    offset: i32,
    start_year: u16,
    transition_time: i32, // Always in wall time.
};

pub const OscillatingDST = struct {
    day: DaySpec,
    month: Month,
    offset: i32,
    transition_time: i32,
    transition_in: Transition,
};

pub const TimezoneRule = struct {
    std_offset: i32,
    dst: ?DST,
};

pub const Transition = enum(u8) {
    standard_time,
    utc,
    wall_time,
};
""")
    out("pub const Weekday = enum(u8) {")
    for weekday in sorted(WEEKDAY_ENUM):
        out(f"    {WEEKDAY_ENUM[weekday]} = {weekday},")
    out("};")
    out("")
    for name, rule in sorted(rules.items()):
        if rule[0] == "oscillating":
            continue
        out(f"const dst_rule_{name} = [_]ContinuousDST{{")
        for rule in rule[1]:
            out(f"""    .{{
        .day = .{{ {fmt_dayspec(rule["day"])} }},
        .end_year = {rule["end"] or "null"},
        .month = .{MONTH_ENUM[rule["month"]]},
        .offset = {rule["offset"]},
        .start_year = {rule["start"]},
        .transition_time = {rule["time"][0]},
    }},""")
        out("};")
    out("pub fn get_rule(tz: sys.Timezone) TimezoneRule {")
    out("    return switch (tz) {")
    out("        .UTC => .{ .std_offset = 0, .dst = null },")
    for name, spec in sorted(timezones.items()):
        if name == "UTC":
            continue
        name = f'@"{name}"'
        rule_id = spec["rule"]
        out(f"        .{name} => .{{")
        out(f"            .std_offset = {spec['offset']},")
        if rule_id is None:
            out("            .dst = null,")
            out("        },")
            continue
        out("            .dst = .{")
        rule = rules[rule_id]
        if rule[0] == "oscillating":
            out("                .oscillating = .{")
            for rule_spec in rule[1]:
                out(f"""                    .{{
                        .day = .{{ {fmt_dayspec(rule_spec["day"])} }},
                        .month = .{MONTH_ENUM[rule_spec["month"]]},
                        .offset = {rule_spec["offset"]},
                        .transition_time = {rule_spec["time"][0]},
                        .transition_in = .{TRANSITION_ENUM[rule_spec["time"][1]]},
                    }},""")
            out("                },")
        else:
            out(f"                .continuous = &dst_rule_{rule_id},")
        out("            },")
        out("        },")
    out("    };")
    out("}")
    out("")


def parse_day_spec(day, line):
    try:
        return ("fixed", int(day))
    except ValueError:
        pass
    if day.startswith("last"):
        return ("last", WEEKDAYS[day[4:]])
    if ">=" in day:
        dsplit = day.split(">=")
        return ("ge", WEEKDAYS[dsplit[0]], int(dsplit[1]))
    elif "<=" in day:
        dsplit = day.split("<=")
        return ("le", WEEKDAYS[dsplit[0]], int(dsplit[1]))
    exit(f"Unknown day spec {json.dumps(day)} on line {json.dumps(line)}")


def parse_time(time, line):
    factor = 1
    if time.startswith("-"):
        factor = -1
        time = time[1:]
    split = time.split(":")
    if len(split) == 1:
        return factor * int(split[0]) * HOUR
    if len(split) == 2:
        return factor * (int(split[0]) * HOUR + int(split[1]) * MINUTE)
    if len(split) == 3:
        return factor * (int(split[0]) * HOUR + int(split[1]) * MINUTE + int(split[2]))
    exit(f"Unexpected time {json.dumps(time)} on line {json.dumps(line)}")


def parse_time_spec(raw_time, line):
    time_at = "wall"
    time_str = raw_time
    time_suffix = raw_time[-1]
    if time_suffix == "s":
        time_at = "standard"
        time_str = time_str[:-1]
    elif time_suffix == "u":
        time_at = "utc"
        time_str = time_str[:-1]
    elif not time_suffix.isdigit():
        exit(f"Unexpected time {json.dumps(raw_time)} on line {json.dumps(line)}")
    if not time_str:
        exit(f"Unexpected time {json.dumps(raw_time)} on line {json.dumps(line)}")
    time = parse_time(time_str, line)
    if time is None:
        exit(f"Unexpected time {json.dumps(raw_time)} on line {json.dumps(line)}")
    return (time, time_at)


def parse_tz_spec(split, line, rules):
    split_len = len(split)
    if split_len < 3 or split_len > 7:
        exit(f"Unexpected timezone definition on line {json.dumps(line)}")
    split = split + [None] * (7 - split_len)
    offset, rule, extra, year, month, day, time = split
    offset = parse_time(offset, line)
    if rule == "-":
        rule = None
    elif rule in rules:
        rule = ("dst_rule", rule)
    else:
        rule = ("fixed", parse_time(rule, line))
    if year is not None:
        year = int(year)
    if month is not None:
        month = MONTHS[month]
    if day is not None:
        day = parse_day_spec(day, line)
    if time is not None:
        time = parse_time_spec(time, line)
    return {
        "offset": offset,
        "rule": rule,
        "extra": extra,
        "year": year,
        "month": month,
        "day": day,
        "time": time,
    }


def process_tzdata(data):
    rules = {}
    timezones = {}
    tz_name = None
    version = ""
    for line in data.splitlines():
        char = line[0]
        split = line.split()
        if char == "#":
            if split[1] == "version":
                version = line.split(" ")[2]
                if DEBUG:
                    print(f"\n.. Processing version {version}")
        elif char == "L":
            pass
        elif char == "R":
            rule_id, start, end, _, month, day, time, offset, subst = split[1:]
            start = int(start)
            if end == "o":
                end = start
            elif end == "ma":
                end = None
            else:
                end = int(end)
            month = MONTHS[month]
            day = parse_day_spec(day, line)
            time = parse_time_spec(time, line)
            offset = parse_time(offset, line)
            if subst == "-":
                subst = None
            if rule_id not in rules:
                rules[rule_id] = []
            rules[rule_id].append(
                {
                    "start": start,
                    "end": end,
                    "month": month,
                    "day": day,
                    "time": time,
                    "offset": offset,
                    "subst": subst,
                }
            )
        elif char == "Z":
            tz_name = split[1]
            if tz_name == "Etc/UTC":
                tz_name = "UTC"
            if tz_name in timezones:
                exit(f"Found duplicate timezone {json.dumps(tz_name)} on line {json.dumps(line)}")
            timezones[tz_name] = [parse_tz_spec(split[2:], line, rules)]
        else:
            spec = parse_tz_spec(split, line, rules)
            timezones[tz_name].append(spec)
    return rules, timezones, version


def prune_tzdata(ori_rules, ori_timezones):
    rules = {}
    timezones = {}
    seen_rules = set()
    for name, ori_specs in ori_timezones.items():
        if name == "Factory":
            continue
        specs = []
        for spec in ori_specs:
            if spec["year"] is None:
                specs.append(spec)
            elif spec["year"] > NOW_YEAR:
                exit(f"Found timezone {json.dumps(name)} with year {spec['year']} in the future")
        if len(specs) != 1:
            exit(f"Unexpected number of pruned specs found for timezone {json.dumps(name)}: {len(specs)}")
        spec = specs[0]
        timezones[name] = spec
        rule = spec["rule"]
        if rule and rule[0] == "dst_rule":
            seen_rules.add(rule[1])
    dead_rules = set()
    for rule_id in seen_rules:
        active = []
        for rule in ori_rules[rule_id]:
            end = rule["end"]
            if end is None or end >= NOW_YEAR:
                active.append(rule)
        count = len(active)
        if count == 2:
            if any(rule["end"] is not None for rule in active):
                exit(f"Found end year for oscillating rule {json.dumps(rule_id)}")
            rules[rule_id] = ("oscillating", active)
        elif count > 2:
            rules[rule_id] = ("continuous", active)
            offsets = set()
            for rule in active:
                if rule["time"][1] != "wall":
                    exit(f"Unexpected transition of {json.dumps(rule['time'][1])} time for continuous rule {json.dumps(rule_id)}")
                if rule["offset"]:
                    offsets.add(rule["offset"])
            # NOTE(tav): If this constraint ever gets violated, we'd need to
            # update the manner in which we calculate the DST offset inside
            # DateTime.utc() to handle multiple offsets.
            if len(offsets) != 1:
                exit(f"Found multiple offset values for continuous rule {json.dumps(rule_id)}: {offsets}")
        elif count == 0:
            dead_rules.add(rule_id)
        else:
            exit(f"Unexpected number of active rules found for rule {json.dumps(rule_id)}: {count}")
    for name, spec in timezones.items():
        rule = spec["rule"]
        if rule is None:
            continue
        if rule[0] == "dst_rule":
            rule_id = rule[1]
            if rule_id in dead_rules:
                spec["rule"] = None
            else:
                spec["rule"] = rule_id
        else:
            exit(f"Unexpected rule type {json.dumps(rule)} for timezone {json.dumps(name)}")
    return rules, timezones


def main():
    lines, out = zig_file("sys")
    data = fetch(TZDATA, BUILD_DIR, leading_newline=False)
    rules, timezones, version = process_tzdata(data)
    rules, timezones = prune_tzdata(rules, timezones)
    generate_file(out, rules, timezones, version)
    if DEBUG:
        print("\n".join(lines))
    write_file(lines, OUTPUT_FILE)


if __name__ == "__main__":
    main()
