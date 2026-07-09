/**
 * App Update Config Store
 * 
 * Implements different storage strategies for update configuration.
 * Follows Strategy Pattern and Dependency Inversion Principle.
 */

import type { IUpdateConfigStore, UpdateChannel, UpdateConfig } from './types';

/**
 * KV Storage Implementation (Recommended)
 * 
 * Stores update configuration in Cloudflare KV.
 * Provides real-time control over update deployment.
 */
export class KVUpdateConfigStore implements IUpdateConfigStore {
  constructor(private kv: KVNamespace) {}
  
  async getConfig(channel: UpdateChannel): Promise<UpdateConfig> {
    const key = `update_config:${channel}`;
    const value = await this.kv.get<UpdateConfig>(key, 'json');
    
    // Return default config if not found
    return value || { enabled: false, mandatory: false };
  }
  
  async setConfig(channel: UpdateChannel, config: UpdateConfig): Promise<void> {
    const key = `update_config:${channel}`;
    await this.kv.put(key, JSON.stringify(config));
  }
}

/**
 * D1 Storage Implementation (Optional, for future extension)
 * 
 * Stores update configuration in Cloudflare D1 database.
 * Useful when you need more complex queries or audit logs.
 */
export class D1UpdateConfigStore implements IUpdateConfigStore {
  constructor(private db: D1Database) {}
  
  async getConfig(channel: UpdateChannel): Promise<UpdateConfig> {
    const result = await this.db
      .prepare('SELECT enabled, mandatory FROM app_update_config WHERE channel = ?')
      .bind(channel)
      .first<{ enabled: number; mandatory: number }>();
    
    if (!result) {
      return { enabled: false, mandatory: false };
    }
    
    return {
      enabled: Boolean(result.enabled),
      mandatory: Boolean(result.mandatory),
    };
  }
  
  async setConfig(channel: UpdateChannel, config: UpdateConfig): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO app_update_config (channel, enabled, mandatory, updated_at)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(channel) DO UPDATE SET
           enabled = excluded.enabled,
           mandatory = excluded.mandatory,
           updated_at = excluded.updated_at`
      )
      .bind(
        channel,
        config.enabled ? 1 : 0,
        config.mandatory ? 1 : 0,
        Date.now()
      )
      .run();
  }
}

/**
 * Environment Variable Storage Implementation (Simple case)
 * 
 * Reads update configuration from environment variables.
 * Read-only, useful for testing or simple deployments.
 */
export class EnvUpdateConfigStore implements IUpdateConfigStore {
  constructor(private env: Record<string, string | undefined>) {}
  
  async getConfig(channel: UpdateChannel): Promise<UpdateConfig> {
    const enabledKey = `UPDATE_ENABLED_${channel.toUpperCase()}`;
    const mandatoryKey = `UPDATE_MANDATORY_${channel.toUpperCase()}`;
    
    return {
      enabled: this.env[enabledKey] === 'true',
      mandatory: this.env[mandatoryKey] === 'true',
    };
  }
  
  async setConfig(): Promise<void> {
    throw new Error('EnvUpdateConfigStore is read-only');
  }
}
