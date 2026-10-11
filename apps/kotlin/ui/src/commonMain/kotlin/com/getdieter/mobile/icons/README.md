# Selected Material icons

These vector definitions come from JetBrains Compose Material Icons 1.7.3,
authored by the Android Open Source Project. Their package name was changed;
vector paths are unchanged. See [LICENSE.txt](LICENSE.txt) and each source header.

- 31 files were copied from `material-icons-extended-1.7.3-sources.jar`
  (SHA-256 `4e23237644f7da35c391cc4c0263b95248605f499ab46f6d2c92d4fe48793d5a`).
- 56 files were reconstructed from the path calls in the compiled
  `material-icons-extended-desktop-1.7.3.jar` classes, including arc commands.
  Icons whose paths depend on computed locals were not reconstructed.

Keeping only used icons avoids compiling the entire extended icon library
on Kotlin/Native. Standard icons use `material-icons-core`. On iOS, `Glyph`
renders SF Symbols instead; these icons are the Android and JVM rendering.
