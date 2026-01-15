# alphafmt

`alphafmt` applies the standard Go formatting after putting declarations into
the following order, with alphabetic sorting within most sections:

- `package`
- `import`
- `const`
  - only standalone consts are sorted alphabetically
  - const blocks are left alone
- `var`
  - standalone vars are sorted alphabetically
  - block entries are sorted by name
  - blocks are sorted by their first variable
- `type`
  - methods for each type are sorted after each type
- `func`
- `func main`
- `func init`

Comments associated with declarations will be preserved when declarations are
re-ordered.

## Usage

`alphafmt [flags] [path ...]`

If no paths are provided, `alphafmt` reads from stdin and writes to stdout.

Flags:

- `-l` list files whose formatting differs

- `-w` write result to (source) file instead of stdout
