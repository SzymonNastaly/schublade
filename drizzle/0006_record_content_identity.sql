CREATE TABLE `contents` (
	`sha256` text PRIMARY KEY NOT NULL,
	`document_id` text,
	`created_at` integer DEFAULT (unixepoch()) NOT NULL,
	FOREIGN KEY (`document_id`) REFERENCES `documents`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE INDEX `contents_document_id_index` ON `contents` (`document_id`);--> statement-breakpoint
ALTER TABLE `documents` ADD `original_sha256` text;