#!/usr/bin/env node

import fs from 'fs/promises';
import { readFileSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * Load OPENROUTER_API_KEY from process.env or apps/web/.env file.
 * Env var takes precedence if set.
 */
function getOpenRouterApiKey() {
  if (process.env.OPENROUTER_API_KEY) {
    return process.env.OPENROUTER_API_KEY;
  }
  const envPath = path.join(process.cwd(), '.env');
  try {
    const content = readFileSync(envPath, 'utf8');
    for (const line of content.split('\n')) {
      const trimmed = line.trim();
      if (trimmed.startsWith('#') || !trimmed) continue;
      const eq = trimmed.indexOf('=');
      if (eq === -1) continue;
      const key = trimmed.slice(0, eq).trim();
      if (key === 'OPENROUTER_API_KEY') {
        let val = trimmed.slice(eq + 1).trim();
        if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
          val = val.slice(1, -1);
        }
        return val;
      }
    }
  } catch {
    // File not found or unreadable
  }
  return null;
}

// Supported locales
const supportedLocales = ['en', 'zh', 'ja'].filter(locale => locale !== 'en');

// Language name mapping for translation API
const LANGUAGE_MAPPING = {
  zh: 'Simplified Chinese',
  ja: 'Japanese'
};

// Project root (cwd when running the command, not script location)
const PROJECT_ROOT = process.cwd();

/**
 * Find all view i18n directories
 */
async function findViewI18nDirs() {
  const viewsPath = path.join(PROJECT_ROOT, 'src/views');
  const dirs = [];
  
  try {
    const viewDirs = await fs.readdir(viewsPath, { withFileTypes: true });
    for (const dir of viewDirs) {
      if (dir.isDirectory()) {
        const i18nPath = path.join(viewsPath, dir.name, 'i18n');
        try {
          await fs.access(i18nPath);
          dirs.push(`src/views/${dir.name}/i18n`);
        } catch {
          // Directory does not exist, skip
        }
      }
    }
  } catch (error) {
    console.error('Failed to scan views directory:', error.message);
  }
  
  return dirs;
}

/**
 * Translate text using OpenRouter Chat Completions API.
 */
async function translateWithGPT(text, targetLang) {
  const apiKey = getOpenRouterApiKey();
  if (!apiKey) {
    throw new Error('OPENROUTER_API_KEY not found. Set it in process.env or apps/web/.env');
  }

  const systemPrompt = `You are a professional translator. Translate the following English text to ${targetLang}. Keep technical terms (Xisper, BLE, App Key, App Secret, Client ID, Client Secret, SDK, Webhook, URL, API, JSON, HTTP, HTTPS, OAuth, JWT, REST, GraphQL, WebSocket, etc.) in English. Use natural and colloquial expressions. Return ONLY the translated text, nothing else.`;

  const response = await fetch('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: 'google/gemini-2.0-flash-001',
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: text },
      ],
    }),
  });

  const responseData = await response.json();
  const content = responseData.choices?.[0]?.message?.content;
  if (!content) {
    throw new Error('Translation failed: ' + JSON.stringify(responseData));
  }

  return content.trim();
}

/**
 * Read TypeScript language file and parse to object
 */
async function readLanguageFile(filePath) {
  try {
    const content = await fs.readFile(filePath, 'utf8');
    // Remove export default and outer braces, then parse
    const objStr = content
      .replace(/^export\s+default\s*/, '')
      .replace(/^\s*{/, '{')
      .replace(/}\s*$/, '}');
    
    // Use Function constructor to safely parse object
    const func = new Function('return ' + objStr);
    return func();
  } catch (error) {
    console.warn(`Failed to read language file ${filePath}:`, error.message);
    return {};
  }
}

/**
 * Write TypeScript language file
 */
async function writeLanguageFile(filePath, data) {
  // Ensure directory exists
  const dir = path.dirname(filePath);
  await fs.mkdir(dir, { recursive: true });
  
  // Format object as TypeScript
  let content = 'export default {\n';
  
  // Sort by key name and format
  const sortedKeys = Object.keys(data).sort((a, b) => {
    const aLower = a.toLowerCase();
    const bLower = b.toLowerCase();
    if (aLower !== bLower) {
      return aLower.localeCompare(bLower);
    }
    return a.localeCompare(b);
  });
  
  for (const key of sortedKeys) {
    const value = data[key];
    // All keys use double quotes
    const formattedKey = `"${key.replace(/"/g, '\\"')}"`;
    // All values use double quotes, escape special chars
    const formattedValue = `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '\\r').replace(/\t/g, '\\t')}"`;
    content += `  ${formattedKey}: ${formattedValue},\n`;
  }
  
  content += '}\n';
  
  await fs.writeFile(filePath, content, 'utf8');
}

/**
 * Compare two language objects and find differences
 */
function compareLanguageObjects(baseObj, targetObj) {
  const baseKeys = new Set(Object.keys(baseObj));
  const targetKeys = new Set(Object.keys(targetObj));
  
  const keysToAdd = [...baseKeys].filter(key => !targetKeys.has(key));
  const keysToRemove = [...targetKeys].filter(key => !baseKeys.has(key));
  
  return { keysToAdd, keysToRemove };
}

/**
 * Batch translate texts
 */
async function translateTexts(texts, targetLang, maxRetries = 3) {
  const results = {};
  
  for (const text of texts) {
    for (let retries = 0; retries < maxRetries; retries++) {
      try {
        console.log(`  Translating: "${text}" -> ${targetLang}`);
        const translation = await translateWithGPT(text, LANGUAGE_MAPPING[targetLang]);
        results[text] = translation;
        // Add delay to avoid API rate limits
        await new Promise(resolve => setTimeout(resolve, 500));
        break;
      } catch (error) {
        if (retries === maxRetries - 1) {
          console.error(`  Failed to translate "${text}" to ${targetLang}:`, error.message);
          results[text] = text; // Fallback to original on failure
        } else {
          console.warn(`  Retry ${retries + 1} for "${text}"`);
          await new Promise(resolve => setTimeout(resolve, 1000 * (retries + 1)));
        }
      }
    }
  }
  
  return results;
}

/**
 * Process a single i18n directory
 */
async function processI18nDirectory(i18nDir) {
  console.log(`\nProcessing directory: ${i18nDir}`);
  
  const dirPath = path.join(PROJECT_ROOT, i18nDir);
  const enFilePath = path.join(dirPath, 'en.ts');
  
  // Check if English base file exists
  try {
    await fs.access(enFilePath);
  } catch {
    console.log(`  Skip: English base file not found ${enFilePath}`);
    return;
  }
  
  // Read English base file
  const enData = await readLanguageFile(enFilePath);
  const enKeys = Object.keys(enData);
  
  if (enKeys.length === 0) {
    console.log(`  Skip: English file is empty`);
    return;
  }
  
  console.log(`  English base file has ${enKeys.length} keys`);
  
  // Process each target language
  for (const locale of supportedLocales) {
    console.log(`\n  Processing language: ${locale}`);
    
    const targetFilePath = path.join(dirPath, `${locale}.ts`);
    let targetData = await readLanguageFile(targetFilePath);
    
    // Compare differences
    const { keysToAdd, keysToRemove } = compareLanguageObjects(enData, targetData);
    
    console.log(`    Keys to add: ${keysToAdd.length}`);
    console.log(`    Keys to remove: ${keysToRemove.length}`);
    
    if (keysToAdd.length === 0 && keysToRemove.length === 0) {
      console.log(`    ${locale} file already in sync, no update needed`);
      continue;
    }
    
    // Remove obsolete keys
    for (const key of keysToRemove) {
      delete targetData[key];
      console.log(`    Removed key: "${key}"`);
    }
    
    // Translate and add new keys
    if (keysToAdd.length > 0) {
      console.log(`    Translating ${keysToAdd.length} new keys...`);
      const translations = await translateTexts(keysToAdd, locale);
      
      for (const key of keysToAdd) {
        targetData[key] = translations[key];
        console.log(`    Added key: "${key}" -> "${translations[key]}"`);
      }
    }
    
    // Write updated file
    await writeLanguageFile(targetFilePath, targetData);
    console.log(`    ✅ Updated ${targetFilePath}`);
  }
}

/**
 * Main function
 */
async function main() {
  console.log('🌍 Starting i18n translation task...\n');
  console.log(`Supported languages: ${supportedLocales.join(', ')}`);
  
  // Get i18n directory list
  const i18nDirs = [
    'src/i18n/global',
    ...(await findViewI18nDirs())
  ];
  
  console.log(`\nFound ${i18nDirs.length} i18n directories:`);
  i18nDirs.forEach(dir => console.log(`  - ${dir}`));
  
  // Process each directory
  for (const dir of i18nDirs) {
    await processI18nDirectory(dir);
  }
  
  console.log('\n🎉 Translation task complete!');
}

// Export functions for use by other scripts
export {
  translateWithGPT,
  processI18nDirectory,
  findViewI18nDirs,
  main
};

// If running this script directly
if (import.meta.url.startsWith('file://')) {
  const modulePath = fileURLToPath(import.meta.url);
  if (process.argv[1] === modulePath || process.argv[1].endsWith('translate.js')) {
    main().catch(error => {
      console.error('❌ Translation task failed:', error.message);
      process.exit(1);
    });
  }
}

