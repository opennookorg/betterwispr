#!/usr/bin/env python3
"""Validate native localizations, prepare an inactive translation, or package an app.

Uses Python's standard library and macOS plutil for native .strings parsing.
The source .lproj directories are the language declaration; there is no registry.
"""

import argparse
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


CORE = Path("Sources/BetterWisprCore/Localization/Resources")
PERMISSIONS = Path("Resources")
CORE_BUNDLE = "BetterWispr_BetterWisprCore.bundle"
LANGUAGE = re.compile(r"[a-z]{2,3}(?:-[A-Z][a-z]{3})?(?:-(?:[A-Z]{2}|[0-9]{3}))?")
FORMAT = re.compile(
    r"%(?:(?P<position>[1-9][0-9]*)\$)?(?:(?P<plural>\#@\w+@)|[-+ #0']*"
    r"(?:[0-9]+|\*(?:[1-9][0-9]*\$)?)?(?:\.(?:[0-9]+|\*(?:[1-9][0-9]*\$)?))?"
    r"(?P<type>(?:hh|ll|[hlqjztL])?[@dDiuUoOxXfFeEgGaAcCsSpn]))"
)
PLURAL_CATEGORIES = {"zero", "one", "two", "few", "many", "other"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def no_symlinks(path, recursive=True):
    """Do not read or modify through a linked source or output component."""
    path = path.absolute()
    require(not any(part.is_symlink() for part in (path, *path.parents)),
            f"Symlinks are not supported: {path}")
    if recursive and path.is_dir():
        require(not any(child.is_symlink() for child in path.rglob("*")),
                f"Symlinks are not supported inside {path}")


def language_code(value):
    require(LANGUAGE.fullmatch(value) is not None,
            f"Invalid language code {value!r}; use a native code such as de, pt-BR or zh-Hant")
    return value


def languages(directory):
    no_symlinks(directory)
    require(directory.is_dir(), f"Missing localization directory: {directory}")
    result = []
    for folder in sorted(directory.glob("*.lproj")):
        require(folder.is_dir(), f"Expected a localization directory: {folder}")
        if folder.stem == "Base":
            continue
        result.append(language_code(folder.stem))
    return sorted(result, key=lambda code: (code != "en", code))


def load_plist(path):
    require(path.is_file(), f"Missing localization file: {path}")
    no_symlinks(path)
    result = subprocess.run(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", str(path)],
                            capture_output=True)
    require(result.returncode == 0,
            f"Invalid property list {path}: {result.stderr.decode(errors='replace').strip()}")
    value = plistlib.loads(result.stdout)
    require(isinstance(value, dict), f"Expected a dictionary in {path}")
    return value


def formats(text, context, variables=None):
    """Compare argument positions and native types, allowing translated reordering."""
    require(isinstance(text, str), f"Expected a string: {context}")
    require(text.strip(), f"Empty localized string: {context}")
    result = {}
    next_position = 1
    for match in FORMAT.finditer(text.replace("%%", "")):
        # Width/precision stars consume integer arguments before the value.
        for star in re.finditer(r"\*(?:([1-9][0-9]*)\$)?", match.group()):
            index = int(star[1]) if star[1] else next_position
            if not star[1]:
                next_position += 1
            require(index not in result or result[index] == "d", f"Conflicting formats: {context}")
            result[index] = "d"
        position = int(match["position"]) if match["position"] else next_position
        if not match["position"]:
            next_position += 1
        kind = match["type"]
        if match["plural"]:
            name = match["plural"][2:-1]
            require(variables is not None and name in variables,
                    f"Unknown plural variable {name!r}: {context}")
            kind = variables[name]
        require(position not in result or result[position] == kind, f"Conflicting formats: {context}")
        result[position] = kind
    return result


def plural_formats(entry, context):
    require(isinstance(entry, dict) and "NSStringLocalizedFormatKey" in entry,
            f"Missing NSStringLocalizedFormatKey: {context}")
    variables = {}
    for name, rule in entry.items():
        if name == "NSStringLocalizedFormatKey":
            continue
        require(isinstance(rule, dict), f"Invalid plural variable {name!r}: {context}")
        kind = rule.get("NSStringFormatValueTypeKey")
        require(rule.get("NSStringFormatSpecTypeKey") == "NSStringPluralRuleType"
                and isinstance(kind, str) and re.fullmatch(r"(?:hh|ll|[hlqjzt])?[diuoxX]", kind),
                f"Invalid plural value type: {context}/{name}")
        categories = set(rule) - {"NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey"}
        require("other" in categories and categories <= PLURAL_CATEGORIES,
                f"Plural rules need an 'other' branch and native categories: {context}/{name}")
        for category in categories:
            arguments = formats(rule[category], f"{context}/{name}/{category}")
            # Native plural branches may spell out/omit the count (e.g. 'one minute').
            require(not arguments or arguments == {1: kind},
                    f"Plural branch format mismatch: {context}/{name}/{category}")
        variables[name] = kind
    signature = formats(entry["NSStringLocalizedFormatKey"], context, variables)
    referenced = set(re.findall(r"%[1-9][0-9]*\$#@(\w+)@|%#@(\w+)@", entry["NSStringLocalizedFormatKey"]))
    require({name for pair in referenced for name in pair if name} == set(variables),
            f"Unused or missing plural variable: {context}")
    return signature, variables


def compare_tables(english, translated, context, plural=False):
    require(set(english) == set(translated),
            f"Key coverage mismatch in {context}; missing={sorted(set(english) - set(translated))}, "
            f"extra={sorted(set(translated) - set(english))}")
    for key, value in english.items():
        label = f"{context}: {key}"
        expected = plural_formats(value, label) if plural else formats(value, label)
        actual = plural_formats(translated[key], label) if plural else formats(translated[key], label)
        require(actual == expected, f"Format argument mismatch in {label}")


def check(root):
    core_languages = languages(root / CORE)
    permission_languages = languages(root / PERMISSIONS)
    require("en" in core_languages, "English en.lproj is required in Core resources")
    require(core_languages == permission_languages,
            f"Localization folders disagree: Core={core_languages}, permissions={permission_languages}. "
            "Each enabled language needs both native .lproj directories.")
    info = load_plist(root / PERMISSIONS / "Info.plist")
    require(info.get("CFBundleDevelopmentRegion") == "en", "CFBundleDevelopmentRegion must remain en")
    permissions = {key: value for key, value in info.items() if key.endswith("UsageDescription")}
    require(permissions and all(isinstance(value, str) and value.strip() for value in permissions.values()),
            "Info.plist must contain nonempty English permission descriptions")
    english = root / CORE / "en.lproj"
    tables = {path.name: load_plist(path) for path in english.iterdir()
              if path.suffix in {".strings", ".stringsdict"}}
    require("Localizable.strings" in tables, f"Missing Localizable.strings in {english}")
    for code in core_languages:
        directory = root / CORE / f"{code}.lproj"
        names = {path.name for path in directory.iterdir() if path.suffix in {".strings", ".stringsdict"}}
        require(names == set(tables), f"Table coverage mismatch in {directory}; expected {sorted(tables)}")
        for name, baseline in tables.items():
            compare_tables(baseline, load_plist(directory / name), str(directory / name), name.endswith(".stringsdict"))
        permission_file = root / PERMISSIONS / f"{code}.lproj" / "InfoPlist.strings"
        translated = load_plist(permission_file)
        compare_tables(permissions, translated, str(permission_file))
        require(all(value.strip() for value in translated.values()), f"Empty permission text in {permission_file}")
        if code == "en":
            require(translated == permissions, "English permissions must match Resources/Info.plist")
    return core_languages


def initialize(root, code, destination):
    language_code(code)
    require(code not in check(root), f"Language {code!r} is already enabled")
    destination = destination.absolute()
    no_symlinks(destination)
    destination = destination.resolve()
    require(not destination.exists(), f"Destination already exists; nothing overwritten: {destination}")
    for active in (root / CORE, root / PERMISSIONS):
        require(not destination.is_relative_to(active.resolve()),
                f"Templates must be outside active resource directories: {destination}")
    require(destination.parent.is_dir(), f"Destination parent must already exist: {destination.parent}")
    # Build the complete pair beside its final destination, then publish together.
    with tempfile.TemporaryDirectory(prefix=".localization-", dir=destination.parent) as temporary:
        staging = Path(temporary) / "translation"
        for relative in (CORE, PERMISSIONS):
            target = staging / relative / f"{code}.lproj"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(root / relative / "en.lproj", target)
        require(not destination.exists(), f"Destination already exists: {destination}")
        os.rename(staging, destination)
    print(f"Prepared inactive English template pair: {destination}")


def package(root, app):
    codes = check(root)
    app = app.absolute()
    # Frameworks legitimately contain symlinks; inspect only paths we own below.
    no_symlinks(app, recursive=False)
    require(app.is_dir() and app.suffix == ".app", f"Expected an existing .app directory: {app}")
    resources = app / "Contents/Resources"
    bundle = resources / CORE_BUNDLE
    require(bundle.is_dir(), f"Missing packaged Core resources: {bundle}; rebuild and copy the SwiftPM bundle")
    # SwiftPM can emit either a flat resource bundle or the native macOS layout.
    core_resources = bundle / "Contents/Resources" if (bundle / "Contents/Resources").is_dir() else bundle
    packaged = languages(core_resources)
    require(packaged == codes,
            f"Stale packaged Core localizations: found {packaged}, expected {codes}; rebuild SwiftPM resources")
    # Validate actual copied content too; matching folder names do not prove a fresh build.
    for code in codes:
        source_folder = root / CORE / f"{code}.lproj"
        packaged_folder = core_resources / f"{code}.lproj"
        expected_tables = {source.name for source in source_folder.iterdir()
                           if source.suffix in {".strings", ".stringsdict"}}
        actual_tables = {source.name for source in packaged_folder.iterdir()
                         if source.suffix in {".strings", ".stringsdict"}}
        require(actual_tables == expected_tables,
                f"Stale packaged Core tables in {code}.lproj; rebuild SwiftPM resources")
        for source in source_folder.iterdir():
            if source.suffix in {".strings", ".stringsdict"}:
                require(load_plist(packaged_folder / source.name) == load_plist(source),
                        f"Stale packaged Core table: {code}.lproj/{source.name}; rebuild SwiftPM resources")
    info_path = app / "Contents/Info.plist"
    info = load_plist(info_path)
    require(info.get("CFBundleDevelopmentRegion") == "en", "Packaged CFBundleDevelopmentRegion must remain en")
    # Only these standalone permission files are ours. Preserve unrelated resources.
    for folder in resources.glob("*.lproj"):
        no_symlinks(folder)
        require(folder.is_dir(), f"Expected a packaged localization directory: {folder}")
        permission_file = folder / "InfoPlist.strings"
        if permission_file.is_file():
            permission_file.unlink()
            if not any(folder.iterdir()):
                folder.rmdir()
    for code in codes:
        folder = resources / f"{code}.lproj"
        folder.mkdir(exist_ok=True)
        shutil.copy2(root / PERMISSIONS / f"{code}.lproj/InfoPlist.strings", folder / "InfoPlist.strings")
    info["CFBundleLocalizations"] = codes
    info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
    print(f"Packaged native localizations: {', '.join(codes)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1],
                        help=argparse.SUPPRESS)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="validate enabled native language folders and all translation tables")
    init = commands.add_parser("init", help="prepare an inactive English template pair outside active resources")
    init.add_argument("language")
    init.add_argument("destination", type=Path)
    app = commands.add_parser("package", help="validate and package native localizations into a built .app")
    app.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        root = args.root.absolute()
        if args.command == "check":
            print(f"Native localizations valid: {', '.join(check(root))}")
        elif args.command == "init":
            initialize(root, args.language, args.destination)
        else:
            package(root, args.app)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"localization: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
