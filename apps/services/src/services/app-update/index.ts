/**
 * App Update Service
 * 
 * Entry point for the auto-update system.
 * Exports all public APIs and types.
 */

// Export types
export type {
  UpdateChannel,
  Platform,
  Arch,
  UpdateConfig,
  UpdateManifest,
  IUpdateConfigStore,
  IUpdateManifestProvider,
} from './types';

// Export config stores
export {
  KVUpdateConfigStore,
  D1UpdateConfigStore,
  EnvUpdateConfigStore,
} from './config-store';

// Export manifest providers
export {
  R2UpdateManifestProvider,
} from './manifest-provider';

// Export service
export {
  UpdateProxyService,
} from './proxy-service';
