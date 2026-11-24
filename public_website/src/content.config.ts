import { defineCollection } from "astro:content"
import { glob } from "astro/loaders"
import { z } from "astro/zod"

/** Keeps the entry identifier as `<locale>/<file name>`, so the locale and the slug read back exactly. */
function entryIdentifier({ entry }: { entry: string }): string {
	return entry.replace(/\.md$/, "")
}

const title = z.string().max(65)
const description = z.string().min(120).max(160)

const blog = defineCollection({
	loader: glob({ pattern: "*/*.md", base: "./src/content/blog", generateId: entryIdentifier }),
	schema: z
		.object({
			title,
			description,
			publishedOn: z.coerce.date(),
			updatedOn: z.coerce.date().optional(),
			translationKey: z.string().regex(/^[a-z0-9]+(-[a-z0-9]+)*$/),
			tags: z.array(z.string().min(1)).default([]),
		})
		.strict(),
})

const comparisons = defineCollection({
	loader: glob({ pattern: "*/*.md", base: "./src/content/comparisons", generateId: entryIdentifier }),
	schema: z
		.object({
			title,
			description,
			competitor: z.string().min(1),
			competitorUrl: z.url(),
			verifiedOn: z.coerce.date(),
			summary: z.string().min(1),
			aspects: z
				.array(
					z.object({ aspect: z.string().min(1), schublade: z.string().min(1), competitor: z.string().min(1) }).strict(),
				)
				.min(1),
			sources: z.array(z.object({ title: z.string().min(1), url: z.url() }).strict()).min(1),
		})
		.strict(),
})

const informationPages = defineCollection({
	loader: glob({ pattern: "*/*.md", base: "./src/content/information_pages", generateId: entryIdentifier }),
	schema: z.object({ title, description, updatedOn: z.coerce.date() }).strict(),
})

export const collections = { blog, comparisons, informationPages }
