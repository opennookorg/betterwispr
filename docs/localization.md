# Add an interface language

Native folders in `Sources/BetterWisprCore/Localization/Resources/*.lproj`
declare the available interface languages. Each needs a matching
`Resources/<language>.lproj/InfoPlist.strings` for macOS permission messages.
The runtime discovers the Core bundle's localizations. Packaging derives
`CFBundleLocalizations` and copies permission text from these folders. No
language list needs editing. English remains the fallback.

## Prepare a translation

From the repository root, choose a new, explicit staging folder outside the
active resource directories:

```sh
python3 scripts/localization.py init es "$HOME/Downloads/BetterWispr-localization-es"
```

Use a language identifier such as `es` or `pt-BR`. The command refuses invalid
identifiers, an existing destination or an already declared language. It
creates a paired set of native resource folders under the staging destination:

```text
Sources/BetterWisprCore/Localization/Resources/es.lproj/
Resources/es.lproj/InfoPlist.strings
```

These files are English templates, not finished translations. Initializing a
staging folder does not enable a language. Translate every table and all
permission descriptions before activation. Keep keys, format argument types,
argument positions and literal `%%` escapes intact. Equal English and translated
values are allowed for names or other text that does not change.

The `.stringsdict` files use native plural rules. Categories vary by language;
choose the categories the target language needs, retain `other`, and keep the
plural variables and argument types consistent. Review zero, one and several
counts, including sentences with other format arguments.

## Activate and verify

Copy both completed folders into their matching repository paths. This paired
copy is the intentional activation step. Do not copy an unfinished template.
Then run:

```sh
python3 scripts/localization.py check
python3 Tests/localization_tools_check.py
swift test --filter Localization
```

The source check covers matching language folders, table names, keys, format
arguments, plural definitions and permission descriptions. The small tool
fixtures exercise staging, activation and packaging without opening an app.
See [the localization checklist](testing.md#interface-localization) for manual
checks and for inspecting a separately built app:

```sh
python3 Tests/localization_check.py /path/to/BetterWispr.app
```

Build normally to create a fresh package. The build validates source resources,
checks that the packaged Core languages match them, and derives app language
metadata before signing. The package command targets the explicit app path;
use it only for build artifacts. These checks do not install or launch an app
or change language preferences.

An interface translation does not add dictation language support, cleanup
rules, voice commands or writing tones. `StylePreview` shows illustrative French
examples and keeps French input unchanged in its cleanup preview. Light and
Medium cleanup currently edit English dictation only. Translating
`StyleExamples.strings` does not extend cleanup to another spoken language.
