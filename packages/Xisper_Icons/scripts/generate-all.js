/**
 * Generate all Xisper icons from SVG.
 * Source: xisper_primary_macos.svg (#007C8B brand teal).
 * Outputs: iconset/, Xisper.iconset/, tray/, Xisper.icns
 */
import sharp from 'sharp'
import { readFileSync, mkdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const ICONS_ROOT = join(__dirname, '..')
const ICONSET_DIR = join(ICONS_ROOT, 'iconset')
const MACOS_ICONSET_DIR = join(ICONS_ROOT, 'Xisper.iconset')
const TRAY_DIR = join(ICONS_ROOT, 'tray')

const SIZES = [
  [16, 'icon_16x16.png', 'icon_16x16@2x.png', 32],
  [32, 'icon_32x32.png', 'icon_32x32@2x.png', 64],
  [128, 'icon_128x128.png', 'icon_128x128@2x.png', 256],
  [256, 'icon_256x256.png', 'icon_256x256@2x.png', 512],
  [512, 'icon_512x512.png', 'icon_512x512@2x.png', 1024],
]

async function generateIconset(svgPath) {
  mkdirSync(ICONSET_DIR, { recursive: true })
  const svg = readFileSync(svgPath)

  for (const [size1x, name1x, name2x, size2x] of SIZES) {
    await sharp(svg).resize(size1x, size1x).png().toFile(join(ICONSET_DIR, name1x))
    await sharp(svg).resize(size2x, size2x).png().toFile(join(ICONSET_DIR, name2x))
  }
  console.log('✅ Iconset generated (16–1024px)')
}

async function generateMacosIconset(svgPath) {
  mkdirSync(MACOS_ICONSET_DIR, { recursive: true })
  const svg = readFileSync(svgPath)

  for (const [size1x, name1x, name2x, size2x] of SIZES) {
    await sharp(svg).resize(size1x, size1x).png().toFile(join(MACOS_ICONSET_DIR, name1x))
    await sharp(svg).resize(size2x, size2x).png().toFile(join(MACOS_ICONSET_DIR, name2x))
  }
  console.log('✅ Xisper.iconset generated (16–1024px)')
}

async function generateTray(svgPath) {
  mkdirSync(TRAY_DIR, { recursive: true })
  const svg = readFileSync(svgPath)
  const source = await sharp(svg).resize(512, 512).png().toBuffer()

  const icon16 = await sharp(source).resize(16, 16, { kernel: 'lanczos3' }).png().toBuffer()
  await sharp(icon16)
    .extend({ top: 3, bottom: 3, left: 3, right: 3, background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toFile(join(TRAY_DIR, 'xisper_black_22.png'))

  const icon32 = await sharp(source).resize(32, 32, { kernel: 'lanczos3' }).png().toBuffer()
  await sharp(icon32)
    .extend({ top: 6, bottom: 6, left: 6, right: 6, background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toFile(join(TRAY_DIR, 'xisper_black_44.png'))

  console.log('✅ Tray icons generated (22/44pt)')
}

async function generateIcns() {
  const icnsPath = join(ICONS_ROOT, 'Xisper.icns')
  const src1024 = join(MACOS_ICONSET_DIR, 'icon_512x512@2x.png')
  const { createICNS } = await import('png2icons')
  const { readFileSync } = await import('node:fs')
  try {
    const input = readFileSync(src1024)
    const output = createICNS(input, 0)
    const { writeFileSync } = await import('node:fs')
    writeFileSync(icnsPath, Buffer.from(output))
    console.log('✅ Xisper.icns generated')
  } catch (e) {
    console.warn('⚠️ icns generation failed:', e.message)
  }
}

async function main() {
  const appSvg = join(ICONS_ROOT, 'svg', 'xisper_app.svg')
  const macosSvg = join(ICONS_ROOT, 'svg', 'xisper_primary_macos.svg')
  const blackSvg = join(ICONS_ROOT, 'svg', 'xisper_black.svg')

  await generateIconset(appSvg)
  await generateMacosIconset(macosSvg)
  await generateTray(blackSvg)
  await generateIcns()
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})