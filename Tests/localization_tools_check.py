#!/usr/bin/env python3
"""Black-box localization workflow checks using tiny disposable native resources."""
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'scripts/localization.py'
INSPECTOR = ROOT / 'Tests/localization_check.py'
CORE = Path('Sources/BetterWisprCore/Localization/Resources')
PERMISSIONS = Path('Resources')


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value, sort_keys=False))


class LocalizationToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='BetterWispr-localization-tools-')
        self.addCleanup(self.temporary.cleanup)
        self.workspace = Path(self.temporary.name).resolve()
        self.root = self.workspace / 'source'
        self.permissions = {'NSMicrophoneUsageDescription': 'Records when requested.',
                            'NSSpeechRecognitionUsageDescription': 'Uses on-device recognition.'}
        self.info = {'CFBundleDevelopmentRegion': 'en', 'CFBundleIdentifier': 'org.betterwispr.fixture',
                     **self.permissions}
        write_plist(self.root / PERMISSIONS / 'Info.plist', self.info)
        write_plist(self.root / PERMISSIONS / 'en.lproj/InfoPlist.strings', self.permissions)
        write_plist(self.root / CORE / 'en.lproj/Localizable.strings',
                    {'Settings': 'Settings', 'Downloading %@%%': 'Downloading %@%%',
                     '%@ has %ld words': '%@ has %ld words'})
        write_plist(self.root / CORE / 'en.lproj/Appearance.strings', {'Light': 'Light'})
        write_plist(self.root / CORE / 'en.lproj/Localizable.stringsdict', {
            '%ld words': {'NSStringLocalizedFormatKey': '%#@words@', 'words': {
                'NSStringFormatSpecTypeKey': 'NSStringPluralRuleType',
                'NSStringFormatValueTypeKey': 'ld', 'one': '%ld word', 'other': '%ld words'}}})

    def cli(self, *arguments, succeeds=True):
        result = subprocess.run([sys.executable, str(TOOL), '--root', str(self.root),
                                 *map(str, arguments)], capture_output=True, text=True)
        message = f'{arguments}:\n{result.stdout}\n{result.stderr}'
        if succeeds:
            self.assertEqual(result.returncode, 0, message)
        else:
            self.assertNotEqual(result.returncode, 0, message)
        return result

    def initialize(self, code='pt-BR'):
        destination = self.workspace / f'translation-{code}'
        self.cli('init', code, destination)
        return destination

    def activate(self, code='pt-BR'):
        staged = self.initialize(code)
        for relative in (CORE, PERMISSIONS):
            shutil.copytree(staged / relative / f'{code}.lproj', self.root / relative / f'{code}.lproj')
        return staged

    def fake_app(self, native_layout=False):
        app = self.workspace / 'Fixture.app'
        write_plist(app / 'Contents/Info.plist', self.info)
        core = app / 'Contents/Resources/BetterWispr_BetterWisprCore.bundle'
        if native_layout:
            core = core / 'Contents/Resources'
        shutil.copytree(self.root / CORE, core)
        return app, core

    def inspect(self, app, succeeds=True):
        result = subprocess.run([sys.executable, str(INSPECTOR), str(app), '--root', str(self.root)],
                                capture_output=True, text=True)
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_staging_does_not_enable_language_and_paired_copy_does(self):
        staged = self.initialize()
        self.assertFalse((self.root / CORE / 'pt-BR.lproj').exists())
        self.assertFalse((self.root / PERMISSIONS / 'pt-BR.lproj').exists())
        self.cli('check')
        translated = staged / CORE / 'pt-BR.lproj/Localizable.strings'
        table = plistlib.loads(translated.read_bytes())
        table['Settings'] = 'Configurações'
        table['%@ has %ld words'] = '%2$ld palavras para %1$@'
        write_plist(translated, table)
        for relative in (CORE, PERMISSIONS):
            shutil.copytree(staged / relative / 'pt-BR.lproj', self.root / relative / 'pt-BR.lproj')
        self.cli('check')
        app, _ = self.fake_app()
        self.cli('package', app)
        self.assertEqual(plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleLocalizations'], ['en', 'pt-BR'])
        self.assertEqual(plistlib.loads((app / 'Contents/Resources/pt-BR.lproj/InfoPlist.strings').read_bytes()), self.permissions)
        self.inspect(app)

    def test_invalid_codes_and_existing_destination_do_not_write(self):
        for code in ('../es', 'es/ES', 'es_ES', ''):
            with self.subTest(code=code):
                destination = self.workspace / 'invalid'
                self.cli('init', code, destination, succeeds=False)
                self.assertFalse(destination.exists())
        existing_language = self.workspace / 'already-enabled'
        self.cli('init', 'en', existing_language, succeeds=False)
        self.assertFalse(existing_language.exists())
        destination = self.initialize('es')
        before = {path.relative_to(destination): path.read_bytes() for path in destination.rglob('*') if path.is_file()}
        self.cli('init', 'es', destination, succeeds=False)
        self.assertEqual(before, {path.relative_to(destination): path.read_bytes() for path in destination.rglob('*') if path.is_file()})

    def test_staging_inside_active_resources_is_rejected(self):
        for relative in (CORE, PERMISSIONS):
            destination = self.root / relative / 'translation-draft'
            self.cli('init', 'es', destination, succeeds=False)
            self.assertFalse(destination.exists())

    def test_missing_permission_pair_blocks_validation_and_packaging(self):
        self.activate('es')
        shutil.rmtree(self.root / PERMISSIONS / 'es.lproj')
        self.cli('check', succeeds=False)
        app, _ = self.fake_app()
        before = (app / 'Contents/Info.plist').read_bytes()
        self.cli('package', app, succeeds=False)
        self.assertEqual((app / 'Contents/Info.plist').read_bytes(), before)

    def test_missing_permission_key_and_empty_permission_are_rejected(self):
        self.activate('es')
        path = self.root / PERMISSIONS / 'es.lproj/InfoPlist.strings'
        write_plist(path, {'NSMicrophoneUsageDescription': 'Records when requested.'})
        self.cli('check', succeeds=False)
        write_plist(path, {**self.permissions, 'NSMicrophoneUsageDescription': '  '})
        self.cli('check', succeeds=False)

    def test_missing_table_key_and_wrong_argument_type_are_rejected(self):
        self.activate('es')
        path = self.root / CORE / 'es.lproj/Appearance.strings'
        path.unlink()
        self.cli('check', succeeds=False)
        write_plist(path, {})
        self.cli('check', succeeds=False)
        write_plist(path, {'Light': 'Light'})
        path = self.root / CORE / 'es.lproj/Localizable.strings'
        table = plistlib.loads(path.read_bytes())
        table['Downloading %@%%'] = 'Downloading %ld%%'
        write_plist(path, table)
        self.cli('check', succeeds=False)

    def test_additional_native_integer_arguments_are_rejected(self):
        source = self.root / CORE / 'en.lproj/Localizable.strings'
        english = plistlib.loads(source.read_bytes())
        english['%@'] = '%@'
        write_plist(source, english)
        self.activate('es')
        translated = self.root / CORE / 'es.lproj/Localizable.strings'
        table = plistlib.loads(translated.read_bytes())
        for conversion in ('D', 'U', 'O'):
            with self.subTest(conversion=conversion):
                table['%@'] = f'%@ %{conversion}'
                write_plist(translated, table)
                self.cli('check', succeeds=False)

    def test_blank_ordinary_translations_are_rejected(self):
        self.activate('es')
        path = self.root / CORE / 'es.lproj/Appearance.strings'
        for blank in ('', ' ', '\t\n'):
            with self.subTest(blank=repr(blank)):
                write_plist(path, {'Light': blank})
                self.cli('check', succeeds=False)

    def test_blank_native_plural_branches_are_rejected(self):
        self.activate('es')
        path = self.root / CORE / 'es.lproj/Localizable.stringsdict'
        original = path.read_bytes()
        for category in ('one', 'other'):
            for blank in ('', ' \t\n'):
                with self.subTest(category=category, blank=repr(blank)):
                    table = plistlib.loads(original)
                    table['%ld words']['words'][category] = blank
                    write_plist(path, table)
                    self.cli('check', succeeds=False)

    def test_literal_trailing_percent_remains_valid(self):
        self.activate('es')
        path = self.root / CORE / 'es.lproj/Localizable.strings'
        table = plistlib.loads(path.read_bytes())
        table['Settings'] = 'Progreso %'
        write_plist(path, table)
        self.cli('check')

    def test_native_plural_categories_can_vary_but_argument_types_must_match(self):
        self.activate('es')
        path = self.root / CORE / 'es.lproj/Localizable.stringsdict'
        table = plistlib.loads(path.read_bytes())
        rule = table['%ld words']['words']
        del rule['one']
        rule['few'] = '%ld words'
        write_plist(path, table)
        self.cli('check')
        rule['few'] = '%@ words'
        write_plist(path, table)
        self.cli('check', succeeds=False)
        rule['few'] = '%ld words'
        del rule['other']
        write_plist(path, table)
        self.cli('check', succeeds=False)

    def test_native_core_layout_and_framework_symlinks_are_supported(self):
        self.activate('es')
        app, _ = self.fake_app(native_layout=True)
        framework = app / 'Contents/Frameworks/Fixture.framework'
        (framework / 'Versions/A').mkdir(parents=True)
        (framework / 'Versions/Current').symlink_to('A', target_is_directory=True)
        (framework / 'Resources').symlink_to('Versions/Current/Resources', target_is_directory=True)
        self.cli('package', app)
        self.inspect(app)

    def test_stale_core_locale_or_content_blocks_package(self):
        self.activate('es')
        app, core = self.fake_app()
        shutil.copytree(core / 'en.lproj', core / 'fr.lproj')
        self.cli('package', app, succeeds=False)
        shutil.rmtree(core / 'fr.lproj')
        write_plist(core / 'es.lproj/Appearance.strings', {'Light': 'Stale'})
        self.cli('package', app, succeeds=False)

    def test_package_removes_stale_permission_locale_and_inspector_rejects_stale_metadata(self):
        app, core = self.fake_app()
        resources = app / 'Contents/Resources'
        write_plist(resources / 'es.lproj/InfoPlist.strings', self.permissions)
        self.cli('package', app)
        self.assertFalse((resources / 'es.lproj').exists())
        self.inspect(app)
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        info['CFBundleLocalizations'] = ['en', 'es']
        write_plist(app / 'Contents/Info.plist', info)
        self.inspect(app, succeeds=False)
        self.cli('package', app)
        shutil.copytree(core / 'en.lproj', core / 'es.lproj')
        self.inspect(app, succeeds=False)


if __name__ == '__main__':
    unittest.main()
