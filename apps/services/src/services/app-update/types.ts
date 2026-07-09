/**
 * App Update Service Types
 * 
 * Type definitions for the auto-update system.
 */

// Update channel types
export type UpdateChannel = 'beta' | 'production';

// Platform types
export type Platform = 'darwin' | 'win32' | 'linux';

// Architecture types
export type Arch = 'arm64' | 'x64';

// Update configuration
export interface UpdateConfig {
  enabled: boolean;      // Whether updates are enabled
  mandatory: boolean;    // Whether update is mandatory (force update)
}

// Update manifest (compatible with electron-updater)
export interface UpdateManifest {
  version: string;
  files: Array<{
    url: string;
    sha512: string;
    size: number;
  }>;
  path: string;
  sha512: string;
  releaseDate: string;
  releaseName: string;
  releaseNotes?: string;
  mandatory?: boolean;   // Added field for force update
}

// Config store interface (Dependency Inversion Principle)
export interface IUpdateConfigStore {
  getConfig(channel: UpdateChannel): Promise<UpdateConfig>;
  setConfig(channel: UpdateChannel, config: UpdateConfig): Promise<void>;
}

// Manifest provider interface (Dependency Inversion Principle)
export interface IUpdateManifestProvider {
  getManifest(channel: UpdateChannel, platform: Platform): Promise<UpdateManifest | null>;
}
