/**
 * Generate tray icons from 512px source for sharp rendering on macOS menu bar.
 * Canvas: 22x22 @1x, 44x44 @2x. Icon content: 16x16 / 32x32 (Bjango: "16pt circular
 * items match system menu bar weight"). Padding centers the icon in the canvas.
 */
import sharp from 'sharp'
import { readFileSync } from 'node:fs'
import { mkdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const ICONS_ROOT = join(__dirname, '..')
const TRAY_DIR = join(ICONS_ROOT, 'tray')

const SVG_PATH = join(ICONS_ROOT, 'svg', 'xisper_black.svg')

async function generate() {
  mkdirSync(TRAY_DIR, { recursive: true })

  const svg = readFileSync(SVG_PATH)
  const source = await sharp(svg).resize(512, 512).png().toBuffer()

  // Icon content 16pt, canvas 22pt → 3pt padding each side
  const icon16 = await sharp(source).resize(16, 16, { kernel: 'lanczos3' }).png().toBuffer()
  await sharp(icon16)
    .extend({ top: 3, bottom: 3, left: 3, right: 3, background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toFile(join(TRAY_DIR, 'xisper_black_22.png'))

  // Icon content 32pt, canvas 44pt → 6pt padding each side
  const icon32 = await sharp(source).resize(32, 32, { kernel: 'lanczos3' }).png().toBuffer()
  await sharp(icon32)
    .extend({ top: 6, bottom: 6, left: 6, right: 6, background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toFile(join(TRAY_DIR, 'xisper_black_44.png'))

  console.log('✅ Tray icons generated: 16pt content in 22/44pt canvas (standard macOS padding)')
}

generate().catch((err) => {
  console.error(err)
  process.exit(1)
})