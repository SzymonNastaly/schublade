ALTER TABLE `categories` DROP COLUMN `confirmed_at`;--> statement-breakpoint
ALTER TABLE `documents` DROP COLUMN `verification_reason`;--> statement-breakpoint
ALTER TABLE `senders` DROP COLUMN `confirmed_at`;--> statement-breakpoint
ALTER TABLE `tags` DROP COLUMN `confirmed_at`;