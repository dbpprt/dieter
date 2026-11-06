# Trademarks

Dieter's source code is licensed under the [MIT license](LICENSE). That license
covers the code; it does not grant rights to the project's name or logo.

## What is covered

The name **Dieter**, the Dieter logo, mark and app icons (the files in
[`assets/brand`](assets/brand) and the app icons derived from them) identify
this project and its official releases. They are not licensed for use in a way
that suggests that a product, service, fork or build is the official Dieter or
is endorsed by the project.

## What you may do

- Refer to Dieter by name to describe the project accurately, for example
  "works with Dieter", "a fork of Dieter" or "based on Dieter".
- Use the name and unmodified logo to link to or write about the official
  project, as long as it is clear that you are not the project.
- Build and run the code for yourself, including unmodified official
  configuration, without redistributing it.

## Forks and redistributed builds

If you distribute a modified version, or builds from your own signing
identity, give it a different name and logo so users can tell it apart from
official releases:

1. Change the distribution identity in
   [`config/identity.json`](config/identity.json): product name, bundle prefix,
   Apple team, repository, default gateway, tap and registry. Run
   `just generate` and commit the regenerated files
   ([docs/building.md](docs/building.md#forking)).
2. Replace the brand assets and app icons with your own.
3. Do not publish your builds to app stores, package managers or update feeds
   under the Dieter name.

## Questions

If you are unsure whether a use is fine, ask the maintainer by opening an
issue before you publish.
