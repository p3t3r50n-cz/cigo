CREATE DATABASE IF NOT EXISTS mail CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE mail;

CREATE TABLE IF NOT EXISTS domain (
  domain VARCHAR(255) PRIMARY KEY,
  active TINYINT(1) NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS mailbox (
  email VARCHAR(255) PRIMARY KEY,
  domain VARCHAR(255) NOT NULL,
  localpart VARCHAR(64) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  active TINYINT(1) NOT NULL DEFAULT 1,
  UNIQUE KEY mailbox_address (domain, localpart),
  CONSTRAINT mailbox_domain FOREIGN KEY (domain) REFERENCES domain(domain)
);

CREATE TABLE IF NOT EXISTS mail_alias (
  address VARCHAR(255) PRIMARY KEY,
  destination TEXT NOT NULL,
  active TINYINT(1) NOT NULL DEFAULT 1
);
