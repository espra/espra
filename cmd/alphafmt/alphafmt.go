// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

// Command alphafmt implements gofmt with section sorting.
package main

import (
	"bytes"
	"flag"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/printer"
	"go/token"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"

	"espra.dev/pkg/obs"
	"espra.dev/pkg/process"
)

type declItem struct {
	name string
	decl ast.Decl
}

func appendDeclItems(blocks []ast.Decl, singles []declItem) []ast.Decl {
	decls := slices.Clone(blocks)
	for _, item := range singles {
		decls = append(decls, item.decl)
	}
	return decls
}

func buildImportSection(fset *token.FileSet, importDecls []ast.Decl) string {
	if len(importDecls) == 0 {
		return ""
	}

	var docGroups []*ast.CommentGroup
	var stdSpecs []*ast.ImportSpec
	var otherSpecs []*ast.ImportSpec
	for _, decl := range importDecls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.IMPORT {
			continue
		}
		if gen.Doc != nil {
			docGroups = append(docGroups, gen.Doc)
		}
		for _, spec := range gen.Specs {
			importSpec, ok := spec.(*ast.ImportSpec)
			if !ok {
				continue
			}
			path := importPath(importSpec)
			if isStdImport(path) {
				stdSpecs = append(stdSpecs, importSpec)
			} else {
				otherSpecs = append(otherSpecs, importSpec)
			}
		}
	}

	sortImportSpecs(stdSpecs)
	sortImportSpecs(otherSpecs)

	buf := &bytes.Buffer{}
	for _, group := range docGroups {
		for _, line := range group.List {
			buf.WriteString(line.Text)
			buf.WriteByte('\n')
		}
	}
	buf.WriteString("import (\n")
	writeImportSpecs(buf, fset, stdSpecs)
	if len(stdSpecs) > 0 && len(otherSpecs) > 0 {
		buf.WriteByte('\n')
	}
	writeImportSpecs(buf, fset, otherSpecs)
	buf.WriteString(")\n")
	return strings.TrimRight(buf.String(), "\n")
}

func buildTypeSection(fset *token.FileSet, comments []*ast.CommentGroup, typeDecls []declItem, methods map[string][]*ast.FuncDecl) string {
	if len(typeDecls) == 0 && len(methods) == 0 {
		return ""
	}

	parts := []string{}
	seen := map[string]struct{}{}
	for _, item := range typeDecls {
		seen[item.name] = struct{}{}
		typeString := formatDecl(fset, comments, item.decl)
		parts = append(parts, typeString)
		if typeMethods := methods[item.name]; len(typeMethods) > 0 {
			for _, method := range typeMethods {
				methodString := formatDecl(fset, comments, method)
				parts = append(parts, methodString)
			}
		}
	}

	remaining := []string{}
	for name := range methods {
		if _, ok := seen[name]; ok {
			continue
		}
		remaining = append(remaining, name)
	}

	sort.Strings(remaining)
	for _, name := range remaining {
		for _, method := range methods[name] {
			methodString := formatDecl(fset, comments, method)
			parts = append(parts, methodString)
		}
	}
	return strings.Join(parts, "\n\n")
}

func collectDeclStrings(fset *token.FileSet, comments []*ast.CommentGroup, decls []ast.Decl) string {
	if len(decls) == 0 {
		return ""
	}
	parts := []string{}
	for _, decl := range decls {
		part := formatDecl(fset, comments, decl)
		parts = append(parts, part)
	}
	return strings.Join(parts, "\n\n")
}

func collectDocComments(node ast.Node, out map[*ast.CommentGroup]struct{}) {
	ast.Inspect(node, func(n ast.Node) bool {
		switch typed := n.(type) {
		case *ast.Field:
			if typed.Doc != nil {
				out[typed.Doc] = struct{}{}
			}
		case *ast.FuncDecl:
			if typed.Doc != nil {
				out[typed.Doc] = struct{}{}
			}
		case *ast.GenDecl:
			if typed.Doc != nil {
				out[typed.Doc] = struct{}{}
			}
		case *ast.ImportSpec:
			if typed.Doc != nil {
				out[typed.Doc] = struct{}{}
			}
		case *ast.TypeSpec:
			if typed.Doc != nil {
				out[typed.Doc] = struct{}{}
			}
		case *ast.ValueSpec:
			if typed.Doc != nil {
				out[typed.Doc] = struct{}{}
			}
		}
		return true
	})
}

func collectFuncStrings(fset *token.FileSet, comments []*ast.CommentGroup, funcs []*ast.FuncDecl) string {
	if len(funcs) == 0 {
		return ""
	}
	parts := []string{}
	for _, decl := range funcs {
		part := formatDecl(fset, comments, decl)
		parts = append(parts, part)
	}
	return strings.Join(parts, "\n\n")
}

func collectGoFiles(paths []string) []string {
	var files []string

	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil {
			obs.Fatalf("Failed to stat %q: %v", p, err)
		}
		if !info.IsDir() {
			if filepath.Ext(p) != ".go" {
				obs.Fatalf("File at path %q does not end in .go", p)
			}
			files = append(files, p)
			continue
		}
		err = filepath.WalkDir(p, func(path string, d fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if d.IsDir() {
				name := d.Name()
				if strings.HasPrefix(name, ".") || name == "vendor" || name == "testdata" {
					return filepath.SkipDir
				}
				return nil
			}
			if filepath.Ext(path) == ".go" {
				files = append(files, path)
			}
			return nil
		})
		if err != nil {
			obs.Fatalf("Failed to walk directory %q: %v", p, err)
		}
	}
	sort.Strings(files)
	return files
}

func commentsForDecl(comments []*ast.CommentGroup, decl ast.Decl) []*ast.CommentGroup {
	start, end := declRange(decl)
	if start == token.NoPos || end == token.NoPos {
		return nil
	}

	docComments := map[*ast.CommentGroup]struct{}{}
	collectDocComments(decl, docComments)

	var filtered []*ast.CommentGroup
	for _, comment := range comments {
		if comment.Pos() < start || comment.End() > end {
			continue
		}
		if _, ok := docComments[comment]; ok {
			continue
		}
		filtered = append(filtered, comment)
	}
	return filtered
}

func declRange(decl ast.Decl) (token.Pos, token.Pos) {
	switch node := decl.(type) {
	case *ast.GenDecl:
		if len(node.Specs) == 1 {
			spec := node.Specs[0]
			return spec.Pos(), spec.End()
		}
	}
	return decl.Pos(), decl.End()
}

func firstDeclName(decl ast.Decl) string {
	gen, ok := decl.(*ast.GenDecl)
	if !ok || len(gen.Specs) == 0 {
		return ""
	}

	return specFirstName(gen.Specs[0])
}

func formatDecl(fset *token.FileSet, comments []*ast.CommentGroup, decl ast.Decl) string {
	buf := &bytes.Buffer{}
	cfg := &printer.Config{
		Mode:     printer.TabIndent | printer.UseSpaces,
		Tabwidth: 8,
	}
	var docComment *ast.CommentGroup
	if gen, ok := decl.(*ast.GenDecl); ok && gen.Doc != nil {
		docComment = gen.Doc
		gen.Doc = nil
	}
	node := &printer.CommentedNode{
		Comments: commentsForDecl(comments, decl),
		Node:     decl,
	}
	if docComment != nil {
		for _, line := range docComment.List {
			buf.WriteString(line.Text)
			buf.WriteByte('\n')
		}
	}
	if err := cfg.Fprint(buf, fset, node); err != nil {
		obs.Fatalf("Failed to format declaration: %v", err)
	}
	return strings.TrimRight(buf.String(), "\n")
}

func formatFile(path string) (bool, []byte) {
	src, err := os.ReadFile(path)
	if err != nil {
		obs.Fatalf("Failed to read file %q: %v", path, err)
	}
	formatted := formatSource(path, src)
	return !bytes.Equal(src, formatted), formatted
}

func formatImportSpec(fset *token.FileSet, spec *ast.ImportSpec) string {
	if spec == nil {
		return ""
	}
	buf := &bytes.Buffer{}
	cfg := &printer.Config{
		Mode:     printer.TabIndent | printer.UseSpaces,
		Tabwidth: 8,
	}
	if err := cfg.Fprint(buf, fset, spec); err != nil {
		obs.Fatalf("Failed to format import spec: %v", err)
	}
	return strings.TrimRight(buf.String(), "\n")
}

func formatSource(filename string, src []byte) []byte {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filename, src, parser.ParseComments)
	if err != nil {
		obs.Fatalf("Failed to parse file %q: %v", filename, err)
	}
	ordered := orderFileDecls(fset, file)
	formatted, err := format.Source(ordered)
	if err != nil {
		obs.Fatalf("Failed to format file %q: %v", filename, err)
	}
	return formatted
}

func formatStdin() {
	src, err := io.ReadAll(os.Stdin)
	if err != nil {
		obs.Fatalf("Failed to read from stdin: %v", err)
	}
	formatted := formatSource("stdin", src)
	if _, err = os.Stdout.Write(formatted); err != nil {
		obs.Fatalf("Failed to write to stdout: %v", err)
	}
}

func importPath(spec *ast.ImportSpec) string {
	if spec == nil || spec.Path == nil {
		return ""
	}
	path, err := strconv.Unquote(spec.Path.Value)
	if err != nil {
		return strings.Trim(spec.Path.Value, "\"")
	}
	return path
}

func isStdImport(path string) bool {
	if path == "" {
		return true
	}
	if strings.HasPrefix(path, ".") {
		return false
	}
	first, _, _ := strings.Cut(path, "/")
	return !strings.Contains(first, ".")
}

func orderFileDecls(fset *token.FileSet, file *ast.File) []byte {
	var constBlocks []ast.Decl
	var constSingles []declItem
	var funcs []*ast.FuncDecl
	var importDecls []ast.Decl
	var initFuncs []*ast.FuncDecl
	var mainFuncs []*ast.FuncDecl
	var typeDecls []declItem
	var varBlocks []ast.Decl
	var varSingles []declItem

	methods := map[string][]*ast.FuncDecl{}
	for _, decl := range file.Decls {
		switch node := decl.(type) {
		case *ast.GenDecl:
			switch node.Tok {
			case token.IMPORT:
				importDecls = append(importDecls, node)
			case token.CONST:
				block, singles := splitValueDecls(node)
				if block != nil {
					constBlocks = append(constBlocks, block)
					continue
				}
				constSingles = append(constSingles, singles...)
			case token.VAR:
				block, singles := splitValueDecls(node)
				if block != nil {
					sortVarBlockSpecs(block)
					varBlocks = append(varBlocks, block)
					continue
				}
				varSingles = append(varSingles, singles...)
			case token.TYPE:
				items := splitTypeDecls(node)
				typeDecls = append(typeDecls, items...)
			}
		case *ast.FuncDecl:
			if node.Recv != nil {
				recvName := receiverTypeName(node.Recv)
				if recvName == "" {
					funcs = append(funcs, node)
					continue
				}
				methods[recvName] = append(methods[recvName], node)
				continue
			}
			switch node.Name.Name {
			case "main":
				mainFuncs = append(mainFuncs, node)
			case "init":
				initFuncs = append(initFuncs, node)
			default:
				funcs = append(funcs, node)
			}
		}
	}

	sort.SliceStable(constSingles, func(i, j int) bool {
		return constSingles[i].name < constSingles[j].name
	})
	sort.SliceStable(varSingles, func(i, j int) bool {
		return varSingles[i].name < varSingles[j].name
	})
	sort.SliceStable(varBlocks, func(i, j int) bool {
		return firstDeclName(varBlocks[i]) < firstDeclName(varBlocks[j])
	})
	sort.SliceStable(typeDecls, func(i, j int) bool {
		return typeDecls[i].name < typeDecls[j].name
	})
	sort.SliceStable(funcs, func(i, j int) bool {
		return funcs[i].Name.Name < funcs[j].Name.Name
	})

	for recv := range methods {
		sort.SliceStable(methods[recv], func(i, j int) bool {
			return methods[recv][i].Name.Name < methods[recv][j].Name.Name
		})
	}

	buf := &bytes.Buffer{}
	writeLeadingComments(buf, fset, file)
	buf.WriteString("package ")
	buf.WriteString(file.Name.Name)
	buf.WriteByte('\n')

	wrote := false
	appendSection := func(section string) {
		if section == "" {
			return
		}
		if !wrote {
			buf.WriteByte('\n')
			wrote = true
		} else {
			buf.WriteString("\n\n")
		}
		buf.WriteString(section)
	}

	section := buildImportSection(fset, importDecls)
	appendSection(section)

	section = collectDeclStrings(fset, file.Comments, appendDeclItems(constBlocks, constSingles))
	appendSection(section)

	section = collectDeclStrings(fset, file.Comments, appendDeclItems(varBlocks, varSingles))
	appendSection(section)

	typeSection := buildTypeSection(fset, file.Comments, typeDecls, methods)
	appendSection(typeSection)

	section = collectFuncStrings(fset, file.Comments, funcs)
	appendSection(section)

	section = collectFuncStrings(fset, file.Comments, mainFuncs)
	appendSection(section)

	section = collectFuncStrings(fset, file.Comments, initFuncs)
	appendSection(section)
	return buf.Bytes()
}

func receiverTypeName(fieldList *ast.FieldList) string {
	if fieldList == nil || len(fieldList.List) == 0 {
		return ""
	}
	return typeName(fieldList.List[0].Type)
}

func sortImportSpecs(specs []*ast.ImportSpec) {
	sort.SliceStable(specs, func(i, j int) bool {
		return importPath(specs[i]) < importPath(specs[j])
	})
}

func sortVarBlockSpecs(decl ast.Decl) {
	gen, ok := decl.(*ast.GenDecl)
	if !ok || gen.Tok != token.VAR || len(gen.Specs) == 0 {
		return
	}
	sort.SliceStable(gen.Specs, func(i, j int) bool {
		return specFirstName(gen.Specs[i]) < specFirstName(gen.Specs[j])
	})
}

func specFirstName(spec ast.Spec) string {
	switch typed := spec.(type) {
	case *ast.ValueSpec:
		if len(typed.Names) == 0 {
			return ""
		}
		return typed.Names[0].Name
	case *ast.TypeSpec:
		if typed.Name == nil {
			return ""
		}
		return typed.Name.Name
	default:
		return ""
	}
}

func splitTypeDecls(decl *ast.GenDecl) []declItem {
	var items []declItem
	for i, spec := range decl.Specs {
		typeSpec, ok := spec.(*ast.TypeSpec)
		if !ok {
			continue
		}
		newTypeSpec := &ast.TypeSpec{
			Assign:     typeSpec.Assign,
			Comment:    typeSpec.Comment,
			Name:       typeSpec.Name,
			Type:       typeSpec.Type,
			TypeParams: typeSpec.TypeParams,
		}
		newDecl := &ast.GenDecl{
			Specs: []ast.Spec{newTypeSpec},
			Tok:   token.TYPE,
		}
		if typeSpec.Doc != nil {
			newDecl.Doc = typeSpec.Doc
		} else if i == 0 && decl.Doc != nil {
			newDecl.Doc = decl.Doc
		}
		items = append(items, declItem{
			name: typeSpec.Name.Name,
			decl: newDecl,
		})
	}
	return items
}

func splitValueDecls(decl *ast.GenDecl) (ast.Decl, []declItem) {
	if decl.Lparen != token.NoPos {
		return decl, nil
	}

	var singles []declItem
	for i, spec := range decl.Specs {
		valueSpec, ok := spec.(*ast.ValueSpec)
		if !ok || len(valueSpec.Names) == 0 {
			continue
		}
		newValueSpec := &ast.ValueSpec{
			Comment: valueSpec.Comment,
			Names:   valueSpec.Names,
			Type:    valueSpec.Type,
			Values:  valueSpec.Values,
		}
		newDecl := &ast.GenDecl{
			Specs: []ast.Spec{newValueSpec},
			Tok:   decl.Tok,
		}
		if valueSpec.Doc != nil {
			newDecl.Doc = valueSpec.Doc
		} else if i == 0 && decl.Doc != nil {
			newDecl.Doc = decl.Doc
		}
		singles = append(singles, declItem{
			name: valueSpec.Names[0].Name,
			decl: newDecl,
		})
	}
	return nil, singles
}

func typeName(expr ast.Expr) string {
	switch node := expr.(type) {
	case *ast.Ident:
		return node.Name
	case *ast.StarExpr:
		return typeName(node.X)
	case *ast.IndexExpr:
		return typeName(node.X)
	case *ast.IndexListExpr:
		return typeName(node.X)
	case *ast.SelectorExpr:
		return node.Sel.Name
	default:
		return ""
	}
}

func writeImportSpecs(buf *bytes.Buffer, fset *token.FileSet, specs []*ast.ImportSpec) {
	for _, spec := range specs {
		formatted := formatImportSpec(fset, spec)
		if formatted == "" {
			continue
		}
		lines := strings.Split(formatted, "\n")
		for _, line := range lines {
			if line != "" {
				buf.WriteByte('\t')
				buf.WriteString(line)
			}
			buf.WriteByte('\n')
		}
	}
}

func writeLeadingComments(buf *bytes.Buffer, fset *token.FileSet, file *ast.File) {
	var leading []*ast.CommentGroup
	for _, comment := range file.Comments {
		if comment.End() >= file.Name.Pos() {
			break
		}
		leading = append(leading, comment)
	}
	for i, comment := range leading {
		for _, line := range comment.List {
			buf.WriteString(line.Text)
			buf.WriteByte('\n')
		}
		nextLine := fset.Position(file.Name.Pos()).Line
		if i+1 < len(leading) {
			nextLine = fset.Position(leading[i+1].Pos()).Line
		}
		endLine := fset.Position(comment.End()).Line
		if nextLine > endLine+1 {
			buf.WriteByte('\n')
		}
	}
}

func main() {
	flag.CommandLine = flag.NewFlagSet("alphafmt", flag.ExitOnError)
	flag.CommandLine.SetOutput(os.Stdout)
	flag.Usage = func() {
		fmt.Println("Usage: alphafmt [flags] [path ...]")
		flag.PrintDefaults()
	}

	list := flag.Bool("l", false, "list files whose formatting differs")
	write := flag.Bool("w", false, "write result to (source) file instead of stdout")
	flag.Parse()

	stat, err := os.Stdin.Stat()
	if err != nil {
		obs.Fatalf("Failed to stat stdin: %v", err)
	}

	paths := flag.Args()
	if (stat.Mode() & os.ModeCharDevice) == 0 {
		if len(paths) > 0 {
			obs.Fatalf("Cannot specify paths when piping via stdin")
		}
		if *list {
			obs.Fatalf("Cannot use -l when piping via stdin")
		}
		if *write {
			obs.Fatalf("Cannot use -w when piping via stdin")
		}
		formatStdin()
		return
	}

	if len(paths) == 0 {
		flag.Usage()
		process.Exit(0)
	}

	files := collectGoFiles(paths)
	for _, path := range files {
		changed, out := formatFile(path)
		if *list && changed {
			fmt.Println(path)
		}
		if *write && changed {
			if err := os.WriteFile(path, out, 0o644); err != nil {
				obs.Fatalf("Failed to write output to %q: %v", path, err)
			}
		} else if !*list {
			if _, err := os.Stdout.Write(out); err != nil {
				obs.Fatalf("Failed to write to stdout: %v", err)
			}
		}
	}
}
