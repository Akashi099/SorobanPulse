-- Issue #1348: Microsoft Teams notification channel.
-- webhook_url holds an AES-256-GCM envelope (`enc:v1:` prefix) produced by
-- integration_secrets::seal — Teams incoming webhook URLs embed a secret.
CREATE TABLE IF NOT EXISTS teams_integrations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subscription_id UUID NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    webhook_url TEXT NOT NULL CONSTRAINT teams_integrations_webhook_url_encrypted
        CHECK (webhook_url LIKE 'enc:v1:%'),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (subscription_id)
);
