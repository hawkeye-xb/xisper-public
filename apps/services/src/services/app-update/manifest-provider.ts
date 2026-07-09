/**
 * App Update Manifest Provider
 * 
 * Fetches update manifests from R2 storage.
 * Follows Single Responsibility Principle.
 */

import type { IUpdateManifestProvider, UpdateChannel, Platform, UpdateManifest } from './types';

/**
 * R2 Update Manifest Provider
 * 
 * Fetches latest-*.yml files from Cloudflare R2.
 * Compatible with electron-updater format.
 */
export class R2UpdateManifestProvider implements IUpdateManifestProvider {
  constructor(
    private r2Endpoint: string,
    private bucketName: string,
    private r2PublicUrl?: string
  ) {}
  
  async getManifest(channel: UpdateChannel, platform: Platform): Promise<UpdateManifest | null> {
    // Determine manifest filename based on platform
    const platformName = platform === 'darwin' ? 'mac' : platform;
    const manifestPath = `${channel}/latest-${platformName}.yml`;
    
    // Use public URL if available, otherwise use R2 endpoint
    const baseUrl = this.r2PublicUrl || `${this.r2Endpoint}/${this.bucketName}`;
    const url = `${baseUrl}/${manifestPath}`;
    
    try {
      console.log(`[ManifestProvider] Fetching manifest from: ${url}`);
      
      const response = await fetch(url);
      
      if (!response.ok) {
        if (response.status === 404) {
          console.log(`[ManifestProvider] Manifest not found: ${manifestPath}`);
        } else {
          console.error(`[ManifestProvider] Failed to fetch manifest: ${response.status} ${response.statusText}`);
        }
        return null;
      }
      
      const yamlText = await response.text();
      const manifest = this.parseYaml(yamlText);
      
      // Rewrite relative file URLs to absolute paths so electron-updater can download directly from R2
      const channelBaseUrl = `${baseUrl}/${channel}`;
      manifest.files = manifest.files.map(file => ({
        ...file,
        url: file.url.startsWith('http') ? file.url : `${channelBaseUrl}/${file.url}`,
      }));
      if (manifest.path && !manifest.path.startsWith('http')) {
        manifest.path = `${channelBaseUrl}/${manifest.path}`;
      }
      
      console.log(`[ManifestProvider] Successfully fetched manifest for version: ${manifest.version}`);
      
      return manifest;
    } catch (error) {
      console.error('[ManifestProvider] Failed to fetch manifest:', error);
      return null;
    }
  }
  
  /**
   * Parse YAML manifest file
   * 
   * Simple YAML parser for electron-updater's latest-*.yml format.
   * Format example:
   * version: 0.0.1-beta
   * files:
   *   - url: Xisper-Dev-0.0.1-beta-arm64-mac.zip
   *     sha512: xxx
   *     size: 12345
   * path: Xisper-Dev-0.0.1-beta-arm64-mac.zip
   * sha512: xxx
   * releaseDate: '2026-02-03T10:00:00.000Z'
   * releaseName: 0.0.1-beta
   */
  private parseYaml(yaml: string): UpdateManifest {
    const lines = yaml.split('\n');
    const manifest: Partial<UpdateManifest> = {
      files: [],
    };
    
    let currentFile: any = null;
    let inFilesSection = false;
    
    for (const line of lines) {
      const trimmed = line.trim();
      
      if (!trimmed || trimmed.startsWith('#')) {
        continue;
      }
      
      // Check if we should exit files section (non-indented top-level field)
      // Use original line (not trimmed) to check indentation
      if (inFilesSection && !line.startsWith(' ') && !line.startsWith('\t') && !trimmed.startsWith('-') && trimmed.includes(':')) {
        // Save last file and exit files section
        if (currentFile) {
          manifest.files!.push(currentFile);
          currentFile = null;
        }
        inFilesSection = false;
        // Continue to parse this line as a top-level field
      }
      
      // Parse top-level fields
      if (trimmed.startsWith('version:')) {
        manifest.version = this.extractValue(trimmed);
      } else if (trimmed.startsWith('path:')) {
        manifest.path = this.extractValue(trimmed);
      } else if (trimmed.startsWith('sha512:') && !inFilesSection) {
        manifest.sha512 = this.extractValue(trimmed);
      } else if (trimmed.startsWith('releaseDate:')) {
        manifest.releaseDate = this.extractValue(trimmed);
      } else if (trimmed.startsWith('releaseName:')) {
        manifest.releaseName = this.extractValue(trimmed);
      } else if (trimmed.startsWith('releaseNotes:')) {
        // Release notes can be multiline, so we handle it simply
        const value = this.extractValue(trimmed);
        manifest.releaseNotes = value === '|' ? '' : value;
      } else if (trimmed === 'files:') {
        inFilesSection = true;
      } else if (inFilesSection) {
        // Parse files array
        if (trimmed.startsWith('- url:') || trimmed.startsWith('url:')) {
          // Save previous file if exists
          if (currentFile) {
            manifest.files!.push(currentFile);
          }
          // Start new file
          currentFile = {
            url: this.extractValue(trimmed.replace('- ', '')),
            sha512: '',
            size: 0,
          };
        } else if (trimmed.startsWith('sha512:') && currentFile) {
          currentFile.sha512 = this.extractValue(trimmed);
        } else if (trimmed.startsWith('size:') && currentFile) {
          currentFile.size = parseInt(this.extractValue(trimmed), 10);
        }
      }
    }
    
    // Add last file if exists
    if (currentFile) {
      manifest.files!.push(currentFile);
    }
    
    // Validate required fields
    if (!manifest.version || !manifest.path || !manifest.sha512) {
      throw new Error('Invalid manifest: missing required fields');
    }
    
    return manifest as UpdateManifest;
  }
  
  /**
   * Extract value from YAML line
   * Example: "version: 0.0.1-beta" -> "0.0.1-beta"
   */
  private extractValue(line: string): string {
    const index = line.indexOf(':');
    if (index === -1) {
      return line;
    }
    
    let value = line.substring(index + 1).trim();
    
    // Remove quotes if present
    if ((value.startsWith("'") && value.endsWith("'")) ||
        (value.startsWith('"') && value.endsWith('"'))) {
      value = value.slice(1, -1);
    }
    
    return value;
  }
}
