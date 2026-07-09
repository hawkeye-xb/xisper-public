#!/usr/bin/env node

/**
 * Move script for copying build outputs to build/output directory
 * This script should be run after all build tasks are completed
 */

import { existsSync, mkdirSync, cpSync, rmSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const ROOT_DIR = join(__dirname, '../..');
const OUTPUT_DIR = join(ROOT_DIR, 'build/output');

const pathsToCopy = [
  {
    source: join(ROOT_DIR, 'apps/oauth2-platform/dist'),
    dest: join(OUTPUT_DIR, 'developer/portal'),
    name: 'dp-oa dist'
  },
  {
    source: join(ROOT_DIR, 'apps/developer-platform/dist'),
    dest: join(OUTPUT_DIR, 'developer/dp-portal'),
    name: 'dp-portal dist'
  },
  {
    source: join(ROOT_DIR, 'apps/privacy'),
    dest: join(OUTPUT_DIR, 'developer/privacy'),
    name: 'privacy'
  },
  {
    source: join(ROOT_DIR, 'apps/user-agreement'),
    dest: join(OUTPUT_DIR, 'developer/user-agreement'),
    name: 'user-agreement'
  },
  {
    source: join(ROOT_DIR, 'apps/support'),
    dest: join(OUTPUT_DIR, 'developer/support'),
    name: 'support'
  },
  {
    source: join(ROOT_DIR, 'apps/stt-demo/dist'),
    dest: join(OUTPUT_DIR, 'demo/stt'),
    name: 'stt-demo dist'
  },
  {
    source: join(ROOT_DIR, 'packages/feature-toggle'),
    dest: join(OUTPUT_DIR, 'feature-toggle'),
    name: 'feature-toggle'
  },
  {
    source: join(ROOT_DIR, '_routes.json'),
    dest: join(OUTPUT_DIR, '_routes.json'),
    name: '_routes.json',
    optional: false
  },
  {
    source: join(ROOT_DIR, '_redirects'),
    dest: join(OUTPUT_DIR, '_redirects'),
    name: '_redirects',
    optional: true
  }
];

function log(message) {
  console.log(`[build-move] ${message}`);
}

function error(message) {
  console.error(`[build-move] ERROR: ${message}`);
  process.exit(1);
}

function cleanOutputDir() {
  if (existsSync(OUTPUT_DIR)) {
    log('Cleaning existing output directory...');
    rmSync(OUTPUT_DIR, { recursive: true, force: true });
  }
  mkdirSync(OUTPUT_DIR, { recursive: true });
  log('Output directory ready');
}

function copyFiles() {
  log('Copying files to output directory...');
  
  for (const { source, dest, name, optional } of pathsToCopy) {
    if (!existsSync(source)) {
      if (optional) {
        log(`⊘ Skipped ${name} (optional, not found)`);
        continue;
      } else {
        error(`Source path does not exist: ${source}`);
      }
    }
    
    try {
      const destDir = dirname(dest);
      if (!existsSync(destDir)) {
        mkdirSync(destDir, { recursive: true });
      }
      
      cpSync(source, dest, { recursive: true });
      log(`✓ Copied ${name}`);
    } catch (err) {
      error(`Failed to copy ${name}: ${err.message}`);
    }
  }
  
  log('All files copied successfully');
}

function main() {
  log('Starting file move process...');
  
  // Step 1: Clean output directory
  cleanOutputDir();
  
  // Step 2: Copy files
  copyFiles();
  
  log('File move process completed successfully!');
  log(`Output directory: ${OUTPUT_DIR}`);
}

main();

