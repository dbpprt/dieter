# Rich Mail fixture

`rich.md` is embedded by the isolated gateway and consumed by the bundled
renderer tests and the real Mail reader flows on macOS, Android and iOS.
It includes supported graphics, the Vega-Lite alias, malformed JSON, blocked
external data, escaped HTML, image alt text and workspace links. The fixture's
relative README link resolves to the sender's checkout in the device flows.

`backgrounds.md` compares null, omitted and explicit white backgrounds for both
Vega-Lite and raw Vega, including title/subtitle, axes, legend and text marks.
The isolated mailbox seeds it as **Chart background comparison**.

Run `just e2e mac flows:mail-backgrounds screenshots:compositor` for real window
captures (requires Screen Recording), or `just e2e ios flows:mail-backgrounds`
and `just e2e android profile:android-emulator flows:mail-backgrounds`. Open the
PNGs and inspect the surrounding Mail surface in each theme; render counts and
alpha checks alone cannot qualify the visual result.

To reproduce a locally supplied report without committing its data, set
`DIETER_TEST_MAIL_REPORT=/absolute/path/report.md` for an E2E run. The fixture
passes it to `tools/fixtures/gateway -e2e-fixture -mail-report PATH` and seeds
**upday revised transparency report** only in the disposable mailbox. The file
uses the ordinary Mail body validation and is never fetched from production.
