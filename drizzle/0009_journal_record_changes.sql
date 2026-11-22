-- Written into the file that `drizzle-kit generate --custom` prepares, because drizzle-kit
-- knows no triggers. Every write to a row of a journaled table moves the journal entry of its
-- record to a new highest sequence number, inside the statement that writes the row. No trigger
-- names a column, so no later column can be left out. An update moves the record a row left as
-- well as the record it joined, should an update ever change the identifier.
CREATE TRIGGER `documents_change_journal_after_insert` AFTER INSERT ON `documents` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'document' AND `record_identifier` = NEW.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('document', NEW.`id`);
END;
--> statement-breakpoint
CREATE TRIGGER `documents_change_journal_after_update` AFTER UPDATE ON `documents` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'document' AND `record_identifier` IN (OLD.`id`, NEW.`id`);
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) SELECT 'document', OLD.`id` WHERE OLD.`id` <> NEW.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('document', NEW.`id`);
END;
--> statement-breakpoint
CREATE TRIGGER `documents_change_journal_after_delete` AFTER DELETE ON `documents` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'document' AND `record_identifier` = OLD.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('document', OLD.`id`);
END;
--> statement-breakpoint
CREATE TRIGGER `document_tags_change_journal_after_insert` AFTER INSERT ON `document_tags` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'document' AND `record_identifier` = NEW.`document_id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('document', NEW.`document_id`);
END;
--> statement-breakpoint
CREATE TRIGGER `document_tags_change_journal_after_update` AFTER UPDATE ON `document_tags` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'document' AND `record_identifier` IN (OLD.`document_id`, NEW.`document_id`);
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) SELECT 'document', OLD.`document_id` WHERE OLD.`document_id` <> NEW.`document_id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('document', NEW.`document_id`);
END;
--> statement-breakpoint
CREATE TRIGGER `document_tags_change_journal_after_delete` AFTER DELETE ON `document_tags` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'document' AND `record_identifier` = OLD.`document_id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('document', OLD.`document_id`);
END;
--> statement-breakpoint
CREATE TRIGGER `extracted_fields_change_journal_after_insert` AFTER INSERT ON `extracted_fields` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'document' AND `record_identifier` = NEW.`document_id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('document', NEW.`document_id`);
END;
--> statement-breakpoint
CREATE TRIGGER `extracted_fields_change_journal_after_update` AFTER UPDATE ON `extracted_fields` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'document' AND `record_identifier` IN (OLD.`document_id`, NEW.`document_id`);
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) SELECT 'document', OLD.`document_id` WHERE OLD.`document_id` <> NEW.`document_id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('document', NEW.`document_id`);
END;
--> statement-breakpoint
CREATE TRIGGER `extracted_fields_change_journal_after_delete` AFTER DELETE ON `extracted_fields` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'document' AND `record_identifier` = OLD.`document_id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('document', OLD.`document_id`);
END;
--> statement-breakpoint
CREATE TRIGGER `household_members_change_journal_after_insert` AFTER INSERT ON `household_members` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'household_member' AND `record_identifier` = NEW.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('household_member', NEW.`id`);
END;
--> statement-breakpoint
CREATE TRIGGER `household_members_change_journal_after_update` AFTER UPDATE ON `household_members` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'household_member' AND `record_identifier` IN (OLD.`id`, NEW.`id`);
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) SELECT 'household_member', OLD.`id` WHERE OLD.`id` <> NEW.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('household_member', NEW.`id`);
END;
--> statement-breakpoint
CREATE TRIGGER `household_members_change_journal_after_delete` AFTER DELETE ON `household_members` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'household_member' AND `record_identifier` = OLD.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('household_member', OLD.`id`);
END;
--> statement-breakpoint
CREATE TRIGGER `senders_change_journal_after_insert` AFTER INSERT ON `senders` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'sender' AND `record_identifier` = NEW.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('sender', NEW.`id`);
END;
--> statement-breakpoint
CREATE TRIGGER `senders_change_journal_after_update` AFTER UPDATE ON `senders` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'sender' AND `record_identifier` IN (OLD.`id`, NEW.`id`);
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) SELECT 'sender', OLD.`id` WHERE OLD.`id` <> NEW.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('sender', NEW.`id`);
END;
--> statement-breakpoint
CREATE TRIGGER `senders_change_journal_after_delete` AFTER DELETE ON `senders` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'sender' AND `record_identifier` = OLD.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('sender', OLD.`id`);
END;
--> statement-breakpoint
CREATE TRIGGER `categories_change_journal_after_insert` AFTER INSERT ON `categories` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'category' AND `record_identifier` = NEW.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('category', NEW.`id`);
END;
--> statement-breakpoint
CREATE TRIGGER `categories_change_journal_after_update` AFTER UPDATE ON `categories` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'category' AND `record_identifier` IN (OLD.`id`, NEW.`id`);
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) SELECT 'category', OLD.`id` WHERE OLD.`id` <> NEW.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('category', NEW.`id`);
END;
--> statement-breakpoint
CREATE TRIGGER `categories_change_journal_after_delete` AFTER DELETE ON `categories` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'category' AND `record_identifier` = OLD.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('category', OLD.`id`);
END;
--> statement-breakpoint
CREATE TRIGGER `tags_change_journal_after_insert` AFTER INSERT ON `tags` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'tag' AND `record_identifier` = NEW.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('tag', NEW.`id`);
END;
--> statement-breakpoint
CREATE TRIGGER `tags_change_journal_after_update` AFTER UPDATE ON `tags` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'tag' AND `record_identifier` IN (OLD.`id`, NEW.`id`);
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) SELECT 'tag', OLD.`id` WHERE OLD.`id` <> NEW.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('tag', NEW.`id`);
END;
--> statement-breakpoint
CREATE TRIGGER `tags_change_journal_after_delete` AFTER DELETE ON `tags` BEGIN
	DELETE FROM `change_journal` WHERE `record_kind` = 'tag' AND `record_identifier` = OLD.`id`;
	INSERT INTO `change_journal` (`record_kind`, `record_identifier`) VALUES ('tag', OLD.`id`);
END;
--> statement-breakpoint
INSERT INTO `change_journal_identity` (`single_row`, `journal_identifier`) VALUES (1, lower(hex(randomblob(16))));
--> statement-breakpoint
-- The records that exist already. A client reads the journal upwards from its start, so the
-- documents come first in the order of the archive's listing, and the first pages of a fill hold
-- the documents a person looks for first. Each page carries the records its documents refer to,
-- so the other records can follow.
INSERT INTO `change_journal` (`record_kind`, `record_identifier`) SELECT 'document', `id` FROM `documents`
	ORDER BY `status` <> 'archived' DESC, coalesce(`document_date`, date(`created_at`, 'unixepoch')) DESC, `created_at` DESC, `id` DESC;
--> statement-breakpoint
INSERT INTO `change_journal` (`record_kind`, `record_identifier`) SELECT 'household_member', `id` FROM `household_members` ORDER BY `created_at`, `id`;
--> statement-breakpoint
INSERT INTO `change_journal` (`record_kind`, `record_identifier`) SELECT 'sender', `id` FROM `senders` ORDER BY `created_at`, `id`;
--> statement-breakpoint
INSERT INTO `change_journal` (`record_kind`, `record_identifier`) SELECT 'category', `id` FROM `categories` ORDER BY `created_at`, `id`;
--> statement-breakpoint
INSERT INTO `change_journal` (`record_kind`, `record_identifier`) SELECT 'tag', `id` FROM `tags` ORDER BY `created_at`, `id`;
