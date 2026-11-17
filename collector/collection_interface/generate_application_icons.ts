// Renders the icons of collection_application from its two SVG drawings with `tauri icon`, keeping
// only what a macOS bundle and its menu bar item read. Run it after changing either drawing.
import { execFileSync } from "node:child_process"
import { copyFileSync, mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const icons = join(import.meta.dirname, "../collection_application/icons")
const rendered = mkdtempSync(join(tmpdir(), "collection_application_icons_"))
const tauri = join(import.meta.dirname, "node_modules/.bin/tauri")

try {
	execFileSync(tauri, ["icon", join(icons, "application_icon.svg"), "-o", join(rendered, "application")], {
		stdio: "inherit",
	})
	for (const name of ["icon.icns", "icon.png", "32x32.png", "128x128.png", "128x128@2x.png"]) {
		copyFileSync(join(rendered, "application", name), join(icons, name))
	}
	// The menu bar shows the template 18 points high, so 44 pixels stay sharp at a scale of 2.
	execFileSync(tauri, ["icon", join(icons, "menu_bar_template.svg"), "-o", join(rendered, "menu_bar"), "--png", "44"], {
		stdio: "inherit",
	})
	copyFileSync(join(rendered, "menu_bar", "44x44.png"), join(icons, "menu_bar_template.png"))
} finally {
	rmSync(rendered, { recursive: true, force: true })
}
