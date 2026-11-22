CREATE TABLE `change_journal` (
	`sequence_number` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`record_kind` text NOT NULL,
	`record_identifier` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `change_journal_record_index` ON `change_journal` (`record_kind`,`record_identifier`);--> statement-breakpoint
CREATE TABLE `change_journal_identity` (
	`single_row` integer PRIMARY KEY NOT NULL,
	`journal_identifier` text NOT NULL,
	CONSTRAINT "change_journal_identity_single_row_check" CHECK("change_journal_identity"."single_row" = 1)
);
