/**
 * Copy Xisper icons to all apps that need them.
 * Run: pnpm --filter @xisper/icons build:icons
 */
import { cpSync, mkdirSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const ICONS_ROOT = join(__dirname, '..')
const ROOT = join(ICONS_ROOT, '..', '..')

function copy(src, dest) {
  mkdirSync(dirname(dest), { recursive: true })
  cpSync(src, dest, { force: true })
}


// mac-desktop: AppIcon.appiconset + XisperIcon.imageset
const macAssets = join(ROOT, 'apps', 'mac-desktop', 'Xisper', 'Assets.xcassets')
const macosIconset = join(ICONS_ROOT, 'Xisper.iconset')
const iconNames = [
  'icon_16x16', 'icon_16x16@2x',
  'icon_32x32', 'icon_32x32@2x',
  'icon_128x128', 'icon_128x128@2x',
  'icon_256x256', 'icon_256x256@2x',
  'icon_512x512', 'icon_512x512@2x',
]
for (const name of iconNames) {
  copy(join(macosIconset, `${name}.png`), join(macAssets, 'AppIcon.appiconset', `${name}.png`))
}
copy(join(macosIconset, 'icon_128x128.png'), join(macAssets, 'XisperIcon.imageset', 'icon_128x128.png'))
copy(join(macosIconset, 'icon_128x128@2x.png'), join(macAssets, 'XisperIcon.imageset', 'icon_128x128@2x.png'))

console.log('✅ Icons copied to desktop/build, web/public, admin/public, landing/public, mac-desktop/Assets')