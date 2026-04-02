-- Default admin user with password 'change_me' (BCrypt encoded)
INSERT INTO users (username, password_hash, display_name, email, role, enabled)
VALUES ('admin', '$2a$10$SCjumTfh0XwfkKu7COdXI.91t/05h1UK5LmCS/m3iNULaGGPEPdLe', 'Administrator', 'admin@kappman.local', 'ADMIN', true);
