-- Add attachments column to memories table for blob storage
ALTER TABLE memories ADD COLUMN attachments JSONB DEFAULT '[]'::jsonb;

-- Create index on attachments for faster lookups
CREATE INDEX IF NOT EXISTS idx_memories_attachments ON memories USING GIN (attachments);

-- Update migration version tracking
INSERT INTO schema_migrations (version, applied_at) 
VALUES ('v6.2_attachments', NOW()) 
ON CONFLICT (version) DO NOTHING;