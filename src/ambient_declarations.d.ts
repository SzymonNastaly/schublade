interface ImportMetaEnv {
	readonly VITE_ACCESS_DEVELOPMENT_EXEMPTION?: string
}

// The workerd test project imports PDF fixtures as Data modules.
declare module "*.pdf" {
	const documentBytes: ArrayBuffer
	export default documentBytes
}

// workerd implements readAtLeast, which fills a view with at least that many elements, but the
// generated runtime types leave it out.
interface ReadableStreamBYOBReader {
	readAtLeast: <T extends ArrayBufferView>(minElements: number, view: T) => Promise<ReadableStreamReadResult<T>>
}
