from pathlib import Path
import json
import re
import sys


def mask_source(source):
    out = list(source)
    i = 0
    state = "code"
    block_depth = 0
    while i < len(source):
        if state == "code":
            if source.startswith("//", i):
                out[i] = out[i + 1] = " "
                i += 2
                state = "line_comment"
            elif source.startswith("/*", i):
                out[i] = out[i + 1] = " "
                i += 2
                block_depth = 1
                state = "block_comment"
            elif source.startswith('"""', i):
                out[i] = out[i + 1] = out[i + 2] = " "
                i += 3
                state = "multistring"
            elif source[i] == '"':
                out[i] = " "
                i += 1
                state = "string"
            else:
                i += 1
        elif state == "line_comment":
            if source[i] == "\n":
                state = "code"
            else:
                out[i] = " "
            i += 1
        elif state == "block_comment":
            if source.startswith("/*", i):
                out[i] = out[i + 1] = " "
                i += 2
                block_depth += 1
            elif source.startswith("*/", i):
                out[i] = out[i + 1] = " "
                i += 2
                block_depth -= 1
                if block_depth == 0:
                    state = "code"
            else:
                if source[i] != "\n":
                    out[i] = " "
                i += 1
        elif state == "string":
            if source[i] == "\\":
                out[i] = " "
                if i + 1 < len(source) and source[i + 1] != "\n":
                    out[i + 1] = " "
                i += 2
            elif source[i] == '"':
                out[i] = " "
                i += 1
                state = "code"
            else:
                if source[i] != "\n":
                    out[i] = " "
                i += 1
        else:
            if source.startswith('"""', i):
                out[i] = out[i + 1] = out[i + 2] = " "
                i += 3
                state = "code"
            else:
                if source[i] != "\n":
                    out[i] = " "
                i += 1
    return "".join(out)


def matching(masked, start, opening, closing):
    depth = 0
    for i in range(start, len(masked)):
        if masked[i] == opening:
            depth += 1
        elif masked[i] == closing:
            depth -= 1
            if depth == 0:
                return i
    return None


def functions(path):
    source = path.read_text()
    masked = mask_source(source)
    found = []
    for match in re.finditer(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>]*>\s*)?\(", masked):
        close_paren = matching(masked, match.end() - 1, "(", ")")
        if close_paren is None:
            continue
        next_decl = re.search(r"\b(?:func|var|let|case|init|protocol|struct|class|enum|extension)\b", masked[close_paren + 1:])
        open_brace = masked.find("{", close_paren + 1)
        if open_brace < 0:
            continue
        if next_decl and close_paren + 1 + next_decl.start() < open_brace:
            continue
        close_brace = matching(masked, open_brace, "{", "}")
        if close_brace is None:
            continue
        start_line = masked.count("\n", 0, match.start()) + 1
        open_line = masked.count("\n", 0, open_brace) + 1
        close_line = masked.count("\n", 0, close_brace) + 1
        found.append({
            "path": str(path),
            "line": start_line,
            "endLine": close_line,
            "name": match.group(1),
            "bodyLines": max(close_line - open_line - 1, 0),
        })
    return found


def main():
    roots = [Path("App"), Path("Helper"), Path("Packages/ThermikCore/Sources"), Path("Packages/ThermikCore/Tests"), Path("scripts")]
    paths = sorted({path for root in roots for path in root.rglob("*.swift")})
    selected = set(sys.argv[1:])
    all_functions = [item for path in paths if not selected or str(path) in selected for item in functions(path)]
    violations = [item for item in all_functions if item["bodyLines"] > 10]
    output = Path("build/swift-function-inventory.json")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"functions": all_functions, "violations": violations}, indent=2) + "\n")
    for item in sorted(violations, key=lambda item: (item["path"], item["line"])):
        print(f'{item["path"]}:{item["line"]}:{item["name"]}:{item["bodyLines"]}')
    print(f"TOTAL files={len(paths)} functions={len(all_functions)} violations={len(violations)}", file=sys.stderr)


if __name__ == "__main__":
    main()
