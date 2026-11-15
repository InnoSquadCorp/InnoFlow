#!/usr/bin/env python3
"""Validate the reviewed API-breakage allowlist and render it for SwiftPM.

`swift package diagnose-api-breaking-changes` also reports declarations with
`package` access. Those cannot be used from another package, so changing them
is not a compatibility break for a consumer, but the digester cannot tell the
difference. This allowlist names such diagnostics one by one.

An entry is accepted only when the baseline source proves the point for the
declaration its message names. A message starts with the digester's
declaration kind and qualified name, such as `func Store.run(_:awaited:)`,
`var Runtime.executor`, `constructor Entry.init(key:)`, `class Runtime` or
`enumelement Effect.Operation.map`. The file the entry cites must contain, at
the baseline tag, a code line (not a comment or string literal) that starts
with the cited `package` declaration, and that declaration must be

- the named declaration itself: the same kind and name inside exactly the
  enclosing types the message names, and for a function, initializer or
  subscript the same argument labels; or
- a type on the named path: the named type itself, or a type enclosing the
  named declaration, again inside exactly the enclosing types the message
  names.

Enclosing types come from the braces of the baseline source. An extension
gives its members the type it extends, but `package extension T` itself is
never accepted for `T` or for its members. A `public` declaration, or another
`package` declaration of the cited file, can therefore never stand for a
listed diagnostic. The allowlist is bound to one baseline, so it has to be
reviewed again when the stable version moves.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

PREFIX = "API breakage: "
FIELDS = {"message", "source", "declaration", "reason"}

# Digester declaration kind -> (trailing path components that are not types,
# Swift keywords that declare the named declaration itself). Enum cases,
# associated types, deinitializers and accessors carry no access modifier of
# their own, so only a type enclosing them can be cited.
KINDS = {
    "struct": (0, {"struct"}),
    "class": (0, {"class", "actor"}),  # the digester reports an actor as a class
    "enum": (0, {"enum"}),
    "protocol": (0, {"protocol"}),
    "func": (1, {"func"}),
    "var": (1, {"var", "let"}),
    "constructor": (1, {"init"}),
    "subscript": (1, {"subscript"}),
    "typealias": (1, {"typealias"}),
    "enumelement": (1, set()),
    "associatedtype": (1, set()),
    "destructor": (1, set()),
    "accessor": (2, set()),
}
LABELLED = {"func", "constructor", "subscript"}
SUBJECT = re.compile(r"([a-z]+) ([^\s(]+)(?:\(((?:[^\s():]+:)*)\))?(?= |$)")
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
OPERATOR = re.compile(r"[/=\-+!*%<>&|^~?]+")

TYPE_KEYWORDS = {"struct", "class", "actor", "enum", "protocol"}
SCOPE_KEYWORDS = TYPE_KEYWORDS | {"extension"}
DECLARATION_KEYWORDS = SCOPE_KEYWORDS | {
    "func", "var", "let", "init", "subscript", "typealias", "case", "associatedtype",
    "deinit", "macro"}
MODIFIERS = {
    "package", "public", "open", "internal", "fileprivate", "private", "final", "static",
    "class", "override", "nonisolated", "indirect", "mutating", "nonmutating", "convenience",
    "required", "lazy", "weak", "unowned", "dynamic", "optional", "prefix", "postfix",
    "infix", "distributed", "consuming", "borrowing"}
NOT_A_TYPE_NAME = DECLARATION_KEYWORDS | MODIFIERS | {"in", "where"}
STRING_START = re.compile(r'(#*)("""|")')
WORD = re.compile(r"`[^`\n]+`|#?[A-Za-z_$][A-Za-z0-9_$]*|[0-9][A-Za-z0-9_]*")
OPERATOR_CHARACTERS = set("/=-+!*%<>&|^~?.")


class AllowlistError(Exception):
    pass


def baseline_source(root, baseline, source):
    if source.startswith("/") or ".." in Path(source).parts:
        raise AllowlistError(f"source must be a repository-relative path: {source}")
    result = subprocess.run(
        ["git", "-C", str(root), "show", f"refs/tags/{baseline}:{source}"],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise AllowlistError(f"{source} does not exist at baseline {baseline}")
    return result.stdout


def named_declaration(message):
    """Return (kind, path, labels) of the declaration a digester message names.

    `labels` lists the argument labels of a function, initializer or
    subscript (`_` for an unlabeled argument) and is None for other kinds.
    """
    match = SUBJECT.match(message[len(PREFIX):])
    if match is None or match.group(1) not in KINDS:
        return None
    kind, path = match.group(1), match.group(2).split(".")
    if len(path) < KINDS[kind][0] or not all(NAME.fullmatch(name) for name in path[:-1]):
        return None
    if not (NAME.fullmatch(path[-1]) or (kind == "func" and OPERATOR.fullmatch(path[-1]))):
        return None
    if kind not in LABELLED:
        return kind, path, None
    if match.group(3) is None:
        return None
    return kind, path, match.group(3).split(":")[:-1]


def swift_tokens(text):
    """Split Swift source into (line, token) pairs outside comments and literal text.

    A string literal becomes one '""' token while the code of its
    interpolations stays, so a brace in a comment or string never counts.
    """
    tokens = []
    line, index = 1, 0
    # The innermost lexical context is last: ["code", open parentheses] for
    # the file or an interpolation, ["string", terminator, escape] for a literal.
    contexts = [["code", 0]]
    while index < len(text):
        context, character = contexts[-1], text[index]
        if context[0] == "string":
            _, terminator, escape = context
            if text.startswith(terminator, index):
                contexts.pop()
                index += len(terminator)
            elif text.startswith(escape, index):
                index += len(escape)
                if text.startswith("(", index):
                    contexts.append(["code", 1])
                elif text.startswith("\n", index):
                    line += 1
                index += 1
            else:
                if character == "\n":
                    if not terminator.startswith('"""'):
                        raise ValueError(f"line {line}: unterminated string literal")
                    line += 1
                index += 1
            continue
        literal = STRING_START.match(text, index)
        if character == "\n":
            line += 1
            index += 1
        elif character.isspace():
            index += 1
        elif text.startswith("//", index):
            end = text.find("\n", index)
            index = len(text) if end < 0 else end
        elif text.startswith("/*", index):
            depth = 0
            while True:
                if index >= len(text):
                    raise ValueError("unterminated block comment")
                if text.startswith("/*", index):
                    depth, index = depth + 1, index + 2
                elif text.startswith("*/", index):
                    depth, index = depth - 1, index + 2
                    if depth == 0:
                        break
                else:
                    if text[index] == "\n":
                        line += 1
                    index += 1
        elif literal:
            tokens.append((line, '""'))
            hashes, quotes = literal.groups()
            contexts.append(["string", quotes + hashes, "\\" + hashes])
            index = literal.end()
        elif len(contexts) > 1 and character == ")" and context[1] == 1:
            contexts.pop()  # the end of an interpolation
            index += 1
        else:
            if len(contexts) > 1 and character in "()":
                context[1] += 1 if character == "(" else -1
            word = WORD.match(text, index)
            end = word.end() if word else index + 1
            if not word and character in OPERATOR_CHARACTERS:
                while end < len(text) and text[end] in OPERATOR_CHARACTERS \
                        and not text.startswith(("//", "/*"), end):
                    end += 1
            tokens.append((line, text[index:end]))
            index = end
    if len(contexts) > 1:
        raise ValueError("unterminated string literal")
    return tokens


def scope_name(header):
    """The type a brace opens: the last `struct/class/actor/enum/protocol/extension T`."""
    for index in range(len(header) - 2, -1, -1):
        name = header[index + 1]
        if header[index] in SCOPE_KEYWORDS and name not in NOT_A_TYPE_NAME \
                and NAME.fullmatch(name.strip("`")):
            names = [name.strip("`")]
            index += 2
            while index + 1 < len(header) and header[index] == "." \
                    and NAME.fullmatch(header[index + 1].strip("`")):
                names.append(header[index + 1].strip("`"))
                index += 2
            return names
    return None


class BaselineStructure:
    """Code tokens of a baseline file with the types that enclose each of them."""

    def __init__(self, text, where):
        try:
            self.tokens = swift_tokens(text)
            # One path per token; None inside a body that is not a type.
            self.enclosing = []
            paths, header = [()], []
            for _, token in self.tokens:
                self.enclosing.append(paths[-1])
                if token == "{":
                    name = scope_name(header)
                    paths.append(None if paths[-1] is None or name is None
                                 else paths[-1] + tuple(name))
                    header = []
                elif token == "}":
                    if len(paths) == 1:
                        raise ValueError("unbalanced braces")
                    paths.pop()
                    header = []
                elif token == ";":
                    header = []
                else:
                    header.append(token)
            if len(paths) != 1:
                raise ValueError("unbalanced braces")
        except ValueError as error:
            raise AllowlistError(f"{where} cannot be read as Swift: {error}")
        self.first_token = {}
        for index, (line, _) in enumerate(self.tokens):
            self.first_token.setdefault(line, index)

    def text(self, index):
        return self.tokens[index][1] if index < len(self.tokens) else ""

    def declaration(self, line):
        """(keyword, qualified name, index after the name) declared by a code line."""
        index = self.first_token.get(line)
        if index is None or self.text(index) != "package" or self.enclosing[index] is None:
            return None
        enclosing = self.enclosing[index]
        while True:
            token = self.text(index)
            if token == "class" and self.text(index + 1) in MODIFIERS | DECLARATION_KEYWORDS:
                index += 1  # `class func`, `class var`
            elif token in MODIFIERS - {"class"}:
                index += 1
                if self.text(index) == "(" and self.text(index + 2) == ")":
                    index += 3  # `private(set)`, `nonisolated(unsafe)`
            else:
                break
        keyword = self.text(index)
        if keyword in ("init", "subscript", "deinit"):
            return keyword, enclosing + (keyword,), index + 1
        name = self.text(index + 1).strip("`")
        if keyword in DECLARATION_KEYWORDS and (
                NAME.fullmatch(name) or (keyword == "func" and OPERATOR.fullmatch(name))):
            return keyword, enclosing + (name,), index + 2
        return None

    def argument_labels(self, keyword, declared_name, index):
        """The argument labels of the parameter clause that follows a declared name."""
        if keyword == "init" and self.text(index) in ("?", "!"):
            index += 1
        if self.text(index).startswith("<"):  # a generic parameter clause
            depth = 0
            while index < len(self.tokens):
                token = self.text(index)
                if set(token) <= set("<>"):
                    depth += token.count("<") - token.count(">")
                index += 1
                if depth <= 0:
                    break
        if self.text(index) != "(":
            return None
        labels, segment, depth = [], [], 0
        for position in range(index + 1, len(self.tokens)):
            token = self.text(position)
            if depth == 0 and token in (",", ")"):
                # A segment without a colon continues a generic argument list.
                if ":" in segment:
                    names = [part.strip("`") for at, part in enumerate(segment[:segment.index(":")])
                             if part != "@" and (at == 0 or segment[at - 1] != "@")]
                    if not 1 <= len(names) <= 2 or not all(NAME.fullmatch(part) for part in names):
                        return None
                    # An operator argument never has a label, and a subscript
                    # argument has one only when it is spelled twice.
                    unlabeled = OPERATOR.fullmatch(declared_name) or (
                        keyword == "subscript" and len(names) == 1)
                    labels.append("_" if unlabeled else names[0])
                if token == ")":
                    return labels
                segment = []
            elif token in ("(", "[", "{"):
                depth += 1
            elif token in (")", "]", "}"):
                depth -= 1
            elif depth == 0:
                segment.append(token)
        return None

    def binds(self, named, line):
        """Whether the declaration on `line` is the named one or a type on its path."""
        declaration = self.declaration(line)
        if declaration is None:
            return False
        kind, path, labels = named
        keyword, declared, after = declaration
        trailing, own_keywords = KINDS[kind]
        path = tuple(path)
        if keyword in TYPE_KEYWORDS:
            if declared != path[:len(declared)] or len(declared) > len(path) - trailing:
                return False
            return declared != path or keyword in own_keywords
        if keyword not in own_keywords or declared != path:
            return False
        return kind not in LABELLED or self.argument_labels(keyword, declared[-1], after) == labels


def subject(named):
    kind, path, labels = named
    arguments = "" if labels is None else "(" + "".join(f"{label}:" for label in labels) + ")"
    return f"{kind} {'.'.join(path)}{arguments}"


def validate(root, allowlist_path, baseline):
    try:
        document = json.loads(Path(allowlist_path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise AllowlistError(f"cannot read {allowlist_path}: {error}")
    if not isinstance(document, dict) or set(document) != {"schema", "baseline", "entries"}:
        raise AllowlistError("allowlist must contain exactly schema, baseline and entries")
    if document["schema"] != 1:
        raise AllowlistError("unsupported allowlist schema")
    if document["baseline"] != baseline:
        raise AllowlistError(
            f"allowlist was reviewed against {document['baseline']}, not {baseline}; "
            "review every entry again for the new baseline")
    entries = document["entries"]
    if not isinstance(entries, list):
        raise AllowlistError("entries must be a list")

    messages = []
    sources = {}
    structures = {}
    for index, entry in enumerate(entries):
        where = f"entries[{index}]"
        if not isinstance(entry, dict) or set(entry) != FIELDS:
            raise AllowlistError(f"{where} must contain exactly {sorted(FIELDS)}")
        if not all(isinstance(entry[field], str) and entry[field].strip() for field in FIELDS):
            raise AllowlistError(f"{where} has an empty field")
        message, declaration = entry["message"], entry["declaration"].strip()
        if not message.startswith(PREFIX) or "\n" in message:
            raise AllowlistError(f"{where}.message must be one line starting with {PREFIX!r}")
        if message in messages:
            raise AllowlistError(f"{where}.message is listed twice")
        named = named_declaration(message)
        if named is None:
            raise AllowlistError(
                f"{where}.message must name a declaration as `<kind> <qualified name>` "
                f"with a digester kind ({', '.join(KINDS)})")
        if not declaration.startswith("package "):
            raise AllowlistError(
                f"{where}.declaration must be a package-access declaration: {declaration}")
        source = entry["source"]
        if source not in sources:
            sources[source] = baseline_source(root, baseline, source)
        # Lines are numbered as the tokenizer numbers them: by "\n" alone.
        lines = [number for number, line in enumerate(sources[source].split("\n"), 1)
                 if line.strip().startswith(declaration)]
        if not lines:
            raise AllowlistError(
                f"{where}: {source} at {baseline} has no line starting with {declaration!r}")
        if source not in structures:
            structures[source] = BaselineStructure(sources[source], f"{source} at {baseline}")
        if not any(structures[source].binds(named, line) for line in lines):
            raise AllowlistError(
                f"{where}: {declaration!r} in {source} at {baseline} declares neither "
                f"{subject(named)} nor a type enclosing it")
        messages.append(message)
    return messages


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--allowlist", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--output", required=True)
    arguments = parser.parse_args()
    try:
        messages = validate(Path(arguments.root), arguments.allowlist, arguments.baseline)
    except AllowlistError as error:
        print(f"[api-breakage-allowlist] {error}", file=sys.stderr)
        return 2
    Path(arguments.output).write_text("".join(f"{message}\n" for message in messages),
                                      encoding="utf-8")
    print(f"[api-breakage-allowlist] {len(messages)} reviewed package-access diagnostic(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
