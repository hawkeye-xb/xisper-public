/**
 * App Update Proxy Service
 * 
 * Orchestrates update checking logic.
 * Follows Dependency Inversion Principle - depends on abstractions, not concrete implementations.
 */

import type { 
  IUpdateConfigStore, 
  IUpdateManifestProvider, 
  UpdateChannel, 
  Platform, 
  UpdateManifest 
} from './types';

/**
 * Update Proxy Service
 * 
 * Handles update requests:
 * 1. Check if updates are enabled
 * 2. Fetch manifest from storage
 * 3. Inject mandatory flag
 * 4. Return result
 */
export class UpdateProxyService {
  constructor(
    private configStore: IUpdateConfigStore,
    private manifestProvider: IUpdateManifestProvider
  ) {}
  
  /**
   * Handle update request
   * 
   * @param channel - Update channel (beta or production)
   * @param platform - OS platform (darwin, win32, linux)
   * @param currentVersion - Current app version (optional, for logging)
   * @returns Update manifest if available, null otherwise
   */
  async handleUpdateRequest(
    channel: UpdateChannel,
    platform: Platform,
    currentVersion?: string
  ): Promise<UpdateManifest | null> {
    console.log(`[UpdateProxyService] Update request: channel=${channel}, platform=${platform}, currentVersion=${currentVersion || 'unknown'}`);
    
    // 1. Check configuration switch
    const config = await this.configStore.getConfig(channel);
    
    if (!config.enabled) {
      console.log(`[UpdateProxyService] Updates disabled for channel: ${channel}`);
      return null;  // Return null means no update available
    }
    
    console.log(`[UpdateProxyService] Updates enabled for channel: ${channel} (mandatory: ${config.mandatory})`);
    
    // 2. Fetch manifest
    const manifest = await this.manifestProvider.getManifest(channel, platform);
    
    if (!manifest) {
      console.log(`[UpdateProxyService] No manifest found for channel: ${channel}, platform: ${platform}`);
      return null;
    }
    
    // 3. Inject mandatory field
    manifest.mandatory = config.mandatory;
    
    // 4. Log and return
    console.log(`[UpdateProxyService] Update available: ${manifest.version} (mandatory: ${config.mandatory})`);
    
    return manifest;
  }
}
