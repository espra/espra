# XON (XON Object Notation)

XON is a human-friendly config format that keeps values as strings until you
decide otherwise. This results in a config format that does what you expect,
without surprises.

## Why

Use XON when:

* Type coercion has burned you before.

* You want spaces in keys/values, without having to quote everything.

* You need nesting, but not a programming language.

* You value a simple, predictable spec.

Don't use XON if:

* You need universal support today.

* JSON, YAML, TOML, or KDL are good enough for your needs.

* You need a programming language like Cue, Dhall, HCL, KCL, or Jsonnet.

## Syntax

```xon
// Line comment

some block {
    key = some value
    keys can have spaces = another value
    quoted value = "only needed when the value has {meta [characters]}"

    some list = [
        item 1
        item 2
        etc.
    ]

    multiline = `
        first line sets indentation baseline
          subsequent lines must meet or exceed it
    `

    some nested block {
        items = [one, two, three]
    }
}
```

## File Extension

`.xon`

## Decoder Conventions

Parser emits strings. Decoder interprets them based on the target type:

| Input  | Target bool | Target string | Target int | Target float |
|--------|-------------|---------------|------------|--------------|
| `true` | `true`      | `"true"`      | error      | error        |
| `42`   | error       | `"42"`        | `42`       | `42.0`       |
| `3.14` | error       | `"3.14"`      | error      | `3.14`       |
| `NO`   | error       | `"NO"`        | error      | error        |
| `0123` | error       | `"0123"`      | error      | error        |

We specify standards for conversion to common data types:

* Booleans: `true` and `false` only.

* Integer values:

  * Decimal values, e.g. `1234`, `-567`, `+89`, etc.

    * To avoid the octal trap, if a number starts with `0` but isn't just `0`,
      it will generate an error.

  * Hex values with both lower and upper case characters, e.g. `0xab47`,
    `0Xab47`, `0xAB47`, `0XAB47`, `-0xab47`, `+0xab47`, etc.

  * Octal values, e.g. `0o777`, `-0o127`, `+0o345`.

  * Legibility `_` separator anywhere except the start of values, end of values,
    consecutively, or after the `0x`, `0X` or `0o` prefixes, e.g. `2_00_000`,
    `0xdead_beef`, etc.

* Float values:

  * Decimal values, e.g. `1.23`, `.5`, `2.`, `-.5`, `+2.`, etc.

  * Scientific notation, e.g. `1.2e10`, `1.2e+10`, `1.2E-10`, `-1.2e10`, etc.

  * Legibility `_` separator anywhere except the start and end of segments (the
    parts separated by `.` and `e` or `E`), e.g. `3.141_592_653`, etc.

  * Supports the special values of `nan`, `inf`, `-inf`, and `+inf` (lowercase
    only).

* Time-related values:

  * Datetime values use the common RFC 3339 format,
    `YYYY-MM-DDTHH:MM:SS[.SSS...](Z|±HH:MM)` with optional sub-second precision.
    The timezone component must either be `Z` for UTC, or a `±HH:MM` offset.

    ```xon
    created = 2026-01-15T10:30:00Z
    expires = 2026-01-15T23:30:00.123456789+05:30
    ```

  * Datetime values that cannot be formatted as RFC 3339, e.g. when the year
    exceeds 9999, must error.

  * Time duration values are encoded like `14h35m0.2s`. Durations can be
    positive or negative, and the accepted units are `w`, `d`, `h`, `m`, `s`,
    `ms`, `µs`, `μs`, `us`, and `ns`. All units must be whole integers, except
    `s` which can be fractional.

    ```xon
    timeout = 30s
    interval = 1h30m
    offset = -4h30m
    ```

* Optional values:

  * The literal `nil` translates to "empty"/None/null for pointer or optional
    types.

  * If the target happens to be a pointer to a string or an optional string,
    then the "empty"/None/null interpretation shall take precedence. The quoted
    `"nil"` can be used if the explicit string value is desired.

## Benefits for Config Files

Use natural language in config files without needing to put everything in
quotes. Compare this XON:

```xon
description = A simple config file
display name = Alice Fung
```

To TOML where users must quote every value, as well as all keys with spaces:

```toml
description = "A simple config file"
"display name" = "Alice Fung"
```

And to JSON, where users must quote everything:

```json
{
    "description": "A simple config file",
    "display name": "Alice Fung"
}
```

Avoid the accidental type coercions of YAML:

```yaml
enabled: NO         # becomes false
version: 1.0        # becomes a float, instead of the expected semver string
id: 0123            # becomes the octal 83, instead of "0123"
country: NO         # becomes false, instead of the code for Norway
```

By letting the decoder decide, XON avoids accidental misconfigurations:

```xon
enabled = NO        // stays "NO", decoder decides
version = 1.0       // stays "1.0", you control the typing
id = 0123           // stays "0123"
country = NO        // stays "NO"
```

Unlike JSON, where duplicate values are often silently accepted by most
implementations:

```json
{
    "port": 8080,
    "port": 9090
}
```

XON rejects duplicate keys, limiting the impact of accidental repeats:

```xon
port = 8080
port = 9090  // ERROR!
```

## Comparison

| Feature                                  | XON | JSON | JSON5   | YAML    | TOML     | KDL |
|------------------------------------------|-----|------|---------|---------|----------|-----|
| Caller-controlled type conversions       | yes | no   | no      | no      | no       | no  |
| Errors on invalid type conversions       | yes | yes  | yes     | no      | yes      | yes |
| Comments                                 | yes | no   | yes     | yes     | yes      | yes |
| Unquoted values                          | yes | no   | no      | yes     | no       | yes |
| Multiline strings + stripped indentation | yes | no   | no      | yes     | no       | yes |
| Spec complexity                          | low | med  | med     | high    | med-high | med |

## Usage

Using the Go decoder:

```go
import (
    "os"
    "espra.dev/pkg/xon"
)

type Config struct {
    BootstrapLink   string     `xon:"bootstrap link"`
    DataDirectory   string     `xon:"data directory"`
    Nodes           []Node     `xon:"node"`
}

type Node struct {
    Host   string    `xon:"host"`
    Port   uint16    `xon:"port"`
}

func main() {
    data, err := os.ReadFile("config.xon")
    cfg := &Config{}
    err = xon.Decode(data, cfg)
    ...
}
```

Example config:

```xon
bootstrap link = https://espra.dev/bootstrap?limit=50
data directory = /var/espra

node {
    host = fast.espra.dev
    port = 8040
}

node {
    host = archive.espra.dev
    port = 8041
}
```

## Rules

Current version: `0.1`.

XON supports 4 different core constructs:

* Strings
* Blocks
* Lists
* Comments

XON files are UTF-8 encoded:

* Only ` ` (space) and `\t` (horizontal tab) are treated as whitespace.

* `\r\n` is normalized to `\n` before parsing, so both Unix and Windows line
  endings are supported.

### Comments

Comments begin with a `//` and continue to the end of the line. Inline comments
must have whitespace before the `//`:

```xon
// This is a comment
host = localhost            // This is an inline comment
link = https://example.com  // The double slash in the URL is not a comment
```

Comments can appear:

* On their own line.

* After a value on the same line.

* After `{`, `}`, `[`, or `]`.

```xon
server {  // production config
    host = localhost
    ports = [
        8080  // primary
        8081  // fallback
    ]
}  // end server
```

There are no block comments in XON.

### Strings

Strings are the primitive unit in XON:

```xon
<block-name> {          // string
    <key> = <value>     // string = string
    list = [a, b, c]    // string = list of strings
}
```

Strings appear as:

* Block names
* Keys
* Values, when the value is not a list or a block

Strings can be made up of any byte sequence. But they must use `<|0xNN|>` byte
escapes to represent:

* `\r`
* Invalid UTF-8 byte sequences

Strings follow the same parsing rules in all contexts, and can be one of:

* Unquoted
* Quoted
* Multiline

Unquoted strings are automatically trimmed for whitespace, so spacing can be
used to improve legibility, e.g.

```xon
  primary node = node-1.espra.com
secondary node = node-2.espra.com
```

Strings must be quoted if they:

* Are empty.

* Have leading or trailing whitespace.

* Contain any XON meta character sequence, i.e.

  * Start with `[` or `//`.

  * End with `]` or `,`.

  * Contain `//`, `=`, `{`, `}`, `[`, or `]` preceded by whitespace.

This lets us use values like URLs without having to quote them all the time,
e.g.

```xon
link 1 = https://example.com
link 2 = https://example.com/items[]=foo
link 3 = https://example.com/group/{id}
link 4 = https://example.com/?query=foo
```

Quoted strings are enclosed in `"`, e.g.

```xon
key = "some value with { characters that need quotes }"
```

Strings must be multiline if they contain unescaped `\n` or `"` bytes, e.g.

```xon
knuth = `
"Premature optimization is the root of all evil."
— Donald Knuth
`
```

Multiline strings:

* Begin and end with a matching odd number of backtick characters, e.g. 1, 3, 5,
  etc. For example, if the string contains one backtick, you can enclose it in a
  multiline with three backticks.

* An even number of consecutive backticks is interpreted as an empty string,
  e.g. ` `` `.

* Strip whitespace and/or newlines after the opening backtick sequence, and
  before the closing backtick sequence.

* Detect the base indentation from the amount of leading whitespace on the first
  non-empty line. All horizontal tabs are treated as being equivalent to 4
  spaces.

* Strip the detected base indentation from all non-empty lines.

* Error if any non-empty lines have content within the base indentation region,
  i.e. have less indentation than the first non-empty line.

Multiline strings cannot be used as block names or keys, e.g.

```xon
// ERROR!
`line one
line two` {
    ...
}

// ERROR!
`line one
line two` = value
```

However, quoted block names and keys are totally fine, e.g.

```xon
"name with = sign" {
    ...
}

"key with = sign" = value
```

Empty block names and keys are also fine:

```xon
"" {
    ...
}

"" = value
```

Except when a string is a list element, it cannot appear on a line by itself and
can only be followed by whitespace or an inline comment on the same line.

### Byte Escapes

Strings can contain byte escapes using the syntax `<|0xNN|>` where `NN`
can be any two hex digits, i.e. `0-9`, `a-f`, or `A-F`. This is useful for
representing:

* `\r` or `\r\n` sequences that might otherwise get normalized.
* Control characters that would not normally be visible.
* Values with byte sequences that would not be valid UTF-8.

```xon
crlf = line1<|0x0D|><|0x0A|>line2
^c = <|0x03|>
quote = say <|0x22|>hello<|0x22|>
```

If the parser encounters `<|0x`, it must be followed by exactly two hex digits
and `|>`, otherwise it is an error. The literal `<|0x` sequence can be embedded
in a string, by escaping the opening `<`:

```xon
literal = "<|0x3C|>|0x0D|>"   // produces the literal: <|0x0D|>
```

Formatters must always use byte escapes for:

* `\r`
* All non-printable control characters except `\t`
* Any byte sequence that would be invalid UTF-8

### Key/Value Pairs

Key/value pairs are constructed with a `<key>` string followed by one or more
whitespace, a literal `=`, one or more whitespace, and a `<value>` where the
value can either be a string or a list.

```xon
name = Alice Fung

location=London // ERROR! Space needed around the =
```

### Blocks

Blocks act as a container for key/value pairs. All blocks must be named. An
unnamed block must result in an error:

```xon
{
    // ERROR!
}
```

Empty blocks can be represented by `{}` on the same line, or with the braces on
separate lines:

```xon
middleware {}

health check {
}
```

Blocks are constructed with a `<block-name>` followed by one or more whitespace
and a literal `{`. The opening brace must either:

* Be followed by whitespace and a newline, or

* Be followed by an inline comment, or

* Be immediately followed by `}` to form an empty block.

It is an error to not have any whitespace before the opening brace:

```xon
server{  // ERROR!
    host = example.com
}
```

A line containing the closure of a block must not be followed by anything else
besides whitespace or inline comments.

### Block Contents

Within a block, each line must be one of:

* A key/value pair
* A nested block
* A comment
* Empty (whitespace only)

Duplicate keys within the same block must result in an error:

```xon
server {
    port = 8080
    port = 9090  // ERROR!
}
```

Nested blocks with the same name are allowed and are typically decoded as a
list, e.g.

```xon
server {
    host = primary.example.com
}

server {
    host = backup.example.com
}
```

### Lists

Lists are ordered collections of values. They are enclosed within `[` and `]`:

```xon
tags = [tech, finance, impact]
```

The opening `[` can be immediately followed by a value, a newline, or an inline
comment. Likewise, the closing `]` can immediately follow a value or be on a
line by itself.

List elements can be separated by commas, newlines, or both:

```xon
// Commas only:
ports = [8080, 8081, 8082]

// Newline only:
allowed hosts = [
    localhost
    example.com
    api.example.com
]

// Mixed
features = [
    auth, logging
    metrics
]
```

Trailing commas are permitted:

```xon
ports = [8080, 8081, 8082,]

features = [
    auth,
    logging,
    metrics,
]
```

Commas must be followed by either whitespace or a newline as this helps to
improve legibility. Likewise, whitespace and newlines are not allowed before
commas.

To avoid accidental omission of commas, the use of commas with multiple elements
on the same line when any element is unquoted and contains whitespace must
result in an error:

```xon
list = [one two, three] // ERROR!

// This avoids potential confusion as to whether:
//
//   ["one two", "three"] or ["one", "two", "three"] was intended
```

Empty lists can be represented by `[]` on the same line, or with brackets on
separate lines:

```xon
disabled features = []

disabled tests = [
]
```

List elements cannot be omitted. A leading comma or consecutive commas must
result in an error, e.g.

```xon
x = [, a, b]   // ERROR!

y = [a,, b]    // ERROR!
```

List elements can be strings (unquoted, quoted, or multiline) and even nested
lists:

```xon
hosts = ["example.com", "example.net"]

matrix = [
    [1, 2, 3]
    [4, 5, 6]
]
```

Lists of blocks cannot be represented directly within `[]` constructs:

```xon
list = [
    // ERROR!
    {
        key = value
    }
]
```

Instead, the same block name must be repeated multiple times to implicitly
create a list of those blocks.

### Top Level

A XON file's top level behaves like an implicit unnamed block, i.e. there's no
need to wrap it in a `{}` like in JSON.

The top level can contain:

* Key/value pairs
* Named blocks
* Comments
* Empty lines

Duplicate keys at the top level result in an error, and follow the same rules as
blocks.

### Versioned Blocks

Versioned blocks allow config files to support a future version whilst still
being compatible with existing deployments. This solves the tension between
catching typos, while allowing for new config values.

```xon
server {
    host = example.com
    port = 8080
    [v5] {
        tls mode = strict
    }
}
```

When decoding for version 4, only `host` and `port` are accepted. When decoding
for version 5 or above, `tls mode` is also accepted. Unknown keys outside of
versioned blocks always result in an error when `DecodeVersion` is used:

```go
cfg := &Config{}
err := xon.DecodeVersion(data, cfg, 4)  // ignores [v5] block
err := xon.DecodeVersion(data, cfg, 5)  // includes [v5] block
```

Rules:

* Versioned blocks use the syntax `[v<N>]` where `<N>` is a non-negative integer
  up to 9,223,372,036,854,775,807 (max int64).

* Versioned blocks can appear anywhere a regular block can, i.e. at the top
  level and at any nested depth.

* Versioned blocks can contain key/value pairs and nested blocks that are merged
  with the contents of their parent block.

* Any keys that are duplicated inside a version block and its parent must result
  in an error.

* Only one versioned block number can be used within a config file at any given
  time. This is to ensure that applications update their config so that cruft
  doesn't accumulate.
