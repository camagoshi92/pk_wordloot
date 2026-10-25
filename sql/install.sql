CREATE TABLE IF NOT EXISTS `pk_wordloot_containers` (
    `container_id` VARCHAR(191) NOT NULL,
    `model` VARCHAR(64) NOT NULL,
    `x` DECIMAL(12,3) NOT NULL,
    `y` DECIMAL(12,3) NOT NULL,
    `z` DECIMAL(12,3) NOT NULL,
    `cooldown_until` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `pending_loot` LONGTEXT NULL,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`container_id`),
    KEY `idx_pk_wordloot_cooldown` (`cooldown_until`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
