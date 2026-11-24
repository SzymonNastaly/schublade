import { fileURLToPath } from "node:url"
import sharp from "sharp"
import {
	DRAWER_EMBLEM_MARKUP,
	DRAWER_EMBLEM_VIEW_BOX,
	WORDMARK_OUTLINE,
	WORDMARK_VIEW_BOX,
} from "../src/brand_drawings.ts"

const WIDTH = 1200
const HEIGHT = 630
const SCREENSHOT = fileURLToPath(new URL("../src/assets/screenshots/mac_library_reader.png", import.meta.url))
const OUTPUT = fileURLToPath(new URL("../public/social_image.png", import.meta.url))

const screenshotWidth = 860
const screenshotLeft = 420
const screenshotTop = 150

const background = `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}">
	<defs>
		<linearGradient id="band" x1="0" y1="0" x2="0" y2="1">
			<stop offset="0" stop-color="#2c68c4" />
			<stop offset="0.58" stop-color="#1a4fa6" />
			<stop offset="1" stop-color="#123f8c" />
		</linearGradient>
		<radialGradient id="glow" cx="0.3" cy="0" r="0.7">
			<stop offset="0" stop-color="#cde4ff" stop-opacity="0.45" />
			<stop offset="1" stop-color="#cde4ff" stop-opacity="0" />
		</radialGradient>
	</defs>
	<rect width="${WIDTH}" height="${HEIGHT}" fill="url(#band)" />
	<rect width="${WIDTH}" height="${HEIGHT}" fill="url(#glow)" />
	<svg x="64" y="214" width="190" height="169" viewBox="${DRAWER_EMBLEM_VIEW_BOX}">${DRAWER_EMBLEM_MARKUP}</svg>
	<svg x="64" y="404" width="330" height="46" viewBox="${WORDMARK_VIEW_BOX}">
		<path d="${WORDMARK_OUTLINE}" fill="#ffffff" />
	</svg>
	<rect x="${screenshotLeft - 2}" y="${screenshotTop - 2}" width="${screenshotWidth + 4}" height="${HEIGHT}" rx="14" fill="#0b2447" fill-opacity="0.35" />
</svg>`

const screenshotHeight = HEIGHT - screenshotTop
const roundedCorners = Buffer.from(
	`<svg xmlns="http://www.w3.org/2000/svg" width="${screenshotWidth}" height="${screenshotHeight}"><rect width="${screenshotWidth}" height="${screenshotHeight + 20}" rx="12" /></svg>`,
)
const screenshot = await sharp(SCREENSHOT)
	.resize({ width: screenshotWidth })
	.extract({ left: 0, top: 0, width: screenshotWidth, height: screenshotHeight })
	.composite([{ input: roundedCorners, blend: "dest-in" }])
	.png()
	.toBuffer()

await sharp(Buffer.from(background))
	.composite([{ input: screenshot, left: screenshotLeft, top: screenshotTop }])
	.png({ compressionLevel: 9, palette: false })
	.toFile(OUTPUT)

console.log(`Wrote ${OUTPUT}`)
