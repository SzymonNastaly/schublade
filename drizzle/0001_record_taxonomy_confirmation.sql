ALTER TABLE `categories` ADD `confirmed_at` integer;--> statement-breakpoint
ALTER TABLE `senders` ADD `confirmed_at` integer;--> statement-breakpoint
ALTER TABLE `tags` ADD `confirmed_at` integer;--> statement-breakpoint
UPDATE `categories` SET `confirmed_at` = unixepoch() WHERE `normalized_name` IN ('invoice', 'receipt', 'contract', 'insurance', 'tax notice', 'bank statement', 'medical', 'official identification');--> statement-breakpoint
UPDATE `documents` SET `verification_reason` = NULL WHERE `verification_reason` = 'new_taxonomy_record';
