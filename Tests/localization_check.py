#!/usr/bin/env python3
"""Inspect source-declared native localizations in a packaged app without launching it."""
import argparse
import plistlib
import subprocess
from pathlib import Path


def plist(path):
    data = subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(path)])
    return plistlib.loads(data)


def languages(path):
    return {folder.stem for folder in path.glob('*.lproj') if folder.is_dir()}


def inspect(app, root):
    source = root / 'Sources/BetterWisprCore/Localization/Resources'
    expected = sorted(languages(source), key=lambda language: (language != 'en', language))
    assert expected and expected[0] == 'en', 'The English fallback resources are missing'
    assert languages(root / 'Resources') == set(expected), 'Source permission locales differ from Core locales'
    base_info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleDevelopmentRegion'] == 'en'
    assert info['CFBundleLocalizations'] == expected, 'Packaged language metadata differs from source locales'
    permissions = {key: value for key, value in base_info.items() if key.endswith('UsageDescription')}
    assert permissions, 'English fallback permission descriptions are missing'
    assert {key: value for key, value in info.items() if key.endswith('UsageDescription')} == permissions
    resources = app / 'Contents/Resources'
    core = resources / 'BetterWispr_BetterWisprCore.bundle'
    assert core.is_dir(), 'The native Core localization bundle is missing'
    assert not (app / 'Contents/MacOS/BetterWispr_BetterWisprCore.bundle').exists(), 'Duplicate Core resources'
    core_resources = core / 'Contents/Resources' if (core / 'Contents/Resources').is_dir() else core
    assert languages(core_resources) == set(expected), 'Packaged Core locales differ from source locales'
    permission_languages = {folder.stem for folder in resources.glob('*.lproj')
                            if (folder / 'InfoPlist.strings').is_file()}
    assert permission_languages == set(expected), 'Packaged permission locales differ from source locales'
    for language in expected:
        permission_strings = plist(resources / f'{language}.lproj/InfoPlist.strings')
        assert permission_strings == plist(root / f'Resources/{language}.lproj/InfoPlist.strings')
        assert permission_strings.keys() == permissions.keys()
        assert all(isinstance(value, str) and value.strip() for value in permission_strings.values())
        if language == 'en':
            assert permission_strings == permissions, 'English permissions differ from fallback descriptions'
        source_locale = source / f'{language}.lproj'
        packaged_locale = core_resources / f'{language}.lproj'
        expected_tables = {path.name for path in source_locale.iterdir() if path.suffix in {'.strings', '.stringsdict'}}
        packaged_tables = {path.name for path in packaged_locale.iterdir() if path.suffix in {'.strings', '.stringsdict'}}
        assert packaged_tables == expected_tables, f'Packaged tables differ for {language}'
        for table in expected_tables:
            assert plist(packaged_locale / table) == plist(source_locale / table), f'Packaged content differs: {language}/{table}'
    print(f'Native resources and permission descriptions match source languages: {", ".join(expected)}.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    arguments = parser.parse_args()
    inspect(arguments.app, arguments.root)
