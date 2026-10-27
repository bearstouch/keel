# Change workflow

Every change, whether a feature, a fix or a refactor, follows the same steps.

## Steps

1. **Start from the contract.** Find the requirements the change touches in the
   [requirement pages](../requirements/index.md). For a behavior change or a new feature, update the page first or
   alongside the code. Add new requirement IDs, each with an acceptance check. Never renumber or reuse IDs.
2. **Implement with tests.** Write unit tests that assert observable behavior and failure safety
   ([Testing](testing.md)). Follow the [development rules](rules.md).
3. **Format, lint, build, test.** All must be clean:

    ```sh
    swift format -i -r Sources Tests ThirdParty
    swift format lint --strict -r Sources Tests ThirdParty   # prints nothing
    swift build                                              # zero warnings
    swift test
    ```

4. **Independent review.** Get a fresh-eyes review (a second person or an independent review agent) covering
   correctness, acceptance gaps, security, data loss, races, leaks and test gaps. Fix crucial findings, then format,
   lint, build and test again.
5. **Record what was verified.** State what was observed and what remains pending. Update `README.md` and
   `CHANGELOG.md` if the change is user-visible, and refresh [design sources](../design/sources.md) if the design
   changed. If a check can only be done by hand later, add it to
   [Project status → Pending verification](../project/status.md#pending-verification).
6. **Commit** with Conventional Commits, scoped to a module or area: `feat(<scope>): …`, `fix(<scope>): …`,
   `docs(<scope>): …`.

## Definition of done

A change is done when all of these hold:

1. The requirement pages it touches are updated, and new requirement IDs have acceptance checks.
2. Code and unit tests are in, and the tests assert observable behavior and failure safety.
3. `swift format lint --strict -r Sources Tests ThirdParty` prints nothing, `swift build` has zero warnings, and
   `swift test` passes.
4. Integration checks for the affected area pass against containers, never against a user's servers.
5. UI changes are reviewed against the design canvas in light and dark, with VoiceOver labels and keyboard operation.
6. No secrets, values, key names or console output are logged or persisted beyond what the requirements allow.
7. An independent review checked correctness, security, data loss, races and test gaps, and crucial findings are
   fixed.
8. `CHANGELOG.md` is updated for user-visible changes, and pending manual checks are listed.

## Honesty rules

- An acceptance check counts as passed only when it was actually observed.
- Manual checks that can't be performed here (VoiceOver, notarization on a clean Mac, Intel hardware, managed cloud
  Redis) are recorded as **pending**, never as passed.
- Document blockers instead of faking results.

## Documentation

These docs are plain Markdown in `docs/`, laid out for [MkDocs](https://www.mkdocs.org/) (`mkdocs.yml` at the repo
root holds the navigation). To preview the site:

```sh
pip install mkdocs-material
mkdocs serve          # http://127.0.0.1:8000
mkdocs build --strict # static site in site/; fails on broken links
```

When you add a page, add it to `nav` in `mkdocs.yml`. Use relative links between pages. Two pages are parsed by code,
so keep their table layouts intact: the color tables in [Design](../design/index.md) (`generate-design-tokens.py`) and
the [Default shortcuts](../requirements/functional.md#default-shortcuts) table (`ShortcutBindingsTests`).
