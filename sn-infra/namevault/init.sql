CREATE TABLE IF NOT EXISTS mappings (
    id SERIAL PRIMARY KEY,
    real TEXT NOT NULL UNIQUE,
    pseudo TEXT NOT NULL,
    created_by TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
