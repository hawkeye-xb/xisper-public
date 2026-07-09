#!/usr/bin/env node

import fs from 'fs/promises';
import { readFileSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * Load DEEPSEEK_API_KEY from process.env or .env file.
 */
function getDeepSeekApiKey() {
  if (process.env.DEEPSEEK_API_KEY) {
    return process.env.DEEPSEEK_API_KEY;
  }
  
  const envPaths = [
    path.join(process.cwd(), '.env'),
    path.join(__dirname, '../../../apps/mac-desktop/.env')
  ];
  
  for (const envPath of envPaths) {
    try {
      const content = readFileSync(envPath, 'utf8');
      for (const line of content.split('\n')) {
        const trimmed = line.trim();
        if (trimmed.startsWith('#') || !trimmed) continue;
        const eq = trimmed.indexOf('=');
        if (eq === -1) continue;
        const key = trimmed.slice(0, eq).trim();
        if (key === 'DEEPSEEK_API_KEY') {
          let val = trimmed.slice(eq + 1).trim();
          if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
            val = val.slice(1, -1);
          }
          return val;
        }
      }
    } catch {
      continue;
    }
  }
  
  return null;
}

// Supported locales
const supportedLocales = ['zh-Hans', 'ja'];

// Language name mapping for translation API
const LANGUAGE_MAPPING = {
  'zh-Hans': 'Simplified Chinese',
  'ja': 'Japanese'
};

// Project paths
const MAC_DESKTOP_ROOT = path.join(process.cwd());
const XCSTRINGS_PATH = path.join(MAC_DESKTOP_ROOT, 'Xisper/Localizable.xcstrings');

/**
 * Translate text using DeepSeek official API
 */
async function translateWithDeepSeek(text, targetLang) {
  const apiKey = getDeepSeekApiKey();
  if (!apiKey) {
    throw new Error('DEEPSEEK_API_KEY not found. Set it in process.env or .env file');
  }

  const systemPrompt = `You are a professional translator. Translate the following English text to ${targetLang}. Keep technical terms (Xisper, BLE, App Key, App Secret, Client ID, Client Secret, SDK, Webhook, URL, API, JSON, HTTP, HTTPS, OAuth, JWT, REST, GraphQL, WebSocket, POST, PUT, PATCH, DELETE, GET, etc.) in English. Use natural and colloquial expressions. Return ONLY the translated text, nothing else.`;

  const response = await fetch('https://api.deepseek.com/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: 'deepseek-chat',
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
 * Batch translate texts with retry logic
 */
async function translateTexts(texts, targetLang, maxRetries = 3) {
  const results = {};
  
  for (const text of texts) {
    for (let retries = 0; retries < maxRetries; retries++) {
      try {
        console.log(`  Translating: "${text}" -> ${targetLang}`);
        const translation = await translateWithDeepSeek(text, LANGUAGE_MAPPING[targetLang]);
        results[text] = translation;
        console.log(`    ✓ "${translation}"`);
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
 * Read and parse .xcstrings file
 */
async function readXCStrings(filePath) {
  try {
    const content = await fs.readFile(filePath, 'utf8');
    return JSON.parse(content);
  } catch (error) {
    console.error(`Failed to read .xcstrings file:`, error.message);
    throw error;
  }
}

/**
 * Write .xcstrings file with proper formatting
 */
async function writeXCStrings(filePath, data) {
  const content = JSON.stringify(data, null, 2);
  await fs.writeFile(filePath, content + '\n', 'utf8');
}

/**
 * Find missing translations in .xcstrings file
 */
function findMissingTranslations(xcstrings, locale) {
  const missing = [];
  
  for (const [key, value] of Object.entries(xcstrings.strings)) {
    const hasTranslation = value.localizations?.[locale]?.stringUnit?.value;
    if (!hasTranslation) {
      missing.push(key);
    }
  }
  
  return missing;
}

/**
 * Update .xcstrings with new translations
 */
function updateXCStrings(xcstrings, translations, locale) {
  for (const [key, translation] of Object.entries(translations)) {
    if (!xcstrings.strings[key]) {
      xcstrings.strings[key] = {};
    }
    
    if (!xcstrings.strings[key].localizations) {
      xcstrings.strings[key].localizations = {};
    }
    
    xcstrings.strings[key].localizations[locale] = {
      stringUnit: {
        state: 'translated',
        value: translation
      }
    };
  }
  
  return xcstrings;
}

/**
 * Main function
 */
async function main() {
  console.log('🌍 Starting Swift i18n translation (xcstrings format)...\n');
  console.log(`Supported languages: ${supportedLocales.join(', ')}`);
  console.log(`Translation model: DeepSeek\n`);
  
  // Read existing .xcstrings file
  console.log(`Reading: ${XCSTRINGS_PATH}`);
  const xcstrings = await readXCStrings(XCSTRINGS_PATH);
  
  const totalKeys = Object.keys(xcstrings.strings).length;
  console.log(`Total keys in .xcstrings: ${totalKeys}\n`);
  
  // Process each target language
  for (const locale of supportedLocales) {
    console.log(`Processing language: ${locale}`);
    
    const missing = findMissingTranslations(xcstrings, locale);
    console.log(`  Missing translations: ${missing.length}`);
    
    if (missing.length === 0) {
      console.log(`  ${locale} is complete!\n`);
      continue;
    }
    
    console.log(`  Translating ${missing.length} keys...\n`);
    const translations = await translateTexts(missing, locale);
    
    // Update xcstrings with new translations
    updateXCStrings(xcstrings, translations, locale);
    console.log(`  ✅ Updated ${locale} translations\n`);
  }
  
  // Write updated .xcstrings file
  await writeXCStrings(XCSTRINGS_PATH, xcstrings);
  console.log(`💾 Saved to: ${XCSTRINGS_PATH}`);
  console.log('\n🎉 Translation task complete!');
}

// Run if executed directly
if (import.meta.url.startsWith('file://')) {
  const modulePath = fileURLToPath(import.meta.url);
  if (process.argv[1] === modulePath || process.argv[1].endsWith('translate-swift.js')) {
    main().catch(error => {
      console.error('❌ Translation task failed:', error.message);
      process.exit(1);
    });
  }
}
