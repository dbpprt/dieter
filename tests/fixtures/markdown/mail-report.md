## Summary

Three dependencies have **critical** advisories and seven are outdated. Every fix is a patch or minor release; `go.mod` and `web/package.json` need updates. The upgrade notes are in [README.md](README.md).

| Package | Current | Fixed in | Severity | Advisory | Importers | Notes |
|:--|--:|--:|:-:|:--|--:|:--|
| golang.org/x/net | 0.23.0 | 0.33.0 | critical | [DA-2026-0141](https://advisories.example.com/DA-2026-0141) | 14 | HTTP/2 header parsing |
| golang.org/x/crypto | 0.21.0 | 0.31.0 | critical | [DA-2026-0138](https://advisories.example.com/DA-2026-0138) | 9 | SSH key callback misuse |
| github.com/golang-jwt/jwt/v5 | 5.2.0 | 5.2.2 | critical | [DA-2026-0122](https://advisories.example.com/DA-2026-0122) | 3 | Header parsing allocation |
| express | 4.19.2 | 4.21.2 | high | [DA-2026-0117](https://advisories.example.com/DA-2026-0117) | 2 | Open redirect |
| semver | 7.5.1 | 7.5.4 | moderate | [DA-2026-0094](https://advisories.example.com/DA-2026-0094) | 6 | Range parsing ReDoS |

### Suggested next steps

- [x] Pin the fixed versions on a branch
- [ ] Run the integration suite against the branch
- [ ] Ship the upgrade with the next release

```sh
go get golang.org/x/net@v0.33.0 golang.org/x/crypto@v0.31.0 github.com/golang-jwt/jwt/v5@v5.2.2
go mod tidy && go test ./...
```
