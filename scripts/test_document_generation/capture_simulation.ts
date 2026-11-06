export interface GrayscaleRaster {
	width: number
	height: number
	luminance: Uint8Array
}

export interface ColorRaster {
	width: number
	height: number
	rgba: Uint8Array
}

export type RandomSource = () => number

export function createRandomSource(seed: string): RandomSource {
	let state = 2166136261
	for (const character of seed) {
		state = Math.imul(state ^ character.codePointAt(0)!, 16777619)
	}
	return () => {
		state = (state + 0x6d2b79f5) | 0
		let mixed = Math.imul(state ^ (state >>> 15), 1 | state)
		mixed = (mixed + Math.imul(mixed ^ (mixed >>> 7), 61 | mixed)) ^ mixed
		return ((mixed ^ (mixed >>> 14)) >>> 0) / 4294967296
	}
}

const standardNormalSample = (random: RandomSource): number =>
	(random() + random() + random() + random() - 2) * Math.sqrt(3)
const clampByte = (value: number): number => (value < 0 ? 0 : value > 255 ? 255 : Math.round(value))
const clampUnit = (value: number): number => (value < 0 ? 0 : value > 1 ? 1 : value)
const smoothstep = (value: number): number => value * value * (3 - 2 * value)

function sampleBilinear(raster: GrayscaleRaster, x: number, y: number): number {
	const column = Math.min(Math.max(x, 0), raster.width - 1.001)
	const row = Math.min(Math.max(y, 0), raster.height - 1.001)
	const left = Math.floor(column)
	const top = Math.floor(row)
	const horizontalWeight = column - left
	const verticalWeight = row - top
	const index = top * raster.width + left
	const upper = raster.luminance[index]! * (1 - horizontalWeight) + raster.luminance[index + 1]! * horizontalWeight
	const lower =
		raster.luminance[index + raster.width]! * (1 - horizontalWeight) +
		raster.luminance[index + raster.width + 1]! * horizontalWeight
	return upper * (1 - verticalWeight) + lower * verticalWeight
}

function createValueNoise(random: RandomSource, columns: number, rows: number): (x: number, y: number) => number {
	const lattice = Float32Array.from({ length: (columns + 1) * (rows + 1) }, () => random())
	return (x, y) => {
		const gridX = clampUnit(x) * columns
		const gridY = clampUnit(y) * rows
		const cellX = Math.min(Math.floor(gridX), columns - 1)
		const cellY = Math.min(Math.floor(gridY), rows - 1)
		const weightX = smoothstep(gridX - cellX)
		const weightY = smoothstep(gridY - cellY)
		const at = (offsetX: number, offsetY: number) => lattice[(cellY + offsetY) * (columns + 1) + cellX + offsetX]!
		const upper = at(0, 0) * (1 - weightX) + at(1, 0) * weightX
		const lower = at(0, 1) * (1 - weightX) + at(1, 1) * weightX
		return upper * (1 - weightY) + lower * weightY
	}
}

function blurChannel(values: Float32Array, width: number, height: number): Float32Array {
	const horizontal = new Float32Array(values.length)
	for (let y = 0; y < height; y++) {
		for (let x = 0; x < width; x++) {
			const index = y * width + x
			const left = values[x > 0 ? index - 1 : index]!
			const right = values[x < width - 1 ? index + 1 : index]!
			horizontal[index] = (left + 2 * values[index]! + right) / 4
		}
	}
	const result = new Float32Array(values.length)
	for (let y = 0; y < height; y++) {
		for (let x = 0; x < width; x++) {
			const index = y * width + x
			const above = horizontal[y > 0 ? index - width : index]!
			const below = horizontal[y < height - 1 ? index + width : index]!
			result[index] = (above + 2 * horizontal[index]! + below) / 4
		}
	}
	return result
}

export function simulateFlatbedScan(page: GrayscaleRaster, random: RandomSource): ColorRaster {
	const { width, height } = page
	const angle = ((random() < 0.5 ? -1 : 1) * (0.3 + random() * 0.5) * Math.PI) / 180
	const cosine = Math.cos(angle)
	const sine = Math.sin(angle)
	const shiftX = (random() * 2 - 1) * 5
	const shiftY = random() * 7
	const inkLevel = 30 + random() * 12
	const paperLevel = 241 + random() * 6
	const lidLevel = 214
	const illuminationSlope = (random() * 2 - 1) * 0.035
	const toneCurve = Float32Array.from(
		{ length: 256 },
		(_, level) => inkLevel + (paperLevel - inkLevel) * (level / 255) ** 1.35,
	)

	const tones = new Float32Array(width * height)
	for (let y = 0; y < height; y++) {
		for (let x = 0; x < width; x++) {
			const offsetX = x - width / 2 - shiftX
			const offsetY = y - height / 2 - shiftY
			const sourceX = cosine * offsetX + sine * offsetY + width / 2
			const sourceY = -sine * offsetX + cosine * offsetY + height / 2
			const distanceOutside = Math.max(-sourceX, sourceX - (width - 1), -sourceY, sourceY - (height - 1))
			const tone =
				distanceOutside > 0
					? lidLevel - 70 * Math.exp(-distanceOutside / 1.5)
					: toneCurve[Math.round(sampleBilinear(page, sourceX, sourceY))]!
			tones[y * width + x] = tone * (1 + illuminationSlope * (x / width - 0.5))
		}
	}
	const softened = blurChannel(tones, width, height)

	const dustCount = 25 + Math.floor(random() * 35)
	for (let speck = 0; speck < dustCount; speck++) {
		const centerX = random() * width
		const centerY = random() * height
		const radius = 0.5 + random() * 1.3
		const darkness = 60 + random() * 90
		for (let y = Math.floor(centerY - radius); y <= Math.ceil(centerY + radius); y++) {
			for (let x = Math.floor(centerX - radius); x <= Math.ceil(centerX + radius); x++) {
				if (x < 0 || y < 0 || x >= width || y >= height) continue
				if ((x - centerX) ** 2 + (y - centerY) ** 2 <= radius * radius)
					softened[y * width + x] = Math.min(softened[y * width + x]!, darkness)
			}
		}
	}

	const rgba = new Uint8Array(width * height * 4)
	for (let index = 0; index < width * height; index++) {
		const value = softened[index]! + standardNormalSample(random) * 3
		rgba[index * 4] = clampByte(value + 2)
		rgba[index * 4 + 1] = clampByte(value)
		rgba[index * 4 + 2] = clampByte(value - 4)
		rgba[index * 4 + 3] = 255
	}
	return { width, height, rgba }
}

export function simulateReceiptPhotograph(receipt: GrayscaleRaster, random: RandomSource): ColorRaster {
	const width = 1200
	const height = 1600
	const angle = ((random() < 0.5 ? -1 : 1) * (1.5 + random() * 1.5) * Math.PI) / 180
	const cosine = Math.cos(angle)
	const sine = Math.sin(angle)
	const centerX = width / 2 + (random() * 2 - 1) * 30
	const centerY = height / 2 + (random() * 2 - 1) * 25
	const shadowOffsetX = 9
	const shadowOffsetY = 14
	const surfaceTexture = createValueNoise(random, 9, 12)
	const surfaceGrain = createValueNoise(random, 4, 60)
	const thermalFade = createValueNoise(random, 3, 6)
	const paperBlotches = createValueNoise(random, 5, 9)
	const creaseRow = receipt.height * (0.38 + random() * 0.2)
	const inkColor = [64, 60, 74] as const

	const toReceiptCoordinates = (x: number, y: number): [number, number] => {
		const offsetX = x - centerX
		const offsetY = y - centerY
		return [
			cosine * offsetX + sine * offsetY + receipt.width / 2,
			-sine * offsetX + cosine * offsetY + receipt.height / 2,
		]
	}
	const insideDistance = (column: number, row: number) =>
		Math.min(column, receipt.width - column, row, receipt.height - row)

	const channels = [
		new Float32Array(width * height),
		new Float32Array(width * height),
		new Float32Array(width * height),
	] as const
	for (let y = 0; y < height; y++) {
		for (let x = 0; x < width; x++) {
			const index = y * width + x
			const texture = surfaceTexture(x / width, y / height) * 0.7 + surfaceGrain(x / width, y / height) * 0.3
			const [shadowColumn, shadowRow] = toReceiptCoordinates(x - shadowOffsetX, y - shadowOffsetY)
			const shadow = 1 - 0.5 * smoothstep(clampUnit((insideDistance(shadowColumn, shadowRow) + 22) / 44))
			let red = (92 + 30 * texture) * shadow
			let green = (70 + 24 * texture) * shadow
			let blue = (52 + 18 * texture) * shadow

			const [column, row] = toReceiptCoordinates(x, y)
			const coverage = clampUnit(insideDistance(column, row) + 0.5)
			if (coverage > 0) {
				const ink = (255 - sampleBilinear(receipt, column, row)) / 255
				const fade = 0.42 + 0.33 * thermalFade(column / receipt.width, row / receipt.height)
				const creaseOffset = row - creaseRow
				const crease =
					1 - 0.07 * Math.exp(-((creaseOffset / 3) ** 2)) + 0.03 * Math.exp(-(((creaseOffset - 7) / 6) ** 2))
				const paper = (0.96 + 0.04 * paperBlotches(column / receipt.width, row / receipt.height)) * crease
				const inkStrength = ink * fade
				const paperColor = [247 * paper, 239 * paper, 222 * paper] as const
				red = red * (1 - coverage) + (paperColor[0] * (1 - inkStrength) + inkColor[0] * inkStrength) * coverage
				green = green * (1 - coverage) + (paperColor[1] * (1 - inkStrength) + inkColor[1] * inkStrength) * coverage
				blue = blue * (1 - coverage) + (paperColor[2] * (1 - inkStrength) + inkColor[2] * inkStrength) * coverage
			}

			const radial = ((x - width / 2) ** 2 + (y - height / 2) ** 2) / ((width / 2) ** 2 + (height / 2) ** 2)
			const lighting = (1 - 0.3 * radial) * (1.05 - 0.1 * (y / height))
			channels[0][index] = red * lighting * 1.02
			channels[1][index] = green * lighting
			channels[2][index] = blue * lighting * 0.94
		}
	}

	const softened = channels.map((channel) => blurChannel(channel, width, height))
	const rgba = new Uint8Array(width * height * 4)
	for (let index = 0; index < width * height; index++) {
		const luminanceNoise = standardNormalSample(random) * 4
		for (let channel = 0; channel < 3; channel++) {
			rgba[index * 4 + channel] = clampByte(
				softened[channel]![index]! + luminanceNoise + standardNormalSample(random) * 1.5,
			)
		}
		rgba[index * 4 + 3] = 255
	}
	return { width, height, rgba }
}
