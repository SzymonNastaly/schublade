CREATE TABLE `api_tokens` (
	`id` text PRIMARY KEY NOT NULL,
	`description` text NOT NULL,
	`token_sha256` text NOT NULL,
	`authorization_scope_json` text NOT NULL,
	`last_used_at` integer,
	`created_at` integer DEFAULT (unixepoch()) NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `api_tokens_token_sha256_index` ON `api_tokens` (`token_sha256`);--> statement-breakpoint
CREATE TABLE `authorization_grants` (
	`id` text PRIMARY KEY NOT NULL,
	`client_id` text NOT NULL,
	`client_name` text NOT NULL,
	`authorization_scope_json` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch()) NOT NULL,
	`revoked_at` integer
);
--> statement-breakpoint
CREATE INDEX `authorization_grants_client_id_index` ON `authorization_grants` (`client_id`);--> statement-breakpoint
CREATE TABLE `categories` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`normalized_name` text NOT NULL,
	`expected_fields_json` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch()) NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `categories_normalized_name_index` ON `categories` (`normalized_name`);--> statement-breakpoint
CREATE TABLE `document_tags` (
	`document_id` text NOT NULL,
	`tag_id` text NOT NULL,
	PRIMARY KEY(`document_id`, `tag_id`),
	FOREIGN KEY (`document_id`) REFERENCES `documents`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`tag_id`) REFERENCES `tags`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `document_tags_tag_id_index` ON `document_tags` (`tag_id`);--> statement-breakpoint
CREATE TABLE `documents` (
	`id` text PRIMARY KEY NOT NULL,
	`title` text,
	`document_date` text,
	`sender_id` text,
	`category_id` text,
	`person_member_id` text,
	`summary` text,
	`storage_object_key` text NOT NULL,
	`mime_type` text NOT NULL,
	`byte_size` integer NOT NULL,
	`page_count` integer,
	`status` text DEFAULT 'processing' NOT NULL,
	`verification_reason` text,
	`created_at` integer DEFAULT (unixepoch()) NOT NULL,
	`updated_at` integer DEFAULT (unixepoch()) NOT NULL,
	FOREIGN KEY (`sender_id`) REFERENCES `senders`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`category_id`) REFERENCES `categories`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`person_member_id`) REFERENCES `household_members`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `documents_storage_object_key_index` ON `documents` (`storage_object_key`);--> statement-breakpoint
CREATE INDEX `documents_document_date_index` ON `documents` (`document_date`);--> statement-breakpoint
CREATE INDEX `documents_sender_id_index` ON `documents` (`sender_id`);--> statement-breakpoint
CREATE INDEX `documents_category_id_index` ON `documents` (`category_id`);--> statement-breakpoint
CREATE INDEX `documents_person_member_id_index` ON `documents` (`person_member_id`);--> statement-breakpoint
CREATE INDEX `documents_status_index` ON `documents` (`status`);--> statement-breakpoint
CREATE TABLE `extracted_fields` (
	`id` text PRIMARY KEY NOT NULL,
	`document_id` text NOT NULL,
	`field_key` text NOT NULL,
	`field_type` text NOT NULL,
	`value_text` text,
	`value_number` real,
	`confidence_score` real,
	FOREIGN KEY (`document_id`) REFERENCES `documents`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `extracted_fields_document_field_index` ON `extracted_fields` (`document_id`,`field_key`);--> statement-breakpoint
CREATE TABLE `household_members` (
	`id` text PRIMARY KEY NOT NULL,
	`display_name` text NOT NULL,
	`addressee_names_json` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch()) NOT NULL
);
--> statement-breakpoint
CREATE TABLE `senders` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`normalized_name` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch()) NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `senders_normalized_name_index` ON `senders` (`normalized_name`);--> statement-breakpoint
CREATE TABLE `tags` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`normalized_name` text NOT NULL,
	`color_hex` text,
	`created_at` integer DEFAULT (unixepoch()) NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `tags_normalized_name_index` ON `tags` (`normalized_name`);