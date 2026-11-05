# Notes for working on this app

## Carlo's standing rules (always follow)

- **Save buttons are green whenever there's something to save.** Any button whose label starts with "Save" (Save, Save them all, Save the statement, Save note…) is green while it can be pressed, and goes back to normal once it's pressed or greyed out. This is done app-wide by `greenSave()` in `index.html` (class `save-go`), so new Save buttons get it automatically. Keep new save buttons labelled "Save…" and don't override their colour.
