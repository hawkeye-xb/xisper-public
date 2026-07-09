// ═══════════════════════════════════════════════════════════════
//  Design Language Tokens — Auto-generated, do not edit manually
// ═══════════════════════════════════════════════════════════════

import SwiftUI
import AppKit

// MARK: - Colors

extension Color {
    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua]) == .darkAqua {
                return NSColor(red: dark.0/255, green: dark.1/255, blue: dark.2/255, alpha: 1)
            }
            return NSColor(red: light.0/255, green: light.1/255, blue: light.2/255, alpha: 1)
        })
    }

    // Primary Scale
    static let primary1 = adaptive(light: (248, 252, 253), dark: (6, 8, 8))
    static let primary2 = adaptive(light: (240, 246, 247), dark: (9, 13, 14))
    static let primary3 = adaptive(light: (224, 236, 238), dark: (16, 22, 23))
    static let primary4 = adaptive(light: (206, 226, 230), dark: (21, 30, 31))
    static let primary5 = adaptive(light: (181, 217, 222), dark: (25, 39, 41))
    static let primary6 = adaptive(light: (140, 198, 207), dark: (31, 52, 56))
    static let primary7 = adaptive(light: (90, 173, 185), dark: (35, 73, 79))
    static let primary8 = adaptive(light: (0, 143, 159), dark: (0, 143, 159))
    static let primary9 = adaptive(light: (0, 124, 139), dark: (28, 157, 173))
    static let primary10 = adaptive(light: (0, 95, 108), dark: (105, 182, 193))
    static let primary11 = adaptive(light: (0, 65, 74), dark: (172, 219, 226))
    static let primary12 = adaptive(light: (0, 37, 42), dark: (219, 240, 243))

    // Neutral Scale
    static let neutral1 = adaptive(light: (251, 251, 251), dark: (7, 7, 7))
    static let neutral2 = adaptive(light: (245, 245, 245), dark: (12, 12, 12))
    static let neutral3 = adaptive(light: (233, 233, 234), dark: (21, 21, 21))
    static let neutral4 = adaptive(light: (221, 222, 222), dark: (27, 28, 28))
    static let neutral5 = adaptive(light: (208, 209, 209), dark: (35, 36, 36))
    static let neutral6 = adaptive(light: (184, 187, 187), dark: (48, 48, 49))
    static let neutral7 = adaptive(light: (156, 159, 160), dark: (65, 67, 67))
    static let neutral8 = adaptive(light: (122, 126, 127), dark: (122, 126, 127))
    static let neutral9 = adaptive(light: (105, 109, 109), dark: (137, 141, 142))
    static let neutral10 = adaptive(light: (80, 83, 84), dark: (165, 168, 169))
    static let neutral11 = adaptive(light: (54, 56, 57), dark: (207, 209, 210))
    static let neutral12 = adaptive(light: (30, 31, 32), dark: (234, 235, 235))

    // Success Scale
    static let success1 = adaptive(light: (249, 252, 249), dark: (6, 8, 6))
    static let success2 = adaptive(light: (242, 247, 242), dark: (10, 13, 10))
    static let success3 = adaptive(light: (227, 237, 227), dark: (17, 22, 17))
    static let success4 = adaptive(light: (211, 227, 211), dark: (23, 30, 23))
    static let success5 = adaptive(light: (190, 218, 190), dark: (28, 39, 28))
    static let success6 = adaptive(light: (156, 200, 156), dark: (37, 53, 37))
    static let success7 = adaptive(light: (116, 176, 117), dark: (47, 74, 48))
    static let success8 = adaptive(light: (62, 146, 69), dark: (62, 146, 69))
    static let success9 = adaptive(light: (47, 127, 54), dark: (82, 161, 87))
    static let success10 = adaptive(light: (33, 98, 39), dark: (128, 184, 129))
    static let success11 = adaptive(light: (22, 67, 26), dark: (184, 221, 184))
    static let success12 = adaptive(light: (11, 38, 13), dark: (224, 241, 224))

    // Warning Scale
    static let warning1 = adaptive(light: (254, 250, 247), dark: (9, 7, 6))
    static let warning2 = adaptive(light: (250, 244, 239), dark: (15, 11, 9))
    static let warning3 = adaptive(light: (244, 231, 222), dark: (26, 19, 15))
    static let warning4 = adaptive(light: (239, 217, 204), dark: (35, 26, 20))
    static let warning5 = adaptive(light: (237, 201, 177), dark: (46, 33, 23))
    static let warning6 = adaptive(light: (229, 173, 136), dark: (63, 43, 30))
    static let warning7 = adaptive(light: (212, 139, 87), dark: (91, 57, 34))
    static let warning8 = adaptive(light: (190, 96, 0), dark: (190, 96, 0))
    static let warning9 = adaptive(light: (168, 80, 0), dark: (204, 113, 37))
    static let warning10 = adaptive(light: (131, 60, 0), dark: (219, 150, 102))
    static let warning11 = adaptive(light: (90, 40, 0), dark: (245, 198, 167))
    static let warning12 = adaptive(light: (52, 22, 0), dark: (252, 230, 217))

    // Danger Scale
    static let danger1 = adaptive(light: (255, 250, 249), dark: (10, 6, 6))
    static let danger2 = adaptive(light: (252, 243, 242), dark: (16, 11, 10))
    static let danger3 = adaptive(light: (246, 229, 227), dark: (27, 18, 18))
    static let danger4 = adaptive(light: (243, 214, 211), dark: (36, 24, 23))
    static let danger5 = adaptive(light: (244, 196, 191), dark: (49, 31, 29))
    static let danger6 = adaptive(light: (238, 165, 158), dark: (66, 40, 38))
    static let danger7 = adaptive(light: (223, 127, 120), dark: (96, 52, 49))
    static let danger8 = adaptive(light: (203, 78, 74), dark: (203, 78, 74))
    static let danger9 = adaptive(light: (179, 63, 60), dark: (217, 97, 91))
    static let danger10 = adaptive(light: (140, 46, 44), dark: (230, 139, 132))
    static let danger11 = adaptive(light: (96, 31, 29), dark: (253, 191, 185))
    static let danger12 = adaptive(light: (56, 16, 15), dark: (255, 228, 224))

    // Info Scale
    static let info1 = adaptive(light: (248, 252, 253), dark: (6, 8, 8))
    static let info2 = adaptive(light: (240, 246, 248), dark: (9, 13, 14))
    static let info3 = adaptive(light: (223, 236, 240), dark: (15, 22, 24))
    static let info4 = adaptive(light: (205, 226, 232), dark: (20, 30, 32))
    static let info5 = adaptive(light: (179, 217, 226), dark: (24, 39, 43))
    static let info6 = adaptive(light: (137, 198, 213), dark: (30, 52, 58))
    static let info7 = adaptive(light: (84, 173, 193), dark: (32, 73, 82))
    static let info8 = adaptive(light: (0, 142, 169), dark: (0, 142, 169))
    static let info9 = adaptive(light: (0, 123, 149), dark: (0, 157, 183))
    static let info10 = adaptive(light: (0, 95, 115), dark: (100, 181, 201))
    static let info11 = adaptive(light: (0, 65, 79), dark: (169, 219, 231))
    static let info12 = adaptive(light: (0, 37, 45), dark: (218, 240, 245))

}

// MARK: - Typography

enum DesignFont {
    static let xs: CGFloat = 10.0
    static let sm: CGFloat = 13.0
    static let base: CGFloat = 16.0
    static let lg: CGFloat = 20.0
    static let xl: CGFloat = 25.0
    static let xxl: CGFloat = 31.0
    static let xxxl: CGFloat = 39.0
    static let xxxxl: CGFloat = 49.0
    static let display: CGFloat = 61.0

    // Line heights (multiplier)
    static let lineHeight_xs: CGFloat = 1.6
    static let lineHeight_sm: CGFloat = 1.55
    static let lineHeight_base: CGFloat = 1.5
    static let lineHeight_lg: CGFloat = 1.45
    static let lineHeight_xl: CGFloat = 1.35
    static let lineHeight_xxl: CGFloat = 1.3
    static let lineHeight_xxxl: CGFloat = 1.25
    static let lineHeight_xxxxl: CGFloat = 1.2
    static let lineHeight_display: CGFloat = 1.1

    // Font weights
    static let weight_regular: Font.Weight = .regular
    static let weight_medium: Font.Weight = .medium
    static let weight_semibold: Font.Weight = .semibold
    static let weight_bold: Font.Weight = .bold
}

// MARK: - Spacing

enum DesignSpacing {
    static let xxxxs: CGFloat = 4
    static let xxxs: CGFloat = 8
    static let xxs: CGFloat = 16
    static let xs: CGFloat = 20
    static let sm: CGFloat = 24
    static let md: CGFloat = 32
    static let lg: CGFloat = 40
    static let xl: CGFloat = 48
    static let xxl: CGFloat = 64
    static let xxxl: CGFloat = 80
    static let xxxxl: CGFloat = 96

    // Semantic
    static let page_margin: CGFloat = 64
    static let section_gap: CGFloat = 48
    static let card_padding: CGFloat = 40
    static let stack_gap: CGFloat = 32
    static let inline_gap: CGFloat = 24
    static let input_padding_x: CGFloat = 24
    static let input_padding_y: CGFloat = 20
    static let button_padding_x: CGFloat = 32
    static let button_padding_y: CGFloat = 20
    static let icon_gap: CGFloat = 8
}

// MARK: - Corner Radius

enum DesignRadius {
    static let none: CGFloat = 0
    static let xs: CGFloat = 2
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 32
    static let full: CGFloat = .infinity
}

// MARK: - Animation

extension Animation {
    static let gentle = Animation.interpolatingSpring(mass: 1.0, stiffness: 120, damping: 17.4)
    static let `default` = Animation.interpolatingSpring(mass: 1.0, stiffness: 170, damping: 18.6)
    static let responsive = Animation.interpolatingSpring(mass: 0.8, stiffness: 300, damping: 22.3)
    static let bouncy = Animation.interpolatingSpring(mass: 1.0, stiffness: 200, damping: 12.4)

    static let micro = Animation.easeInOut(duration: 0.08)
    static let fast = Animation.easeInOut(duration: 0.13)
    static let normal = Animation.easeInOut(duration: 0.21)
    static let slow = Animation.easeInOut(duration: 0.3)
    static let slower = Animation.easeInOut(duration: 0.42)
    static let page = Animation.easeInOut(duration: 0.34)
}
