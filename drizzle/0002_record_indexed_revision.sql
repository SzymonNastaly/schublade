ALTER TABLE `documents` ADD `indexed_at` integer;--> statement-breakpoint
UPDATE `documents` SET `indexed_at` = `updated_at` WHERE `status` = 'archived';
