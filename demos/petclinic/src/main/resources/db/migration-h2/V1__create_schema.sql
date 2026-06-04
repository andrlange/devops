-- V1__create_schema.sql
-- PetClinic schema - compatible with PostgreSQL 18 and H2

CREATE TABLE pet_types (
    id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name      VARCHAR(80) NOT NULL UNIQUE
);

CREATE TABLE owners (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name VARCHAR(80)  NOT NULL,
    last_name  VARCHAR(80)  NOT NULL,
    address    VARCHAR(255) NOT NULL,
    city       VARCHAR(80)  NOT NULL,
    telephone  VARCHAR(20)  NOT NULL,
    email      VARCHAR(120)
);

CREATE TABLE pets (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       VARCHAR(80)  NOT NULL,
    birth_date DATE         NOT NULL,
    image_url  VARCHAR(512),
    type_id    BIGINT       NOT NULL REFERENCES pet_types(id),
    owner_id   BIGINT       NOT NULL REFERENCES owners(id) ON DELETE CASCADE
);

CREATE TABLE specialties (
    id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR(80) NOT NULL UNIQUE
);

CREATE TABLE vets (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name VARCHAR(80) NOT NULL,
    last_name  VARCHAR(80) NOT NULL
);

CREATE TABLE vet_specialties (
    vet_id       BIGINT NOT NULL REFERENCES vets(id) ON DELETE CASCADE,
    specialty_id BIGINT NOT NULL REFERENCES specialties(id) ON DELETE CASCADE,
    PRIMARY KEY (vet_id, specialty_id)
);

CREATE TABLE visits (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pet_id      BIGINT       NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
    vet_id      BIGINT       NOT NULL REFERENCES vets(id),
    visit_date  DATE         NOT NULL,
    visit_time  TIME         NOT NULL,
    description VARCHAR(255) NOT NULL,
    status      VARCHAR(20)  NOT NULL DEFAULT 'SCHEDULED'
);

-- Indexes
CREATE INDEX idx_pets_owner_id    ON pets(owner_id);
CREATE INDEX idx_pets_type_id     ON pets(type_id);
CREATE INDEX idx_visits_pet_id    ON visits(pet_id);
CREATE INDEX idx_visits_vet_id    ON visits(vet_id);
CREATE INDEX idx_visits_date      ON visits(visit_date);
CREATE INDEX idx_visits_status    ON visits(status);
CREATE INDEX idx_owners_last_name ON owners(last_name);
